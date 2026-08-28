#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <notify.h>
#import <objc/message.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <stdarg.h>
#import <stdint.h>
#import <stdio.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <unistd.h>

#import "FLMDiagnostics.h"
#import "FLMSceneLifecycle.h"

#define FLYME_RUNTIME_NOTIFICATION "com.codex.flymemultitasking.runtime"
#define FLYME_PREFERENCES_NOTIFICATION CFSTR("com.codex.flymemultitasking.preferences-changed")
#define FLYME_PREFERENCES_DOMAIN CFSTR("com.codex.flymemultitasking")
#define FLYME_KEYBOARD_NOTIFICATION "com.codex.flymemultitasking.keyboard-state-changed"
#define FLYME_KEYBOARD_SCENE_NOTIFICATION "com.codex.flymemultitasking.keyboard-scene-changed"
#define FLYME_KEYBOARD_SESSION_NOTIFICATION "com.codex.flymemultitasking.keyboard-session-changed"
#define FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION "com.codex.flymemultitasking.keyboard-avoidance-changed"
#define FLYME_KEYBOARD_CARD_GEOMETRY_NOTIFICATION "com.codex.flymemultitasking.keyboard-card-geometry-changed"
#define FLYME_KEYBOARD_SHARED_STATE_NOTIFICATION "com.codex.flymemultitasking.keyboard-shared-state-changed"
#define FLYME_KEYBOARD_APP_CTOR_NOTIFICATION "com.codex.flymemultitasking.keyboard-app-ctor-v50"
#define FLYME_KEYBOARD_APP_READY_NOTIFICATION "com.codex.flymemultitasking.keyboard-app-ready-v50"
#define FLYME_KEYBOARD_DISMISS_REQUEST_NOTIFICATION "com.codex.flymemultitasking.keyboard-dismiss-request-v1"
#define FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION "com.codex.flymemultitasking.keyboard-dismiss-ack-v1"
#define FLYME_KEYBOARD_APP_CTOR_MAGIC 0xF150ULL
#define FLYME_KEYBOARD_APP_READY_MAGIC 0xF250ULL
#define FLYME_KEYBOARD_APP_ADAPTER_BUILD 52ULL
#define FLYME_KEYBOARD_SHARED_STATE_VERSION 5
#define FLYME_RUNTIME_MAGIC 0x464C594DULL
#define FLYME_LOCK_SCREEN_ITEM @"com.codex.flymemultitasking.lockscreen"
// Bump this together with the package version in control / Info.plist so the
// diagnostic log can tell one build from another.
#define FLMLogBuildString @"Stable build 0.9.52"

// Kept only to discard the identifier left by older installs. It is not a
// supported wheel item and must never be rendered or activated.
static NSString *const FLMRemovedLegacyWheelItemIdentifier =
    @"com.codex.flymemultitasking.screensense";

static const char *FLMDiagnosticPrimaryPath =
    "/var/jb/var/mobile/Library/Preferences/FlymeMultitasking-Diagnostic.log";
static const char *FLMDiagnosticFallbackPath =
    "/var/mobile/Library/Preferences/FlymeMultitasking-Diagnostic.log";
static dispatch_queue_t FLMDiagnosticWriterQueue;
static BOOL FLMDiagnosticWriterReady = NO;
static int FLMDiagnosticLegacyReceiverToken = -1;
static int FLMDiagnosticSpringBoardReceiverToken = -1;
static int FLMDiagnosticApplicationReceiverToken = -1;
static int FLMDiagnosticKeyboardReceiverToken = -1;
static int FLMDiagnosticUIKitOtherReceiverToken = -1;
static int FLMDiagnosticInputGeometryStateToken = -1;
static int FLMDiagnosticInputKeyboardStateToken = -1;
static int FLMDiagnosticInputSpacingStateToken = -1;
static int FLMDiagnosticInputInsetsStateToken = -1;
static int FLMDiagnosticInputCommitReceiverToken = -1;
static const off_t FLMDiagnosticMaximumSize = 1024 * 1024;
// Keyboard hit testing is a small tolerance around UIKit's actual visible
// frame.  It is deliberately not an accessory rectangle: when the keyboard
// window returns nil, the floating backdrop must remain the next owner.
static const CGFloat FLMKeyboardHitTestSlop = 6.0;

static const char *FLMDiagnosticRoleName(uint8_t role) {
    switch (role) {
        case FLMDiagnosticRoleSpringBoard: return "springboard";
        case FLMDiagnosticRoleApplication: return "application";
        case FLMDiagnosticRoleKeyboardExtension: return "keyboard-extension";
        case FLMDiagnosticRoleUIKitOther: return "uikit-other";
        default: return "unknown";
    }
}

static const char *FLMDiagnosticEventName(uint8_t event) {
    switch (event) {
        case FLMDiagnosticEventProcessReady: return "process-ready";
        case FLMDiagnosticEventRouteReload: return "route-reload";
        case FLMDiagnosticEventResponderBecome: return "responder-become";
        case FLMDiagnosticEventResponderResign: return "responder-resign";
        case FLMDiagnosticEventFramePublish: return "frame-publish";
        case FLMDiagnosticEventFrameObserved: return "frame-observed";
        case FLMDiagnosticEventFrameCorrected: return "frame-corrected";
        case FLMDiagnosticEventCardGeometry: return "card-geometry";
        case FLMDiagnosticEventAvoidanceReload: return "avoidance-reload";
        case FLMDiagnosticEventIntersection: return "intersection";
        case FLMDiagnosticEventDismissRequest: return "dismiss-request";
        case FLMDiagnosticEventWillHide: return "will-hide";
        case FLMDiagnosticEventDidHide: return "did-hide";
        case FLMDiagnosticEventSceneMatch: return "scene-match";
        case FLMDiagnosticEventLayoutRefresh: return "layout-refresh";
        case FLMDiagnosticEventRouteReady: return "route-ready";
        case FLMDiagnosticEventDismissAck: return "dismiss-ack";
        case FLMDiagnosticEventAdapterLoaded: return "adapter-loaded";
        case FLMDiagnosticEventAdapterCtor: return "adapter-ctor";
        case FLMDiagnosticEventAdapterReady: return "adapter-ready";
        case FLMDiagnosticEventInputGeometry: return "input-geometry";
        case FLMDiagnosticEventInputKeyboardFrame: return "input-keyboard-frame";
        case FLMDiagnosticEventInputSpacing: return "input-spacing";
        case FLMDiagnosticEventInputInsets: return "input-insets";
        case FLMDiagnosticEventInputSampleCommit: return "input-sample-commit";
        case FLMDiagnosticEventTransportRegister: return "transport-register";
        case FLMDiagnosticEventTransportReady: return "transport-ready";
        case FLMDiagnosticEventTransportReceiveDismiss:
            return "transport-recv-dismiss";
        case FLMDiagnosticEventTransportReceiveRoute:
            return "transport-recv-route";
        case FLMDiagnosticEventDismissClaim: return "dismiss-claim";
        case FLMDiagnosticEventResponderActionBegin:
            return "responder-resign-begin";
        case FLMDiagnosticEventResponderActionComplete:
            return "responder-resign-complete";
        default: return "unknown-event";
    }
}

static const char *FLMRemoteTransportChannelName(uint8_t channel) {
    switch (channel) {
        case 0: return "state";
        case 1: return "scene";
        case 2: return "session";
        case 3: return "avoidance";
        case 4: return "card-geometry";
        case 5: return "shared-state";
        case 6: return "dismiss-request";
        default: return "unknown";
    }
}

static void FLMRotateDiagnosticFileIfNeeded(const char *path) {
    if (!path) {
        return;
    }
    struct stat information;
    if (stat(path, &information) != 0 ||
        information.st_size < FLMDiagnosticMaximumSize) {
        return;
    }
    char previousPath[PATH_MAX];
    int length = snprintf(previousPath, sizeof(previousPath), "%s.previous", path);
    if (length <= 0 || (size_t)length >= sizeof(previousPath)) {
        return;
    }
    unlink(previousPath);
    rename(path, previousPath);
}

static int FLMOpenDiagnosticFile(void) {
    FLMRotateDiagnosticFileIfNeeded(FLMDiagnosticPrimaryPath);
    int descriptor = open(FLMDiagnosticPrimaryPath,
                          O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                          0644);
    if (descriptor >= 0) {
        return descriptor;
    }
    FLMRotateDiagnosticFileIfNeeded(FLMDiagnosticFallbackPath);
    return open(FLMDiagnosticFallbackPath,
                O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                0644);
}

static void FLMAppendDiagnosticLineNow(NSString *message) {
    if (message.length == 0) {
        return;
    }
    struct timeval now;
    gettimeofday(&now, NULL);
    NSString *line =
        [NSString stringWithFormat:@"%lld.%03d pid=%d %@\n",
                                   (long long)now.tv_sec,
                                   (int)(now.tv_usec / 1000),
                                   getpid(),
                                   message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) {
        return;
    }
    int descriptor = FLMOpenDiagnosticFile();
    if (descriptor < 0) {
        return;
    }
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    size_t remaining = data.length;
    while (remaining > 0) {
        ssize_t written = write(descriptor, bytes, remaining);
        if (written > 0) {
            bytes += written;
            remaining -= (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        break;
    }
    close(descriptor);
}

void FLMEnqueueDiagnosticLine(NSString *format, ...) {
    if (!FLMDiagnosticWriterReady || !FLMDiagnosticWriterQueue ||
        format.length == 0) {
        return;
    }
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format
                                               arguments:arguments];
    va_end(arguments);
    dispatch_async(FLMDiagnosticWriterQueue, ^{
        @autoreleasepool {
            FLMAppendDiagnosticLineNow(message);
        }
    });
}

static void FLMRecordRemoteDiagnosticEvent(int token) {
    uint64_t state = 0;
    if (token < 0 || notify_get_state(token, &state) != NOTIFY_STATUS_OK) {
        return;
    }
    uint8_t event = (uint8_t)(state >> 56);
    uint8_t role = (uint8_t)((state >> 48) & 0xFFULL);
    uint16_t session = (uint16_t)((state >> 32) & 0xFFFFULL);
    uint16_t first = (uint16_t)((state >> 16) & 0xFFFFULL);
    uint16_t second = (uint16_t)(state & 0xFFFFULL);
    if (event == FLMDiagnosticEventInputGeometry) {
        FLMAppendDiagnosticLineNow(
            [NSString stringWithFormat:
                @"remote role=%s event=input-geometry session=%u inputHeight=%.1f containerHeight=%.1f raw=0x%016llx",
                FLMDiagnosticRoleName(role), session, (CGFloat)first / 10.0,
                (CGFloat)second / 10.0, (unsigned long long)state]);
        return;
    }
    if (event == FLMDiagnosticEventInputKeyboardFrame) {
        FLMAppendDiagnosticLineNow(
            [NSString stringWithFormat:
                @"remote role=%s event=input-keyboard-frame session=%u containerBottom=%.1f keyboardTop=%.1f raw=0x%016llx",
                FLMDiagnosticRoleName(role), session, (CGFloat)first / 10.0,
                (CGFloat)second / 10.0, (unsigned long long)state]);
        return;
    }
    if (event == FLMDiagnosticEventInputSpacing) {
        FLMAppendDiagnosticLineNow(
            [NSString stringWithFormat:
                @"remote role=%s event=input-spacing session=%u gap=%.1f safeBottom=%.1f raw=0x%016llx",
                FLMDiagnosticRoleName(role), session,
                (CGFloat)(int16_t)first / 10.0, (CGFloat)second / 10.0,
                (unsigned long long)state]);
        return;
    }
    if (event == FLMDiagnosticEventInputInsets) {
        FLMAppendDiagnosticLineNow(
            [NSString stringWithFormat:
                @"remote role=%s event=input-insets session=%u contentBottom=%.1f adjustedBottom=%.1f raw=0x%016llx",
                FLMDiagnosticRoleName(role), session, (CGFloat)first / 10.0,
                (CGFloat)second / 10.0, (unsigned long long)state]);
        return;
    }
    if (event == FLMDiagnosticEventTransportRegister) {
        uint8_t channel = (uint8_t)(first >> 8);
        int status = (int)(first & 0xFFU);
        int tokenValue = (int)(int16_t)second;
        FLMAppendDiagnosticLineNow(
            [NSString stringWithFormat:
                @"remote role=%s event=transport-register channel=%s status=%d token=%d session=%u",
                FLMDiagnosticRoleName(role),
                FLMRemoteTransportChannelName(channel), status, tokenValue,
                session]);
        return;
    }
    if (event == FLMDiagnosticEventTransportReady) {
        FLMAppendDiagnosticLineNow(
            [NSString stringWithFormat:
                @"remote role=%s event=transport-ready registered=%u expected=%u session=%u",
                FLMDiagnosticRoleName(role), first, second, session]);
        return;
    }
    if (event == FLMDiagnosticEventTransportReceiveDismiss ||
        event == FLMDiagnosticEventTransportReceiveRoute) {
        FLMAppendDiagnosticLineNow(
            [NSString stringWithFormat:
                @"remote role=%s event=%s session=%u generation=%u pid=%u",
                FLMDiagnosticRoleName(role), FLMDiagnosticEventName(event),
                session, first, second]);
        return;
    }
    if (event == FLMDiagnosticEventDismissRequest) {
        FLMAppendDiagnosticLineNow(
            [NSString stringWithFormat:
                @"remote role=%s event=dismiss-request session=%u generation=%u sceneHash=%u",
                FLMDiagnosticRoleName(role), session, first, second]);
        return;
    }
    if (event == FLMDiagnosticEventDismissAck) {
        FLMAppendDiagnosticLineNow(
            [NSString stringWithFormat:
                @"remote role=%s event=dismiss-ack phase=complete session=%u generation=%u result=%u",
                FLMDiagnosticRoleName(role), session, first, second]);
        return;
    }
    if (event == FLMDiagnosticEventDismissClaim) {
        FLMAppendDiagnosticLineNow(
            [NSString stringWithFormat:
                @"remote role=%s event=dismiss-claim received=1 session=%u generation=%u pid=%u",
                FLMDiagnosticRoleName(role),
                session, first, second]);
        return;
    }
    if (event == FLMDiagnosticEventResponderActionBegin ||
        event == FLMDiagnosticEventResponderActionComplete) {
        const char *phase = event == FLMDiagnosticEventResponderActionBegin
                                ? "begin"
                                : "complete";
        FLMAppendDiagnosticLineNow(
            [NSString stringWithFormat:
                @"remote role=%s event=responder-resign phase=%s session=%u generation=%u pid=%u",
                FLMDiagnosticRoleName(role), phase, session, first, second]);
        return;
    }
    FLMAppendDiagnosticLineNow(
        [NSString stringWithFormat:
            @"remote role=%s event=%s session=%u a=%u b=%u raw=0x%016llx",
            FLMDiagnosticRoleName(role), FLMDiagnosticEventName(event),
            session, first, second, (unsigned long long)state]);
}

static void FLMRegisterDiagnosticReceiver(const char *notificationName,
                                          int *receiverToken) {
    notify_register_dispatch(notificationName,
                             receiverToken,
                             FLMDiagnosticWriterQueue,
                             ^(int deliveredToken) {
        FLMRecordRemoteDiagnosticEvent(deliveredToken);
    });
}

static BOOL FLMReadDiagnosticState(int token, uint64_t *state) {
    return token >= 0 && state &&
           notify_get_state(token, state) == NOTIFY_STATUS_OK;
}

static void FLMRecordCommittedInputDiagnosticSample(int deliveredToken) {
    uint64_t commitBefore = 0;
    uint64_t geometry = 0;
    uint64_t keyboard = 0;
    uint64_t spacing = 0;
    uint64_t insets = 0;
    uint64_t commitAfter = 0;
    if (!FLMReadDiagnosticState(deliveredToken, &commitBefore) ||
        !FLMReadDiagnosticState(FLMDiagnosticInputGeometryStateToken,
                                &geometry) ||
        !FLMReadDiagnosticState(FLMDiagnosticInputKeyboardStateToken,
                                &keyboard) ||
        !FLMReadDiagnosticState(FLMDiagnosticInputSpacingStateToken,
                                &spacing) ||
        !FLMReadDiagnosticState(FLMDiagnosticInputInsetsStateToken, &insets) ||
        !FLMReadDiagnosticState(deliveredToken, &commitAfter) ||
        commitBefore != commitAfter) {
        return;
    }

    uint8_t commitEvent = (uint8_t)(commitBefore >> 56);
    uint8_t role = (uint8_t)((commitBefore >> 48) & 0xFFULL);
    uint16_t sequence = (uint16_t)((commitBefore >> 32) & 0xFFFFULL);
    uint16_t routeSession = (uint16_t)((commitBefore >> 16) & 0xFFFFULL);
    uint16_t monotonicTick = (uint16_t)(commitBefore & 0xFFFFULL);
    uint64_t fields[] = {geometry, keyboard, spacing, insets};
    uint8_t expectedEvents[] = {
        FLMDiagnosticEventInputGeometry,
        FLMDiagnosticEventInputKeyboardFrame,
        FLMDiagnosticEventInputSpacing,
        FLMDiagnosticEventInputInsets,
    };
    if (commitEvent != FLMDiagnosticEventInputSampleCommit ||
        role != FLMDiagnosticRoleApplication || sequence == 0) {
        return;
    }
    for (NSUInteger index = 0; index < 4; index++) {
        uint8_t fieldEvent = (uint8_t)(fields[index] >> 56);
        uint8_t fieldRole = (uint8_t)((fields[index] >> 48) & 0xFFULL);
        uint16_t fieldSequence =
            (uint16_t)((fields[index] >> 32) & 0xFFFFULL);
        if (fieldEvent != expectedEvents[index] ||
            fieldRole != FLMDiagnosticRoleApplication ||
            fieldSequence != sequence) {
            return;
        }
    }

    uint16_t inputHeight = (uint16_t)((geometry >> 16) & 0xFFFFULL);
    uint16_t containerHeight = (uint16_t)(geometry & 0xFFFFULL);
    uint16_t containerBottom = (uint16_t)((keyboard >> 16) & 0xFFFFULL);
    uint16_t keyboardTop = (uint16_t)(keyboard & 0xFFFFULL);
    int16_t gap = (int16_t)((spacing >> 16) & 0xFFFFULL);
    uint16_t safeBottom = (uint16_t)(spacing & 0xFFFFULL);
    uint16_t contentBottom = (uint16_t)((insets >> 16) & 0xFFFFULL);
    uint16_t adjustedBottom = (uint16_t)(insets & 0xFFFFULL);
    FLMAppendDiagnosticLineNow(
        [NSString stringWithFormat:
            @"remote role=application event=input-sample seq=%u session=%u tickMsMod65536=%u space=fixed-screen inputHeight=%.1f containerHeight=%.1f containerBottom=%.1f keyboardVisualTop=%.1f visualGap=%.1f safeBottom=%.1f contentInsetBottom=%.1f adjustedInsetBottom=%.1f",
            sequence,
            routeSession,
            monotonicTick,
            (CGFloat)inputHeight / 10.0,
            (CGFloat)containerHeight / 10.0,
            (CGFloat)containerBottom / 10.0,
            (CGFloat)keyboardTop / 10.0,
            (CGFloat)gap / 10.0,
            (CGFloat)safeBottom / 10.0,
            (CGFloat)contentBottom / 10.0,
            (CGFloat)adjustedBottom / 10.0]);
}

static void FLMRegisterCommittedInputDiagnosticReceiver(void) {
    if (notify_register_check(FLYME_DIAGNOSTIC_INPUT_GEOMETRY_STATE,
                              &FLMDiagnosticInputGeometryStateToken) !=
        NOTIFY_STATUS_OK ||
        notify_register_check(FLYME_DIAGNOSTIC_INPUT_KEYBOARD_STATE,
                              &FLMDiagnosticInputKeyboardStateToken) !=
            NOTIFY_STATUS_OK ||
        notify_register_check(FLYME_DIAGNOSTIC_INPUT_SPACING_STATE,
                              &FLMDiagnosticInputSpacingStateToken) !=
            NOTIFY_STATUS_OK ||
        notify_register_check(FLYME_DIAGNOSTIC_INPUT_INSETS_STATE,
                              &FLMDiagnosticInputInsetsStateToken) !=
            NOTIFY_STATUS_OK) {
        return;
    }
    notify_register_dispatch(
        FLYME_DIAGNOSTIC_INPUT_COMMIT_NOTIFICATION,
        &FLMDiagnosticInputCommitReceiverToken,
        FLMDiagnosticWriterQueue,
        ^(int deliveredToken) {
            FLMRecordCommittedInputDiagnosticSample(deliveredToken);
        });
}

static void FLMStartDiagnosticWriter(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FLMDiagnosticWriterQueue =
            dispatch_queue_create("com.codex.flymemultitasking.diagnostic-writer",
                                  DISPATCH_QUEUE_SERIAL);
        FLMRegisterDiagnosticReceiver(FLYME_DIAGNOSTIC_EVENT_NOTIFICATION,
                                      &FLMDiagnosticLegacyReceiverToken);
        FLMRegisterDiagnosticReceiver(FLYME_DIAGNOSTIC_SPRINGBOARD_NOTIFICATION,
                                      &FLMDiagnosticSpringBoardReceiverToken);
        FLMRegisterDiagnosticReceiver(FLYME_DIAGNOSTIC_APPLICATION_NOTIFICATION,
                                      &FLMDiagnosticApplicationReceiverToken);
        FLMRegisterDiagnosticReceiver(FLYME_DIAGNOSTIC_KEYBOARD_NOTIFICATION,
                                      &FLMDiagnosticKeyboardReceiverToken);
        FLMRegisterDiagnosticReceiver(FLYME_DIAGNOSTIC_UIKIT_OTHER_NOTIFICATION,
                                      &FLMDiagnosticUIKitOtherReceiverToken);
        FLMRegisterCommittedInputDiagnosticReceiver();
        FLMDiagnosticWriterReady = YES;
        dispatch_async(FLMDiagnosticWriterQueue, ^{
            @autoreleasepool {
                FLMAppendDiagnosticLineNow(
                    [NSString stringWithFormat:@"logger-ready build=%@ schema=27",
                                               FLMLogBuildString]);
            }
        });
    });
}

static const CGFloat FLMDefaultWheelRadius = 202.0;
static const CGFloat FLMMinimumWheelRadius = 170.0;
static const CGFloat FLMMaximumWheelRadius = 225.0;
static const CGFloat FLMDefaultWheelIconSize = 56.0;
static const CGFloat FLMMinimumWheelIconSize = 44.0;
static const CGFloat FLMMaximumWheelIconSize = 68.0;
static const CGFloat FLMDefaultCornerTriggerSize = 58.0;
static const CGFloat FLMMinimumCornerTriggerSize = 36.0;
static const CGFloat FLMMaximumCornerTriggerSize = 96.0;
static CGFloat FLMCornerTriggerSize = FLMDefaultCornerTriggerSize;
static const CGFloat FLMDefaultDockWidth = 156.0;
static const CGFloat FLMMinimumDockWidth = 156.0;
static const CGFloat FLMMaximumDockWidth = 270.0;
static const CGFloat FLMDockSideMargin = 10.0;
static const CGFloat FLMDockTopMargin = 8.0;
// The centered card is a physical presentation surface for a full-screen
// application. The app Scene and keyboard always remain 390x844. The card
// width selects one uniform presentation scale; top/bottom crop values then
// select which part of that full-screen surface remains visible.
static const CGFloat FLMCenteredCardWidth = 315.0;
static const CGFloat FLMCenteredCardTopCrop = 37.0;
static const CGFloat FLMCenteredCardBottomCrop = 19.0;
static const CGFloat FLMMinimumCenteredCardWidth = 240.0;
static const CGFloat FLMMaximumCenteredCardWidth = 360.0;
static const CGFloat FLMMinimumCenteredCardCrop = 0.0;
static const CGFloat FLMMaximumCenteredCardCrop = 260.0;
// The Scene remains display-sized at 390x844. The physical card height is
// computed as width * 844 / 390 - topCrop - bottomCrop.
static const CGFloat FLMVirtualViewportWidth = 390.0;
static const CGFloat FLMVirtualViewportHeight = 844.0;
static const CGFloat FLMCenteredDockActivationDistance = 110.0;
static const CGFloat FLMDefaultCenteredDockSwipeThreshold = 20.0;
static const CGFloat FLMMinimumCenteredDockSwipeThreshold = 8.0;
static const CGFloat FLMMaximumCenteredDockSwipeThreshold = 120.0;
static const CGFloat FLMDefaultDockedShrinkAmount = 0.0;
static const CGFloat FLMMinimumDockedShrinkAmount = 0.0;
static const CGFloat FLMMaximumDockedShrinkAmount = 60.0;
static const CGFloat FLMMinimumDockPresentationWidth = 96.0;
static const CGFloat FLMDockAnimationSpeed = 0.85;
static const NSTimeInterval FLMFloatingLaunchTimeout = 6.5;
static const NSTimeInterval FLMFloatingSceneSettleDelay = 0.10;
static const NSTimeInterval FLMFloatingScenePollInterval = 0.05;
static const NSTimeInterval FLMFloatingSceneResolveGraceDelay = 0.03;
static const NSTimeInterval FLMFloatingLaunchCoverSettleDelay = 0.02;
static const NSTimeInterval FLMFloatingLaunchCoverFadeDuration = 0.05;
static const NSTimeInterval FLMFloatingFullscreenActivationDelay = 0.02;
static const NSTimeInterval FLMFloatingFullscreenHandoffPollInterval = 0.03;
static const CGFloat FLMFloatingFullscreenActivationThreshold = 0.85;
static const NSTimeInterval FLMFloatingSceneGenerationDelay = 0.75;
static const NSTimeInterval FLMFloatingPresenterRecoveryTimeout = 1.0;
static const NSTimeInterval FLMFloatingCloseFallbackDelay = 0.45;
// The close intent has a bounded app-claim phase followed by a separate
// keyboard-settlement phase. Hidden settlement can commit earlier only after
// the app claim has been observed.
static const NSTimeInterval FLMFloatingKeyboardAppClaimTimeout = 0.70;
static const NSTimeInterval FLMFloatingKeyboardSettlementTimeout = 1.50;

typedef struct {
    CGRect centeredFrame;
    CGRect centeredBounds;
    CGPoint centeredPosition;
    CGFloat centeredContentScale;
    CGFloat dockPresentationScale;
    CGFloat screenScale;
} FLMSessionCanonicalGeometry;

static CGFloat FLMPixelAlignedValue(CGFloat value, CGFloat screenScale) {
    if (!isfinite(value) || !isfinite(screenScale) || screenScale <= 0.0) {
        return value;
    }
    return round(value * screenScale) / screenScale;
}

static CGRect FLMPixelAlignedRect(CGRect rect, CGFloat screenScale) {
    return CGRectMake(FLMPixelAlignedValue(CGRectGetMinX(rect), screenScale),
                      FLMPixelAlignedValue(CGRectGetMinY(rect), screenScale),
                      MAX(0.0, FLMPixelAlignedValue(CGRectGetWidth(rect),
                                                    screenScale)),
                      MAX(0.0, FLMPixelAlignedValue(CGRectGetHeight(rect),
                                                    screenScale)));
}

typedef NS_ENUM(uint8_t, FLMKeyboardDismissResult) {
    FLMKeyboardDismissResultNone = 0,
    FLMKeyboardDismissResultSuccess = 1,
    FLMKeyboardDismissResultNoResponder = 2,
    FLMKeyboardDismissResultFailed = 3,
    FLMKeyboardDismissResultSceneFallbackSuccess = 4,
    FLMKeyboardDismissResultStaleGeneration = 5,
    FLMKeyboardDismissResultWrongProcess = 6,
};

typedef NS_ENUM(NSUInteger, FLMFloatingKeyboardCloseState) {
    FLMFloatingKeyboardCloseStateIdle = 0,
    FLMFloatingKeyboardCloseStateAwaitingAppClaim,
    FLMFloatingKeyboardCloseStateAwaitingKeyboardSettlement,
    FLMFloatingKeyboardCloseStateCommit,
    FLMFloatingKeyboardCloseStateAborted,
};

typedef NS_ENUM(uint8_t, FLMKeyboardDismissAckPhase) {
    FLMKeyboardDismissAckPhaseNone = 0,
    FLMKeyboardDismissAckPhaseClaimed = 1,
    FLMKeyboardDismissAckPhaseActionComplete = 2,
};

static NSString *FLMFloatingKeyboardCloseStateName(
    FLMFloatingKeyboardCloseState state) {
    switch (state) {
        case FLMFloatingKeyboardCloseStateAwaitingAppClaim:
            return @"AwaitingAppClaim";
        case FLMFloatingKeyboardCloseStateAwaitingKeyboardSettlement:
            return @"AwaitingKeyboardSettlement";
        case FLMFloatingKeyboardCloseStateCommit:
            return @"Commit";
        case FLMFloatingKeyboardCloseStateAborted:
            return @"Aborted";
        default:
            return @"Idle";
    }
}

// A close request is an immutable transaction snapshot. Every request, ACK,
// timeout, hidden-frame settlement and final commit must compare against this
// same object instead of sampling the mutable current route again.
@interface FLMKeyboardCloseContext : NSObject
@property(nonatomic, readonly, copy) NSString *identifier;
@property(nonatomic, readonly, strong) id scene;
@property(nonatomic, readonly) uint64_t bundleHash;
@property(nonatomic, readonly) uint64_t sceneHash;
@property(nonatomic, readonly) uint64_t session;
@property(nonatomic, readonly) uint64_t sessionGeneration;
@property(nonatomic, readonly) uint64_t requestGeneration;
@property(nonatomic, readonly) pid_t adapterPID;
@property(nonatomic, readonly) NSUInteger closeToken;
- (instancetype)initWithIdentifier:(NSString *)identifier
                              scene:(id)scene
                         bundleHash:(uint64_t)bundleHash
                          sceneHash:(uint64_t)sceneHash
                            session:(uint64_t)session
                  sessionGeneration:(uint64_t)sessionGeneration
                  requestGeneration:(uint64_t)requestGeneration
                         adapterPID:(pid_t)adapterPID
                         closeToken:(NSUInteger)closeToken;
@end

@implementation FLMKeyboardCloseContext

- (instancetype)initWithIdentifier:(NSString *)identifier
                              scene:(id)scene
                         bundleHash:(uint64_t)bundleHash
                          sceneHash:(uint64_t)sceneHash
                            session:(uint64_t)session
                  sessionGeneration:(uint64_t)sessionGeneration
                  requestGeneration:(uint64_t)requestGeneration
                         adapterPID:(pid_t)adapterPID
                         closeToken:(NSUInteger)closeToken {
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _scene = scene;
        _bundleHash = bundleHash;
        _sceneHash = sceneHash;
        _session = session;
        _sessionGeneration = sessionGeneration;
        _requestGeneration = requestGeneration;
        _adapterPID = adapterPID;
        _closeToken = closeToken;
    }
    return self;
}

@end

typedef NS_ENUM(NSUInteger, FLMFloatingDockPresentationMode) {
    FLMFloatingDockPresentationModeCentered = 0,
    FLMFloatingDockPresentationModeDocked,
    FLMFloatingDockPresentationModeHiddenDock,
};
// A dock touch must choose one owner at its beginning.  The previous
// implementation inferred the owner again on every Changed callback, so an
// ordinary card drag could turn into a hide gesture (or a resize) halfway
// through the same touch.
typedef NS_ENUM(NSUInteger, FLMFloatingDockInputMode) {
    FLMFloatingDockInputModeNone = 0,
    FLMFloatingDockInputModeCardDrag,
    FLMFloatingDockInputModeResize,
    FLMFloatingDockInputModeHiddenReveal,
};

typedef NS_ENUM(NSUInteger, FLMFloatingDockRendererMode) {
    FLMFloatingDockRendererModeDisplayLink = 0,
    FLMFloatingDockRendererModeDirectPan,
};

static NSString *FLMFloatingDockRendererModeName(
    FLMFloatingDockRendererMode mode) {
    return mode == FLMFloatingDockRendererModeDirectPan
               ? @"direct-pan"
               : @"display-link";
}

static NSString *FLMFloatingDockInputModeName(FLMFloatingDockInputMode mode) {
    switch (mode) {
        case FLMFloatingDockInputModeCardDrag:
            return @"card-drag";
        case FLMFloatingDockInputModeResize:
            return @"resize";
        case FLMFloatingDockInputModeHiddenReveal:
            return @"hidden-reveal";
        default:
            return @"none";
    }
}

typedef NS_ENUM(NSUInteger, FLMFloatingDockControlTransition) {
    FLMFloatingDockControlTransitionNone = 0,
    FLMFloatingDockControlTransitionEntry,
    FLMFloatingDockControlTransitionSnap,
    FLMFloatingDockControlTransitionResize,
    FLMFloatingDockControlTransitionRestore,
    FLMFloatingDockControlTransitionHide,
    FLMFloatingDockControlTransitionReveal,
};

static NSString *FLMFloatingDockControlTransitionName(
    FLMFloatingDockControlTransition transition) {
    switch (transition) {
        case FLMFloatingDockControlTransitionEntry:
            return @"entry";
        case FLMFloatingDockControlTransitionSnap:
            return @"snap";
        case FLMFloatingDockControlTransitionResize:
            return @"resize";
        case FLMFloatingDockControlTransitionRestore:
            return @"restore";
        case FLMFloatingDockControlTransitionHide:
            return @"hide";
        case FLMFloatingDockControlTransitionReveal:
            return @"reveal";
        default:
            return @"none";
    }
}

static const CGFloat FLMFloatingDockHideIntentDistance = 18.0;
static const CGFloat FLMFloatingDockHideIntentHorizontalRatio = 1.35;
typedef NS_ENUM(NSUInteger, FLMFloatingLaunchState) {
    FLMFloatingLaunchStateIdle,
    FLMFloatingLaunchStatePrewarming,
    FLMFloatingLaunchStateWaitingForScene,
    FLMFloatingLaunchStateWaitingForPresenter,
    FLMFloatingLaunchStateAttached,
    FLMFloatingLaunchStateFailing,
    FLMFloatingLaunchStateClosing,
};

@interface NSObject (FLMRuntimePrivate)
+ (id)defaultWorkspace;
+ (id)sharedInstance;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleIdentifier;
- (void)lockUIFromSource:(NSInteger)source withOptions:(id)options;
- (id)frontmostApplication;
- (id)_accessibilityFrontMostApplication;
- (NSString *)bundleIdentifier;
- (NSString *)displayIdentifier;
@end

@interface FLMDisplayConfiguration : NSObject
- (id)identity;
@end

@interface UIScreen (FLMRuntimePrivate)
- (FLMDisplayConfiguration *)displayConfiguration;
@end

@interface FLMSystemGestureManager : NSObject
+ (instancetype)sharedInstance;
- (void)addGestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       toDisplayWithIdentity:(id)displayIdentity;
@end

@interface UIApplication (FLMRuntimePrivate)
- (BOOL)launchApplicationWithIdentifier:(NSString *)identifier suspended:(BOOL)suspended;
- (void)_simulateLockButtonPress;
@end

@interface UIImage (FLMRuntimePrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier
                                               format:(NSInteger)format
                                                scale:(CGFloat)scale;
@end

@interface FLMSBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (id)applicationWithBundleIdentifier:(NSString *)bundleIdentifier;
@end

@interface FLMSBApplication : NSObject
@end

@interface FLMApplicationSceneHandle : NSObject
- (id)sceneIfExists;
- (id)scene;
@end

@interface FLMDeviceApplicationSceneEntity : NSObject
- (instancetype)initWithApplicationForMainDisplay:(id)application
             generatingNewPrimarySceneIfRequired:(BOOL)required;
- (FLMApplicationSceneHandle *)sceneHandle;
@end

@interface NSObject (FLMSceneHostingPrivate)
- (id)settings;
- (id)mutableSettings;
- (NSString *)identifier;
- (NSString *)sceneIdentifier;
- (id)uiPresentationManager;
- (id)presentationManager;
- (id)createPresenterWithIdentifier:(NSString *)identifier;
- (UIView *)presentationView;
- (void)activate;
- (void)deactivate;
- (void)invalidate;
- (void)setForeground:(BOOL)foreground;
- (void)setBackgrounded:(BOOL)backgrounded;
- (void)setDeactivationReasons:(unsigned long long)reasons;
- (void)setFrame:(CGRect)frame;
- (void)setInterfaceOrientation:(NSInteger)orientation;
- (void)updateSettings:(id)settings withTransitionContext:(id)context;
- (void)updateClientSettingsWithBlock:(void (^)(id mutableSettings))block;
- (void)_setContentState:(NSInteger)state;
@end

static BOOL FLMDeviceIsLocked(void) {
    id manager = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
    if (!manager) {
        return NO;
    }
    NSArray<NSString *> *selectorNames =
        @[@"isUILocked", @"isLockScreenVisible", @"isLockScreenActive", @"isLocked"];
    for (NSString *selectorName in selectorNames) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![manager respondsToSelector:selector]) {
            continue;
        }
        BOOL (*getter)(id, SEL) =
            (BOOL (*)(id, SEL))[manager methodForSelector:selector];
        if (getter && getter(manager, selector)) {
            return YES;
        }
    }
    return NO;
}

static CGRect FLMVisualScreenBounds(void) {
    return [UIScreen mainScreen].bounds;
}

static CGPoint FLMVisualPointFromRawPoint(CGPoint rawPoint) {
    // Portrait-only build: the global gesture coordinate space is already the
    // same space used by the SpringBoard windows and the centered card.
    return rawPoint;
}

// The portrait build has no wheel entry path outside the portrait display
// coordinate space.  Keep this check at the shared boundary instead of
// relying on a one-time window-frame update: UIKit's system gesture manager
// can deliver a touch after the display has rotated, before any layout pass.
static BOOL FLMPortraitWheelDisplayIsValid(void) {
    CGRect bounds = FLMVisualScreenBounds();
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    return width > 0.0 && height > 0.0 && width <= height;
}

static NSString *FLMIdentifierForApplication(id application) {
    if ([application respondsToSelector:@selector(bundleIdentifier)]) {
        NSString *identifier = [application bundleIdentifier];
        if (identifier.length > 0) {
            return identifier;
        }
    }
    if ([application respondsToSelector:@selector(displayIdentifier)]) {
        NSString *identifier = [application displayIdentifier];
        if (identifier.length > 0) {
            return identifier;
        }
    }
    return nil;
}

static NSString *FLMFrontmostApplicationIdentifier(void) {
    id workspaceClass = NSClassFromString(@"SBMainWorkspace");
    id workspace =
        [workspaceClass respondsToSelector:@selector(sharedInstance)]
            ? [workspaceClass sharedInstance]
            : nil;
    if ([workspace respondsToSelector:@selector(frontmostApplication)]) {
        NSString *identifier =
            FLMIdentifierForApplication([workspace frontmostApplication]);
        if (identifier.length > 0) {
            return identifier;
        }
    }
    UIApplication *springBoard = [UIApplication sharedApplication];
    if ([springBoard respondsToSelector:
                         @selector(_accessibilityFrontMostApplication)]) {
        return FLMIdentifierForApplication(
            [springBoard _accessibilityFrontMostApplication]);
    }
    return nil;
}

static BOOL FLMPrewarmApplicationIdentifier(NSString *identifier) {
    if (identifier.length == 0 ||
        [identifier isEqualToString:FLYME_LOCK_SCREEN_ITEM]) {
        return NO;
    }
    UIApplication *application = [UIApplication sharedApplication];
    if (![application respondsToSelector:
                         @selector(launchApplicationWithIdentifier:suspended:)]) {
        return NO;
    }
    return [application launchApplicationWithIdentifier:identifier
                                               suspended:YES];
}

static CGFloat FLMClampedCornerTriggerSize(CGFloat value) {
    if (!isfinite(value)) {
        return FLMDefaultCornerTriggerSize;
    }
    return MAX(FLMMinimumCornerTriggerSize,
               MIN(FLMMaximumCornerTriggerSize, value));
}

static CGRect FLMDockTransitionEnvelope(CGRect source,
                                        CGRect target,
                                        CGRect bounds) {
    if (CGRectIsNull(source) || CGRectIsEmpty(source)) {
        source = target;
    }
    if (CGRectIsNull(target) || CGRectIsEmpty(target)) {
        target = source;
    }
    if (CGRectIsNull(source) || CGRectIsEmpty(source)) {
        return CGRectNull;
    }
    // UIKit springs can temporarily move outside both model frames.  Keep a
    // small overshoot margin so the physical gate owns the complete visual
    // path instead of exposing a one-frame strip around the animation.
    CGRect envelope = CGRectInset(CGRectUnion(source, target), -32.0, -32.0);
    CGRect clipped = CGRectIntersection(bounds, envelope);
    return CGRectIsNull(clipped) || CGRectIsEmpty(clipped) ? CGRectNull : clipped;
}

static BOOL FLMPointInsideCornerTrigger(CGPoint point,
                                        CGRect bounds,
                                        BOOL *fromRight) {
    // Keep the original 58x65 quarter-ellipse at the default. The setting
    // scales both axes together while preserving that exact aspect ratio.
    CGFloat horizontalRadius =
        FLMClampedCornerTriggerSize(FLMCornerTriggerSize);
    CGFloat verticalRadius = horizontalRadius * (65.0 / 58.0);
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    CGFloat bottomDistance = height - point.y;
    if (point.x < 0.0 || point.x > width ||
        bottomDistance < 0.0 || bottomDistance > verticalRadius) {
        return NO;
    }

    CGFloat verticalComponent = bottomDistance / verticalRadius;
    CGFloat leftComponent = point.x / horizontalRadius;
    CGFloat rightComponent = (width - point.x) / horizontalRadius;
    BOOL insideLeft =
        leftComponent * leftComponent +
            verticalComponent * verticalComponent <=
        1.0;
    BOOL insideRight =
        rightComponent * rightComponent +
            verticalComponent * verticalComponent <=
        1.0;
    if (fromRight) {
        *fromRight = insideRight && !insideLeft;
    }
    return insideLeft || insideRight;
}

@interface FLMOverlayViewController : UIViewController
@end

@implementation FLMOverlayViewController

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (BOOL)shouldAutorotate {
    return NO;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskPortrait;
}

@end

@interface FLMOverlayWindow : UIWindow
@end

@implementation FLMOverlayWindow

- (BOOL)canBecomeKeyWindow {
    return NO;
}

@end

// A system-manager recognizer can observe a touch without becoming the owner
// of the remote Scene's touch stream.  This transparent, display-level window
// is the ownership boundary for docked/hidden card touches.  It only
// hit-tests the card or hidden handle; all other points still pass through.
@interface FLMDockTouchGateWindow : FLMOverlayWindow
@property(nonatomic, assign) BOOL dockTouchGateEnabled;
@property(nonatomic, assign) BOOL wheelPriorityActive;
@property(nonatomic, assign) CGRect dockCardFrame;
@property(nonatomic, assign) CGRect dockHandleFrame;
@property(nonatomic, assign) CGRect dockResizeFrame;
@end

@implementation FLMDockTouchGateWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.dockTouchGateEnabled || FLMDeviceIsLocked()) {
        return nil;
    }
    if (self.wheelPriorityActive && FLMPortraitWheelDisplayIsValid() &&
        FLMPointInsideCornerTrigger(point, self.bounds, NULL)) {
        UITouch *touch = [event.allTouches anyObject];
        if (touch && touch.phase == UITouchPhaseBegan) {
            FLMEnqueueDiagnosticLine(
                @"sb dock-input-gate owner=wheel point={%.1f,%.1f} touch=%p",
                point.x, point.y, (__bridge void *)touch);
        }
        return nil;
    }
    BOOL insideCard = !CGRectIsNull(self.dockCardFrame) &&
                      !CGRectIsEmpty(self.dockCardFrame) &&
                      CGRectContainsPoint(CGRectInset(self.dockCardFrame, -3.0, -3.0),
                                          point);
    BOOL insideHandle = !CGRectIsNull(self.dockHandleFrame) &&
                        !CGRectIsEmpty(self.dockHandleFrame) &&
                        CGRectContainsPoint(CGRectInset(self.dockHandleFrame,
                                                        -18.0,
                                                        -18.0),
                                            point);
    BOOL insideResize = !CGRectIsNull(self.dockResizeFrame) &&
                        !CGRectIsEmpty(self.dockResizeFrame) &&
                        CGRectContainsPoint(CGRectInset(self.dockResizeFrame,
                                                        -10.0,
                                                        -10.0),
                                            point);
    if (!insideCard && !insideHandle && !insideResize) {
        return nil;
    }
    UIView *rootView = self.rootViewController.view;
    UITouch *touch = [event.allTouches anyObject];
    if (touch && touch.phase == UITouchPhaseBegan) {
        FLMEnqueueDiagnosticLine(
            @"sb dock-input-gate owner=dock card=%d handle=%d resize=%d point={%.1f,%.1f} touch=%p",
            insideCard, insideHandle, insideResize, point.x, point.y,
            (__bridge void *)touch);
    }
    return rootView;
}

@end

// The remote keyboard host must live in a full-display window that belongs to
// SpringBoard's active UIWindowScene. The remote host needs a key event window
// for third-party keyboard-extension buttons to complete their UIKit actions.
// Empty root space still returns nil so card and backdrop touches fall through.
@interface FLMKeyboardForwardingWindow : UIWindow
@property(nonatomic, assign) CGRect keyboardInteractionFrame;
@end

@implementation FLMKeyboardForwardingWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (CGRectIsNull(self.keyboardInteractionFrame) ||
        !CGRectContainsPoint(self.keyboardInteractionFrame, point)) {
        return nil;
    }
    UIView *hitView = [super hitTest:point withEvent:event];
    UIView *rootView = self.rootViewController.view;
    if (hitView == self || hitView == rootView) {
        return nil;
    }
    return hitView;
}

@end

@interface FLMFloatingWindow : FLMOverlayWindow
@property(nonatomic, assign) BOOL passesTouchesOutsideFloatingContent;
@property(nonatomic, assign) BOOL suppressesCornerRoutingDuringDockGesture;
@property(nonatomic, assign) CGRect keyboardPassThroughFrame;
@property(nonatomic, weak) UIView *floatingContentView;
@property(nonatomic, weak) UIView *floatingPrimaryControlView;
@property(nonatomic, weak) UIView *floatingSecondaryControlView;
@end

static void FLMLogFloatingHitTest(FLMFloatingWindow *window,
                                  CGPoint point,
                                  UIEvent *event,
                                  UIView *hitView,
                                  NSString *route) {
    UITouch *touch = [event.allTouches anyObject];
    FLMEnqueueDiagnosticLine(
        @"sb touch-hit touch=%p timestamp=%.6f phase=%ld route=%@ point={%.1f,%.1f} hit=%@ hitPtr=%p key=%d keyboardPass=%@ card=%@ handle=%@",
        (__bridge void *)touch, touch ? touch.timestamp : 0.0,
        (long)(touch ? touch.phase : UITouchPhaseCancelled),
        route ?: @"<none>", point.x, point.y,
        hitView ? NSStringFromClass([hitView class]) : @"<nil>",
        (__bridge void *)hitView, window.isKeyWindow,
        NSStringFromCGRect(window.keyboardPassThroughFrame),
        NSStringFromCGRect(window.floatingContentView.frame),
        NSStringFromCGRect(window.floatingPrimaryControlView.frame));
}

@implementation FLMFloatingWindow

- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // A remote scene can retain an oversized hit-test view for one layout
    // transaction after it is reattached.  Always give the centered handle
    // first refusal: it owns the only gestures that leave centered mode.
    UIView *primaryControl = self.floatingPrimaryControlView;
    if (primaryControl && !primaryControl.hidden &&
        primaryControl.userInteractionEnabled && primaryControl.alpha > 0.01) {
        CGPoint primaryPoint = [self convertPoint:point toView:primaryControl];
        UIView *primaryHit = [primaryControl hitTest:primaryPoint withEvent:event];
        if (primaryHit) {
            FLMLogFloatingHitTest(self, point, event, primaryHit, @"handle");
            return primaryHit;
        }
    }
    if (self.suppressesCornerRoutingDuringDockGesture) {
        // A dock drag owns the touch stream until its settle animation ends.
        // Without this short-lived guard, crossing a bottom corner changes the
        // window route from the dock gesture to the wheel hotspot for one
        // compositor transaction, which presents as a one-frame flash.
        UIView *hitView = [super hitTest:point withEvent:event];
        return hitView ?: self.rootViewController.view;
    }
    // Do not route by a rectangle-only keyboard pass. The actual forwarding
    // window is above this window and gets first refusal through its own
    // hitTest:. If that hit-test returns nil, UIKit must continue here so the
    // backdrop owns the point even while the keyboard is visible.
    if (self.passesTouchesOutsideFloatingContent) {
        BOOL insideContent =
            self.floatingContentView &&
            CGRectContainsPoint(CGRectInset(self.floatingContentView.frame, -2.0, -2.0),
                                point);
        BOOL insidePrimaryControl =
            self.floatingPrimaryControlView &&
            !self.floatingPrimaryControlView.hidden &&
            CGRectContainsPoint(CGRectInset(self.floatingPrimaryControlView.frame,
                                            -6.0,
                                            -6.0),
                                point);
        BOOL insideSecondaryControl =
            self.floatingSecondaryControlView &&
            !self.floatingSecondaryControlView.hidden &&
            CGRectContainsPoint(CGRectInset(self.floatingSecondaryControlView.frame,
                                            -12.0,
                                            -12.0),
                                point);
        if (!insideContent && !insidePrimaryControl && !insideSecondaryControl) {
            // The wheel owns the corner trigger even while the card is docked
            // or hidden: keep the touch inside the window so the in-window
            // corner recognizers can summon the wheel instead of letting the
            // touch pass through to the app below.
            if (FLMPortraitWheelDisplayIsValid() &&
                FLMPointInsideCornerTrigger(point, self.bounds, NULL)) {
                FLMLogFloatingHitTest(self, point, event, nil, @"wheel-corner");
                UIView *hitView = [super hitTest:point withEvent:event];
                return hitView ?: self.rootViewController.view;
            }
            FLMLogFloatingHitTest(self, point, event, nil, @"docked-pass");
            return nil;
        }
    }
    UIView *hitView = [super hitTest:point withEvent:event];
    BOOL insideCard = self.floatingContentView &&
                      CGRectContainsPoint(self.floatingContentView.frame, point);
    FLMLogFloatingHitTest(self, point, event, hitView,
                          insideCard ? @"card" : @"backdrop");
    return hitView;
}

@end

@interface FLMHotspotWindow : UIWindow
@property(nonatomic, assign) BOOL hotspotsEnabled;
@end

@implementation FLMHotspotWindow

- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // Lock-screen exclusion is decided by the gesture delegate. Do not call
    // the private lock-state aggregate from this top-level window: on some
    // SpringBoard generations one of its compatibility selectors reports an
    // active lock-screen service even while the device is unlocked, which
    // would make the entire wheel entry disappear before UIKit arbitration.
    if (!self.hotspotsEnabled) {
        return nil;
    }
    if (!FLMPortraitWheelDisplayIsValid()) {
        return nil;
    }
    if (!FLMPointInsideCornerTrigger(point, self.bounds, NULL)) {
        return nil;
    }
    return [super hitTest:point withEvent:event];
}

@end

@class FLMWheelController;

static BOOL FLMHomeDockZoneHitTest(CGRect bounds, CGPoint point);

// Full-screen transparent window that owns the bottom-center home-indicator
// zone while a plain application is frontmost. Its recognizer runs UIKit's
// normal in-window arbitration, so once the long-press begins, the system
// gesture manager gate fails the real home gesture and the app switcher never
// opens. Every gate (card visible, wheel pinned, locked, home screen) is
// re-evaluated per touch in the hit-test, so the window never swallows input
// it should not own.
@interface FLMHomeDockWindow : UIWindow
@end

@implementation FLMHomeDockWindow

- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!FLMHomeDockZoneHitTest(self.bounds, point)) {
        return nil;
    }
    return [super hitTest:point withEvent:event];
}

@end

@interface FLMCornerGestureRecognizer : UILongPressGestureRecognizer
@property(nonatomic, assign) NSTimeInterval flmFirstTouchTimestamp;
@property(nonatomic, assign) BOOL flmOutsideCloseAuthorized;
@property(nonatomic, assign) CGPoint flmAuthorizedStartPoint;
@property(nonatomic, assign) NSUInteger flmActiveTouchCount;
@property(nonatomic, copy) void (^flmTouchStateDidChange)(void);
@end

@implementation FLMCornerGestureRecognizer

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *firstTouch = [touches anyObject];
    if (firstTouch && self.flmFirstTouchTimestamp <= 0.0) {
        self.flmFirstTouchTimestamp = firstTouch.timestamp;
    }
    self.flmActiveTouchCount += touches.count;
    if (self.flmTouchStateDidChange) {
        self.flmTouchStateDidChange();
    }
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    self.flmActiveTouchCount =
        touches.count >= self.flmActiveTouchCount
            ? 0
            : self.flmActiveTouchCount - touches.count;
    if (self.flmTouchStateDidChange) {
        self.flmTouchStateDidChange();
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches
               withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    self.flmActiveTouchCount =
        touches.count >= self.flmActiveTouchCount
            ? 0
            : self.flmActiveTouchCount - touches.count;
    if (self.flmTouchStateDidChange) {
        self.flmTouchStateDidChange();
    }
}

- (void)reset {
    [super reset];
    self.flmFirstTouchTimestamp = 0.0;
    self.flmOutsideCloseAuthorized = NO;
    self.flmAuthorizedStartPoint = CGPointZero;
    self.flmActiveTouchCount = 0;
    if (self.flmTouchStateDidChange) {
        self.flmTouchStateDidChange();
    }
}

- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)preventingGestureRecognizer {
    (void)preventingGestureRecognizer;
    return NO;
}

- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)preventedGestureRecognizer {
    (void)preventedGestureRecognizer;
    return YES;
}

- (BOOL)shouldBeRequiredToFailByGestureRecognizer:
    (UIGestureRecognizer *)otherGestureRecognizer {
    (void)otherGestureRecognizer;
    return NO;
}

- (BOOL)shouldRequireFailureOfGestureRecognizer:
    (UIGestureRecognizer *)otherGestureRecognizer {
    (void)otherGestureRecognizer;
    return NO;
}

@end

// Intercepts the home-indicator up-swipe in the bottom-center zone. The system
// home gesture needs motion, so a stationary press always beats it: after
// flmPressDuration with less than flmMovementTolerance of travel the recognizer
// begins (and prevents the home gesture from opening the app switcher), then a
// subsequent upward drag past flmSwipeThreshold docks the frontmost app. A
// regular quick or slow swipe moves more than the tolerance before the press
// elapses and fails itself, leaving the system home gesture untouched.
@interface FLMDockGestureRecognizer : UIGestureRecognizer
@property(nonatomic, assign) NSTimeInterval flmPressDuration;
@property(nonatomic, assign) CGFloat flmMovementTolerance;
@property(nonatomic, assign) CGFloat flmSwipeThreshold;
@property(nonatomic, assign, readonly) BOOL flmLongPressConfirmed;
@property(nonatomic, assign, readonly) BOOL flmTriggered;
@end

@interface FLMDockGestureRecognizer () {
    NSTimeInterval _flmFirstTouchTimestamp;
    CGPoint _flmPressStartPoint;
    NSUInteger _flmPressToken;
}
@end

@implementation FLMDockGestureRecognizer

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    self = [super initWithTarget:target action:action];
    if (self) {
        _flmPressDuration = 0.25;
        _flmMovementTolerance = 8.0;
        _flmSwipeThreshold = 40.0;
    }
    return self;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    if (self.state != UIGestureRecognizerStatePossible) {
        return;
    }
    UITouch *firstTouch = [touches anyObject];
    if (!firstTouch) {
        return;
    }
    _flmFirstTouchTimestamp = firstTouch.timestamp;
    _flmPressStartPoint = [firstTouch locationInView:nil];
    _flmLongPressConfirmed = NO;
    _flmTriggered = NO;
    _flmPressToken += 1;
    NSUInteger token = _flmPressToken;
    __weak FLMDockGestureRecognizer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(self.flmPressDuration *
                                           NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FLMDockGestureRecognizer *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_flmPressToken != token ||
            strongSelf.state != UIGestureRecognizerStatePossible) {
            return;
        }
        strongSelf->_flmLongPressConfirmed = YES;
        strongSelf.state = UIGestureRecognizerStateBegan;
    });
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    UITouch *firstTouch = [touches anyObject];
    if (!firstTouch) {
        return;
    }
    CGPoint location = [firstTouch locationInView:nil];
    if (self.state == UIGestureRecognizerStatePossible) {
        CGFloat movement =
            hypot(location.x - _flmPressStartPoint.x,
                  location.y - _flmPressStartPoint.y);
        if (movement >= self.flmMovementTolerance) {
            _flmPressToken += 1;
            self.state = UIGestureRecognizerStateFailed;
        }
        return;
    }
    if (self.state == UIGestureRecognizerStateBegan ||
        self.state == UIGestureRecognizerStateChanged) {
        CGFloat upward = _flmPressStartPoint.y - location.y;
        if (_flmTriggered && upward >= self.flmSwipeThreshold) {
            self.state = UIGestureRecognizerStateChanged;
        } else if (!_flmTriggered && upward >= self.flmSwipeThreshold) {
            _flmTriggered = YES;
            self.state = UIGestureRecognizerStateChanged;
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    if (self.state == UIGestureRecognizerStatePossible) {
        _flmPressToken += 1;
        self.state = UIGestureRecognizerStateFailed;
    } else if (self.state == UIGestureRecognizerStateBegan ||
               self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateEnded;
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    if (self.state == UIGestureRecognizerStatePossible) {
        _flmPressToken += 1;
        self.state = UIGestureRecognizerStateFailed;
    }
}

- (void)reset {
    [super reset];
    _flmPressToken += 1;
    _flmFirstTouchTimestamp = 0.0;
    _flmPressStartPoint = CGPointZero;
    _flmLongPressConfirmed = NO;
    _flmTriggered = NO;
}

- (BOOL)canBePreventedByGestureRecognizer:
    (UIGestureRecognizer *)preventingGestureRecognizer {
    (void)preventingGestureRecognizer;
    return NO;
}

- (BOOL)canPreventGestureRecognizer:
    (UIGestureRecognizer *)preventedGestureRecognizer {
    (void)preventedGestureRecognizer;
    return YES;
}

- (BOOL)shouldBeRequiredToFailByGestureRecognizer:
    (UIGestureRecognizer *)otherGestureRecognizer {
    (void)otherGestureRecognizer;
    return NO;
}

- (BOOL)shouldRequireFailureOfGestureRecognizer:
    (UIGestureRecognizer *)otherGestureRecognizer {
    (void)otherGestureRecognizer;
    return NO;
}

@end

@interface FLMOutsideTapGestureRecognizer : UIGestureRecognizer
@property(nonatomic, weak) UIView *protectedView;
@property(nonatomic, weak) UIView *secondaryProtectedView;
@property(nonatomic, assign) CGRect additionalProtectedFrame;
@property(nonatomic, strong) NSMutableDictionary<NSValue *, NSValue *> *startPoints;
@property(nonatomic, assign) NSTimeInterval firstTouchTimestamp;
@property(nonatomic, assign) BOOL outsideCloseAuthorized;
@property(nonatomic, assign) NSUInteger touchSequence;
@end

@implementation FLMOutsideTapGestureRecognizer

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    self = [super initWithTarget:target action:action];
    if (self) {
        _startPoints = [NSMutableDictionary dictionary];
        _additionalProtectedFrame = CGRectNull;
        self.cancelsTouchesInView = NO;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
    }
    return self;
}

- (NSValue *)keyForTouch:(UITouch *)touch {
    return [NSValue valueWithNonretainedObject:touch];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    static NSUInteger nextTouchSequence = 0;
    self.touchSequence = ++nextTouchSequence;
    self.outsideCloseAuthorized = NO;
    if (self.startPoints.count + touches.count > 1) {
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    if (self.firstTouchTimestamp <= 0.0) {
        UITouch *firstTouch = [touches anyObject];
        self.firstTouchTimestamp = firstTouch.timestamp;
    }
    for (UITouch *touch in touches) {
        CGPoint point = [touch locationInView:self.view];
        BOOL inCard = self.protectedView &&
                      CGRectContainsPoint(self.protectedView.frame, point);
        BOOL inHandle = self.secondaryProtectedView &&
                        CGRectContainsPoint(self.secondaryProtectedView.frame,
                                            point);
        BOOL inKeyboard = !CGRectIsNull(self.additionalProtectedFrame) &&
                          CGRectContainsPoint(self.additionalProtectedFrame,
                                              point);
        FLMEnqueueDiagnosticLine(
            @"sb touch-backdrop-began sequence=%lu touch=%p timestamp=%.6f point={%.1f,%.1f} inCard=%d inHandle=%d inKeyboard=%d keyboardFrame=%@",
            (unsigned long)self.touchSequence, (__bridge void *)touch,
            touch.timestamp, point.x, point.y, inCard, inHandle, inKeyboard,
            NSStringFromCGRect(self.additionalProtectedFrame));
        if (inCard) {
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
        if (inHandle) {
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
        if (inKeyboard) {
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
        self.startPoints[[self keyForTouch:touch]] = [NSValue valueWithCGPoint:point];
    }
    self.outsideCloseAuthorized = self.startPoints.count == 1;
    FLMEnqueueDiagnosticLine(
        @"sb touch-backdrop-authorized sequence=%lu authorized=%d",
        (unsigned long)self.touchSequence, self.outsideCloseAuthorized);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for (UITouch *touch in touches) {
        NSValue *startValue = self.startPoints[[self keyForTouch:touch]];
        if (!startValue) {
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
        CGPoint start = startValue.CGPointValue;
        CGPoint current = [touch locationInView:self.view];
        if (hypot(current.x - start.x, current.y - start.y) > 12.0) {
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    NSTimeInterval lastTimestamp = self.firstTouchTimestamp;
    for (UITouch *touch in touches) {
        lastTimestamp = MAX(lastTimestamp, touch.timestamp);
        [self.startPoints removeObjectForKey:[self keyForTouch:touch]];
    }
    if (self.startPoints.count != 0) {
        return;
    }
    self.state =
        lastTimestamp - self.firstTouchTimestamp <= 0.35
            ? UIGestureRecognizerStateRecognized
            : UIGestureRecognizerStateFailed;
    FLMEnqueueDiagnosticLine(
        @"sb touch-backdrop-ended sequence=%lu authorized=%d duration=%.4f state=%ld",
        (unsigned long)self.touchSequence, self.outsideCloseAuthorized,
        lastTimestamp - self.firstTouchTimestamp, (long)self.state);
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    self.state = UIGestureRecognizerStateCancelled;
}

- (void)reset {
    [super reset];
    [self.startPoints removeAllObjects];
    self.firstTouchTimestamp = 0.0;
    self.outsideCloseAuthorized = NO;
    self.touchSequence = 0;
}

- (BOOL)canBePreventedByGestureRecognizer:
    (UIGestureRecognizer *)preventingGestureRecognizer {
    (void)preventingGestureRecognizer;
    return NO;
}

@end

static CGFloat FLMUniformScaleFromTransform(CATransform3D transform) {
    CGFloat scaleX = hypot(transform.m11, transform.m12);
    CGFloat scaleY = hypot(transform.m21, transform.m22);
    CGFloat scale = (scaleX + scaleY) * 0.5;
    return scale > 0.001 && isfinite(scale) ? scale : 1.0;
}

@interface FLMWheelItemView : UIView
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, assign) BOOL highlighted;
@end

@implementation FLMWheelItemView

- (instancetype)initWithIdentifier:(NSString *)identifier
                             image:(UIImage *)image
                              size:(CGFloat)size {
    self = [super initWithFrame:CGRectMake(0.0, 0.0, size, size)];
    if (self) {
        _identifier = [identifier copy];
        BOOL isLockItem = [identifier isEqualToString:FLYME_LOCK_SCREEN_ITEM];
        BOOL isBuiltInAction = isLockItem;
        self.backgroundColor = isLockItem ? [UIColor systemBlueColor]
                                          : [UIColor clearColor];
        self.layer.cornerRadius = size * 0.5;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.22;
        self.layer.shadowRadius = 8.0;
        self.layer.shadowOffset = CGSizeMake(0.0, 3.0);
        self.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:self.bounds].CGPath;

        _iconView = [[UIImageView alloc] initWithImage:image];
        CGFloat lockInset = size * (15.0 / FLMDefaultWheelIconSize);
        _iconView.frame =
            isBuiltInAction ? CGRectInset(self.bounds, lockInset, lockInset)
                            : self.bounds;
        _iconView.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _iconView.contentMode =
            isBuiltInAction ? UIViewContentModeScaleAspectFit
                            : UIViewContentModeScaleAspectFill;
        _iconView.clipsToBounds = YES;
        _iconView.layer.cornerRadius = isBuiltInAction ? 0.0 : size * 0.5;
        [self addSubview:_iconView];
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    if (_highlighted == highlighted) {
        return;
    }
    _highlighted = highlighted;
    CGFloat scale = highlighted ? 1.24 : 1.0;
    self.layer.shadowOpacity = highlighted ? 0.32 : 0.18;
    [UIView animateWithDuration:0.28
                          delay:0.0
         usingSpringWithDamping:0.64
          initialSpringVelocity:0.45
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         self.transform = CGAffineTransformMakeScale(scale, scale);
                     }
                     completion:nil];
}

@end

@interface FLMWheelController : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, strong) FLMOverlayWindow *overlayWindow;
@property(nonatomic, strong) UIView *wheelContainer;
@property(nonatomic, strong) FLMHotspotWindow *hotspotWindow;
@property(nonatomic, strong) FLMHomeDockWindow *homeDockWindow;
@property(nonatomic, strong) FLMOverlayWindow *floatingWindow;
@property(nonatomic, strong) FLMDockTouchGateWindow *floatingDockTouchGateWindow;
@property(nonatomic, strong) UIView *floatingDimView;
@property(nonatomic, strong) UIView *floatingDockShadowView;
@property(nonatomic, strong) UIView *floatingContainer;
@property(nonatomic, strong) UIView *floatingDockInteractionShield;
@property(nonatomic, strong) UIView *floatingHandle;
@property(nonatomic, strong) UIView *floatingHandleBar;
// Transparent hit target for dock resizing.  The old L-shaped layer was only
// a visual affordance; the resize gesture itself remains active without it.
@property(nonatomic, strong) UIView *floatingResizeHandle;
@property(nonatomic, strong) UIView *floatingHostView;
@property(nonatomic, strong) UILabel *floatingStatusLabel;
@property(nonatomic, strong) UIView *floatingLaunchCoverView;
@property(nonatomic, strong) UIImageView *floatingLaunchIconView;
@property(nonatomic, strong) FLMOutsideTapGestureRecognizer *floatingBackdropTap;
@property(nonatomic, strong) UILongPressGestureRecognizer *floatingHandlePress;
@property(nonatomic, strong) UITapGestureRecognizer *floatingHandleTap;
@property(nonatomic, strong) UILongPressGestureRecognizer *floatingDockDragPress;
@property(nonatomic, strong) FLMCornerGestureRecognizer *floatingExclusiveGesture;
@property(nonatomic, strong) FLMCornerGestureRecognizer *floatingDockInputGesture;
@property(nonatomic, weak) UIWindow *previousKeyWindow;
@property(nonatomic, strong) FLMCornerGestureRecognizer *cornerGuardGesture;
@property(nonatomic, strong) FLMCornerGestureRecognizer *cornerGesture;
@property(nonatomic, strong) FLMCornerGestureRecognizer *floatingCornerGuardGesture;
@property(nonatomic, strong) FLMCornerGestureRecognizer *floatingCornerGesture;
@property(nonatomic, strong) FLMCornerGestureRecognizer *modalGesture;
@property(nonatomic, strong) UITapGestureRecognizer *wheelTapGesture;
@property(nonatomic, strong) id systemGestureManager;
@property(nonatomic, strong) id displayIdentity;
@property(nonatomic, strong) NSArray<FLMWheelItemView *> *itemViews;
@property(nonatomic, copy) NSArray<NSString *> *itemIdentifiers;
@property(nonatomic, weak) FLMWheelItemView *highlightedItem;
@property(nonatomic, assign) BOOL enabled;
@property(nonatomic, assign) BOOL presentingFromRight;
@property(nonatomic, assign) BOOL usesSystemGestureManager;
@property(nonatomic, assign) BOOL wheelPinned;
@property(nonatomic, assign) BOOL wheelGestureActive;
@property(nonatomic, assign) CGFloat wheelRadius;
@property(nonatomic, assign) CGFloat wheelIconSize;
@property(nonatomic, assign) CGFloat centeredCardWidth;
@property(nonatomic, assign) CGFloat centeredCardTopCrop;
@property(nonatomic, assign) CGFloat centeredCardBottomCrop;
@property(nonatomic, assign) CGFloat centeredDockSwipeThreshold;
@property(nonatomic, assign) CGFloat dockedShrinkAmount;
@property(nonatomic, assign) FLMSessionCanonicalGeometry sessionCanonicalGeometry;
@property(nonatomic, assign) BOOL sessionCanonicalGeometryValid;
@property(nonatomic, assign) NSUInteger sessionCanonicalGeometrySession;
@property(nonatomic, assign) NSTimeInterval floatingDockRestorePrepareTimestamp;
@property(nonatomic, assign) NSUInteger floatingDockRestorePerformanceGeneration;
@property(nonatomic, assign) CGPoint floatingHandleStartPoint;
@property(nonatomic, assign) CGRect floatingHandleInitialContainerFrame;
@property(nonatomic, assign) BOOL floatingHandleMoved;
@property(nonatomic, assign) BOOL floatingDocked;
@property(nonatomic, assign) BOOL floatingDockedOnRight;
@property(nonatomic, assign) BOOL floatingDockHidden;
@property(nonatomic, assign) BOOL floatingDockHideGestureActive;
@property(nonatomic, assign) BOOL floatingDockHideReady;
@property(nonatomic, assign) CGPoint floatingDockHideStartPoint;
@property(nonatomic, assign) CGRect floatingDockHideInitialFrame;
@property(nonatomic, assign) CGPoint floatingHiddenBarDragStartPoint;
@property(nonatomic, assign) CGRect floatingHiddenBarDragInitialFrame;
@property(nonatomic, assign) BOOL floatingDockTransitionActive;
@property(nonatomic, assign) FLMFloatingDockPresentationMode floatingDockPresentationMode;
@property(nonatomic, strong) UIViewPropertyAnimator *floatingDockTransitionAnimator;
@property(nonatomic, assign) FLMFloatingDockControlTransition
    floatingDockControlTransition;
@property(nonatomic, assign) NSUInteger floatingDockControlTransitionGeneration;
@property(nonatomic, assign) CGRect floatingDockControlTargetFrame;
@property(nonatomic, assign) BOOL floatingDockControlDefersKeyboardTeardown;
@property(nonatomic, assign) CGFloat floatingDockWidth;
@property(nonatomic, assign) CGFloat floatingDockVerticalCenter;
@property(nonatomic, assign) CGPoint floatingDockDragStartPoint;
@property(nonatomic, assign) CGPoint floatingDockDragInitialCenter;
@property(nonatomic, assign) CGPoint floatingDockDirectPanMinimumCenter;
@property(nonatomic, assign) CGPoint floatingDockDirectPanMaximumCenter;
@property(nonatomic, assign) CGPoint floatingResizeStartPoint;
@property(nonatomic, assign) CGRect floatingResizeInitialFrame;
@property(nonatomic, assign) CGPoint floatingDockInputLatestPoint;
@property(nonatomic, assign) CGPoint floatingDockInputFramePoint;
@property(nonatomic, assign) BOOL floatingDockInputTargetsResize;
@property(nonatomic, assign) BOOL floatingDockGlobalDragActivated;
@property(nonatomic, assign) FLMFloatingDockInputMode floatingDockInputMode;
@property(nonatomic, assign) BOOL floatingDockInputSessionActive;
@property(nonatomic, assign) BOOL floatingDockInputBlockedUntilNextTouch;
@property(nonatomic, assign) NSTimeInterval floatingDockInputBlockCutoffTimestamp;
@property(nonatomic, assign) BOOL floatingDockInputFramePending;
@property(nonatomic, assign) NSUInteger floatingDockInputFrameGeneration;
@property(nonatomic, strong) CADisplayLink *floatingDockInputDisplayLink;
@property(nonatomic, assign) NSUInteger floatingDockInputGeneration;
@property(nonatomic, assign) NSUInteger floatingDockPerfCallbackCount;
@property(nonatomic, assign) NSUInteger floatingDockPerfConsumedFrameCount;
@property(nonatomic, assign) NSUInteger floatingDockPerfInputSampleCount;
@property(nonatomic, assign) NSUInteger floatingDockPerfCoalescedSampleCount;
@property(nonatomic, assign) NSUInteger floatingDockPerfCallbackGapEstimate;
@property(nonatomic, assign) NSUInteger floatingDockPerfRenderFrames;
@property(nonatomic, assign) NSUInteger floatingDockPerfMissedVsync;
@property(nonatomic, assign) NSTimeInterval floatingDockPerfFrameSumMs;
@property(nonatomic, assign) NSTimeInterval floatingDockPerfMaximumFrameMs;
@property(nonatomic, assign) NSTimeInterval floatingDockPerfLastRenderTimestamp;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *floatingDockPerfFrameSamples;
@property(nonatomic, assign) NSInteger floatingDockPerfMaximumFramesPerSecond;
@property(nonatomic, assign) CGFloat floatingDockPerfRequestedMinimumFramesPerSecond;
@property(nonatomic, assign) CGFloat floatingDockPerfRequestedMaximumFramesPerSecond;
@property(nonatomic, assign) CGFloat floatingDockPerfRequestedPreferredFramesPerSecond;
@property(nonatomic, assign) NSTimeInterval floatingDockPerfActualCallbackDeltaSumMs;
@property(nonatomic, assign) NSTimeInterval floatingDockPerfTargetDeltaSumMs;
@property(nonatomic, assign) NSTimeInterval floatingDockPerfMaximumActualCallbackDeltaMs;
@property(nonatomic, assign) NSTimeInterval floatingDockPerfMaximumTargetDeltaMs;
@property(nonatomic, assign) NSTimeInterval floatingDockPerfLastTargetTimestamp;
@property(nonatomic, assign) BOOL floatingDockDisplayLinkConfigLogged;
@property(nonatomic, assign) NSTimeInterval floatingDockPerfLastTimestamp;
@property(nonatomic, assign) NSTimeInterval floatingDockPerfMaximumCallbackGap;
@property(nonatomic, assign) BOOL floatingDockReady;
@property(nonatomic, assign) FLMFloatingDockRendererMode floatingDockRendererMode;
@property(nonatomic, assign) BOOL floatingDockDisplayLinkCapped60;
@property(nonatomic, assign) NSUInteger floatingDockDisplayLinkProbeIntervalCount;
@property(nonatomic, assign) NSUInteger floatingDockDisplayLinkProbeSlowCount;
@property(nonatomic, assign) NSTimeInterval floatingDockDisplayLinkProbeLastTimestamp;
@property(nonatomic, assign) NSTimeInterval floatingDockPerfInputDeltaSumMs;
@property(nonatomic, assign) NSTimeInterval floatingDockPerfLastInputTimestamp;
@property(nonatomic, assign) NSUInteger floatingDockPerfRenderCommitCount;
@property(nonatomic, assign) NSTimeInterval floatingDockPerfRenderDeltaSumMs;
@property(nonatomic, assign) NSTimeInterval floatingDockPerfLastRenderCommitTimestamp;
@property(nonatomic, assign) BOOL floatingDockFeedbackSent;
@property(nonatomic, assign) BOOL floatingResizeCenterReady;
@property(nonatomic, assign) BOOL floatingDockContentTailProtected;
@property(nonatomic, assign) NSUInteger floatingDockContentProtectionGeneration;
@property(nonatomic, assign) BOOL floatingDockContentTransitionCommitted;
@property(nonatomic, assign) CGRect floatingDockContentProtectionFrame;
@property(nonatomic, assign) CGRect floatingDockTouchGateTransitionFrame;
@property(nonatomic, assign) BOOL floatingDockBarrierTouchActive;
@property(nonatomic, assign) CGPoint floatingExclusiveStartPoint;
@property(nonatomic, assign) NSTimeInterval floatingExclusiveStartTimestamp;
@property(nonatomic, assign) BOOL floatingExclusiveTapEligible;
@property(nonatomic, assign) BOOL floatingInteractiveFullscreenTransition;
@property(nonatomic, assign) BOOL floatingInteractiveScenePrepared;
@property(nonatomic, assign) BOOL floatingSceneUsesCardGeometry;
@property(nonatomic, assign) BOOL floatingSceneCardGeometryPending;
@property(nonatomic, assign) BOOL floatingSceneCardGeometryCommitted;
@property(nonatomic, assign) BOOL contentViewportCommitted;
@property(nonatomic, assign) NSUInteger floatingSceneGeometryCommitGeneration;
@property(nonatomic, assign) CGFloat floatingFullscreenProgress;
@property(nonatomic, strong) UIView *floatingInteractiveSnapshot;
@property(nonatomic, strong) UIView *floatingInteractiveSnapshotBackground;
@property(nonatomic, strong) UIView *floatingInteractiveSnapshotContent;
@property(nonatomic, assign) BOOL floatingReconnectSuppressed;
@property(nonatomic, assign) BOOL floatingKeyboardVisible;
@property(nonatomic, assign) CGRect floatingKeyboardFrame;
@property(nonatomic, assign) CGFloat lastPortraitKeyboardHeight;
@property(nonatomic, assign) CGFloat floatingKeyboardMaximumVisibleHeight;
@property(nonatomic, assign) BOOL floatingKeyboardInteractionSessionActive;
@property(nonatomic, assign) NSUInteger floatingKeyboardInteractionGeneration;
@property(nonatomic, assign) NSUInteger floatingKeyboardSessionCounter;
@property(nonatomic, assign) NSUInteger floatingKeyboardSessionGeneration;
@property(nonatomic, assign) FLMFloatingKeyboardCloseState floatingKeyboardCloseState;
@property(nonatomic, assign) NSUInteger floatingKeyboardDismissRequestGeneration;
@property(nonatomic, assign) NSUInteger floatingKeyboardDismissSessionGeneration;
@property(nonatomic, assign) NSUInteger floatingKeyboardDismissCloseToken;
@property(nonatomic, assign) FLMKeyboardDismissResult floatingKeyboardDismissResult;
@property(nonatomic, assign) FLMKeyboardDismissAckPhase floatingKeyboardDismissAckPhase;
@property(nonatomic, assign) BOOL floatingKeyboardAppDismissClaimed;
@property(nonatomic, assign) BOOL floatingKeyboardAppResponderActionStarted;
@property(nonatomic, copy) NSString *floatingKeyboardCloseAbortReason;
@property(nonatomic, assign) BOOL floatingKeyboardSettlementFrameHidden;
@property(nonatomic, assign) BOOL floatingKeyboardSettlementDidHide;
@property(nonatomic, assign) pid_t floatingKeyboardDismissAdapterPID;
@property(nonatomic, strong) FLMKeyboardCloseContext *floatingKeyboardCloseContext;
@property(nonatomic, assign) BOOL floatingCloseCommitInProgress;
@property(nonatomic, assign) BOOL floatingKeyboardAdapterHandshakeValid;
@property(nonatomic, assign) BOOL floatingKeyboardAdapterHandshakeAttempted;
@property(nonatomic, assign) pid_t floatingKeyboardAdapterHandshakePID;
@property(nonatomic, copy) NSString *floatingKeyboardAdapterHandshakeIdentifier;
@property(nonatomic, assign) NSUInteger floatingKeyboardAdapterHandshakeSessionGeneration;
@property(nonatomic, assign) CGRect floatingKeyboardLastPublishedFrame;
@property(nonatomic, assign) BOOL floatingKeyboardLastPublishedFrameValid;
@property(nonatomic, assign) BOOL floatingKeyboardLastPublishedVisible;
@property(nonatomic, assign) NSUInteger floatingKeyboardLastPublishedSessionGeneration;
@property(nonatomic, assign) CGRect floatingKeyboardLastNotificationFrame;
@property(nonatomic, assign) BOOL floatingKeyboardLastNotificationFrameValid;
@property(nonatomic, assign) BOOL floatingKeyboardLastNotificationVisible;
@property(nonatomic, strong) FLMKeyboardForwardingWindow *keyboardForwardingWindow;
@property(nonatomic, weak) UIView *floatingKeyboardLayerHostView;
@property(nonatomic, weak) UIView *floatingKeyboardRejectedHostView;
@property(nonatomic, assign) BOOL floatingKeyboardRejectedHostWasHidden;
@property(nonatomic, strong) UIView *floatingKeyboardOriginalSuperview;
@property(nonatomic, assign) NSInteger floatingKeyboardOriginalSubviewIndex;
@property(nonatomic, assign) CGRect floatingKeyboardOriginalFrame;
@property(nonatomic, assign) CGAffineTransform floatingKeyboardOriginalTransform;
@property(nonatomic, assign) UIViewAutoresizing floatingKeyboardOriginalAutoresizingMask;
@property(nonatomic, assign) BOOL floatingKeyboardOriginalTranslatesAutoresizingMask;
@property(nonatomic, assign) NSUInteger floatingKeyboardHostSessionGeneration;
@property(nonatomic, strong) id floatingKeyboardScene;
@property(nonatomic, strong) id floatingKeyboardPreferredHostIdentity;
@property(nonatomic, assign) NSUInteger floatingKeyboardPairingSessionGeneration;
@property(nonatomic, assign) BOOL floatingKeyboardPresentationSuspendedForDock;
@property(nonatomic, assign) BOOL floatingKeyboardAvoidancePublishDeferred;
@property(nonatomic, assign) BOOL floatingKeyboardFramePending;
@property(nonatomic, assign) CGRect floatingKeyboardPendingFrame;
@property(nonatomic, assign) NSUInteger floatingKeyboardPendingSessionGeneration;
@property(nonatomic, weak) UIView *floatingKeyboardDeferredHostView;
@property(nonatomic, strong) id floatingKeyboardDeferredScene;
@property(nonatomic, assign) NSUInteger floatingKeyboardDeferredSessionGeneration;
@property(nonatomic, assign) CGPoint cornerGestureStartPoint;
@property(nonatomic, copy) NSString *floatingIdentifier;
@property(nonatomic, copy) NSString *prewarmedIdentifier;
@property(nonatomic, copy) NSString *lastObservedFrontmostIdentifier;
@property(nonatomic, assign) BOOL floatingExternalActivationArmed;
@property(nonatomic, assign) BOOL floatingFullscreenActivationArmed;
@property(nonatomic, strong) FLMDeviceApplicationSceneEntity *floatingSceneEntity;
@property(nonatomic, strong) FLMApplicationSceneHandle *floatingSceneHandle;
@property(nonatomic, strong) id floatingScene;
@property(nonatomic, strong) id floatingPresentationManager;
@property(nonatomic, strong) id floatingPresenter;
@property(nonatomic, strong) id floatingPresenterScene;
@property(nonatomic, assign) CGSize floatingHostReferenceSize;
@property(nonatomic, assign) NSUInteger floatingLaunchGeneration;
@property(nonatomic, assign) FLMFloatingLaunchState floatingLaunchState;
@property(nonatomic, assign) NSTimeInterval floatingLaunchStartedAt;
@property(nonatomic, assign) NSUInteger floatingRevealRetryCount;
@property(nonatomic, assign) NSTimeInterval floatingScenePreparedAt;
@property(nonatomic, assign) NSTimeInterval floatingPresenterUnavailableAt;
@property(nonatomic, assign) NSUInteger floatingPresenterRetryAttempt;
@property(nonatomic, assign) BOOL floatingCloseInProgress;
@property(nonatomic, assign) NSUInteger floatingCloseTokenCounter;
@property(nonatomic, assign) NSUInteger floatingActiveCloseToken;
@property(nonatomic, assign) BOOL floatingCloseCleanupDone;
@property(nonatomic, assign) BOOL floatingCloseKeepApplication;
@property(nonatomic, assign) BOOL floatingCloseDeferKeyboardSessionEnd;
@property(nonatomic, copy) NSString *floatingQueuedIdentifier;
@property(nonatomic, copy) NSString *floatingQueuedFullscreenIdentifier;
@property(nonatomic, strong) id floatingClosingScene;
@property(nonatomic, strong) id floatingClosingPresenter;
@property(nonatomic, strong) UIView *floatingClosingHostView;
@property(nonatomic, strong) NSTimer *lockMonitorTimer;
@property(nonatomic, strong) FLMDockGestureRecognizer *homeDockGesture;
@property(nonatomic, assign) BOOL homeDockGestureActive;
@property(nonatomic, assign) BOOL homeDockTriggerHandled;
@property(nonatomic, assign) BOOL floatingOpenTargetDocked;
+ (instancetype)sharedController;
- (void)start;
- (void)reloadPreferences;
- (void)createWindows;
- (void)createFloatingWindow;
- (BOOL)registerGlobalCornerGesture;
- (void)updateWindowFrames;
- (void)handleCornerGuardGesture:(UIGestureRecognizer *)gesture;
- (void)handleCornerGesture:(UIGestureRecognizer *)gesture;
- (void)handleModalGesture:(UIGestureRecognizer *)gesture;
- (void)handleHomeDockGesture:(FLMDockGestureRecognizer *)gesture;
- (void)activateDockedFrontmostApplication;
- (BOOL)shouldActivateWheelAtPoint:(CGPoint)point;
- (NSArray<NSNumber *> *)itemCountsByRingForCount:(NSUInteger)count;
- (void)presentWheelFromRight:(BOOL)fromRight;
- (void)updateHighlightForPoint:(CGPoint)point;
- (void)pinWheel;
- (void)handleWheelTap:(UITapGestureRecognizer *)gesture;
- (void)handleFloatingBackdropTap:(UIGestureRecognizer *)gesture;
- (void)handleFloatingHandlePress:(UILongPressGestureRecognizer *)gesture;
- (void)handleFloatingHiddenBarDrag:(UILongPressGestureRecognizer *)gesture;
- (void)handleFloatingHandleTap:(UITapGestureRecognizer *)gesture;
- (void)handleFloatingDockDragPress:(UILongPressGestureRecognizer *)gesture;
- (void)handleFloatingExclusiveGesture:(UIGestureRecognizer *)gesture;
- (void)handleFloatingDockInputGesture:(FLMCornerGestureRecognizer *)gesture;
- (BOOL)floatingDockControlOwnsPoint:(CGPoint)point;
- (void)refreshWheelPriorityWindow;
- (void)activateFloatingDockDragForGeneration:(NSUInteger)generation;
- (void)prepareFloatingDockDisplayLink;
- (void)setFloatingDockDisplayLinkActive:(BOOL)active;
- (void)queueFloatingDockInputUpdateForPoint:(CGPoint)point;
- (void)flushFloatingDockInputFrame:(CADisplayLink *)displayLink;
- (void)flushFloatingDockInputFrameImmediately;
- (void)cancelFloatingDockInputUpdates;
- (void)applyFloatingDockInputPoint:(CGPoint)point;
- (void)applyFloatingDockDirectPanPoint:(CGPoint)point;
- (void)observeFloatingDockDisplayLinkInterval:(NSTimeInterval)timestamp;
- (void)recordFloatingDockInputSampleAtTimestamp:(NSTimeInterval)timestamp;
- (void)recordFloatingDockRenderCommitAtTimestamp:(NSTimeInterval)timestamp;
- (void)verifyFloatingDockPresentationScaleInvariant:(NSString *)phase;
- (void)setFloatingDockRoutingSuppressed:(BOOL)suppressed;
- (void)updateFloatingDockTouchGate;
- (void)keyboardFrameWillChange:(NSNotification *)notification;
- (void)keyboardDidHide:(NSNotification *)notification;
- (void)handleApplicationDismissAck:(int)token;
- (void)handleKeyboardSharedStateUpdate;
- (void)beginKeyboardCoordinatedCloseWithToken:(NSUInteger)closeToken;
- (void)handleKeyboardSettlementForCloseToken:(NSUInteger)closeToken;
- (void)scheduleKeyboardSettlementTimeoutForContext:(FLMKeyboardCloseContext *)context;
- (void)interruptFloatingDockTransitionAtPoint:(CGPoint)point;
- (void)suspendFloatingKeyboardPresentationForDockMode;
- (void)flushFloatingKeyboardAvoidancePublishAfterDock;
- (void)commitCoordinatedCloseForToken:(NSUInteger)closeToken;
- (void)abortCoordinatedCloseForToken:(NSUInteger)closeToken
                               reason:(NSString *)reason;
- (void)applyKeyboardFrame:(CGRect)frame visible:(BOOL)visible;
- (void)finalizeKeyboardDismissalProtection;
- (void)prepareKeyboardForwardingWindowIfNeeded;
- (void)keyboardLayerHostView:(UIView *)hostView
            didUpdateForScene:(id)scene
            sessionGeneration:(NSUInteger)sessionGeneration;
- (BOOL)floatingKeyboardPresentationReady;
- (BOOL)floatingApplicationHostReadyForKeyboardRoute;
- (void)flushDeferredFloatingKeyboardHostIfReady;
- (void)flushPendingFloatingKeyboardFrameIfReady;
- (void)quarantineFloatingKeyboardHost:(UIView *)hostView
                     sessionGeneration:(NSUInteger)sessionGeneration
                                 reason:(NSString *)reason;
- (void)releaseFloatingKeyboardHostQuarantine:(UIView *)hostView
                                        reason:(NSString *)reason;
- (void)releaseAllFloatingKeyboardHostQuarantinesForReason:(NSString *)reason;
- (void)discardFloatingKeyboardHostQuarantine:(UIView *)hostView
                                        reason:(NSString *)reason;
- (void)discardAllFloatingKeyboardHostQuarantinesForReason:(NSString *)reason;
- (void)restoreFloatingKeyboardLayerHost;
- (void)discardFloatingKeyboardLayerHost;
- (void)deactivateKeyboardForwardingWindow;
- (void)endFloatingKeyboardSession;
- (BOOL)propagateFloatingKeyboardScenePairing:(id)keyboardScene
                         preferredHostIdentity:(id)preferredHostIdentity
                             sessionGeneration:(NSUInteger)sessionGeneration;
- (void)clearFloatingKeyboardScenePairingForSession:(NSUInteger)sessionGeneration;
- (CGRect)floatingKeyboardInteractionFrame;
- (BOOL)pointIsInsideFloatingInteractionDomain:(CGPoint)point;
- (CGFloat)floatingKeyboardAvoidanceHeightForFrame:(CGRect)frame;
- (void)beginFloatingKeyboardInteractionSession;
- (void)endFloatingKeyboardInteractionSession;
- (void)resetFloatingInteractiveLayoutAnimated:(BOOL)animated;
- (void)setFloatingApplicationInputBlocked:(BOOL)blocked;
- (NSUInteger)armFloatingContentProtectionForDockTransitionFrame:(CGRect)frame;
- (void)floatingDockInputRecognizerTouchStateDidChange;
- (void)markFloatingContentProtectionAnimationCommitted:
    (NSUInteger)generation;
- (void)releaseFloatingContentProtectionAfterDockTransition:
    (NSUInteger)generation;
- (void)updateFloatingFullscreenSnapshotForProgress:(CGFloat)progress;
- (void)layoutFloatingHandleForCurrentContainer;
- (CGFloat)effectiveCenteredCardWidth;
- (CGFloat)effectiveCenteredCardHeight;
- (CGFloat)effectiveCenteredCardScaleX;
- (CGFloat)effectiveCenteredCardScaleY;
- (CGFloat)configuredCenteredCardWidth;
- (CGFloat)configuredCenteredCardHeight;
- (BOOL)ensureSessionCanonicalGeometry;
- (void)invalidateSessionCanonicalGeometry;
- (CGRect)sessionCanonicalCenteredFrame;
- (CGRect)uncachedCenteredFloatingFrame;
- (void)reassertSessionCanonicalCenteredModelGeometry;
- (CGFloat)effectiveCenteredDockSwipeThreshold;
- (CGFloat)effectiveDockedPresentationWidth;
- (CGFloat)floatingDockPresentationScale;
- (CGRect)floatingContainerPresentationFrame;
- (void)configureFloatingContainerForDockPresentationAtCenter:(CGPoint)center
                                                          scale:(CGFloat)scale;
- (CGRect)centeredFloatingFrame;
- (CGRect)dockedFloatingFrameOnRight:(BOOL)onRight width:(CGFloat)width;
- (CGRect)dockedFloatingFrameOnRight:(BOOL)onRight
                               width:(CGFloat)width
             preservingVerticalCenter:(CGFloat)verticalCenter;
- (CGRect)dockedHiddenFloatingFrameOnRight:(BOOL)onRight width:(CGFloat)width;
- (CGRect)dockedHiddenFloatingFrameOnRight:(BOOL)onRight
                                      width:(CGFloat)width
                    preservingVerticalCenter:(CGFloat)verticalCenter;
- (void)layoutFloatingDockShadow;
- (void)updateFloatingDockAccessoryPositions;
- (void)layoutFloatingResizeHandle;
- (BOOL)floatingResizeControlContainsPoint:(CGPoint)point;
- (void)saveFloatingDockWidth;
- (void)normalizeFloatingContainerTransform;
- (void)lockFloatingDockGeometryForDrag;
- (void)configureFloatingInteractionForDockedState;
- (void)restoreFloatingHandleInteraction;
- (void)transitionFloatingWindowToDocked;
- (void)transitionFloatingWindowToCentered;
- (void)transitionFloatingWindowToHiddenAnimated:(BOOL)animated;
- (void)finishFloatingDockHiddenGesture:(BOOL)shouldHide
                                atPoint:(CGPoint)point;
- (void)updateFloatingDockHiddenRevealForPoint:(CGPoint)point;
- (void)snapDockedFloatingWindowUsingTouchPoint:(CGPoint)point;
- (void)prepareFloatingSceneForInteractiveFullscreen;
- (void)restoreFloatingSceneAfterCancelledTransition;
- (void)transitionFloatingWindowToFullscreen;
- (void)finishFullscreenHandoffWithCover:(UIView *)cover
                              identifier:(NSString *)identifier
                                 attempt:(NSUInteger)attempt;
- (void)protectedSceneDidDisappear:(NSNotification *)notification;
- (void)openFloatingIdentifier:(NSString *)identifier;
- (void)attachFloatingIdentifier:(NSString *)identifier
                       generation:(NSUInteger)generation
                          attempt:(NSUInteger)attempt;
- (void)commitFloatingCardSceneGeometryForIdentifier:(NSString *)identifier
                                           generation:(NSUInteger)generation
                                              attempt:(NSUInteger)attempt;
- (void)finishFloatingCardSceneGeometryCommitForIdentifier:(NSString *)identifier
                                                  generation:(NSUInteger)generation
                                                     attempt:(NSUInteger)attempt;
- (void)failFloatingLaunchForIdentifier:(NSString *)identifier
                               generation:(NSUInteger)generation;
- (void)invalidateFloatingPresenterForRecoveryReason:(NSString *)reason;
- (void)finishFloatingCloseWithToken:(NSUInteger)token;
- (FLMApplicationSceneHandle *)sceneHandleForIdentifier:(NSString *)identifier;
- (id)sceneForHandle:(FLMApplicationSceneHandle *)sceneHandle;
- (BOOL)prepareFloatingScene:(id)scene
                      handle:(FLMApplicationSceneHandle *)sceneHandle;
- (void)backgroundFloatingScene:(id)scene;
- (UIView *)hostViewForSceneHandle:(FLMApplicationSceneHandle *)sceneHandle;
- (void)layoutFloatingWindow;
- (void)configureFloatingLaunchCoverForIdentifier:(NSString *)identifier;
- (void)revealFloatingContentForGeneration:(NSUInteger)generation;
- (void)layoutFloatingHostView;
- (CGSize)floatingSystemSceneReferenceSize;
- (CGSize)floatingContentViewportReferenceSize;
- (CGSize)floatingSceneReferenceSize;
- (BOOL)applyFloatingSceneLogicalFrameForCurrentPresentation:(NSString *)policy;
- (BOOL)floatingSceneLogicalFrameMatchesSystemReference;
- (void)closeFloatingWindowKeepingApplication:(BOOL)keepApplication;
- (void)activateIdentifierFullscreen:(NSString *)identifier;
- (void)beginLockMonitoring;
- (void)stopLockMonitoringIfIdle;
- (void)checkLockState:(NSTimer *)timer;
- (FLMWheelItemView *)itemNearPoint:(CGPoint)point maximumDistance:(CGFloat)distance;
- (void)dismissWheelLaunchingItem:(FLMWheelItemView *)item;
- (void)activateIdentifier:(NSString *)identifier;
@end

static int FlymeRuntimeToken = -1;
static int FlymeKeyboardRouteToken = -1;
static int FlymeKeyboardSceneToken = -1;
static int FlymeKeyboardSessionToken = -1;
static int FlymeKeyboardAvoidanceToken = -1;
static int FlymeKeyboardCardGeometryToken = -1;
static int FlymeKeyboardAppCtorToken = -1;
static int FlymeKeyboardAppReadyToken = -1;
static int FlymeKeyboardDismissRequestToken = -1;
static int FlymeKeyboardDismissAckToken = -1;
static int FlymeKeyboardSharedStateToken = -1;
static NSString *const FLMKeyboardSharedStatePath =
    @"/var/mobile/Library/Preferences/FlymeMultitasking-KeyboardState.plist";
static NSString *const FLMKeyboardSharedStateRootlessPath =
    @"/var/jb/var/mobile/Library/Preferences/FlymeMultitasking-KeyboardState.plist";
static dispatch_queue_t FLMKeyboardSharedStateWriterQueue;
static NSString *FLMKeyboardSharedIdentifier;
static uint64_t FLMKeyboardSharedSceneHash = 0;
static uint64_t FLMKeyboardSharedSessionGeneration = 0;
static BOOL FLMKeyboardSharedAvoidanceVisible = NO;
static CGFloat FLMKeyboardSharedAvoidanceHeight = 0.0;
static BOOL FLMKeyboardSharedCardActive = NO;
static CGFloat FLMKeyboardSharedCardBottom = 0.0;
static CGFloat FLMKeyboardSharedCardScale = 0.0;
static CGFloat FLMKeyboardSharedCardWidth = 0.0;
static CGFloat FLMKeyboardSharedCardHeight = 0.0;
static CGFloat FLMKeyboardSharedContentViewportWidth = 0.0;
static CGFloat FLMKeyboardSharedContentViewportHeight = 0.0;
static uint64_t FLMKeyboardSharedStateGeneration = 0;
static uint64_t FLMKeyboardSharedRouteGeneration = 0;
static uint64_t FLMKeyboardSharedGeometryGeneration = 0;
static uint64_t FLMKeyboardSharedAvoidanceGeneration = 0;
static uint64_t FLMKeyboardSharedDismissRequestGeneration = 0;
static uint64_t FLMKeyboardSharedDismissSession = 0;
static uint64_t FLMKeyboardSharedDismissSessionGeneration = 0;
static uint64_t FLMKeyboardSharedDismissSceneHash = 0;
static uint64_t FLMKeyboardSharedDismissBundleHash = 0;
static pid_t FLMKeyboardSharedDismissAdapterPID = 0;
static uint64_t FLMKeyboardSharedDismissAckGeneration = 0;
static uint64_t FLMKeyboardSharedDismissAckSession = 0;
static pid_t FLMKeyboardSharedDismissAckPID = 0;
static uint64_t FLMKeyboardSharedDismissAckPhase = 0;
static uint64_t FLMKeyboardSharedDismissAckResult = 0;
static BOOL FLMKeyboardSharedStateWriteScheduled = NO;
static NSUInteger FLMKeyboardSharedStateWriteGeneration = 0;
static NSDictionary *FLMKeyboardSharedStateLastSnapshot;
static BOOL FLMKeyboardSharedStateForceWrite = YES;
static NSString *FLMKeyboardLastPublishedRouteIdentifier;
static uint64_t FLMKeyboardLastPublishedRouteSceneHash = 0;
static uint64_t FLMKeyboardLastPublishedRouteSession = 0;
static BOOL FLMKeyboardAdapterHandshakeCacheValid = NO;
static BOOL FLMKeyboardAdapterHandshakeCacheAttempted = NO;
static NSString *FLMKeyboardAdapterHandshakeCacheIdentifier;
static uint64_t FLMKeyboardAdapterHandshakeCacheSession = 0;
static pid_t FLMKeyboardAdapterHandshakeCachePID = 0;
static void FLMScheduleKeyboardSharedStateWrite(void);

static id FLMCopyPreference(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyValue((__bridge CFStringRef)key,
                                                      FLYME_PREFERENCES_DOMAIN,
                                                      kCFPreferencesCurrentUser,
                                                      kCFPreferencesAnyHost);
    return CFBridgingRelease(value);
}

static NSString *FLMSceneIdentifier(id scene) {
    if (!scene) {
        return nil;
    }
    @try {
        if ([scene respondsToSelector:@selector(sceneIdentifier)]) {
            id value = [scene sceneIdentifier];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return value;
            }
        }
        if ([scene respondsToSelector:@selector(identifier)]) {
            id value = [scene identifier];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return value;
            }
        }
        id settings = [scene respondsToSelector:@selector(settings)]
                          ? [scene settings]
                          : nil;
        if ([settings respondsToSelector:@selector(sceneIdentifier)]) {
            id value = [settings sceneIdentifier];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return value;
            }
        }
        if ([settings respondsToSelector:@selector(identifier)]) {
            id value = [settings identifier];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return value;
            }
        }
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static uint64_t FLMIdentifierHash(NSString *identifier) {
    const char *bytes = identifier.UTF8String;
    if (!bytes || bytes[0] == '\0') {
        return 0;
    }
    uint64_t value = 1469598103934665603ULL;
    for (const unsigned char *cursor = (const unsigned char *)bytes;
         *cursor;
         cursor++) {
        value ^= (uint64_t)*cursor;
        value *= 1099511628211ULL;
    }
    return value ?: 1;
}

static NSDictionary *FLMReadKeyboardSharedStateSnapshot(void) {
    NSDictionary *state =
        [NSDictionary dictionaryWithContentsOfFile:FLMKeyboardSharedStatePath];
    if (![state isKindOfClass:[NSDictionary class]]) {
        state = [NSDictionary
            dictionaryWithContentsOfFile:FLMKeyboardSharedStateRootlessPath];
    }
    return [state isKindOfClass:[NSDictionary class]] ? state : nil;
}

static uint64_t FLMNextKeyboardSharedGeneration(uint64_t generation) {
    generation += 1;
    return generation == 0 ? 1 : generation;
}

static void FLMAdvanceKeyboardSharedStateGeneration(void) {
    FLMKeyboardSharedStateGeneration =
        FLMNextKeyboardSharedGeneration(FLMKeyboardSharedStateGeneration);
}

typedef struct {
    int registerStatus;
    int readStatus;
    uint64_t rawState;
    uint16_t magic;
    uint16_t build;
    uint16_t bundleHash;
    pid_t pid;
    BOOL processAlive;
    BOOL valid;
} FLMKeyboardLifecycleEvidence;

static uint64_t FLMPackKeyboardDismissRequestState(
    uint64_t sessionGeneration,
    uint64_t requestGeneration) {
    return ((sessionGeneration & 0xFFFFFFFFULL) << 32) |
           (requestGeneration & 0xFFFFFFFFULL);
}

static uint64_t FLMPackKeyboardDismissAckState(
    uint64_t sessionGeneration,
    uint64_t requestGeneration,
    pid_t pid,
    FLMKeyboardDismissResult result) {
    return ((uint64_t)result << 56) |
           ((sessionGeneration & 0xFFFFFFULL) << 32) |
           ((requestGeneration & 0xFFFFULL) << 16) |
           ((uint64_t)pid & 0xFFFFULL);
}

static NSString *FLMKeyboardDismissResultName(FLMKeyboardDismissResult result) {
    switch (result) {
        case FLMKeyboardDismissResultNone:
            return @"none";
        case FLMKeyboardDismissResultSuccess:
            return @"success";
        case FLMKeyboardDismissResultNoResponder:
            return @"no-responder";
        case FLMKeyboardDismissResultFailed:
            return @"failed";
        case FLMKeyboardDismissResultSceneFallbackSuccess:
            return @"scene-fallback-success";
        case FLMKeyboardDismissResultStaleGeneration:
            return @"stale-generation";
        case FLMKeyboardDismissResultWrongProcess:
            return @"wrong-process";
        default:
            return @"unknown";
    }
}

static FLMKeyboardLifecycleEvidence FLMReadKeyboardLifecycleEvidence(
    const char *notificationName,
    int *token,
    uint16_t expectedMagic) {
    FLMKeyboardLifecycleEvidence evidence = {
        .registerStatus = NOTIFY_STATUS_OK,
        .readStatus = -1,
    };
    if (*token < 0) {
        evidence.registerStatus =
            notify_register_check(notificationName, token);
        if (evidence.registerStatus != NOTIFY_STATUS_OK) {
            *token = -1;
            return evidence;
        }
    }
    evidence.readStatus = notify_get_state(*token, &evidence.rawState);
    if (evidence.readStatus != NOTIFY_STATUS_OK) {
        return evidence;
    }
    evidence.magic = (uint16_t)((evidence.rawState >> 48) & 0xFFFFULL);
    evidence.build = (uint16_t)((evidence.rawState >> 32) & 0xFFFFULL);
    evidence.pid = (pid_t)((evidence.rawState >> 16) & 0xFFFFULL);
    evidence.bundleHash = (uint16_t)(evidence.rawState & 0xFFFFULL);
    errno = 0;
    evidence.processAlive =
        evidence.pid > 1 &&
        (kill(evidence.pid, 0) == 0 || errno == EPERM);
    evidence.valid = evidence.magic == expectedMagic &&
                     evidence.build == FLYME_KEYBOARD_APP_ADAPTER_BUILD &&
                     evidence.processAlive;
    return evidence;
}

static BOOL FLMLogKeyboardAdapterHandshake(NSString *context,
                                           NSString *identifier,
                                           pid_t *readyPID) {
    if (readyPID) {
        *readyPID = 0;
    }
    FLMKeyboardLifecycleEvidence ctor = FLMReadKeyboardLifecycleEvidence(
        FLYME_KEYBOARD_APP_CTOR_NOTIFICATION,
        &FlymeKeyboardAppCtorToken,
        FLYME_KEYBOARD_APP_CTOR_MAGIC);
    FLMKeyboardLifecycleEvidence ready = FLMReadKeyboardLifecycleEvidence(
        FLYME_KEYBOARD_APP_READY_NOTIFICATION,
        &FlymeKeyboardAppReadyToken,
        FLYME_KEYBOARD_APP_READY_MAGIC);
    // The wheel can target any ordinary application. The identifier is the
    // exact value published by SpringBoard; the lifecycle tokens prove that
    // this same target process loaded and completed the adapter.
    uint16_t expectedBundleHash =
        (uint16_t)(FLMIdentifierHash(identifier) & 0xFFFFULL);
    BOOL targetMatches = identifier.length > 0 && expectedBundleHash != 0;
    BOOL identityMatches =
        ctor.bundleHash == expectedBundleHash &&
        ready.bundleHash == expectedBundleHash;
    BOOL accepted = targetMatches && ctor.valid && ready.valid &&
                    identityMatches && ctor.pid == ready.pid;
    if (accepted && readyPID) {
        *readyPID = ready.pid;
    }
    FLMEnqueueDiagnosticLine(
        @"sb adapter-handshake context=%@ app=%@ bundleHash=0x%04x filter=target-bundle target-gated accepted=%d adapterPID=%d ctor={reg:%d read:%d raw:0x%016llx magic:0x%04x build:%u bundleHash:0x%04x pid:%d alive:%d valid:%d} ready={reg:%d read:%d raw:0x%016llx magic:0x%04x build:%u bundleHash:0x%04x pid:%d alive:%d valid:%d}",
        context ?: @"<none>", identifier ?: @"<none>", expectedBundleHash,
        accepted, ready.pid,
        ctor.registerStatus, ctor.readStatus,
        (unsigned long long)ctor.rawState, ctor.magic, ctor.build,
        ctor.bundleHash, ctor.pid, ctor.processAlive, ctor.valid,
        ready.registerStatus, ready.readStatus,
        (unsigned long long)ready.rawState, ready.magic, ready.build,
        ready.bundleHash, ready.pid, ready.processAlive, ready.valid);
    return accepted;
}

static BOOL FLMKeyboardAppAdapterReadyForIdentifier(NSString *identifier,
                                                     pid_t *readyPID) {
    if (readyPID) {
        *readyPID = 0;
    }
    BOOL sameRoute = FLMKeyboardAdapterHandshakeCacheAttempted &&
                     FLMKeyboardAdapterHandshakeCacheSession ==
                         FLMKeyboardSharedSessionGeneration &&
                     [FLMKeyboardAdapterHandshakeCacheIdentifier
                         isEqualToString:identifier];
    if (sameRoute) {
        if (readyPID) {
            *readyPID = FLMKeyboardAdapterHandshakeCachePID;
        }
        return FLMKeyboardAdapterHandshakeCacheValid;
    }
    pid_t adapterPID = 0;
    BOOL accepted = FLMLogKeyboardAdapterHandshake(
        @"route-publish", identifier, &adapterPID);
    FLMKeyboardAdapterHandshakeCacheAttempted = YES;
    FLMKeyboardAdapterHandshakeCacheValid = accepted;
    FLMKeyboardAdapterHandshakeCacheIdentifier = [identifier copy];
    FLMKeyboardAdapterHandshakeCacheSession =
        FLMKeyboardSharedSessionGeneration;
    FLMKeyboardAdapterHandshakeCachePID = adapterPID;
    if (readyPID) {
        *readyPID = adapterPID;
    }
    return accepted;
}

static void FLMPublishKeyboardDismissRequest(FLMKeyboardCloseContext *context) {
    if (!context || context.identifier.length == 0 ||
        context.session == 0 || context.sessionGeneration == 0 ||
        context.requestGeneration == 0) {
        return;
    }
    NSString *identifier = context.identifier;
    id scene = context.scene;
    BOOL duplicateRequest =
        FLMKeyboardSharedDismissRequestGeneration == context.requestGeneration &&
        FLMKeyboardSharedDismissSession == context.session &&
        FLMKeyboardSharedDismissSessionGeneration == context.sessionGeneration &&
        FLMKeyboardSharedDismissSceneHash == context.sceneHash &&
        FLMKeyboardSharedDismissBundleHash == context.bundleHash &&
        FLMKeyboardSharedDismissAdapterPID == context.adapterPID;
    if (duplicateRequest) {
        FLMEnqueueDiagnosticLine(
            @"sb dismiss-request ignored=pending-close session=%llu requestGeneration=%llu adapterPID=%d",
            (unsigned long long)context.session,
            (unsigned long long)context.requestGeneration,
            context.adapterPID);
        return;
    }
    // Write the reliable shared-state tuple before attempting the optional
    // Darwin compatibility token. A notify registration failure must never
    // erase the only request route.
    FLMKeyboardSharedDismissRequestGeneration = context.requestGeneration;
    FLMKeyboardSharedDismissSession = context.session;
    FLMKeyboardSharedDismissSessionGeneration = context.sessionGeneration;
    FLMKeyboardSharedDismissSceneHash = context.sceneHash;
    FLMKeyboardSharedDismissBundleHash = context.bundleHash;
    FLMKeyboardSharedDismissAdapterPID = context.adapterPID;
    FLMKeyboardSharedDismissAckGeneration = 0;
    FLMKeyboardSharedDismissAckSession = 0;
    FLMKeyboardSharedDismissAckPID = 0;
    FLMKeyboardSharedDismissAckPhase = 0;
    FLMKeyboardSharedDismissAckResult = 0;
    FLMAdvanceKeyboardSharedStateGeneration();
    FLMScheduleKeyboardSharedStateWrite();
    if (FlymeKeyboardDismissRequestToken < 0 &&
        notify_register_check(FLYME_KEYBOARD_DISMISS_REQUEST_NOTIFICATION,
                              &FlymeKeyboardDismissRequestToken) !=
            NOTIFY_STATUS_OK) {
        FLMEnqueueDiagnosticLine(
            @"sb dismiss-request publish-failed app=%@ session=%llu generation=%llu",
            identifier, (unsigned long long)context.session,
            (unsigned long long)context.requestGeneration);
        return;
    }
    uint64_t requestState = FLMPackKeyboardDismissRequestState(
        context.session, context.requestGeneration);
    notify_set_state(FlymeKeyboardDismissRequestToken, requestState);
    // The plist is the reliable request route. The Darwin payload remains as
    // a compatibility wake-up, but the application adapter validates and
    // consumes this immutable identity tuple from shared state.
    FLMPublishDiagnosticEvent(
        FLMDiagnosticRoleSpringBoard,
        FLMDiagnosticEventDismissRequest,
        context.sessionGeneration,
        (uint16_t)(context.requestGeneration & 0xFFFFULL),
        (uint16_t)(context.sceneHash & 0xFFFFULL));
    notify_post(FLYME_KEYBOARD_DISMISS_REQUEST_NOTIFICATION);
    FLMEnqueueDiagnosticLine(
        @"sb dismiss-request posted app=%@ bundleHash=0x%016llx scene=%@ sceneHash=0x%016llx session=%llu sessionGeneration=%llu requestGeneration=%llu adapterPID=%d state=0x%016llx shared-state=1",
        identifier,
        (unsigned long long)context.bundleHash,
        FLMSceneIdentifier(scene) ?: @"<none>",
        (unsigned long long)context.sceneHash,
        (unsigned long long)context.session,
        (unsigned long long)context.sessionGeneration,
        (unsigned long long)context.requestGeneration,
        context.adapterPID,
        (unsigned long long)requestState);
}

static void FLMScheduleKeyboardSharedStateWrite(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FLMKeyboardSharedStateWriterQueue = dispatch_queue_create(
            "com.codex.flymemultitasking.keyboard-shared-state",
            DISPATCH_QUEUE_SERIAL);
    });
    BOOL active = FLMKeyboardSharedIdentifier.length > 0 &&
                  FLMKeyboardSharedSessionGeneration != 0;
    NSDictionary *snapshot = @{
        @"version": @5,
        @"active": @(active),
        @"bundleID": FLMKeyboardSharedIdentifier ?: @"",
        @"sceneHash": @(FLMKeyboardSharedSceneHash),
        @"sessionGeneration": @(FLMKeyboardSharedSessionGeneration),
        @"stateGeneration": @(FLMKeyboardSharedStateGeneration),
        @"routeGeneration": @(FLMKeyboardSharedRouteGeneration),
        @"geometryGeneration": @(FLMKeyboardSharedGeometryGeneration),
        @"avoidanceGeneration": @(FLMKeyboardSharedAvoidanceGeneration),
        @"avoidanceVisible": @(FLMKeyboardSharedAvoidanceVisible),
        @"avoidanceHeight": @(FLMKeyboardSharedAvoidanceHeight),
        @"cardActive": @(FLMKeyboardSharedCardActive),
        @"cardBottom": @(FLMKeyboardSharedCardBottom),
        @"cardScale": @(FLMKeyboardSharedCardScale),
        @"cardWidth": @(FLMKeyboardSharedCardWidth),
        @"cardHeight": @(FLMKeyboardSharedCardHeight),
        @"contentViewportWidth": @(FLMKeyboardSharedContentViewportWidth),
        @"contentViewportHeight": @(FLMKeyboardSharedContentViewportHeight),
        @"dismissRequestGeneration": @(FLMKeyboardSharedDismissRequestGeneration),
        @"dismissSession": @(FLMKeyboardSharedDismissSession),
        @"dismissSessionGeneration": @(FLMKeyboardSharedDismissSessionGeneration),
        @"dismissSceneHash": @(FLMKeyboardSharedDismissSceneHash),
        @"dismissBundleHash": @(FLMKeyboardSharedDismissBundleHash),
        @"dismissAdapterPID": @(FLMKeyboardSharedDismissAdapterPID),
        @"dismissAckGeneration": @(FLMKeyboardSharedDismissAckGeneration),
        @"dismissAckSession": @(FLMKeyboardSharedDismissAckSession),
        @"dismissAckPID": @(FLMKeyboardSharedDismissAckPID),
        @"dismissAckPhase": @(FLMKeyboardSharedDismissAckPhase),
        @"dismissAckResult": @(FLMKeyboardSharedDismissAckResult),
    };
    BOOL unchanged = FLMKeyboardSharedStateLastSnapshot &&
                     [FLMKeyboardSharedStateLastSnapshot
                         isEqualToDictionary:snapshot];
    if (unchanged && !FLMKeyboardSharedStateForceWrite) {
        FLMEnqueueDiagnosticLine(
            @"sb shared-state skipped=unchanged stateGeneration=%llu",
            (unsigned long long)FLMKeyboardSharedStateGeneration);
        return;
    }
    FLMKeyboardSharedStateLastSnapshot = [snapshot copy];
    FLMKeyboardSharedStateForceWrite = NO;
    NSUInteger writeGeneration = ++FLMKeyboardSharedStateWriteGeneration;
    if (FLMKeyboardSharedStateWriteScheduled) {
        FLMEnqueueDiagnosticLine(
            @"sb shared-state dirty coalesced generation=%lu",
            (unsigned long)writeGeneration);
        return;
    }
    FLMKeyboardSharedStateWriteScheduled = YES;
    dispatch_async(FLMKeyboardSharedStateWriterQueue, ^{
        @autoreleasepool {
            NSMutableDictionary *writeState = [snapshot mutableCopy];
            writeState[@"updatedAt"] = @([[NSDate date] timeIntervalSince1970]);
            NSError *serializationError = nil;
            NSData *data = [NSPropertyListSerialization
                dataWithPropertyList:writeState
                              format:NSPropertyListBinaryFormat_v1_0
                             options:0
                               error:&serializationError];
            if (!data || serializationError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    FLMKeyboardSharedStateWriteScheduled = NO;
                    if (FLMKeyboardSharedStateWriteGeneration != writeGeneration) {
                        FLMScheduleKeyboardSharedStateWrite();
                    }
                });
                return;
            }
            NSError *writeError = nil;
            BOOL wrote = [data writeToFile:FLMKeyboardSharedStatePath
                                   options:NSDataWritingAtomic
                                     error:&writeError];
            NSString *writtenPath = nil;
            if (wrote) {
                chmod(FLMKeyboardSharedStatePath.fileSystemRepresentation, 0644);
                writtenPath = FLMKeyboardSharedStatePath;
            } else {
                writeError = nil;
                wrote = [data writeToFile:FLMKeyboardSharedStateRootlessPath
                                  options:NSDataWritingAtomic
                                    error:&writeError];
                if (wrote) {
                    chmod(
                        FLMKeyboardSharedStateRootlessPath.fileSystemRepresentation,
                        0644);
                    writtenPath = FLMKeyboardSharedStateRootlessPath;
                }
            }
            if (wrote) {
                // The notification is only a refresh signal. All routing and
                // geometry values are read from the atomically replaced file.
                notify_post(FLYME_KEYBOARD_SHARED_STATE_NOTIFICATION);
            }
            FLMEnqueueDiagnosticLine(
                @"sb shared-state write success=%d path=%@ error=%@",
                wrote, writtenPath ?: @"<none>",
                writeError.localizedDescription ?: @"<none>");
            dispatch_async(dispatch_get_main_queue(), ^{
                // A changed generation means a newer stable node was marked
                // while this snapshot was on disk. Re-queue exactly one
                // current snapshot; pan samples never call this writer.
                FLMKeyboardSharedStateWriteScheduled = NO;
                if (FLMKeyboardSharedStateWriteGeneration != writeGeneration) {
                    FLMScheduleKeyboardSharedStateWrite();
                }
            });
        }
    });
    FLMEnqueueDiagnosticLine(
        @"sb shared-state dirty=1 generation=%lu stateGeneration=%llu routeGeneration=%llu geometryGeneration=%llu avoidanceGeneration=%llu active=%d app=%@ session=%llu avoidance=%d/%.2f card=%d/%.2f/%.5f dismissRequest=%llu ack=%llu",
        (unsigned long)writeGeneration,
        (unsigned long long)FLMKeyboardSharedStateGeneration,
        (unsigned long long)FLMKeyboardSharedRouteGeneration,
        (unsigned long long)FLMKeyboardSharedGeometryGeneration,
        (unsigned long long)FLMKeyboardSharedAvoidanceGeneration,
        active, FLMKeyboardSharedIdentifier ?: @"<none>",
        (unsigned long long)FLMKeyboardSharedSessionGeneration,
        FLMKeyboardSharedAvoidanceVisible, FLMKeyboardSharedAvoidanceHeight,
        FLMKeyboardSharedCardActive, FLMKeyboardSharedCardBottom,
        FLMKeyboardSharedCardScale,
        (unsigned long long)FLMKeyboardSharedDismissRequestGeneration,
        (unsigned long long)FLMKeyboardSharedDismissAckGeneration);
}

static void FLMPublishKeyboardState(NSString *identifier,
                                    id scene,
                                    uint64_t sessionGeneration) {
    uint64_t routeHash = FLMIdentifierHash(identifier);
    uint64_t sceneHash = FLMIdentifierHash(FLMSceneIdentifier(scene));
    BOOL routeChanged =
        ![FLMKeyboardLastPublishedRouteIdentifier isEqualToString:identifier] ||
        FLMKeyboardLastPublishedRouteSceneHash != sceneHash ||
        FLMKeyboardLastPublishedRouteSession != sessionGeneration;
    BOOL forceWrite = FLMKeyboardSharedStateForceWrite;
    if (!routeChanged && !forceWrite) {
        FLMEnqueueDiagnosticLine(
            @"sb route-publish skipped=unchanged app=%@ scene=%@ session=%llu",
            identifier ?: @"<none>",
            FLMSceneIdentifier(scene) ?: @"<none>",
            (unsigned long long)sessionGeneration);
        return;
    }
    FLMKeyboardLastPublishedRouteIdentifier = [identifier copy];
    FLMKeyboardLastPublishedRouteSceneHash = sceneHash;
    FLMKeyboardLastPublishedRouteSession = sessionGeneration;
    FLMKeyboardSharedIdentifier = [identifier copy];
    FLMKeyboardSharedSceneHash = sceneHash;
    FLMKeyboardSharedSessionGeneration = sessionGeneration;
    if (routeChanged && (identifier.length == 0 || sessionGeneration == 0)) {
        FLMKeyboardSharedAvoidanceVisible = NO;
        FLMKeyboardSharedAvoidanceHeight = 0.0;
        FLMKeyboardSharedCardActive = NO;
        FLMKeyboardSharedCardBottom = 0.0;
        FLMKeyboardSharedCardScale = 0.0;
        FLMKeyboardSharedCardWidth = 0.0;
        FLMKeyboardSharedCardHeight = 0.0;
        FLMKeyboardSharedContentViewportWidth = 0.0;
        FLMKeyboardSharedContentViewportHeight = 0.0;
        FLMKeyboardSharedDismissRequestGeneration = 0;
        FLMKeyboardSharedDismissSession = 0;
        FLMKeyboardSharedDismissSessionGeneration = 0;
        FLMKeyboardSharedDismissSceneHash = 0;
        FLMKeyboardSharedDismissBundleHash = 0;
        FLMKeyboardSharedDismissAdapterPID = 0;
        FLMKeyboardSharedDismissAckGeneration = 0;
        FLMKeyboardSharedDismissAckSession = 0;
        FLMKeyboardSharedDismissAckPID = 0;
        FLMKeyboardSharedDismissAckPhase = 0;
        FLMKeyboardSharedDismissAckResult = 0;
    }
    if (routeChanged) {
        FLMKeyboardSharedRouteGeneration = FLMNextKeyboardSharedGeneration(
            FLMKeyboardSharedRouteGeneration);
        FLMAdvanceKeyboardSharedStateGeneration();
        // A new app Scene/session starts with a clean stable-node baseline.
        if (identifier.length > 0 && sessionGeneration != 0) {
            FLMKeyboardSharedAvoidanceVisible = NO;
            FLMKeyboardSharedAvoidanceHeight = 0.0;
            FLMKeyboardSharedCardActive = NO;
            FLMKeyboardSharedCardBottom = 0.0;
            FLMKeyboardSharedCardScale = 0.0;
            FLMKeyboardSharedCardWidth = 0.0;
            FLMKeyboardSharedCardHeight = 0.0;
            FLMKeyboardSharedContentViewportWidth = 0.0;
            FLMKeyboardSharedContentViewportHeight = 0.0;
        }
    } else if (forceWrite) {
        FLMAdvanceKeyboardSharedStateGeneration();
    }
    FLMScheduleKeyboardSharedStateWrite();
    if (FlymeKeyboardRouteToken < 0 &&
        notify_register_check(FLYME_KEYBOARD_NOTIFICATION,
                              &FlymeKeyboardRouteToken) != NOTIFY_STATUS_OK) {
        FlymeKeyboardRouteToken = -1;
    }
    if (FlymeKeyboardSceneToken < 0) {
        notify_register_check(FLYME_KEYBOARD_SCENE_NOTIFICATION,
                              &FlymeKeyboardSceneToken);
    }
    if (FlymeKeyboardSessionToken < 0) {
        notify_register_check(FLYME_KEYBOARD_SESSION_NOTIFICATION,
                              &FlymeKeyboardSessionToken);
    }
    if (FlymeKeyboardRouteToken >= 0) {
        notify_set_state(FlymeKeyboardRouteToken, routeHash);
    }
    if (FlymeKeyboardSceneToken >= 0) {
        notify_set_state(FlymeKeyboardSceneToken, sceneHash);
    }
    if (FlymeKeyboardSessionToken >= 0) {
        notify_set_state(FlymeKeyboardSessionToken, sessionGeneration);
    }
    if (FlymeKeyboardRouteToken >= 0) {
        notify_post(FLYME_KEYBOARD_NOTIFICATION);
    }
    FLMEnqueueDiagnosticLine(
        @"sb route-publish once=1 routeGeneration=%llu app=%@ scene=%@ session=%llu routeHash=0x%llx sceneHash=0x%llx routeChannel=global fanout=global",
        (unsigned long long)FLMKeyboardSharedRouteGeneration,
        identifier ?: @"<none>", FLMSceneIdentifier(scene) ?: @"<none>",
        (unsigned long long)sessionGeneration,
        (unsigned long long)routeHash,
        (unsigned long long)sceneHash);
    if (identifier.length > 0 && sessionGeneration != 0) {
        // The adapter may publish its Ready token on the next main-loop turn.
        // Probe once after route publication; presenter polling never calls
        // this path and therefore cannot create an IPC/handshake storm.
        NSString *handshakeIdentifier = [identifier copy];
        uint64_t handshakeSession = sessionGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.08 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (FLMKeyboardSharedSessionGeneration == handshakeSession &&
                [FLMKeyboardSharedIdentifier
                    isEqualToString:handshakeIdentifier]) {
                FLMKeyboardAppAdapterReadyForIdentifier(
                    handshakeIdentifier, NULL);
            }
        });
    }
}

static void FLMPublishKeyboardAvoidance(uint64_t sessionGeneration,
                                        CGFloat keyboardHeight,
                                        BOOL visible) {
    if (sessionGeneration == 0) {
        return;
    }
    // Adapter readiness is sampled once per keyboard session by the controller.
    // Avoidance publication is a stable state node and must not perform a
    // notify handshake for every keyboard frame.
    BOOL effectiveVisible = visible;
    CGFloat height = effectiveVisible ? MAX(0.0, keyboardHeight) : 0.0;
    BOOL unchanged =
        FLMKeyboardSharedSessionGeneration == sessionGeneration &&
        FLMKeyboardSharedAvoidanceVisible == effectiveVisible &&
        fabs(FLMKeyboardSharedAvoidanceHeight - height) <= 0.25;
    if (unchanged) {
        return;
    }
    FLMKeyboardSharedAvoidanceVisible = effectiveVisible;
    FLMKeyboardSharedAvoidanceHeight = height;
    FLMKeyboardSharedAvoidanceGeneration = FLMNextKeyboardSharedGeneration(
        FLMKeyboardSharedAvoidanceGeneration);
    FLMAdvanceKeyboardSharedStateGeneration();
    FLMScheduleKeyboardSharedStateWrite();
    if (FlymeKeyboardAvoidanceToken < 0 &&
        notify_register_check(FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION,
                              &FlymeKeyboardAvoidanceToken) != NOTIFY_STATUS_OK) {
        FlymeKeyboardAvoidanceToken = -1;
    }
    uint64_t encodedHeight =
        MIN(0xFFFFFFULL, (uint64_t)llround(height * 100.0));
    uint64_t encodedGeneration =
        (sessionGeneration & 0x7FFFFFFFFFULL) << 24;
    uint64_t state = (effectiveVisible ? (1ULL << 63) : 0) |
                     encodedGeneration | encodedHeight;
    if (FlymeKeyboardAvoidanceToken >= 0) {
        notify_set_state(FlymeKeyboardAvoidanceToken, state);
        notify_post(FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION);
    }
    FLMEnqueueDiagnosticLine(
        @"sb avoidance-publish generation=%llu session=%llu requested=%d visible=%d height=%.2f adapterReady=deferred adapterPID=deferred state=0x%llx",
        (unsigned long long)FLMKeyboardSharedAvoidanceGeneration,
        (unsigned long long)sessionGeneration, visible, effectiveVisible,
        height, (unsigned long long)state);
}

static void FLMPublishKeyboardCardGeometry(uint64_t sessionGeneration,
                                           CGFloat cardBottom,
                                           CGFloat visualScale,
                                           CGFloat cardWidth,
                                           CGFloat cardHeight,
                                           BOOL active) {
    BOOL hasCardDimensions = cardWidth > 1.0 && cardHeight > 1.0;
    BOOL nextActive = active && sessionGeneration != 0 &&
                      cardBottom > 1.0 && visualScale > 0.05 &&
                      hasCardDimensions;
    CGFloat nextBottom = nextActive ? cardBottom : 0.0;
    CGFloat nextScale = nextActive ? visualScale : 0.0;
    CGFloat nextWidth = nextActive ? MAX(0.0, cardWidth) : 0.0;
    CGFloat nextHeight = nextActive ? MAX(0.0, cardHeight) : 0.0;
    CGFloat nextViewportWidth = nextActive ? FLMVirtualViewportWidth : 0.0;
    CGFloat nextViewportHeight = nextActive && visualScale > 0.05
                                     ? nextHeight / visualScale
                                     : 0.0;
    BOOL unchanged = FLMKeyboardSharedSessionGeneration == sessionGeneration &&
                     FLMKeyboardSharedCardActive == nextActive &&
                     fabs(FLMKeyboardSharedCardBottom - nextBottom) <= 0.25 &&
                     fabs(FLMKeyboardSharedCardScale - nextScale) <= 0.0005 &&
                     fabs(FLMKeyboardSharedCardWidth - nextWidth) <= 0.25 &&
                     fabs(FLMKeyboardSharedCardHeight - nextHeight) <= 0.25 &&
                     fabs(FLMKeyboardSharedContentViewportWidth -
                          nextViewportWidth) <= 0.25 &&
                     fabs(FLMKeyboardSharedContentViewportHeight -
                          nextViewportHeight) <= 0.25;
    if (unchanged) {
        return;
    }
    FLMKeyboardSharedCardActive = nextActive;
    FLMKeyboardSharedCardBottom = nextBottom;
    FLMKeyboardSharedCardScale = nextScale;
    FLMKeyboardSharedCardWidth = nextWidth;
    FLMKeyboardSharedCardHeight = nextHeight;
    FLMKeyboardSharedContentViewportWidth = nextViewportWidth;
    FLMKeyboardSharedContentViewportHeight = nextViewportHeight;
    FLMKeyboardSharedGeometryGeneration = FLMNextKeyboardSharedGeneration(
        FLMKeyboardSharedGeometryGeneration);
    FLMAdvanceKeyboardSharedStateGeneration();
    FLMScheduleKeyboardSharedStateWrite();
    if (FlymeKeyboardCardGeometryToken < 0 &&
        notify_register_check(FLYME_KEYBOARD_CARD_GEOMETRY_NOTIFICATION,
                              &FlymeKeyboardCardGeometryToken) !=
            NOTIFY_STATUS_OK) {
        FlymeKeyboardCardGeometryToken = -1;
    }
    uint64_t state = 0;
    if (FLMKeyboardSharedCardActive) {
        uint64_t generation = (sessionGeneration & 0x7FFFULL) << 48;
        uint64_t encodedBottom =
            MIN(0xFFFFFFULL, (uint64_t)llround(cardBottom * 100.0)) << 24;
        uint64_t encodedScale =
            MIN(0xFFFFFFULL, (uint64_t)llround(visualScale * 1000000.0));
        state = (1ULL << 63) | generation | encodedBottom | encodedScale;
    }
    if (FlymeKeyboardCardGeometryToken >= 0) {
        notify_set_state(FlymeKeyboardCardGeometryToken, state);
        notify_post(FLYME_KEYBOARD_CARD_GEOMETRY_NOTIFICATION);
    }
    FLMEnqueueDiagnosticLine(
        @"sb geometry-publish generation=%llu session=%llu active=%d bottom=%.2f scale=%.5f card={%.2f,%.2f} viewport={%.2f,%.2f} state=0x%llx",
        (unsigned long long)FLMKeyboardSharedGeometryGeneration,
        (unsigned long long)sessionGeneration, active, cardBottom, visualScale,
        FLMKeyboardSharedCardWidth, FLMKeyboardSharedCardHeight,
        FLMKeyboardSharedContentViewportWidth,
        FLMKeyboardSharedContentViewportHeight,
        (unsigned long long)state);
}

static UIWindowScene *FLMForegroundWindowScene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                return (UIWindowScene *)scene;
            }
        }
    }
    return nil;
}

static UIWindow *FLMCurrentKeyWindow(void) {
    UIWindowScene *scene = FLMForegroundWindowScene();
    if (@available(iOS 13.0, *)) {
        for (UIWindow *window in scene.windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    return nil;
}

static UIWindow *FLMCreateWindow(CGRect frame) {
    UIWindowScene *scene = FLMForegroundWindowScene();
    if (@available(iOS 13.0, *)) {
        if (scene) {
            FLMOverlayWindow *window = [[FLMOverlayWindow alloc] initWithWindowScene:scene];
            window.frame = frame;
            return window;
        }
    }
    return [[FLMOverlayWindow alloc] initWithFrame:frame];
}

static FLMFloatingWindow *FLMCreateFloatingWindow(CGRect frame) {
    UIWindowScene *scene = FLMForegroundWindowScene();
    if (@available(iOS 13.0, *)) {
        if (scene) {
            FLMFloatingWindow *window =
                [[FLMFloatingWindow alloc] initWithWindowScene:scene];
            window.frame = frame;
            return window;
        }
    }
    return [[FLMFloatingWindow alloc] initWithFrame:frame];
}

static FLMDockTouchGateWindow *FLMCreateDockTouchGateWindow(CGRect frame) {
    UIWindowScene *scene = FLMForegroundWindowScene();
    if (@available(iOS 13.0, *)) {
        if (scene) {
            FLMDockTouchGateWindow *window =
                [[FLMDockTouchGateWindow alloc] initWithWindowScene:scene];
            window.frame = frame;
            return window;
        }
    }
    return [[FLMDockTouchGateWindow alloc] initWithFrame:frame];
}

static FLMHotspotWindow *FLMCreateHotspotWindow(CGRect frame) {
    UIWindowScene *scene = FLMForegroundWindowScene();
    if (@available(iOS 13.0, *)) {
        if (scene) {
            FLMHotspotWindow *window =
                [[FLMHotspotWindow alloc] initWithWindowScene:scene];
            window.frame = frame;
            return window;
        }
    }
    return [[FLMHotspotWindow alloc] initWithFrame:frame];
}

static FLMHomeDockWindow *FLMCreateHomeDockWindow(CGRect frame) {
    UIWindowScene *scene = FLMForegroundWindowScene();
    if (@available(iOS 13.0, *)) {
        if (scene) {
            FLMHomeDockWindow *window =
                [[FLMHomeDockWindow alloc] initWithWindowScene:scene];
            window.frame = frame;
            return window;
        }
    }
    return [[FLMHomeDockWindow alloc] initWithFrame:frame];
}

static UIImage *FLMLockImage(void) {
    UIImage *image = [UIImage systemImageNamed:@"lock.fill"];
    return [image imageWithTintColor:[UIColor whiteColor]
                       renderingMode:UIImageRenderingModeAlwaysOriginal];
}

static UIImage *FLMApplicationIcon(NSString *bundleIdentifier) {
    if ([bundleIdentifier isEqualToString:FLYME_LOCK_SCREEN_ITEM]) {
        return FLMLockImage();
    }
    if ([UIImage respondsToSelector:
                     @selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        UIImage *image = [UIImage _applicationIconImageForBundleIdentifier:bundleIdentifier
                                                                    format:2
                                                                     scale:[UIScreen mainScreen].scale];
        if (image) {
            return image;
        }
    }
    return [UIImage systemImageNamed:@"app.fill"];
}

static void FLMPreferencesChanged(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[FLMWheelController sharedController] reloadPreferences];
    });
}

@implementation FLMWheelController

+ (instancetype)sharedController {
    static FLMWheelController *controller = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [[self alloc] init];
    });
    return controller;
}

- (void)start {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        FLMPreferencesChanged,
                                        FLYME_PREFERENCES_NOTIFICATION,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(protectedSceneDidDisappear:)
                   name:FLMProtectedSceneDidDisappearNotification
                 object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(keyboardFrameWillChange:)
                   name:UIKeyboardWillChangeFrameNotification
                 object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(keyboardDidHide:)
                   name:UIKeyboardDidHideNotification
                 object:nil];
        if (notify_register_dispatch(
                FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION,
                &FlymeKeyboardDismissAckToken,
                dispatch_get_main_queue(),
                ^(int token) {
                    [[FLMWheelController sharedController]
                        handleApplicationDismissAck:token];
                }) != NOTIFY_STATUS_OK) {
            FlymeKeyboardDismissAckToken = -1;
        }
        if (notify_register_dispatch(
                FLYME_KEYBOARD_SHARED_STATE_NOTIFICATION,
                &FlymeKeyboardSharedStateToken,
                dispatch_get_main_queue(),
                ^(__unused int token) {
                    [[FLMWheelController sharedController]
                        handleKeyboardSharedStateUpdate];
                }) != NOTIFY_STATUS_OK) {
            FlymeKeyboardSharedStateToken = -1;
        }
        self.lastPortraitKeyboardHeight = 291.0;
        self.floatingKeyboardFrame = CGRectNull;
        // Dock presentation width is session-local. Every new dock transition
        // starts from the configured minimum size instead of restoring stale geometry.
        self.floatingDockWidth = FLMDefaultDockWidth;
        self.floatingDockedOnRight = YES;
        // Clear a route left by a previous SpringBoard generation before any
        // application-side UIKit adapter is allowed to change geometry.
        FLMPublishKeyboardState(nil, nil, 0);
        [self createWindows];
        [self reloadPreferences];
    });
}

- (void)createWindows {
    CGRect bounds = FLMVisualScreenBounds();
    self.overlayWindow = (FLMOverlayWindow *)FLMCreateWindow(bounds);
    self.overlayWindow.windowLevel = UIWindowLevelAlert + 91.0;
    self.overlayWindow.backgroundColor = [UIColor clearColor];
    self.overlayWindow.userInteractionEnabled = NO;
    self.overlayWindow.rootViewController = [[FLMOverlayViewController alloc] init];
    self.overlayWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.overlayWindow.hidden = YES;

    self.wheelContainer = [[UIView alloc] initWithFrame:bounds];
    self.wheelContainer.userInteractionEnabled = YES;
    [self.overlayWindow.rootViewController.view addSubview:self.wheelContainer];

    self.wheelTapGesture =
        [[UITapGestureRecognizer alloc] initWithTarget:self
                                               action:@selector(handleWheelTap:)];
    self.wheelTapGesture.cancelsTouchesInView = YES;
    self.wheelTapGesture.delaysTouchesEnded = NO;
    [self.overlayWindow.rootViewController.view addGestureRecognizer:self.wheelTapGesture];

    [self createFloatingWindow];

    self.floatingDockTouchGateWindow = FLMCreateDockTouchGateWindow(bounds);
    // Stay below the wheel hotspot window, but above application and remote
    // presenter surfaces.  The gate's hit-test returns nil outside the dock
    // card and corner trigger, so it does not become a full-screen blocker.
    self.floatingDockTouchGateWindow.windowLevel = UIWindowLevelAlert + 119.0;
    self.floatingDockTouchGateWindow.backgroundColor = [UIColor clearColor];
    self.floatingDockTouchGateWindow.userInteractionEnabled = NO;
    self.floatingDockTouchGateWindow.rootViewController =
        [[FLMOverlayViewController alloc] init];
    self.floatingDockTouchGateWindow.rootViewController.view.backgroundColor =
        [UIColor clearColor];
    self.floatingDockTouchGateWindow.hidden = YES;

    self.hotspotWindow = FLMCreateHotspotWindow(bounds);
    // This transparent window is the wheel's arbitration boundary. It only
    // hit-tests the four corner ellipses, but it stays above the floating card
    // and keyboard forwarding windows so those routes cannot win first.
    self.hotspotWindow.windowLevel = UIWindowLevelAlert + 120.0;
    self.hotspotWindow.backgroundColor = [UIColor clearColor];
    UIViewController *hotspotController = [[UIViewController alloc] init];
    hotspotController.view.backgroundColor = [UIColor clearColor];
    self.hotspotWindow.rootViewController = hotspotController;

    // Bottom-center home-dock zone. The recognizer must live on this window's
    // view (UIKit in-window arbitration, not the system gesture manager) so a
    // recognized long-press gates the real home gesture off instead of losing
    // the arbitration race against it. The hit-test re-validates every touch.
    self.homeDockWindow = FLMCreateHomeDockWindow(bounds);
    self.homeDockWindow.windowLevel = UIWindowLevelAlert + 90.0;
    self.homeDockWindow.backgroundColor = [UIColor clearColor];
    UIViewController *homeDockController = [[UIViewController alloc] init];
    homeDockController.view.backgroundColor = [UIColor clearColor];
    self.homeDockWindow.rootViewController = homeDockController;

    self.cornerGesture =
        [[FLMCornerGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(handleCornerGesture:)];
    self.cornerGesture.delegate = self;
    self.cornerGesture.cancelsTouchesInView = YES;
    self.cornerGesture.numberOfTouchesRequired = 1;
    self.cornerGesture.minimumPressDuration = 0.12;
    self.cornerGesture.allowableMovement = CGFLOAT_MAX;

    self.cornerGuardGesture =
        [[FLMCornerGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleCornerGuardGesture:)];
    self.cornerGuardGesture.delegate = self;
    self.cornerGuardGesture.cancelsTouchesInView = YES;
    self.cornerGuardGesture.delaysTouchesBegan = NO;
    self.cornerGuardGesture.delaysTouchesEnded = NO;
    self.cornerGuardGesture.numberOfTouchesRequired = 1;
    self.cornerGuardGesture.minimumPressDuration = 0.0;
    self.cornerGuardGesture.allowableMovement = CGFLOAT_MAX;

    // A second wheel pair attached to the floating window itself. The system
    // gesture manager pair can be arbitrated away by the card gestures when a
    // card is up, and shouldReceiveTouch: is not reliably consulted for
    // system-manager gestures. In-window recognizers always run UIKit's
    // standard delegate arbitration, so the wheel keeps its corner in every
    // card mode: centered (the window owns the whole screen), docked and
    // hidden (the window hit-tests the corner trigger before pass-through).
    self.floatingCornerGuardGesture =
        [[FLMCornerGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleCornerGuardGesture:)];
    self.floatingCornerGuardGesture.delegate = self;
    self.floatingCornerGuardGesture.cancelsTouchesInView = YES;
    self.floatingCornerGuardGesture.delaysTouchesBegan = NO;
    self.floatingCornerGuardGesture.delaysTouchesEnded = NO;
    self.floatingCornerGuardGesture.numberOfTouchesRequired = 1;
    self.floatingCornerGuardGesture.minimumPressDuration = 0.0;
    self.floatingCornerGuardGesture.allowableMovement = CGFLOAT_MAX;
    [self.floatingWindow.rootViewController.view
        addGestureRecognizer:self.floatingCornerGuardGesture];

    self.floatingCornerGesture =
        [[FLMCornerGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleCornerGesture:)];
    self.floatingCornerGesture.delegate = self;
    self.floatingCornerGesture.cancelsTouchesInView = YES;
    self.floatingCornerGesture.numberOfTouchesRequired = 1;
    self.floatingCornerGesture.minimumPressDuration = 0.12;
    self.floatingCornerGesture.allowableMovement = CGFLOAT_MAX;
    [self.floatingWindow.rootViewController.view
        addGestureRecognizer:self.floatingCornerGesture];

    self.modalGesture =
        [[FLMCornerGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(handleModalGesture:)];
    self.modalGesture.delegate = self;
    self.modalGesture.cancelsTouchesInView = YES;
    self.modalGesture.numberOfTouchesRequired = 1;
    self.modalGesture.minimumPressDuration = 0.0;
    self.modalGesture.allowableMovement = CGFLOAT_MAX;
    self.modalGesture.enabled = NO;

    self.floatingExclusiveGesture =
        [[FLMCornerGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingExclusiveGesture:)];
    self.floatingExclusiveGesture.delegate = self;
    // The system-wide recognizer only accepts touches that began outside the
    // card/handle/keyboard domain. Once accepted it must consume that outside
    // tap so the Home Screen does not also activate an icon underneath.
    self.floatingExclusiveGesture.cancelsTouchesInView = YES;
    self.floatingExclusiveGesture.delaysTouchesBegan = NO;
    self.floatingExclusiveGesture.delaysTouchesEnded = NO;
    self.floatingExclusiveGesture.numberOfTouchesRequired = 1;
    self.floatingExclusiveGesture.minimumPressDuration = 0.0;
    self.floatingExclusiveGesture.allowableMovement = CGFLOAT_MAX;
    self.floatingExclusiveGesture.enabled = NO;

    self.floatingDockInputGesture =
        [[FLMCornerGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingDockInputGesture:)];
    self.floatingDockInputGesture.delegate = self;
    self.floatingDockInputGesture.cancelsTouchesInView = YES;
    // The global route remains the cross-Scene input path.  The transparent
    // gate window is a second, physical hit-test boundary when SpringBoard's
    // active window Scene can sit above the remote presenter.
    self.floatingDockInputGesture.delaysTouchesBegan = YES;
    self.floatingDockInputGesture.delaysTouchesEnded = NO;
    self.floatingDockInputGesture.numberOfTouchesRequired = 1;
    self.floatingDockInputGesture.minimumPressDuration = 0.0;
    self.floatingDockInputGesture.allowableMovement = CGFLOAT_MAX;
    self.floatingDockInputGesture.enabled = NO;
    __weak typeof(self) weakSelf = self;
    self.floatingDockInputGesture.flmTouchStateDidChange = ^{
        [weakSelf floatingDockInputRecognizerTouchStateDidChange];
    };

    // Docks the frontmost app from the bottom-center home-indicator zone. The
    // system home gesture wins any swipe that starts moving quickly; only a
    // stationary press (long-press) beats it, then the upward drag past the
    // swipe threshold grabs the frontmost app into the upper-right dock. The
    // recognizer lives on the dedicated zone window: once it begins, UIKit's
    // gate makes the system home gesture fail, which the system gesture
    // manager pair (0.8.68) could not do.
    self.homeDockGesture =
        [[FLMDockGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleHomeDockGesture:)];
    self.homeDockGesture.delegate = self;
    self.homeDockGesture.cancelsTouchesInView = YES;
    self.homeDockGesture.delaysTouchesBegan = NO;
    self.homeDockGesture.delaysTouchesEnded = NO;
    [self.homeDockWindow.rootViewController.view
        addGestureRecognizer:self.homeDockGesture];

    self.usesSystemGestureManager = [self registerGlobalCornerGesture];
    if (!self.usesSystemGestureManager) {
        // The private manager is the only route that follows touches across
        // application Scenes. The transparent window is a fallback for
        // systems where that private registration API is unavailable.
        [self.hotspotWindow.rootViewController.view
            addGestureRecognizer:self.cornerGuardGesture];
        [self.hotspotWindow.rootViewController.view
            addGestureRecognizer:self.cornerGesture];
        [self.floatingDockTouchGateWindow.rootViewController.view
            addGestureRecognizer:self.floatingDockInputGesture];
    }
    [self updateWindowFrames];
    FLMEnqueueDiagnosticLine(
        @"sb dock-input-route primary=%@ physicalGateWindow=1 level=%.1f",
        self.usesSystemGestureManager ? @"system-manager" : @"gate-window",
        self.floatingDockTouchGateWindow.windowLevel);
}

- (void)createFloatingWindow {
    CGRect bounds = FLMVisualScreenBounds();
    self.contentViewportCommitted = NO;
    self.floatingKeyboardPresentationSuspendedForDock = NO;
    self.floatingKeyboardAvoidancePublishDeferred = NO;
    self.floatingWindow = FLMCreateFloatingWindow(bounds);
    self.floatingWindow.windowLevel = UIWindowLevelAlert + 92.0;
    self.floatingWindow.backgroundColor = [UIColor clearColor];
    self.floatingWindow.rootViewController = [[FLMOverlayViewController alloc] init];
    self.floatingWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.floatingWindow.hidden = YES;
    ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame = CGRectNull;

    // Presentation hierarchy: ShadowContainer -> ClipContainer ->
    // RemoteSceneHost. Dock and snap operations move the outer presentation
    // layer only; the remote Scene keeps its logical bounds and is never
    // resized from the interactive display-link path.
    self.floatingDimView = [[UIView alloc] initWithFrame:bounds];
    self.floatingDimView.backgroundColor =
        [UIColor colorWithWhite:0.0 alpha:0.12];
    [self.floatingWindow.rootViewController.view addSubview:self.floatingDimView];

    // ShadowContainer: visual-only sibling behind the ClipContainer.
    self.floatingDockShadowView = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingDockShadowView.backgroundColor =
        [UIColor colorWithWhite:0.0 alpha:0.01];
    self.floatingDockShadowView.userInteractionEnabled = NO;
    self.floatingDockShadowView.hidden = YES;
    self.floatingDockShadowView.alpha = 0.0;
    self.floatingDockShadowView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.floatingDockShadowView.layer.shadowOpacity = 0.18;
    self.floatingDockShadowView.layer.shadowRadius = 14.0;
    self.floatingDockShadowView.layer.shadowOffset = CGSizeMake(0.0, 3.0);
    [self.floatingWindow.rootViewController.view
        addSubview:self.floatingDockShadowView];

    // ClipContainer: the only layer whose position/transform changes during
    // Dock interaction; corner clipping contains the RemoteSceneHost.
    self.floatingContainer = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingContainer.backgroundColor = [UIColor blackColor];
    self.floatingContainer.layer.cornerRadius = 22.0;
    self.floatingContainer.layer.masksToBounds = YES;
    [self.floatingWindow.rootViewController.view addSubview:self.floatingContainer];

    self.floatingStatusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.floatingStatusLabel.text = @"正在打开…";
    self.floatingStatusLabel.textAlignment = NSTextAlignmentCenter;
    self.floatingStatusLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    self.floatingStatusLabel.font = [UIFont systemFontOfSize:15.0
                                                     weight:UIFontWeightMedium];
    self.floatingStatusLabel.hidden = YES;
    [self.floatingContainer addSubview:self.floatingStatusLabel];

    self.floatingLaunchCoverView = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingLaunchCoverView.backgroundColor =
        [UIColor secondarySystemBackgroundColor];
    self.floatingLaunchCoverView.hidden = YES;
    self.floatingLaunchCoverView.userInteractionEnabled = NO;
    [self.floatingContainer addSubview:self.floatingLaunchCoverView];

    self.floatingLaunchIconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.floatingLaunchIconView.contentMode = UIViewContentModeScaleAspectFit;
    self.floatingLaunchIconView.layer.cornerRadius = 16.0;
    self.floatingLaunchIconView.layer.masksToBounds = YES;
    [self.floatingLaunchCoverView addSubview:self.floatingLaunchIconView];

    self.floatingDockInteractionShield = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingDockInteractionShield.backgroundColor = [UIColor clearColor];
    self.floatingDockInteractionShield.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.floatingDockInteractionShield.hidden = YES;
    self.floatingDockInteractionShield.userInteractionEnabled = NO;
    [self.floatingContainer addSubview:self.floatingDockInteractionShield];

    self.floatingHandle = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingHandle.backgroundColor = [UIColor clearColor];
    self.floatingHandleBar = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingHandleBar.backgroundColor =
        [UIColor colorWithWhite:1.0 alpha:0.72];
    self.floatingHandleBar.layer.cornerRadius = 2.5;
    self.floatingHandleBar.userInteractionEnabled = NO;
    [self.floatingHandle addSubview:self.floatingHandleBar];
    [self.floatingWindow.rootViewController.view addSubview:self.floatingHandle];

    // Keep the resize interaction as a transparent hit target.  The previous
    // L-shaped CAShapeLayer was only a visual affordance and is intentionally
    // not recreated.
    self.floatingResizeHandle = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingResizeHandle.backgroundColor = [UIColor clearColor];
    self.floatingResizeHandle.hidden = YES;
    self.floatingResizeHandle.userInteractionEnabled = YES;
    [self.floatingWindow.rootViewController.view
        addSubview:self.floatingResizeHandle];

    self.floatingBackdropTap =
        [[FLMOutsideTapGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingBackdropTap:)];
    self.floatingBackdropTap.protectedView = self.floatingContainer;
    self.floatingBackdropTap.secondaryProtectedView = self.floatingHandle;
    self.floatingBackdropTap.delegate = self;
    [self.floatingWindow.rootViewController.view
        addGestureRecognizer:self.floatingBackdropTap];

    self.floatingHandlePress =
        [[UILongPressGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingHandlePress:)];
    self.floatingHandlePress.minimumPressDuration = 0.12;
    self.floatingHandlePress.allowableMovement = CGFLOAT_MAX;
    self.floatingHandlePress.cancelsTouchesInView = YES;
    [self.floatingHandle addGestureRecognizer:self.floatingHandlePress];

    self.floatingHandleTap =
        [[UITapGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingHandleTap:)];
    self.floatingHandleTap.cancelsTouchesInView = YES;
    [self.floatingHandleTap
        requireGestureRecognizerToFail:self.floatingHandlePress];
    [self.floatingHandle addGestureRecognizer:self.floatingHandleTap];
    self.floatingHandle.userInteractionEnabled = YES;

    self.floatingDockDragPress =
        [[UILongPressGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingDockDragPress:)];
    self.floatingDockDragPress.minimumPressDuration = 0.10;
    self.floatingDockDragPress.allowableMovement = CGFLOAT_MAX;
    self.floatingDockDragPress.cancelsTouchesInView = YES;
    self.floatingDockDragPress.enabled = NO;
    [self.floatingDockInteractionShield
        addGestureRecognizer:self.floatingDockDragPress];

    FLMFloatingWindow *floatingWindow =
        (FLMFloatingWindow *)self.floatingWindow;
    floatingWindow.floatingContentView = self.floatingContainer;
    floatingWindow.floatingPrimaryControlView = self.floatingHandle;
    floatingWindow.floatingSecondaryControlView = self.floatingResizeHandle;
    [self layoutFloatingWindow];
}

- (BOOL)registerGlobalCornerGesture {
    Class managerClass = NSClassFromString(@"_UISystemGestureManager");
    FLMSystemGestureManager *manager =
        (FLMSystemGestureManager *)[managerClass sharedInstance];
    FLMDisplayConfiguration *displayConfiguration =
        [[UIScreen mainScreen] displayConfiguration];
    id identity = [displayConfiguration identity];
    SEL registrationSelector =
        @selector(addGestureRecognizer:toDisplayWithIdentity:);
    if (!manager || !identity || ![manager respondsToSelector:registrationSelector]) {
        return NO;
    }

    // Keep the wheel pair in the private system gesture manager so it remains
    // global while another application's Scene is frontmost. The floating
    // window owns a second pair for centered/docked card-local arbitration.
    [manager addGestureRecognizer:self.cornerGuardGesture
            toDisplayWithIdentity:identity];
    [manager addGestureRecognizer:self.cornerGesture toDisplayWithIdentity:identity];
    [manager addGestureRecognizer:self.modalGesture toDisplayWithIdentity:identity];
    [manager addGestureRecognizer:self.floatingExclusiveGesture
            toDisplayWithIdentity:identity];
    [manager addGestureRecognizer:self.floatingDockInputGesture
            toDisplayWithIdentity:identity];
    self.systemGestureManager = manager;
    self.displayIdentity = identity;
    return YES;
}

- (void)reloadPreferences {
    CFPreferencesSynchronize(FLYME_PREFERENCES_DOMAIN,
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);
    id enabledValue = FLMCopyPreference(@"enabled");
    id itemsValue = FLMCopyPreference(@"wheelItems");
    id radiusValue = FLMCopyPreference(@"wheelRadius");
    id iconSizeValue = FLMCopyPreference(@"wheelIconSize");
    // Use a new key so values left by the retired experimental implementation
    // cannot change the restored 58x65 default after this upgrade.
    id cornerTriggerSizeValue = FLMCopyPreference(@"cornerTriggerSizeV2");
    id centeredCardWidthValue = FLMCopyPreference(@"centeredCardWidth");
    id centeredCardTopCropValue = FLMCopyPreference(@"centeredCardTopCrop");
    id centeredCardBottomCropValue = FLMCopyPreference(@"centeredCardBottomCrop");
    id centeredDockSwipeThresholdValue =
        FLMCopyPreference(@"centeredDockSwipeThreshold");
    id dockedShrinkAmountValue = FLMCopyPreference(@"dockedShrinkAmount");
    self.enabled = [enabledValue isKindOfClass:[NSNumber class]] && [enabledValue boolValue];
    NSArray *configuredItems =
        [itemsValue isKindOfClass:[NSArray class]] ? itemsValue : @[];
    NSMutableArray<NSString *> *runtimeItems =
        [NSMutableArray arrayWithCapacity:configuredItems.count];
    for (id candidate in configuredItems) {
        if (![candidate isKindOfClass:[NSString class]] ||
            [(NSString *)candidate length] == 0 ||
            [(NSString *)candidate isEqualToString:
                FLMRemovedLegacyWheelItemIdentifier]) {
            continue;
        }
        [runtimeItems addObject:(NSString *)candidate];
    }
    self.itemIdentifiers = [runtimeItems copy];
    CGFloat requestedRadius =
        [radiusValue isKindOfClass:[NSNumber class]]
            ? [radiusValue doubleValue]
            : FLMDefaultWheelRadius;
    CGFloat requestedIconSize =
        [iconSizeValue isKindOfClass:[NSNumber class]]
            ? [iconSizeValue doubleValue]
            : FLMDefaultWheelIconSize;
    self.wheelRadius =
        MAX(FLMMinimumWheelRadius, MIN(FLMMaximumWheelRadius, requestedRadius));
    self.wheelIconSize =
        MAX(FLMMinimumWheelIconSize,
            MIN(FLMMaximumWheelIconSize, requestedIconSize));
    CGFloat requestedCornerTriggerSize =
        [cornerTriggerSizeValue isKindOfClass:[NSNumber class]]
            ? [cornerTriggerSizeValue doubleValue]
            : FLMDefaultCornerTriggerSize;
    FLMCornerTriggerSize =
        FLMClampedCornerTriggerSize(requestedCornerTriggerSize);
    CGFloat requestedCenteredCardWidth =
        [centeredCardWidthValue isKindOfClass:[NSNumber class]]
            ? [centeredCardWidthValue doubleValue]
            : FLMCenteredCardWidth;
    self.centeredCardWidth =
        MAX(FLMMinimumCenteredCardWidth,
            MIN(FLMMaximumCenteredCardWidth, requestedCenteredCardWidth));
    CGFloat requestedTopCrop =
        [centeredCardTopCropValue isKindOfClass:[NSNumber class]]
            ? [centeredCardTopCropValue doubleValue]
            : FLMCenteredCardTopCrop;
    CGFloat requestedBottomCrop =
        [centeredCardBottomCropValue isKindOfClass:[NSNumber class]]
            ? [centeredCardBottomCropValue doubleValue]
            : FLMCenteredCardBottomCrop;
    self.centeredCardTopCrop =
        MAX(FLMMinimumCenteredCardCrop,
            MIN(FLMMaximumCenteredCardCrop, requestedTopCrop));
    self.centeredCardBottomCrop =
        MAX(FLMMinimumCenteredCardCrop,
            MIN(FLMMaximumCenteredCardCrop, requestedBottomCrop));
    CGFloat requestedSwipeThreshold =
        [centeredDockSwipeThresholdValue isKindOfClass:[NSNumber class]]
            ? [centeredDockSwipeThresholdValue doubleValue]
            : FLMDefaultCenteredDockSwipeThreshold;
    self.centeredDockSwipeThreshold =
        MAX(FLMMinimumCenteredDockSwipeThreshold,
            MIN(FLMMaximumCenteredDockSwipeThreshold, requestedSwipeThreshold));
    CGFloat requestedDockShrink =
        [dockedShrinkAmountValue isKindOfClass:[NSNumber class]]
            ? [dockedShrinkAmountValue doubleValue]
            : FLMDefaultDockedShrinkAmount;
    self.dockedShrinkAmount =
        MAX(FLMMinimumDockedShrinkAmount,
            MIN(FLMMaximumDockedShrinkAmount, requestedDockShrink));
    self.cornerGuardGesture.enabled = self.enabled;
    self.cornerGesture.enabled = self.enabled;
    self.floatingCornerGuardGesture.enabled = self.enabled;
    self.floatingCornerGesture.enabled = self.enabled;
    if (!self.enabled) {
        self.modalGesture.enabled = NO;
    }
    [self refreshWheelPriorityWindow];
    if (!self.enabled) {
        [self dismissWheelLaunchingItem:nil];
        [self closeFloatingWindowKeepingApplication:YES];
    } else if (self.floatingWindow && !self.floatingWindow.hidden &&
               !self.floatingInteractiveFullscreenTransition) {
        // Settings changes are presentation-only. Re-layout the existing
        // card if it is visible, while leaving the application's full-screen
        // Scene, responder route, and keyboard coordinate system untouched.
        [self layoutFloatingWindow];
    }
}

- (void)refreshWheelPriorityWindow {
    BOOL canReceive = self.enabled &&
                      !self.wheelPinned &&
                      self.itemIdentifiers.count > 0;
    // A Scene-bound window cannot receive touches from a different frontmost
    // application. It is therefore only an emergency fallback; the global
    // system-manager pair remains enabled regardless of this window state.
    self.hotspotWindow.hotspotsEnabled = canReceive &&
                                         !self.usesSystemGestureManager &&
                                         FLMPortraitWheelDisplayIsValid();
    self.hotspotWindow.hidden = !self.enabled || self.usesSystemGestureManager;
    self.hotspotWindow.windowLevel = UIWindowLevelAlert + 120.0;
}

- (void)updateWindowFrames {
    CGRect bounds = FLMVisualScreenBounds();
    self.overlayWindow.frame = bounds;
    self.overlayWindow.rootViewController.view.frame = bounds;
    self.wheelContainer.frame = bounds;
    self.hotspotWindow.frame = bounds;
    self.hotspotWindow.rootViewController.view.frame = bounds;
    self.homeDockWindow.frame = bounds;
    self.homeDockWindow.rootViewController.view.frame = bounds;
    self.floatingWindow.frame = bounds;
    self.floatingWindow.rootViewController.view.frame = bounds;
    self.floatingDockTouchGateWindow.frame = bounds;
    self.floatingDockTouchGateWindow.rootViewController.view.frame = bounds;
    self.floatingDimView.frame = bounds;
    [self layoutFloatingWindow];
    [self updateFloatingDockTouchGate];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.homeDockGesture) {
        return self.enabled && !self.wheelPinned &&
               self.floatingWindow.hidden && !self.floatingCloseInProgress &&
               !FLMDeviceIsLocked();
    }
    if (gestureRecognizer == self.floatingDockInputGesture) {
        CGPoint point =
            FLMVisualPointFromRawPoint([gestureRecognizer locationInView:nil]);
        BOOL controlPoint = [self floatingDockControlOwnsPoint:point];
        BOOL transitionBarrier =
            self.floatingDockTransitionActive &&
            !CGRectIsNull(self.floatingDockTouchGateTransitionFrame) &&
            CGRectContainsPoint(self.floatingDockTouchGateTransitionFrame, point);
        BOOL contentBarrier =
            self.floatingDockContentTailProtected &&
            !CGRectIsNull(self.floatingDockContentProtectionFrame) &&
            CGRectContainsPoint(self.floatingDockContentProtectionFrame, point);
        if (controlPoint && self.floatingDockTransitionActive &&
            !self.floatingWindow.hidden && !FLMDeviceIsLocked()) {
            // A DockControlOverlay touch is allowed to interrupt the current
            // presentation animator. The content barrier never outranks it.
            return YES;
        }
        if (!controlPoint && !self.floatingWindow.hidden && !FLMDeviceIsLocked() &&
            (transitionBarrier || contentBarrier)) {
            return YES;
        }
        BOOL canBegin = (self.floatingDocked || self.floatingDockHidden) &&
                        !self.floatingWindow.hidden &&
                        !FLMDeviceIsLocked();
        if (canBegin) {
            canBegin = controlPoint;
        }
        if (!canBegin) {
            [self setFloatingDockRoutingSuppressed:NO];
        }
        return canBegin;
    }
    if (gestureRecognizer == self.floatingDockDragPress) {
        BOOL canBegin = self.floatingDocked && !self.floatingWindow.hidden &&
                        !self.floatingDockTransitionActive;
        if (!canBegin) {
            [self setFloatingDockRoutingSuppressed:NO];
        }
        return canBegin;
    }
    if (gestureRecognizer == self.floatingBackdropTap) {
        return !self.floatingWindow.hidden && !self.floatingDocked;
    }
    if (gestureRecognizer == self.floatingExclusiveGesture) {
        if (self.enabled && !self.wheelPinned &&
            self.itemIdentifiers.count > 0 &&
            FLMPortraitWheelDisplayIsValid() &&
            FLMPointInsideCornerTrigger(
                FLMVisualPointFromRawPoint([gestureRecognizer locationInView:nil]),
                FLMVisualScreenBounds(),
                NULL)) {
            FLMEnqueueDiagnosticLine(
                @"sb should-begin recognizer=exclusive gate=wheel-corner point={%.1f,%.1f}",
                FLMVisualPointFromRawPoint([gestureRecognizer locationInView:nil]).x,
                FLMVisualPointFromRawPoint([gestureRecognizer locationInView:nil]).y);
            return NO;
        }
        return !self.floatingWindow.hidden && !self.floatingDocked &&
               !FLMDeviceIsLocked();
    }
    if (gestureRecognizer == self.modalGesture) {
        return self.enabled && self.wheelPinned && !FLMDeviceIsLocked();
    }
    if (gestureRecognizer == self.cornerGuardGesture ||
        gestureRecognizer == self.floatingCornerGuardGesture) {
        return FLMPortraitWheelDisplayIsValid() &&
               self.enabled && !self.wheelPinned &&
               self.itemIdentifiers.count > 0 && !FLMDeviceIsLocked();
    }
    if (gestureRecognizer != self.cornerGesture &&
        gestureRecognizer != self.floatingCornerGesture) {
        return NO;
    }
    if (!FLMPortraitWheelDisplayIsValid() ||
        !self.enabled || self.wheelPinned || self.itemIdentifiers.count == 0) {
        return NO;
    }
    if (FLMDeviceIsLocked()) {
        return NO;
    }
    CGRect bounds = FLMVisualScreenBounds();
    BOOL fromRight = NO;
    BOOL insideTrigger =
        FLMPointInsideCornerTrigger(self.cornerGestureStartPoint,
                                    bounds,
                                    &fromRight);
    self.presentingFromRight = fromRight;
    return insideTrigger;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer == self.homeDockGesture) {
        if (!self.enabled || self.wheelPinned || !self.floatingWindow.hidden ||
            self.floatingCloseInProgress || FLMDeviceIsLocked()) {
            return NO;
        }
        CGPoint rawPoint = [touch locationInView:nil];
        CGPoint point = FLMVisualPointFromRawPoint(rawPoint);
        CGRect screenBounds = FLMVisualScreenBounds();
        CGFloat zoneLeft = CGRectGetWidth(screenBounds) * 0.30;
        CGFloat zoneRight = CGRectGetWidth(screenBounds) * 0.70;
        if (point.x < zoneLeft || point.x > zoneRight ||
            point.y < CGRectGetHeight(screenBounds) - 100.0) {
            return NO;
        }
        NSString *frontmost = FLMFrontmostApplicationIdentifier();
        if (frontmost.length == 0 ||
            [frontmost isEqualToString:@"com.apple.springboard"] ||
            [frontmost isEqualToString:FLYME_LOCK_SCREEN_ITEM]) {
            return NO;
        }
        return YES;
    }
    if (gestureRecognizer == self.floatingDockInputGesture) {
        CGPoint rawPoint = [touch locationInView:nil];
        CGPoint point = FLMVisualPointFromRawPoint(rawPoint);
        BOOL controlPoint = [self floatingDockControlOwnsPoint:point];
        BOOL transitionBarrier =
            self.floatingDockTransitionActive &&
            !CGRectIsNull(self.floatingDockTouchGateTransitionFrame) &&
            CGRectContainsPoint(self.floatingDockTouchGateTransitionFrame, point);
        BOOL contentBarrier =
            self.floatingDockContentTailProtected &&
            !CGRectIsNull(self.floatingDockContentProtectionFrame) &&
            CGRectContainsPoint(self.floatingDockContentProtectionFrame, point);
        if (!controlPoint && !self.floatingWindow.hidden && !FLMDeviceIsLocked() &&
            (transitionBarrier || contentBarrier)) {
            [self setFloatingDockRoutingSuppressed:YES];
            [self setFloatingApplicationInputBlocked:YES];
            FLMEnqueueDiagnosticLine(
                @"sb dock-input-delegate owner=content-barrier accepted=0 route=%@ transition=%d protected=%d kind=%@ timestamp=%.6f point={%.1f,%.1f} view=%@ envelope=%@",
                self.usesSystemGestureManager ? @"system" : @"gate",
                transitionBarrier,
                contentBarrier,
                FLMFloatingDockControlTransitionName(
                    self.floatingDockControlTransition),
                touch.timestamp,
                point.x,
                point.y,
                touch.view ? NSStringFromClass([touch.view class]) : @"<nil>",
                NSStringFromCGRect(transitionBarrier
                                       ? self.floatingDockTouchGateTransitionFrame
                                       : self.floatingDockContentProtectionFrame));
            return YES;
        }
        BOOL transitionTakeover =
            controlPoint && self.floatingDockTransitionActive;
        if (((!self.floatingDocked && !self.floatingDockHidden) &&
             !transitionTakeover) ||
            self.floatingWindow.hidden ||
            FLMDeviceIsLocked()) {
            return NO;
        }
        BOOL staleStream =
            !controlPoint && self.floatingDockInputBlockedUntilNextTouch &&
            self.floatingDockInputBlockCutoffTimestamp > 0.0 &&
            touch.timestamp > 0.0 &&
            touch.timestamp <= self.floatingDockInputBlockCutoffTimestamp + 0.001;
        BOOL accepted = NO;
        accepted = controlPoint;
        accepted = accepted && !staleStream;
        FLMEnqueueDiagnosticLine(
            @"sb dock-input-delegate accepted=%d owner=DockControlOverlay route=%@ docked=%d hidden=%d transition=%d tailGuard=%d stale=%d timestamp=%.6f point={%.1f,%.1f} view=%@ card=%@",
            accepted,
            self.usesSystemGestureManager ? @"system" : @"gate",
            self.floatingDocked,
            self.floatingDockHidden,
            self.floatingDockTransitionActive,
            controlPoint,
            staleStream,
            touch.timestamp,
            point.x,
            point.y,
            touch.view ? NSStringFromClass([touch.view class]) : @"<nil>",
            NSStringFromCGRect([self floatingContainerPresentationFrame]));
        if (accepted) {
            // A touch newer than the transition cutoff is a genuinely new
            // stream. Clear the tail guard before the gesture begins so the
            // first deliberate post-transition drag/tap is not discarded.
            self.floatingDockInputBlockedUntilNextTouch = NO;
            self.floatingDockInputBlockCutoffTimestamp = 0.0;
            // Lock the floating card's touch route before the recognizer has
            // reached Began.  Waiting for the action callback leaves a small
            // arbitration window where a drag through a lower corner can be
            // handed to the wheel for one compositor frame.
            [self setFloatingDockRoutingSuppressed:YES];
            if (self.floatingDocked && !self.floatingDockHidden) {
                // Reassert the shield at touch-begin.  The dock can finish its
                // settle animation between two recognizer callbacks; without
                // this refresh a newly accepted drag can briefly target the
                // remote Scene underneath the card.
                [self setFloatingApplicationInputBlocked:YES];
            }
        }
        return accepted;
    }
    if (gestureRecognizer == self.floatingBackdropTap) {
        BOOL accepted = !self.floatingWindow.hidden;
        CGPoint point = [touch locationInView:self.floatingWindow.rootViewController.view];
        FLMEnqueueDiagnosticLine(
            @"sb touch-delegate recognizer=backdrop touch=%p timestamp=%.6f accepted=%d point={%.1f,%.1f} view=%@",
            (__bridge void *)touch, touch.timestamp, accepted, point.x, point.y,
            touch.view ? NSStringFromClass([touch.view class]) : @"<nil>");
        return accepted;
    }
    if (gestureRecognizer == self.floatingExclusiveGesture) {
        FLMCornerGestureRecognizer *exclusiveGesture =
            (FLMCornerGestureRecognizer *)gestureRecognizer;
        exclusiveGesture.flmOutsideCloseAuthorized = NO;
        if (self.floatingWindow.hidden || FLMDeviceIsLocked()) {
            FLMEnqueueDiagnosticLine(
                @"sb touch-delegate recognizer=exclusive touch=%p timestamp=%.6f accepted=0 gate=%@",
                (__bridge void *)touch, touch.timestamp,
                self.floatingWindow.hidden ? @"window-hidden" : @"device-locked");
            return NO;
        }
        UIView *touchView = touch.view;
        if (touchView == self.floatingContainer ||
            [touchView isDescendantOfView:self.floatingContainer] ||
            touchView == self.floatingHandle ||
            [touchView isDescendantOfView:self.floatingHandle]) {
            FLMEnqueueDiagnosticLine(
                @"sb touch-delegate recognizer=exclusive touch=%p timestamp=%.6f accepted=0 gate=protected-view view=%@ viewPtr=%p",
                (__bridge void *)touch, touch.timestamp,
                touchView ? NSStringFromClass([touchView class]) : @"<nil>",
                (__bridge void *)touchView);
            return NO;
        }
        CGPoint rawPoint = [touch locationInView:nil];
        CGPoint point = FLMVisualPointFromRawPoint(rawPoint);
        // The wheel owns the corner trigger while it can summon: the exclusive
        // close gesture must never arbitrate away the corner swipe that opens
        // the wheel over a centered card.
        if (self.enabled && !self.wheelPinned &&
            self.itemIdentifiers.count > 0 &&
            FLMPortraitWheelDisplayIsValid() &&
            FLMPointInsideCornerTrigger(point,
                                        FLMVisualScreenBounds(),
                                        NULL)) {
            FLMEnqueueDiagnosticLine(
                @"sb touch-delegate recognizer=exclusive touch=%p timestamp=%.6f accepted=0 gate=wheel-corner point={%.1f,%.1f}",
                (__bridge void *)touch, touch.timestamp, point.x, point.y);
            return NO;
        }
        BOOL outside = ![self pointIsInsideFloatingInteractionDomain:point];
        exclusiveGesture.flmOutsideCloseAuthorized = outside;
        exclusiveGesture.flmAuthorizedStartPoint = point;
        FLMEnqueueDiagnosticLine(
            @"sb touch-delegate recognizer=exclusive touch=%p timestamp=%.6f accepted=%d point={%.1f,%.1f} view=%@ keyboardVisible=%d interaction=%d keyboardFrame=%@ card=%@",
            (__bridge void *)touch, touch.timestamp, outside, point.x, point.y,
            touchView ? NSStringFromClass([touchView class]) : @"<nil>",
            self.floatingKeyboardVisible,
            self.floatingKeyboardInteractionSessionActive,
            NSStringFromCGRect([self floatingKeyboardInteractionFrame]),
            NSStringFromCGRect([self floatingContainerPresentationFrame]));
        return outside;
    }
    if (gestureRecognizer == self.floatingDockDragPress) {
        if (!self.floatingDocked || self.floatingWindow.hidden ||
            self.floatingDockTransitionActive || FLMDeviceIsLocked()) {
            return NO;
        }
        [self setFloatingDockRoutingSuppressed:YES];
        return YES;
    }
    if (gestureRecognizer == self.modalGesture) {
        return self.enabled && self.wheelPinned && !FLMDeviceIsLocked();
    }
    if (gestureRecognizer == self.cornerGuardGesture ||
        gestureRecognizer == self.floatingCornerGuardGesture) {
        if (!FLMPortraitWheelDisplayIsValid() ||
            !self.enabled || self.wheelPinned ||
            self.itemIdentifiers.count == 0 || FLMDeviceIsLocked()) {
            return NO;
        }
        CGPoint rawPoint = [touch locationInView:nil];
        CGPoint point = FLMVisualPointFromRawPoint(rawPoint);
        BOOL accepted = FLMPointInsideCornerTrigger(point,
                                                    FLMVisualScreenBounds(),
                                                    NULL);
        if (accepted) {
            FLMEnqueueDiagnosticLine(
                @"sb wheel-priority-touch accepted recognizer=%@ point={%.1f,%.1f}",
                gestureRecognizer == self.cornerGuardGesture ? @"guard" : @"floating-guard",
                point.x, point.y);
        }
        return accepted;
    }
    if (gestureRecognizer != self.cornerGesture &&
        gestureRecognizer != self.floatingCornerGesture) {
        return NO;
    }
    if (!FLMPortraitWheelDisplayIsValid() ||
        !self.enabled || self.wheelPinned || self.itemIdentifiers.count == 0) {
        return NO;
    }
    if (FLMDeviceIsLocked()) {
        return NO;
    }
    CGRect bounds = FLMVisualScreenBounds();
    CGPoint rawPoint = [touch locationInView:nil];
    CGPoint point = FLMVisualPointFromRawPoint(rawPoint);
    BOOL fromRight = NO;
    if (!FLMPointInsideCornerTrigger(point, bounds, &fromRight)) {
        return NO;
    }
    self.presentingFromRight = fromRight;
    self.cornerGestureStartPoint = point;
    self.wheelGestureActive = NO;
    FLMEnqueueDiagnosticLine(
        @"sb wheel-priority-touch accepted recognizer=%@ point={%.1f,%.1f} fromRight=%d",
        gestureRecognizer == self.cornerGesture ? @"opener" : @"floating-opener",
        point.x, point.y, fromRight);
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer {
    // The wheel family spans the dedicated hotspot window and the floating
    // window fallback pair. Every member must be able to recognize beside any
    // other member, otherwise the first recognizer to begin prevents the rest
    // and the wheel silently stops summoning in card modes.
    FLMCornerGestureRecognizer *wheelFamily[] = {
        self.cornerGuardGesture,
        self.cornerGesture,
        self.floatingCornerGuardGesture,
        self.floatingCornerGesture,
    };
    BOOL firstInFamily = NO;
    BOOL secondInFamily = NO;
    for (NSUInteger i = 0; i < sizeof(wheelFamily) / sizeof(wheelFamily[0]); i++) {
        if (gestureRecognizer == wheelFamily[i]) {
            firstInFamily = YES;
        }
        if (otherGestureRecognizer == wheelFamily[i]) {
            secondInFamily = YES;
        }
    }
    if (firstInFamily && secondInFamily) {
        return YES;
    }
    // The in-window guard must not disable the backdrop close on a quick
    // corner tap; let the backdrop tap run alongside any wheel-family member.
    BOOL backdropInvolved =
        gestureRecognizer == self.floatingBackdropTap ||
        otherGestureRecognizer == self.floatingBackdropTap;
    if (backdropInvolved && (firstInFamily || secondInFamily)) {
        return YES;
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldBeRequiredToFailByGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return NO;
}

- (void)handleModalGesture:(UIGestureRecognizer *)gesture {
    if (!self.wheelPinned) {
        return;
    }
    CGPoint rawPoint = [gesture locationInView:nil];
    CGPoint point = FLMVisualPointFromRawPoint(rawPoint);
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            [self updateHighlightForPoint:point];
            break;
        case UIGestureRecognizerStateEnded: {
            FLMWheelItemView *item =
                [self itemNearPoint:point
                    maximumDistance:self.wheelIconSize * 0.5 + 2.0];
            [self dismissWheelLaunchingItem:item];
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            self.highlightedItem.highlighted = NO;
            self.highlightedItem = nil;
            break;
        default:
            break;
    }
}

- (void)handleCornerGuardGesture:(UIGestureRecognizer *)gesture {
    // Recognizing immediately reserves the corner zone so home/back/card
    // gestures cannot consume the same touch stream. Keep a breadcrumb for
    // the priority boundary because this guard runs before the wheel opener.
    if (gesture.state == UIGestureRecognizerStateBegan &&
        FLMPortraitWheelDisplayIsValid()) {
        CGPoint point = FLMVisualPointFromRawPoint([gesture locationInView:nil]);
        FLMEnqueueDiagnosticLine(
            @"sb wheel-priority-guard began point={%.1f,%.1f}",
            point.x, point.y);
    }
}

- (void)handleHomeDockGesture:(FLMDockGestureRecognizer *)gesture {
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            self.homeDockGestureActive = YES;
            self.homeDockTriggerHandled = NO;
            FLMEnqueueDiagnosticLine(
                @"sb home-dock long-press confirmed app=%@",
                FLMFrontmostApplicationIdentifier() ?: @"<none>");
            break;
        case UIGestureRecognizerStateChanged:
            if (gesture.flmTriggered && !self.homeDockTriggerHandled) {
                self.homeDockTriggerHandled = YES;
                [self activateDockedFrontmostApplication];
            }
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            self.homeDockGestureActive = NO;
            self.homeDockTriggerHandled = NO;
            break;
        default:
            break;
    }
}

- (void)activateDockedFrontmostApplication {
    if (!self.enabled || FLMDeviceIsLocked() ||
        !self.floatingWindow.hidden || self.floatingCloseInProgress) {
        return;
    }
    NSString *frontmost = FLMFrontmostApplicationIdentifier();
    if (frontmost.length == 0 ||
        [frontmost isEqualToString:@"com.apple.springboard"] ||
        [frontmost isEqualToString:FLYME_LOCK_SCREEN_ITEM]) {
        return;
    }
    self.floatingOpenTargetDocked = YES;
    [self openFloatingIdentifier:frontmost];
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback =
            [[UIImpactFeedbackGenerator alloc]
                initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
    }
    FLMEnqueueDiagnosticLine(@"sb home-dock activate app=%@", frontmost);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRequireFailureOfGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return NO;
}

- (void)handleCornerGesture:(UIGestureRecognizer *)gesture {
    if (!FLMPortraitWheelDisplayIsValid()) {
        if (self.wheelGestureActive) {
            [self dismissWheelLaunchingItem:nil];
            self.wheelGestureActive = NO;
        }
        return;
    }
    CGPoint rawPoint = [gesture locationInView:nil];
    CGPoint point = FLMVisualPointFromRawPoint(rawPoint);

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            if (!self.wheelGestureActive && [self shouldActivateWheelAtPoint:point]) {
                self.wheelGestureActive = YES;
                FLMEnqueueDiagnosticLine(
                    @"sb wheel-gesture began point={%.1f,%.1f} start={%.1f,%.1f} priority=1",
                    point.x, point.y,
                    self.cornerGestureStartPoint.x,
                    self.cornerGestureStartPoint.y);
                [self presentWheelFromRight:self.presentingFromRight];
            }
            if (self.wheelGestureActive) {
                [self updateHighlightForPoint:point];
            }
            break;
        case UIGestureRecognizerStateEnded:
            if (self.wheelGestureActive) {
                FLMWheelItemView *selectedItem = self.highlightedItem;
                if (selectedItem) {
                    [self dismissWheelLaunchingItem:selectedItem];
                } else {
                    [self pinWheel];
                }
            }
            FLMEnqueueDiagnosticLine(
                @"sb wheel-gesture ended active=%d point={%.1f,%.1f}",
                self.wheelGestureActive, point.x, point.y);
            self.wheelGestureActive = NO;
            break;
        case UIGestureRecognizerStateCancelled:
            if (self.wheelGestureActive) {
                [self pinWheel];
            }
            FLMEnqueueDiagnosticLine(
                @"sb wheel-gesture cancelled active=%d point={%.1f,%.1f}",
                self.wheelGestureActive, point.x, point.y);
            self.wheelGestureActive = NO;
            break;
        case UIGestureRecognizerStateFailed:
            if (self.wheelGestureActive) {
                [self dismissWheelLaunchingItem:nil];
            }
            self.wheelGestureActive = NO;
            break;
        default:
            break;
    }
}

- (BOOL)shouldActivateWheelAtPoint:(CGPoint)point {
    if (!FLMPortraitWheelDisplayIsValid()) {
        return NO;
    }
    CGFloat horizontalMovement = point.x - self.cornerGestureStartPoint.x;
    CGFloat verticalMovement = point.y - self.cornerGestureStartPoint.y;
    CGFloat totalMovement = hypot(horizontalMovement, verticalMovement);
    CGFloat inwardMovement =
        self.presentingFromRight ? -horizontalMovement : horizontalMovement;
    CGFloat upwardMovement = -verticalMovement;
    return totalMovement >= 14.0 &&
           (inwardMovement >= 4.0 || upwardMovement >= 4.0);
}

- (NSArray<NSNumber *> *)itemCountsByRingForCount:(NSUInteger)count {
    NSMutableArray<NSNumber *> *counts = [NSMutableArray array];
    NSUInteger remaining = count;
    NSUInteger capacity = 4;
    while (remaining > 0) {
        NSUInteger ringCount = MIN(remaining, capacity);
        [counts addObject:@(ringCount)];
        remaining -= ringCount;
        capacity += 1;
    }
    return counts;
}

- (void)presentWheelFromRight:(BOOL)fromRight {
    if (!FLMPortraitWheelDisplayIsValid()) {
        return;
    }
    [self.itemViews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.wheelPinned = NO;
    // The opening touch belongs to this wheel stream. Do not let the
    // priority window start a second stream while the wheel is animating in.
    self.hotspotWindow.hotspotsEnabled = NO;
    // The wheel must render and receive touches above any visible card. The
    // keyboard forwarding window sits at floating+1, so present at +2.
    self.overlayWindow.userInteractionEnabled = NO;
    self.overlayWindow.windowLevel = self.floatingWindow.windowLevel + 2.0;
    NSMutableArray<FLMWheelItemView *> *views = [NSMutableArray array];
    CGRect bounds = FLMVisualScreenBounds();
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    CGPoint anchor = CGPointMake(fromRight ? width - 4.0 : 4.0, height - 4.0);
    NSArray<NSNumber *> *ringCounts =
        [self itemCountsByRingForCount:self.itemIdentifiers.count];
    CGFloat fullStartAngle = -82.0 * (CGFloat)M_PI / 180.0;
    CGFloat fullEndAngle = -10.0 * (CGFloat)M_PI / 180.0;
    CGFloat fullAngleSpan = fullEndAngle - fullStartAngle;
    CGFloat safeCenterMargin = self.wheelIconSize * 0.5 + 10.0;
    CGFloat maximumRadiusByWidth =
        (width - 4.0 - safeCenterMargin) / cos(fullEndAngle);
    CGFloat maximumRadiusByHeight =
        (height - 4.0 - safeCenterMargin) / fabs(sin(fullStartAngle));
    CGFloat maximumRadius = MAX(120.0, MIN(maximumRadiusByWidth,
                                           maximumRadiusByHeight));
    CGFloat firstRadius = MIN(self.wheelRadius, maximumRadius);
    CGFloat ringSpacing = 0.0;
    if (ringCounts.count > 1) {
        CGFloat ringIntervals = (CGFloat)(ringCounts.count - 1);
        CGFloat desiredSpacing = self.wheelIconSize + 20.0;
        CGFloat minimumSpacing = self.wheelIconSize + 6.0;
        CGFloat desiredOuterRadius = firstRadius + desiredSpacing * ringIntervals;
        if (desiredOuterRadius <= maximumRadius) {
            ringSpacing = desiredSpacing;
        } else {
            firstRadius =
                MIN(firstRadius,
                    MAX(132.0, maximumRadius - minimumSpacing * ringIntervals));
            ringSpacing = (maximumRadius - firstRadius) / ringIntervals;
        }
    }

    NSUInteger itemIndex = 0;
    for (NSUInteger ring = 0; ring < ringCounts.count; ring++) {
        NSUInteger ringCount = ringCounts[ring].unsignedIntegerValue;
        CGFloat radius = firstRadius + (CGFloat)ring * ringSpacing;
        for (NSUInteger position = 0; position < ringCount; position++) {
            CGFloat fraction = ringCount == 1
                                   ? 0.5
                                   : (CGFloat)position / (CGFloat)(ringCount - 1);
            CGFloat angle = fullStartAngle + fraction * fullAngleSpan;
            CGFloat leftX = 4.0 + radius * cos(angle);
            CGFloat centerX = fromRight ? width - leftX : leftX;
            CGFloat centerY = anchor.y + radius * sin(angle);
            NSString *identifier = self.itemIdentifiers[itemIndex++];
            FLMWheelItemView *item =
                [[FLMWheelItemView alloc] initWithIdentifier:identifier
                                                       image:FLMApplicationIcon(identifier)
                                                        size:self.wheelIconSize];
            item.center = CGPointMake(centerX, centerY);
            item.alpha = 0.0;
            item.transform = CGAffineTransformMakeScale(0.42, 0.42);
            [self.wheelContainer addSubview:item];
            [views addObject:item];
        }
    }
    self.itemViews = views;

    self.overlayWindow.hidden = NO;
    self.wheelContainer.alpha = 1.0;
    [self.itemViews enumerateObjectsUsingBlock:^(
                        FLMWheelItemView *item, NSUInteger index, BOOL *stop) {
        (void)stop;
        [UIView animateWithDuration:0.44
                              delay:MIN((NSTimeInterval)index * 0.018, 0.12)
             usingSpringWithDamping:0.72
              initialSpringVelocity:0.55
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
                             item.alpha = 1.0;
                             item.transform = CGAffineTransformIdentity;
                         }
                         completion:nil];
    }];
}

- (void)updateHighlightForPoint:(CGPoint)point {
    FLMWheelItemView *nearest =
        [self itemNearPoint:point
            maximumDistance:self.wheelIconSize * 0.5 + 2.0];
    if (nearest == self.highlightedItem) {
        return;
    }
    self.highlightedItem.highlighted = NO;
    self.highlightedItem = nearest;
    self.highlightedItem.highlighted = YES;
    if (@available(iOS 10.0, *)) {
        if (nearest) {
            UISelectionFeedbackGenerator *feedback =
                [[UISelectionFeedbackGenerator alloc] init];
            [feedback selectionChanged];
        }
    }
}

- (FLMWheelItemView *)itemNearPoint:(CGPoint)point maximumDistance:(CGFloat)distance {
    FLMWheelItemView *nearest = nil;
    CGFloat nearestDistance = CGFLOAT_MAX;
    for (FLMWheelItemView *item in self.itemViews) {
        CGFloat itemDistance = hypot(point.x - item.center.x, point.y - item.center.y);
        if (itemDistance < nearestDistance) {
            nearestDistance = itemDistance;
            nearest = item;
        }
    }
    return nearestDistance <= distance ? nearest : nil;
}

- (void)pinWheel {
    if (self.overlayWindow.hidden || self.wheelPinned) {
        return;
    }
    self.highlightedItem.highlighted = NO;
    self.highlightedItem = nil;
    self.wheelPinned = YES;
    self.hotspotWindow.hotspotsEnabled = NO;
    self.overlayWindow.userInteractionEnabled = YES;
    if (self.usesSystemGestureManager) {
        self.modalGesture.enabled = YES;
        self.wheelTapGesture.enabled = NO;
    } else {
        self.wheelTapGesture.enabled = YES;
    }
    [self beginLockMonitoring];
    [UIView animateWithDuration:0.32
                          delay:0.0
         usingSpringWithDamping:0.76
          initialSpringVelocity:0.25
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         for (FLMWheelItemView *item in self.itemViews) {
                             item.transform = CGAffineTransformIdentity;
                             item.alpha = 1.0;
                         }
                     }
                     completion:nil];
}

- (void)handleWheelTap:(UITapGestureRecognizer *)gesture {
    if (!self.wheelPinned) {
        return;
    }
    CGPoint point = [gesture locationInView:self.wheelContainer];
    FLMWheelItemView *item =
        [self itemNearPoint:point
            maximumDistance:self.wheelIconSize * 0.5 + 2.0];
    [self dismissWheelLaunchingItem:item];
}

- (void)dismissWheelLaunchingItem:(FLMWheelItemView *)item {
    NSString *selectedIdentifier = [item.identifier copy];
    BOOL selectedIsCurrentFloating =
        !self.floatingWindow.hidden && self.floatingIdentifier.length > 0 &&
        [selectedIdentifier isEqualToString:self.floatingIdentifier];
    BOOL selectedIsFrontmost =
        selectedIdentifier.length > 0 &&
        [selectedIdentifier isEqualToString:FLMFrontmostApplicationIdentifier()];
    if (selectedIdentifier.length > 0 && !selectedIsCurrentFloating &&
        !selectedIsFrontmost &&
        ![selectedIdentifier isEqualToString:FLYME_LOCK_SCREEN_ITEM] &&
        FLMPrewarmApplicationIdentifier(selectedIdentifier)) {
        // Start the suspended scene while the wheel is completing its existing
        // dismissal animation. This gives scene creation a 240 ms head start.
        self.prewarmedIdentifier = selectedIdentifier;
    } else {
        self.prewarmedIdentifier = nil;
    }
    self.highlightedItem.highlighted = NO;
    self.highlightedItem = nil;
    self.wheelPinned = NO;
    self.modalGesture.enabled = NO;
    self.wheelTapGesture.enabled = YES;
    self.overlayWindow.userInteractionEnabled = NO;
    // Restore the overlay below the floating window now that the wheel no
    // longer needs to sit above a visible card.
    self.overlayWindow.windowLevel = UIWindowLevelAlert + 91.0;
    [self refreshWheelPriorityWindow];
    [self stopLockMonitoringIfIdle];
    if (self.overlayWindow.hidden) {
        if (item) {
            [self activateIdentifier:item.identifier];
        }
        return;
    }

    [UIView animateWithDuration:0.24
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseIn
                     animations:^{
                         self.wheelContainer.alpha = 0.0;
                         for (FLMWheelItemView *itemView in self.itemViews) {
                             itemView.transform = CGAffineTransformMakeScale(0.78, 0.78);
                             itemView.alpha = 0.0;
                         }
                     }
                     completion:^(BOOL finished) {
                         (void)finished;
                         self.overlayWindow.hidden = YES;
                         self.wheelContainer.alpha = 1.0;
                         [self.itemViews makeObjectsPerformSelector:@selector(removeFromSuperview)];
                         self.itemViews = @[];
                         if (item) {
                             [self activateIdentifier:item.identifier];
                         }
                     }];
}

- (void)handleFloatingBackdropTap:(UIGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded ||
        self.floatingWindow.hidden) {
        return;
    }
    FLMOutsideTapGestureRecognizer *outsideGesture =
        (FLMOutsideTapGestureRecognizer *)gesture;
    CGPoint point = FLMVisualPointFromRawPoint([gesture locationInView:nil]);
    FLMEnqueueDiagnosticLine(
        @"sb touch route=backdrop authorized=%d point={%.1f,%.1f} keyboardVisible=%d interaction=%d keyboardFrame=%@ card=%@",
        outsideGesture.outsideCloseAuthorized, point.x, point.y,
        self.floatingKeyboardVisible,
        self.floatingKeyboardInteractionSessionActive,
        NSStringFromCGRect([self floatingKeyboardInteractionFrame]),
        NSStringFromCGRect([self floatingContainerPresentationFrame]));
    if (outsideGesture.outsideCloseAuthorized) {
        FLMEnqueueDiagnosticLine(@"sb close-reason=backdrop-tap");
        [self closeFloatingWindowKeepingApplication:YES];
    }
}

- (void)handleFloatingExclusiveGesture:(UIGestureRecognizer *)gesture {
    if (self.floatingWindow.hidden || self.floatingDocked) {
        self.floatingExclusiveTapEligible = NO;
        return;
    }

    CGPoint rawPoint = [gesture locationInView:nil];
    CGPoint point = FLMVisualPointFromRawPoint(rawPoint);
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            self.floatingExclusiveStartPoint =
                ((FLMCornerGestureRecognizer *)gesture)
                    .flmAuthorizedStartPoint;
            self.floatingExclusiveStartTimestamp = CACurrentMediaTime();
            self.floatingExclusiveTapEligible =
                ((FLMCornerGestureRecognizer *)gesture)
                    .flmOutsideCloseAuthorized &&
                ((FLMCornerGestureRecognizer *)gesture)
                        .flmFirstTouchTimestamp > 0.0;
            FLMEnqueueDiagnosticLine(
                @"sb exclusive-began authorized=%d eligible=%d delegatePoint={%.1f,%.1f} callbackPoint={%.1f,%.1f} keyboardVisible=%d interaction=%d currentDomain=%d",
                ((FLMCornerGestureRecognizer *)gesture).flmOutsideCloseAuthorized,
                self.floatingExclusiveTapEligible,
                self.floatingExclusiveStartPoint.x,
                self.floatingExclusiveStartPoint.y, point.x, point.y,
                self.floatingKeyboardVisible,
                self.floatingKeyboardInteractionSessionActive,
                [self pointIsInsideFloatingInteractionDomain:point]);
            break;
        case UIGestureRecognizerStateChanged:
            if (self.floatingExclusiveTapEligible &&
                hypot(point.x - self.floatingExclusiveStartPoint.x,
                      point.y - self.floatingExclusiveStartPoint.y) > 12.0) {
                self.floatingExclusiveTapEligible = NO;
            }
            break;
        case UIGestureRecognizerStateEnded: {
            BOOL shouldClose =
                self.floatingExclusiveTapEligible &&
                CACurrentMediaTime() - self.floatingExclusiveStartTimestamp <= 0.35 &&
                hypot(point.x - self.floatingExclusiveStartPoint.x,
                      point.y - self.floatingExclusiveStartPoint.y) <= 12.0;
            self.floatingExclusiveTapEligible = NO;
            if (shouldClose && !self.floatingWindow.hidden && !self.floatingDocked &&
                ((FLMCornerGestureRecognizer *)gesture)
                    .flmOutsideCloseAuthorized) {
                FLMEnqueueDiagnosticLine(
                    @"sb close-reason=exclusive-tap point={%.1f,%.1f}",
                    point.x, point.y);
                [self closeFloatingWindowKeepingApplication:YES];
            }
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            self.floatingExclusiveTapEligible = NO;
            break;
        default:
            break;
    }
}

- (void)activateFloatingDockDragForGeneration:(NSUInteger)generation {
    if (generation != self.floatingDockInputGeneration ||
        !self.floatingDocked || self.floatingDockHidden ||
        self.floatingWindow.hidden ||
        !self.floatingDockInputSessionActive ||
        self.floatingDockInputMode != FLMFloatingDockInputModeCardDrag ||
        self.floatingDockInputTargetsResize ||
        (self.floatingDockInputGesture.state != UIGestureRecognizerStateBegan &&
         self.floatingDockInputGesture.state != UIGestureRecognizerStateChanged &&
         self.floatingDockInputGesture.state != UIGestureRecognizerStateEnded)) {
        return;
    }
    self.floatingDockGlobalDragActivated = YES;
    self.floatingResizeHandle.hidden = YES;
    self.floatingDockTouchGateWindow.dockResizeFrame = CGRectNull;
    FLMEnqueueDiagnosticLine(
        @"sb dock-input-activated generation=%lu transport=live-layer geometry=locked start={%.1f,%.1f} center={%.1f,%.1f}",
        (unsigned long)generation,
        self.floatingDockDragStartPoint.x,
        self.floatingDockDragStartPoint.y,
        self.floatingDockDragInitialCenter.x,
        self.floatingDockDragInitialCenter.y);
    UIView *rootView = self.floatingWindow.rootViewController.view;
    [rootView bringSubviewToFront:self.floatingContainer];
    [rootView bringSubviewToFront:self.floatingResizeHandle];
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback =
            [[UIImpactFeedbackGenerator alloc]
                initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
    }
}

- (void)setFloatingDockRoutingSuppressed:(BOOL)suppressed {
    FLMFloatingWindow *floatingWindow =
        (FLMFloatingWindow *)self.floatingWindow;
    floatingWindow.suppressesCornerRoutingDuringDockGesture = suppressed;
}

- (void)updateFloatingDockTouchGate {
    FLMDockTouchGateWindow *gate = self.floatingDockTouchGateWindow;
    if (!gate || !self.floatingWindow) {
        return;
    }
    CGRect bounds = self.floatingWindow.bounds;
    if (!CGRectEqualToRect(gate.frame, bounds)) {
        gate.frame = bounds;
    }
    UIView *gateRootView = gate.rootViewController.view;
    if (gateRootView && !CGRectEqualToRect(gateRootView.frame, bounds)) {
        gateRootView.frame = bounds;
    }
    gate.wheelPriorityActive = FLMPortraitWheelDisplayIsValid() &&
                               self.enabled && !self.wheelPinned &&
                               self.itemIdentifiers.count > 0 &&
                               !FLMDeviceIsLocked();

    BOOL active = !self.floatingWindow.hidden &&
                  (self.floatingDocked || self.floatingDockHidden ||
                   self.floatingDockTransitionActive ||
                   self.floatingDockContentTailProtected);
    gate.dockTouchGateEnabled = active;
    if (!active) {
        gate.dockCardFrame = CGRectNull;
        gate.dockHandleFrame = CGRectNull;
        gate.dockResizeFrame = CGRectNull;
        gate.userInteractionEnabled = NO;
        gate.hidden = YES;
        return;
    }

    if (self.floatingDockTransitionActive &&
        !CGRectIsNull(self.floatingDockTouchGateTransitionFrame) &&
        !CGRectIsEmpty(self.floatingDockTouchGateTransitionFrame)) {
        gate.dockCardFrame = self.floatingDockTouchGateTransitionFrame;
    } else if (self.floatingDockContentTailProtected &&
               !CGRectIsNull(self.floatingDockContentProtectionFrame) &&
               !CGRectIsEmpty(self.floatingDockContentProtectionFrame)) {
        gate.dockCardFrame = self.floatingDockContentProtectionFrame;
    } else {
        gate.dockCardFrame = self.floatingDockHidden
                                 ? CGRectNull
                                 : [self floatingContainerPresentationFrame];
    }
    gate.dockHandleFrame = !self.floatingHandle.hidden
                               ? self.floatingHandle.frame
                               : CGRectNull;
    gate.dockResizeFrame = (!self.floatingDockHidden &&
                            !self.floatingResizeHandle.hidden)
                               ? self.floatingResizeHandle.frame
                               : CGRectNull;
    gate.userInteractionEnabled = YES;
    gate.hidden = NO;
}

- (void)prepareFloatingDockDisplayLink {
    CADisplayLink *displayLink = self.floatingDockInputDisplayLink;
    if (displayLink) {
        displayLink.paused = YES;
        return;
    }
    displayLink =
        [CADisplayLink displayLinkWithTarget:self
                                    selector:@selector(flushFloatingDockInputFrame:)];
    NSInteger screenMaximum = [UIScreen mainScreen].maximumFramesPerSecond;
    self.floatingDockPerfMaximumFramesPerSecond = screenMaximum;
    CGFloat requestedMinimum = screenMaximum >= 120 ? 80.0 : screenMaximum;
    CGFloat requestedMaximum = MAX(1, screenMaximum);
    CGFloat requestedPreferred = requestedMaximum;
    self.floatingDockPerfRequestedMinimumFramesPerSecond = requestedMinimum;
    self.floatingDockPerfRequestedMaximumFramesPerSecond = requestedMaximum;
    self.floatingDockPerfRequestedPreferredFramesPerSecond = requestedPreferred;
    if ([displayLink respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        displayLink.preferredFramesPerSecond = screenMaximum;
    }
    if (@available(iOS 15.0, *)) {
        displayLink.preferredFrameRateRange =
            CAFrameRateRangeMake((float)requestedMinimum,
                                 (float)requestedMaximum,
                                 (float)requestedPreferred);
    }
    self.floatingDockInputDisplayLink = displayLink;
    displayLink.paused = YES;
    [displayLink addToRunLoop:[NSRunLoop mainRunLoop]
                       forMode:NSRunLoopCommonModes];
    if (!self.floatingDockDisplayLinkConfigLogged) {
        FLMEnqueueDiagnosticLine(
            @"sb dock-displaylink-config screenMaxFPS=%ld requestedMinFPS=%.2f requestedMaxFPS=%.2f requestedPreferredFPS=%.2f preferredFramesPerSecond=%ld duration=%.6f runLoopMode=CommonModes paused=1",
            (long)screenMaximum,
            requestedMinimum,
            requestedMaximum,
            requestedPreferred,
            (long)screenMaximum,
            displayLink.duration);
        self.floatingDockDisplayLinkConfigLogged = YES;
    }
}

- (void)setFloatingDockDisplayLinkActive:(BOOL)active {
    if (active && !self.floatingDockInputDisplayLink) {
        [self prepareFloatingDockDisplayLink];
    }
    self.floatingDockInputDisplayLink.paused = !active;
}

- (void)queueFloatingDockInputUpdateForPoint:(CGPoint)point {
    if (self.floatingWindow.hidden ||
        ((!self.floatingDocked && !self.floatingDockHidden) &&
         !self.floatingDockTransitionActive)) {
        return;
    }
    [self recordFloatingDockInputSampleAtTimestamp:CACurrentMediaTime()];
    if (self.floatingDockInputFramePending) {
        self.floatingDockPerfCoalescedSampleCount += 1;
    }
    self.floatingDockInputFramePoint = point;
    self.floatingDockInputFrameGeneration = self.floatingDockInputGeneration;
    self.floatingDockInputFramePending = YES;
    // The link is created once when Dock becomes available and remains
    // paused until a real drag. A zero-movement tap therefore never starts a
    // render loop merely because Ended delivered one final point.
}

- (void)recordFloatingDockInputSampleAtTimestamp:(NSTimeInterval)timestamp {
    self.floatingDockPerfInputSampleCount += 1;
    if (self.floatingDockPerfLastInputTimestamp > 0.0 &&
        timestamp > self.floatingDockPerfLastInputTimestamp) {
        self.floatingDockPerfInputDeltaSumMs +=
            (timestamp - self.floatingDockPerfLastInputTimestamp) * 1000.0;
    }
    self.floatingDockPerfLastInputTimestamp = timestamp;
}

- (void)recordFloatingDockRenderCommitAtTimestamp:(NSTimeInterval)timestamp {
    self.floatingDockPerfRenderCommitCount += 1;
    if (self.floatingDockPerfLastRenderCommitTimestamp > 0.0 &&
        timestamp > self.floatingDockPerfLastRenderCommitTimestamp) {
        self.floatingDockPerfRenderDeltaSumMs +=
            (timestamp - self.floatingDockPerfLastRenderCommitTimestamp) *
            1000.0;
    }
    self.floatingDockPerfLastRenderCommitTimestamp = timestamp;
}

- (void)observeFloatingDockDisplayLinkInterval:(NSTimeInterval)timestamp {
    if (!self.floatingDockInputSessionActive ||
        self.floatingDockDisplayLinkCapped60 ||
        self.floatingDockPerfMaximumFramesPerSecond < 120 ||
        self.floatingDockInputMode != FLMFloatingDockInputModeCardDrag ||
        self.floatingDockDisplayLinkProbeIntervalCount >= 3) {
        return;
    }
    if (self.floatingDockDisplayLinkProbeLastTimestamp > 0.0 &&
        timestamp > self.floatingDockDisplayLinkProbeLastTimestamp) {
        NSTimeInterval interval =
            timestamp - self.floatingDockDisplayLinkProbeLastTimestamp;
        self.floatingDockDisplayLinkProbeIntervalCount += 1;
        if (interval >= 0.012) {
            self.floatingDockDisplayLinkProbeSlowCount += 1;
        } else {
            self.floatingDockDisplayLinkProbeSlowCount = 0;
        }
        if (self.floatingDockDisplayLinkProbeSlowCount >= 3) {
            self.floatingDockDisplayLinkCapped60 = YES;
            self.floatingDockRendererMode =
                FLMFloatingDockRendererModeDirectPan;
            if (!self.floatingDockGlobalDragActivated) {
                [self activateFloatingDockDragForGeneration:
                          self.floatingDockInputGeneration];
            }
            self.floatingDockInputFramePending = NO;
            [self setFloatingDockDisplayLinkActive:NO];
            FLMEnqueueDiagnosticLine(
                @"sb dock-renderer mode=direct-pan displayLinkCapped60=1 probeIntervals=%lu thresholdMs=12 screenMaxFPS=%ld",
                (unsigned long)self.floatingDockDisplayLinkProbeIntervalCount,
                (long)self.floatingDockPerfMaximumFramesPerSecond);
        }
    }
    self.floatingDockDisplayLinkProbeLastTimestamp = timestamp;
}

- (void)applyFloatingDockDirectPanPoint:(CGPoint)point {
    if (self.floatingWindow.hidden ||
        self.floatingDockInputMode != FLMFloatingDockInputModeCardDrag) {
        return;
    }
    CGPoint delta = CGPointMake(
        point.x - self.floatingDockDragStartPoint.x,
        point.y - self.floatingDockDragStartPoint.y);
    CGPoint targetPosition = CGPointMake(
        self.floatingDockDragInitialCenter.x + delta.x,
        self.floatingDockDragInitialCenter.y + delta.y);
    CGPoint minimumCenter = self.floatingDockDirectPanMinimumCenter;
    CGPoint maximumCenter = self.floatingDockDirectPanMaximumCenter;
    if (maximumCenter.x < minimumCenter.x) {
        maximumCenter.x = minimumCenter.x;
    }
    if (maximumCenter.y < minimumCenter.y) {
        maximumCenter.y = minimumCenter.y;
    }
    targetPosition.x = MAX(minimumCenter.x,
                           MIN(maximumCenter.x, targetPosition.x));
    targetPosition.y = MAX(minimumCenter.y,
                           MIN(maximumCenter.y, targetPosition.y));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.floatingContainer.layer.position = targetPosition;
    [CATransaction commit];
}

- (void)flushFloatingDockInputFrame:(CADisplayLink *)displayLink {
    if (displayLink && self.floatingDockInputSessionActive) {
        NSTimeInterval timestamp = displayLink.timestamp;
        NSTimeInterval targetDelta = displayLink.targetTimestamp - timestamp;
        NSTimeInterval nominalInterval =
            self.floatingDockPerfMaximumFramesPerSecond > 0
                ? 1.0 / (CGFloat)self.floatingDockPerfMaximumFramesPerSecond
                : 1.0 / 60.0;
        if (targetDelta <= 0.0) {
            targetDelta = nominalInterval;
        }
        self.floatingDockPerfLastTargetTimestamp =
            displayLink.targetTimestamp;
        self.floatingDockPerfTargetDeltaSumMs += targetDelta * 1000.0;
        self.floatingDockPerfMaximumTargetDeltaMs =
            MAX(self.floatingDockPerfMaximumTargetDeltaMs,
                targetDelta * 1000.0);
        self.floatingDockPerfCallbackCount += 1;
        self.floatingDockPerfRenderFrames += 1;
        [self observeFloatingDockDisplayLinkInterval:timestamp];
        if (self.floatingDockPerfLastTimestamp > 0.0 &&
            timestamp > self.floatingDockPerfLastTimestamp) {
            NSTimeInterval actualCallbackDelta =
                timestamp - self.floatingDockPerfLastTimestamp;
            NSTimeInterval callbackGap = actualCallbackDelta;
            self.floatingDockPerfActualCallbackDeltaSumMs +=
                actualCallbackDelta * 1000.0;
            self.floatingDockPerfMaximumActualCallbackDeltaMs =
                MAX(self.floatingDockPerfMaximumActualCallbackDeltaMs,
                    actualCallbackDelta * 1000.0);
            self.floatingDockPerfMaximumCallbackGap =
                MAX(self.floatingDockPerfMaximumCallbackGap, callbackGap);
            NSInteger callbackIntervals =
                MAX(1, (NSInteger)llround(callbackGap / nominalInterval));
            if (callbackIntervals > 1) {
                // This remains an estimate: ProMotion may legally vary its
                // cadence, while renderFrames records the actual callbacks.
                self.floatingDockPerfMissedVsync +=
                    (NSUInteger)(callbackIntervals - 1);
                self.floatingDockPerfCallbackGapEstimate +=
                    (NSUInteger)(callbackIntervals - 1);
            }
        }
        if (self.floatingDockPerfLastRenderTimestamp > 0.0 &&
            timestamp > self.floatingDockPerfLastRenderTimestamp) {
            NSTimeInterval frameMs =
                (timestamp - self.floatingDockPerfLastRenderTimestamp) * 1000.0;
            self.floatingDockPerfFrameSumMs += frameMs;
            self.floatingDockPerfMaximumFrameMs =
                MAX(self.floatingDockPerfMaximumFrameMs, frameMs);
            if (!self.floatingDockPerfFrameSamples) {
                self.floatingDockPerfFrameSamples =
                    [NSMutableArray arrayWithCapacity:128];
            }
            [self.floatingDockPerfFrameSamples addObject:@(frameMs)];
        }
        self.floatingDockPerfLastTimestamp = timestamp;
        self.floatingDockPerfLastRenderTimestamp = timestamp;
    }
    if (!self.floatingDockInputFramePending) {
        return;
    }
    self.floatingDockInputFramePending = NO;
    if (self.floatingDockInputFrameGeneration !=
            self.floatingDockInputGeneration ||
        self.floatingWindow.hidden) {
        return;
    }
    self.floatingDockPerfConsumedFrameCount += 1;
    [self applyFloatingDockInputPoint:self.floatingDockInputFramePoint];
}

- (void)flushFloatingDockInputFrameImmediately {
    [self flushFloatingDockInputFrame:nil];
}

- (void)cancelFloatingDockInputUpdates {
    self.floatingDockInputFramePending = NO;
    [self setFloatingDockDisplayLinkActive:NO];
}

- (void)applyFloatingDockInputPoint:(CGPoint)point {
    if (self.floatingWindow.hidden) {
        return;
    }
    if (self.floatingDockInputMode == FLMFloatingDockInputModeHiddenReveal ||
        self.floatingDockHideGestureActive) {
        [self updateFloatingDockHiddenRevealForPoint:point];
        return;
    }

    UIView *rootView = self.floatingWindow.rootViewController.view;
    if (self.floatingDockInputMode == FLMFloatingDockInputModeResize ||
        self.floatingDockInputTargetsResize) {
        CGFloat horizontalOutward =
            self.floatingDockedOnRight
                ? self.floatingResizeStartPoint.x - point.x
                : point.x - self.floatingResizeStartPoint.x;
        CGFloat verticalOutward = point.y - self.floatingResizeStartPoint.y;
        CGFloat delta = (horizontalOutward + verticalOutward) * 0.5;
        CGFloat requestedWidth =
            CGRectGetWidth(self.floatingResizeInitialFrame) + delta;
        CGFloat width = requestedWidth;
        if (requestedWidth > FLMMaximumDockWidth) {
            width = FLMMaximumDockWidth +
                    MIN(16.0,
                        (requestedWidth - FLMMaximumDockWidth) * 0.60);
        }
        width = MAX(FLMMinimumDockPresentationWidth, width);
        if (!self.floatingResizeCenterReady && requestedWidth >= 286.0) {
            self.floatingResizeCenterReady = YES;
            if (@available(iOS 10.0, *)) {
                UIImpactFeedbackGenerator *feedback =
                    [[UIImpactFeedbackGenerator alloc]
                        initWithStyle:UIImpactFeedbackStyleMedium];
                [feedback impactOccurred];
            }
        } else if (self.floatingResizeCenterReady && requestedWidth <= 278.0) {
            self.floatingResizeCenterReady = NO;
        }
        CGRect centeredFrame = [self centeredFloatingFrame];
        CGFloat aspectRatio =
            CGRectGetWidth(centeredFrame) /
            MAX(1.0, CGRectGetHeight(centeredFrame));
        CGFloat height = width / MAX(0.1, aspectRatio);
        CGFloat top = CGRectGetMinY(self.floatingResizeInitialFrame);
        CGFloat anchorX =
            self.floatingDockedOnRight
                ? CGRectGetMaxX(self.floatingResizeInitialFrame)
                : CGRectGetMinX(self.floatingResizeInitialFrame);
        CGRect visualFrame =
            CGRectMake(self.floatingDockedOnRight ? anchorX - width : anchorX,
                       top, width, height);
        CGFloat scale =
            width / MAX(1.0, [self effectiveCenteredCardWidth]);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        // Resize samples stay on the compositor path as well: only the
        // presentation layer position/transform changes while the finger is
        // down.  Bounds, host layout, shared state and disk I/O wait for the
        // single settle transaction after Ended.
        self.floatingContainer.layer.position =
            CGPointMake(CGRectGetMidX(visualFrame),
                        CGRectGetMidY(visualFrame));
        self.floatingContainer.layer.transform =
            CATransform3DMakeAffineTransform(CGAffineTransformMakeScale(scale,
                                                                         scale));
        self.floatingDockWidth = width;
        self.floatingDockVerticalCenter = CGRectGetMidY(visualFrame);
        [CATransaction commit];
        [self recordFloatingDockRenderCommitAtTimestamp:CACurrentMediaTime()];
        return;
    }
    if (self.floatingDockInputMode != FLMFloatingDockInputModeCardDrag) {
        return;
    }
    CGFloat movement =
        hypot(point.x - self.floatingDockDragStartPoint.x,
              point.y - self.floatingDockDragStartPoint.y);
    if (!self.floatingDockGlobalDragActivated && movement >= 5.0) {
        [self activateFloatingDockDragForGeneration:
                  self.floatingDockInputGeneration];
    }
    if (!self.floatingDockGlobalDragActivated) {
        return;
    }
    CGPoint delta =
        CGPointMake(point.x - self.floatingDockDragStartPoint.x,
                    point.y - self.floatingDockDragStartPoint.y);
    CGRect bounds = rootView.bounds;
    UIEdgeInsets safeInsets = rootView.safeAreaInsets;
    UIView *movingView = self.floatingContainer;
    CGRect movingFrame = [self floatingContainerPresentationFrame];
    CGFloat halfWidth = CGRectGetWidth(movingFrame) * 0.5;
    CGFloat halfHeight = CGRectGetHeight(movingFrame) * 0.5;
    CGPoint center =
        CGPointMake(self.floatingDockDragInitialCenter.x + delta.x,
                    self.floatingDockDragInitialCenter.y + delta.y);
    CGFloat minimumCenterX = safeInsets.left + halfWidth;
    CGFloat maximumCenterX =
        CGRectGetWidth(bounds) - safeInsets.right - halfWidth;
    if (maximumCenterX < minimumCenterX) {
        maximumCenterX = minimumCenterX;
    }
    center.x = MAX(minimumCenterX,
                   MIN(maximumCenterX, center.x));
    center.y = MAX(safeInsets.top + halfHeight,
                   MIN(CGRectGetHeight(bounds) - safeInsets.bottom - halfHeight,
                       center.y));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // The dock card has no Auto Layout constraints. Move its backing layer
    // directly so each display-link sample only changes the composited
    // position; wrapping the same update in UIView's animation machinery was
    // needlessly entering view/layout bookkeeping on every sample.
    movingView.layer.position = center;
    self.floatingDockVerticalCenter = center.y;
    // Keep only the gate rectangle in sync with the composited drag.  This is
    // a plain CGRect assignment (no window layout or lock query) and prevents
    // a second touch on the moved snapshot from reaching the remote surface.
    if (self.floatingDockTouchGateWindow.dockTouchGateEnabled) {
        CGRect compositedFrame =
            CGRectMake(center.x - CGRectGetWidth(movingFrame) * 0.5,
                       center.y - CGRectGetHeight(movingFrame) * 0.5,
                       CGRectGetWidth(movingFrame),
                       CGRectGetHeight(movingFrame));
        self.floatingDockTouchGateWindow.dockCardFrame =
            CGRectInset(compositedFrame, -3.0, -3.0);
    }
    [CATransaction commit];
    [self recordFloatingDockRenderCommitAtTimestamp:CACurrentMediaTime()];
}

- (void)transitionFloatingWindowToHiddenAnimated:(BOOL)animated {
    if (!self.floatingDocked || self.floatingDockHidden ||
        self.floatingWindow.hidden) {
        return;
    }
    CGRect source = [self floatingContainerPresentationFrame];
    [self suspendFloatingKeyboardPresentationForDockMode];
    self.floatingDockHidden = YES;
    self.floatingDockHideReady = NO;
    self.floatingDockTransitionActive = YES;
    self.floatingDockControlTransition =
        FLMFloatingDockControlTransitionHide;
    self.floatingDockControlTargetFrame = CGRectNull;
    self.floatingDockControlTransitionGeneration += 1;
    [self setFloatingDockRoutingSuppressed:YES];
    CGFloat verticalCenter = CGRectGetMidY(source);
    self.floatingDockVerticalCenter = verticalCenter;
    CGRect target =
        [self dockedHiddenFloatingFrameOnRight:self.floatingDockedOnRight
                                          width:self.floatingDockWidth
                        preservingVerticalCenter:verticalCenter];
    self.floatingDockControlTargetFrame = target;
    self.floatingDockTouchGateTransitionFrame =
        FLMDockTransitionEnvelope(
            source,
            target,
            self.floatingWindow.rootViewController.view.bounds);
    [self updateFloatingDockTouchGate];
    CGFloat dockScale = [self floatingDockPresentationScale];
    void (^changes)(void) = ^{
        self.floatingContainer.center =
            CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
        self.floatingContainer.transform =
            CGAffineTransformMakeScale(dockScale, dockScale);
        self.floatingContainer.layer.cornerRadius = 22.0;
        self.floatingDockShadowView.alpha = 0.0;
        self.floatingDimView.alpha = 0.0;
        self.floatingResizeHandle.hidden = YES;
        self.floatingHandle.alpha = 1.0;
        [self layoutFloatingHandleForCurrentContainer];
    };
    void (^completion)(void) = ^{
        self.floatingDockTransitionAnimator = nil;
        self.floatingDockTransitionActive = NO;
        self.floatingDockTouchGateTransitionFrame = CGRectNull;
        self.floatingDockControlTransition =
            FLMFloatingDockControlTransitionNone;
        self.floatingDockControlTargetFrame = CGRectNull;
        self.floatingDockPresentationMode =
            FLMFloatingDockPresentationModeHiddenDock;
        [self configureFloatingInteractionForDockedState];
        [self setFloatingDockRoutingSuppressed:NO];
    };
    if (!animated) {
        changes();
        completion();
    } else {
        UIViewPropertyAnimator *hideAnimator =
            [[UIViewPropertyAnimator alloc]
                initWithDuration:0.24
                          curve:UIViewAnimationCurveEaseOut
                     animations:changes];
        self.floatingDockTransitionAnimator = hideAnimator;
        [hideAnimator addCompletion:^(__unused UIViewAnimatingPosition position) {
            completion();
        }];
        [hideAnimator startAnimation];
    }
}

- (void)finishFloatingDockHiddenGesture:(BOOL)shouldHide
                                atPoint:(CGPoint)point {
    (void)point;
    if (!self.floatingDocked || self.floatingWindow.hidden) {
        [self setFloatingDockRoutingSuppressed:NO];
        return;
    }
    self.floatingDockHideGestureActive = NO;
    self.floatingDockHideReady = NO;
    self.floatingDockInputGeneration += 1;
    [self setFloatingDockRoutingSuppressed:YES];
    [self setFloatingApplicationInputBlocked:YES];
    CGRect currentPresentationFrame = [self floatingContainerPresentationFrame];
    CGFloat verticalCenter = CGRectGetMidY(currentPresentationFrame);
    self.floatingDockVerticalCenter = verticalCenter;
    if (shouldHide) {
        [self suspendFloatingKeyboardPresentationForDockMode];
        CGRect source = currentPresentationFrame;
        self.floatingDockHidden = YES;
        self.floatingDockTransitionActive = YES;
        self.floatingDockControlTransition =
            FLMFloatingDockControlTransitionHide;
        NSUInteger hideTransitionGeneration =
            ++self.floatingDockControlTransitionGeneration;
        CGRect target =
            [self dockedHiddenFloatingFrameOnRight:self.floatingDockedOnRight
                                              width:self.floatingDockWidth
                            preservingVerticalCenter:verticalCenter];
        // Single-stage edge-hide: the grab bar and the card travel together,
        // so the bar glides up from the card's corner to its edge landing
        // spot while the card slides off-screen, instead of popping in.
        UIView *rootView = self.floatingWindow.rootViewController.view;
        CGRect bounds = rootView.bounds;
        self.floatingDockTouchGateTransitionFrame =
            FLMDockTransitionEnvelope(source, target, bounds);
        self.floatingDockControlTargetFrame = target;
        [self updateFloatingDockTouchGate];
        CGFloat handleWidth = 44.0;
        CGFloat handleHeight = 72.0;
        CGRect handleLanding =
            CGRectMake(self.floatingDockedOnRight
                           ? CGRectGetWidth(bounds) - handleWidth
                           : 0.0,
                       CGRectGetMinY(source) + 24.0,
                       handleWidth,
                       handleHeight);
        // Start the glide from wherever the drag left the bar.  The old code
        // snapped the bar back to the L-grip's frame at the card corner,
        // which was already off-screen at release, so the bar visibly flew
        // in from nowhere instead of continuing its travel to the edge.
        CGRect handleStart = self.floatingHandle.frame;
        if (CGRectIsEmpty(handleStart)) {
            handleStart = handleLanding;
        }
        self.floatingHandle.hidden = NO;
        self.floatingHandle.userInteractionEnabled = NO;
        self.floatingHandle.frame = handleStart;
        // Switch the grab bar to its hidden vertical form before the glide
        // animation starts, so the bar travels as a vertical line instead of
        // flying out as a horizontal strip and then snapping vertical at the
        // end.
        self.floatingHandleBar.frame =
            CGRectMake(self.floatingDockedOnRight ? 36.0 : 3.0,
                       floor((CGRectGetHeight(handleStart) - 44.0) * 0.5),
                       5.0,
                       44.0);
        [self.floatingWindow.rootViewController.view
            bringSubviewToFront:self.floatingHandle];
        UIViewPropertyAnimator *hideAnimator =
            [[UIViewPropertyAnimator alloc]
                initWithDuration:0.24
                          curve:UIViewAnimationCurveEaseOut
                     animations:^ {
                             self.floatingContainer.center =
                                 CGPointMake(CGRectGetMidX(target),
                                             CGRectGetMidY(target));
                             self.floatingContainer.transform =
                                 CGAffineTransformMakeScale(
                                     [self floatingDockPresentationScale],
                                     [self floatingDockPresentationScale]);
        self.floatingContainer.layer.cornerRadius = 22.0;
        self.floatingHandle.frame = handleLanding;
                             self.floatingHandle.alpha = 1.0;
                             self.floatingDimView.alpha = 0.0;
                         }];
        self.floatingDockTransitionAnimator = hideAnimator;
        [hideAnimator addCompletion:^(__unused UIViewAnimatingPosition position) {
                               self.floatingDockTransitionAnimator = nil;
                               if (hideTransitionGeneration !=
                                       self.floatingDockControlTransitionGeneration) {
                                   return;
                               }
                               self.floatingDockTransitionActive = NO;
                               self.floatingDockTouchGateTransitionFrame = CGRectNull;
                               self.floatingDockControlTransition =
                                   FLMFloatingDockControlTransitionNone;
                               self.floatingDockControlTargetFrame = CGRectNull;
                               self.floatingDockPresentationMode =
                                   FLMFloatingDockPresentationModeHiddenDock;
                               [self configureFloatingInteractionForDockedState];
                              [self setFloatingDockRoutingSuppressed:NO];
                          }];
        [hideAnimator startAnimation];
        return;
    }

    // Revealing the hidden dock is a state handoff, not a presentation that
    // needs a settle animation.  Keeping a transition window here lets the
    // system recognizers arbitrate one more touch against the old hidden
    // route, which is the source of the occasional card-content activation.
    self.floatingDockHidden = NO;
    self.floatingDockTransitionActive = YES;
    self.floatingDockControlTransition =
        FLMFloatingDockControlTransitionReveal;
    NSUInteger revealTransitionGeneration =
        ++self.floatingDockControlTransitionGeneration;
    CGRect target =
        [self dockedFloatingFrameOnRight:self.floatingDockedOnRight
                                   width:self.floatingDockWidth
                 preservingVerticalCenter:verticalCenter];
    [self setFloatingApplicationInputBlocked:YES];
    // No UIView animation and no completion callback: apply the complete
    // docked geometry and interaction state in this one main-thread turn.
    // UIKit cannot deliver another touch between these statements, and the
    // next touch sees the final docked route immediately.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [UIView performWithoutAnimation:^{
        [self configureFloatingContainerForDockPresentationAtCenter:
                  CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target))
                                                          scale:[self floatingDockPresentationScale]];
        self.floatingContainer.layer.cornerRadius = 22.0;
        self.floatingDockShadowView.alpha = 0.0;
        self.floatingDimView.alpha = 0.0;
        self.floatingResizeHandle.hidden = YES;
        self.floatingHandle.alpha = 0.0;
        [self layoutFloatingHandleForCurrentContainer];
    }];
    [CATransaction commit];
    self.floatingDockTransitionActive = NO;
    // The reveal gesture has ended; do not carry the old transition cutoff
    // into the first deliberate touch on the newly docked card.
    self.floatingDockInputBlockedUntilNextTouch = NO;
    self.floatingDockInputBlockCutoffTimestamp = 0.0;
    if (revealTransitionGeneration == self.floatingDockControlTransitionGeneration) {
        self.floatingDockControlTransition =
            FLMFloatingDockControlTransitionNone;
    }
    self.floatingDockControlTargetFrame = CGRectNull;
    self.floatingDockPresentationMode =
        FLMFloatingDockPresentationModeDocked;
    [self configureFloatingInteractionForDockedState];
    [self setFloatingDockRoutingSuppressed:NO];
}

- (void)updateFloatingDockHiddenRevealForPoint:(CGPoint)point {
    if (!self.floatingDocked || !self.floatingDockHideGestureActive ||
        self.floatingWindow.hidden) {
        return;
    }
    BOOL revealing = self.floatingDockHidden;
    CGFloat travel = revealing
                         ? (self.floatingDockedOnRight
                                ? self.floatingDockHideStartPoint.x - point.x
                                : point.x - self.floatingDockHideStartPoint.x)
                         : (self.floatingDockedOnRight
                                ? point.x - self.floatingDockHideStartPoint.x
                                : self.floatingDockHideStartPoint.x - point.x);
    travel = MAX(0.0, travel);
    CGFloat distance = MAX(40.0, FLMCenteredDockActivationDistance);
    CGFloat progress = MIN(1.0, travel / distance);
    CGRect start = self.floatingDockHideInitialFrame;
    CGFloat verticalCenter = CGRectGetMidY(start);
    self.floatingDockVerticalCenter = verticalCenter;
    CGRect target = revealing
                        ? [self dockedFloatingFrameOnRight:self.floatingDockedOnRight
                                                       width:self.floatingDockWidth
                                    preservingVerticalCenter:verticalCenter]
                        : [self dockedHiddenFloatingFrameOnRight:self.floatingDockedOnRight
                                                            width:self.floatingDockWidth
                                          preservingVerticalCenter:verticalCenter];
    CGRect visual = CGRectMake(CGRectGetMinX(start) +
                                   (CGRectGetMinX(target) - CGRectGetMinX(start)) * progress,
                               CGRectGetMinY(start) +
                                   (CGRectGetMinY(target) - CGRectGetMinY(start)) * progress,
                               CGRectGetWidth(start) +
                                   (CGRectGetWidth(target) - CGRectGetWidth(start)) * progress,
                               CGRectGetHeight(start) +
                                   (CGRectGetHeight(target) - CGRectGetHeight(start)) * progress);
    // The hidden grab bar tracks the drag from the card edge to its landing
    // position while the card disappears.
    CGRect bounds = self.floatingWindow.rootViewController.view.bounds;
    CGFloat handleWidth = 44.0;
    CGFloat handleHeight = 72.0;
    CGRect hiddenFrame =
        [self dockedHiddenFloatingFrameOnRight:self.floatingDockedOnRight
                                          width:self.floatingDockWidth
                        preservingVerticalCenter:verticalCenter];
    CGRect handleLanding =
        CGRectMake(self.floatingDockedOnRight
                       ? CGRectGetWidth(bounds) - handleWidth
                       : 0.0,
                   CGRectGetMinY(hiddenFrame) + 24.0,
                   handleWidth,
                   handleHeight);
    CGRect handleOrigin = self.floatingHandle.frame;
    if (CGRectIsEmpty(handleOrigin)) {
        handleOrigin = handleLanding;
    }
    [UIView performWithoutAnimation:^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.floatingContainer.layer.position =
            CGPointMake(CGRectGetMidX(visual), CGRectGetMidY(visual));
        CGFloat dockScale = [self floatingDockPresentationScale];
        self.floatingContainer.layer.transform =
            CATransform3DMakeScale(dockScale, dockScale, 1.0);
        [CATransaction commit];
        self.floatingDockShadowView.alpha = 0.0;
        self.floatingHandle.hidden = NO;
        self.floatingHandle.alpha = revealing ? 1.0 - progress : progress;
        // Keep the bar in its vertical hidden form while the handle tracks
        // the drag; only the handle container moves, never the bar shape.
        self.floatingHandleBar.frame =
            CGRectMake(self.floatingDockedOnRight ? 36.0 : 3.0,
                       floor((handleHeight - 44.0) * 0.5),
                       5.0,
                       44.0);
        CGFloat handleX =
            revealing
                ? CGRectGetMinX(handleLanding) +
                      (CGRectGetMinX(handleOrigin) -
                       CGRectGetMinX(handleLanding)) *
                          progress
                : CGRectGetMinX(handleOrigin) +
                      (CGRectGetMinX(handleLanding) -
                       CGRectGetMinX(handleOrigin)) *
                          progress;
        CGFloat handleY =
            revealing
                ? CGRectGetMinY(handleLanding) +
                      (CGRectGetMinY(handleOrigin) -
                       CGRectGetMinY(handleLanding)) *
                          progress
                : CGRectGetMinY(handleOrigin) +
                      (CGRectGetMinY(handleLanding) -
                       CGRectGetMinY(handleOrigin)) *
                          progress;
        self.floatingHandle.frame =
            CGRectMake(handleX, handleY, handleWidth, handleHeight);
    }];
    // The gate window already owns the in-flight touch.  Re-running its full
    // cross-window/lock-state refresh for every display-link sample was a
    // measurable source of hidden-reveal hitching; terminal configuration
    // publishes the final geometry once.
    if (!self.floatingDockInputSessionActive) {
        [self updateFloatingDockTouchGate];
    }
}

- (BOOL)floatingDockControlOwnsPoint:(CGPoint)point {
    if (self.floatingWindow.hidden) {
        return NO;
    }
    if (self.floatingDockHidden) {
        return !self.floatingHandle.hidden &&
               CGRectContainsPoint(CGRectInset(self.floatingHandle.frame,
                                               -18.0,
                                               -18.0),
                                   point);
    }
    if ([self floatingResizeControlContainsPoint:point]) {
        return YES;
    }
    CGRect cardFrame = [self floatingContainerPresentationFrame];
    if (self.floatingDockTransitionActive &&
        !CGRectIsNull(self.floatingDockControlTargetFrame)) {
        cardFrame = CGRectUnion(cardFrame,
                                self.floatingDockControlTargetFrame);
    }
    return !CGRectIsNull(cardFrame) && CGRectContainsPoint(cardFrame, point);
}

- (void)interruptFloatingDockTransitionAtPoint:(CGPoint)point {
    if (!self.floatingDockTransitionActive &&
        !self.floatingDockTransitionAnimator.running) {
        return;
    }
    FLMFloatingDockControlTransition interruptedTransition =
        self.floatingDockControlTransition;
    CALayer *containerLayer = self.floatingContainer.layer;
    CALayer *presentationLayer = containerLayer.presentationLayer;
    CGPoint presentationPosition = presentationLayer
                                       ? presentationLayer.position
                                       : containerLayer.position;
    CATransform3D presentationTransform = presentationLayer
                                               ? presentationLayer.transform
                                               : containerLayer.transform;
    CGRect presentationFrame = [self floatingContainerPresentationFrame];
    if (CGRectIsNull(presentationFrame) || CGRectIsEmpty(presentationFrame)) {
        presentationFrame = self.floatingContainer.frame;
    }
    CGFloat presentationScale =
        FLMUniformScaleFromTransform(presentationTransform);
    FLMEnqueueDiagnosticLine(
        @"sb dock-transition-takeover enabled=1 transition=%@ point={%.1f,%.1f} presentation=%@ presentationPosition={%.1f,%.1f} presentationScale=%.6f",
        FLMFloatingDockControlTransitionName(interruptedTransition),
        point.x,
        point.y,
        NSStringFromCGRect(presentationFrame),
        presentationPosition.x,
        presentationPosition.y,
        presentationScale);
    self.floatingDockControlTransitionGeneration += 1;
    UIViewPropertyAnimator *animator = self.floatingDockTransitionAnimator;
    if (animator) {
        [animator stopAnimation:YES];
        [animator finishAnimationAtPosition:UIViewAnimatingPositionCurrent];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [containerLayer removeAllAnimations];
    if ([self ensureSessionCanonicalGeometry]) {
        containerLayer.bounds = self.sessionCanonicalGeometry.centeredBounds;
    }
    containerLayer.position = presentationPosition;
    containerLayer.transform = presentationTransform;
    [CATransaction commit];
    self.floatingDockTransitionAnimator = nil;
    self.floatingDockTransitionActive = NO;
    self.floatingDockControlTransition =
        FLMFloatingDockControlTransitionNone;
    self.floatingDockControlTargetFrame = CGRectNull;
    self.floatingDockControlDefersKeyboardTeardown = NO;
    self.floatingDockTouchGateTransitionFrame = CGRectNull;
    if (interruptedTransition == FLMFloatingDockControlTransitionRestore) {
        self.floatingDocked = NO;
        self.floatingDockHidden = NO;
        [self flushFloatingKeyboardAvoidancePublishAfterDock];
    } else if (interruptedTransition == FLMFloatingDockControlTransitionEntry ||
               interruptedTransition == FLMFloatingDockControlTransitionSnap ||
               interruptedTransition == FLMFloatingDockControlTransitionResize ||
               interruptedTransition == FLMFloatingDockControlTransitionReveal) {
        self.floatingDocked = YES;
        self.floatingDockHidden = NO;
    } else if (interruptedTransition == FLMFloatingDockControlTransitionHide) {
        self.floatingDocked = YES;
        self.floatingDockHidden = YES;
    }
    if (self.floatingDockContentTailProtected) {
        [self releaseFloatingContentProtectionAfterDockTransition:
                  self.floatingDockContentProtectionGeneration];
    }
    [self configureFloatingInteractionForDockedState];
    [self updateFloatingDockTouchGate];
}

- (void)handleFloatingDockInputGesture:(FLMCornerGestureRecognizer *)gesture {
    CGPoint rawPoint = [gesture locationInView:nil];
    CGPoint point = FLMVisualPointFromRawPoint(rawPoint);
    self.floatingDockInputLatestPoint = point;

    BOOL terminal = gesture.state == UIGestureRecognizerStateEnded ||
                    gesture.state == UIGestureRecognizerStateCancelled ||
                    gesture.state == UIGestureRecognizerStateFailed;
    BOOL controlPoint = [self floatingDockControlOwnsPoint:point];
    BOOL transitionBarrier =
        self.floatingDockTransitionActive &&
        !CGRectIsNull(self.floatingDockTouchGateTransitionFrame) &&
        CGRectContainsPoint(self.floatingDockTouchGateTransitionFrame, point);
    BOOL contentBarrier =
        self.floatingDockContentTailProtected &&
        !CGRectIsNull(self.floatingDockContentProtectionFrame) &&
        CGRectContainsPoint(self.floatingDockContentProtectionFrame, point);
    BOOL transitionTakeover =
        controlPoint && self.floatingDockTransitionActive;
    if (gesture.state == UIGestureRecognizerStateBegan && controlPoint &&
        self.floatingDockTransitionActive) {
        [self interruptFloatingDockTransitionAtPoint:point];
        controlPoint = [self floatingDockControlOwnsPoint:point];
        transitionBarrier = NO;
        contentBarrier = NO;
    }
    if (gesture.state == UIGestureRecognizerStateBegan &&
        !controlPoint && (transitionBarrier || contentBarrier)) {
        self.floatingDockBarrierTouchActive = YES;
        [self setFloatingDockRoutingSuppressed:YES];
        [self setFloatingApplicationInputBlocked:YES];
        FLMEnqueueDiagnosticLine(
                @"sb dock-input-barrier state=began accepted=0 transition=%d protected=%d kind=%@ point={%.1f,%.1f} activeTouches=%lu",
            transitionBarrier,
            contentBarrier,
            FLMFloatingDockControlTransitionName(
                self.floatingDockControlTransition),
            point.x,
            point.y,
            (unsigned long)gesture.flmActiveTouchCount);
        return;
    }
    if (self.floatingDockBarrierTouchActive) {
        if (terminal) {
            self.floatingDockBarrierTouchActive = NO;
            FLMEnqueueDiagnosticLine(
                @"sb dock-input-barrier state=ended recognizerState=%ld point={%.1f,%.1f} activeTouches=%lu",
                (long)gesture.state,
                point.x,
                point.y,
                (unsigned long)gesture.flmActiveTouchCount);
            if (self.floatingDockContentTailProtected) {
                [self releaseFloatingContentProtectionAfterDockTransition:
                          self.floatingDockContentProtectionGeneration];
            }
        }
        return;
    }

    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self cancelFloatingDockInputUpdates];
        self.floatingDockInputGeneration += 1;
        self.floatingDockPerfCallbackCount = 0;
        self.floatingDockPerfConsumedFrameCount = 0;
        self.floatingDockPerfInputSampleCount = 0;
        self.floatingDockPerfCoalescedSampleCount = 0;
        self.floatingDockPerfCallbackGapEstimate = 0;
        self.floatingDockPerfRenderFrames = 0;
        self.floatingDockPerfMissedVsync = 0;
        self.floatingDockPerfFrameSumMs = 0.0;
        self.floatingDockPerfMaximumFrameMs = 0.0;
        self.floatingDockPerfLastRenderTimestamp = 0.0;
        self.floatingDockPerfFrameSamples =
            [NSMutableArray arrayWithCapacity:128];
        self.floatingDockPerfActualCallbackDeltaSumMs = 0.0;
        self.floatingDockPerfTargetDeltaSumMs = 0.0;
        self.floatingDockPerfMaximumActualCallbackDeltaMs = 0.0;
        self.floatingDockPerfMaximumTargetDeltaMs = 0.0;
        self.floatingDockPerfLastTargetTimestamp = 0.0;
        self.floatingDockPerfLastTimestamp = 0.0;
        self.floatingDockPerfMaximumCallbackGap = 0.0;
        self.floatingDockRendererMode =
            FLMFloatingDockRendererModeDisplayLink;
        self.floatingDockDisplayLinkCapped60 = NO;
        self.floatingDockDisplayLinkProbeIntervalCount = 0;
        self.floatingDockDisplayLinkProbeSlowCount = 0;
        self.floatingDockDisplayLinkProbeLastTimestamp = 0.0;
        self.floatingDockPerfInputDeltaSumMs = 0.0;
        self.floatingDockPerfLastInputTimestamp = 0.0;
        self.floatingDockPerfRenderCommitCount = 0;
        self.floatingDockPerfRenderDeltaSumMs = 0.0;
        self.floatingDockPerfLastRenderCommitTimestamp = 0.0;
        self.floatingDockInputMode = FLMFloatingDockInputModeNone;
        self.floatingDockInputSessionActive = NO;
        self.floatingDockInputTargetsResize = NO;
        self.floatingDockHideGestureActive = NO;
        self.floatingDockHideReady = NO;
        self.floatingDockHideStartPoint = point;
        self.floatingDockHideInitialFrame =
            [self floatingContainerPresentationFrame];
        self.floatingDockGlobalDragActivated = NO;
        BOOL pointIsOwned = [self floatingDockControlOwnsPoint:point];
        BOOL staleStream =
            self.floatingDockInputBlockedUntilNextTouch &&
            self.floatingDockInputBlockCutoffTimestamp > 0.0 &&
            gesture.flmFirstTouchTimestamp > 0.0 &&
            gesture.flmFirstTouchTimestamp <=
                self.floatingDockInputBlockCutoffTimestamp + 0.001;
        BOOL canBegin = (self.floatingDocked || self.floatingDockHidden ||
                         transitionTakeover) &&
                        !self.floatingWindow.hidden &&
                        (!self.floatingDockTransitionActive || transitionTakeover) &&
                        !FLMDeviceIsLocked() && pointIsOwned && !staleStream;
        if (!canBegin) {
            // System-registered recognizers can continue to report the tail
            // of a touch that started before the card became docked.  Mark
            // that stream as foreign so its later Changed/Ended callbacks
            // cannot be mistaken for a fresh dock tap or drag.
            self.floatingDockInputBlockedUntilNextTouch = YES;
            if (self.floatingDockInputBlockCutoffTimestamp <= 0.0) {
                self.floatingDockInputBlockCutoffTimestamp =
                    gesture.flmFirstTouchTimestamp > 0.0
                        ? gesture.flmFirstTouchTimestamp
                        : CACurrentMediaTime();
            }
            if (!self.floatingDockTransitionActive &&
                !self.floatingDockContentTailProtected) {
                [self setFloatingDockRoutingSuppressed:NO];
            }
            FLMEnqueueDiagnosticLine(
                @"sb dock-input-ignored state=began docked=%d hidden=%d transition=%d owned=%d stale=%d blocked=%d point={%.1f,%.1f}",
                self.floatingDocked,
                self.floatingDockHidden,
                self.floatingDockTransitionActive,
                pointIsOwned,
                staleStream,
                self.floatingDockInputBlockedUntilNextTouch,
                point.x,
                point.y);
            return;
        }
        self.floatingDockInputBlockedUntilNextTouch = NO;
        self.floatingDockInputBlockCutoffTimestamp = 0.0;
        [self setFloatingDockRoutingSuppressed:YES];
        if (self.floatingDocked && !self.floatingDockHidden) {
            [self setFloatingApplicationInputBlocked:YES];
        }
        self.floatingDockInputSessionActive = YES;
        if (self.floatingDockHidden) {
            self.floatingDockInputMode =
                FLMFloatingDockInputModeHiddenReveal;
        } else if ([self floatingResizeControlContainsPoint:point]) {
            self.floatingDockInputMode = FLMFloatingDockInputModeResize;
        } else {
            self.floatingDockInputMode = FLMFloatingDockInputModeCardDrag;
        }
        self.floatingDockInputTargetsResize =
            self.floatingDockInputMode == FLMFloatingDockInputModeResize;
        FLMEnqueueDiagnosticLine(
            @"sb dock-input-began mode=%@ generation=%lu transitionTakeover=enabled point={%.1f,%.1f} frame=%@ hidden=%d side=%@",
            FLMFloatingDockInputModeName(self.floatingDockInputMode),
            (unsigned long)self.floatingDockInputGeneration,
            point.x,
            point.y,
            NSStringFromCGRect([self floatingContainerPresentationFrame]),
            self.floatingDockHidden,
            self.floatingDockedOnRight ? @"right" : @"left");
        if (self.floatingDockInputMode == FLMFloatingDockInputModeHiddenReveal) {
            self.floatingDockHideGestureActive = YES;
            self.floatingDockHideStartPoint = point;
            self.floatingDockHideInitialFrame =
                [self floatingContainerPresentationFrame];
            return;
        }
        if (self.floatingDockInputMode == FLMFloatingDockInputModeResize) {
            self.floatingResizeStartPoint = point;
            self.floatingResizeInitialFrame =
                [self floatingContainerPresentationFrame];
            self.floatingResizeCenterReady = NO;
            if (@available(iOS 10.0, *)) {
                UIImpactFeedbackGenerator *feedback =
                    [[UIImpactFeedbackGenerator alloc]
                        initWithStyle:UIImpactFeedbackStyleMedium];
                [feedback impactOccurred];
            }
            return;
        }
        [self lockFloatingDockGeometryForDrag];
        self.floatingDockDragStartPoint = point;
        self.floatingDockDragInitialCenter = self.floatingContainer.center;
        return;
    }

    if (self.floatingDockInputBlockedUntilNextTouch ||
        !self.floatingDockInputSessionActive ||
        self.floatingDockInputMode == FLMFloatingDockInputModeNone) {
        if (gesture.state == UIGestureRecognizerStateEnded ||
            gesture.state == UIGestureRecognizerStateCancelled ||
            gesture.state == UIGestureRecognizerStateFailed) {
            self.floatingDockInputBlockedUntilNextTouch = NO;
            self.floatingDockInputBlockCutoffTimestamp = 0.0;
            self.floatingDockInputSessionActive = NO;
            self.floatingDockInputMode = FLMFloatingDockInputModeNone;
            self.floatingDockInputTargetsResize = NO;
            self.floatingDockInputGeneration += 1;
            [self cancelFloatingDockInputUpdates];
            if (!self.floatingDockTransitionActive &&
                !self.floatingDockContentTailProtected) {
                [self setFloatingDockRoutingSuppressed:NO];
            }
        }
        return;
    }

    if ((!self.floatingDocked && !self.floatingDockHidden) ||
        self.floatingWindow.hidden) {
        // The dock can disappear while a touch is in flight.  Do not let the
        // remainder of that touch enter the centered-card tap path.
        self.floatingDockInputBlockedUntilNextTouch = YES;
        if (self.floatingDockInputBlockCutoffTimestamp <= 0.0) {
            self.floatingDockInputBlockCutoffTimestamp =
                gesture.flmFirstTouchTimestamp > 0.0
                    ? gesture.flmFirstTouchTimestamp
                    : CACurrentMediaTime();
        }
        if (gesture.state == UIGestureRecognizerStateEnded ||
            gesture.state == UIGestureRecognizerStateCancelled ||
            gesture.state == UIGestureRecognizerStateFailed) {
            self.floatingDockInputSessionActive = NO;
            self.floatingDockInputMode = FLMFloatingDockInputModeNone;
            self.floatingDockInputTargetsResize = NO;
            self.floatingDockInputBlockCutoffTimestamp = 0.0;
            self.floatingDockInputGeneration += 1;
            [self cancelFloatingDockInputUpdates];
            if (!self.floatingDockTransitionActive &&
                !self.floatingDockContentTailProtected) {
                [self setFloatingDockRoutingSuppressed:NO];
            }
        }
        return;
    }

    if (!terminal) {
        if (self.floatingDockInputMode == FLMFloatingDockInputModeCardDrag) {
            CGFloat horizontalDelta =
                point.x - self.floatingDockHideStartPoint.x;
            CGFloat verticalDelta =
                point.y - self.floatingDockHideStartPoint.y;
            CGFloat outwardTravel = self.floatingDockedOnRight
                                         ? horizontalDelta
                                         : -horizontalDelta;
            BOOL clearHorizontalIntent =
                outwardTravel >= FLMFloatingDockHideIntentDistance &&
                fabs(horizontalDelta) >=
                    fabs(verticalDelta) *
                        FLMFloatingDockHideIntentHorizontalRatio;
            if (clearHorizontalIntent) {
                // Decide hide intent from the touch direction, even if the
                // ordinary card drag has already activated after a few points.
                // The old global-drag gate made a slower left-edge swipe miss
                // hidden mode permanently. Rebase the visual start here so a
                // late mode switch remains continuous instead of jumping back
                // to the touch-down frame.
                self.floatingDockHideStartPoint = point;
                self.floatingDockHideInitialFrame =
                    [self floatingContainerPresentationFrame];
                self.floatingDockInputMode =
                    FLMFloatingDockInputModeHiddenReveal;
                self.floatingDockHideGestureActive = YES;
                self.floatingDockHideReady = NO;
                self.floatingDockGlobalDragActivated = NO;
                FLMEnqueueDiagnosticLine(
                    @"sb dock-input-mode-change from=card-drag to=hidden-reveal travel=%.1f point={%.1f,%.1f}",
                    outwardTravel,
                    point.x,
                    point.y);
            }
        }
        CGPoint changedOrigin =
            self.floatingDockInputMode == FLMFloatingDockInputModeHiddenReveal
                ? self.floatingDockHideStartPoint
                : self.floatingDockInputMode == FLMFloatingDockInputModeResize
                      ? self.floatingResizeStartPoint
                      : self.floatingDockDragStartPoint;
        CGFloat changedMovement = hypot(point.x - changedOrigin.x,
                                        point.y - changedOrigin.y);
        BOOL realInteractiveUpdate =
            self.floatingDockInputMode == FLMFloatingDockInputModeResize ||
            (self.floatingDockInputMode ==
                 FLMFloatingDockInputModeHiddenReveal &&
             changedMovement > 1.0) ||
            (self.floatingDockInputMode == FLMFloatingDockInputModeCardDrag &&
             changedMovement >= 5.0);
        BOOL directPan =
            self.floatingDockInputMode == FLMFloatingDockInputModeCardDrag &&
            self.floatingDockDisplayLinkCapped60 &&
            self.floatingDockRendererMode ==
                FLMFloatingDockRendererModeDirectPan &&
            changedMovement >= 5.0;
        if (realInteractiveUpdate && !directPan) {
            [self setFloatingDockDisplayLinkActive:YES];
        }
        if (directPan) {
            [self recordFloatingDockInputSampleAtTimestamp:CACurrentMediaTime()];
            [self applyFloatingDockDirectPanPoint:point];
            [self recordFloatingDockRenderCommitAtTimestamp:CACurrentMediaTime()];
        } else {
            [self queueFloatingDockInputUpdateForPoint:point];
        }
        if (self.floatingDockInputMode == FLMFloatingDockInputModeHiddenReveal) {
            CGFloat outwardTravel = self.floatingDockedOnRight
                                         ? point.x - self.floatingDockHideStartPoint.x
                                         : self.floatingDockHideStartPoint.x - point.x;
            self.floatingDockHideReady =
                outwardTravel >= [self effectiveCenteredDockSwipeThreshold];
        }
        return;
    }

    FLMFloatingDockInputMode inputMode = self.floatingDockInputMode;
    BOOL wasGlobalDragActivated = self.floatingDockGlobalDragActivated;
    CGPoint movementOrigin = inputMode == FLMFloatingDockInputModeHiddenReveal
                                 ? self.floatingDockHideStartPoint
                                 : inputMode == FLMFloatingDockInputModeResize
                                       ? self.floatingResizeStartPoint
                                       : self.floatingDockDragStartPoint;
    CGFloat movement = hypot(point.x - movementOrigin.x,
                             point.y - movementOrigin.y);
    BOOL revealing = self.floatingDockHidden;
    CGFloat outwardTravel = revealing
                                ? (self.floatingDockedOnRight
                                       ? self.floatingDockHideStartPoint.x - point.x
                                       : point.x - self.floatingDockHideStartPoint.x)
                                : (self.floatingDockedOnRight
                                       ? point.x - self.floatingDockHideStartPoint.x
                                       : self.floatingDockHideStartPoint.x - point.x);
    BOOL terminalInteractiveUpdate =
        inputMode == FLMFloatingDockInputModeResize ||
        (inputMode == FLMFloatingDockInputModeHiddenReveal &&
         movement > 1.0) ||
        (inputMode == FLMFloatingDockInputModeCardDrag && movement >= 5.0);
    BOOL directPan =
        inputMode == FLMFloatingDockInputModeCardDrag &&
        self.floatingDockDisplayLinkCapped60 &&
        self.floatingDockRendererMode ==
            FLMFloatingDockRendererModeDirectPan;
    if (terminalInteractiveUpdate) {
        if (!directPan) {
            [self setFloatingDockDisplayLinkActive:YES];
        }
        // Always submit the terminal drag point before deciding where to
        // settle. A tap never reaches this compositor flush path.
        if (directPan) {
            [self recordFloatingDockInputSampleAtTimestamp:CACurrentMediaTime()];
            [self applyFloatingDockDirectPanPoint:point];
            [self recordFloatingDockRenderCommitAtTimestamp:CACurrentMediaTime()];
        } else {
            [self queueFloatingDockInputUpdateForPoint:point];
            [self flushFloatingDockInputFrameImmediately];
        }
    }
    [self cancelFloatingDockInputUpdates];
    NSArray<NSNumber *> *sortedFrameSamples =
        [self.floatingDockPerfFrameSamples
            sortedArrayUsingSelector:@selector(compare:)];
    NSUInteger frameSampleCount = sortedFrameSamples.count;
    double averageFrameMs = frameSampleCount > 0
                                ? self.floatingDockPerfFrameSumMs /
                                      (double)frameSampleCount
                                : 0.0;
    double p95FrameMs = 0.0;
    if (frameSampleCount > 0) {
        NSUInteger p95Index =
            MIN(frameSampleCount - 1,
                (NSUInteger)ceil((double)frameSampleCount * 0.95) - 1);
        p95FrameMs = sortedFrameSamples[p95Index].doubleValue;
    }
    double effectiveFPS = averageFrameMs > 0.0 ? 1000.0 / averageFrameMs : 0.0;
    NSUInteger actualCallbackDeltaSamples =
        self.floatingDockPerfRenderFrames > 1
            ? self.floatingDockPerfRenderFrames - 1
            : 0;
    double actualCallbackDeltaMs = actualCallbackDeltaSamples > 0
                                       ? self.floatingDockPerfActualCallbackDeltaSumMs /
                                             (double)actualCallbackDeltaSamples
                                       : 0.0;
    double targetDeltaMs = self.floatingDockPerfRenderFrames > 0
                               ? self.floatingDockPerfTargetDeltaSumMs /
                                     (double)self.floatingDockPerfRenderFrames
                               : 0.0;
    double averageInputDeltaMs =
        self.floatingDockPerfInputSampleCount > 1
            ? self.floatingDockPerfInputDeltaSumMs /
                  (double)(self.floatingDockPerfInputSampleCount - 1)
            : 0.0;
    double averageRenderDeltaMs =
        self.floatingDockPerfRenderCommitCount > 1
            ? self.floatingDockPerfRenderDeltaSumMs /
                  (double)(self.floatingDockPerfRenderCommitCount - 1)
            : 0.0;
    double effectiveRenderFPS = averageRenderDeltaMs > 0.0
                                    ? 1000.0 / averageRenderDeltaMs
                                    : 0.0;
    FLMEnqueueDiagnosticLine(
        @"sb dock-input-ended state=%ld mode=%@ movement=%.1f outward=%.1f global=%d frame=%@ rendererMode=%@ displayLinkCapped60=%d inputSamples=%lu renderCommits=%lu avgInputDelta=%.2f avgRenderDelta=%.2f effectiveRenderFPS=%.2f perf={renderFrames:%lu screenMaxFPS:%ld requestedMinFPS:%.2f requestedMaxFPS:%.2f requestedPreferredFPS:%.2f actualCallbackDelta:%.2f targetDelta:%.2f avgFrameMs:%.2f p95FrameMs:%.2f maxFrameMs:%.2f missedVsync:%lu callbackEffectiveFPS:%.2f callbackGapEstimate:%lu maxCallbackMs:%.2f transport:live-layer}",
        (long)gesture.state,
        FLMFloatingDockInputModeName(inputMode),
        movement,
        outwardTravel,
        wasGlobalDragActivated,
        NSStringFromCGRect([self floatingContainerPresentationFrame]),
        FLMFloatingDockRendererModeName(self.floatingDockRendererMode),
        self.floatingDockDisplayLinkCapped60,
        (unsigned long)self.floatingDockPerfInputSampleCount,
        (unsigned long)self.floatingDockPerfRenderCommitCount,
        averageInputDeltaMs,
        averageRenderDeltaMs,
        effectiveRenderFPS,
        (unsigned long)self.floatingDockPerfRenderFrames,
        (long)self.floatingDockPerfMaximumFramesPerSecond,
        self.floatingDockPerfRequestedMinimumFramesPerSecond,
        self.floatingDockPerfRequestedMaximumFramesPerSecond,
        self.floatingDockPerfRequestedPreferredFramesPerSecond,
        actualCallbackDeltaMs,
        targetDeltaMs,
        averageFrameMs,
        p95FrameMs,
        self.floatingDockPerfMaximumFrameMs,
        (unsigned long)self.floatingDockPerfMissedVsync,
        effectiveFPS,
        (unsigned long)self.floatingDockPerfCallbackGapEstimate,
        self.floatingDockPerfMaximumCallbackGap * 1000.0);

    self.floatingDockInputSessionActive = NO;
    self.floatingDockInputMode = FLMFloatingDockInputModeNone;
    self.floatingDockRendererMode = FLMFloatingDockRendererModeDisplayLink;
    self.floatingDockDisplayLinkCapped60 = NO;
    self.floatingDockDisplayLinkProbeIntervalCount = 0;
    self.floatingDockDisplayLinkProbeSlowCount = 0;
    self.floatingDockDisplayLinkProbeLastTimestamp = 0.0;
    self.floatingDockPerfInputDeltaSumMs = 0.0;
    self.floatingDockPerfLastInputTimestamp = 0.0;
    self.floatingDockPerfRenderCommitCount = 0;
    self.floatingDockPerfRenderDeltaSumMs = 0.0;
    self.floatingDockPerfLastRenderCommitTimestamp = 0.0;
    self.floatingDockInputGeneration += 1;

    if (inputMode == FLMFloatingDockInputModeHiddenReveal) {
        self.floatingDockInputTargetsResize = NO;
        // A tap on the hidden handle remains inert.  Only an inward swipe
        // that crosses the configured threshold reveals the card.
        if (revealing && outwardTravel < 5.0) {
            self.floatingDockHideGestureActive = NO;
            self.floatingDockHideReady = NO;
            [self updateFloatingDockTouchGate];
            [self setFloatingDockRoutingSuppressed:NO];
            return;
        }
        BOOL commit = gesture.state == UIGestureRecognizerStateEnded &&
                      outwardTravel >= [self effectiveCenteredDockSwipeThreshold];
        [self finishFloatingDockHiddenGesture:revealing ? !commit : commit
                                       atPoint:point];
        return;
    }

    if (inputMode == FLMFloatingDockInputModeResize) {
        if (!self.floatingDocked || self.floatingDockHidden) {
            self.floatingDockInputTargetsResize = NO;
            self.floatingResizeCenterReady = NO;
            [self setFloatingDockRoutingSuppressed:NO];
            return;
        }
        [self normalizeFloatingContainerTransform];
        BOOL restoreCentered =
            gesture.state == UIGestureRecognizerStateEnded &&
            self.floatingResizeCenterReady;
        self.floatingResizeCenterReady = NO;
        self.floatingDockInputTargetsResize = NO;
        if (restoreCentered) {
            [self transitionFloatingWindowToCentered];
            return;
        }
        [self saveFloatingDockWidth];
        CGRect currentPresentationFrame =
            [self floatingContainerPresentationFrame];
        CGFloat currentVerticalCenter =
            CGRectGetMidY(currentPresentationFrame);
        self.floatingDockVerticalCenter = currentVerticalCenter;
        CGRect target =
            [self dockedFloatingFrameOnRight:self.floatingDockedOnRight
                                        width:self.floatingDockWidth
                    preservingVerticalCenter:currentVerticalCenter];
        NSUInteger controlTransitionGeneration =
            ++self.floatingDockControlTransitionGeneration;
        self.floatingDockControlTransition =
            FLMFloatingDockControlTransitionResize;
        self.floatingDockControlTargetFrame = target;
        self.floatingDockControlDefersKeyboardTeardown = NO;
        self.floatingDockTransitionActive = YES;
        self.floatingDockTouchGateTransitionFrame =
            FLMDockTransitionEnvelope(
                currentPresentationFrame,
                target,
                self.floatingWindow.rootViewController.view.bounds);
        [self updateFloatingDockTouchGate];
        [self setFloatingDockRoutingSuppressed:YES];
        UIViewPropertyAnimator *resizeAnimator =
            [[UIViewPropertyAnimator alloc]
                initWithDuration:0.24
                          curve:UIViewAnimationCurveEaseOut
                      animations:^{
                             self.floatingContainer.center =
                                 CGPointMake(CGRectGetMidX(target),
                                             CGRectGetMidY(target));
                             CGFloat dockScale =
                                 [self floatingDockPresentationScale];
                             self.floatingContainer.transform =
                                 CGAffineTransformMakeScale(dockScale,
                                                           dockScale);
                             [self layoutFloatingDockShadow];
                             [self layoutFloatingResizeHandle];
                          }];
        self.floatingDockTransitionAnimator = resizeAnimator;
        [resizeAnimator addCompletion:^(__unused UIViewAnimatingPosition position) {
                              self.floatingDockTransitionAnimator = nil;
                              if (controlTransitionGeneration !=
                                      self.floatingDockControlTransitionGeneration ||
                                  self.floatingDockControlTransition !=
                                      FLMFloatingDockControlTransitionResize) {
                                  return;
                              }
                              self.floatingDockControlTransition =
                                  FLMFloatingDockControlTransitionNone;
                              self.floatingDockControlTargetFrame = CGRectNull;
                              self.floatingDockTransitionActive = NO;
                              self.floatingDockTouchGateTransitionFrame = CGRectNull;
                              [self configureFloatingInteractionForDockedState];
                             [self setFloatingDockRoutingSuppressed:NO];
                         }];
        [resizeAnimator startAnimation];
        return;
    }

    self.floatingDockGlobalDragActivated = NO;
    self.floatingDockInputTargetsResize = NO;
    BOOL directDockTap = gesture.state == UIGestureRecognizerStateEnded &&
                         self.floatingDocked && !self.floatingDockHidden &&
                         inputMode == FLMFloatingDockInputModeCardDrag &&
                         !wasGlobalDragActivated && movement <= 8.0;
    if (directDockTap) {
        CGRect sourceFrame = [self floatingContainerPresentationFrame];
        BOOL wasTransitioning = self.floatingDockTransitionActive;
        if (wasTransitioning) {
            // A Snap can still own the card when the tap recognizer reaches
            // Ended. Take over from the compositor's current state instead
            // of requiring transition==0 before accepting the tap.
            [self interruptFloatingDockTransitionAtPoint:point];
        }
        if (self.floatingDocked && !self.floatingDockHidden &&
            !self.floatingWindow.hidden) {
            [self cancelFloatingDockInputUpdates];
            self.floatingDockRestorePrepareTimestamp = CACurrentMediaTime();
            FLMEnqueueDiagnosticLine(
                @"sb dock-tap recognized movement=%.1f sourceFrame=%@ transition=%d",
                movement, NSStringFromCGRect(sourceFrame), wasTransitioning);
            [self transitionFloatingWindowToCentered];
            return;
        }
    }
    if (wasGlobalDragActivated || movement >= 5.0) {
        // A moved card always settles horizontally, even if the last display
        // link arrived before the recognizer's Ended callback.
        [self snapDockedFloatingWindowUsingTouchPoint:point];
        return;
    }
    [self setFloatingDockRoutingSuppressed:NO];
}

- (void)handleFloatingHiddenBarDrag:(UILongPressGestureRecognizer *)gesture {
    UIView *rootView = self.floatingWindow.rootViewController.view;
    CGRect bounds = rootView.bounds;
    CGPoint point = [gesture locationInView:rootView];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.floatingHiddenBarDragStartPoint = point;
        self.floatingHiddenBarDragInitialFrame = self.floatingHandle.frame;
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGFloat deltaY = point.y - self.floatingHiddenBarDragStartPoint.y;
        CGRect frame = self.floatingHiddenBarDragInitialFrame;
        CGFloat topLimit = MAX(8.0, rootView.safeAreaInsets.top);
        CGFloat bottomLimit =
            CGRectGetHeight(bounds) - CGRectGetHeight(frame) -
            rootView.safeAreaInsets.bottom;
        frame.origin.y =
            MAX(topLimit, MIN(bottomLimit, CGRectGetMinY(frame) + deltaY));
        [UIView performWithoutAnimation:^{
            self.floatingHandle.frame = frame;
        }];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        // The hidden bar is free to travel vertically while dragged, but it
        // always springs back to its landing spot beside the hidden card
        // (upper-right for the right dock, upper-left for the left dock).
        CGRect landing =
            CGRectMake(self.floatingDockedOnRight
                           ? CGRectGetWidth(bounds) -
                                 CGRectGetWidth(self.floatingHandle.frame)
                           : 0.0,
                       MAX(8.0,
                           CGRectGetMinY([self floatingContainerPresentationFrame]) + 24.0),
                       CGRectGetWidth(self.floatingHandle.frame),
                       CGRectGetHeight(self.floatingHandle.frame));
        [UIView animateWithDuration:0.32
                              delay:0.0
             usingSpringWithDamping:0.78
              initialSpringVelocity:0.20
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
                             self.floatingHandle.frame = landing;
                         }
                         completion:nil];
    }
}

- (void)handleFloatingHandleTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded ||
        self.floatingWindow.hidden) {
        return;
    }
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
    }
    [UIView animateWithDuration:0.10
                     animations:^{
                         self.floatingHandleBar.alpha = 1.0;
                         self.floatingHandleBar.transform =
                             CGAffineTransformMakeScale(1.10, 1.28);
                     }
                     completion:^(BOOL finished) {
                         (void)finished;
                         [UIView animateWithDuration:0.18
                                          animations:^{
                                              self.floatingHandleBar.alpha = 1.0;
                                              self.floatingHandleBar.transform =
                                                  CGAffineTransformIdentity;
                                          }];
                     }];
}

- (void)handleFloatingDockDragPress:(UILongPressGestureRecognizer *)gesture {
    if (!self.floatingDocked || self.floatingWindow.hidden) {
        return;
    }
    UIView *rootView = self.floatingWindow.rootViewController.view;
    CGPoint point = [gesture locationInView:rootView];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self setFloatingDockRoutingSuppressed:YES];
        self.floatingDockDragStartPoint = point;
        self.floatingDockDragInitialCenter = self.floatingContainer.center;
        [rootView bringSubviewToFront:self.floatingContainer];
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *feedback =
                [[UIImpactFeedbackGenerator alloc]
                    initWithStyle:UIImpactFeedbackStyleMedium];
            [feedback impactOccurred];
        }
        return;
    }

    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint delta =
            CGPointMake(point.x - self.floatingDockDragStartPoint.x,
                        point.y - self.floatingDockDragStartPoint.y);
        CGRect bounds = rootView.bounds;
        UIEdgeInsets safeInsets = rootView.safeAreaInsets;
        CGRect currentFrame = [self floatingContainerPresentationFrame];
        CGFloat halfWidth = CGRectGetWidth(currentFrame) * 0.5;
        CGFloat halfHeight = CGRectGetHeight(currentFrame) * 0.5;
        CGPoint center =
            CGPointMake(self.floatingDockDragInitialCenter.x + delta.x,
                        self.floatingDockDragInitialCenter.y + delta.y);
        CGFloat minimumCenterX = safeInsets.left + halfWidth;
        CGFloat maximumCenterX =
            CGRectGetWidth(bounds) - safeInsets.right - halfWidth;
        if (maximumCenterX < minimumCenterX) {
            maximumCenterX = minimumCenterX;
        }
        center.x = MAX(minimumCenterX,
                       MIN(maximumCenterX, center.x));
        center.y = MAX(safeInsets.top + halfHeight,
                       MIN(CGRectGetHeight(bounds) - safeInsets.bottom - halfHeight,
                           center.y));
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [UIView performWithoutAnimation:^{
            self.floatingContainer.center = center;
            self.floatingDockVerticalCenter = center.y;
            [self updateFloatingDockTouchGate];
        }];
        [CATransaction commit];
        return;
    }

    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        [self snapDockedFloatingWindowUsingTouchPoint:point];
    }
}

- (void)setFloatingApplicationInputBlocked:(BOOL)blocked {
    if (!blocked &&
        (self.floatingDocked || self.floatingDockHidden ||
         self.floatingDockContentTailProtected)) {
        blocked = YES;
    }
    self.floatingHostView.userInteractionEnabled = !blocked;
    self.floatingDockInteractionShield.frame = self.floatingContainer.bounds;
    self.floatingDockInteractionShield.hidden = !blocked;
    self.floatingDockInteractionShield.userInteractionEnabled = blocked;
    if (blocked) {
        [self.floatingContainer
            bringSubviewToFront:self.floatingDockInteractionShield];
    }
    [self updateFloatingDockTouchGate];
}

- (NSUInteger)armFloatingContentProtectionForDockTransitionFrame:
    (CGRect)frame {
    self.floatingDockContentTailProtected = YES;
    NSUInteger generation = ++self.floatingDockContentProtectionGeneration;
    self.floatingDockContentTransitionCommitted = NO;
    self.floatingDockContentProtectionFrame = frame;
    [self setFloatingApplicationInputBlocked:YES];
    FLMEnqueueDiagnosticLine(
        @"sb dock-content-barrier armed generation=%lu frame=%@ activeTouches=%lu recognizerState=%ld",
        (unsigned long)generation,
        NSStringFromCGRect(frame),
        (unsigned long)self.floatingDockInputGesture.flmActiveTouchCount,
        (long)self.floatingDockInputGesture.state);
    return generation;
}

- (void)floatingDockInputRecognizerTouchStateDidChange {
    if (!self.floatingDockContentTailProtected) {
        return;
    }
    [self releaseFloatingContentProtectionAfterDockTransition:
              self.floatingDockContentProtectionGeneration];
}

- (void)markFloatingContentProtectionAnimationCommitted:
    (NSUInteger)generation {
    if (generation != self.floatingDockContentProtectionGeneration ||
        !self.floatingDockContentTailProtected) {
        return;
    }
    self.floatingDockContentTransitionCommitted = YES;
    [self releaseFloatingContentProtectionAfterDockTransition:generation];
}

- (void)releaseFloatingContentProtectionAfterDockTransition:
    (NSUInteger)generation {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self.floatingDockContentProtectionGeneration) {
            return;
        }
        // A recognizer registered through _UISystemGestureManager is allowed
        // to remain in Ended after its touch has drained.  Waiting for
        // Possible here therefore deadlocks the content barrier on affected
        // builds.  The active-touch count plus the controller-owned barrier
        // session are the actual lifetime of the stream we must absorb.
        BOOL touchesQuiescent =
            self.floatingDockInputGesture.flmActiveTouchCount == 0 &&
            !self.floatingDockBarrierTouchActive;
        if (!self.floatingDockContentTailProtected ||
            !self.floatingDockContentTransitionCommitted ||
            !touchesQuiescent || self.floatingDockTransitionActive) {
            return;
        }
        self.floatingDockContentTailProtected = NO;
        self.floatingDockContentProtectionFrame = CGRectNull;
        self.floatingDockInputBlockedUntilNextTouch = NO;
        self.floatingDockInputBlockCutoffTimestamp = 0.0;
        if (!self.floatingWindow.hidden && !self.floatingDocked &&
            !self.floatingDockHidden) {
            [self configureFloatingInteractionForDockedState];
        }
        [self setFloatingDockRoutingSuppressed:NO];
        [self updateFloatingDockTouchGate];
        FLMEnqueueDiagnosticLine(
            @"sb dock-content-barrier released generation=%lu animationCommitted=1 touchesQuiescent=1 recognizerState=%ld",
            (unsigned long)generation,
            (long)self.floatingDockInputGesture.state);
    });
}

- (void)updateFloatingFullscreenSnapshotForProgress:(CGFloat)progress {
    UIView *wrapper = self.floatingInteractiveSnapshot;
    UIView *background = self.floatingInteractiveSnapshotBackground;
    UIView *content = self.floatingInteractiveSnapshotContent;
    if (!wrapper || !content) {
        return;
    }
    progress = MIN(1.0, MAX(0.0, progress));
    CGRect start = self.floatingHandleInitialContainerFrame;
    CGRect bounds = self.floatingWindow.rootViewController.view.bounds;
    if (CGRectGetWidth(start) < 1.0 || CGRectGetHeight(start) < 1.0) {
        return;
    }
    self.floatingFullscreenProgress = progress;

    // The card and the display now share one aspect ratio, so fullscreen is a
    // single proportional recovery: every edge moves continuously from the
    // card frame to the display frame.  The previous width-stage/height-stage
    // reveal made the finger-driven gesture look like two separate animations.
    CGFloat geometryProgress = progress;
    CGFloat minX = CGRectGetMinX(start) +
                   (CGRectGetMinX(bounds) - CGRectGetMinX(start)) *
                       geometryProgress;
    CGFloat minY = CGRectGetMinY(start) +
                   (CGRectGetMinY(bounds) - CGRectGetMinY(start)) *
                       geometryProgress;
    CGFloat width = CGRectGetWidth(start) +
                    (CGRectGetWidth(bounds) - CGRectGetWidth(start)) *
                        geometryProgress;
    CGFloat height = CGRectGetHeight(start) +
                     (CGRectGetHeight(bounds) - CGRectGetHeight(start)) *
                         geometryProgress;
    CGRect frame = CGRectMake(minX, minY, width, height);
    wrapper.transform = CGAffineTransformIdentity;
    wrapper.frame = frame;
    CGFloat cornerRadius =
        22.0 * (CGRectGetWidth(start) / FLMCenteredCardWidth) *
        (1.0 - progress);
    wrapper.layer.cornerRadius = cornerRadius;

    CGFloat uniformScale = CGRectGetWidth(frame) /
                           MAX(1.0, CGRectGetWidth(start));
    CGPoint localCenter =
        CGPointMake(CGRectGetMidX(wrapper.bounds), CGRectGetMidY(wrapper.bounds));
    content.center = localCenter;
    content.transform = CGAffineTransformMakeScale(uniformScale, uniformScale);
    if (background) {
        background.center = localCenter;
        background.transform =
            CGAffineTransformMakeScale(uniformScale, uniformScale);
    }
    // The proportional foreground remains visible for the complete gesture.
    // The optional duplicate is kept only as a snapshot fallback and follows
    // the same transform; it must never aspect-fill or create a second stage.
    content.alpha = 1.0;
    background.alpha = 0.0;

    // Keep every visible element on this same progress curve.  Previously the
    // card path, dim layer, white bar and final fullscreen animation each had a
    // separate callback.  That made release at an arbitrary point look like a
    // second animation was starting after the bar had already finished.
    self.floatingContainer.transform = CGAffineTransformIdentity;
    self.floatingContainer.frame = frame;
    self.floatingContainer.layer.cornerRadius = cornerRadius;
    self.floatingDimView.alpha = 1.0 - progress;
    CGFloat handleFade =
        MIN(1.0, MAX(0.0, (progress - 0.84) / 0.16));
    self.floatingHandle.alpha = 1.0 - handleFade;
    self.floatingHandleBar.alpha = 1.0;
    self.floatingHandleBar.transform = CGAffineTransformIdentity;
    [self layoutFloatingHandleForCurrentContainer];
}

- (void)prepareFloatingSceneForInteractiveFullscreen {
    if (self.floatingInteractiveScenePrepared) {
        return;
    }
    self.floatingInteractiveScenePrepared = YES;
    self.floatingInteractiveFullscreenTransition = YES;
    self.floatingFullscreenProgress = 0.0;
    self.floatingHandleBar.alpha = 1.0;
    self.floatingHandleBar.transform = CGAffineTransformIdentity;

    UIView *content =
        [self.floatingContainer snapshotViewAfterScreenUpdates:NO];
    if (!content) {
        content = [[UIView alloc] initWithFrame:self.floatingContainer.bounds];
        content.backgroundColor = [UIColor blackColor];
    }
    UIView *background =
        [self.floatingContainer snapshotViewAfterScreenUpdates:NO];
    CGRect start = self.floatingHandleInitialContainerFrame;
    UIView *wrapper = [[UIView alloc] initWithFrame:start];
    wrapper.backgroundColor = [UIColor clearColor];
    wrapper.autoresizingMask = UIViewAutoresizingNone;
    wrapper.userInteractionEnabled = NO;
    wrapper.clipsToBounds = YES;
    wrapper.layer.cornerRadius =
        22.0 * CGRectGetWidth(start) / FLMCenteredCardWidth;
    CGRect sourceBounds = CGRectMake(0.0,
                                     0.0,
                                     CGRectGetWidth(start),
                                     CGRectGetHeight(start));
    if (background) {
        background.bounds = sourceBounds;
        background.center = CGPointMake(CGRectGetMidX(wrapper.bounds),
                                        CGRectGetMidY(wrapper.bounds));
        background.autoresizingMask = UIViewAutoresizingNone;
        background.userInteractionEnabled = NO;
        background.alpha = 0.0;
        [wrapper addSubview:background];
    }
    content.bounds = sourceBounds;
    content.center = CGPointMake(CGRectGetMidX(wrapper.bounds),
                                 CGRectGetMidY(wrapper.bounds));
    content.autoresizingMask = UIViewAutoresizingNone;
    content.userInteractionEnabled = NO;
    [wrapper addSubview:content];
    [self.floatingWindow.rootViewController.view addSubview:wrapper];
    [self.floatingWindow.rootViewController.view
        bringSubviewToFront:self.floatingHandle];
    self.floatingInteractiveSnapshot = wrapper;
    self.floatingInteractiveSnapshotBackground = background;
    self.floatingInteractiveSnapshotContent = content;
    self.floatingContainer.alpha = 0.0;
    [self updateFloatingFullscreenSnapshotForProgress:0.0];
}

- (void)restoreFloatingSceneAfterCancelledTransition {
    if (!self.floatingInteractiveScenePrepared &&
        !self.floatingInteractiveSnapshot) {
        return;
    }
    [self.floatingInteractiveSnapshot removeFromSuperview];
    self.floatingInteractiveSnapshot = nil;
    self.floatingInteractiveSnapshotBackground = nil;
    self.floatingInteractiveSnapshotContent = nil;
    self.floatingInteractiveScenePrepared = NO;
    self.floatingInteractiveFullscreenTransition = NO;
    self.floatingFullscreenActivationArmed = NO;
    self.floatingFullscreenProgress = 0.0;
    self.floatingReconnectSuppressed = NO;
    self.floatingContainer.alpha = 1.0;
    self.floatingContainer.transform = CGAffineTransformIdentity;
    if (!CGRectIsEmpty(self.floatingHandleInitialContainerFrame)) {
        self.floatingContainer.frame = self.floatingHandleInitialContainerFrame;
    }
    [self layoutFloatingHostView];
}

- (void)handleFloatingHandlePress:(UILongPressGestureRecognizer *)gesture {
    if (self.floatingWindow.hidden) {
        return;
    }
    if (self.floatingDocked && self.floatingDockHidden) {
        [self handleFloatingHiddenBarDrag:gesture];
        return;
    }
    UIView *rootView = self.floatingWindow.rootViewController.view;
    CGPoint point = [gesture locationInView:rootView];
    CGRect bounds = rootView.bounds;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        // A centered card always starts a new dock gesture at the fixed
        // minimum size. Resizing a prior dock is intentionally not remembered.
        self.floatingDockWidth = [self effectiveDockedPresentationWidth];
        self.floatingHandleStartPoint = point;
        self.floatingHandleInitialContainerFrame =
            [self floatingContainerPresentationFrame];
        self.floatingHandleMoved = NO;
        self.floatingDockTransitionActive = NO;
        self.floatingDockFeedbackSent = NO;
        self.floatingInteractiveScenePrepared = NO;
        self.floatingHandleBar.alpha = 1.0;
        self.floatingHandleBar.transform = CGAffineTransformIdentity;
        [self setFloatingApplicationInputBlocked:NO];
        self.floatingDockReady = NO;
        return;
    }

    CGFloat primaryMovement =
        point.y - self.floatingHandleStartPoint.y;

    if (gesture.state == UIGestureRecognizerStateChanged) {
        if (primaryMovement <= -3.0) {
            if (self.floatingInteractiveScenePrepared) {
                [self restoreFloatingSceneAfterCancelledTransition];
            }
            [self setFloatingApplicationInputBlocked:YES];
            self.floatingHandleMoved = YES;
            self.floatingDockTransitionActive = YES;
            CGRect start = self.floatingHandleInitialContainerFrame;
            CGRect dockTarget =
                [self dockedFloatingFrameOnRight:YES width:self.floatingDockWidth];
            CGFloat triggerProgress =
                MIN(1.0, MAX(0.0,
                             -primaryMovement /
                                 [self effectiveCenteredDockSwipeThreshold]));
            CGFloat visualProgress =
                MIN(1.0, MAX(0.0,
                             -primaryMovement /
                                 FLMCenteredDockActivationDistance));
            CGFloat width =
                CGRectGetWidth(start) +
                (CGRectGetWidth(dockTarget) - CGRectGetWidth(start)) * visualProgress;
            CGFloat scale = width / MAX(1.0, CGRectGetWidth(start));
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [UIView performWithoutAnimation:^{
                self.floatingContainer.center =
                    CGPointMake(CGRectGetMidX(start), CGRectGetMidY(start));
                self.floatingContainer.transform =
                    CGAffineTransformMakeScale(scale, scale);
                self.floatingDockShadowView.center = self.floatingContainer.center;
                self.floatingDockShadowView.transform =
                    self.floatingContainer.transform;
            }];
            [CATransaction commit];
            // Card corners scale proportionally with the card: the visual
            // radius stays 22pt at the centered size and shrinks to the
            // docked ratio (22 * dockWidth / 315) as the card shrinks.
            self.floatingContainer.layer.cornerRadius = 22.0;
            self.floatingDimView.alpha = 1.0 - visualProgress;
            self.floatingDockShadowView.hidden = YES;
            self.floatingDockShadowView.alpha = 0.0;
            self.floatingHandle.alpha = 1.0;
            [self layoutFloatingHandleForCurrentContainer];
            if (!self.floatingDockReady && triggerProgress >= 1.0) {
                if (@available(iOS 10.0, *)) {
                    UIImpactFeedbackGenerator *feedback =
                        [[UIImpactFeedbackGenerator alloc]
                            initWithStyle:UIImpactFeedbackStyleMedium];
                    if (!self.floatingDockFeedbackSent) {
                        [feedback impactOccurred];
                        self.floatingDockFeedbackSent = YES;
                    }
                }
                self.floatingDockReady = YES;
            } else if (self.floatingDockReady && triggerProgress < 0.90) {
                self.floatingDockReady = NO;
            }
        } else if (primaryMovement >= 3.0) {
            self.floatingDockReady = NO;
            [self setFloatingApplicationInputBlocked:NO];
            self.floatingHandleMoved = YES;
            self.floatingDockTransitionActive = NO;
            self.floatingDockShadowView.alpha = 0.0;
            self.floatingDockShadowView.hidden = YES;
            if (!self.floatingInteractiveScenePrepared) {
                [self prepareFloatingSceneForInteractiveFullscreen];
            }
            CGFloat available =
                MAX(1.0,
                    CGRectGetHeight(bounds) -
                        CGRectGetMaxY(self.floatingHandleInitialContainerFrame));
            CGFloat progress = MIN(1.0, MAX(0.0, primaryMovement / available));
            [self updateFloatingFullscreenSnapshotForProgress:progress];
            if (progress >= FLMFloatingFullscreenActivationThreshold &&
                !self.floatingFullscreenActivationArmed &&
                self.floatingIdentifier.length > 0) {
                self.floatingFullscreenActivationArmed = YES;
                self.floatingReconnectSuppressed = YES;
                [self activateIdentifierFullscreen:self.floatingIdentifier];
            }
        } else {
            self.floatingDockReady = NO;
            [self setFloatingApplicationInputBlocked:NO];
            if (self.floatingInteractiveScenePrepared) {
                if (self.floatingFullscreenActivationArmed &&
                    self.floatingIdentifier.length > 0 &&
                    [self.floatingIdentifier
                        isEqualToString:FLMFrontmostApplicationIdentifier()]) {
                    [self transitionFloatingWindowToFullscreen];
                    return;
                }
                [self restoreFloatingSceneAfterCancelledTransition];
            }
            self.floatingDockTransitionActive = NO;
            self.floatingContainer.transform = CGAffineTransformIdentity;
            self.floatingContainer.frame =
                self.floatingHandleInitialContainerFrame;
            self.floatingDockShadowView.transform = CGAffineTransformIdentity;
            self.floatingContainer.layer.cornerRadius = 22.0;
            self.floatingDimView.alpha = 1.0;
            self.floatingDockShadowView.alpha = 0.0;
            self.floatingDockShadowView.hidden = YES;
            self.floatingHandle.alpha = 1.0;
            [self layoutFloatingHostView];
            [self layoutFloatingHandleForCurrentContainer];
        }
        return;
    }

    if (gesture.state == UIGestureRecognizerStateEnded &&
        self.floatingDockReady && primaryMovement < 0.0) {
        self.floatingDockReady = NO;
        [self transitionFloatingWindowToDocked];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded &&
        self.floatingHandleMoved && !self.floatingDockTransitionActive &&
        primaryMovement > 0.0 &&
        point.y >= CGRectGetHeight(bounds) - 80.0) {
        self.floatingDockReady = NO;
        [self transitionFloatingWindowToFullscreen];
        return;
    }
    self.floatingDockReady = NO;
    [self resetFloatingInteractiveLayoutAnimated:YES];
}

- (void)resetFloatingInteractiveLayoutAnimated:(BOOL)animated {
    if (self.floatingFullscreenActivationArmed &&
        !self.floatingWindow.hidden && self.floatingIdentifier.length > 0 &&
        [self.floatingIdentifier
            isEqualToString:FLMFrontmostApplicationIdentifier()]) {
        [self transitionFloatingWindowToFullscreen];
        return;
    }
    self.floatingDockReady = NO;
    [self restoreFloatingSceneAfterCancelledTransition];
    [self setFloatingApplicationInputBlocked:NO];
    [self normalizeFloatingContainerTransform];
    void (^changes)(void) = ^{
        self.floatingContainer.alpha = 1.0;
        self.floatingContainer.layer.cornerRadius = 22.0;
        self.floatingDimView.alpha = 1.0;
        self.floatingHandle.alpha = 1.0;
        self.floatingHandleBar.alpha = 1.0;
        self.floatingHandleBar.transform = CGAffineTransformIdentity;
        self.floatingDockShadowView.alpha = 0.0;
        [self layoutFloatingWindow];
    };
    if (!animated) {
        changes();
        self.floatingDockTransitionActive = NO;
        if (!self.floatingDocked) {
            self.floatingDockShadowView.hidden = YES;
        }
        return;
    }
    [UIView animateWithDuration:0.34
                          delay:0.0
         usingSpringWithDamping:0.78
          initialSpringVelocity:0.25
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:changes
                     completion:^(BOOL finished) {
                         (void)finished;
                         self.floatingDockTransitionActive = NO;
                         if (!self.floatingDocked) {
                             self.floatingDockShadowView.hidden = YES;
                         }
                     }];
}

- (void)transitionFloatingWindowToFullscreen {
    self.floatingDockReady = NO;
    if (self.floatingWindow.hidden || self.floatingIdentifier.length == 0) {
        [self resetFloatingInteractiveLayoutAnimated:YES];
        return;
    }
    UIView *rootView = self.floatingWindow.rootViewController.view;
    [self endFloatingKeyboardSession];
    CGRect targetFrame = rootView.bounds;
    if (!self.floatingInteractiveScenePrepared) {
        self.floatingHandleInitialContainerFrame =
            [self floatingContainerPresentationFrame];
        [self prepareFloatingSceneForInteractiveFullscreen];
    }
    NSString *identifier = [self.floatingIdentifier copy];
    self.floatingReconnectSuppressed = YES;
    // Start the already-running scene promotion while the final part of the
    // same card morph is still on screen. The old implementation waited until
    // that animation ended, producing a visible motion/pause/activation split.
    if (!self.floatingFullscreenActivationArmed) {
        self.floatingFullscreenActivationArmed = YES;
        [self activateIdentifierFullscreen:identifier];
    }
    CGFloat remainingProgress =
        MAX(0.0, 1.0 - self.floatingFullscreenProgress);
    NSTimeInterval finishDuration = 0.10 + 0.22 * remainingProgress;
    [UIView animateWithDuration:finishDuration
                           delay:0.0
                         options:UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionAllowUserInteraction
                       animations:^{
                          [self updateFloatingFullscreenSnapshotForProgress:1.0];
                      }
                      completion:^(BOOL finished) {
                          (void)finished;
                          UIView *snapshot = self.floatingInteractiveSnapshot;
                         self.floatingInteractiveSnapshot = nil;
                         self.floatingInteractiveSnapshotBackground = nil;
                         self.floatingInteractiveSnapshotContent = nil;
                         if (!snapshot) {
                             snapshot = [[UIView alloc] initWithFrame:targetFrame];
                             snapshot.backgroundColor = [UIColor blackColor];
                             [rootView addSubview:snapshot];
                         } else {
                             snapshot.layer.cornerRadius = 0.0;
                             [rootView addSubview:snapshot];
                         }

                          self.floatingInteractiveScenePrepared = NO;
                          self.floatingInteractiveFullscreenTransition = NO;
                          self.floatingFullscreenProgress = 1.0;
                         self.floatingLaunchGeneration += 1;
                         self.floatingExclusiveGesture.enabled = NO;
                         self.cornerGuardGesture.enabled = self.enabled;
                         self.cornerGesture.enabled = self.enabled;
                         self.floatingContainer.alpha = 0.0;
                          [self finishFullscreenHandoffWithCover:snapshot
                                                    identifier:identifier
                                                      attempt:0];
                     }];
}

- (void)finishFullscreenHandoffWithCover:(UIView *)cover
                              identifier:(NSString *)identifier
                                 attempt:(NSUInteger)attempt {
    BOOL targetIsFrontmost =
        identifier.length > 0 &&
        [identifier isEqualToString:FLMFrontmostApplicationIdentifier()];
    // Match the 0.8.46 handoff cadence. The cover already completed the
    // single continuous card-to-fullscreen animation; wait only one bounded
    // polling turn before swapping it with the real foreground Scene. The
    // polling cadence is shorter now because the app activation is armed
    // during the drag itself.
    BOOL displayCommitted = targetIsFrontmost && attempt >= 1;
    if (!displayCommitted && attempt < 24) {
        if (attempt == 0 || attempt >= 22) {
            FLMEnqueueDiagnosticLine(
                @"sb fullscreen-handoff wait target=%@ frontmost=%@ attempt=%lu",
                identifier ?: @"<none>",
                FLMFrontmostApplicationIdentifier() ?: @"<none>",
                (unsigned long)attempt);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(FLMFloatingFullscreenHandoffPollInterval *
                                               NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self finishFullscreenHandoffWithCover:cover
                                       identifier:identifier
                                          attempt:attempt + 1];
        });
        return;
    }

    if (!displayCommitted) {
        // Never remove the only visible surface merely because the promotion
        // deadline expired. Keep the app in centered mode and let the user
        // retry; this prevents an occasional black SpringBoard screen when
        // launchApplicationWithIdentifier: has not committed the target Scene.
        FLMEnqueueDiagnosticLine(
            @"sb fullscreen-handoff timeout target=%@ frontmost=%@ restoring-card=1",
            identifier ?: @"<none>",
            FLMFrontmostApplicationIdentifier() ?: @"<none>");
        [cover removeFromSuperview];
        self.floatingReconnectSuppressed = NO;
        [self restoreFloatingSceneAfterCancelledTransition];
        [self resetFloatingInteractiveLayoutAnimated:NO];
        self.floatingExclusiveGesture.enabled = self.usesSystemGestureManager;
        self.cornerGuardGesture.enabled = self.enabled;
        self.cornerGesture.enabled = self.enabled;
        return;
    }

    id scene = self.floatingScene;
    id presenter = self.floatingPresenter;
    [self.floatingHostView removeFromSuperview];
    self.floatingHostView = nil;
    self.floatingHostReferenceSize = CGSizeZero;
    self.floatingSceneEntity = nil;
    self.floatingSceneHandle = nil;
    self.floatingScene = nil;
    self.floatingPresentationManager = nil;
    self.floatingPresenter = nil;
    self.floatingIdentifier = nil;
    self.floatingFullscreenProgress = 0.0;
    [self applyKeyboardFrame:CGRectNull visible:NO];
    FLMClearProtectedScene(scene);
    @try {
        if ([presenter respondsToSelector:@selector(deactivate)]) {
            [presenter deactivate];
        }
        if ([presenter respondsToSelector:@selector(invalidate)]) {
            [presenter invalidate];
        }
    } @catch (__unused NSException *exception) {
    }

    // The geometry animation already ended at the exact physical-screen
    // bounds. Once SpringBoard confirms the real Scene is frontmost, exchange
    // the identical full-screen cover without a second visible animation.
    [UIView performWithoutAnimation:^{
        self.floatingWindow.hidden = YES;
        [self releaseAllFloatingKeyboardHostQuarantinesForReason:@"fullscreen-handoff"];
        [self updateFloatingDockTouchGate];
        [cover removeFromSuperview];
        self.floatingContainer.alpha = 1.0;
        [self resetFloatingInteractiveLayoutAnimated:NO];
        [self stopLockMonitoringIfIdle];
    }];
}

- (void)protectedSceneDidDisappear:(NSNotification *)notification {
    (void)notification;
    if (self.floatingKeyboardSessionGeneration != 0) {
        [self endFloatingKeyboardSession];
    }
    if (self.floatingWindow.hidden) {
        return;
    }
    if (self.floatingReconnectSuppressed) {
        return;
    }
    if (FLMDeviceIsLocked() || self.floatingIdentifier.length == 0) {
        [self closeFloatingWindowKeepingApplication:YES];
        return;
    }

    NSString *identifier = [self.floatingIdentifier copy];
    if (self.floatingDocked &&
        [identifier isEqualToString:FLMFrontmostApplicationIdentifier()]) {
        // The user opened the docked application through SpringBoard. Its
        // primary scene now belongs to the fullscreen transition; reconnecting
        // that same scene into the dock produces a black, permanently stale
        // presenter. Detach our presenter without backgrounding the app.
        self.floatingReconnectSuppressed = YES;
        [self closeFloatingWindowKeepingApplication:NO];
        return;
    }
    if (self.floatingKeyboardSessionGeneration == 0) {
        self.floatingKeyboardSessionCounter += 1;
        if (self.floatingKeyboardSessionCounter == 0) {
            self.floatingKeyboardSessionCounter = 1;
        }
        self.floatingKeyboardSessionGeneration =
            self.floatingKeyboardSessionCounter;
        [self invalidateSessionCanonicalGeometry];
    }
    self.floatingLaunchGeneration += 1;
    NSUInteger generation = self.floatingLaunchGeneration;
    self.floatingLaunchState = FLMFloatingLaunchStatePrewarming;
    self.floatingLaunchStartedAt = CACurrentMediaTime();
    self.floatingRevealRetryCount = 0;
    self.floatingScenePreparedAt = 0.0;
    // Card presentation is intentionally decoupled from Scene geometry. Mark
    // the presentation route ready immediately so keyboard/host callbacks do
    // not wait for a private compact-frame acknowledgement.
    self.floatingSceneUsesCardGeometry = NO;
    self.floatingSceneCardGeometryPending = NO;
    self.floatingSceneCardGeometryCommitted = NO;
    self.contentViewportCommitted = NO;
    self.floatingKeyboardPresentationSuspendedForDock = NO;
    self.floatingKeyboardAvoidancePublishDeferred = NO;
    self.floatingSceneGeometryCommitGeneration = generation;
    self.floatingKeyboardFramePending = NO;
    self.floatingKeyboardPendingFrame = CGRectNull;
    self.floatingKeyboardPendingSessionGeneration = 0;
    id presenter = self.floatingPresenter;
    [self.floatingHostView removeFromSuperview];
    self.floatingHostView = nil;
    self.floatingHostReferenceSize = CGSizeZero;
    self.floatingSceneEntity = nil;
    self.floatingSceneHandle = nil;
    self.floatingScene = nil;
    self.floatingPresentationManager = nil;
    self.floatingPresenter = nil;
    @try {
        if ([presenter respondsToSelector:@selector(deactivate)]) {
            [presenter deactivate];
        }
        if ([presenter respondsToSelector:@selector(invalidate)]) {
            [presenter invalidate];
        }
    } @catch (__unused NSException *exception) {
    }
    [self configureFloatingLaunchCoverForIdentifier:identifier];
    self.floatingHandle.userInteractionEnabled = NO;
    self.floatingExclusiveGesture.enabled = NO;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [self attachFloatingIdentifier:identifier
                                generation:generation
                                   attempt:0];
    });
}

- (CGFloat)configuredCenteredCardWidth {
    CGFloat width = self.centeredCardWidth;
    if (width <= 0.0) {
        width = FLMCenteredCardWidth;
    }
    return MAX(FLMMinimumCenteredCardWidth,
               MIN(FLMMaximumCenteredCardWidth, width));
}

- (CGFloat)configuredCenteredCardHeight {
    CGFloat width = [self configuredCenteredCardWidth];
    CGFloat baseHeight = width * FLMVirtualViewportHeight /
                         FLMVirtualViewportWidth;
    CGFloat topCrop = MAX(FLMMinimumCenteredCardCrop,
                          MIN(FLMMaximumCenteredCardCrop,
                              self.centeredCardTopCrop));
    CGFloat bottomCrop = MAX(FLMMinimumCenteredCardCrop,
                             MIN(FLMMaximumCenteredCardCrop,
                                 self.centeredCardBottomCrop));
    CGFloat height = baseHeight - topCrop - bottomCrop;
    // Keep the card visible even if a user enters unusually large crop values.
    // The full-screen Scene is never resized; this is only a presentation
    // surface guard.
    return MAX(240.0, MIN(780.0, height));
}

- (CGFloat)effectiveCenteredCardWidth {
    if (self.sessionCanonicalGeometryValid &&
        self.sessionCanonicalGeometrySession ==
            self.floatingKeyboardSessionGeneration) {
        return CGRectGetWidth(self.sessionCanonicalGeometry.centeredBounds);
    }
    return [self configuredCenteredCardWidth];
}

- (CGFloat)effectiveCenteredCardHeight {
    if (self.sessionCanonicalGeometryValid &&
        self.sessionCanonicalGeometrySession ==
            self.floatingKeyboardSessionGeneration) {
        return CGRectGetHeight(self.sessionCanonicalGeometry.centeredBounds);
    }
    return [self configuredCenteredCardHeight];
}

- (CGFloat)effectiveCenteredCardScaleX {
    if (self.sessionCanonicalGeometryValid &&
        self.sessionCanonicalGeometrySession ==
            self.floatingKeyboardSessionGeneration) {
        return self.sessionCanonicalGeometry.centeredContentScale;
    }
    return [self configuredCenteredCardWidth] / FLMVirtualViewportWidth;
}

- (CGFloat)effectiveCenteredCardScaleY {
    // Full-screen content is always transformed by one uniform scale. Top and
    // bottom crop alter the visible card frame, never the app's logical frame.
    return [self effectiveCenteredCardScaleX];
}

- (CGFloat)effectiveCenteredDockSwipeThreshold {
    CGFloat value = self.centeredDockSwipeThreshold;
    if (!isfinite(value) || value <= 0.0) {
        value = FLMDefaultCenteredDockSwipeThreshold;
    }
    return MAX(FLMMinimumCenteredDockSwipeThreshold,
               MIN(FLMMaximumCenteredDockSwipeThreshold, value));
}

- (CGFloat)effectiveDockedPresentationWidth {
    CGFloat width = FLMMinimumDockWidth -
                    MAX(0.0, MIN(FLMMaximumDockedShrinkAmount,
                                  self.dockedShrinkAmount));
    return MAX(FLMMinimumDockPresentationWidth, width);
}

- (CGFloat)floatingDockPresentationScale {
    CGFloat centeredWidth = [self effectiveCenteredCardWidth];
    CGFloat dockWidth = self.floatingDockWidth;
    if (!isfinite(dockWidth) || dockWidth <= 0.0) {
        dockWidth = [self effectiveDockedPresentationWidth];
    }
    // Keep the session snapshot as the source of the centered basis. A user
    // resize may change dockWidth during the session, so the presentation
    // ratio remains dynamic while never re-deriving the centered card from a
    // transformed/presentation layer.
    if (self.sessionCanonicalGeometryValid &&
        self.sessionCanonicalGeometrySession ==
            self.floatingKeyboardSessionGeneration) {
        centeredWidth = CGRectGetWidth(
            self.sessionCanonicalGeometry.centeredBounds);
    }
    CGFloat scale = dockWidth / MAX(1.0, centeredWidth);
    return MAX(0.05, MIN(1.0, scale));
}

- (void)verifyFloatingDockPresentationScaleInvariant:(NSString *)phase {
    if (!self.floatingDocked || self.floatingDockTransitionActive ||
        !self.floatingContainer) {
        return;
    }
    BOOL canonicalReady = [self ensureSessionCanonicalGeometry];
    CGFloat canonicalScale = canonicalReady
                                 ? self.sessionCanonicalGeometry.dockPresentationScale
                                 : [self floatingDockPresentationScale];
    CALayer *layer = self.floatingContainer.layer;
    CALayer *presentationLayer = layer.presentationLayer ?: layer;
    CGFloat presentationScale =
        FLMUniformScaleFromTransform(presentationLayer.transform);
    if (!isfinite(canonicalScale) || canonicalScale <= 0.001 ||
        !isfinite(presentationScale) || presentationScale <= 0.001) {
        return;
    }
    CGFloat delta = fabs(presentationScale - canonicalScale);
    if (delta > 0.02) {
        FLMEnqueueDiagnosticLine(
            @"sb dock-transform invariant-failure phase=%@ presentationFromScale=%.6f canonicalDockPresentationScale=%.6f delta=%.6f",
            phase ?: @"settled", presentationScale, canonicalScale, delta);
    }
}

- (void)invalidateSessionCanonicalGeometry {
    self.sessionCanonicalGeometryValid = NO;
    self.sessionCanonicalGeometrySession = 0;
    self.sessionCanonicalGeometry = (FLMSessionCanonicalGeometry){
        CGRectZero, CGRectZero, CGPointZero, 0.0, 0.0, 0.0};
}

- (BOOL)ensureSessionCanonicalGeometry {
    if (!self.floatingWindow || self.floatingKeyboardSessionGeneration == 0) {
        return NO;
    }
    if (self.sessionCanonicalGeometryValid &&
        self.sessionCanonicalGeometrySession ==
            self.floatingKeyboardSessionGeneration) {
        return YES;
    }
    CGRect rawFrame = [self uncachedCenteredFloatingFrame];
    if (CGRectIsNull(rawFrame) || CGRectIsEmpty(rawFrame) ||
        CGRectGetWidth(rawFrame) <= 0.5 || CGRectGetHeight(rawFrame) <= 0.5) {
        return NO;
    }
    UIScreen *screen = self.floatingWindow.screen ?: [UIScreen mainScreen];
    CGFloat screenScale = screen.scale;
    if (!isfinite(screenScale) || screenScale <= 0.0) {
        screenScale = 1.0;
    }
    CGRect centeredFrame = FLMPixelAlignedRect(rawFrame, screenScale);
    CGFloat centeredWidth = CGRectGetWidth(centeredFrame);
    CGFloat centeredHeight = CGRectGetHeight(centeredFrame);
    if (centeredWidth <= 0.5 || centeredHeight <= 0.5) {
        return NO;
    }
    CGFloat dockWidth = self.floatingDockWidth;
    if (!isfinite(dockWidth) || dockWidth <= 0.0) {
        dockWidth = [self effectiveDockedPresentationWidth];
    }
    dockWidth = MAX(FLMMinimumDockPresentationWidth,
                    MIN(FLMMaximumDockWidth, dockWidth));
    CGFloat dockScale = dockWidth / centeredWidth;
    FLMSessionCanonicalGeometry geometry = {
        centeredFrame,
        CGRectMake(0.0, 0.0, centeredWidth, centeredHeight),
        CGPointMake(FLMPixelAlignedValue(CGRectGetMidX(centeredFrame),
                                         screenScale),
                    FLMPixelAlignedValue(CGRectGetMidY(centeredFrame),
                                         screenScale)),
        centeredWidth / FLMVirtualViewportWidth,
        MAX(0.05, MIN(1.0, dockScale)),
        screenScale,
    };
    self.sessionCanonicalGeometry = geometry;
    self.sessionCanonicalGeometrySession =
        self.floatingKeyboardSessionGeneration;
    self.sessionCanonicalGeometryValid = YES;
    FLMEnqueueDiagnosticLine(
        @"sb session-canonical-geometry session=%lu centeredFrame=%@ centeredBounds=%@ centeredPosition={%.4f,%.4f} centeredContentScale=%.6f dockPresentationScale=%.6f screenScale=%.2f source=user-preference+centered-policy",
        (unsigned long)self.sessionCanonicalGeometrySession,
        NSStringFromCGRect(geometry.centeredFrame),
        NSStringFromCGRect(geometry.centeredBounds),
        geometry.centeredPosition.x, geometry.centeredPosition.y,
        geometry.centeredContentScale, geometry.dockPresentationScale,
        geometry.screenScale);
    return YES;
}

- (CGRect)sessionCanonicalCenteredFrame {
    return [self ensureSessionCanonicalGeometry]
               ? self.sessionCanonicalGeometry.centeredFrame
               : CGRectNull;
}

- (void)reassertSessionCanonicalCenteredModelGeometry {
    if (![self ensureSessionCanonicalGeometry] || !self.floatingContainer) {
        return;
    }
    FLMSessionCanonicalGeometry geometry = self.sessionCanonicalGeometry;
    CALayer *layer = self.floatingContainer.layer;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.floatingContainer.transform = CGAffineTransformIdentity;
    layer.bounds = geometry.centeredBounds;
    layer.position = geometry.centeredPosition;
    layer.transform = CATransform3DIdentity;
    [CATransaction commit];
}

- (CGRect)floatingContainerPresentationFrame {
    UIView *container = self.floatingContainer;
    if (!container) {
        return CGRectNull;
    }
    CALayer *layer = container.layer;
    CALayer *presentationLayer = layer.presentationLayer ?: layer;
    CGRect bounds = presentationLayer.bounds;
    CGPoint position = presentationLayer.position;
    CGFloat scale = FLMUniformScaleFromTransform(presentationLayer.transform);
    CGFloat width = CGRectGetWidth(bounds) * scale;
    CGFloat height = CGRectGetHeight(bounds) * scale;
    if (!isfinite(position.x) || !isfinite(position.y) ||
        !isfinite(width) || !isfinite(height) || width <= 0.5 || height <= 0.5) {
        return container.frame;
    }
    CGRect frame = CGRectMake(position.x - width * 0.5,
                              position.y - height * 0.5,
                              width,
                              height);
    CGRect viewFrame = container.frame;
    if ((fabs(position.x) <= 0.001 && fabs(position.y) <= 0.001) &&
        !CGRectIsEmpty(viewFrame) && !CGRectIsNull(viewFrame) &&
        (fabs(CGRectGetMidX(viewFrame)) > 0.001 ||
         fabs(CGRectGetMidY(viewFrame)) > 0.001)) {
        return viewFrame;
    }
    return frame;
}

- (void)configureFloatingContainerForDockPresentationAtCenter:(CGPoint)center
                                                          scale:(CGFloat)scale {
    if (!self.floatingContainer) {
        return;
    }
    CGRect centeredFrame = [self centeredFloatingFrame];
    if (CGRectGetWidth(centeredFrame) <= 0.5 ||
        CGRectGetHeight(centeredFrame) <= 0.5) {
        return;
    }
    scale = MAX(0.05, MIN(1.0, scale));
    CALayer *layer = self.floatingContainer.layer;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.bounds = CGRectMake(0.0,
                              0.0,
                              CGRectGetWidth(centeredFrame),
                              CGRectGetHeight(centeredFrame));
    layer.position = center;
    layer.transform = CATransform3DMakeScale(scale, scale, 1.0);
    [CATransaction commit];
}

- (CGRect)centeredFloatingFrame {
    if (self.floatingKeyboardSessionGeneration != 0 &&
        [self ensureSessionCanonicalGeometry]) {
        return self.sessionCanonicalGeometry.centeredFrame;
    }
    return [self uncachedCenteredFloatingFrame];
}

- (CGRect)uncachedCenteredFloatingFrame {
    CGRect bounds = self.floatingWindow.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    if (width <= 0.0 || height <= 0.0) {
        return CGRectZero;
    }

    UIEdgeInsets safeInsets =
        self.floatingWindow.rootViewController.view.safeAreaInsets;
    // The centered card dimensions are explicit presentation preferences.
    // Never derive them from orientation, safe-area height, keyboard state, or
    // Scene geometry. The app itself remains a full-screen Scene underneath.
    const CGFloat containerWidth = [self effectiveCenteredCardWidth];
    const CGFloat containerHeight = [self effectiveCenteredCardHeight];
    CGFloat centeredUpperTop =
        floor((height - containerHeight) * 0.5 - 44.0);
    CGFloat top = MAX(safeInsets.top + 8.0, centeredUpperTop);
    CGFloat originX = floor((width - containerWidth) * 0.5);
    return CGRectMake(originX, top, containerWidth, containerHeight);
}

- (CGRect)dockedFloatingFrameOnRight:(BOOL)onRight width:(CGFloat)width {
    UIView *rootView = self.floatingWindow.rootViewController.view;
    CGRect bounds = rootView.bounds;
    UIEdgeInsets safeInsets = rootView.safeAreaInsets;
    CGRect centeredFrame = [self centeredFloatingFrame];
    CGFloat aspectRatio =
        CGRectGetWidth(centeredFrame) / MAX(1.0, CGRectGetHeight(centeredFrame));
    CGFloat clampedWidth =
        MAX(FLMMinimumDockPresentationWidth,
            MIN(FLMMaximumDockWidth, width));
    CGFloat height = clampedWidth / MAX(0.1, aspectRatio);
    CGFloat top = safeInsets.top + FLMDockTopMargin;
    CGFloat originX =
        onRight
            ? CGRectGetWidth(bounds) - safeInsets.right -
                  FLMDockSideMargin - clampedWidth
            : safeInsets.left + FLMDockSideMargin;
    return CGRectMake(originX, top, clampedWidth, height);
}

- (CGRect)dockedFloatingFrameOnRight:(BOOL)onRight
                               width:(CGFloat)width
             preservingVerticalCenter:(CGFloat)verticalCenter {
    CGRect frame = [self dockedFloatingFrameOnRight:onRight width:width];
    UIView *rootView = self.floatingWindow.rootViewController.view;
    UIEdgeInsets safeInsets = rootView.safeAreaInsets;
    CGFloat halfHeight = CGRectGetHeight(frame) * 0.5;
    CGFloat minimumCenterY = safeInsets.top + halfHeight;
    CGFloat maximumCenterY =
        CGRectGetHeight(rootView.bounds) - safeInsets.bottom - halfHeight;
    if (maximumCenterY < minimumCenterY) {
        maximumCenterY = minimumCenterY;
    }
    CGFloat clampedCenterY =
        MAX(minimumCenterY, MIN(maximumCenterY, verticalCenter));
    frame.origin.y = clampedCenterY - halfHeight;
    return frame;
}

- (CGRect)dockedHiddenFloatingFrameOnRight:(BOOL)onRight
                                      width:(CGFloat)width {
    CGRect frame = [self dockedFloatingFrameOnRight:onRight width:width];
    return [self dockedHiddenFloatingFrameOnRight:onRight
                                            width:width
                          preservingVerticalCenter:CGRectGetMidY(frame)];
}

- (CGRect)dockedHiddenFloatingFrameOnRight:(BOOL)onRight
                                      width:(CGFloat)width
                    preservingVerticalCenter:(CGFloat)verticalCenter {
    CGRect frame =
        [self dockedFloatingFrameOnRight:onRight
                                  width:width
                preservingVerticalCenter:verticalCenter];
    // Fully hide the card off-screen: only the edge handle bar remains
    // visible, so the user never sees an app sliver next to it.
    CGFloat visibleSliver = 0.0;
    frame.origin.x = onRight
                         ? CGRectGetWidth(self.floatingWindow.bounds) -
                               visibleSliver
                         : visibleSliver - CGRectGetWidth(frame);
    return frame;
}

- (void)layoutFloatingDockShadow {
    // The dock shadow was removed: the release animation previously left a
    // visible dark halo behind the card. Keep the view tree intact so all
    // callers stay valid, but never present the shadow.
    self.floatingDockShadowView.hidden = YES;
    self.floatingDockShadowView.alpha = 0.0;
    return;
}

- (void)updateFloatingDockAccessoryPositions {
    BOOL dockInputInFlight =
        self.floatingDockInputSessionActive &&
        (self.floatingDockInputMode == FLMFloatingDockInputModeCardDrag ||
         self.floatingDockInputMode == FLMFloatingDockInputModeResize);
    if (dockInputInFlight || self.floatingDockGlobalDragActivated) {
        // The active display-wide recognizer already owns this touch. The
        // resize target is invisible and the gate is only needed for the
        // next touch, so defer sibling-window/frame work until the settle
        // animation. This keeps the remote surface on the compositor path
        // instead of forcing a full accessory/layout update every sample.
        return;
    }
    if (!self.floatingDocked) {
        [self layoutFloatingResizeHandle];
        [self updateFloatingDockTouchGate];
        return;
    }
    if (!self.floatingDockShadowView.hidden) {
        self.floatingDockShadowView.center = self.floatingContainer.center;
        self.floatingDockShadowView.transform = self.floatingContainer.transform;
    }
    [self layoutFloatingResizeHandle];
    [self updateFloatingDockTouchGate];
}

- (void)layoutFloatingResizeHandle {
    if (!self.floatingResizeHandle || !self.floatingDocked ||
        self.floatingDockHidden || self.floatingWindow.hidden) {
        self.floatingResizeHandle.hidden = YES;
        return;
    }
    CGRect frame = [self floatingContainerPresentationFrame];
    const CGFloat hitSize = 46.0;
    self.floatingResizeHandle.frame =
        self.floatingDockedOnRight
            ? CGRectMake(CGRectGetMinX(frame) - 32.0,
                         CGRectGetMaxY(frame) - 14.0,
                         hitSize,
                         hitSize)
            : CGRectMake(CGRectGetMaxX(frame) - 14.0,
                         CGRectGetMaxY(frame) - 14.0,
                         hitSize,
                         hitSize);
    // Keep the transparent target hit-testable.  No layer, border, alpha
    // animation, or other visual affordance is attached to this view.
    self.floatingResizeHandle.hidden = NO;
    self.floatingResizeHandle.alpha = 1.0;
}

- (BOOL)floatingResizeControlContainsPoint:(CGPoint)point {
    if (!self.floatingDocked || self.floatingDockHidden ||
        self.floatingResizeHandle.hidden) {
        return NO;
    }
    CGRect broadFrame = CGRectInset(self.floatingResizeHandle.frame, -10.0, -10.0);
    if (!CGRectContainsPoint(broadFrame, point)) {
        return NO;
    }
    UIBezierPath *path = [UIBezierPath bezierPath];
    if (self.floatingDockedOnRight) {
        [path moveToPoint:CGPointMake(24.0, 2.0)];
        [path addLineToPoint:CGPointMake(24.0, 12.0)];
        [path addQuadCurveToPoint:CGPointMake(34.0, 22.0)
                    controlPoint:CGPointMake(24.0, 22.0)];
        [path addLineToPoint:CGPointMake(44.0, 22.0)];
    } else {
        [path moveToPoint:CGPointMake(22.0, 2.0)];
        [path addLineToPoint:CGPointMake(22.0, 12.0)];
        [path addQuadCurveToPoint:CGPointMake(12.0, 22.0)
                    controlPoint:CGPointMake(22.0, 22.0)];
        [path addLineToPoint:CGPointMake(2.0, 22.0)];
    }
    CGPoint localPoint =
        CGPointMake(point.x - CGRectGetMinX(self.floatingResizeHandle.frame),
                    point.y - CGRectGetMinY(self.floatingResizeHandle.frame));
    CGPathRef touchPath =
        CGPathCreateCopyByStrokingPath(path.CGPath,
                                       NULL,
                                       20.0,
                                       kCGLineCapRound,
                                       kCGLineJoinRound,
                                       1.0);
    if (!touchPath) {
        return NO;
    }
    BOOL contains = CGPathContainsPoint(touchPath, NULL, localPoint, NO);
    CGPathRelease(touchPath);
    return contains;
}

- (void)saveFloatingDockWidth {
    self.floatingDockWidth =
        MAX(FLMMinimumDockPresentationWidth,
            MIN(FLMMaximumDockWidth, self.floatingDockWidth));
}

- (void)normalizeFloatingContainerTransform {
    if (!self.floatingContainer) {
        return;
    }
    CGRect visualFrame = [self floatingContainerPresentationFrame];
    BOOL dockPresentation = self.floatingDocked || self.floatingDockHidden ||
                            self.floatingDockTransitionActive;
    if (dockPresentation) {
        CGPoint center = CGPointMake(CGRectGetMidX(visualFrame),
                                     CGRectGetMidY(visualFrame));
        [self configureFloatingContainerForDockPresentationAtCenter:center
                                                               scale:[self floatingDockPresentationScale]];
        self.floatingContainer.layer.cornerRadius = 22.0;
        self.floatingDockInteractionShield.frame = self.floatingContainer.bounds;
        [self layoutFloatingResizeHandle];
        return;
    }
    BOOL canonicalReady = [self ensureSessionCanonicalGeometry];
    BOOL canonicalModel = canonicalReady &&
                          CGRectEqualToRect(
                              self.floatingContainer.layer.bounds,
                              self.sessionCanonicalGeometry.centeredBounds) &&
                          CGPointEqualToPoint(
                              self.floatingContainer.layer.position,
                              self.sessionCanonicalGeometry.centeredPosition);
    if (CGAffineTransformIsIdentity(self.floatingContainer.transform) &&
        CGAffineTransformIsIdentity(self.floatingContainer.layer.affineTransform) &&
        (!canonicalReady || canonicalModel)) {
        return;
    }
    [UIView performWithoutAnimation:^{
        [self reassertSessionCanonicalCenteredModelGeometry];
        self.floatingContainer.transform = CGAffineTransformIdentity;
        self.floatingContainer.layer.transform = CATransform3DIdentity;
        self.floatingDockShadowView.transform = CGAffineTransformIdentity;
        CGRect canonicalFrame = [self sessionCanonicalCenteredFrame];
        if (CGRectIsNull(canonicalFrame) || CGRectIsEmpty(canonicalFrame)) {
            canonicalFrame = self.floatingContainer.frame;
        }
        self.floatingDockShadowView.frame = canonicalFrame;
        self.floatingDockInteractionShield.frame = self.floatingContainer.bounds;
        [self layoutFloatingHostView];
        [self layoutFloatingResizeHandle];
    }];
}

- (void)lockFloatingDockGeometryForDrag {
    [self normalizeFloatingContainerTransform];
    CGRect currentFrame = [self floatingContainerPresentationFrame];
    CGRect rootBounds = self.floatingWindow.rootViewController.view.bounds;
    UIEdgeInsets safeInsets =
        self.floatingWindow.rootViewController.view.safeAreaInsets;
    CGFloat halfWidth = CGRectGetWidth(currentFrame) * 0.5;
    CGFloat halfHeight = CGRectGetHeight(currentFrame) * 0.5;
    self.floatingDockDirectPanMinimumCenter =
        CGPointMake(safeInsets.left + halfWidth, safeInsets.top + halfHeight);
    self.floatingDockDirectPanMaximumCenter = CGPointMake(
        CGRectGetWidth(rootBounds) - safeInsets.right - halfWidth,
        CGRectGetHeight(rootBounds) - safeInsets.bottom - halfHeight);
    CGPoint currentCenter = CGPointMake(CGRectGetMidX(currentFrame),
                                        CGRectGetMidY(currentFrame));
    [UIView performWithoutAnimation:^{
        [self configureFloatingContainerForDockPresentationAtCenter:currentCenter
                                                               scale:[self floatingDockPresentationScale]];
        self.floatingContainer.layer.cornerRadius = 22.0;
        self.floatingDockVerticalCenter = currentCenter.y;
        self.floatingDockInteractionShield.frame = self.floatingContainer.bounds;
        [self layoutFloatingDockShadow];
        [self layoutFloatingResizeHandle];
        [self updateFloatingDockTouchGate];
    }];
    FLMEnqueueDiagnosticLine(
        @"sb dock-drag geometry-locked source=%@ locked=%@ width=%.1f transport=live-layer",
        NSStringFromCGRect(currentFrame),
        NSStringFromCGRect([self floatingContainerPresentationFrame]),
        self.floatingDockWidth);
}

- (void)configureFloatingInteractionForDockedState {
    // Keep the frozen user preference in the build contract.  The new
    // interruptible animator has a fixed 0.24s presentation duration, while
    // this legacy speed value remains intentionally available to preferences
    // and diagnostics.
    (void)FLMDockAnimationSpeed;
    FLMFloatingWindow *floatingWindow =
        (FLMFloatingWindow *)self.floatingWindow;
    BOOL docked = self.floatingDocked;
    BOOL hidden = self.floatingDockHidden;
    self.floatingDockPresentationMode =
        hidden ? FLMFloatingDockPresentationModeHiddenDock
               : docked ? FLMFloatingDockPresentationModeDocked
                        : FLMFloatingDockPresentationModeCentered;
    if (!self.floatingDockTransitionActive &&
        !self.floatingDockGlobalDragActivated &&
        !self.floatingDockHideGestureActive &&
        !self.floatingDockInputSessionActive &&
        !self.floatingDockContentTailProtected) {
        floatingWindow.suppressesCornerRoutingDuringDockGesture = NO;
    }
    floatingWindow.passesTouchesOutsideFloatingContent = docked || hidden;
    self.floatingBackdropTap.enabled =
        !docked && !hidden && !self.floatingDockContentTailProtected;
    self.floatingDockDragPress.enabled = NO;
    self.floatingDockInputGesture.enabled =
        docked || hidden || self.floatingDockTransitionActive ||
        self.floatingDockContentTailProtected;
    if (docked && !hidden) {
        [self prepareFloatingDockDisplayLink];
    } else {
        [self setFloatingDockDisplayLinkActive:NO];
    }
    self.floatingResizeHandle.userInteractionEnabled = docked && !hidden;
    self.floatingResizeHandle.hidden = !docked || hidden;
    self.floatingResizeHandle.alpha = 1.0;
    BOOL contentTailProtected =
        self.floatingDockContentTailProtected && !docked && !hidden;
    self.floatingHostView.userInteractionEnabled =
        !docked && !hidden && !contentTailProtected;
    self.floatingDockInteractionShield.frame = self.floatingContainer.bounds;
    self.floatingDockInteractionShield.hidden =
        (!docked || hidden) && !contentTailProtected;
    self.floatingDockInteractionShield.userInteractionEnabled =
        (docked && !hidden) || contentTailProtected;
    if ((docked && !hidden) || contentTailProtected) {
        [self.floatingContainer
            bringSubviewToFront:self.floatingDockInteractionShield];
    }
    self.floatingHandle.userInteractionEnabled =
        (hidden || !docked) && !contentTailProtected;
    self.floatingHandle.hidden = docked && !hidden;
    self.floatingHandlePress.enabled =
        (!docked || hidden) && !contentTailProtected;
    self.floatingHandleTap.enabled =
        !docked && !hidden && !contentTailProtected;
    self.floatingExclusiveGesture.enabled =
        !docked && !hidden && self.usesSystemGestureManager &&
        !self.floatingWindow.hidden &&
        !self.floatingDockContentTailProtected;
    if (hidden) {
        self.floatingResizeHandle.hidden = YES;
        self.floatingDimView.alpha = 0.0;
        self.floatingHandle.alpha = 1.0;
        self.floatingDockShadowView.alpha = 0.0;
        self.floatingDockShadowView.hidden = YES;
        [self layoutFloatingHandleForCurrentContainer];
        if (self.previousKeyWindow &&
            self.previousKeyWindow != self.floatingWindow) {
            [self.previousKeyWindow makeKeyWindow];
        }
    } else if (docked) {
        [self layoutFloatingResizeHandle];
        self.floatingDimView.alpha = 0.0;
        self.floatingHandle.alpha = 0.0;
        self.floatingDockShadowView.alpha = 0.0;
        [self layoutFloatingDockShadow];
        if (self.previousKeyWindow &&
            self.previousKeyWindow != self.floatingWindow) {
            [self.previousKeyWindow makeKeyWindow];
        }
    } else {
        self.floatingResizeHandle.hidden = YES;
        self.floatingHandle.alpha = 1.0;
        self.floatingDockShadowView.alpha = 0.0;
        self.floatingDockShadowView.hidden = YES;
        [self.floatingWindow makeKeyWindow];
    }
    [self updateFloatingDockTouchGate];
}

- (void)restoreFloatingHandleInteraction {
    // configureFloatingInteractionForDockedState deliberately disables the
    // handle for a docked card.  The old close/open path only unhid it, so a
    // subsequently centered card could display a white bar whose recognizers
    // never received touches.  Keep this reset independent of Scene startup.
    self.floatingHandle.hidden = NO;
    self.floatingHandle.alpha = 1.0;
    self.floatingHandle.userInteractionEnabled = YES;
    self.floatingHandlePress.enabled = YES;
    self.floatingHandleTap.enabled = YES;
}

- (void)transitionFloatingWindowToDocked {
    self.floatingDockReady = NO;
    if (self.floatingWindow.hidden || self.floatingDocked) {
        return;
    }
    CGRect source = [self floatingContainerPresentationFrame];
    self.floatingDockContentTailProtected = NO;
    self.floatingDockContentProtectionGeneration += 1;
    self.floatingDockContentProtectionFrame = CGRectNull;
    self.floatingDockContentTransitionCommitted = NO;
    // Invalidate any global dock recognizer that may still be observing the
    // centered handle's original touch.  The dock becomes eligible only for a
    // later touch, never for the tail of the docking swipe itself.
    [self cancelFloatingDockInputUpdates];
    self.floatingDockInputGeneration += 1;
    self.floatingDockInputSessionActive = NO;
    self.floatingDockInputMode = FLMFloatingDockInputModeNone;
    self.floatingDockInputTargetsResize = NO;
    self.floatingDockGlobalDragActivated = NO;
    // The current centered-to-dock swipe is already owned by the centered
    // control. Do not leave a stale cutoff that rejects the first deliberate
    // Dock Pan after the entry animation.
    self.floatingDockInputBlockedUntilNextTouch = NO;
    self.floatingDockInputBlockCutoffTimestamp = 0.0;
    [self setFloatingApplicationInputBlocked:YES];
    [self setFloatingDockRoutingSuppressed:YES];
    // Dock is a presentation mode, never a lifecycle boundary. The keyboard
    // surface may be suspended, but the app route/session/presenter/host is
    // retained as one continuous transaction.
    [self suspendFloatingKeyboardPresentationForDockMode];
    self.floatingDockTransitionActive = YES;
    self.floatingDockHidden = NO;
    self.floatingDockHideGestureActive = NO;
    self.floatingDockedOnRight = YES;
    self.floatingDockWidth = [self effectiveDockedPresentationWidth];
    CGRect target =
        [self dockedFloatingFrameOnRight:YES width:self.floatingDockWidth];
    NSUInteger entryTransitionGeneration =
        ++self.floatingDockControlTransitionGeneration;
    self.floatingDockControlTransition =
        FLMFloatingDockControlTransitionEntry;
    self.floatingDockControlTargetFrame = target;
    self.floatingDockControlDefersKeyboardTeardown = NO;
    self.floatingDockTouchGateTransitionFrame =
        FLMDockTransitionEnvelope(
            source,
            target,
            self.floatingWindow.rootViewController.view.bounds);
    self.floatingDockInputGesture.enabled = YES;
    [self updateFloatingDockTouchGate];
    FLMEnqueueDiagnosticLine(
        @"sb dock-entry-begin generation=%lu contentBlocked=0 control=DockControlOverlay+DockPan cutoff=0 source=%@ target=%@ route-kept=1",
        (unsigned long)entryTransitionGeneration,
        NSStringFromCGRect(source),
        NSStringFromCGRect(target));
    self.floatingDockVerticalCenter = CGRectGetMidY(target);
    BOOL canonicalReady = [self ensureSessionCanonicalGeometry];
    CGFloat targetScale = canonicalReady
                              ? self.sessionCanonicalGeometry.dockPresentationScale
                              : [self floatingDockPresentationScale];
    CALayer *containerLayer = self.floatingContainer.layer;
    CALayer *presentationLayer = containerLayer.presentationLayer;
    CGPoint sourcePosition = presentationLayer
                                 ? presentationLayer.position
                                 : containerLayer.position;
    CATransform3D sourceTransform = presentationLayer
                                        ? presentationLayer.transform
                                        : containerLayer.transform;
    CGFloat sourcePresentationScale =
        FLMUniformScaleFromTransform(sourceTransform);
    if (!presentationLayer || sourcePresentationScale <= 0.001) {
        sourcePresentationScale = 1.0;
    }
    self.floatingDockShadowView.hidden = YES;
    CABasicAnimation *positionAnimation =
        [CABasicAnimation animationWithKeyPath:@"position"];
    positionAnimation.fromValue = [NSValue valueWithCGPoint:sourcePosition];
    positionAnimation.toValue = [NSValue valueWithCGPoint:
                                           CGPointMake(CGRectGetMidX(target),
                                                       CGRectGetMidY(target))];
    CABasicAnimation *scaleAnimation =
        [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scaleAnimation.fromValue = @(sourcePresentationScale);
    scaleAnimation.toValue = @(targetScale);
    CAAnimationGroup *entryAnimation = [CAAnimationGroup animation];
    entryAnimation.animations = @[positionAnimation, scaleAnimation];
    entryAnimation.duration = 0.24;
    entryAnimation.timingFunction =
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [CATransaction setCompletionBlock:^ {
        self.floatingDockTransitionAnimator = nil;
        if (entryTransitionGeneration !=
                self.floatingDockControlTransitionGeneration ||
            self.floatingDockControlTransition !=
                FLMFloatingDockControlTransitionEntry) {
            return;
        }
        self.floatingDockControlTransition =
            FLMFloatingDockControlTransitionNone;
        self.floatingDockControlTargetFrame = CGRectNull;
        self.floatingDockControlDefersKeyboardTeardown = NO;
        if (self.floatingWindow.hidden || self.floatingCloseInProgress ||
            self.floatingIdentifier.length == 0) {
            self.floatingDockTransitionActive = NO;
            self.floatingDockTouchGateTransitionFrame = CGRectNull;
            [self updateFloatingDockTouchGate];
            [self setFloatingDockRoutingSuppressed:NO];
            return;
        }
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        containerLayer.position =
            CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
        containerLayer.transform =
            CATransform3DMakeScale(targetScale, targetScale, 1.0);
        containerLayer.cornerRadius = 22.0;
        [CATransaction commit];
        self.floatingDocked = YES;
        self.floatingDockTransitionActive = NO;
        [self verifyFloatingDockPresentationScaleInvariant:@"entry-settled"];
        self.floatingDockTouchGateTransitionFrame = CGRectNull;
        self.floatingDockHidden = NO;
        self.lastObservedFrontmostIdentifier =
            FLMFrontmostApplicationIdentifier();
        self.floatingExternalActivationArmed =
            ![self.lastObservedFrontmostIdentifier
                isEqualToString:self.floatingIdentifier];
        self.floatingHandleBar.alpha = 1.0;
        self.floatingHandleBar.transform = CGAffineTransformIdentity;
        [self configureFloatingInteractionForDockedState];
        FLMEnqueueDiagnosticLine(
            @"sb dock-state-publish once=1 presentationMode=Docked generation=%lu",
            (unsigned long)entryTransitionGeneration);
        FLMEnqueueDiagnosticLine(
            @"sb dock-entry-settled generation=%lu frame=%@ presentationScale=%.6f contentScaleStable=%.6f",
            (unsigned long)entryTransitionGeneration,
            NSStringFromCGRect([self floatingContainerPresentationFrame]),
            targetScale,
            [self effectiveCenteredCardScaleX]);
        [self setFloatingDockRoutingSuppressed:NO];
    }];
    containerLayer.position =
        CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
    containerLayer.transform =
        CATransform3DMakeScale(targetScale, targetScale, 1.0);
    containerLayer.cornerRadius = 22.0;
    [containerLayer addAnimation:entryAnimation
                           forKey:@"flyme.dock.entry.presentation"];
    [CATransaction commit];
}

- (void)transitionFloatingWindowToCentered {
    self.floatingDockReady = NO;
    if (self.floatingWindow.hidden || self.floatingDockHidden ||
        (!self.floatingDocked && !self.floatingDockTransitionActive)) {
        self.floatingDockRestorePrepareTimestamp = 0.0;
        return;
    }
    NSTimeInterval restoreTapTimestamp =
        self.floatingDockRestorePrepareTimestamp;
    self.floatingDockRestorePrepareTimestamp = 0.0;
    NSTimeInterval now = CACurrentMediaTime();
    if (restoreTapTimestamp <= 0.0 || restoreTapTimestamp > now) {
        restoreTapTimestamp = now;
    }
    CALayer *containerLayer = self.floatingContainer.layer;
    CALayer *presentationLayer = containerLayer.presentationLayer;
    CGPoint sourcePosition = presentationLayer
                                 ? presentationLayer.position
                                 : containerLayer.position;
    CGRect sourceFrame = [self floatingContainerPresentationFrame];
    if (CGRectIsNull(sourceFrame) || CGRectIsEmpty(sourceFrame)) {
        sourceFrame = self.floatingContainer.frame;
    }
    BOOL canonicalReady = [self ensureSessionCanonicalGeometry];
    FLMSessionCanonicalGeometry canonicalGeometry =
        self.sessionCanonicalGeometry;
    CGRect target = canonicalReady
                        ? canonicalGeometry.centeredFrame
                        : [self centeredFloatingFrame];
    if (CGRectIsNull(target) || CGRectIsEmpty(target)) {
        return;
    }
    CGPoint targetPosition = canonicalReady
                                 ? canonicalGeometry.centeredPosition
                                 : CGPointMake(CGRectGetMidX(target),
                                               CGRectGetMidY(target));
    CGFloat centeredContentScale = canonicalReady
                                       ? canonicalGeometry.centeredContentScale
                                       : [self effectiveCenteredCardScaleX];
    if (!isfinite(centeredContentScale) || centeredContentScale <= 0.001) {
        centeredContentScale = [self configuredCenteredCardWidth] /
                               FLMVirtualViewportWidth;
    }
    CGFloat effectiveSourceScale = CGRectGetWidth(sourceFrame) /
                                   MAX(1.0, FLMVirtualViewportWidth);
    if (!isfinite(effectiveSourceScale) || effectiveSourceScale <= 0.001) {
        effectiveSourceScale = 0.0;
    }
    CGFloat canonicalDockPresentationScale = canonicalReady
                                                  ? canonicalGeometry.dockPresentationScale
                                                  : [self floatingDockPresentationScale];
    CGFloat presentationFromScale = presentationLayer
                                        ? FLMUniformScaleFromTransform(
                                              presentationLayer.transform)
                                        : canonicalDockPresentationScale;
    if (!isfinite(presentationFromScale) || presentationFromScale <= 0.001) {
        presentationFromScale = canonicalDockPresentationScale;
    }
    presentationFromScale = MAX(0.05, MIN(1.0, presentationFromScale));
    canonicalDockPresentationScale =
        MAX(0.05, MIN(1.0, canonicalDockPresentationScale));
    [self verifyFloatingDockPresentationScaleInvariant:@"restore"];
    FLMEnqueueDiagnosticLine(
        @"sb dock-restore begin sourcePosition={%.1f,%.1f} targetPosition={%.1f,%.1f} canonicalWidth=%.4f centeredContentScale=%.6f presentationFromScale=%.6f presentationToScale=1.000000 effectiveSourceScale=%.6f remoteHostUnchanged=1 transition=%d presentation-only=1 canonical=%d",
        sourcePosition.x,
        sourcePosition.y,
        targetPosition.x,
        targetPosition.y,
        canonicalReady ? CGRectGetWidth(canonicalGeometry.centeredBounds)
                       : CGRectGetWidth(target),
        centeredContentScale,
        presentationFromScale,
        effectiveSourceScale,
        self.floatingDockTransitionActive,
        canonicalReady);
    FLMEnqueueDiagnosticLine(
        @"sb restore-content-scale stable=%.6f centeredContentScale=%.6f dockPresentationScale=%.6f presentationFromScale=%.6f presentationToScale=1.000000 effectiveSourceScale=%.6f remoteHostUnchanged=1 scene-geometry-unchanged=1",
        centeredContentScale,
        centeredContentScale,
        canonicalDockPresentationScale,
        presentationFromScale,
        effectiveSourceScale);
    NSUInteger restoreTransitionGeneration =
        ++self.floatingDockControlTransitionGeneration;
    self.floatingDockRestorePerformanceGeneration =
        restoreTransitionGeneration;
    self.floatingDockControlTransition =
        FLMFloatingDockControlTransitionRestore;
    self.floatingDockControlTargetFrame = target;
    self.floatingDockControlDefersKeyboardTeardown = NO;
    CGRect bounds = self.floatingWindow.rootViewController.view.bounds;
    CGRect transitionEnvelope =
        FLMDockTransitionEnvelope(sourceFrame, target, bounds);
    // The content barrier is armed as state only in Restore. The helper used
    // by Dock entry/snap also updates the touch-gate window synchronously,
    // which would pull layout work into this tap-to-CA critical section.
    self.floatingDockContentTailProtected = YES;
    NSUInteger protectionGeneration =
        ++self.floatingDockContentProtectionGeneration;
    self.floatingDockContentTransitionCommitted = NO;
    self.floatingDockContentProtectionFrame = transitionEnvelope;
    self.floatingDockTouchGateTransitionFrame = transitionEnvelope;
    FLMFloatingWindow *floatingWindow =
        (FLMFloatingWindow *)self.floatingWindow;
    [self cancelFloatingDockInputUpdates];
    [self setFloatingDockRoutingSuppressed:YES];
    floatingWindow.passesTouchesOutsideFloatingContent = NO;
    self.floatingDockDragPress.enabled = NO;
    // Keep the recognizer alive while the current Ended action unwinds. The
    // content barrier now follows the touch stream itself because a recognizer
    // owned by _UISystemGestureManager may never report Possible here.
    self.floatingDockInputGesture.enabled = YES;
    self.floatingDockInputGeneration += 1;
    self.floatingDockGlobalDragActivated = NO;
    self.floatingDockInputSessionActive = NO;
    self.floatingDockInputMode = FLMFloatingDockInputModeNone;
    self.floatingDockInputTargetsResize = NO;
    self.floatingDockInputBlockedUntilNextTouch = NO;
    self.floatingDockInputBlockCutoffTimestamp = 0.0;
    self.floatingDockTransitionActive = YES;
    self.floatingResizeCenterReady = NO;
    self.floatingResizeHandle.hidden = YES;
    self.floatingDockShadowView.hidden = YES;
    self.floatingDocked = NO;
    self.floatingDockHidden = NO;
    self.floatingDockHideGestureActive = NO;
    self.floatingHostView.userInteractionEnabled = NO;
    self.floatingDockInteractionShield.hidden = NO;
    self.floatingDockInteractionShield.userInteractionEnabled = YES;
    [self.floatingContainer bringSubviewToFront:self.floatingDockInteractionShield];
    self.floatingHandle.userInteractionEnabled = NO;
    self.floatingHandlePress.enabled = NO;
    self.floatingHandleTap.enabled = NO;
    self.floatingExternalActivationArmed = NO;
    self.floatingFullscreenActivationArmed = NO;
    self.lastObservedFrontmostIdentifier = nil;
    // Returning to the centered card changes only presentation. Keep the
    // application Scene, responder route, session generation and remote host
    // unchanged; no scene-frame write or route republish belongs here.
    self.floatingDockPresentationMode =
        FLMFloatingDockPresentationModeCentered;
    self.floatingHandle.hidden = NO;
    self.floatingHandle.alpha = 1.0;
    // Freeze the current compositor state in the model before adding the
    // restore group. The remote Scene and host are not touched here; only the
    // outer PresentationContainer position and scale are animated.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [containerLayer removeAllAnimations];
    self.floatingContainer.transform = CGAffineTransformIdentity;
    containerLayer.bounds = canonicalReady
                               ? canonicalGeometry.centeredBounds
                               : CGRectMake(0.0,
                                            0.0,
                                            CGRectGetWidth(target),
                                            CGRectGetHeight(target));
    containerLayer.position = targetPosition;
    containerLayer.transform = CATransform3DIdentity;
    containerLayer.cornerRadius = 22.0;
    containerLayer.borderWidth = 0.0;
    [CATransaction commit];
    CABasicAnimation *positionAnimation =
        [CABasicAnimation animationWithKeyPath:@"position"];
    positionAnimation.fromValue = [NSValue valueWithCGPoint:sourcePosition];
    positionAnimation.toValue = [NSValue valueWithCGPoint:targetPosition];
    CABasicAnimation *scaleAnimation =
        [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scaleAnimation.fromValue = @(presentationFromScale);
    scaleAnimation.toValue = @1.0;
    CAAnimationGroup *restoreAnimation = [CAAnimationGroup animation];
    restoreAnimation.animations = @[positionAnimation, scaleAnimation];
    restoreAnimation.duration = 0.24;
    restoreAnimation.timingFunction =
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    NSTimeInterval prepareMs =
        (CACurrentMediaTime() - restoreTapTimestamp) * 1000.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [CATransaction setCompletionBlock:^{
        NSTimeInterval completionStart = CACurrentMediaTime();
        self.floatingDockTransitionAnimator = nil;
        if (restoreTransitionGeneration !=
                self.floatingDockControlTransitionGeneration ||
            self.floatingDockControlTransition !=
                FLMFloatingDockControlTransitionRestore ||
            protectionGeneration !=
                self.floatingDockContentProtectionGeneration) {
            return;
        }
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.floatingContainer.transform = CGAffineTransformIdentity;
        containerLayer.position = targetPosition;
        containerLayer.transform = CATransform3DIdentity;
        containerLayer.cornerRadius = 22.0;
        containerLayer.borderWidth = 0.0;
        [CATransaction commit];
        self.floatingDimView.alpha = 1.0;
        self.floatingDockShadowView.alpha = 0.0;
        self.floatingDockShadowView.hidden = YES;
        self.floatingHandle.hidden = NO;
        self.floatingHandle.alpha = 1.0;
        self.floatingDockTransitionActive = NO;
        self.floatingDockControlTransition =
            FLMFloatingDockControlTransitionNone;
        self.floatingDockControlTargetFrame = CGRectNull;
        self.floatingDockTouchGateTransitionFrame = CGRectNull;
        self.floatingDockPresentationMode =
            FLMFloatingDockPresentationModeCentered;
        [self markFloatingContentProtectionAnimationCommitted:
                  protectionGeneration];
        NSUInteger restoreSessionGeneration =
            self.floatingKeyboardSessionGeneration;
        BOOL deferredWorkScheduled = !self.floatingWindow.hidden;
        if (deferredWorkScheduled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (restoreTransitionGeneration !=
                        self.floatingDockControlTransitionGeneration ||
                    restoreSessionGeneration !=
                        self.floatingKeyboardSessionGeneration ||
                    self.floatingWindow.hidden ||
                    self.floatingDockTransitionActive ||
                    self.floatingDocked || self.floatingDockHidden) {
                    return;
                }
                // Key-window, input-gate, handle geometry and any pending
                // avoidance publication intentionally run one main-loop turn
                // after the Restore render-server completion.
                [self configureFloatingInteractionForDockedState];
                [self layoutFloatingHandleForCurrentContainer];
                if (self.floatingKeyboardAvoidancePublishDeferred) {
                    [self flushFloatingKeyboardAvoidancePublishAfterDock];
                }
                FLMEnqueueDiagnosticLine(
                    @"sb dock-restore deferred-work generation=%lu keyWindow=%d avoidanceDeferred=%d",
                    (unsigned long)restoreTransitionGeneration,
                    self.floatingWindow.isKeyWindow,
                    self.floatingKeyboardAvoidancePublishDeferred);
            });
        }
        NSTimeInterval completionMs =
            (CACurrentMediaTime() - completionStart) * 1000.0;
        FLMEnqueueDiagnosticLine(
            @"sb dock-restore-perf phase=completion prepareMs=%.3f completionMs=%.3f deferredWorkScheduled=%d generation=%lu",
            prepareMs, completionMs, deferredWorkScheduled,
            (unsigned long)restoreTransitionGeneration);
        FLMEnqueueDiagnosticLine(
            @"sb dock-restore complete transition=render-server docked=0 hidden=0 presentationMode=Centered sourcePosition={%.1f,%.1f} targetPosition={%.1f,%.1f} canonicalWidth=%.4f centeredContentScale=%.6f presentationFromScale=%.6f presentationToScale=1.000000 effectiveSourceScale=%.6f remoteHostUnchanged=1 restore-content-scale-stable=%.6f deferredWorkScheduled=%d",
            sourcePosition.x,
            sourcePosition.y,
            targetPosition.x,
            targetPosition.y,
            canonicalReady ? CGRectGetWidth(canonicalGeometry.centeredBounds)
                           : CGRectGetWidth(target),
            centeredContentScale,
            presentationFromScale,
            effectiveSourceScale,
            centeredContentScale,
            deferredWorkScheduled);
    }];
    [containerLayer addAnimation:restoreAnimation
                           forKey:@"flyme.dock.restore.presentation"];
    FLMEnqueueDiagnosticLine(
        @"sb dock-restore-perf phase=add prepareMs=%.3f completionMs=pending deferredWorkScheduled=pending generation=%lu",
        prepareMs, (unsigned long)restoreTransitionGeneration);
    [CATransaction commit];
}

- (void)snapDockedFloatingWindowUsingTouchPoint:(CGPoint)point {
    (void)point;
    if (!self.floatingDocked || self.floatingDockHidden) {
        self.floatingDockTransitionActive = NO;
        self.floatingDockTouchGateTransitionFrame = CGRectNull;
        [self setFloatingDockRoutingSuppressed:NO];
        return;
    }
    // The drag is free in both axes.  Decide the landing side from the card's
    // actual final center (which represents which half of the screen contains
    // more of the card), not from the finger's last sample.  The target keeps
    // the current vertical center, so release never snaps the card upward or
    // downward into a corner.
    UIView *movingView = self.floatingContainer;
    [self normalizeFloatingContainerTransform];
    CGRect bounds = self.floatingWindow.rootViewController.view.bounds;
    CGRect currentFrame = [self floatingContainerPresentationFrame];
    self.floatingDockedOnRight =
        CGRectGetMidX(currentFrame) >= CGRectGetMidX(bounds);
    CGRect target =
        [self dockedFloatingFrameOnRight:self.floatingDockedOnRight
                                   width:self.floatingDockWidth
                 preservingVerticalCenter:CGRectGetMidY(currentFrame)];
    self.floatingDockVerticalCenter = CGRectGetMidY(target);
    FLMEnqueueDiagnosticLine(
        @"sb dock-snap side=%@ current=%@ target=%@ vertical=%.1f",
        self.floatingDockedOnRight ? @"right" : @"left",
        NSStringFromCGRect(currentFrame),
        NSStringFromCGRect(target),
        self.floatingDockVerticalCenter);
    NSUInteger controlTransitionGeneration =
        ++self.floatingDockControlTransitionGeneration;
    self.floatingDockControlTransition =
        FLMFloatingDockControlTransitionSnap;
    self.floatingDockControlTargetFrame = target;
    self.floatingDockControlDefersKeyboardTeardown = NO;
    self.floatingDockTransitionActive = YES;
    self.floatingDockTouchGateTransitionFrame =
        FLMDockTransitionEnvelope(currentFrame, target, bounds);
    [self updateFloatingDockTouchGate];
    [self setFloatingDockRoutingSuppressed:YES];
    // Snap is a presentation-only operation.  The remote Scene, host bounds,
    // shared state and content scale are untouched; Core Animation moves the
    // outer presentation layer's position and commits the model once.
    CALayer *movingLayer = movingView.layer;
    CALayer *presentationLayer = movingLayer.presentationLayer;
    CGPoint fromPosition = presentationLayer
                               ? presentationLayer.position
                               : movingLayer.position;
    CGPoint targetPosition = CGPointMake(CGRectGetMidX(target),
                                         CGRectGetMidY(target));
    CABasicAnimation *snapAnimation =
        [CABasicAnimation animationWithKeyPath:@"position"];
    snapAnimation.fromValue = [NSValue valueWithCGPoint:fromPosition];
    snapAnimation.toValue = [NSValue valueWithCGPoint:targetPosition];
    snapAnimation.duration = 0.24;
    snapAnimation.timingFunction =
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [CATransaction setCompletionBlock:^{
        self.floatingDockTransitionAnimator = nil;
        if (controlTransitionGeneration !=
                self.floatingDockControlTransitionGeneration ||
            self.floatingDockControlTransition !=
                FLMFloatingDockControlTransitionSnap) {
            return;
        }
        self.floatingDockControlTransition =
            FLMFloatingDockControlTransitionNone;
        self.floatingDockControlTargetFrame = CGRectNull;
        if (self.floatingWindow.hidden || !self.floatingDocked ||
            self.floatingDockHidden) {
            self.floatingDockTransitionActive = NO;
            self.floatingDockTouchGateTransitionFrame = CGRectNull;
            [self updateFloatingDockTouchGate];
            [self setFloatingDockRoutingSuppressed:NO];
            return;
        }
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        movingLayer.borderWidth = 0.0;
        movingLayer.cornerRadius = 22.0;
        [CATransaction commit];
        self.floatingDockVerticalCenter = targetPosition.y;
        self.floatingDockTransitionActive = NO;
        [self verifyFloatingDockPresentationScaleInvariant:@"snap-settled"];
        self.floatingDockTouchGateTransitionFrame = CGRectNull;
        self.floatingDockPresentationMode =
            FLMFloatingDockPresentationModeDocked;
        [self updateFloatingDockAccessoryPositions];
        [self updateFloatingDockTouchGate];
        [self setFloatingDockRoutingSuppressed:NO];
        FLMEnqueueDiagnosticLine(
            @"sb dock-snap-complete transition=position-only frame=%@",
            NSStringFromCGRect([self floatingContainerPresentationFrame]));
    }];
    movingLayer.position = targetPosition;
    [movingLayer addAnimation:snapAnimation forKey:@"flyme.dock.snap.position"];
    [CATransaction commit];
}

- (void)configureFloatingLaunchCoverForIdentifier:(NSString *)identifier {
    self.floatingLaunchIconView.image = FLMApplicationIcon(identifier);
    self.floatingLaunchCoverView.alpha = 1.0;
    self.floatingLaunchCoverView.hidden = NO;
    self.floatingLaunchCoverView.userInteractionEnabled = YES;
    self.floatingStatusLabel.hidden = YES;
    [self.floatingContainer bringSubviewToFront:self.floatingLaunchCoverView];
    if (!self.floatingDockInteractionShield.hidden) {
        [self.floatingContainer bringSubviewToFront:self.floatingDockInteractionShield];
    }
}

- (void)revealFloatingContentForGeneration:(NSUInteger)generation {
    // A presentationView can exist one or two compositor frames before its
    // remote surface contains the app. Keep the neutral app cover above it for
    // that short interval, then reveal the already-laid-out content once.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(FLMFloatingLaunchCoverSettleDelay *
                                           NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != self.floatingLaunchGeneration ||
            self.floatingWindow.hidden) {
            return;
        }
        if (!self.floatingHostView ||
            self.floatingLaunchState != FLMFloatingLaunchStateAttached) {
            if (self.floatingRevealRetryCount < 4) {
                self.floatingRevealRetryCount += 1;
                FLMEnqueueDiagnosticLine(
                    @"sb launch-cover retry-reveal generation=%lu retry=%lu state=%lu host=%p",
                    (unsigned long)generation,
                    (unsigned long)self.floatingRevealRetryCount,
                    (unsigned long)self.floatingLaunchState,
                    (__bridge void *)self.floatingHostView);
                [self revealFloatingContentForGeneration:generation];
            } else {
                FLMEnqueueDiagnosticLine(
                    @"sb launch-cover recovery-failed generation=%lu state=%lu host=%p",
                    (unsigned long)generation,
                    (unsigned long)self.floatingLaunchState,
                    (__bridge void *)self.floatingHostView);
                [self failFloatingLaunchForIdentifier:self.floatingIdentifier
                                             generation:generation];
            }
            return;
        }
        self.floatingRevealRetryCount = 0;
        [self.floatingHostView setNeedsLayout];
        [self.floatingHostView layoutIfNeeded];
        [UIView animateWithDuration:FLMFloatingLaunchCoverFadeDuration
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseOut |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
                             self.floatingLaunchCoverView.alpha = 0.0;
                         }
                         completion:^(__unused BOOL finished) {
            if (generation != self.floatingLaunchGeneration ||
                self.floatingWindow.hidden ||
                self.floatingLaunchState != FLMFloatingLaunchStateAttached) {
                return;
            }
            self.floatingLaunchCoverView.hidden = YES;
            self.floatingLaunchCoverView.alpha = 1.0;
            self.floatingLaunchCoverView.userInteractionEnabled = NO;
            // The launch-cover completion is also used by the hidden-mode
            // frontmost-app route.  Do not blindly re-enable the remote host
            // here: the dock/hidden transition can still be pending, and the
            // completion itself must never be the first path that lets a
            // touch reach app content.
            BOOL contentCanInteract =
                !self.floatingDocked &&
                !self.floatingDockHidden &&
                !self.floatingDockTransitionActive &&
                !self.floatingDockContentTailProtected &&
                !self.floatingOpenTargetDocked;
            [self setFloatingApplicationInputBlocked:!contentCanInteract];
            self.floatingHandle.userInteractionEnabled = contentCanInteract;
            self.floatingExclusiveGesture.enabled =
                contentCanInteract && self.usesSystemGestureManager;
            if (self.floatingOpenTargetDocked) {
                self.floatingOpenTargetDocked = NO;
                FLMEnqueueDiagnosticLine(
                    @"sb home-dock transition app=%@",
                    self.floatingIdentifier ?: @"<none>");
                [self transitionFloatingWindowToDocked];
            }
        }];
    });
}

- (void)layoutFloatingWindow {
    if (!self.floatingWindow) {
        return;
    }
    CGRect bounds = self.floatingWindow.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    if (width <= 0.0 || height <= 0.0) {
        return;
    }
    if (self.floatingDockTransitionActive) {
        // Dock transitions own the outer PresentationContainer until their
        // compositor completion. A layout pass here must never resize the
        // remote host or overwrite an in-flight position/scale animation.
        return;
    }

    if (self.floatingKeyboardSessionGeneration != 0) {
        [self ensureSessionCanonicalGeometry];
    }
    CGRect targetFrame = [self centeredFloatingFrame];
    if (self.floatingDocked) {
        CGFloat verticalCenter = self.floatingDockVerticalCenter;
        if (verticalCenter <= 0.0) {
            verticalCenter =
                CGRectGetMidY([self floatingContainerPresentationFrame]);
        }
        CGRect fallbackFrame =
            [self dockedFloatingFrameOnRight:self.floatingDockedOnRight
                                       width:self.floatingDockWidth];
        if (verticalCenter <= 0.0) {
            verticalCenter = CGRectGetMidY(fallbackFrame);
        }
        targetFrame = self.floatingDockHidden
                          ? [self dockedHiddenFloatingFrameOnRight:
                                   self.floatingDockedOnRight
                                                               width:self.floatingDockWidth
                                             preservingVerticalCenter:verticalCenter]
                          : [self dockedFloatingFrameOnRight:
                                   self.floatingDockedOnRight
                                                               width:self.floatingDockWidth
                                             preservingVerticalCenter:verticalCenter];
        self.floatingDockVerticalCenter = CGRectGetMidY(targetFrame);
    }
    if (self.floatingDocked) {
        [self configureFloatingContainerForDockPresentationAtCenter:
                  CGPointMake(CGRectGetMidX(targetFrame),
                              CGRectGetMidY(targetFrame))
                                                          scale:[self floatingDockPresentationScale]];
        self.floatingContainer.layer.cornerRadius = 22.0;
    } else {
        if ([self ensureSessionCanonicalGeometry]) {
            [self reassertSessionCanonicalCenteredModelGeometry];
        } else {
            self.floatingContainer.transform = CGAffineTransformIdentity;
            self.floatingContainer.frame = targetFrame;
        }
        self.floatingContainer.layer.cornerRadius = 22.0;
        [self layoutFloatingHostView];
    }
    self.floatingStatusLabel.frame = self.floatingContainer.bounds;
    self.floatingLaunchCoverView.frame = self.floatingContainer.bounds;
    CGFloat iconSide = MIN(88.0,
                           MAX(64.0,
                               CGRectGetWidth(self.floatingContainer.bounds) *
                                   0.24));
    self.floatingLaunchIconView.bounds =
        CGRectMake(0.0, 0.0, iconSide, iconSide);
    self.floatingLaunchIconView.center =
        CGPointMake(CGRectGetMidX(self.floatingLaunchCoverView.bounds),
                    CGRectGetMidY(self.floatingLaunchCoverView.bounds));
    self.floatingDockInteractionShield.frame = self.floatingContainer.bounds;
    [self layoutFloatingHandleForCurrentContainer];
    [self layoutFloatingDockShadow];
    [self layoutFloatingResizeHandle];
    [self updateFloatingDockTouchGate];
}

- (void)layoutFloatingHandleForCurrentContainer {
    CGRect bounds = self.floatingWindow.rootViewController.view.bounds;
    BOOL centeredInteraction =
        !self.floatingDocked && !self.floatingDockHidden &&
        !self.floatingDockTransitionActive &&
        !self.floatingDockInputSessionActive &&
        !self.floatingDockContentTailProtected;
    CGRect containerFrame = centeredInteraction &&
                                    [self ensureSessionCanonicalGeometry]
                                ? self.sessionCanonicalGeometry.centeredFrame
                                : [self floatingContainerPresentationFrame];
    CGFloat containerWidth = CGRectGetWidth(containerFrame);
    if (self.floatingDockHidden) {
        CGFloat handleWidth = 44.0;
        CGFloat handleHeight = 72.0;
        CGFloat x = self.floatingDockedOnRight
                         ? CGRectGetWidth(bounds) - handleWidth
                         : 0.0;
        CGFloat y = CGRectGetMinY(containerFrame) + 24.0;
        self.floatingHandle.frame =
            CGRectMake(x, MAX(8.0, y), handleWidth, handleHeight);
        // The hidden grab bar uses a stable vertical length while it remains
        // attached to the edge.
        CGFloat barLength = 44.0;
        self.floatingHandleBar.frame =
            CGRectMake(self.floatingDockedOnRight ? 36.0 : 3.0,
                       floor((handleHeight - barLength) * 0.5),
                       5.0,
                       barLength);
        return;
    }
    CGFloat visibleHandleWidth = containerWidth * 0.30;
    // Keep the invisible hit target outside the application card. The visible
    // bar remains centered, with exactly 20 pt of horizontal reach on each
    // side and a little more vertical forgiveness.
    CGFloat handleWidth = visibleHandleWidth + 40.0;
    CGFloat handleHeight = 58.0;
    self.floatingHandle.frame =
        CGRectMake(floor(CGRectGetMidX(containerFrame) -
                         handleWidth * 0.5),
                   CGRectGetMaxY(containerFrame),
                   handleWidth,
                   handleHeight);
    self.floatingHandleBar.frame =
        CGRectMake(20.0,
                   floor((handleHeight - 5.0) * 0.5),
                   visibleHandleWidth,
                   5.0);
}

- (void)layoutFloatingHostView {
    UIView *host = self.floatingHostView;
    if (!host || !self.floatingContainer) {
        return;
    }
    CGSize systemSceneReference = [self floatingSystemSceneReferenceSize];
    // The host always receives the full-screen logical canvas. The card is a
    // clipped presentation surface, not a replacement content viewport.
    CGSize referenceSize = systemSceneReference;
    self.floatingHostReferenceSize = referenceSize;
    CGSize targetSize = self.floatingContainer.bounds.size;
    if (targetSize.width < 1.0 || targetSize.height < 1.0) {
        return;
    }

    // RemoteSceneHost is a fixed logical canvas for the entire centered-card
    // session. Dock is an outer PresentationContainer transform; it never
    // changes the host bounds, host transform, Scene frame, or viewport.
    BOOL canonicalReady = [self ensureSessionCanonicalGeometry];
    CGFloat remoteContentScale = canonicalReady
                                     ? self.sessionCanonicalGeometry
                                           .centeredContentScale
                                     : [self effectiveCenteredCardScaleX];
    if (!isfinite(remoteContentScale) || remoteContentScale <= 0.001) {
        remoteContentScale = [self configuredCenteredCardWidth] /
                             FLMVirtualViewportWidth;
    }
    CGFloat uniformScale = remoteContentScale;
    CGFloat dockPresentationScale =
        (self.floatingDocked || self.floatingDockHidden ||
         self.floatingDockTransitionActive)
            ? [self floatingDockPresentationScale]
            : 1.0;
    CALayer *presentationLayer = self.floatingContainer.layer.presentationLayer;
    CGFloat presentationContainerScale = FLMUniformScaleFromTransform(
        presentationLayer ? presentationLayer.transform
                           : self.floatingContainer.layer.transform);
    CGFloat effectiveDockScale = remoteContentScale * dockPresentationScale;
    CGRect targetPhysicalCard = canonicalReady
                                    ? self.sessionCanonicalGeometry.centeredFrame
                                    : [self centeredFloatingFrame];
    if (self.floatingInteractiveFullscreenTransition) {
        targetPhysicalCard = [self floatingContainerPresentationFrame];
    }
    if (CGRectIsNull(targetPhysicalCard) || CGRectIsEmpty(targetPhysicalCard)) {
        targetPhysicalCard = [self centeredFloatingFrame];
    }
    uniformScale = MAX(0.05, uniformScale);
    CGFloat scaleX = uniformScale;
    CGFloat scaleY = uniformScale;
    host.transform = CGAffineTransformIdentity;
    host.bounds = CGRectMake(0.0,
                             0.0,
                             referenceSize.width,
                             referenceSize.height);
    // The centered card shifts its content window by (bottom-top)/2. The
    // outer Dock transform scales this already-fixed host together with the
    // container, so the same offset is retained in every Dock state.
    CGFloat cropOffset =
        self.floatingInteractiveFullscreenTransition
            ? 0.0
            : (self.centeredCardBottomCrop - self.centeredCardTopCrop) * 0.5;
    host.center = CGPointMake(CGRectGetMidX(self.floatingContainer.bounds),
                              CGRectGetMidY(self.floatingContainer.bounds) +
                                  cropOffset);
    host.clipsToBounds = NO;
    host.transform = CGAffineTransformMakeScale(scaleX, scaleY);
    FLMEnqueueDiagnosticLine(
        @"sb content-scale policy=%@ systemSceneReference={%.4f,%.4f} hostReference={%.4f,%.4f} targetPhysicalCard={%.1f,%.1f} scaleXY={%.6f,%.6f} uniform=%d selectedCard={%.1f,%.1f} topCrop=%.1f bottomCrop=%.1f dockPresentationScale=%.6f presentationContainerScale=%.6f remoteContentScale=%.6f effectiveDockScale=%.6f sceneFrameReference=system",
        self.floatingInteractiveFullscreenTransition ? @"fullscreen-transition" : @"session-fixed",
        systemSceneReference.width,
        systemSceneReference.height,
        referenceSize.width,
        referenceSize.height,
        CGRectGetWidth(targetPhysicalCard),
        CGRectGetHeight(targetPhysicalCard),
        scaleX,
        scaleY,
        fabs(scaleX - scaleY) <= 0.0001,
        [self effectiveCenteredCardWidth],
        [self effectiveCenteredCardHeight],
        self.centeredCardTopCrop,
        self.centeredCardBottomCrop,
        dockPresentationScale,
        presentationContainerScale,
        remoteContentScale,
        effectiveDockScale);
    BOOL dockPresentationBusy = self.floatingDocked ||
                                self.floatingDockTransitionActive ||
                                self.floatingDockInputSessionActive;
    if (!dockPresentationBusy) {
        FLMPublishKeyboardCardGeometry(
            self.floatingKeyboardSessionGeneration,
            CGRectGetMaxY(targetPhysicalCard),
            uniformScale,
            [self effectiveCenteredCardWidth],
            [self effectiveCenteredCardHeight],
            !self.floatingWindow.hidden && !self.floatingDocked &&
                self.floatingKeyboardSessionGeneration != 0 &&
                !self.floatingSceneCardGeometryPending);
    } else {
        FLMEnqueueDiagnosticLine(
            @"sb dock-presentation geometry-suppressed=1 docked=%d transition=%d input=%d",
            self.floatingDocked,
            self.floatingDockTransitionActive,
            self.floatingDockInputSessionActive);
    }
}

- (BOOL)propagateFloatingKeyboardScenePairing:(id)keyboardScene
                         preferredHostIdentity:(id)preferredHostIdentity
                             sessionGeneration:(NSUInteger)sessionGeneration {
    if (!keyboardScene || !preferredHostIdentity || sessionGeneration == 0 ||
        sessionGeneration != self.floatingKeyboardSessionGeneration ||
        self.floatingWindow.hidden || self.floatingDocked) {
        return NO;
    }
    if (self.floatingKeyboardScene == keyboardScene &&
        self.floatingKeyboardPreferredHostIdentity == preferredHostIdentity &&
        self.floatingKeyboardPairingSessionGeneration == sessionGeneration) {
        return YES;
    }

    SEL updateSelector = NSSelectorFromString(@"updateClientSettingsWithBlock:");
    if (![keyboardScene respondsToSelector:updateSelector]) {
        FLMEnqueueDiagnosticLine(
            @"sb scene-pair apply=unsupported session=%lu keyboardScene=%@ class=%@",
            (unsigned long)sessionGeneration,
            FLMSceneIdentifier(keyboardScene) ?: @"<none>",
            NSStringFromClass([keyboardScene class]));
        return NO;
    }

    self.floatingKeyboardScene = keyboardScene;
    self.floatingKeyboardPreferredHostIdentity = preferredHostIdentity;
    self.floatingKeyboardPairingSessionGeneration = sessionGeneration;
    __block BOOL applied = NO;
    __block NSString *failure = nil;
    void (^settingsBlock)(id) = ^(id mutableSettings) {
        @try {
            id currentIdentity = nil;
            @try {
                currentIdentity =
                    [mutableSettings valueForKey:@"preferredSceneHostIdentity"];
            } @catch (__unused NSException *exception) {
            }
            if (currentIdentity && currentIdentity != preferredHostIdentity &&
                ![currentIdentity isEqual:preferredHostIdentity]) {
                failure = @"identity-changed";
                return;
            }
            SEL setter =
                NSSelectorFromString(@"setPreferredSceneHostIdentity:");
            if ([mutableSettings respondsToSelector:setter]) {
                ((void (*)(id, SEL, id))objc_msgSend)(mutableSettings,
                                                     setter,
                                                     preferredHostIdentity);
            } else {
                [mutableSettings setValue:preferredHostIdentity
                                   forKey:@"preferredSceneHostIdentity"];
            }
            applied = YES;
        } @catch (NSException *exception) {
            failure = exception.name ?: @"exception";
        }
    };
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(keyboardScene,
                                             updateSelector,
                                             settingsBlock);
    } @catch (NSException *exception) {
        failure = exception.name ?: @"exception";
    }
    if (!applied) {
        self.floatingKeyboardScene = nil;
        self.floatingKeyboardPreferredHostIdentity = nil;
        self.floatingKeyboardPairingSessionGeneration = 0;
    }
    FLMEnqueueDiagnosticLine(
        @"sb scene-pair apply=%d session=%lu keyboardScene=%@ preferredClass=%@ preferred=%p failure=%@",
        applied, (unsigned long)sessionGeneration,
        FLMSceneIdentifier(keyboardScene) ?: @"<none>",
        NSStringFromClass([preferredHostIdentity class]),
        (__bridge void *)preferredHostIdentity, failure ?: @"<none>");
    return applied;
}

- (void)clearFloatingKeyboardScenePairingForSession:(NSUInteger)sessionGeneration {
    id keyboardScene = self.floatingKeyboardScene;
    BOOL owned = keyboardScene && sessionGeneration != 0 &&
                 self.floatingKeyboardPairingSessionGeneration ==
                     sessionGeneration;
    __block BOOL cleared = NO;
    __block NSString *failure = nil;
    SEL updateSelector = NSSelectorFromString(@"updateClientSettingsWithBlock:");
    if (owned && [keyboardScene respondsToSelector:updateSelector]) {
        id ownedIdentity = self.floatingKeyboardPreferredHostIdentity;
        void (^settingsBlock)(id) = ^(id mutableSettings) {
            @try {
                id currentIdentity = nil;
                @try {
                    currentIdentity =
                        [mutableSettings valueForKey:@"preferredSceneHostIdentity"];
                } @catch (__unused NSException *exception) {
                }
                if (currentIdentity && ownedIdentity &&
                    currentIdentity != ownedIdentity &&
                    ![currentIdentity isEqual:ownedIdentity]) {
                    failure = @"identity-changed";
                    return;
                }
                SEL setter =
                    NSSelectorFromString(@"setPreferredSceneHostIdentity:");
                if ([mutableSettings respondsToSelector:setter]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(mutableSettings,
                                                         setter,
                                                         nil);
                } else {
                    [mutableSettings setValue:nil
                                       forKey:@"preferredSceneHostIdentity"];
                }
                cleared = YES;
            } @catch (NSException *exception) {
                failure = exception.name ?: @"exception";
            }
        };
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(keyboardScene,
                                                 updateSelector,
                                                 settingsBlock);
        } @catch (NSException *exception) {
            failure = exception.name ?: @"exception";
        }
    }
    FLMEnqueueDiagnosticLine(
        @"sb scene-pair clear=%d owned=%d session=%lu keyboardScene=%@ failure=%@",
        cleared, owned, (unsigned long)sessionGeneration,
        FLMSceneIdentifier(keyboardScene) ?: @"<none>",
        failure ?: @"<none>");
    self.floatingKeyboardScene = nil;
    self.floatingKeyboardPreferredHostIdentity = nil;
    self.floatingKeyboardPairingSessionGeneration = 0;
}

- (void)prepareKeyboardForwardingWindowIfNeeded {
    UIWindowScene *targetWindowScene = self.floatingWindow.windowScene;
    if (!targetWindowScene) {
        targetWindowScene = FLMForegroundWindowScene();
    }
    if (!targetWindowScene) {
        return;
    }

    FLMKeyboardForwardingWindow *existingWindow =
        self.keyboardForwardingWindow;
    if (existingWindow && existingWindow.windowScene != targetWindowScene) {
        [self restoreFloatingKeyboardLayerHost];
        existingWindow.hidden = YES;
        existingWindow.rootViewController = nil;
        self.keyboardForwardingWindow = nil;
        existingWindow = nil;
    }
    if (existingWindow) {
        CGRect bounds = FLMVisualScreenBounds();
        existingWindow.frame = bounds;
        existingWindow.rootViewController.view.frame = existingWindow.bounds;
        existingWindow.windowLevel = self.floatingWindow.windowLevel + 1.0;
        return;
    }

    CGRect bounds = FLMVisualScreenBounds();
    FLMKeyboardForwardingWindow *window =
        [[FLMKeyboardForwardingWindow alloc]
            initWithWindowScene:targetWindowScene];
    window.frame = bounds;
    // TrollOpen's level 45 sits above its own content hierarchy. Flyme's card
    // is itself an alert-level SpringBoard window, so the same absolute level
    // incorrectly places the native keyboard underneath it. Keep the keyboard
    // one level above the card while preserving the same Scene and responder.
    window.windowLevel = self.floatingWindow.windowLevel + 1.0;
    window.backgroundColor = [UIColor clearColor];
    window.opaque = NO;
    window.userInteractionEnabled = YES;
    window.keyboardInteractionFrame = CGRectNull;
    FLMOverlayViewController *rootController =
        [[FLMOverlayViewController alloc] init];
    rootController.view.backgroundColor = [UIColor clearColor];
    rootController.view.frame = window.bounds;
    rootController.view.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    window.rootViewController = rootController;
    SEL autorotationSelector =
        NSSelectorFromString(@"setAutorotates:forceUpdateInterfaceOrientation:");
    if ([window respondsToSelector:autorotationSelector]) {
        ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(window,
                                                     autorotationSelector,
                                                     NO,
                                                     NO);
    }
    window.hidden = YES;
    self.keyboardForwardingWindow = window;
}

- (void)keyboardLayerHostView:(UIView *)hostView
            didUpdateForScene:(id)scene
            sessionGeneration:(NSUInteger)sessionGeneration {
    FLMEnqueueDiagnosticLine(
        @"sb host-update enter host=%p session=%lu current=%lu scene=%@ target=%@ hidden=%d docked=%d launch=%lu",
        (__bridge void *)hostView, (unsigned long)sessionGeneration,
        (unsigned long)self.floatingKeyboardSessionGeneration,
        FLMSceneIdentifier(scene) ?: @"<none>",
        FLMSceneIdentifier(self.floatingScene) ?: @"<none>",
        self.floatingWindow.hidden, self.floatingDocked,
        (unsigned long)self.floatingLaunchState);
    // A keyboard Scene can finish one last host transaction after the outside
    // tap has started closing the card.  That callback must be hidden before
    // the hosted application Scene is detached; otherwise UIKit retains it in
    // the application hierarchy and restores it inside the next card.
    if (hostView && self.floatingCloseInProgress) {
        id closingScene = self.floatingClosingScene ?: self.floatingScene;
        id owningScene = nil;
        @try {
            owningScene = [hostView valueForKey:@"_owningScene"];
        } @catch (__unused NSException *exception) {
        }
        NSString *closingIdentifier = FLMSceneIdentifier(closingScene);
        NSString *owningIdentifier = FLMSceneIdentifier(owningScene);
        NSString *updatedIdentifier = FLMSceneIdentifier(scene);
        BOOL closingSceneMatches = closingScene &&
            (owningScene == closingScene || scene == closingScene ||
             (closingIdentifier.length > 0 &&
              ([closingIdentifier isEqualToString:owningIdentifier] ||
               [closingIdentifier isEqualToString:updatedIdentifier])));
        if (closingSceneMatches) {
            if (hostView != self.floatingKeyboardLayerHostView) {
                [self quarantineFloatingKeyboardHost:hostView
                                   sessionGeneration:sessionGeneration
                                               reason:@"closing-transaction"];
            }
            FLMEnqueueDiagnosticLine(
                @"sb host-update quarantined=closing-transaction host=%p session=%lu active=%p scene=%@",
                (__bridge void *)hostView, (unsigned long)sessionGeneration,
                (__bridge void *)self.floatingKeyboardLayerHostView,
                closingIdentifier ?: @"<none>");
            return;
        }
    }
    if (!hostView || sessionGeneration == 0 ||
        sessionGeneration != self.floatingKeyboardSessionGeneration ||
        self.floatingWindow.hidden || self.floatingDocked ||
        !self.floatingScene || self.floatingIdentifier.length == 0 ||
        self.floatingLaunchState == FLMFloatingLaunchStateClosing) {
        FLMEnqueueDiagnosticLine(@"sb host-update rejected=inactive");
        return;
    }
    if (![self floatingApplicationHostReadyForKeyboardRoute]) {
        self.floatingKeyboardDeferredHostView = hostView;
        self.floatingKeyboardDeferredScene = scene;
        self.floatingKeyboardDeferredSessionGeneration = sessionGeneration;
        FLMEnqueueDiagnosticLine(
            @"sb host-deferred waiting=application-host session=%lu host=%p scene=%@ contentViewportPending=%d contentViewportCommitted=%d launch=%lu",
            (unsigned long)sessionGeneration, (__bridge void *)hostView,
            FLMSceneIdentifier(scene) ?: @"<none>",
            self.floatingSceneCardGeometryPending,
            self.floatingSceneCardGeometryCommitted,
            (unsigned long)self.floatingLaunchState);
        return;
    }

    id owningScene = nil;
    id keyboardScene = nil;
    id preferredHostIdentity = nil;
    BOOL paired = NO;
    @try {
        owningScene = [hostView valueForKey:@"_owningScene"];
        keyboardScene = [hostView valueForKey:@"_keyboardScene"];
        preferredHostIdentity =
            [hostView valueForKey:@"_keyboardPreferredHostIdentity"];
        id pairedValue = [hostView valueForKey:@"_isPaired"];
        paired = [pairedValue respondsToSelector:@selector(boolValue)] &&
                 [pairedValue boolValue];
    } @catch (__unused NSException *exception) {
    }
    NSString *targetIdentifier = FLMSceneIdentifier(self.floatingScene);
    NSString *owningIdentifier = FLMSceneIdentifier(owningScene);
    NSString *updatedIdentifier = FLMSceneIdentifier(scene);
    FLMEnqueueDiagnosticLine(
        @"sb host-native owner=%@ keyboardScene=%@ preferredHostClass=%@ preferredHost=%p paired=%d",
        owningIdentifier ?: @"<none>",
        FLMSceneIdentifier(keyboardScene) ?: @"<none>",
        preferredHostIdentity
            ? NSStringFromClass([preferredHostIdentity class])
            : @"<none>",
        (__bridge void *)preferredHostIdentity, paired);
    BOOL matches = owningScene == self.floatingScene || scene == self.floatingScene;
    if (!matches && targetIdentifier.length > 0) {
        matches = [targetIdentifier isEqualToString:owningIdentifier] ||
                  [targetIdentifier isEqualToString:updatedIdentifier];
    }
    if (!matches) {
        FLMEnqueueDiagnosticLine(
            @"sb host-update rejected=scene-mismatch target=%@ owner=%@ updated=%@",
            targetIdentifier ?: @"<none>", owningIdentifier ?: @"<none>",
            updatedIdentifier ?: @"<none>");
        return;
    }
    // A native keyboard host is not safe to reparent until UIKit has supplied
    // the keyboard Scene and its preferred host identity. In 0.8.59 two host
    // objects arrived for one session; accepting both made them alternately
    // steal the forwarding window and occasionally exposed the keyboard in
    // the card's own hierarchy.
    if (!paired || !keyboardScene || !preferredHostIdentity) {
        if (hostView == self.floatingKeyboardLayerHostView) {
            FLMEnqueueDiagnosticLine(
                @"sb host-update ignored=unpaired-current host=%p session=%lu",
                (__bridge void *)hostView,
                (unsigned long)sessionGeneration);
        } else {
            [self quarantineFloatingKeyboardHost:hostView
                               sessionGeneration:sessionGeneration
                                           reason:@"waiting-pairing"];
            self.floatingKeyboardDeferredHostView = hostView;
            self.floatingKeyboardDeferredScene = scene;
            self.floatingKeyboardDeferredSessionGeneration = sessionGeneration;
            FLMEnqueueDiagnosticLine(
                @"sb host-deferred waiting=pairing host=%p session=%lu keyboardScene=%@ preferred=%p",
                (__bridge void *)hostView,
                (unsigned long)sessionGeneration,
                FLMSceneIdentifier(keyboardScene) ?: @"<none>",
                (__bridge void *)preferredHostIdentity);
        }
        return;
    }
    if (self.floatingKeyboardLayerHostView &&
        hostView != self.floatingKeyboardLayerHostView &&
        self.floatingKeyboardHostSessionGeneration == sessionGeneration) {
        // Keep one native host for the lifetime of a keyboard session. The
        // alternate host is a UIKit compositor callback, not a new route.
        [self quarantineFloatingKeyboardHost:hostView
                           sessionGeneration:sessionGeneration
                                       reason:@"alternate-host"];
        FLMEnqueueDiagnosticLine(
            @"sb host-update rejected=alternate-host active=%p incoming=%p session=%lu",
            (__bridge void *)self.floatingKeyboardLayerHostView,
            (__bridge void *)hostView,
            (unsigned long)sessionGeneration);
        return;
    }
    if (paired && keyboardScene && preferredHostIdentity) {
        [self propagateFloatingKeyboardScenePairing:keyboardScene
                              preferredHostIdentity:preferredHostIdentity
                                  sessionGeneration:sessionGeneration];
    }

    [self prepareKeyboardForwardingWindowIfNeeded];
    UIView *forwardingRoot =
        self.keyboardForwardingWindow.rootViewController.view;
    if (!forwardingRoot) {
        FLMEnqueueDiagnosticLine(@"sb host-update rejected=no-forwarding-root");
        return;
    }

    // A host can first arrive as the unpaired duplicate and then become the
    // selected host in a later UIKit transaction. Restore its original
    // visibility before moving it to the forwarding window.
    [self releaseFloatingKeyboardHostQuarantine:hostView
                                          reason:@"selected-host"];

    if (hostView != self.floatingKeyboardLayerHostView ||
        self.floatingKeyboardHostSessionGeneration != sessionGeneration) {
        if (self.floatingKeyboardLayerHostView) {
            if (self.floatingKeyboardHostSessionGeneration == sessionGeneration) {
                [self restoreFloatingKeyboardLayerHost];
            } else {
                [self discardFloatingKeyboardLayerHost];
            }
        }
        UIView *originalSuperview = hostView.superview;
        self.floatingKeyboardOriginalSuperview = originalSuperview;
        self.floatingKeyboardOriginalSubviewIndex =
            originalSuperview ? [originalSuperview.subviews indexOfObject:hostView]
                              : NSNotFound;
        self.floatingKeyboardOriginalFrame = hostView.frame;
        self.floatingKeyboardOriginalTransform = hostView.transform;
        self.floatingKeyboardOriginalAutoresizingMask = hostView.autoresizingMask;
        self.floatingKeyboardOriginalTranslatesAutoresizingMask =
            hostView.translatesAutoresizingMaskIntoConstraints;
        self.floatingKeyboardLayerHostView = hostView;
        self.floatingKeyboardHostSessionGeneration = sessionGeneration;
    }

    if (hostView.superview != forwardingRoot) {
        [hostView removeFromSuperview];
        hostView.translatesAutoresizingMaskIntoConstraints = YES;
        hostView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                    UIViewAutoresizingFlexibleHeight;
        hostView.transform = CGAffineTransformIdentity;
        hostView.frame = forwardingRoot.bounds;
        [forwardingRoot addSubview:hostView];
    } else {
        hostView.transform = CGAffineTransformIdentity;
        hostView.frame = forwardingRoot.bounds;
    }
    [hostView setNeedsLayout];
    [hostView layoutIfNeeded];
    if (self.floatingKeyboardVisible) {
        [self.keyboardForwardingWindow makeKeyAndVisible];
    } else {
        // Keep the forwarding window completely hidden while the keyboard is
        // not visible. The native host can remain attached for the next
        // keyboard frame without becoming an accidental on-card keyboard.
        self.keyboardForwardingWindow.hidden = YES;
    }
    FLMEnqueueDiagnosticLine(
        @"sb host-update paired host=%p session=%lu visible=%d hostFrame=%@ windowLevel=%.1f key=%d",
        (__bridge void *)hostView, (unsigned long)sessionGeneration,
        self.floatingKeyboardVisible, NSStringFromCGRect(hostView.frame),
        self.keyboardForwardingWindow.windowLevel,
        self.keyboardForwardingWindow.isKeyWindow);
    [self flushDeferredFloatingKeyboardHostIfReady];
    [self flushPendingFloatingKeyboardFrameIfReady];
}

- (void)deactivateKeyboardForwardingWindow {
    FLMKeyboardForwardingWindow *window = self.keyboardForwardingWindow;
    BOOL wasKey = window.isKeyWindow;
    window.keyboardInteractionFrame = CGRectNull;
    if (wasKey && !self.floatingWindow.hidden &&
        !self.floatingDocked) {
        [self.floatingWindow makeKeyWindow];
    }
    window.hidden = YES;
    FLMEnqueueDiagnosticLine(
        @"sb forwarding-deactivate wasKey=%d cardHidden=%d docked=%d",
        wasKey, self.floatingWindow.hidden, self.floatingDocked);
}

- (void)quarantineFloatingKeyboardHost:(UIView *)hostView
                     sessionGeneration:(NSUInteger)sessionGeneration
                                 reason:(NSString *)reason {
    if (!hostView || hostView == self.floatingKeyboardLayerHostView) {
        return;
    }
    UIView *previousHost = self.floatingKeyboardRejectedHostView;
    if (previousHost && previousHost != hostView) {
        [self discardFloatingKeyboardHostQuarantine:previousHost
                                              reason:@"replaced"];
    }
    BOOL newlyQuarantined = self.floatingKeyboardRejectedHostView != hostView;
    if (newlyQuarantined) {
        self.floatingKeyboardRejectedHostWasHidden = hostView.hidden;
        self.floatingKeyboardRejectedHostView = hostView;
    }
    @try {
        hostView.hidden = YES;
    } @catch (__unused NSException *exception) {
    }
    if (newlyQuarantined) {
        FLMEnqueueDiagnosticLine(
            @"sb host-quarantine host=%p session=%lu reason=%@ originallyHidden=%d superview=%p",
            (__bridge void *)hostView, (unsigned long)sessionGeneration,
            reason ?: @"<none>", self.floatingKeyboardRejectedHostWasHidden,
            (__bridge void *)hostView.superview);
    }
}

- (void)releaseFloatingKeyboardHostQuarantine:(UIView *)hostView
                                        reason:(NSString *)reason {
    if (!hostView || hostView != self.floatingKeyboardRejectedHostView) {
        return;
    }
    BOOL originallyHidden = self.floatingKeyboardRejectedHostWasHidden;
    @try {
        hostView.hidden = originallyHidden;
    } @catch (__unused NSException *exception) {
    }
    self.floatingKeyboardRejectedHostView = nil;
    self.floatingKeyboardRejectedHostWasHidden = NO;
    FLMEnqueueDiagnosticLine(
        @"sb host-quarantine-release host=%p reason=%@ restoredHidden=%d",
        (__bridge void *)hostView, reason ?: @"<none>", originallyHidden);
}

- (void)releaseAllFloatingKeyboardHostQuarantinesForReason:(NSString *)reason {
    UIView *hostView = self.floatingKeyboardRejectedHostView;
    if (hostView) {
        [self releaseFloatingKeyboardHostQuarantine:hostView reason:reason];
    } else {
        self.floatingKeyboardRejectedHostWasHidden = NO;
    }
}

- (void)discardFloatingKeyboardHostQuarantine:(UIView *)hostView
                                        reason:(NSString *)reason {
    if (!hostView || hostView != self.floatingKeyboardRejectedHostView) {
        return;
    }
    UIView *previousSuperview = hostView.superview;
    self.floatingKeyboardRejectedHostView = nil;
    self.floatingKeyboardRejectedHostWasHidden = NO;
    @try {
        [hostView removeFromSuperview];
    } @catch (__unused NSException *exception) {
    }
    FLMEnqueueDiagnosticLine(
        @"sb host-quarantine-discard host=%p reason=%@ previousSuperview=%p",
        (__bridge void *)hostView, reason ?: @"<none>",
        (__bridge void *)previousSuperview);
}

- (void)discardAllFloatingKeyboardHostQuarantinesForReason:(NSString *)reason {
    UIView *hostView = self.floatingKeyboardRejectedHostView;
    if (hostView) {
        [self discardFloatingKeyboardHostQuarantine:hostView reason:reason];
    } else {
        self.floatingKeyboardRejectedHostWasHidden = NO;
    }
}

- (void)restoreFloatingKeyboardLayerHost {
    UIView *hostView = self.floatingKeyboardLayerHostView;
    UIView *originalSuperview = self.floatingKeyboardOriginalSuperview;
    if (hostView) {
        @try {
            [hostView removeFromSuperview];
            hostView.transform = self.floatingKeyboardOriginalTransform;
            hostView.frame = self.floatingKeyboardOriginalFrame;
            hostView.autoresizingMask =
                self.floatingKeyboardOriginalAutoresizingMask;
            hostView.translatesAutoresizingMaskIntoConstraints =
                self.floatingKeyboardOriginalTranslatesAutoresizingMask;
            if (originalSuperview) {
                NSInteger index = self.floatingKeyboardOriginalSubviewIndex;
                if (index >= 0 &&
                    index <= (NSInteger)originalSuperview.subviews.count) {
                    [originalSuperview insertSubview:hostView
                                              atIndex:(NSUInteger)index];
                } else {
                    [originalSuperview addSubview:hostView];
                }
            }
        } @catch (__unused NSException *exception) {
        }
    }
    self.floatingKeyboardLayerHostView = nil;
    self.floatingKeyboardOriginalSuperview = nil;
    self.floatingKeyboardOriginalSubviewIndex = NSNotFound;
    self.floatingKeyboardHostSessionGeneration = 0;
    self.floatingKeyboardDeferredHostView = nil;
    self.floatingKeyboardDeferredScene = nil;
    self.floatingKeyboardDeferredSessionGeneration = 0;
    [self deactivateKeyboardForwardingWindow];
    FLMEnqueueDiagnosticLine(
        @"sb host-restore host=%p originalSuperview=%p",
        (__bridge void *)hostView, (__bridge void *)originalSuperview);
}

- (void)discardFloatingKeyboardLayerHost {
    UIView *hostView = self.floatingKeyboardLayerHostView;
    @try {
        [hostView removeFromSuperview];
    } @catch (__unused NSException *exception) {
    }
    self.floatingKeyboardLayerHostView = nil;
    self.floatingKeyboardOriginalSuperview = nil;
    self.floatingKeyboardOriginalSubviewIndex = NSNotFound;
    self.floatingKeyboardHostSessionGeneration = 0;
    self.floatingKeyboardDeferredHostView = nil;
    self.floatingKeyboardDeferredScene = nil;
    self.floatingKeyboardDeferredSessionGeneration = 0;
    [self deactivateKeyboardForwardingWindow];
    FLMEnqueueDiagnosticLine(@"sb host-discard host=%p",
                             (__bridge void *)hostView);
}

- (BOOL)floatingApplicationHostReadyForKeyboardRoute {
    if (self.floatingWindow.hidden || self.floatingDocked ||
        self.floatingKeyboardSessionGeneration == 0 ||
        !self.floatingIdentifier.length || !self.floatingScene ||
        !self.floatingHostView ||
        self.floatingLaunchState != FLMFloatingLaunchStateAttached) {
        return NO;
    }
    if (self.floatingInteractiveFullscreenTransition) {
        return YES;
    }
    if (self.floatingSceneCardGeometryPending) {
        return NO;
    }
    if (self.floatingSceneUsesCardGeometry &&
        !self.floatingSceneCardGeometryCommitted) {
        return NO;
    }
    return YES;
}

- (void)flushDeferredFloatingKeyboardHostIfReady {
    UIView *deferredHost = self.floatingKeyboardDeferredHostView;
    NSUInteger deferredSession =
        self.floatingKeyboardDeferredSessionGeneration;
    id deferredScene = self.floatingKeyboardDeferredScene;
    if (!deferredHost) {
        self.floatingKeyboardDeferredScene = nil;
        self.floatingKeyboardDeferredSessionGeneration = 0;
        return;
    }
    if (deferredSession == 0 ||
        deferredSession != self.floatingKeyboardSessionGeneration) {
        FLMEnqueueDiagnosticLine(
            @"sb host-deferred discard=stale pendingSession=%lu current=%lu host=%p",
            (unsigned long)deferredSession,
            (unsigned long)self.floatingKeyboardSessionGeneration,
            (__bridge void *)deferredHost);
        self.floatingKeyboardDeferredHostView = nil;
        self.floatingKeyboardDeferredScene = nil;
        self.floatingKeyboardDeferredSessionGeneration = 0;
        return;
    }
    if (![self floatingApplicationHostReadyForKeyboardRoute]) {
        return;
    }
    self.floatingKeyboardDeferredHostView = nil;
    self.floatingKeyboardDeferredScene = nil;
    self.floatingKeyboardDeferredSessionGeneration = 0;
    FLMEnqueueDiagnosticLine(
        @"sb host-deferred replay=1 session=%lu host=%p scene=%@",
        (unsigned long)deferredSession, (__bridge void *)deferredHost,
        FLMSceneIdentifier(deferredScene) ?: @"<none>");
    [self keyboardLayerHostView:deferredHost
              didUpdateForScene:deferredScene
              sessionGeneration:deferredSession];
}

- (BOOL)floatingKeyboardPresentationReady {
    if (![self floatingApplicationHostReadyForKeyboardRoute] ||
        !self.floatingKeyboardLayerHostView ||
        self.floatingKeyboardHostSessionGeneration !=
            self.floatingKeyboardSessionGeneration) {
        return NO;
    }
    return YES;
}

- (void)flushPendingFloatingKeyboardFrameIfReady {
    if (!self.floatingKeyboardFramePending) {
        return;
    }
    NSUInteger pendingSession = self.floatingKeyboardPendingSessionGeneration;
    if (pendingSession == 0 ||
        pendingSession != self.floatingKeyboardSessionGeneration) {
        FLMEnqueueDiagnosticLine(
            @"sb frame-deferred discard=stale pendingSession=%lu current=%lu",
            (unsigned long)pendingSession,
            (unsigned long)self.floatingKeyboardSessionGeneration);
        self.floatingKeyboardFramePending = NO;
        self.floatingKeyboardPendingFrame = CGRectNull;
        self.floatingKeyboardPendingSessionGeneration = 0;
        return;
    }
    if (![self floatingKeyboardPresentationReady]) {
        return;
    }
    CGRect pendingFrame = self.floatingKeyboardPendingFrame;
    self.floatingKeyboardFramePending = NO;
    self.floatingKeyboardPendingFrame = CGRectNull;
    self.floatingKeyboardPendingSessionGeneration = 0;
    FLMEnqueueDiagnosticLine(
        @"sb frame-deferred replay=1 session=%lu frame=%@ host=%p contentViewportCommitted=%d",
        (unsigned long)pendingSession, NSStringFromCGRect(pendingFrame),
        (__bridge void *)self.floatingKeyboardLayerHostView,
        self.floatingSceneCardGeometryCommitted);
    [self applyKeyboardFrame:pendingFrame visible:YES];
}

- (void)applyKeyboardFrame:(CGRect)frame visible:(BOOL)visible {
    if (self.floatingDocked || self.floatingDockTransitionActive ||
        self.floatingKeyboardPresentationSuspendedForDock) {
        FLMEnqueueDiagnosticLine(
            @"sb frame-apply ignored=dock-presentation visible=%d docked=%d transition=%d session=%lu",
            visible,
            self.floatingDocked,
            self.floatingDockTransitionActive,
            (unsigned long)self.floatingKeyboardSessionGeneration);
        return;
    }
    if (self.floatingWindow.hidden || self.floatingDocked) {
        visible = NO;
    }
    if (visible &&
        (self.floatingKeyboardSessionGeneration == 0 ||
         !self.floatingScene)) {
        FLMEnqueueDiagnosticLine(
            @"sb frame-apply rejected=inactive-session session=%lu scene=%@ frame=%@",
            (unsigned long)self.floatingKeyboardSessionGeneration,
            FLMSceneIdentifier(self.floatingScene) ?: @"<none>",
            NSStringFromCGRect(frame));
        return;
    }
    if (visible && ![self floatingKeyboardPresentationReady]) {
        self.floatingKeyboardFramePending = YES;
        self.floatingKeyboardPendingFrame = frame;
        self.floatingKeyboardPendingSessionGeneration =
            self.floatingKeyboardSessionGeneration;
        FLMEnqueueDiagnosticLine(
            @"sb frame-deferred waiting=scene-host session=%lu frame=%@ appHost=%p keyboardHost=%p contentViewportPending=%d contentViewportCommitted=%d launch=%lu",
            (unsigned long)self.floatingKeyboardSessionGeneration,
            NSStringFromCGRect(frame), (__bridge void *)self.floatingHostView,
            (__bridge void *)self.floatingKeyboardLayerHostView,
            self.floatingSceneCardGeometryPending,
            self.floatingSceneCardGeometryCommitted,
            (unsigned long)self.floatingLaunchState);
        return;
    }
    if (!visible && !self.floatingKeyboardVisible &&
        !self.floatingKeyboardInteractionSessionActive &&
        ![self floatingKeyboardPresentationReady]) {
        if (self.floatingKeyboardFramePending) {
            FLMEnqueueDiagnosticLine(
                @"sb frame-deferred hide=1 pendingSession=%lu current=%lu",
                (unsigned long)self.floatingKeyboardPendingSessionGeneration,
                (unsigned long)self.floatingKeyboardSessionGeneration);
        }
        self.floatingKeyboardFramePending = NO;
        self.floatingKeyboardPendingFrame = CGRectNull;
        self.floatingKeyboardPendingSessionGeneration = 0;
        return;
    }
    if (!visible && ![self floatingKeyboardPresentationReady] &&
        !self.floatingKeyboardVisible) {
        self.floatingKeyboardFramePending = NO;
        self.floatingKeyboardPendingFrame = CGRectNull;
        self.floatingKeyboardPendingSessionGeneration = 0;
        return;
    }
    CGRect bounds = self.floatingWindow.rootViewController.view.bounds;
    FLMEnqueueDiagnosticLine(
        @"sb frame-apply inputVisible=%d inputFrame=%@ cardHidden=%d docked=%d session=%lu host=%p",
        visible, NSStringFromCGRect(frame), self.floatingWindow.hidden,
        self.floatingDocked,
        (unsigned long)self.floatingKeyboardSessionGeneration,
        (__bridge void *)self.floatingKeyboardLayerHostView);
    if (visible) {
        pid_t adapterPID = 0;
        BOOL sameHandshake =
            self.floatingKeyboardAdapterHandshakeAttempted &&
            self.floatingKeyboardAdapterHandshakeSessionGeneration ==
                self.floatingKeyboardSessionGeneration &&
            [self.floatingKeyboardAdapterHandshakeIdentifier
                isEqualToString:self.floatingIdentifier];
        BOOL adapterAccepted = self.floatingKeyboardAdapterHandshakeValid;
        if (!sameHandshake) {
            adapterAccepted = FLMKeyboardAppAdapterReadyForIdentifier(
                self.floatingIdentifier, &adapterPID);
            self.floatingKeyboardAdapterHandshakeAttempted = YES;
            self.floatingKeyboardAdapterHandshakeValid = adapterAccepted;
            self.floatingKeyboardAdapterHandshakePID = adapterPID;
            self.floatingKeyboardAdapterHandshakeIdentifier =
                [self.floatingIdentifier copy];
            self.floatingKeyboardAdapterHandshakeSessionGeneration =
                self.floatingKeyboardSessionGeneration;
        } else {
            adapterPID = self.floatingKeyboardAdapterHandshakePID;
        }
        FLMEnqueueDiagnosticLine(
            @"sb keyboard-relation target=%@ frontmost=%@ appScene=%@ appSceneClass=%@ keyboardScene=%@ keyboardSceneClass=%@ preferredHostClass=%@ preferredHost=%p nativeHostClass=%@ nativeHost=%p adapterAccepted=%d adapterPID=%d sbPID=%d",
            self.floatingIdentifier ?: @"<none>",
            FLMFrontmostApplicationIdentifier() ?: @"<none>",
            FLMSceneIdentifier(self.floatingScene) ?: @"<none>",
            self.floatingScene
                ? NSStringFromClass([self.floatingScene class])
                : @"<none>",
            FLMSceneIdentifier(self.floatingKeyboardScene) ?: @"<none>",
            self.floatingKeyboardScene
                ? NSStringFromClass([self.floatingKeyboardScene class])
                : @"<none>",
            self.floatingKeyboardPreferredHostIdentity
                ? NSStringFromClass(
                      [self.floatingKeyboardPreferredHostIdentity class])
                : @"<none>",
            (__bridge void *)self.floatingKeyboardPreferredHostIdentity,
            self.floatingKeyboardLayerHostView
                ? NSStringFromClass([self.floatingKeyboardLayerHostView class])
                : @"<none>",
            (__bridge void *)self.floatingKeyboardLayerHostView,
            adapterAccepted, adapterPID, getpid());
        [self beginFloatingKeyboardInteractionSession];
        CGRect visibleFrame = CGRectIntersection(bounds, frame);
        CGFloat reportedHeight = CGRectIsNull(visibleFrame)
                                    ? 0.0
                                    : CGRectGetHeight(visibleFrame);
        if (reportedHeight <= 1.0) {
            FLMEnqueueDiagnosticLine(
                @"sb frame-apply rejected=empty-visible-frame rawFrame=%@ bounds=%@",
                NSStringFromCGRect(frame), NSStringFromCGRect(bounds));
            [self applyKeyboardFrame:CGRectNull visible:NO];
            return;
        }
        self.lastPortraitKeyboardHeight = reportedHeight;
        self.floatingKeyboardMaximumVisibleHeight = reportedHeight;
        CGFloat height = MIN(CGRectGetHeight(bounds), reportedHeight);
        frame = CGRectMake(CGRectGetMinX(bounds),
                           CGRectGetMaxY(bounds) - height,
                           CGRectGetWidth(bounds),
                           height);
        BOOL repeatedFrame =
            self.floatingKeyboardLastPublishedFrameValid &&
            self.floatingKeyboardLastPublishedVisible &&
            self.floatingKeyboardLastPublishedSessionGeneration ==
                self.floatingKeyboardSessionGeneration &&
            CGRectEqualToRect(self.floatingKeyboardLastPublishedFrame, frame);
        self.floatingKeyboardVisible = YES;
        self.floatingKeyboardFrame = frame;
        if (repeatedFrame) {
            return;
        }
        self.floatingKeyboardLastPublishedFrame = frame;
        self.floatingKeyboardLastPublishedFrameValid = YES;
        self.floatingKeyboardLastPublishedVisible = YES;
        self.floatingKeyboardLastPublishedSessionGeneration =
            self.floatingKeyboardSessionGeneration;
        CGRect interactionFrame = [self floatingKeyboardInteractionFrame];
        self.floatingBackdropTap.additionalProtectedFrame = interactionFrame;
        ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame =
            interactionFrame;
        self.keyboardForwardingWindow.windowLevel =
            self.floatingWindow.windowLevel + 1.0;
        self.keyboardForwardingWindow.keyboardInteractionFrame = interactionFrame;
        CGFloat avoidanceHeight =
            [self floatingKeyboardAvoidanceHeightForFrame:interactionFrame];
        // The application Scene frame remains immutable.  UIKit in the target
        // application consumes this logical overlap through
        // _UIRemoteKeyboards and performs its own responder avoidance.
        FLMPublishKeyboardAvoidance(self.floatingKeyboardSessionGeneration,
                                    avoidanceHeight,
                                    YES);
        if (self.floatingKeyboardLayerHostView) {
            [self.keyboardForwardingWindow makeKeyAndVisible];
        }
        FLMEnqueueDiagnosticLine(
            @"sb frame-visible reportedHeight=%.2f stableHeight=%.2f normalized=%@ interaction=%@ avoidance=%.2f forwardingKey=%d level=%.1f cardLevel=%.1f",
            reportedHeight, height,
            NSStringFromCGRect(frame), NSStringFromCGRect(interactionFrame),
            avoidanceHeight,
            self.keyboardForwardingWindow.isKeyWindow,
            self.keyboardForwardingWindow.windowLevel,
            self.floatingWindow.windowLevel);
        return;
    }
    BOOL wasKeyboardInteraction =
        self.floatingKeyboardVisible || self.floatingKeyboardInteractionSessionActive;
    BOOL coordinatedSettlement =
        self.floatingKeyboardDismissCloseToken != 0 &&
        self.floatingKeyboardDismissCloseToken == self.floatingActiveCloseToken &&
        self.floatingKeyboardCloseState ==
            FLMFloatingKeyboardCloseStateAwaitingKeyboardSettlement &&
        self.floatingKeyboardAppDismissClaimed;
    if (coordinatedSettlement) {
        self.floatingKeyboardSettlementFrameHidden = YES;
        FLMEnqueueDiagnosticLine(
            @"sb keyboard-settlement frame-hidden closeToken=%lu session=%lu requestGeneration=%lu",
            (unsigned long)self.floatingKeyboardDismissCloseToken,
            (unsigned long)self.floatingKeyboardDismissSessionGeneration,
            (unsigned long)self.floatingKeyboardDismissRequestGeneration);
    }
    if (!wasKeyboardInteraction && !coordinatedSettlement) {
        return;
    }
    self.floatingKeyboardVisible = NO;
    self.floatingKeyboardFrame = CGRectNull;
    self.floatingKeyboardLastPublishedFrameValid = NO;
    self.floatingKeyboardLastPublishedVisible = NO;
    [self deactivateKeyboardForwardingWindow];
    FLMPublishKeyboardAvoidance(self.floatingKeyboardSessionGeneration,
                                0.0,
                                NO);
    // Closing behavior is tied to the touch's immutable begin-domain snapshot,
    // not a guessed post-dismissal time window. A touch that began in the
    // keyboard remains a keyboard-only touch even after this state is cleared;
    // the next genuine outside touch is immediately eligible to close.
    self.floatingBackdropTap.additionalProtectedFrame = CGRectNull;
    ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame =
        CGRectNull;
    [self endFloatingKeyboardInteractionSession];
    FLMEnqueueDiagnosticLine(
        @"sb frame-hidden protection=cleared policy=touch-origin centered-preserved=%d previousInteraction=%d session=%lu hidden=%d docked=%d",
        !self.floatingWindow.hidden && !self.floatingDocked,
        wasKeyboardInteraction,
        (unsigned long)self.floatingKeyboardSessionGeneration,
        self.floatingWindow.hidden, self.floatingDocked);
    if (coordinatedSettlement) {
        [self handleKeyboardSettlementForCloseToken:
                  self.floatingKeyboardDismissCloseToken];
    }
}

- (void)suspendFloatingKeyboardPresentationForDockMode {
    if (self.floatingKeyboardSessionGeneration == 0) {
        return;
    }
    // Docking changes presentation only. Stop the visible keyboard surface
    // and avoidance, but retain the same route/session/Scene/presenter/host so
    // returning to the centered card cannot create a new app transaction.
    self.floatingKeyboardVisible = NO;
    self.floatingKeyboardFrame = CGRectNull;
    self.floatingKeyboardMaximumVisibleHeight = 0.0;
    self.floatingKeyboardLastPublishedFrameValid = NO;
    self.floatingKeyboardLastPublishedVisible = NO;
    [self deactivateKeyboardForwardingWindow];
    self.floatingKeyboardPresentationSuspendedForDock = YES;
    self.floatingKeyboardAvoidancePublishDeferred = YES;
    self.floatingBackdropTap.additionalProtectedFrame = CGRectNull;
    ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame =
        CGRectNull;
    [self endFloatingKeyboardInteractionSession];
    FLMEnqueueDiagnosticLine(
        @"sb dock-keyboard presentation-suspended session=%lu route-kept=1 scene-kept=1 presenter-kept=1 host-kept=1",
        (unsigned long)self.floatingKeyboardSessionGeneration);
}

- (void)flushFloatingKeyboardAvoidancePublishAfterDock {
    if (!self.floatingKeyboardAvoidancePublishDeferred ||
        self.floatingKeyboardSessionGeneration == 0) {
        self.floatingKeyboardPresentationSuspendedForDock = NO;
        return;
    }
    self.floatingKeyboardAvoidancePublishDeferred = NO;
    self.floatingKeyboardPresentationSuspendedForDock = NO;
    FLMPublishKeyboardAvoidance(self.floatingKeyboardSessionGeneration,
                                0.0,
                                NO);
    FLMEnqueueDiagnosticLine(
        @"sb dock-keyboard avoidance-clear deferred=1 session=%lu after=Centered",
        (unsigned long)self.floatingKeyboardSessionGeneration);
}

- (void)endFloatingKeyboardSession {
    NSUInteger endingSession = self.floatingKeyboardSessionGeneration;
    UIView *endingHost = self.floatingKeyboardLayerHostView;
    FLMEnqueueDiagnosticLine(
        @"sb session-end begin session=%lu visible=%d interaction=%d host=%p app=%@ scene=%@",
        (unsigned long)endingSession, self.floatingKeyboardVisible,
        self.floatingKeyboardInteractionSessionActive,
        (__bridge void *)self.floatingKeyboardLayerHostView,
        self.floatingIdentifier ?: @"<none>",
        FLMSceneIdentifier(self.floatingScene) ?: @"<none>");
    self.floatingKeyboardFramePending = NO;
    self.floatingKeyboardPendingFrame = CGRectNull;
    self.floatingKeyboardPendingSessionGeneration = 0;
    self.floatingKeyboardDeferredHostView = nil;
    self.floatingKeyboardDeferredScene = nil;
    self.floatingKeyboardDeferredSessionGeneration = 0;
    if (endingSession == 0) {
        [self deactivateKeyboardForwardingWindow];
        [self endFloatingKeyboardInteractionSession];
        self.floatingKeyboardMaximumVisibleHeight = 0.0;
        [self invalidateSessionCanonicalGeometry];
        return;
    }
    [self.floatingHostView endEditing:YES];
    FLMPublishKeyboardAvoidance(endingSession, 0.0, NO);
    FLMPublishKeyboardCardGeometry(endingSession, 0.0, 0.0, 0.0, 0.0, NO);
    [self clearFloatingKeyboardScenePairingForSession:endingSession];
    self.floatingKeyboardSessionGeneration = 0;
    [self invalidateSessionCanonicalGeometry];
    FLMPublishKeyboardState(nil, nil, 0);
    self.floatingKeyboardVisible = NO;
    self.floatingKeyboardFrame = CGRectNull;
    self.floatingKeyboardMaximumVisibleHeight = 0.0;
    self.floatingBackdropTap.additionalProtectedFrame = CGRectNull;
    ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame =
        CGRectNull;
    [self deactivateKeyboardForwardingWindow];
    [self endFloatingKeyboardInteractionSession];
    FLMEnqueueDiagnosticLine(
        @"sb session-end route-cleared session=%lu host=%p",
        (unsigned long)endingSession, (__bridge void *)endingHost);

    // The keyboard Scene's preferred host identity was cleared above. Keep the
    // native host hidden for one UIKit transaction so a third-party keyboard
    // can finish that unpair before its remote surface is discarded.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.24 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.floatingKeyboardSessionGeneration == 0 && endingHost &&
            self.floatingKeyboardLayerHostView == endingHost &&
            self.floatingKeyboardHostSessionGeneration == endingSession) {
            FLMEnqueueDiagnosticLine(
                @"sb session-end host-discard session=%lu host=%p",
                (unsigned long)endingSession, (__bridge void *)endingHost);
            [self discardFloatingKeyboardLayerHost];
        }
    });
}

- (CGRect)floatingKeyboardInteractionFrame {
    if (!self.floatingKeyboardInteractionSessionActive ||
        !self.floatingKeyboardVisible ||
        CGRectIsNull(self.floatingKeyboardFrame) ||
        CGRectGetWidth(self.floatingKeyboardFrame) <= 1.0 ||
        CGRectGetHeight(self.floatingKeyboardFrame) <= 1.0) {
        return CGRectNull;
    }
    CGRect bounds = self.floatingWindow.rootViewController.view.bounds;
    CGRect keyboardFrame = CGRectIntersection(bounds, self.floatingKeyboardFrame);
    if (CGRectIsNull(keyboardFrame) || CGRectGetHeight(keyboardFrame) <= 1.0) {
        return CGRectNull;
    }
    // The slop only covers rounding/retargeting at the real frame edge. It is
    // never a guessed keyboard-height fallback and never owns the backdrop's
    // unrelated lower-screen points.
    CGFloat slop = MIN(8.0, MAX(4.0, FLMKeyboardHitTestSlop));
    CGRect protectedFrame = CGRectInset(keyboardFrame, -slop, -slop);
    return CGRectIntersection(bounds, protectedFrame);
}

- (BOOL)pointIsInsideFloatingInteractionDomain:(CGPoint)point {
    BOOL centeredInteraction =
        !self.floatingDocked && !self.floatingDockHidden &&
        !self.floatingDockTransitionActive &&
        !self.floatingDockInputSessionActive &&
        !self.floatingDockContentTailProtected;
    CGRect contentFrame = centeredInteraction &&
                                  [self ensureSessionCanonicalGeometry]
                              ? self.sessionCanonicalGeometry.centeredFrame
                              : [self floatingContainerPresentationFrame];
    contentFrame = CGRectInset(contentFrame, -2.0, -2.0);
    CGRect handleFrame = CGRectInset(self.floatingHandle.frame, -22.0, -20.0);
    if (CGRectContainsPoint(contentFrame, point) ||
        (!self.floatingHandle.hidden && CGRectContainsPoint(handleFrame, point))) {
        return YES;
    }
    CGRect keyboardFrame = [self floatingKeyboardInteractionFrame];
    return !CGRectIsNull(keyboardFrame) &&
           CGRectContainsPoint(keyboardFrame, point);
}

- (CGFloat)floatingKeyboardAvoidanceHeightForFrame:(CGRect)frame {
    if (CGRectIsNull(frame) || CGRectGetHeight(frame) <= 1.0) {
        return 0.0;
    }
    BOOL centeredInteraction =
        !self.floatingDocked && !self.floatingDockHidden &&
        !self.floatingDockTransitionActive &&
        !self.floatingDockInputSessionActive &&
        !self.floatingDockContentTailProtected;
    CGRect contentFrame = centeredInteraction &&
                                  [self ensureSessionCanonicalGeometry]
                              ? self.sessionCanonicalGeometry.centeredFrame
                              : [self floatingContainerPresentationFrame];
    CGFloat physicalOverlap =
        MAX(0.0, CGRectGetMaxY(contentFrame) - CGRectGetMinY(frame));
    if (physicalOverlap <= 1.0) {
        return 0.0;
    }
    CGAffineTransform transform = self.floatingHostView.transform;
    // Keyboard avoidance is vertical geometry. With an independent X/Y card
    // mapping, use the transform's Y scale rather than applying the
    // horizontal scale to vertical input movement.
    CGFloat visualScale = hypot(transform.b, transform.d);
    if (visualScale <= 0.05) {
        CGSize referenceSize = [self floatingSceneReferenceSize];
        visualScale = referenceSize.width > 1.0
                          ? CGRectGetHeight(contentFrame) / referenceSize.height
                          : 1.0;
    }
    visualScale = MAX(0.05, visualScale);
    CGSize referenceSize = [self floatingSceneReferenceSize];
    CGFloat logicalGap = 8.0 / visualScale;
    CGFloat logicalAvoidance = physicalOverlap / visualScale + logicalGap;
    return referenceSize.height > 1.0
               ? MIN(referenceSize.height * 0.72, logicalAvoidance)
               : logicalAvoidance;
}

- (void)beginFloatingKeyboardInteractionSession {
    if (self.floatingWindow.hidden || self.floatingDocked) {
        return;
    }
    if (self.floatingKeyboardInteractionSessionActive) {
        self.floatingBackdropTap.additionalProtectedFrame =
            [self floatingKeyboardInteractionFrame];
        return;
    }
    self.floatingKeyboardInteractionSessionActive = YES;
    self.floatingKeyboardInteractionGeneration += 1;
    NSUInteger generation = self.floatingKeyboardInteractionGeneration;
    CGRect protectedFrame = [self floatingKeyboardInteractionFrame];
    self.floatingBackdropTap.additionalProtectedFrame = protectedFrame;

    // A responder can fail to present a keyboard. Do not leave the lower screen
    // permanently protected if no keyboard frame arrives for this session.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation == self.floatingKeyboardInteractionGeneration &&
            self.floatingKeyboardInteractionSessionActive &&
            !self.floatingKeyboardVisible) {
            [self applyKeyboardFrame:CGRectNull visible:NO];
        }
    });
}

- (void)endFloatingKeyboardInteractionSession {
    self.floatingKeyboardInteractionGeneration += 1;
    self.floatingKeyboardInteractionSessionActive = NO;
}

- (void)handleApplicationDismissAck:(int)token {
    if (token < 0) {
        return;
    }
    uint64_t ackState = 0;
    FLMKeyboardDismissAckPhase ackPhase = FLMKeyboardDismissAckPhaseNone;
    uint64_t ackSession = 0;
    uint64_t ackGeneration = 0;
    pid_t ackPID = 0;
    FLMKeyboardDismissResult ackResult = FLMKeyboardDismissResultNone;
    BOOL sharedAck = token == FlymeKeyboardSharedStateToken;
    if (sharedAck) {
        FLMKeyboardCloseContext *context = self.floatingKeyboardCloseContext;
        NSDictionary *sharedState = FLMReadKeyboardSharedStateSnapshot();
        ackGeneration =
            [sharedState[@"dismissAckGeneration"] unsignedLongLongValue];
        ackSession =
            [sharedState[@"dismissAckSession"] unsignedLongLongValue];
        ackPID = (pid_t)[sharedState[@"dismissAckPID"] intValue];
        ackPhase = (FLMKeyboardDismissAckPhase)
            [sharedState[@"dismissAckPhase"] unsignedIntValue];
        ackResult =
            (FLMKeyboardDismissResult)[sharedState[@"dismissAckResult"] unsignedIntValue];
        if (!context || ackGeneration == 0 || ackSession == 0 || ackPID <= 1 ||
            ackGeneration != context.requestGeneration ||
            ackSession != context.sessionGeneration ||
            ackPhase == FLMKeyboardDismissAckPhaseNone) {
            return;
        }
        // Keep the SpringBoard-side next snapshot from replacing a valid app
        // ACK with the pre-ACK values that were captured before this notify.
        FLMKeyboardSharedDismissAckGeneration = ackGeneration;
        FLMKeyboardSharedDismissAckSession = ackSession;
        FLMKeyboardSharedDismissAckPID = ackPID;
        FLMKeyboardSharedDismissAckPhase = ackPhase;
        FLMKeyboardSharedDismissAckResult = ackResult;
        ackState = FLMPackKeyboardDismissAckState(
            ackSession, ackGeneration, ackPID, ackResult);
    } else if (notify_get_state(token, &ackState) != NOTIFY_STATUS_OK ||
               ackState == 0) {
        return;
    } else {
        ackPhase = FLMKeyboardDismissAckPhaseActionComplete;
        ackResult =
            (FLMKeyboardDismissResult)((ackState >> 56) & 0xFFULL);
        ackSession = (ackState >> 32) & 0xFFFFFFULL;
        ackGeneration = (ackState >> 16) & 0xFFFFULL;
        ackPID = (pid_t)(ackState & 0xFFFFULL);
    }
    FLMKeyboardDismissResult result = ackResult;
    uint64_t sessionGeneration = ackSession;
    NSUInteger requestGeneration = (NSUInteger)ackGeneration;
    pid_t adapterPID = ackPID;
    FLMKeyboardCloseContext *context = self.floatingKeyboardCloseContext;
    BOOL contextMatches = context &&
                          ((sharedAck &&
                            ackSession == context.sessionGeneration &&
                            ackGeneration == context.requestGeneration &&
                            ackPID == context.adapterPID) ||
                           (!sharedAck &&
                            ackSession == (context.sessionGeneration & 0xFFFFFFULL) &&
                            ackGeneration == (context.requestGeneration & 0xFFFFULL) &&
                            (context.adapterPID <= 1 ||
                             ackPID == (context.adapterPID & 0xFFFF))));
    BOOL currentTransaction =
        self.floatingCloseInProgress &&
        (self.floatingKeyboardCloseState ==
             FLMFloatingKeyboardCloseStateAwaitingAppClaim ||
         self.floatingKeyboardCloseState ==
             FLMFloatingKeyboardCloseStateAwaitingKeyboardSettlement) &&
        context != nil && context.closeToken == self.floatingActiveCloseToken &&
        context.closeToken == self.floatingKeyboardDismissCloseToken &&
        contextMatches;
    if (!currentTransaction) {
        if (self.floatingKeyboardCloseState ==
                FLMFloatingKeyboardCloseStateAborted &&
            contextMatches &&
            ackPhase == FLMKeyboardDismissAckPhaseClaimed &&
            [self.floatingKeyboardCloseAbortReason
                isEqualToString:@"keyboard-hidden-without-app-claim"]) {
            FLMEnqueueDiagnosticLine(
                @"sb dismiss-claim ignored=late-after-manual-hide closeToken=%lu session=%llu requestGeneration=%llu pid=%d",
                (unsigned long)context.closeToken,
                (unsigned long long)ackSession,
                (unsigned long long)ackGeneration,
                ackPID);
            return;
        }
        FLMEnqueueDiagnosticLine(
            @"sb dismiss-ack ignored=stale state=0x%016llx phase=%u result=%@ session=%llu requestGeneration=%llu pid=%d activeClose=%lu state=%@ expectedSession=%lu expectedRequest=%lu expectedPID=%d",
            (unsigned long long)ackState,
            (unsigned)ackPhase,
            FLMKeyboardDismissResultName(result),
            (unsigned long long)sessionGeneration,
            (unsigned long long)requestGeneration,
            adapterPID,
            (unsigned long)self.floatingActiveCloseToken,
            FLMFloatingKeyboardCloseStateName(self.floatingKeyboardCloseState),
            (unsigned long)(context ? context.sessionGeneration : 0),
            (unsigned long)(context ? context.requestGeneration : 0),
            context ? context.adapterPID : 0);
        return;
    }

    if (ackPhase < FLMKeyboardDismissAckPhaseClaimed) {
        return;
    }
    if (ackPhase <= self.floatingKeyboardDismissAckPhase) {
        FLMEnqueueDiagnosticLine(
            @"sb dismiss-ack ignored=duplicate phase=%u closeToken=%lu session=%llu requestGeneration=%llu",
            (unsigned)ackPhase,
            (unsigned long)context.closeToken,
            (unsigned long long)ackSession,
            (unsigned long long)ackGeneration);
        return;
    }

    BOOL newlyClaimed = !self.floatingKeyboardAppDismissClaimed;
    self.floatingKeyboardAppDismissClaimed = YES;
    self.floatingKeyboardDismissAckPhase = ackPhase;
    if (ackPhase == FLMKeyboardDismissAckPhaseActionComplete) {
        self.floatingKeyboardAppResponderActionStarted = YES;
    }
    self.floatingKeyboardCloseState =
        FLMFloatingKeyboardCloseStateAwaitingKeyboardSettlement;
    if (ackPhase == FLMKeyboardDismissAckPhaseClaimed) {
        FLMEnqueueDiagnosticLine(
            @"sb dismiss-claim received closeToken=%lu session=%llu requestGeneration=%llu pid=%d phase=claimed appDismissClaimed=1 state=%@",
            (unsigned long)context.closeToken,
            (unsigned long long)ackSession,
            (unsigned long long)ackGeneration,
            ackPID,
            FLMFloatingKeyboardCloseStateName(
                self.floatingKeyboardCloseState));
        if (newlyClaimed) {
            [self scheduleKeyboardSettlementTimeoutForContext:context];
        }
        [self handleKeyboardSettlementForCloseToken:context.closeToken];
        return;
    }

    FLMEnqueueDiagnosticLine(
        @"sb dismiss-ack phase=complete app=%@ bundleHash=0x%016llx scene=%@ sceneHash=0x%016llx session=%llu sessionGeneration=%lu requestGeneration=%llu adapterPID=%d result=%@ state=0x%016llx",
        context.identifier ?: @"<none>",
        (unsigned long long)context.bundleHash,
        FLMSceneIdentifier(context.scene) ?: @"<none>",
        (unsigned long long)context.sceneHash,
        (unsigned long long)context.session,
        (unsigned long)context.sessionGeneration,
        (unsigned long long)requestGeneration,
        adapterPID,
        FLMKeyboardDismissResultName(result),
        (unsigned long long)ackState);
    BOOL terminalFailure =
        result == FLMKeyboardDismissResultStaleGeneration ||
        result == FLMKeyboardDismissResultWrongProcess;
    if (terminalFailure) {
        [self abortCoordinatedCloseForToken:
                  context.closeToken
                  reason:[NSString stringWithFormat:@"ack-%@",
                                                    FLMKeyboardDismissResultName(result)]];
        return;
    }
    if (result == FLMKeyboardDismissResultFailed) {
        // A normal cleanup failure is informational.  The keyboard's hidden
        // frame or the settlement timeout owns settlement; this ACK must
        // never cancel the single CloseIntent or make the next click allocate
        // N+1.
        FLMEnqueueDiagnosticLine(
            @"sb dismiss-ack accepted=0 nonexclusive-failure=1 closeToken=%lu result=failed frameHidden=%d",
            (unsigned long)context.closeToken,
            self.floatingKeyboardSettlementFrameHidden);
    }
    self.floatingKeyboardDismissResult = result;
    self.floatingKeyboardCloseState =
        FLMFloatingKeyboardCloseStateAwaitingKeyboardSettlement;
    FLMEnqueueDiagnosticLine(
        @"sb dismiss-ack accepted=%d closeToken=%lu session=%lu sessionGeneration=%lu requestGeneration=%llu result=%@ phase=%u frameHidden=%d didHide=%d state=%@",
        result != FLMKeyboardDismissResultFailed,
        (unsigned long)context.closeToken,
        (unsigned long)context.session,
        (unsigned long)sessionGeneration,
        (unsigned long long)context.requestGeneration,
        FLMKeyboardDismissResultName(result),
        (unsigned)ackPhase,
        self.floatingKeyboardSettlementFrameHidden,
        self.floatingKeyboardSettlementDidHide,
        FLMFloatingKeyboardCloseStateName(self.floatingKeyboardCloseState));
    if (newlyClaimed) {
        [self scheduleKeyboardSettlementTimeoutForContext:context];
    }
    [self handleKeyboardSettlementForCloseToken:
              context.closeToken];
}

- (void)handleKeyboardSharedStateUpdate {
    if (FlymeKeyboardSharedStateToken >= 0) {
        [self handleApplicationDismissAck:FlymeKeyboardSharedStateToken];
    }
}

- (void)beginKeyboardCoordinatedCloseWithToken:(NSUInteger)closeToken {
    if (!self.floatingCloseInProgress ||
        closeToken != self.floatingActiveCloseToken) {
        return;
    }
    NSString *identifier = [self.floatingIdentifier copy];
    id scene = self.floatingScene;
    uint64_t sessionGeneration = self.floatingKeyboardSessionGeneration;
    if (!self.floatingCloseKeepApplication || identifier.length == 0 ||
        !scene || sessionGeneration == 0 || self.floatingWindow.hidden ||
        self.floatingDocked) {
        [self abortCoordinatedCloseForToken:closeToken
                                     reason:@"invalid-session"];
        return;
    }
    pid_t adapterPID = 0;
    BOOL sameHandshake =
        self.floatingKeyboardAdapterHandshakeAttempted &&
        self.floatingKeyboardAdapterHandshakeSessionGeneration ==
            sessionGeneration &&
        [self.floatingKeyboardAdapterHandshakeIdentifier
            isEqualToString:identifier];
    BOOL adapterAccepted = self.floatingKeyboardAdapterHandshakeValid;
    if (!sameHandshake) {
        adapterAccepted = FLMKeyboardAppAdapterReadyForIdentifier(
            identifier, &adapterPID);
        self.floatingKeyboardAdapterHandshakeAttempted = YES;
        self.floatingKeyboardAdapterHandshakeValid = adapterAccepted;
        self.floatingKeyboardAdapterHandshakePID = adapterPID;
        self.floatingKeyboardAdapterHandshakeIdentifier = [identifier copy];
        self.floatingKeyboardAdapterHandshakeSessionGeneration =
            sessionGeneration;
    } else {
        adapterPID = self.floatingKeyboardAdapterHandshakePID;
    }

    NSUInteger requestGeneration =
        ++self.floatingKeyboardDismissRequestGeneration;
    if (requestGeneration == 0) {
        requestGeneration = ++self.floatingKeyboardDismissRequestGeneration;
    }
    self.floatingKeyboardDismissSessionGeneration = sessionGeneration;
    self.floatingKeyboardDismissCloseToken = closeToken;
    self.floatingKeyboardDismissResult = FLMKeyboardDismissResultNone;
    self.floatingKeyboardDismissAckPhase = FLMKeyboardDismissAckPhaseNone;
    self.floatingKeyboardAppDismissClaimed = NO;
    self.floatingKeyboardAppResponderActionStarted = NO;
    self.floatingKeyboardCloseAbortReason = nil;
    self.floatingKeyboardSettlementFrameHidden = NO;
    self.floatingKeyboardSettlementDidHide = NO;
    self.floatingKeyboardDismissAdapterPID = adapterPID;
    self.floatingKeyboardCloseContext =
        [[FLMKeyboardCloseContext alloc]
            initWithIdentifier:identifier
                          scene:scene
                     bundleHash:FLMIdentifierHash(identifier)
                      sceneHash:FLMIdentifierHash(FLMSceneIdentifier(scene))
                        session:sessionGeneration
              sessionGeneration:sessionGeneration
              requestGeneration:requestGeneration
                     adapterPID:adapterPID
                     closeToken:closeToken];
    self.floatingKeyboardCloseState =
        FLMFloatingKeyboardCloseStateAwaitingAppClaim;
    // Disable only the close recognizer for this transaction. The card, Scene,
    // presenter, route, session and host remain live while the app resigns.
    self.floatingBackdropTap.enabled = NO;
    FLMEnqueueDiagnosticLine(
        @"sb close-intent begin state=AwaitingAppClaim closeToken=%lu app=%@ bundleHash=0x%016llx scene=%@ sceneHash=0x%016llx session=%llu sessionGeneration=%llu requestGeneration=%llu adapterPID=%d adapterAccepted=%d appDismissClaimed=0 appResponderActionStarted=0 card-kept=1 route-kept=1 presenter-kept=1 host-kept=1 context=immutable",
        (unsigned long)closeToken, identifier,
        (unsigned long long)FLMIdentifierHash(identifier),
        FLMSceneIdentifier(scene) ?: @"<none>",
        (unsigned long long)FLMIdentifierHash(FLMSceneIdentifier(scene)),
        (unsigned long long)sessionGeneration,
        (unsigned long long)sessionGeneration,
        (unsigned long long)requestGeneration, adapterPID, adapterAccepted);
    FLMKeyboardCloseContext *expectedContext =
        self.floatingKeyboardCloseContext;
    FLMPublishKeyboardDismissRequest(expectedContext);
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(FLMFloatingKeyboardAppClaimTimeout *
                                NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            if (!self.floatingCloseInProgress ||
                self.floatingActiveCloseToken != expectedContext.closeToken ||
                self.floatingKeyboardCloseContext != expectedContext ||
                self.floatingKeyboardDismissCloseToken !=
                    expectedContext.closeToken ||
                self.floatingKeyboardDismissSessionGeneration !=
                    expectedContext.sessionGeneration ||
                self.floatingKeyboardDismissRequestGeneration !=
                    expectedContext.requestGeneration ||
                self.floatingKeyboardCloseState !=
                    FLMFloatingKeyboardCloseStateAwaitingAppClaim) {
                return;
            }
            FLMEnqueueDiagnosticLine(
                @"sb close-intent abort=app-claim-timeout closeToken=%lu session=%llu requestGeneration=%llu card-kept=1 keyboard-kept=1",
                (unsigned long)expectedContext.closeToken,
                (unsigned long long)expectedContext.sessionGeneration,
                (unsigned long long)expectedContext.requestGeneration);
            [self abortCoordinatedCloseForToken:
                      expectedContext.closeToken
                      reason:@"app-claim-timeout"];
        });
}

- (void)scheduleKeyboardSettlementTimeoutForContext:(FLMKeyboardCloseContext *)context {
    if (!context) {
        return;
    }
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(FLMFloatingKeyboardSettlementTimeout *
                                NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            if (!self.floatingCloseInProgress ||
                self.floatingActiveCloseToken != context.closeToken ||
                self.floatingKeyboardCloseContext != context ||
                self.floatingKeyboardDismissCloseToken != context.closeToken ||
                self.floatingKeyboardDismissSessionGeneration !=
                    context.sessionGeneration ||
                self.floatingKeyboardDismissRequestGeneration !=
                    context.requestGeneration ||
                !self.floatingKeyboardAppDismissClaimed ||
                self.floatingKeyboardCloseState !=
                    FLMFloatingKeyboardCloseStateAwaitingKeyboardSettlement) {
                return;
            }
            if (self.floatingKeyboardSettlementFrameHidden ||
                !self.floatingKeyboardVisible) {
                self.floatingKeyboardSettlementFrameHidden = YES;
                FLMEnqueueDiagnosticLine(
                    @"sb keyboard-settlement timeout-recheck=hidden closeToken=%lu requestGeneration=%llu causal=app-claim",
                    (unsigned long)context.closeToken,
                    (unsigned long long)context.requestGeneration);
                [self handleKeyboardSettlementForCloseToken:context.closeToken];
                return;
            }
            [self abortCoordinatedCloseForToken:context.closeToken
                                         reason:@"keyboard-settlement-timeout"];
        });
}

- (void)handleKeyboardSettlementForCloseToken:(NSUInteger)closeToken {
    if (!self.floatingCloseInProgress ||
        closeToken != self.floatingActiveCloseToken ||
        self.floatingKeyboardDismissCloseToken != closeToken ||
        self.floatingKeyboardCloseState !=
            FLMFloatingKeyboardCloseStateAwaitingKeyboardSettlement ||
        !self.floatingKeyboardAppDismissClaimed ||
        !self.floatingKeyboardCloseContext ||
        self.floatingKeyboardCloseContext.closeToken != closeToken) {
        return;
    }
    FLMKeyboardCloseContext *context = self.floatingKeyboardCloseContext;
    if (!self.floatingKeyboardSettlementFrameHidden) {
        FLMEnqueueDiagnosticLine(
            @"sb keyboard-settlement waiting closeToken=%lu appDismissClaimed=%d ackPhase=%u frameHidden=%d didHide=%d",
            (unsigned long)closeToken,
            self.floatingKeyboardAppDismissClaimed,
            (unsigned)self.floatingKeyboardDismissAckPhase,
            self.floatingKeyboardSettlementFrameHidden,
            self.floatingKeyboardSettlementDidHide);
        return;
    }
    FLMEnqueueDiagnosticLine(
        @"sb keyboard-settlement ready closeToken=%lu requestGeneration=%llu hidden=1 causal=app-claim ackPhase=%u result=%@",
        (unsigned long)context.closeToken,
        (unsigned long long)context.requestGeneration,
        (unsigned)self.floatingKeyboardDismissAckPhase,
        FLMKeyboardDismissResultName(self.floatingKeyboardDismissResult));
    [self commitCoordinatedCloseForToken:closeToken];
}

- (void)commitCoordinatedCloseForToken:(NSUInteger)closeToken {
    if (!self.floatingCloseInProgress ||
        closeToken != self.floatingActiveCloseToken ||
        self.floatingKeyboardCloseState !=
            FLMFloatingKeyboardCloseStateAwaitingKeyboardSettlement ||
        !self.floatingKeyboardAppDismissClaimed ||
        !self.floatingKeyboardCloseContext ||
        self.floatingKeyboardCloseContext.closeToken != closeToken) {
        return;
    }
    if (!self.floatingKeyboardSettlementFrameHidden) {
        return;
    }
    FLMKeyboardCloseContext *context = self.floatingKeyboardCloseContext;
    self.floatingKeyboardCloseState =
        FLMFloatingKeyboardCloseStateCommit;
    FLMEnqueueDiagnosticLine(
        @"sb coordinated-close commit closeToken=%lu requestGeneration=%llu ackPhase=%u result=%@ frameHidden=%d didHide=%d causal=app-claim order=forwarding-stop,host-cleanup,avoidance-clear,geometry-inactive,presenter-detach,session-end,route-clear",
        (unsigned long)closeToken,
        (unsigned long long)context.requestGeneration,
        (unsigned)self.floatingKeyboardDismissAckPhase,
        FLMKeyboardDismissResultName(self.floatingKeyboardDismissResult),
        self.floatingKeyboardSettlementFrameHidden,
        self.floatingKeyboardSettlementDidHide);
    // applyKeyboardFrame:hidden has already stopped forwarding and cleared
    // avoidance. The ordinary close path now performs host removal, Scene /
    // presenter cleanup and route/session clear in its existing serialized
    // order. No Launch Cover is involved in this commit.
    self.floatingCloseDeferKeyboardSessionEnd = YES;
    // Continue the existing close token through its one visual finalizer.
    // Calling the public close entry as a fresh transaction would allocate a
    // second token and lose the context that authorized this commit.
    self.floatingCloseCommitInProgress = YES;
    [self closeFloatingWindowKeepingApplication:YES];
}

- (void)abortCoordinatedCloseForToken:(NSUInteger)closeToken
                               reason:(NSString *)reason {
    if (closeToken == 0 || self.floatingActiveCloseToken != closeToken) {
        return;
    }
    FLMEnqueueDiagnosticLine(
        @"sb coordinated-close abort closeToken=%lu reason=%@ state=%@ app=%@ session=%lu requestGeneration=%lu card-kept=1 route-kept=1 host-kept=1 centered-preserved=1 launch-cover=none",
        (unsigned long)closeToken, reason ?: @"unknown",
        FLMFloatingKeyboardCloseStateName(self.floatingKeyboardCloseState),
        self.floatingIdentifier ?: @"<none>",
        (unsigned long)self.floatingKeyboardDismissSessionGeneration,
        (unsigned long)self.floatingKeyboardDismissRequestGeneration);
    self.floatingKeyboardCloseState = FLMFloatingKeyboardCloseStateAborted;
    self.floatingKeyboardCloseAbortReason = [reason copy];
    self.floatingCloseInProgress = NO;
    self.floatingCloseCleanupDone = NO;
    self.floatingActiveCloseToken = 0;
    self.floatingKeyboardDismissCloseToken = 0;
    self.floatingKeyboardDismissSessionGeneration = 0;
    self.floatingKeyboardDismissResult = FLMKeyboardDismissResultNone;
    self.floatingKeyboardDismissAckPhase = FLMKeyboardDismissAckPhaseNone;
    self.floatingKeyboardAppDismissClaimed = NO;
    self.floatingKeyboardAppResponderActionStarted = NO;
    self.floatingKeyboardSettlementFrameHidden = NO;
    self.floatingKeyboardSettlementDidHide = NO;
    self.floatingKeyboardDismissAdapterPID = 0;
    // Retain the immutable context while Aborted so a late claimed phase can
    // be identified and ignored without touching the centered card.
    self.floatingCloseCommitInProgress = NO;
    self.floatingCloseDeferKeyboardSessionEnd = NO;
    FLMKeyboardSharedDismissRequestGeneration = 0;
    FLMKeyboardSharedDismissSession = 0;
    FLMKeyboardSharedDismissSessionGeneration = 0;
    FLMKeyboardSharedDismissSceneHash = 0;
    FLMKeyboardSharedDismissBundleHash = 0;
    FLMKeyboardSharedDismissAdapterPID = 0;
    FLMKeyboardSharedDismissAckGeneration = 0;
    FLMKeyboardSharedDismissAckSession = 0;
    FLMKeyboardSharedDismissAckPID = 0;
    FLMKeyboardSharedDismissAckPhase = 0;
    FLMKeyboardSharedDismissAckResult = 0;
    FLMScheduleKeyboardSharedStateWrite();
    BOOL canReenableClose = self.enabled && !self.floatingWindow.hidden &&
                            !self.floatingDocked &&
                            self.floatingLaunchState ==
                                FLMFloatingLaunchStateAttached;
    self.floatingBackdropTap.enabled = canReenableClose;
    self.floatingLaunchCoverView.hidden = YES;
    self.floatingLaunchCoverView.alpha = 1.0;
    self.floatingLaunchCoverView.userInteractionEnabled = NO;
    [self updateFloatingDockTouchGate];
}

- (void)keyboardFrameWillChange:(NSNotification *)notification {
    NSValue *frameValue = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (![frameValue isKindOfClass:[NSValue class]]) {
        return;
    }
    CGRect frame = frameValue.CGRectValue;
    CGRect bounds = FLMVisualScreenBounds();
    BOOL visible = CGRectIntersectsRect(bounds, frame) &&
                   CGRectGetMinY(frame) < CGRectGetHeight(bounds);
    BOOL duplicateNotification =
        self.floatingKeyboardLastNotificationFrameValid &&
        self.floatingKeyboardLastNotificationVisible == visible &&
        CGRectEqualToRect(self.floatingKeyboardLastNotificationFrame, frame);
    if (duplicateNotification) {
        return;
    }
    self.floatingKeyboardLastNotificationFrame = frame;
    self.floatingKeyboardLastNotificationFrameValid = YES;
    self.floatingKeyboardLastNotificationVisible = visible;
    FLMEnqueueDiagnosticLine(
        @"sb notification=%@ rawFrame=%@ bounds=%@ computedVisible=%d",
        notification.name, NSStringFromCGRect(frame), NSStringFromCGRect(bounds),
        visible);
    if (visible) {
        [self applyKeyboardFrame:frame visible:YES];
    } else {
        // WillChangeFrame marks the beginning of the physical dismissal
        // animation. Keep the stable avoidance and touch envelope until
        // UIKeyboardDidHide confirms that the keyboard is actually gone.
        FLMEnqueueDiagnosticLine(
            @"sb frame-hidden pending-confirmation stableHeight=%.2f avoidance-retained=1",
            self.floatingKeyboardMaximumVisibleHeight);
        BOOL coordinatedTransaction =
            self.floatingCloseInProgress &&
            self.floatingKeyboardDismissCloseToken != 0 &&
            self.floatingKeyboardDismissCloseToken ==
                self.floatingActiveCloseToken &&
            (self.floatingKeyboardCloseState ==
                 FLMFloatingKeyboardCloseStateAwaitingAppClaim ||
             self.floatingKeyboardCloseState ==
             FLMFloatingKeyboardCloseStateAwaitingKeyboardSettlement);
        NSUInteger closeToken = self.floatingKeyboardDismissCloseToken;
        if (coordinatedTransaction &&
            !self.floatingKeyboardAppDismissClaimed) {
            // A hidden frame before the app's atomic claim is manual or
            // unconfirmed cleanup. It must clear the visual keyboard state,
            // abort the close intent, and preserve the centered card/session.
            [self applyKeyboardFrame:CGRectNull visible:NO];
            FLMEnqueueDiagnosticLine(
                @"sb keyboard-hidden action=keyboard-only causalClaim=0 centered-preserved=1 closeToken=%lu reason=keyboard-hidden-without-app-claim",
                (unsigned long)closeToken);
            [self abortCoordinatedCloseForToken:closeToken
                                         reason:@"keyboard-hidden-without-app-claim"];
        } else if (coordinatedTransaction) {
            // Only an already-claimed app dismissal may turn the resulting
            // hidden frame into a coordinated close settlement.
            FLMEnqueueDiagnosticLine(
                @"sb settlement causal=1 source=keyboard-will-change closeToken=%lu",
                (unsigned long)closeToken);
            [self applyKeyboardFrame:CGRectNull visible:NO];
            [self handleKeyboardSettlementForCloseToken:closeToken];
        }
    }
}

- (void)keyboardDidHide:(NSNotification *)notification {
    FLMEnqueueDiagnosticLine(@"sb notification=%@ did-hide",
                             notification.name);
    BOOL coordinatedSettlement =
        self.floatingCloseInProgress &&
        self.floatingKeyboardDismissCloseToken != 0 &&
        self.floatingKeyboardDismissCloseToken == self.floatingActiveCloseToken &&
        (self.floatingKeyboardCloseState ==
             FLMFloatingKeyboardCloseStateAwaitingAppClaim ||
         self.floatingKeyboardCloseState ==
             FLMFloatingKeyboardCloseStateAwaitingKeyboardSettlement);
    NSUInteger closeToken = self.floatingKeyboardDismissCloseToken;
    if (coordinatedSettlement &&
        !self.floatingKeyboardAppDismissClaimed) {
        [self applyKeyboardFrame:CGRectNull visible:NO];
        FLMEnqueueDiagnosticLine(
            @"sb keyboard-hidden action=keyboard-only causalClaim=0 centered-preserved=1 closeToken=%lu reason=keyboard-hidden-without-app-claim",
            (unsigned long)closeToken);
        [self abortCoordinatedCloseForToken:closeToken
                                     reason:@"keyboard-hidden-without-app-claim"];
        coordinatedSettlement = NO;
    } else if (coordinatedSettlement) {
        self.floatingKeyboardSettlementDidHide = YES;
        FLMEnqueueDiagnosticLine(
            @"sb keyboard-settlement did-hide closeToken=%lu session=%lu requestGeneration=%lu ackPhase=%u ack=%@ causal=1",
            (unsigned long)closeToken,
            (unsigned long)self.floatingKeyboardDismissSessionGeneration,
            (unsigned long)self.floatingKeyboardDismissRequestGeneration,
            (unsigned)self.floatingKeyboardDismissAckPhase,
            FLMKeyboardDismissResultName(self.floatingKeyboardDismissResult));
    }
    [self applyKeyboardFrame:CGRectNull visible:NO];
    BOOL centeredCardSessionActive =
        !self.floatingWindow.hidden && !self.floatingDocked &&
        !self.floatingCloseInProgress &&
        self.floatingLaunchState == FLMFloatingLaunchStateAttached &&
        self.floatingKeyboardSessionGeneration != 0 &&
        self.floatingScene && self.floatingIdentifier.length > 0;
    if (centeredCardSessionActive) {
        [self releaseAllFloatingKeyboardHostQuarantinesForReason:
                  @"keyboard-did-hide-active-card"];
    } else {
        [self discardAllFloatingKeyboardHostQuarantinesForReason:
                  @"keyboard-did-hide-inactive-card"];
    }
    [self finalizeKeyboardDismissalProtection];
    if (coordinatedSettlement) {
        [self handleKeyboardSettlementForCloseToken:
                  closeToken];
    } else if (!self.floatingCloseInProgress) {
        FLMEnqueueDiagnosticLine(
            @"sb keyboard-hidden action=keyboard-only centered-preserved=1 no-coordinated-close=1");
    }
}

- (void)finalizeKeyboardDismissalProtection {
    // WillChangeFrame owns the protection for the physical keyboard-dismiss
    // touch. DidHide arrives after that touch and the keyboard animation have
    // completed, so it must finish the protection instead of extending it for
    // another half second. The outside recognizers already preserve each
    // touch's begin-domain classification.
    self.floatingKeyboardInteractionGeneration += 1;
    NSUInteger finalizedGeneration =
        self.floatingKeyboardInteractionGeneration;
    self.floatingBackdropTap.additionalProtectedFrame = CGRectNull;
    ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame =
        CGRectNull;
    [self endFloatingKeyboardInteractionSession];
    self.floatingKeyboardMaximumVisibleHeight = 0.0;
    FLMEnqueueDiagnosticLine(
        @"sb frame-hidden protection=finalized generation=%lu",
        (unsigned long)finalizedGeneration);
}

- (CGSize)floatingSystemSceneReferenceSize {
    // This is the only reference used to write the private application Scene
    // settings. It intentionally never changes when the app is displayed in
    // the centered card: the app remains a normal display-sized foreground
    // Scene for activation, responder ownership, and keyboard semantics.
    CGRect displayBounds = FLMVisualScreenBounds();
    CGSize size = displayBounds.size;
    if (size.width < 1.0 || size.height < 1.0) {
        size = self.floatingWindow.bounds.size;
    }
    return size.width > 1.0 && size.height > 1.0 ? size : CGSizeZero;
}

- (CGSize)floatingContentViewportReferenceSize {
    // There is deliberately no card-sized logical viewport. The application
    // content and keyboard use the same full-screen coordinate system in every
    // centered-card configuration; only the host presentation is scaled and
    // clipped by layoutFloatingHostView.
    return [self floatingSystemSceneReferenceSize];
}

- (CGSize)floatingSceneReferenceSize {
    // Keep the helper as a scene-only alias. The card never becomes a Scene
    // geometry contract.
    return [self floatingSystemSceneReferenceSize];
}

- (BOOL)applyFloatingSceneLogicalFrameForCurrentPresentation:(NSString *)policy {
    id scene = self.floatingScene;
    if (!scene ||
        ![scene respondsToSelector:@selector(updateSettings:withTransitionContext:)]) {
        return NO;
    }
    CGSize systemSceneReference = [self floatingSystemSceneReferenceSize];
    CGSize contentViewportReference =
        [self floatingContentViewportReferenceSize];
    if (systemSceneReference.width <= 1.0 ||
        systemSceneReference.height <= 1.0) {
        return NO;
    }
    @try {
        id settings = [scene respondsToSelector:@selector(settings)]
                          ? [scene settings]
                          : nil;
        id mutableSettings = [settings mutableCopy];
        if (!mutableSettings && [scene respondsToSelector:@selector(mutableSettings)]) {
            mutableSettings = [scene mutableSettings];
        }
        if (!mutableSettings ||
            ![mutableSettings respondsToSelector:@selector(setFrame:)]) {
            return NO;
        }
        [mutableSettings setFrame:CGRectMake(0.0,
                                              0.0,
                                              systemSceneReference.width,
                                              systemSceneReference.height)];
        [scene updateSettings:mutableSettings withTransitionContext:nil];
        self.floatingHostReferenceSize =
            [self floatingContentViewportReferenceSize];
        FLMEnqueueDiagnosticLine(
            @"sb scene-frame policy=fullscreen systemSceneReference={%.4f,%.4f} contentViewportReference={%.4f,%.4f} physical-card={%.1f,%.1f} requested=%@",
            systemSceneReference.width,
            systemSceneReference.height,
            contentViewportReference.width,
            contentViewportReference.height,
            [self effectiveCenteredCardWidth],
            [self effectiveCenteredCardHeight],
            policy ?: @"unknown");
        return YES;
    } @catch (__unused NSException *exception) {
        FLMEnqueueDiagnosticLine(
            @"sb scene-frame policy=fullscreen rejected=exception systemSceneReference={%.4f,%.4f} contentViewportReference={%.4f,%.4f} physical-card={%.1f,%.1f} requested=%@",
            systemSceneReference.width,
            systemSceneReference.height,
            contentViewportReference.width,
            contentViewportReference.height,
            [self effectiveCenteredCardWidth],
            [self effectiveCenteredCardHeight],
            policy ?: @"unknown");
        return NO;
    }
}

- (FLMApplicationSceneHandle *)sceneHandleForIdentifier:(NSString *)identifier {
    if (identifier.length == 0) {
        return nil;
    }
    @try {
        if (self.floatingSceneEntity &&
            [identifier isEqualToString:self.floatingIdentifier] &&
            [self.floatingSceneEntity respondsToSelector:@selector(sceneHandle)]) {
            id existingCandidate = [self.floatingSceneEntity sceneHandle];
            if (([existingCandidate respondsToSelector:@selector(sceneIfExists)] ||
                 [existingCandidate respondsToSelector:@selector(scene)]) &&
                [self sceneForHandle:existingCandidate]) {
                return (FLMApplicationSceneHandle *)existingCandidate;
            }
            // Do not keep polling a handle whose primary scene was replaced
            // during cold launch.  This was the main source of the permanent
            // "Launching application" card on iOS 16.
            self.floatingSceneEntity = nil;
            self.floatingSceneHandle = nil;
        }

        Class controllerClass = NSClassFromString(@"SBApplicationController");
        if (![controllerClass respondsToSelector:@selector(sharedInstance)]) {
            return nil;
        }
        FLMSBApplicationController *controller =
            (FLMSBApplicationController *)[controllerClass sharedInstance];
        if (![controller respondsToSelector:
                            @selector(applicationWithBundleIdentifier:)]) {
            return nil;
        }
        FLMSBApplication *application =
            (FLMSBApplication *)[controller
                applicationWithBundleIdentifier:identifier];
        if (!application) {
            return nil;
        }

        Class entityClass =
            NSClassFromString(@"SBDeviceApplicationSceneEntity");
        SEL initializer =
            @selector(initWithApplicationForMainDisplay:
                 generatingNewPrimarySceneIfRequired:);
        id allocatedEntity = [entityClass alloc];
        if (!allocatedEntity ||
            ![allocatedEntity respondsToSelector:initializer]) {
            return nil;
        }
        // First let the normal suspended launch create its own primary scene.
        // Forcing one synchronously races UIKit's scene connection and often
        // yields a valid handle with a black, never-ready surface.  Only ask
        // SpringBoard to generate a scene after a bounded grace period.
        BOOL generatePrimaryScene =
            self.floatingLaunchStartedAt > 0.0 &&
            CACurrentMediaTime() - self.floatingLaunchStartedAt >=
                FLMFloatingSceneGenerationDelay;
        FLMDeviceApplicationSceneEntity *entity =
            [(FLMDeviceApplicationSceneEntity *)allocatedEntity
                initWithApplicationForMainDisplay:application
                generatingNewPrimarySceneIfRequired:generatePrimaryScene];
        if (!entity ||
            ![entity respondsToSelector:@selector(sceneHandle)]) {
            return nil;
        }
        id candidate = [entity sceneHandle];
        if (![candidate respondsToSelector:@selector(sceneIfExists)] &&
            ![candidate respondsToSelector:@selector(scene)]) {
            return nil;
        }
        if (generatePrimaryScene || [self sceneForHandle:candidate]) {
            self.floatingSceneEntity = entity;
        }
        return (FLMApplicationSceneHandle *)candidate;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

- (id)sceneForHandle:(FLMApplicationSceneHandle *)sceneHandle {
    if (!sceneHandle) {
        return nil;
    }
    id scene = nil;
    @try {
        if ([sceneHandle respondsToSelector:@selector(sceneIfExists)]) {
            scene = [sceneHandle sceneIfExists];
        }
        if (!scene && [sceneHandle respondsToSelector:@selector(scene)]) {
            scene = [sceneHandle scene];
        }
    } @catch (__unused NSException *exception) {
        scene = nil;
    }
    return scene;
}

- (BOOL)prepareFloatingScene:(id)scene
                      handle:(FLMApplicationSceneHandle *)sceneHandle {
    if (!scene) {
        return NO;
    }
    FLMProtectScene(scene, sceneHandle);
    @try {
        if ([scene respondsToSelector:@selector(_setContentState:)]) {
            [scene _setContentState:2];
        }
        // A rapidly replaced card can leave the resolved Scene in a
        // backgrounded transaction even though its mutable settings say
        // foreground. Ask the Scene to activate before creating a presenter;
        // this is guarded because the selector is private and absent on some
        // iOS 16 builds.
        if ([scene respondsToSelector:@selector(activate)]) {
            [scene activate];
        }
        id settings = [scene respondsToSelector:@selector(settings)]
                          ? [scene settings]
                          : nil;
        id mutableSettings = [settings mutableCopy];
        if (!mutableSettings &&
            [scene respondsToSelector:@selector(mutableSettings)]) {
            mutableSettings = [scene mutableSettings];
        }
        if (!mutableSettings) {
            FLMClearProtectedScene(scene);
            return NO;
        }
        if ([mutableSettings respondsToSelector:@selector(setDeactivationReasons:)]) {
            [mutableSettings setDeactivationReasons:0];
        }
        if ([mutableSettings respondsToSelector:@selector(setForeground:)]) {
            [mutableSettings setForeground:YES];
        }
        if ([mutableSettings respondsToSelector:@selector(setBackgrounded:)]) {
            [mutableSettings setBackgrounded:NO];
        }
        CGSize systemSceneReference = [self floatingSystemSceneReferenceSize];
        CGSize contentViewportReference =
            [self floatingContentViewportReferenceSize];
        if (systemSceneReference.width > 0.0 &&
            systemSceneReference.height > 0.0 &&
            [mutableSettings respondsToSelector:@selector(setFrame:)]) {
            [mutableSettings
                setFrame:CGRectMake(0.0,
                                    0.0,
                                    systemSceneReference.width,
                                    systemSceneReference.height)];
            FLMEnqueueDiagnosticLine(
                @"sb scene-frame policy=fullscreen systemSceneReference={%.4f,%.4f} contentViewportReference={%.4f,%.4f} physical-card={%.1f,%.1f} requested=prepare",
                systemSceneReference.width,
                systemSceneReference.height,
                contentViewportReference.width,
                contentViewportReference.height,
                [self effectiveCenteredCardWidth],
                [self effectiveCenteredCardHeight]);
        }
        NSInteger orientation = UIInterfaceOrientationPortrait;
        if ([mutableSettings respondsToSelector:
                             @selector(setInterfaceOrientation:)]) {
            [mutableSettings setInterfaceOrientation:orientation];
        }
        if (![scene respondsToSelector:
                       @selector(updateSettings:withTransitionContext:)]) {
            FLMClearProtectedScene(scene);
            return NO;
        }
        [scene updateSettings:mutableSettings withTransitionContext:nil];
        return YES;
    } @catch (__unused NSException *exception) {
        FLMClearProtectedScene(scene);
        return NO;
    }
}

- (void)backgroundFloatingScene:(id)scene {
    if (!scene) {
        FLMClearProtectedScene(nil);
        return;
    }
    @try {
        id settings = [scene respondsToSelector:@selector(settings)]
                          ? [scene settings]
                          : nil;
        id mutableSettings = [settings mutableCopy];
        if (!mutableSettings &&
            [scene respondsToSelector:@selector(mutableSettings)]) {
            mutableSettings = [scene mutableSettings];
        }
        CGRect screenBounds = FLMVisualScreenBounds();
        if ([mutableSettings respondsToSelector:@selector(setFrame:)] &&
            !CGRectIsEmpty(screenBounds)) {
            [mutableSettings setFrame:CGRectMake(0.0,
                                                  0.0,
                                                  CGRectGetWidth(screenBounds),
                                                  CGRectGetHeight(screenBounds))];
        }
        if ([mutableSettings respondsToSelector:
                             @selector(setInterfaceOrientation:)]) {
            [mutableSettings setInterfaceOrientation:
                              UIInterfaceOrientationPortrait];
        }
        if ([mutableSettings respondsToSelector:@selector(setForeground:)]) {
            [mutableSettings setForeground:NO];
        }
        if ([mutableSettings respondsToSelector:@selector(setBackgrounded:)]) {
            [mutableSettings setBackgrounded:YES];
        }
        if (mutableSettings &&
            [scene respondsToSelector:
                       @selector(updateSettings:withTransitionContext:)]) {
            [scene updateSettings:mutableSettings withTransitionContext:nil];
        }
    } @catch (__unused NSException *exception) {
    }
    FLMClearProtectedScene(scene);
}

- (void)invalidateFloatingPresenterForRecoveryReason:(NSString *)reason {
    id presenter = self.floatingPresenter;
    id manager = self.floatingPresentationManager;
    id presenterScene = self.floatingPresenterScene;
    UIView *host = self.floatingHostView;
    self.floatingPresenter = nil;
    self.floatingPresentationManager = nil;
    self.floatingPresenterScene = nil;
    self.floatingPresenterUnavailableAt = 0.0;
    if (host) {
        [host removeFromSuperview];
        self.floatingHostView = nil;
    }
    @try {
        if ([presenter respondsToSelector:@selector(deactivate)]) {
            [presenter deactivate];
        }
        if ([presenter respondsToSelector:@selector(invalidate)]) {
            [presenter invalidate];
        }
    } @catch (__unused NSException *exception) {
    }
    FLMEnqueueDiagnosticLine(
        @"sb presenter-recovery reason=%@ manager=%p presenter=%p scene=%@",
        reason ?: @"<unspecified>", (__bridge void *)manager,
        (__bridge void *)presenter,
        FLMSceneIdentifier(presenterScene) ?: @"<none>");
}

- (UIView *)hostViewForSceneHandle:(FLMApplicationSceneHandle *)sceneHandle {
    if (!sceneHandle) {
        return nil;
    }
    id scene = [self sceneForHandle:sceneHandle];
    if (self.floatingPresenterScene &&
        self.floatingPresenterScene != scene) {
        [self invalidateFloatingPresenterForRecoveryReason:@"scene-replaced"];
    }
    BOOL sceneChanged = scene && scene != self.floatingScene;
    BOOL needsInitialSceneSettle = self.floatingScenePreparedAt <= 0.0;
    FLMEnqueueDiagnosticLine(
        @"sb presenter-query handle=%p scene=%@ changed=%d initialSettle=%d launch=%lu",
        (__bridge void *)sceneHandle, FLMSceneIdentifier(scene) ?: @"<none>",
        sceneChanged, needsInitialSceneSettle,
        (unsigned long)self.floatingLaunchState);
    if (sceneChanged || needsInitialSceneSettle) {
        // Scene preparation is a one-time lifecycle step. Presenter polling
        // must only query the existing presenter; repeating updateSettings:
        // here recreates the scene-frame/IPC storm seen during opening.
        if (![self prepareFloatingScene:scene handle:sceneHandle]) {
            return nil;
        }
        self.floatingScene = scene;
        self.floatingHostReferenceSize =
            [self floatingContentViewportReferenceSize];
        self.floatingScenePreparedAt = CACurrentMediaTime();
        self.floatingLaunchState = FLMFloatingLaunchStateWaitingForPresenter;
        return nil;
    }
    if (self.floatingScenePreparedAt > 0.0 &&
        CACurrentMediaTime() - self.floatingScenePreparedAt <
            FLMFloatingSceneSettleDelay) {
        return nil;
    }

    id manager = self.floatingPresentationManager;
    id presenter = self.floatingPresenter;
    UIView *host = nil;
    @try {
        if (!manager &&
            [scene respondsToSelector:@selector(uiPresentationManager)]) {
            manager = [scene uiPresentationManager];
        }
        if (!manager &&
            [scene respondsToSelector:@selector(presentationManager)]) {
            manager = [scene presentationManager];
        }
        if (manager && manager != self.floatingPresentationManager) {
            self.floatingPresentationManager = manager;
        }
        if (!presenter) {
            if ([manager respondsToSelector:
                             @selector(createPresenterWithIdentifier:)]) {
                presenter =
                    [manager createPresenterWithIdentifier:
                                 @"com.codex.flymemultitasking.centered"];
                if (presenter) {
                    self.floatingPresenter = presenter;
                }
                if ([presenter respondsToSelector:@selector(activate)]) {
                    [presenter activate];
                }
            }
        }
        if ([presenter respondsToSelector:@selector(presentationView)]) {
            host = [presenter presentationView];
        }
    } @catch (__unused NSException *exception) {
        host = nil;
    }
    if (![host isKindOfClass:[UIView class]]) {
        if (self.floatingPresenterUnavailableAt <= 0.0) {
            self.floatingPresenterUnavailableAt = CACurrentMediaTime();
        }
        NSTimeInterval unavailableFor =
            CACurrentMediaTime() - self.floatingPresenterUnavailableAt;
        if (unavailableFor >= FLMFloatingPresenterRecoveryTimeout ||
            (self.floatingPresenterRetryAttempt > 0 &&
             self.floatingPresenterRetryAttempt % 12 == 0)) {
            FLMEnqueueDiagnosticLine(
                @"sb presenter-stale-retry manager=%p presenter=%p scene=%@ attempt=%lu unavailable=%.3f",
                (__bridge void *)manager, (__bridge void *)presenter,
                FLMSceneIdentifier(scene) ?: @"<none>",
                (unsigned long)self.floatingPresenterRetryAttempt,
                unavailableFor);
            [self invalidateFloatingPresenterForRecoveryReason:
                      @"nil-host-timeout"];
            // A manager can outlive the Scene transaction that created it.
            // Force the next retry through a fresh handle instead of polling
            // the stale manager indefinitely.
            self.floatingSceneEntity = nil;
            self.floatingSceneHandle = nil;
            self.floatingScene = nil;
            self.floatingScenePreparedAt = 0.0;
        }
        FLMEnqueueDiagnosticLine(
            @"sb presenter-not-ready manager=%p presenter=%p scene=%@ attempt=%lu unavailable=%.3f",
            (__bridge void *)manager, (__bridge void *)presenter,
            FLMSceneIdentifier(scene) ?: @"<none>",
            (unsigned long)self.floatingPresenterRetryAttempt, unavailableFor);
        return nil;
    }
    self.floatingPresentationManager = manager;
    self.floatingPresenter = presenter;
    self.floatingPresenterScene = scene;
    self.floatingPresenterUnavailableAt = 0.0;
    host.backgroundColor = [UIColor blackColor];
    host.userInteractionEnabled = YES;
    // The host always uses the display-sized Scene reference. The physical
    // card is only a clipped presentation surface with the user-selected
    // width and top/bottom crop values.
    host.clipsToBounds = NO;
    self.floatingLaunchState = FLMFloatingLaunchStateAttached;
    FLMEnqueueDiagnosticLine(
        @"sb presenter-attached host=%p frame=%@ scene=%@",
        (__bridge void *)host, NSStringFromCGRect(host.frame),
        FLMSceneIdentifier(scene) ?: @"<none>");
    return host;
}

- (void)openFloatingIdentifier:(NSString *)identifier {
    if (identifier.length == 0 || FLMDeviceIsLocked()) {
        self.prewarmedIdentifier = nil;
        self.floatingOpenTargetDocked = NO;
        return;
    }
    if (self.floatingCloseInProgress) {
        // All wheel targets share the same close transaction. Keep only the
        // latest request and let the close completion open it after the old
        // Scene/presenter has been released.
        self.floatingQueuedIdentifier = [identifier copy];
        FLMEnqueueDiagnosticLine(
            @"sb centered-open queued target=%@ closeToken=%lu current=%@",
            identifier, (unsigned long)self.floatingActiveCloseToken,
            self.floatingIdentifier ?: @"<none>");
        return;
    }
    if (!self.floatingWindow.hidden && self.floatingIdentifier.length > 0 &&
        [identifier isEqualToString:self.floatingIdentifier]) {
        self.prewarmedIdentifier = nil;
        return;
    }
    if (!self.floatingWindow.hidden) {
        self.floatingQueuedIdentifier = [identifier copy];
        [self closeFloatingWindowKeepingApplication:YES];
        FLMEnqueueDiagnosticLine(
            @"sb centered-open queued target=%@ closeToken=%lu reason=replace-current",
            identifier, (unsigned long)self.floatingActiveCloseToken);
        return;
    }
    if ([identifier isEqualToString:FLMFrontmostApplicationIdentifier()] &&
        !self.floatingOpenTargetDocked) {
        self.prewarmedIdentifier = nil;
        return;
    }

    BOOL alreadyPrewarmed =
        [self.prewarmedIdentifier isEqualToString:identifier];
    self.prewarmedIdentifier = nil;
    if (self.floatingKeyboardSessionGeneration != 0) {
        // End the old route while its original Scene/host are still retained;
        // assigning the new target first would make stale cleanup operate on
        // the wrong application generation.
        [self endFloatingKeyboardSession];
    }

    self.floatingDockWidth = [self effectiveDockedPresentationWidth];
    self.floatingReconnectSuppressed = NO;
    self.floatingDocked = NO;
    self.floatingDockHidden = NO;
    self.floatingDockHideGestureActive = NO;
    self.floatingDockedOnRight = YES;
    self.floatingExternalActivationArmed = NO;
    self.floatingFullscreenActivationArmed = NO;
    self.lastObservedFrontmostIdentifier = nil;
    self.floatingDockTransitionActive = NO;
    self.floatingDockControlTransitionGeneration += 1;
    self.floatingDockControlTransition =
        FLMFloatingDockControlTransitionNone;
    self.floatingDockControlTargetFrame = CGRectNull;
    self.floatingDockControlDefersKeyboardTeardown = NO;
    self.floatingDockInputSessionActive = NO;
    self.floatingDockInputMode = FLMFloatingDockInputModeNone;
    self.floatingDockInputTargetsResize = NO;
    self.floatingResizeCenterReady = NO;
    self.floatingResizeHandle.hidden = YES;
    self.floatingResizeHandle.userInteractionEnabled = NO;
    [self cancelFloatingDockInputUpdates];
    [self setFloatingDockRoutingSuppressed:NO];
    // Promote the target with the display-sized Scene first so it retains the
    // full-screen application-style activation and keyboard ownership. The
    // fixed card Scene is committed only after the presenter is attached;
    // this separates route establishment from geometry/layout.
    self.floatingSceneUsesCardGeometry = NO;
    self.floatingSceneCardGeometryPending = NO;
    self.floatingSceneCardGeometryCommitted = YES;
    self.contentViewportCommitted = NO;
    self.floatingKeyboardPresentationSuspendedForDock = NO;
    self.floatingKeyboardAvoidancePublishDeferred = NO;
    self.floatingDockReady = NO;
    ((FLMFloatingWindow *)self.floatingWindow)
        .passesTouchesOutsideFloatingContent = NO;
    self.floatingDockDragPress.enabled = NO;
    self.floatingDockInputGesture.enabled = NO;
    self.floatingDockInputGeneration += 1;
    self.floatingDockShadowView.hidden = YES;
    self.floatingDockShadowView.alpha = 0.0;
    self.floatingDockShadowView.transform = CGAffineTransformIdentity;
    self.floatingDockInteractionShield.hidden = YES;
    self.floatingDockInteractionShield.userInteractionEnabled = NO;
    [self restoreFloatingHandleInteraction];
    self.floatingContainer.layer.borderWidth = 0.0;
    self.floatingInteractiveScenePrepared = NO;
    self.floatingInteractiveFullscreenTransition = NO;
    [self.floatingInteractiveSnapshot removeFromSuperview];
    self.floatingInteractiveSnapshot = nil;
    self.floatingInteractiveSnapshotBackground = nil;
    self.floatingInteractiveSnapshotContent = nil;
    self.floatingFullscreenProgress = 0.0;
    self.floatingKeyboardInteractionGeneration += 1;
    self.floatingKeyboardInteractionSessionActive = NO;
    self.floatingKeyboardVisible = NO;
    self.floatingKeyboardFrame = CGRectNull;
    self.floatingKeyboardFramePending = NO;
    self.floatingKeyboardPendingFrame = CGRectNull;
    self.floatingKeyboardPendingSessionGeneration = 0;
    self.floatingExclusiveTapEligible = NO;
    self.floatingBackdropTap.additionalProtectedFrame = CGRectNull;
    ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame = CGRectNull;
    self.floatingLaunchGeneration += 1;
    NSUInteger generation = self.floatingLaunchGeneration;
    self.floatingLaunchState = FLMFloatingLaunchStatePrewarming;
    self.floatingLaunchStartedAt = CACurrentMediaTime();
    self.floatingScenePreparedAt = 0.0;
    [self.floatingHostView removeFromSuperview];
    self.floatingHostView = nil;
    self.floatingHostReferenceSize = CGSizeZero;
    self.floatingSceneEntity = nil;
    self.floatingSceneHandle = nil;
    self.floatingScene = nil;
    self.floatingPresentationManager = nil;
    self.floatingPresenter = nil;
    self.floatingPresenterScene = nil;
    self.floatingPresenterUnavailableAt = 0.0;
    self.floatingPresenterRetryAttempt = 0;
    self.floatingIdentifier = identifier;
    [self discardFloatingKeyboardLayerHost];
    self.floatingKeyboardSessionCounter += 1;
    if (self.floatingKeyboardSessionCounter == 0) {
        self.floatingKeyboardSessionCounter = 1;
    }
    self.floatingKeyboardSessionGeneration =
        self.floatingKeyboardSessionCounter;
    [self invalidateSessionCanonicalGeometry];
    self.floatingSceneGeometryCommitGeneration = generation;
    FLMEnqueueDiagnosticLine(
        @"sb centered-open app=%@ launchGen=%lu session=%lu prewarmed=%d previousHost=%p",
        identifier, (unsigned long)generation,
        (unsigned long)self.floatingKeyboardSessionGeneration,
        alreadyPrewarmed, (__bridge void *)self.floatingKeyboardLayerHostView);
    // Do not wake an old application responder with a target-gated route. The
    // route becomes active only after SpringBoard resolves the exact Scene.
    FLMPublishKeyboardState(nil, nil, 0);
    [self configureFloatingLaunchCoverForIdentifier:identifier];
    [self layoutFloatingWindow];

    self.floatingDimView.alpha = 0.0;
    self.floatingContainer.alpha = 0.0;
    self.floatingContainer.transform = CGAffineTransformMakeScale(0.90, 0.90);
    self.floatingHandle.alpha = 0.0;
    self.floatingHandle.userInteractionEnabled = NO;
    self.previousKeyWindow = FLMCurrentKeyWindow();
    self.floatingBackdropTap.enabled = YES;
    self.floatingExclusiveGesture.enabled = NO;
    // The corner-only priority window remains live while the card is
    // prewarming/attaching. Wheel presentation must not depend on the target
    // app's Scene or on the card animation having completed.
    self.cornerGuardGesture.enabled = self.enabled;
    self.cornerGesture.enabled = self.enabled;
    [self.floatingWindow makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self layoutFloatingWindow];
    });
    [UIView animateWithDuration:0.40
                          delay:0.0
         usingSpringWithDamping:0.84
          initialSpringVelocity:0.30
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         self.floatingDimView.alpha = 1.0;
                         self.floatingContainer.alpha = 1.0;
                         self.floatingContainer.transform = CGAffineTransformIdentity;
                         self.floatingHandle.alpha = 1.0;
                     }
                     completion:nil];

    if (!alreadyPrewarmed) {
        FLMPrewarmApplicationIdentifier(identifier);
    }
    [self beginLockMonitoring];
    // Let UIKit publish its normal primary scene before querying an entity.
    // Creating both transactions in the same run-loop turn is racy on iOS 16.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(FLMFloatingSceneResolveGraceDelay *
                                           NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self attachFloatingIdentifier:identifier
                            generation:generation
                               attempt:0];
    });
}

- (void)attachFloatingIdentifier:(NSString *)identifier
                      generation:(NSUInteger)generation
                         attempt:(NSUInteger)attempt {
    if (generation != self.floatingLaunchGeneration ||
        ![identifier isEqualToString:self.floatingIdentifier] ||
        self.floatingWindow.hidden) {
        return;
    }
    if (self.floatingLaunchStartedAt <= 0.0) {
        self.floatingLaunchStartedAt = CACurrentMediaTime();
    }
    if (CACurrentMediaTime() - self.floatingLaunchStartedAt >
        FLMFloatingLaunchTimeout) {
        [self failFloatingLaunchForIdentifier:identifier generation:generation];
        return;
    }
    FLMApplicationSceneHandle *sceneHandle =
        [self sceneHandleForIdentifier:identifier];
    if (!sceneHandle) {
        self.floatingLaunchState = FLMFloatingLaunchStateWaitingForScene;
        self.floatingStatusLabel.text = @"正在准备应用…";
        if (attempt < 60) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(FLMFloatingScenePollInterval *
                                        NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [self attachFloatingIdentifier:identifier
                                        generation:generation
                                           attempt:attempt + 1];
                });
            return;
        }
        [self failFloatingLaunchForIdentifier:identifier generation:generation];
        return;
    }

    id resolvedScene = [self sceneForHandle:sceneHandle];
    if (!resolvedScene) {
        self.floatingLaunchState = FLMFloatingLaunchStateWaitingForScene;
        self.floatingStatusLabel.text = @"正在启动应用…";
        if (attempt > 0 && attempt % 5 == 0) {
            // A generated primary-scene entity can retain a handle whose scene
            // was replaced during application launch. Resolve a fresh entity
            // instead of polling the dead handle for the full timeout.
            self.floatingSceneEntity = nil;
            self.floatingSceneHandle = nil;
        }
        if (attempt == 8) {
            FLMPrewarmApplicationIdentifier(identifier);
        }
        if (attempt < 60) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(FLMFloatingScenePollInterval *
                                        NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [self attachFloatingIdentifier:identifier
                                        generation:generation
                                           attempt:attempt + 1];
                });
            return;
        }
        [self failFloatingLaunchForIdentifier:identifier generation:generation];
        return;
    }

    if (resolvedScene != self.floatingScene) {
        self.floatingScene = resolvedScene;
        self.floatingScenePreparedAt = 0.0;
        FLMEnqueueDiagnosticLine(
            @"sb scene-resolved app=%@ launchGen=%lu attempt=%lu scene=%@ session=%lu",
            identifier, (unsigned long)generation, (unsigned long)attempt,
            FLMSceneIdentifier(resolvedScene) ?: @"<none>",
            (unsigned long)self.floatingKeyboardSessionGeneration);
        FLMPublishKeyboardState(identifier,
                                resolvedScene,
                                self.floatingKeyboardSessionGeneration);
        // Give the freshly resolved application Scene one short main-run-loop
        // interval before foreground/frame settings are committed.
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(FLMFloatingSceneResolveGraceDelay *
                                    NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                [self attachFloatingIdentifier:identifier
                                    generation:generation
                                       attempt:attempt + 1];
            });
        return;
    }

    self.floatingPresenterRetryAttempt = attempt;
    UIView *host = [self hostViewForSceneHandle:sceneHandle];
    if (!host) {
        self.floatingLaunchState = FLMFloatingLaunchStateWaitingForPresenter;
        self.floatingStatusLabel.text = @"正在连接画面…";
        // Do not leave a neutral launch cover on screen indefinitely when
        // SpringBoard's presentation manager has lost its presenter during a
        // rapid app switch. After a short bounded retry window, the existing
        // fullscreen activation path is safer than a visually frozen card.
        if (attempt >= 28 && self.floatingPresenterUnavailableAt > 0.0) {
            FLMEnqueueDiagnosticLine(
                @"sb presenter-watchdog fallback=fullscreen app=%@ generation=%lu attempt=%lu unavailable=%.3f",
                identifier, (unsigned long)generation, (unsigned long)attempt,
                CACurrentMediaTime() - self.floatingPresenterUnavailableAt);
            [self failFloatingLaunchForIdentifier:identifier
                                         generation:generation];
            return;
        }
        if (attempt < 60) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(FLMFloatingScenePollInterval *
                                        NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [self attachFloatingIdentifier:identifier
                                        generation:generation
                                           attempt:attempt + 1];
                });
            return;
        }
        [self failFloatingLaunchForIdentifier:identifier generation:generation];
        return;
    }
    self.floatingSceneHandle = sceneHandle;
    self.floatingHostView = host;
    if (self.floatingHostReferenceSize.width < 1.0 ||
        self.floatingHostReferenceSize.height < 1.0) {
        CGSize referenceSize = host.bounds.size;
        if (referenceSize.width < 1.0 || referenceSize.height < 1.0) {
            referenceSize = [self floatingContentViewportReferenceSize];
        }
        self.floatingHostReferenceSize = referenceSize;
    }
    host.autoresizingMask = UIViewAutoresizingNone;
    host.userInteractionEnabled = NO;
    // RemoteSceneHost is attached below ClipContainer. Its logical Scene
    // frame remains the system reference frame while only the container is
    // animated or dragged.
    [self.floatingContainer insertSubview:host atIndex:0];
    [self layoutFloatingHostView];
    self.floatingStatusLabel.hidden = YES;
    [self.floatingContainer bringSubviewToFront:self.floatingLaunchCoverView];
    [self flushDeferredFloatingKeyboardHostIfReady];
    [self flushPendingFloatingKeyboardFrameIfReady];
    [self revealFloatingContentForGeneration:generation];
    FLMEnqueueDiagnosticLine(
        @"sb centered-content-ready app=%@ launchGen=%lu attempt=%lu host=%p hostBounds=%@ systemSceneReference={%.4f,%.4f} hostReference={%.4f,%.4f} physical-card={%.1f,%.1f} topCrop=%.1f bottomCrop=%.1f sceneFrameReference=system contentViewportCommitted=%d",
        identifier, (unsigned long)generation, (unsigned long)attempt,
        (__bridge void *)host, NSStringFromCGRect(host.bounds),
        [self floatingSystemSceneReferenceSize].width,
        [self floatingSystemSceneReferenceSize].height,
        self.floatingHostReferenceSize.width,
        self.floatingHostReferenceSize.height,
        [self effectiveCenteredCardWidth],
        [self effectiveCenteredCardHeight],
        self.centeredCardTopCrop,
        self.centeredCardBottomCrop,
        self.contentViewportCommitted);
}

- (BOOL)floatingSceneLogicalFrameMatchesSystemReference {
    id scene = self.floatingScene;
    CGSize systemSceneReference = [self floatingSystemSceneReferenceSize];
    if (!scene || systemSceneReference.width <= 1.0 ||
        systemSceneReference.height <= 1.0) {
        return NO;
    }
    @try {
        id settings = [scene respondsToSelector:@selector(settings)]
                          ? [scene settings]
                          : nil;
        id frameValue = [settings respondsToSelector:@selector(valueForKey:)]
                            ? [settings valueForKey:@"frame"]
                            : nil;
        if (![frameValue isKindOfClass:[NSValue class]]) {
            return NO;
        }
        CGRect frame = [frameValue CGRectValue];
        return fabs(CGRectGetWidth(frame) - systemSceneReference.width) <= 1.0 &&
               fabs(CGRectGetHeight(frame) - systemSceneReference.height) <= 1.0;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

- (void)commitFloatingCardSceneGeometryForIdentifier:(NSString *)identifier
                                           generation:(NSUInteger)generation
                                              attempt:(NSUInteger)attempt {
    if (generation != self.floatingLaunchGeneration ||
        ![identifier isEqualToString:self.floatingIdentifier] ||
        self.floatingWindow.hidden || !self.floatingHostView ||
        !self.floatingSceneCardGeometryPending) {
        return;
    }
    self.floatingSceneGeometryCommitGeneration = generation;
    self.contentViewportCommitted = NO;
    CGSize previousReference = self.floatingHostReferenceSize;
    self.floatingSceneUsesCardGeometry = NO;
    BOOL applied =
        [self applyFloatingSceneLogicalFrameForCurrentPresentation:
                  @"content-viewport-request"];
    // Do not change the Scene reference here. The route was established using
    // the display-sized Scene and must remain that way. Only the presentation
    // host changes reference space after its content viewport is committed.
    CGSize systemSceneReference = [self floatingSystemSceneReferenceSize];
    CGSize contentViewportReference =
        [self floatingContentViewportReferenceSize];
    [self layoutFloatingHostView];
    FLMEnqueueDiagnosticLine(
        @"sb content-viewport request generation=%lu attempt=%lu applied=%d previousHostReference={%.4f,%.4f} systemSceneReference={%.4f,%.4f} contentViewportReference={%.4f,%.4f} physical-card={%.1f,%.1f} scaleXY={%.6f,%.6f} host=%@ sceneFrameReference=system contentViewportCommitted=%d routeSession=%lu",
        (unsigned long)generation, (unsigned long)attempt, applied,
        previousReference.width,
        previousReference.height,
        systemSceneReference.width,
        systemSceneReference.height,
        contentViewportReference.width,
        contentViewportReference.height,
        [self effectiveCenteredCardWidth],
        [self effectiveCenteredCardHeight],
        [self effectiveCenteredCardScaleX],
        [self effectiveCenteredCardScaleY],
        NSStringFromCGRect(self.floatingHostView.bounds),
        self.contentViewportCommitted,
        (unsigned long)self.floatingKeyboardSessionGeneration);

    if (!applied && attempt >= 8) {
        [self finishFloatingCardSceneGeometryCommitForIdentifier:identifier
                                                         generation:generation
                                                            attempt:attempt];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(FLMFloatingSceneSettleDelay *
                                           NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self finishFloatingCardSceneGeometryCommitForIdentifier:identifier
                                                         generation:generation
                                                            attempt:attempt + 1];
    });
}

- (void)finishFloatingCardSceneGeometryCommitForIdentifier:(NSString *)identifier
                                                  generation:(NSUInteger)generation
                                                     attempt:(NSUInteger)attempt {
    if (generation != self.floatingLaunchGeneration ||
        ![identifier isEqualToString:self.floatingIdentifier] ||
        self.floatingWindow.hidden || !self.floatingHostView ||
        !self.floatingSceneCardGeometryPending) {
        return;
    }
    BOOL committed = [self floatingSceneLogicalFrameMatchesSystemReference];
    if (!committed && attempt < 8) {
        [self commitFloatingCardSceneGeometryForIdentifier:identifier
                                                 generation:generation
                                                    attempt:attempt];
        return;
    }
    if (!committed) {
        // A private Scene may reject the display-sized frame during lifecycle
        // churn. Keep the existing bounded fallback rather than exposing a
        // half-laid-out card or leaving the launch cover forever.
        self.floatingSceneUsesCardGeometry = NO;
        self.floatingSceneCardGeometryPending = NO;
        self.floatingSceneCardGeometryCommitted = NO;
        self.contentViewportCommitted = NO;
        [self applyFloatingSceneLogicalFrameForCurrentPresentation:
                  @"content-viewport-fallback-fullscreen"];
        [self layoutFloatingHostView];
        CGSize systemSceneReference = [self floatingSystemSceneReferenceSize];
        CGSize contentViewportReference =
            [self floatingContentViewportReferenceSize];
        FLMEnqueueDiagnosticLine(
            @"sb content-viewport fallback=fullscreen generation=%lu attempt=%lu systemSceneReference={%.4f,%.4f} contentViewportReference={%.4f,%.4f} physical-card={%.1f,%.1f} host=%@ sceneFrameReference=system contentViewportCommitted=%d",
            (unsigned long)generation, (unsigned long)attempt,
            systemSceneReference.width,
            systemSceneReference.height,
            contentViewportReference.width,
            contentViewportReference.height,
            [self effectiveCenteredCardWidth],
            [self effectiveCenteredCardHeight],
            NSStringFromCGRect(self.floatingHostView.bounds),
            self.contentViewportCommitted);
    } else {
        self.floatingSceneCardGeometryPending = NO;
        self.floatingSceneCardGeometryCommitted = YES;
        self.contentViewportCommitted = YES;
        self.floatingHostReferenceSize =
            [self floatingContentViewportReferenceSize];
        [self layoutFloatingHostView];
        CGSize systemSceneReference = [self floatingSystemSceneReferenceSize];
        CGSize contentViewportReference =
            [self floatingContentViewportReferenceSize];
        FLMEnqueueDiagnosticLine(
        @"sb content-viewport committed generation=%lu attempt=%lu systemSceneReference={%.4f,%.4f} contentViewportReference={%.4f,%.4f} physical-card={%.1f,%.1f} scaleXY={%.6f,%.6f} host=%@ sceneFrameReference=system routeSession=%lu",
            (unsigned long)generation, (unsigned long)attempt,
            systemSceneReference.width,
            systemSceneReference.height,
            contentViewportReference.width,
            contentViewportReference.height,
            [self effectiveCenteredCardWidth],
            [self effectiveCenteredCardHeight],
            [self effectiveCenteredCardScaleX],
            [self effectiveCenteredCardScaleY],
            NSStringFromCGRect(self.floatingHostView.bounds),
            (unsigned long)self.floatingKeyboardSessionGeneration);
    }

    [self flushDeferredFloatingKeyboardHostIfReady];
    [self flushPendingFloatingKeyboardFrameIfReady];
    [self revealFloatingContentForGeneration:generation];
    FLMEnqueueDiagnosticLine(
        @"sb centered-content-ready app=%@ launchGen=%lu attempt=%lu host=%p hostBounds=%@ systemSceneReference={%.4f,%.4f} contentViewportReference={%.4f,%.4f} hostReference={%.4f,%.4f} physical-card={%.1f,%.1f} scaleXY={%.6f,%.6f} sceneFrameReference=system contentViewportCommitted=%d routeSession=%lu",
        identifier, (unsigned long)generation, (unsigned long)attempt,
        (__bridge void *)self.floatingHostView,
        NSStringFromCGRect(self.floatingHostView.bounds),
        [self floatingSystemSceneReferenceSize].width,
        [self floatingSystemSceneReferenceSize].height,
        [self floatingContentViewportReferenceSize].width,
        [self floatingContentViewportReferenceSize].height,
        self.floatingHostReferenceSize.width,
        self.floatingHostReferenceSize.height,
        [self effectiveCenteredCardWidth],
        [self effectiveCenteredCardHeight],
        [self effectiveCenteredCardScaleX],
        [self effectiveCenteredCardScaleY],
            self.contentViewportCommitted,
            (unsigned long)self.floatingKeyboardSessionGeneration);
}

- (void)failFloatingLaunchForIdentifier:(NSString *)identifier
                               generation:(NSUInteger)generation {
    if (generation != self.floatingLaunchGeneration ||
        self.floatingWindow.hidden) {
        return;
    }
    // Invalidate delayed retries before releasing the protection lease.  A
    // retry from a prior launch must never attach a replaced primary scene.
    self.floatingLaunchState = FLMFloatingLaunchStateFailing;
    self.floatingReconnectSuppressed = YES;
    // Fullscreen fallback must be serialized behind the normal close cleanup.
    // Starting it immediately races presenter invalidation and can leave the
    // next activation attached to the old Scene generation.
    self.floatingQueuedFullscreenIdentifier = [identifier copy];
    [self closeFloatingWindowKeepingApplication:YES];
}

- (void)closeFloatingWindowKeepingApplication:(BOOL)keepApplication {
    BOOL continuingCommittedClose =
        self.floatingCloseCommitInProgress && self.floatingCloseInProgress &&
        self.floatingActiveCloseToken != 0 &&
        self.floatingKeyboardCloseState == FLMFloatingKeyboardCloseStateCommit;
    if (self.floatingCloseInProgress && !continuingCommittedClose) {
        FLMEnqueueDiagnosticLine(
            @"sb close-intent ignored=pending-close closeToken=%lu requestedKeep=%d queuedTarget=%@",
            (unsigned long)self.floatingActiveCloseToken, keepApplication,
            self.floatingQueuedIdentifier ?: @"<none>");
        return;
    }

    BOOL centeredKeyboardStatePresent =
        !continuingCommittedClose && keepApplication && !self.floatingWindow.hidden &&
        !self.floatingDocked &&
        self.floatingKeyboardVisible &&
        self.floatingKeyboardInteractionSessionActive &&
        (self.floatingKeyboardLayerHostView != nil ||
         self.keyboardForwardingWindow.isKeyWindow);
    if (centeredKeyboardStatePresent) {
        self.floatingCloseInProgress = YES;
        self.floatingCloseCleanupDone = NO;
        self.floatingCloseKeepApplication = YES;
        self.floatingCloseDeferKeyboardSessionEnd = NO;
        self.floatingCloseTokenCounter += 1;
        if (self.floatingCloseTokenCounter == 0) {
            self.floatingCloseTokenCounter = 1;
        }
        self.floatingActiveCloseToken = self.floatingCloseTokenCounter;
        FLMEnqueueDiagnosticLine(
            @"sb close-intent begin closeToken=%lu route=backdrop app=%@ session=%lu",
            (unsigned long)self.floatingActiveCloseToken,
            self.floatingIdentifier ?: @"<none>",
            (unsigned long)self.floatingKeyboardSessionGeneration);
        [self beginKeyboardCoordinatedCloseWithToken:
                  self.floatingActiveCloseToken];
        return;
    }

    self.floatingCloseInProgress = YES;
    [self cancelFloatingDockInputUpdates];
    if (self.floatingDockTransitionAnimator) {
        [self.floatingDockTransitionAnimator stopAnimation:YES];
        [self.floatingDockTransitionAnimator finishAnimationAtPosition:
                  UIViewAnimatingPositionCurrent];
        self.floatingDockTransitionAnimator = nil;
    }
    [self.floatingContainer.layer removeAllAnimations];
    self.floatingDockContentTailProtected = NO;
    self.floatingDockContentProtectionGeneration += 1;
    self.floatingDockContentTransitionCommitted = NO;
    self.floatingDockContentProtectionFrame = CGRectNull;
    self.floatingDockTouchGateTransitionFrame = CGRectNull;
    self.floatingDockBarrierTouchActive = NO;
    [self setFloatingDockRoutingSuppressed:NO];
    self.floatingOpenTargetDocked = NO;
    self.floatingCloseCleanupDone = NO;
    self.floatingCloseKeepApplication = keepApplication;
    NSUInteger closeToken = self.floatingActiveCloseToken;
    if (!continuingCommittedClose) {
        self.floatingCloseTokenCounter += 1;
        if (self.floatingCloseTokenCounter == 0) {
            self.floatingCloseTokenCounter = 1;
        }
        closeToken = self.floatingCloseTokenCounter;
        self.floatingActiveCloseToken = closeToken;
        self.floatingKeyboardCloseState = FLMFloatingKeyboardCloseStateCommit;
    } else {
        self.floatingCloseKeepApplication = YES;
    }
    FLMEnqueueDiagnosticLine(
        @"sb centered-close begin closeToken=%lu keep=%d app=%@ scene=%@ launchGen=%lu session=%lu keyboardVisible=%d interaction=%d host=%p forwardingKey=%d queuedTarget=%@",
        (unsigned long)closeToken,
        keepApplication, self.floatingIdentifier ?: @"<none>",
        FLMSceneIdentifier(self.floatingScene) ?: @"<none>",
        (unsigned long)self.floatingLaunchGeneration,
        (unsigned long)self.floatingKeyboardSessionGeneration,
        self.floatingKeyboardVisible,
        self.floatingKeyboardInteractionSessionActive,
        (__bridge void *)self.floatingKeyboardLayerHostView,
        self.keyboardForwardingWindow.isKeyWindow,
        self.floatingQueuedIdentifier ?: @"<none>");
    if (!self.floatingCloseDeferKeyboardSessionEnd) {
        [self endFloatingKeyboardSession];
    } else {
        FLMEnqueueDiagnosticLine(
            @"sb centered-close session-end deferred=coordinated closeToken=%lu session=%lu",
            (unsigned long)closeToken,
            (unsigned long)self.floatingKeyboardSessionGeneration);
    }
    self.floatingLaunchGeneration += 1;
    self.floatingLaunchState = FLMFloatingLaunchStateClosing;
    self.floatingLaunchStartedAt = 0.0;
    self.floatingRevealRetryCount = 0;
    self.floatingScenePreparedAt = 0.0;
    self.floatingSceneUsesCardGeometry = NO;
    self.floatingSceneCardGeometryPending = NO;
    self.floatingSceneCardGeometryCommitted = NO;
    self.contentViewportCommitted = NO;
    [self.floatingInteractiveSnapshot removeFromSuperview];
    self.floatingInteractiveSnapshot = nil;
    self.floatingInteractiveSnapshotBackground = nil;
    self.floatingInteractiveSnapshotContent = nil;
    self.floatingFullscreenProgress = 0.0;
    self.floatingKeyboardInteractionGeneration += 1;
    self.floatingKeyboardInteractionSessionActive = NO;
    self.floatingInteractiveScenePrepared = NO;
    self.floatingInteractiveFullscreenTransition = NO;
    self.floatingDocked = NO;
    self.floatingDockHidden = NO;
    self.floatingDockHideGestureActive = NO;
    self.floatingDockTransitionActive = NO;
    self.floatingDockControlTransitionGeneration += 1;
    self.floatingDockControlTransition =
        FLMFloatingDockControlTransitionNone;
    self.floatingDockControlTargetFrame = CGRectNull;
    self.floatingDockControlDefersKeyboardTeardown = NO;
    self.floatingDockInputSessionActive = NO;
    self.floatingDockInputMode = FLMFloatingDockInputModeNone;
    self.floatingDockInputTargetsResize = NO;
    self.floatingResizeCenterReady = NO;
    self.floatingResizeHandle.hidden = YES;
    self.floatingResizeHandle.userInteractionEnabled = NO;
    self.floatingExternalActivationArmed = NO;
    self.floatingFullscreenActivationArmed = NO;
    self.lastObservedFrontmostIdentifier = nil;
    self.floatingDockReady = NO;
    ((FLMFloatingWindow *)self.floatingWindow)
        .passesTouchesOutsideFloatingContent = NO;
    // Both close recognizers are disabled before any asynchronous animation
    // begins. The close token, not launchGeneration, owns this transaction.
    self.floatingBackdropTap.enabled = NO;
    self.floatingDockDragPress.enabled = NO;
    self.floatingDockInputGesture.enabled = NO;
    self.floatingDockInputGeneration += 1;
    [self updateFloatingDockTouchGate];
    self.floatingDockShadowView.hidden = YES;
    self.floatingDockShadowView.alpha = 0.0;
    self.floatingDockShadowView.transform = CGAffineTransformIdentity;
    self.floatingDockInteractionShield.hidden = YES;
    self.floatingDockInteractionShield.userInteractionEnabled = NO;
    self.floatingHandle.hidden = NO;
    self.floatingContainer.layer.borderWidth = 0.0;
    self.floatingContainer.transform = CGAffineTransformIdentity;
    id scene = self.floatingScene;
    id presenter = self.floatingPresenter;
    UIView *host = self.floatingHostView;
    UIWindow *previousKeyWindow = self.previousKeyWindow;
    self.floatingClosingScene = scene;
    self.floatingClosingPresenter = presenter;
    self.floatingClosingHostView = host;
    self.floatingSceneEntity = nil;
    self.floatingSceneHandle = nil;
    self.floatingScene = nil;
    self.floatingHostReferenceSize = CGSizeZero;
    self.floatingPresentationManager = nil;
    self.floatingPresenter = nil;
    self.floatingPresenterScene = nil;
    self.floatingPresenterUnavailableAt = 0.0;
    self.floatingPresenterRetryAttempt = 0;
    self.floatingIdentifier = nil;
    self.floatingExclusiveGesture.enabled = NO;
    self.floatingExclusiveTapEligible = NO;
    self.cornerGuardGesture.enabled = self.enabled;
    self.cornerGesture.enabled = self.enabled;
    self.previousKeyWindow = nil;
    self.floatingKeyboardVisible = NO;
    self.floatingKeyboardFrame = CGRectNull;
    self.floatingBackdropTap.additionalProtectedFrame = CGRectNull;
    ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame = CGRectNull;
    if (previousKeyWindow && previousKeyWindow != self.floatingWindow) {
        [previousKeyWindow makeKeyWindow];
    }
    if (self.floatingWindow.hidden) {
        [self finishFloatingCloseWithToken:closeToken];
        return;
    }

    [UIView animateWithDuration:0.24
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         self.floatingDimView.alpha = 0.0;
                          self.floatingContainer.alpha = 0.0;
                          self.floatingHandle.alpha = 0.0;
                          self.floatingDockShadowView.alpha = 0.0;
                      }
                     completion:^(BOOL finished) {
                         (void)finished;
                         [self finishFloatingCloseWithToken:closeToken];
                     }];
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(FLMFloatingCloseFallbackDelay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [self finishFloatingCloseWithToken:closeToken];
        });
}

- (void)finishFloatingCloseWithToken:(NSUInteger)token {
    if (!self.floatingCloseInProgress ||
        token != self.floatingActiveCloseToken) {
        FLMEnqueueDiagnosticLine(
            @"sb centered-close stale-completion token=%lu active=%lu inProgress=%d",
            (unsigned long)token, (unsigned long)self.floatingActiveCloseToken,
            self.floatingCloseInProgress);
        return;
    }
    if (self.floatingCloseCleanupDone) {
        FLMEnqueueDiagnosticLine(
            @"sb centered-close cleanup-no-op token=%lu reason=already-cleaned",
            (unsigned long)token);
        return;
    }
    self.floatingCloseCleanupDone = YES;
    id scene = self.floatingClosingScene;
    id presenter = self.floatingClosingPresenter;
    UIView *host = self.floatingClosingHostView;
    BOOL keepApplication = self.floatingCloseKeepApplication;
    NSString *queuedIdentifier = [self.floatingQueuedIdentifier copy];
    [host removeFromSuperview];
    FLMEnqueueDiagnosticLine(
        @"sb centered-close host-cleanup closeToken=%lu host=%p",
        (unsigned long)token, (__bridge void *)host);
    // Remove alternate/quarantined keyboard surfaces before the coordinated
    // session publishes its avoidance/geometry clear. The app responder has
    // already been resigned and the forwarding window was stopped before this
    // finalizer was entered.
    [self discardAllFloatingKeyboardHostQuarantinesForReason:
              @"centered-close"];
    [self discardFloatingKeyboardLayerHost];
    if (keepApplication) {
        [self backgroundFloatingScene:scene];
    } else {
        FLMClearProtectedScene(scene);
    }
    if (self.floatingCloseDeferKeyboardSessionEnd) {
        [self endFloatingKeyboardSession];
        FLMEnqueueDiagnosticLine(
            @"sb centered-close coordinated-session-end closeToken=%lu",
            (unsigned long)token);
    }
    self.floatingHostView = nil;
    @try {
        if ([presenter respondsToSelector:@selector(deactivate)]) {
            [presenter deactivate];
        }
        if ([presenter respondsToSelector:@selector(invalidate)]) {
            [presenter invalidate];
        }
    } @catch (__unused NSException *exception) {
    }
    self.floatingClosingScene = nil;
    self.floatingClosingPresenter = nil;
    self.floatingClosingHostView = nil;
    self.floatingQueuedIdentifier = nil;
    NSString *queuedFullscreenIdentifier =
        [self.floatingQueuedFullscreenIdentifier copy];
    self.floatingQueuedFullscreenIdentifier = nil;
    self.floatingWindow.hidden = YES;
    [self updateFloatingDockTouchGate];
    self.floatingLaunchState = FLMFloatingLaunchStateIdle;
    self.floatingDimView.alpha = 1.0;
    self.floatingContainer.alpha = 1.0;
    self.floatingContainer.transform = CGAffineTransformIdentity;
    self.floatingHandle.alpha = 1.0;
    self.floatingLaunchCoverView.hidden = YES;
    self.floatingLaunchCoverView.alpha = 1.0;
    self.floatingLaunchCoverView.userInteractionEnabled = NO;
    self.floatingLaunchIconView.image = nil;
    self.floatingStatusLabel.hidden = YES;
    self.floatingKeyboardCloseState = FLMFloatingKeyboardCloseStateIdle;
    self.floatingKeyboardDismissCloseToken = 0;
    self.floatingKeyboardDismissSessionGeneration = 0;
    self.floatingKeyboardDismissResult = FLMKeyboardDismissResultNone;
    self.floatingKeyboardDismissAckPhase = FLMKeyboardDismissAckPhaseNone;
    self.floatingKeyboardAppDismissClaimed = NO;
    self.floatingKeyboardAppResponderActionStarted = NO;
    self.floatingKeyboardCloseAbortReason = nil;
    self.floatingKeyboardSettlementFrameHidden = NO;
    self.floatingKeyboardSettlementDidHide = NO;
    self.floatingKeyboardDismissAdapterPID = 0;
    self.floatingKeyboardCloseContext = nil;
    self.floatingCloseCommitInProgress = NO;
    self.floatingCloseDeferKeyboardSessionEnd = NO;
    self.floatingCloseInProgress = NO;
    self.floatingActiveCloseToken = 0;
    self.floatingFullscreenActivationArmed = NO;
    FLMEnqueueDiagnosticLine(
        @"sb centered-close cleanup-once token=%lu scene=%@ presenter=%p queuedTarget=%@",
        (unsigned long)token, FLMSceneIdentifier(scene) ?: @"<none>",
        (__bridge void *)presenter,
        queuedFullscreenIdentifier ?: queuedIdentifier ?: @"<none>");
    [self stopLockMonitoringIfIdle];
    if (queuedFullscreenIdentifier.length > 0 && !FLMDeviceIsLocked()) {
        FLMEnqueueDiagnosticLine(
            @"sb fullscreen-fallback dequeue target=%@ closeToken=%lu",
            queuedFullscreenIdentifier, (unsigned long)token);
        [self activateIdentifierFullscreen:queuedFullscreenIdentifier];
    } else if (queuedIdentifier.length > 0 && !FLMDeviceIsLocked()) {
        // This call occurs only after host removal, Scene background/protection
        // release, and presenter invalidate have all completed.
        FLMEnqueueDiagnosticLine(
            @"sb centered-open dequeue target=%@ closeToken=%lu",
            queuedIdentifier, (unsigned long)token);
        [self openFloatingIdentifier:queuedIdentifier];
    }
}

- (void)beginLockMonitoring {
    if (self.lockMonitorTimer.valid) {
        return;
    }
    self.lockMonitorTimer =
        [NSTimer timerWithTimeInterval:0.35
                               target:self
                             selector:@selector(checkLockState:)
                             userInfo:nil
                              repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.lockMonitorTimer
                              forMode:NSRunLoopCommonModes];
}

- (void)stopLockMonitoringIfIdle {
    if (self.wheelPinned || !self.floatingWindow.hidden) {
        return;
    }
    [self.lockMonitorTimer invalidate];
    self.lockMonitorTimer = nil;
}

- (void)checkLockState:(NSTimer *)timer {
    (void)timer;
    // The timer runs in common modes, so without this guard its private
    // frontmost/lock queries can execute in the middle of a display-linked
    // drag.  The repeating timer performs the deferred check on its next tick
    // after the gesture/settle transition becomes idle.
    if (self.floatingDockInputSessionActive ||
        self.floatingDockGlobalDragActivated ||
        self.floatingDockHideGestureActive ||
        self.floatingDockTransitionActive ||
        self.floatingDockContentTailProtected) {
        return;
    }
    [self refreshWheelPriorityWindow];
    if (self.floatingDocked && !self.floatingWindow.hidden &&
        self.floatingIdentifier.length > 0) {
        NSString *frontmostIdentifier = FLMFrontmostApplicationIdentifier();
        BOOL targetIsFrontmost =
            [frontmostIdentifier isEqualToString:self.floatingIdentifier];
        BOOL targetWasFrontmost =
            [self.lastObservedFrontmostIdentifier
                isEqualToString:self.floatingIdentifier];
        if (!targetIsFrontmost) {
            self.floatingExternalActivationArmed = YES;
        }
        self.lastObservedFrontmostIdentifier = frontmostIdentifier;
        if (self.floatingExternalActivationArmed && targetIsFrontmost &&
            !targetWasFrontmost) {
            // The docked app was opened by SpringBoard. Release only our
            // presenter; backgrounding here would black out the fullscreen app.
            self.floatingReconnectSuppressed = YES;
            [self closeFloatingWindowKeepingApplication:NO];
            return;
        }
    }
    if (!FLMDeviceIsLocked()) {
        [self stopLockMonitoringIfIdle];
        return;
    }
    if (self.wheelPinned || !self.overlayWindow.hidden) {
        [self dismissWheelLaunchingItem:nil];
    }
    if (!self.floatingWindow.hidden) {
        [self closeFloatingWindowKeepingApplication:YES];
    }
}

- (void)activateIdentifierFullscreen:(NSString *)identifier {
    if (identifier.length == 0) {
        return;
    }
    NSString *bundleIdentifier = [identifier copy];
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(FLMFloatingFullscreenActivationDelay *
                                NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            UIApplication *application = [UIApplication sharedApplication];
            if ([application respondsToSelector:
                             @selector(launchApplicationWithIdentifier:suspended:)] &&
                [application launchApplicationWithIdentifier:bundleIdentifier
                                                   suspended:NO]) {
                return;
            }
            id workspace =
                [NSClassFromString(@"LSApplicationWorkspace") defaultWorkspace];
            if ([workspace respondsToSelector:
                              @selector(openApplicationWithBundleID:)]) {
                [workspace openApplicationWithBundleID:bundleIdentifier];
            }
        });
}

- (void)activateIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:FLYME_LOCK_SCREEN_ITEM]) {
        UIApplication *application = [UIApplication sharedApplication];
        if ([application respondsToSelector:@selector(_simulateLockButtonPress)]) {
            [application _simulateLockButtonPress];
            return;
        }
        id manager = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
        if ([manager respondsToSelector:@selector(lockUIFromSource:withOptions:)]) {
            [manager lockUIFromSource:1 withOptions:nil];
        }
        return;
    }
    if (!self.floatingWindow.hidden && self.floatingIdentifier.length > 0 &&
        [identifier isEqualToString:self.floatingIdentifier]) {
        // The wheel target is the app already sitting in the card. Dismiss the
        // card and promote the running app straight to fullscreen instead of
        // swallowing the request.
        self.prewarmedIdentifier = nil;
        if (self.floatingCloseInProgress) {
            self.floatingQueuedFullscreenIdentifier = [identifier copy];
            return;
        }
        FLMEnqueueDiagnosticLine(
            @"sb wheel-promote target=%@ closeToken=%lu card=%@",
            identifier, (unsigned long)self.floatingActiveCloseToken,
            self.floatingDocked
                ? (self.floatingDockHidden ? @"hidden" : @"docked")
                : @"centered");
        self.floatingQueuedFullscreenIdentifier = [identifier copy];
        [self closeFloatingWindowKeepingApplication:YES];
        return;
    }
    if ([identifier isEqualToString:FLMFrontmostApplicationIdentifier()]) {
        self.prewarmedIdentifier = nil;
        return;
    }
    [self openFloatingIdentifier:identifier];
}

@end

static BOOL FLMHomeDockZoneHitTest(CGRect bounds, CGPoint point) {
    FLMWheelController *controller = [FLMWheelController sharedController];
    if (!controller.enabled || controller.wheelPinned ||
        !controller.floatingWindow.hidden || controller.floatingCloseInProgress ||
        FLMDeviceIsLocked()) {
        return NO;
    }
    if (point.x < CGRectGetMinX(bounds) + CGRectGetWidth(bounds) * 0.30 ||
        point.x > CGRectGetMinX(bounds) + CGRectGetWidth(bounds) * 0.70 ||
        point.y < CGRectGetMaxY(bounds) - 100.0) {
        return NO;
    }
    NSString *frontmost = FLMFrontmostApplicationIdentifier();
    if (frontmost.length == 0 ||
        [frontmost isEqualToString:@"com.apple.springboard"] ||
        [frontmost isEqualToString:FLYME_LOCK_SCREEN_ITEM]) {
        return NO;
    }
    return YES;
}

%hook _UIKeyboardLayerHostView

- (void)scene:(id)scene
    didUpdateClientSettingsWithDiff:(id)diff
                  oldClientSettings:(id)oldClientSettings
                  transitionContext:(id)transitionContext {
    %orig;
    (void)diff;
    (void)oldClientSettings;
    (void)transitionContext;

    // UIKit must finish its private keyboard Scene transaction before the host
    // changes superviews.  Moving it synchronously is what leaves the remote
    // keyboard half-paired and makes keys or the collapse control stop routing.
    FLMWheelController *controller = [FLMWheelController sharedController];
    NSUInteger sessionGeneration =
        controller.floatingKeyboardSessionGeneration;
    FLMEnqueueDiagnosticLine(
        @"sb host-hook callback host=%p updatedScene=%@ session=%lu",
        (__bridge void *)self, FLMSceneIdentifier(scene) ?: @"<none>",
        (unsigned long)sessionGeneration);
    __weak UIView *weakHostView = (UIView *)self;
    __weak id weakUpdatedScene = scene;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *hostView = weakHostView;
        id updatedScene = weakUpdatedScene;
        if (!hostView) {
            FLMEnqueueDiagnosticLine(
                @"sb host-hook expired updatedScene=%@ session=%lu",
                FLMSceneIdentifier(updatedScene) ?: @"<none>",
                (unsigned long)sessionGeneration);
            return;
        }
        [controller keyboardLayerHostView:hostView
                        didUpdateForScene:updatedScene
                        sessionGeneration:sessionGeneration];
    });
}

%end

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    (void)application;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [[FLMWheelController sharedController] start];
                   });
    // Diagnostics are deliberately initialized after SpringBoard launch and
    // away from keyboard host callbacks. UIKit clients only publish compact
    // Darwin events; this process is the sole asynchronous file writer.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       FLMStartDiagnosticWriter();
                       FLMPublishDiagnosticEvent(
                           FLMDiagnosticRoleSpringBoard,
                           FLMDiagnosticEventProcessReady,
                           0,
                           (uint16_t)(getpid() & 0xFFFF),
                           0);
                   });
}

%end

%ctor {
    if (notify_register_check(FLYME_RUNTIME_NOTIFICATION, &FlymeRuntimeToken) ==
        NOTIFY_STATUS_OK) {
        uint64_t state = (FLYME_RUNTIME_MAGIC << 32) | (uint32_t)getpid();
        notify_set_state(FlymeRuntimeToken, state);
        notify_post(FLYME_RUNTIME_NOTIFICATION);
    }
}
