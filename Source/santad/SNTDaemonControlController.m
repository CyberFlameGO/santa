/// Copyright 2015 Google Inc. All rights reserved.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///    http://www.apache.org/licenses/LICENSE-2.0
///
///    Unless required by applicable law or agreed to in writing, software
///    distributed under the License is distributed on an "AS IS" BASIS,
///    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
///    See the License for the specific language governing permissions and
///    limitations under the License.

#import "Source/santad/SNTDaemonControlController.h"

#import <MOLXPCConnection/MOLXPCConnection.h>

#import "Source/common/SNTCachedDecision.h"
#import "Source/common/SNTCommonEnums.h"
#import "Source/common/SNTConfigurator.h"
#import "Source/common/SNTLogging.h"
#import "Source/common/SNTMetricSet.h"
#import "Source/common/SNTRule.h"
#import "Source/common/SNTStoredEvent.h"
#import "Source/common/SNTStrengthify.h"
#import "Source/common/SNTXPCBundleServiceInterface.h"
#import "Source/common/SNTXPCNotifierInterface.h"
#import "Source/common/SNTXPCSyncdInterface.h"
#import "Source/santad/DataLayer/SNTEventTable.h"
#import "Source/santad/DataLayer/SNTRuleTable.h"
#import "Source/santad/EventProviders/SNTEventProvider.h"
#import "Source/santad/Logs/SNTEventLog.h"
#import "Source/santad/SNTDatabaseController.h"
#import "Source/santad/SNTNotificationQueue.h"
#import "Source/santad/SNTPolicyProcessor.h"
#import "Source/santad/SNTSyncdQueue.h"

// Globals used by the santad watchdog thread
uint64_t watchdogCPUEvents = 0;
uint64_t watchdogRAMEvents = 0;
double watchdogCPUPeak = 0;
double watchdogRAMPeak = 0;

@interface SNTDaemonControlController ()
@property NSString *_syncXsrfToken;
@property SNTPolicyProcessor *policyProcessor;
@property id<SNTEventProvider> eventProvider;
@property SNTNotificationQueue *notQueue;
@property SNTSyncdQueue *syncdQueue;
@end

@implementation SNTDaemonControlController

- (instancetype)initWithEventProvider:(id<SNTEventProvider>)eventProvider
                    notificationQueue:(SNTNotificationQueue *)notQueue
                           syncdQueue:(SNTSyncdQueue *)syncdQueue {
  self = [super init];
  if (self) {
    _policyProcessor =
      [[SNTPolicyProcessor alloc] initWithRuleTable:[SNTDatabaseController ruleTable]];
    _eventProvider = eventProvider;
    _notQueue = notQueue;
    _syncdQueue = syncdQueue;
  }
  return self;
}

#pragma mark Kernel ops

- (void)cacheCounts:(void (^)(uint64_t, uint64_t))reply {
  NSArray<NSNumber *> *counts = [self.eventProvider cacheCounts];
  reply([counts[0] unsignedLongLongValue], [counts[1] unsignedLongLongValue]);
}

- (void)cacheBucketCount:(void (^)(NSArray *))reply {
  reply([self.eventProvider cacheBucketCount]);
}

- (void)flushCache:(void (^)(BOOL))reply {
  reply([self.eventProvider flushCacheNonRootOnly:NO]);
}

- (void)checkCacheForVnodeID:(santa_vnode_id_t)vnodeID withReply:(void (^)(santa_action_t))reply {
  reply([self.eventProvider checkCache:vnodeID]);
}

- (void)driverConnectionEstablished:(void (^)(BOOL))reply {
  reply(self.eventProvider.connectionEstablished);
}

#pragma mark Database ops

- (void)databaseRuleCounts:(void (^)(int64_t binary, int64_t certificate, int64_t compiler,
                                     int64_t transitive, int64_t teamID))reply {
  SNTRuleTable *rdb = [SNTDatabaseController ruleTable];
  reply([rdb binaryRuleCount], [rdb certificateRuleCount], [rdb compilerRuleCount],
        [rdb transitiveRuleCount], [rdb teamIDRuleCount]);
}

