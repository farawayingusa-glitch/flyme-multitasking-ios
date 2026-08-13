#ifndef FLM_DIAGNOSTICS_H
#define FLM_DIAGNOSTICS_H

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <notify.h>
#import <stdint.h>

// SpringBoard owns the diagnostic writer. Auxiliary SpringBoard modules may
// enqueue lines through this function without creating another file writer.
void FLMEnqueueDiagnosticLine(NSString *format, ...);

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
};

// Cross-process diagnostics intentionally carry only fixed-width integers.
// UIKit clients and third-party keyboard extensions never perform file I/O;
// SpringBoard is the sole log writer after its launch has completed.
static inline void FLMPublishDiagnosticEvent(FLMDiagnosticRole role,
                                             FLMDiagnosticEvent event,
                                             uint64_t sessionGeneration,
                                             uint16_t firstValue,
                                             uint16_t secondValue) {
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
