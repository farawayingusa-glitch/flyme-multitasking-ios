#ifndef FLM_DIAGNOSTICS_H
#define FLM_DIAGNOSTICS_H

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <notify.h>
#import <stdint.h>


// The SpringBoard owner restores the persisted setting at launch. Readers use
// notify_check's shared-memory change flag; no preference I/O on hot paths.
#import <os/lock.h>
#define FLYME_DIAGNOSTIC_CAPTURE_NOTIFICATION \
    "com.codex.flymemultitasking.diagnostic-capture-v1"

static inline BOOL FLMDiagnosticCaptureEnabled(void) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static int token = -1;
    static BOOL enabled = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (notify_register_check(FLYME_DIAGNOSTIC_CAPTURE_NOTIFICATION,
                                  &token) != NOTIFY_STATUS_OK) token = -1;
    });
    os_unfair_lock_lock(&lock);
    int changed = 0;
    if (token >= 0 && notify_check(token, &changed) == NOTIFY_STATUS_OK && changed) {
        uint64_t state = 0;
        enabled = notify_get_state(token, &state) == NOTIFY_STATUS_OK && state == 1;
    }
    BOOL result = enabled;
    os_unfair_lock_unlock(&lock);
    return result;
}

static inline void FLMSetDiagnosticCaptureState(BOOL enabled) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (notify_register_check(FLYME_DIAGNOSTIC_CAPTURE_NOTIFICATION,
                                  &token) != NOTIFY_STATUS_OK) token = -1;
    });
    if (token >= 0) {
        if (notify_set_state(token, enabled ? 1 : 0) == NOTIFY_STATUS_OK)
            notify_post(FLYME_DIAGNOSTIC_CAPTURE_NOTIFICATION);
    }
}

// Guard at the call site so expensive diagnostic arguments are not evaluated.
#define FLMDiagnosticLog(...) do { \
    if (FLMDiagnosticCaptureEnabled()) FLMEnqueueDiagnosticLine(__VA_ARGS__); \
} while (0)
#define FLMDiagnosticNSLog(...) do { \
    if (FLMDiagnosticCaptureEnabled()) NSLog(__VA_ARGS__); \
} while (0)

