#ifndef FLM_VIEWPORT_HANDSHAKE_H
#define FLM_VIEWPORT_HANDSHAKE_H

#import <Foundation/Foundation.h>
#import <notify.h>

#define FLM_VIEWPORT_HANDSHAKE_VERSION 1
#define FLM_VIEWPORT_REQUEST_NOTIFICATION \
    "com.codex.flymemultitasking.viewport-request-v1"
#define FLM_VIEWPORT_COMMIT_NOTIFICATION \
    "com.codex.flymemultitasking.viewport-commit-v1"
#define FLM_KEYBOARD_APP_READY_NOTIFICATION \
    "com.codex.flymemultitasking.keyboard-app-ready-v47"

static NSString *const FLMViewportRequestPath =
    @"/var/mobile/Library/Preferences/FlymeMultitasking-ViewportRequest.plist";
static NSString *const FLMViewportRequestRootlessPath =
    @"/var/jb/var/mobile/Library/Preferences/FlymeMultitasking-ViewportRequest.plist";
static NSString *const FLMViewportCommitPath =
    @"/var/mobile/Library/Preferences/FlymeMultitasking-ViewportCommit.plist";
static NSString *const FLMViewportCommitRootlessPath =
    @"/var/jb/var/mobile/Library/Preferences/FlymeMultitasking-ViewportCommit.plist";

typedef NS_ENUM(NSInteger, FLMViewportHandshakePhase) {
    FLMViewportHandshakePhaseIdle = 0,
    FLMViewportHandshakePhaseRequested = 1,
    FLMViewportHandshakePhaseAdapterReady = 2,
    FLMViewportHandshakePhaseApplying = 3,
    FLMViewportHandshakePhaseCommitted = 4,
};

static inline NSDictionary *FLMReadViewportStateAtPath(
    NSString *primaryPath,
    NSString *rootlessPath) {
    NSDictionary *state =
        [NSDictionary dictionaryWithContentsOfFile:primaryPath];
    if (![state isKindOfClass:[NSDictionary class]]) {
        state = [NSDictionary dictionaryWithContentsOfFile:rootlessPath];
    }
    NSNumber *version = [state[@"version"] isKindOfClass:[NSNumber class]]
                            ? state[@"version"]
                            : nil;
    return version.integerValue >= FLM_VIEWPORT_HANDSHAKE_VERSION
               ? state
               : nil;
}

static inline NSDictionary *FLMReadViewportRequestState(void) {
    return FLMReadViewportStateAtPath(FLMViewportRequestPath,
                                      FLMViewportRequestRootlessPath);
}

static inline NSDictionary *FLMReadViewportCommitState(void) {
    return FLMReadViewportStateAtPath(FLMViewportCommitPath,
                                      FLMViewportCommitRootlessPath);
}

static inline BOOL FLMWriteViewportState(NSDictionary *state,
                                         NSString *primaryPath,
                                         NSString *rootlessPath) {
    if (![state isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization
        dataWithPropertyList:state
                      format:NSPropertyListBinaryFormat_v1_0
                     options:0
                       error:&serializationError];
    if (!data || serializationError) {
        return NO;
    }
    NSError *writeError = nil;
    BOOL wrote = [data writeToFile:primaryPath
                           options:NSDataWritingAtomic
                             error:&writeError];
    if (!wrote) {
        writeError = nil;
        wrote = [data writeToFile:rootlessPath
                          options:NSDataWritingAtomic
                            error:&writeError];
    }
    return wrote;
}

static inline BOOL FLMWriteViewportRequestState(NSDictionary *state) {
    BOOL wrote = FLMWriteViewportState(state,
                                       FLMViewportRequestPath,
                                       FLMViewportRequestRootlessPath);
    if (wrote) {
        notify_post(FLM_VIEWPORT_REQUEST_NOTIFICATION);
    }
    return wrote;
}

static inline BOOL FLMWriteViewportCommitState(NSDictionary *state) {
    BOOL wrote = FLMWriteViewportState(state,
                                       FLMViewportCommitPath,
                                       FLMViewportCommitRootlessPath);
    if (wrote) {
        notify_post(FLM_VIEWPORT_COMMIT_NOTIFICATION);
    }
    return wrote;
}

static inline NSString *FLMViewportHandshakePhaseName(
    FLMViewportHandshakePhase phase) {
    switch (phase) {
        case FLMViewportHandshakePhaseRequested:
            return @"ViewportRequested";
        case FLMViewportHandshakePhaseAdapterReady:
            return @"WaitingForAdapter";
        case FLMViewportHandshakePhaseApplying:
            return @"ApplyingViewport";
        case FLMViewportHandshakePhaseCommitted:
            return @"ViewportCommitted";
        case FLMViewportHandshakePhaseIdle:
        default:
            return @"Idle";
    }
}

#endif
