load("@build_bazel_rules_apple//apple:macos.bzl", "macos_command_line_application")
load("//:helper.bzl", "santa_unit_test")

licenses(["notice"])

package(default_visibility = ["//:santa_package_group"])

objc_library(
    name = "FCM_lib",
    srcs = ["SNTSyncFCM.m"],
    hdrs = ["SNTSyncFCM.h"],
    sdk_frameworks = ["SystemConfiguration"],
    deps = [
        "@MOLAuthenticatingURLSession",
    ],
)

objc_library(
    name = "sync_lib",
    srcs = [
        "NSData+Zlib.h",
        "NSData+Zlib.m",
        "SNTSyncConstants.h",
        "SNTSyncConstants.m",
        "SNTSyncEventUpload.h",
        "SNTSyncEventUpload.m",
        "SNTSyncManager.m",
        "SNTSyncPostflight.h",
        "SNTSyncPostflight.m",
        "SNTSyncPreflight.h",
        "SNTSyncPreflight.m",
        "SNTSyncRuleDownload.h",
        "SNTSyncRuleDownload.m",
        "SNTSyncStage.h",
        "SNTSyncStage.m",
        "SNTSyncState.h",
        "SNTSyncState.m",
    ],
    hdrs = ["SNTSyncManager.h"],
    sdk_dylibs = ["libz"],
    deps = [
        ":FCM_lib",
        "//Source/common:SNTFileInfo",
        "//Source/common:SNTLogging",
        "//Source/common:SNTXPCControlInterface",
        "//Source/common:SNTXPCSyncdInterface",
        "@MOLAuthenticatingURLSession",
        "@MOLXPCConnection",
    ],
)

# Using :sync_lib breaks the Zlib category hack used in the tests to
# disable compression, in turn failing the tests. Re-compile here to keep
# the "override" category behavior.
santa_unit_test(
    name = "SNTSyncTest",
    srcs = [
        "NSData+Zlib.h",
        "NSData+Zlib.m",
        "SNTSyncConstants.h",
        "SNTSyncConstants.m",
        "SNTSyncEventUpload.h",
        "SNTSyncEventUpload.m",
        "SNTSyncPostflight.h",
        "SNTSyncPostflight.m",
        "SNTSyncPreflight.h",
        "SNTSyncPreflight.m",
        "SNTSyncRuleDownload.h",
        "SNTSyncRuleDownload.m",
        "SNTSyncStage.h",
        "SNTSyncStage.m",
        "SNTSyncState.h",
        "SNTSyncState.m",
        "SNTSyncTest.m",
    ],
    resources = glob([
        "testdata/*.json",
        "testdata/*.plist",
    ]),
    sdk_dylibs = ["libz"],
    deps = [
        ":FCM_lib",
        "//Source/common:SNTCommonEnums",
        "//Source/common:SNTConfigurator",
        "//Source/common:SNTDropRootPrivs",
        "//Source/common:SNTFileInfo",
        "//Source/common:SNTLogging",
        "//Source/common:SNTRule",
        "//Source/common:SNTStoredEvent",
        "//Source/common:SNTXPCControlInterface",
        "//Source/common:SNTXPCSyncdInterface",
        "@MOLAuthenticatingURLSession",
        "@MOLXPCConnection",
        "@OCMock",
    ],
)

objc_library(
    name = "santass_lib",
    srcs = [
        "SNTSyncService.h",
        "SNTSyncService.m",
        "main.m",
    ],
    deps = [
        "//Source/common:SNTLogging",
        "//Source/common:SNTXPCSyncServiceInterface",
        "@MOLCodesignChecker",
        "@MOLXPCConnection",
    ],
)

macos_command_line_application(
    name = "santasyncservice",
    bundle_id = "com.google.santa.syncservice",
    infoplists = ["Info.plist"],
    minimum_os_version = "10.9",
    version = "//:version",
    visibility = ["//:santa_package_group"],
    deps = [":santass_lib"],
)

test_suite(
    name = "unit_tests",
    tests = [
        ":SNTSyncTest",
    ],
    visibility = ["//:santa_package_group"],
)