// SpringBoard owns the diagnostic writer. Auxiliary SpringBoard modules may
// enqueue lines through this function without creating another file writer.
void FLMEnqueueDiagnosticLine(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

#define FLYME_DIAGNOSTIC_EVENT_NOTIFICATION \
    "com.codex.flymemultitasking.diagnostic-event-v2"
#define FLYME_DIAGNOSTIC_SPRINGBOARD_NOTIFICATION \
    "com.codex.flymemultitasking.diagnostic-springboard-v3"
#define FLYME_DIAGNOSTIC_APPLICATION_NOTIFICATION \
    "com.codex.flymemultitasking.diagnostic-application-v3"
#define FLYME_DIAGNOSTIC_KEYBOARD_NOTIFICATION \
    "com.codex.flymemultitasking.diagnostic-keyboard-v3"
#define FLYME_DIAGNOSTIC_UIKIT_OTHER_NOTIFICATION \
    "com.codex.flymemultitasking.diagnostic-uikit-other-v3"

// SpringBoard publishes one exact application target while Dock control owns
// the card.  The selected application reads this state synchronously at its
// UIApplication event boundary, so a remote Scene cannot receive the same
// touch stream that is controlling the Dock card.
#define FLYME_DOCK_INPUT_BLOCK_NOTIFICATION \
    "com.codex.flymemultitasking.dock-input-block-v1"
#define FLYME_DOCK_INPUT_BLOCK_ACTIVE_MASK (UINT64_C(1) << 63)

static inline uint64_t FLMDockInputBlockState(uint64_t identifierHash,
                                              BOOL blocked) {
    if (!blocked || identifierHash == 0) {
        return 0;
    }
    return FLYME_DOCK_INPUT_BLOCK_ACTIVE_MASK |
           (identifierHash & ~FLYME_DOCK_INPUT_BLOCK_ACTIVE_MASK);
}

static inline BOOL FLMDockInputBlockStateMatches(uint64_t state,
                                                 uint64_t identifierHash) {
    return identifierHash != 0 &&
           (state & FLYME_DOCK_INPUT_BLOCK_ACTIVE_MASK) != 0 &&
           (state & ~FLYME_DOCK_INPUT_BLOCK_ACTIVE_MASK) ==
               (identifierHash & ~FLYME_DOCK_INPUT_BLOCK_ACTIVE_MASK);
}

typedef NS_ENUM(uint8_t, FLMDiagnosticRole) {
    FLMDiagnosticRoleSpringBoard = 1,
    FLMDiagnosticRoleApplication = 2,
    FLMDiagnosticRoleKeyboardExtension = 3,
    FLMDiagnosticRoleUIKitOther = 4,
};

typedef NS_ENUM(uint8_t, FLMDiagnosticEvent) {
    FLMDiagnosticEventProcessReady = 1,
    FLMDiagnosticEventRouteReload = 2,
    FLMDiagnosticEventResponderBecome = 3,
    FLMDiagnosticEventResponderResign = 4,
    FLMDiagnosticEventFramePublish = 5,
    FLMDiagnosticEventFrameObserved = 6,
    FLMDiagnosticEventFrameCorrected = 7,
    FLMDiagnosticEventCardGeometry = 8,
    FLMDiagnosticEventAvoidanceReload = 9,
    FLMDiagnosticEventIntersection = 10,
    FLMDiagnosticEventDismissRequest = 11,
    FLMDiagnosticEventWillHide = 12,
    FLMDiagnosticEventDidHide = 13,
    FLMDiagnosticEventSceneMatch = 14,
    FLMDiagnosticEventLayoutRefresh = 15,
    FLMDiagnosticEventRouteReady = 16,
    FLMDiagnosticEventDismissAck = 17,
    FLMDiagnosticEventAdapterLoaded = 18,
    FLMDiagnosticEventAdapterCtor = 19,
    FLMDiagnosticEventAdapterReady = 20,
    FLMDiagnosticEventInputSuppressed = 21,
    // Resolved keyboard route tuple: a = low 16 bits of the published target
    // hash, b = low 16 bits of this process' own hash. Published from the App
    // side so a route that never matched can be read straight out of the log.
    FLMDiagnosticEventRouteTuple = 22,
};

// Cross-process diagnostics intentionally carry only fixed-width integers.
// UIKit clients and third-party keyboard extensions never perform file I/O;
// SpringBoard is the sole log writer after its launch has completed.
static inline void FLMPublishDiagnosticEvent(FLMDiagnosticRole role,
                                             FLMDiagnosticEvent event,
                                             uint64_t sessionGeneration,
                                             uint16_t firstValue,
                                             uint16_t secondValue) {
    if (!FLMDiagnosticCaptureEnabled()) return;
    static int springBoardToken = -1;
    static int applicationToken = -1;
    static int keyboardToken = -1;
    static int uiKitOtherToken = -1;
    static dispatch_once_t springBoardOnceToken;
    static dispatch_once_t applicationOnceToken;
    static dispatch_once_t keyboardOnceToken;
    static dispatch_once_t uiKitOtherOnceToken;
    int *eventToken = &uiKitOtherToken;
    dispatch_once_t *onceToken = &uiKitOtherOnceToken;
    const char *notificationName = FLYME_DIAGNOSTIC_UIKIT_OTHER_NOTIFICATION;
    switch (role) {
        case FLMDiagnosticRoleSpringBoard:
            eventToken = &springBoardToken;
            onceToken = &springBoardOnceToken;
            notificationName = FLYME_DIAGNOSTIC_SPRINGBOARD_NOTIFICATION;
            break;
        case FLMDiagnosticRoleApplication:
            eventToken = &applicationToken;
            onceToken = &applicationOnceToken;
            notificationName = FLYME_DIAGNOSTIC_APPLICATION_NOTIFICATION;
            break;
        case FLMDiagnosticRoleKeyboardExtension:
            eventToken = &keyboardToken;
            onceToken = &keyboardOnceToken;
            notificationName = FLYME_DIAGNOSTIC_KEYBOARD_NOTIFICATION;
            break;
        case FLMDiagnosticRoleUIKitOther:
        default:
            break;
    }
    dispatch_once(onceToken, ^{
        if (notify_register_check(notificationName, eventToken) !=
            NOTIFY_STATUS_OK) {
            *eventToken = -1;
        }
    });
    if (*eventToken < 0) {
        return;
    }
    uint64_t state = ((uint64_t)event << 56) |
                     ((uint64_t)role << 48) |
                     ((sessionGeneration & 0xFFFFULL) << 32) |
                     ((uint64_t)firstValue << 16) |
                     (uint64_t)secondValue;
    notify_set_state(*eventToken, state);
    notify_post(notificationName);
}

static inline uint16_t FLMDiagnosticUnsignedValue(CGFloat value) {
    if (!isfinite(value) || value <= 0.0) {
        return 0;
    }
    return (uint16_t)MIN(65535.0, llround(value));
}

#endif