- (void)databaseRuleAddRules:(NSArray *)rules
                  cleanSlate:(BOOL)cleanSlate
                       reply:(void (^)(NSError *error))reply {
  SNTRuleTable *ruleTable = [SNTDatabaseController ruleTable];

  // If any rules are added that are not plain allowlist rules, then flush decision cache.
  // In particular, the addition of allowlist compiler rules should cause a cache flush.
  // We also flush cache if a allowlist compiler rule is replaced with a allowlist rule.
  BOOL flushCache = (cleanSlate || [ruleTable addedRulesShouldFlushDecisionCache:rules]);

  NSError *error;
  [ruleTable addRules:rules cleanSlate:cleanSlate error:&error];

  // Whenever we add rules, we can also check for and remove outdated transitive rules.
  [ruleTable removeOutdatedTransitiveRules];

  // The actual cache flushing happens after the new rules have been added to the database.
  if (flushCache) {
    LOGI(@"Flushing decision cache");
    [self.eventProvider flushCacheNonRootOnly:NO];
  }

  reply(error);
}

- (void)databaseEventCount:(void (^)(int64_t count))reply {
  reply([[SNTDatabaseController eventTable] pendingEventsCount]);
}

- (void)databaseEventsPending:(void (^)(NSArray *events))reply {
  reply([[SNTDatabaseController eventTable] pendingEvents]);
}

- (void)databaseRemoveEventsWithIDs:(NSArray *)ids {
  [[SNTDatabaseController eventTable] deleteEventsWithIds:ids];
}

- (void)databaseRuleForBinarySHA256:(NSString *)binarySHA256
                  certificateSHA256:(NSString *)certificateSHA256
                             teamID:(NSString *)teamID
                              reply:(void (^)(SNTRule *))reply {
  reply([[SNTDatabaseController ruleTable] ruleForBinarySHA256:binarySHA256
                                             certificateSHA256:certificateSHA256
                                                        teamID:teamID]);
}

#pragma mark Decision Ops

- (void)decisionForFilePath:(NSString *)filePath
                 fileSHA256:(NSString *)fileSHA256
          certificateSHA256:(NSString *)certificateSHA256
                     teamID:(NSString *)teamID
                      reply:(void (^)(SNTEventState))reply {
  reply([self.policyProcessor decisionForFilePath:filePath
                                       fileSHA256:fileSHA256
                                certificateSHA256:certificateSHA256
                                           teamID:teamID]
          .decision);
}

#pragma mark Config Ops

- (void)watchdogInfo:(void (^)(uint64_t, uint64_t, double, double))reply {
  reply(watchdogCPUEvents, watchdogRAMEvents, watchdogCPUPeak, watchdogRAMPeak);
}

- (void)clientMode:(void (^)(SNTClientMode))reply {
  reply([[SNTConfigurator configurator] clientMode]);
}

- (void)setClientMode:(SNTClientMode)mode reply:(void (^)(void))reply {
  [[SNTConfigurator configurator] setSyncServerClientMode:mode];
  reply();
}

- (void)xsrfToken:(void (^)(NSString *))reply {
  reply(self._syncXsrfToken);
}

- (void)setXsrfToken:(NSString *)token reply:(void (^)(void))reply {
  self._syncXsrfToken = token;
  reply();
}

- (void)fullSyncLastSuccess:(void (^)(NSDate *))reply {
  reply([[SNTConfigurator configurator] fullSyncLastSuccess]);
}

- (void)setFullSyncLastSuccess:(NSDate *)date reply:(void (^)(void))reply {
  [[SNTConfigurator configurator] setFullSyncLastSuccess:date];
  reply();
}

- (void)ruleSyncLastSuccess:(void (^)(NSDate *))reply {
  reply([[SNTConfigurator configurator] ruleSyncLastSuccess]);
}

- (void)setRuleSyncLastSuccess:(NSDate *)date reply:(void (^)(void))reply {
  [[SNTConfigurator configurator] setRuleSyncLastSuccess:date];
  reply();
}

- (void)syncCleanRequired:(void (^)(BOOL))reply {
  reply([[SNTConfigurator configurator] syncCleanRequired]);
}

- (void)setSyncCleanRequired:(BOOL)cleanReqd reply:(void (^)(void))reply {
  [[SNTConfigurator configurator] setSyncCleanRequired:cleanReqd];
  reply();
}

- (void)setAllowedPathRegex:(NSString *)pattern reply:(void (^)(void))reply {
  NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                      options:0
                                                                        error:NULL];
  [[SNTConfigurator configurator] setSyncServerAllowedPathRegex:re];
  reply();
}

- (void)setBlockedPathRegex:(NSString *)pattern reply:(void (^)(void))reply {
  NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                      options:0
                                                                        error:NULL];
  [[SNTConfigurator configurator] setSyncServerBlockedPathRegex:re];
  reply();
}

- (void)setBlockUSBMount:(BOOL)enabled reply:(void (^)(void))reply {
  [[SNTConfigurator configurator] setBlockUSBMount:enabled];
  reply();
}
- (void)setRemountUSBMode:(NSArray *)remountUSBMode reply:(void (^)(void))reply {
  [[SNTConfigurator configurator] setRemountUSBMode:remountUSBMode];
  reply();
}

- (void)enableBundles:(void (^)(BOOL))reply {
  reply([SNTConfigurator configurator].enableBundles);
}

- (void)setEnableBundles:(BOOL)enableBundles reply:(void (^)(void))reply {
  [[SNTConfigurator configurator] setEnableBundles:enableBundles];
  reply();
}

- (void)enableTransitiveRules:(void (^)(BOOL))reply {
  reply([SNTConfigurator configurator].enableTransitiveRules);
}

- (void)setEnableTransitiveRules:(BOOL)enabled reply:(void (^)(void))reply {
  [[SNTConfigurator configurator] setEnableTransitiveRules:enabled];
  reply();
}

#pragma mark Metrics Ops

- (void)metrics:(void (^)(NSDictionary *))reply {
  SNTMetricSet *metricSet = [SNTMetricSet sharedInstance];
  reply([metricSet export]);
}

#pragma mark GUI Ops

- (void)setNotificationListener:(NSXPCListenerEndpoint *)listener {
  // This will leak the underlying NSXPCConnection when "fast user switching" occurs.
  // It is not worth the trouble to fix. Maybe future self will feel differently.
  MOLXPCConnection *c = [[MOLXPCConnection alloc] initClientWithListener:listener];
  c.remoteInterface = [SNTXPCNotifierInterface notifierInterface];
  [c resume];
  self.notQueue.notifierConnection = c;
}

#pragma mark syncd Ops

- (void)setSyncdListener:(NSXPCListenerEndpoint *)listener {
  // Only allow one active syncd connection
  if (self.syncdQueue.syncdConnection) return;
  MOLXPCConnection *c = [[MOLXPCConnection alloc] initClientWithListener:listener];
  c.remoteInterface = [SNTXPCSyncdInterface syncdInterface];
  c.invalidationHandler = ^{
    [self.syncdQueue stopSyncingEvents];
    [self.syncdQueue.syncdConnection invalidate];
    self.syncdQueue.syncdConnection = nil;
    if (self.syncdQueue.invalidationHandler) self.syncdQueue.invalidationHandler();
  };
  c.acceptedHandler = ^{
    [self.syncdQueue startSyncingEvents];
  };
  [c resume];
  self.syncdQueue.syncdConnection = c;
}

- (void)pushNotifications:(void (^)(BOOL))reply {
  [self.syncdQueue.syncdConnection.remoteObjectProxy isFCMListening:^(BOOL response) {
    reply(response);
  }];
}

- (void)postRuleSyncNotificationWithCustomMessage:(NSString *)message reply:(void (^)(void))reply {
  [[self.notQueue.notifierConnection remoteObjectProxy]
    postRuleSyncNotificationWithCustomMessage:message];
  reply();
}

///
///  Used by SantaGUI sync the offending event and potentially all the related events,
///  if the sync server has not seen them before.
///
///  @param event The offending event, fileBundleHash & fileBundleBinaryCount need to be populated.
///  @param events Next bundle events.
///
- (void)syncBundleEvent:(SNTStoredEvent *)event relatedEvents:(NSArray<SNTStoredEvent *> *)events {
  SNTEventTable *eventTable = [SNTDatabaseController eventTable];

  // Delete the event cached by the execution controller.
  [eventTable deleteEventWithId:event.idx];

  // Add the updated event.
  [eventTable addStoredEvent:event];

  // Log all of the generated bundle events.
  [[SNTEventLog logger] logBundleHashingEvents:events];

  WEAKIFY(self);

  // Sync the updated event. If the sync server needs the related events, add them to the eventTable
  // and upload them too.
  [self.syncdQueue addBundleEvent:event
                            reply:^(SNTBundleEventAction action) {
                              STRONGIFY(self);
                              switch (action) {
                                case SNTBundleEventActionDropEvents: break;
                                case SNTBundleEventActionStoreEvents:
                                  [eventTable addStoredEvents:events];
                                  break;
                                case SNTBundleEventActionSendEvents:
                                  [eventTable addStoredEvents:events];
                                  [self.syncdQueue addEvents:events isFromBundle:YES];
                                  break;
                              }
                            }];
}

@end
