#import <UIKit/UIKit.h>
#import <math.h>
#import <notify.h>
#import <unistd.h>

#import "FLMDiagnostics.h"

#define FLYME_KEYBOARD_NOTIFICATION "com.codex.flymemultitasking.keyboard-state-changed"
#define FLYME_KEYBOARD_SCENE_NOTIFICATION "com.codex.flymemultitasking.keyboard-scene-changed"
#define FLYME_KEYBOARD_SESSION_NOTIFICATION "com.codex.flymemultitasking.keyboard-session-changed"
#define FLYME_KEYBOARD_FRAME_NOTIFICATION "com.codex.flymemultitasking.keyboard-frame-changed"
#define FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION "com.codex.flymemultitasking.keyboard-avoidance-changed"
#define FLYME_KEYBOARD_CARD_GEOMETRY_NOTIFICATION "com.codex.flymemultitasking.keyboard-card-geometry-changed"
#define FLYME_KEYBOARD_ROUTE_ACK_NOTIFICATION "com.codex.flymemultitasking.keyboard-route-ready"
#define FLYME_KEYBOARD_DISMISS_NOTIFICATION "com.codex.flymemultitasking.keyboard-dismiss-requested"
#define FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION "com.codex.flymemultitasking.keyboard-dismiss-acknowledged"

static BOOL FLMKeyboardRouteActive = NO;
static BOOL FLMKeyboardTargetApplication = NO;
static BOOL FLMKeyboardExtensionProcess = NO;
static int FLMKeyboardRouteToken = -1;
static int FLMKeyboardSceneToken = -1;
static int FLMKeyboardSessionToken = -1;
static int FLMKeyboardFrameToken = -1;
static int FLMKeyboardAvoidanceToken = -1;
static int FLMKeyboardCardGeometryToken = -1;
static int FLMKeyboardRouteAckToken = -1;
static int FLMKeyboardDismissToken = -1;
static int FLMKeyboardDismissAckToken = -1;
static uint64_t FLMKeyboardTargetSceneHash = 0;
static uint64_t FLMKeyboardSessionGeneration = 0;
static uint64_t FLMKeyboardEndedSessionGeneration = 0;
static uint64_t FLMKeyboardDismissRequestedGeneration = 0;
static uint64_t FLMExternalKeyboardAvoidanceGeneration = 0;
static CGFloat FLMExternalKeyboardAvoidanceHeight = 0.0;
static __weak UIResponder *FLMKeyboardActiveTextResponder = nil;
static id FLMKeyboardWillHideObserver = nil;
static id FLMKeyboardHideObserver = nil;
static BOOL FLMEndingApplicationKeyboardSession = NO;
static BOOL FLMRemoteKeyboardGeometryInstalled = NO;
static BOOL FLMKeyboardCardGeometryActive = NO;
static BOOL FLMDeliveringCorrectedKeyboardNotification = NO;
static uint64_t FLMKeyboardCardGeometryGeneration = 0;
static CGFloat FLMKeyboardCardBottom = 0.0;
static CGFloat FLMKeyboardCardVisualScale = 0.0;

static FLMDiagnosticRole FLMKeyboardDiagnosticRole(void) {
    if (FLMKeyboardExtensionProcess) {
        return FLMDiagnosticRoleKeyboardExtension;
    }
    if (FLMKeyboardTargetApplication) {
        return FLMDiagnosticRoleApplication;
    }
    return FLMDiagnosticRoleUIKitOther;
}

static void FLMRefreshApplicationKeyboardLayout(void);
static void FLMInstallRemoteKeyboardGeometryIfAvailable(void);
static void FLMReloadKeyboardAvoidance(void);
static void FLMReloadKeyboardCardGeometry(void);

static void FLMPublishSessionState(const char *notificationName,
                                   int *token,
                                   uint64_t sessionGeneration) {
    if (!notificationName || !token || sessionGeneration == 0) {
        return;
    }
    if (*token < 0 &&
        notify_register_check(notificationName, token) != NOTIFY_STATUS_OK) {
        return;
    }
    notify_set_state(*token, sessionGeneration);
    notify_post(notificationName);
}

static void FLMPublishKeyboardDismissAck(uint64_t sessionGeneration) {
    FLMPublishDiagnosticEvent(
        FLMDiagnosticRoleApplication,
        FLMDiagnosticEventDismissAck,
        sessionGeneration,
        FLMKeyboardActiveTextResponder ? 1 : 0,
        FLMEndingApplicationKeyboardSession ? 1 : 0);
    FLMPublishSessionState(FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION,
                           &FLMKeyboardDismissAckToken,
                           sessionGeneration);
}

static BOOL FLMProcessIsKeyboardExtension(void) {
    NSDictionary *extension =
        [NSBundle mainBundle].infoDictionary[@"NSExtension"];
    NSString *pointIdentifier =
        [extension isKindOfClass:[NSDictionary class]]
            ? extension[@"NSExtensionPointIdentifier"]
            : nil;
    return [pointIdentifier isKindOfClass:[NSString class]] &&
           [pointIdentifier rangeOfString:@"keyboard-service"
                                  options:NSCaseInsensitiveSearch].location !=
               NSNotFound;
}

static CGSize FLMFullPhysicalScreenSize(void) {
    UIScreen *screen = [UIScreen mainScreen];
    CGRect nativeBounds = screen.nativeBounds;
    CGFloat scale = screen.nativeScale;
    if (scale <= 0.0) {
        scale = screen.scale;
    }
    if (scale <= 0.0) {
        scale = 1.0;
    }
    CGFloat width = CGRectGetWidth(nativeBounds) / scale;
    CGFloat height = CGRectGetHeight(nativeBounds) / scale;
    if (width > height) {
        CGFloat value = width;
        width = height;
        height = value;
    }
    if (width < 1.0 || height < 1.0) {
        CGRect bounds = screen.bounds;
        width = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
        height = MAX(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    }
    return CGSizeMake(width, height);
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

static NSString *FLMSceneIdentifier(UIWindowScene *scene) {
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        return nil;
    }
    @try {
        SEL selector = NSSelectorFromString(@"sceneIdentifier");
        if ([scene respondsToSelector:selector]) {
            id (*getter)(id, SEL) =
                (id (*)(id, SEL))[scene methodForSelector:selector];
            id value = getter ? getter(scene, selector) : nil;
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return value;
            }
        }
        NSString *persistentIdentifier = scene.session.persistentIdentifier;
        if (persistentIdentifier.length > 0) {
            return persistentIdentifier;
        }
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static BOOL FLMSceneMatchesKeyboardRoute(UIWindowScene *scene) {
    if (!FLMKeyboardRouteActive ||
        ![scene isKindOfClass:[UIWindowScene class]]) {
        return NO;
    }
    if (FLMKeyboardTargetSceneHash == 0) {
        return YES;
    }
    // A third-party keyboard extension owns a remote keyboard Scene, not the
    // target application's UIWindowScene identifier. The active Darwin
    // session already limits this route to the selected keyboard lifetime;
    // do not query UIApplication from an extension process.
    if (FLMKeyboardExtensionProcess) {
        return YES;
    }
    uint64_t currentHash = FLMIdentifierHash(FLMSceneIdentifier(scene));
    // Some iOS 16 app scenes hide their private sceneIdentifier until the
    // first keyboard transaction. The process-level bundle route is still a
    // safer fallback than leaving the keyboard trapped in the card.
    if (currentHash == 0 || currentHash == FLMKeyboardTargetSceneHash) {
        return YES;
    }

    // SpringBoard's private sceneIdentifier and the application process's
    // UISceneSession persistentIdentifier are not guaranteed to be the same
    // string on iOS 16. The bundle route already limits this tweak to the one
    // target application process, so accept its connected UIWindowScene as a
    // safe process-local fallback instead of silently skipping all avoidance.
    NSSet<UIScene *> *connectedScenes =
        [UIApplication sharedApplication].connectedScenes;
    for (UIScene *connectedScene in connectedScenes) {
        if (connectedScene == scene) {
            return YES;
        }
    }
    return connectedScenes.count <= 1;
}

static CGRect FLMPhysicalReferenceBoundsForScene(UIWindowScene *scene) {
    CGSize size = FLMFullPhysicalScreenSize();
    if ([scene isKindOfClass:[UIWindowScene class]] &&
        UIInterfaceOrientationIsLandscape(scene.interfaceOrientation)) {
        size = CGSizeMake(size.height, size.width);
    }
    return CGRectMake(0.0, 0.0, size.width, size.height);
}

static BOOL FLMResignFirstResponderInView(UIView *view) {
    if (!view) {
        return NO;
    }
    BOOL resigned = NO;
    @try {
        if (view.isFirstResponder) {
            resigned = [view resignFirstResponder] || resigned;
        }
        for (UIView *subview in [view.subviews copy]) {
            resigned = FLMResignFirstResponderInView(subview) || resigned;
        }
    } @catch (__unused NSException *exception) {
    }
    return resigned;
}

static void FLMEndApplicationKeyboardSession(void) {
    if (FLMEndingApplicationKeyboardSession) {
        return;
    }
    FLMEndingApplicationKeyboardSession = YES;
    UIResponder *activeResponder = FLMKeyboardActiveTextResponder;
    @try {
        if (activeResponder) {
            [activeResponder resignFirstResponder];
        }
    } @catch (__unused NSException *exception) {
    }
    if (@available(iOS 13.0, *)) {
        for (UIScene *connectedScene in
             [UIApplication sharedApplication].connectedScenes) {
            if (![connectedScene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)connectedScene).windows) {
                FLMResignFirstResponderInView(window);
                [window endEditing:YES];
            }
        }
    }
    [[UIApplication sharedApplication]
        sendAction:@selector(resignFirstResponder)
               to:nil
             from:nil
         forEvent:nil];
    FLMKeyboardActiveTextResponder = nil;
    FLMEndingApplicationKeyboardSession = NO;
}

static void FLMRefreshApplicationKeyboardLayout(void) {
    if (!FLMKeyboardTargetApplication) {
        return;
    }
    FLMPublishDiagnosticEvent(
        FLMDiagnosticRoleApplication,
        FLMDiagnosticEventLayoutRefresh,
        FLMKeyboardSessionGeneration,
        FLMDiagnosticUnsignedValue(FLMExternalKeyboardAvoidanceHeight),
        FLMKeyboardCardGeometryActive ? 1 : 0);
    for (UIScene *connectedScene in
         [UIApplication sharedApplication].connectedScenes) {
        if (![connectedScene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)connectedScene;
        if (!FLMSceneMatchesKeyboardRoute(windowScene)) {
            continue;
        }
        for (UIWindow *window in windowScene.windows) {
            [window setNeedsLayout];
            [window.rootViewController.view setNeedsLayout];
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!FLMKeyboardRouteActive) {
            return;
        }
        for (UIScene *connectedScene in
             [UIApplication sharedApplication].connectedScenes) {
            if (![connectedScene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            UIWindowScene *windowScene = (UIWindowScene *)connectedScene;
            if (!FLMSceneMatchesKeyboardRoute(windowScene)) {
                continue;
            }
            for (UIWindow *window in windowScene.windows) {
                [window layoutIfNeeded];
                [window.rootViewController.view layoutIfNeeded];
            }
        }
    });
}

static void FLMReloadKeyboardRoute(void) {
    uint64_t targetHash = 0;
    if (FLMKeyboardRouteToken >= 0) {
        notify_get_state(FLMKeyboardRouteToken, &targetHash);
    }
    NSString *currentIdentifier = [NSBundle mainBundle].bundleIdentifier;
    uint64_t currentHash = FLMIdentifierHash(currentIdentifier);
    BOOL previousRouteActive = FLMKeyboardRouteActive;
    BOOL previousTargetApplication = FLMKeyboardTargetApplication;
    uint64_t sessionGeneration = 0;
    if (FLMKeyboardSessionToken >= 0) {
        notify_get_state(FLMKeyboardSessionToken, &sessionGeneration);
    }
    uint64_t previousSessionGeneration = FLMKeyboardSessionGeneration;
    BOOL sessionChanged =
        sessionGeneration != previousSessionGeneration;
    FLMKeyboardSessionGeneration = sessionGeneration;
    FLMKeyboardTargetApplication =
        sessionGeneration != 0 && targetHash != 0 && currentHash != 0 &&
        targetHash == currentHash;
    FLMKeyboardExtensionProcess = FLMProcessIsKeyboardExtension();
    FLMKeyboardRouteActive =
        FLMKeyboardTargetApplication ||
        (sessionGeneration != 0 && targetHash != 0 &&
         FLMKeyboardExtensionProcess);
    FLMKeyboardTargetSceneHash = 0;
    if (FLMKeyboardSceneToken >= 0) {
        notify_get_state(FLMKeyboardSceneToken,
                         &FLMKeyboardTargetSceneHash);
    }
    if (sessionChanged) {
        FLMExternalKeyboardAvoidanceGeneration = 0;
        FLMExternalKeyboardAvoidanceHeight = 0.0;
        // Close any responder and keyboard Scene retained by the previous
        // centered card before the new generation is allowed to focus. This
        // does not depend on delivery of the
        // short-lived route-off notification between two openings.
        if (previousSessionGeneration != 0 && previousRouteActive &&
            previousTargetApplication) {
            FLMKeyboardEndedSessionGeneration = previousSessionGeneration;
            FLMEndApplicationKeyboardSession();
        }
        if (sessionGeneration != 0) {
            FLMKeyboardEndedSessionGeneration = 0;
        }
    }
    if (!FLMKeyboardTargetApplication) {
        FLMExternalKeyboardAvoidanceGeneration = 0;
        FLMExternalKeyboardAvoidanceHeight = 0.0;
    }
    FLMReloadKeyboardCardGeometry();
    uint16_t routeFlags =
        (FLMKeyboardRouteActive ? 1U : 0U) |
        (FLMKeyboardTargetApplication ? 2U : 0U) |
        (FLMKeyboardExtensionProcess ? 4U : 0U) |
        (sessionChanged ? 8U : 0U) |
        (previousRouteActive ? 16U : 0U) |
        (FLMKeyboardTargetSceneHash != 0 ? 32U : 0U);
    if (sessionChanged || FLMKeyboardRouteActive || previousRouteActive) {
        FLMPublishDiagnosticEvent(
            FLMKeyboardDiagnosticRole(),
            FLMDiagnosticEventRouteReload,
            FLMKeyboardSessionGeneration,
            routeFlags,
            (uint16_t)(targetHash & 0xFFFFULL));
    }
    if (FLMKeyboardTargetApplication && sessionGeneration != 0) {
        FLMPublishDiagnosticEvent(
            FLMDiagnosticRoleApplication,
            FLMDiagnosticEventRouteReady,
            sessionGeneration,
            FLMRemoteKeyboardGeometryInstalled ? 1 : 0,
            (uint16_t)(getpid() & 0xFFFF));
        FLMPublishSessionState(FLYME_KEYBOARD_ROUTE_ACK_NOTIFICATION,
                               &FLMKeyboardRouteAckToken,
                               sessionGeneration);
    }
}

static void FLMReloadKeyboardCardGeometry(void) {
    uint64_t state = 0;
    if (FLMKeyboardCardGeometryToken < 0 ||
        notify_get_state(FLMKeyboardCardGeometryToken, &state) !=
            NOTIFY_STATUS_OK) {
        return;
    }
    BOOL active = (state & (1ULL << 63)) != 0;
    uint64_t generation = (state >> 48) & 0x7FFFULL;
    CGFloat cardBottom = (CGFloat)((state >> 24) & 0xFFFFFFULL) / 100.0;
    CGFloat visualScale = (CGFloat)(state & 0xFFFFFFULL) / 1000000.0;
    BOOL currentSession =
        FLMKeyboardTargetApplication && active && generation != 0 &&
        generation == (FLMKeyboardSessionGeneration & 0x7FFFULL) &&
        cardBottom > 1.0 && visualScale > 0.05;
    FLMKeyboardCardGeometryActive = currentSession;
    FLMKeyboardCardGeometryGeneration = currentSession ? generation : 0;
    FLMKeyboardCardBottom = currentSession ? cardBottom : 0.0;
    FLMKeyboardCardVisualScale = currentSession ? visualScale : 0.0;
    if (FLMKeyboardTargetApplication || FLMKeyboardExtensionProcess) {
        FLMPublishDiagnosticEvent(
            FLMKeyboardDiagnosticRole(),
            FLMDiagnosticEventCardGeometry,
            FLMKeyboardSessionGeneration,
            FLMDiagnosticUnsignedValue(FLMKeyboardCardBottom),
            FLMDiagnosticUnsignedValue(FLMKeyboardCardVisualScale * 1000.0));
    }
}

static void FLMReloadKeyboardAvoidance(void) {
    uint64_t state = 0;
    if (FLMKeyboardAvoidanceToken < 0 ||
        notify_get_state(FLMKeyboardAvoidanceToken, &state) != NOTIFY_STATUS_OK) {
        return;
    }
    BOOL visible = (state & (1ULL << 63)) != 0;
    uint64_t sessionGeneration = (state >> 24) & 0x7FFFFFFFFFULL;
    CGFloat height = (CGFloat)(state & 0xFFFFFFULL) / 100.0;
    BOOL currentSession = FLMKeyboardTargetApplication && visible &&
                          sessionGeneration != 0 &&
                          sessionGeneration == FLMKeyboardSessionGeneration;
    if (!currentSession) {
        // FlymeKeyboard is injected into UIKit clients, including SpringBoard.
        // Never touch UIScreen/UIApplication from a dyld initializer or an
        // inactive route: iOS 16 asserts when +[UIScreen mainScreen] is used
        // before SpringBoard has finished creating its display environment.
        FLMExternalKeyboardAvoidanceGeneration = 0;
        FLMExternalKeyboardAvoidanceHeight = 0.0;
        FLMRefreshApplicationKeyboardLayout();
        if (FLMKeyboardRouteActive) {
            FLMPublishDiagnosticEvent(
                FLMKeyboardDiagnosticRole(),
                FLMDiagnosticEventAvoidanceReload,
                FLMKeyboardSessionGeneration,
                0,
                0);
        }
        return;
    }
    FLMExternalKeyboardAvoidanceGeneration = sessionGeneration;
    // SpringBoard already mapped the physical card/keyboard overlap into the
    // target Scene's logical coordinate space. Avoid another UIScreen query
    // here so this Darwin path stays safe during process initialization.
    FLMExternalKeyboardAvoidanceHeight = MAX(0.0, height);
    FLMPublishDiagnosticEvent(
        FLMDiagnosticRoleApplication,
        FLMDiagnosticEventAvoidanceReload,
        FLMKeyboardSessionGeneration,
        1,
        FLMDiagnosticUnsignedValue(FLMExternalKeyboardAvoidanceHeight));
    FLMRefreshApplicationKeyboardLayout();
}

%hook UIResponder

- (BOOL)becomeFirstResponder {
    BOOL routedTextInput =
        FLMKeyboardTargetApplication &&
        [self conformsToProtocol:@protocol(UITextInput)];
    if (routedTextInput) {
        FLMInstallRemoteKeyboardGeometryIfAvailable();
    }
    BOOL result = %orig;
    if (routedTextInput && result) {
        // Keep the concrete responder, not just its containing windows. Several
        // applications restore a text responder while their Scene is brought
        // forward again; window-wide endEditing alone does not reliably clear
        // that retained responder between centered-card generations.
        FLMKeyboardActiveTextResponder = self;
    }
    if (routedTextInput) {
        FLMPublishDiagnosticEvent(
            FLMDiagnosticRoleApplication,
            FLMDiagnosticEventResponderBecome,
            FLMKeyboardSessionGeneration,
            result ? 1 : 0,
            FLMRemoteKeyboardGeometryInstalled ? 1 : 0);
    }
    return result;
}

- (BOOL)resignFirstResponder {
    BOOL wasTracked = FLMKeyboardActiveTextResponder == self;
    BOOL result = %orig;
    if (result && FLMKeyboardActiveTextResponder == self) {
        FLMKeyboardActiveTextResponder = nil;
    }
    if (FLMKeyboardTargetApplication &&
        [self conformsToProtocol:@protocol(UITextInput)]) {
        FLMPublishDiagnosticEvent(
            FLMDiagnosticRoleApplication,
            FLMDiagnosticEventResponderResign,
            FLMKeyboardSessionGeneration,
            result ? 1 : 0,
            wasTracked ? 1 : 0);
    }
    return result;
}

%end

static void FLMPublishKeyboardFrame(CGRect frame, BOOL visible) {
    if (visible && !FLMKeyboardRouteActive) {
        return;
    }
    uint64_t sessionGeneration = FLMKeyboardRouteActive
                                     ? FLMKeyboardSessionGeneration
                                     : FLMKeyboardEndedSessionGeneration;
    if (sessionGeneration == 0) {
        return;
    }
    if (FLMKeyboardFrameToken < 0 &&
        notify_register_check(FLYME_KEYBOARD_FRAME_NOTIFICATION,
                              &FLMKeyboardFrameToken) != NOTIFY_STATUS_OK) {
        return;
    }
    CGFloat height = visible ? MAX(0.0, CGRectGetHeight(frame)) : 0.0;
    uint64_t encodedHeight =
        MIN(0xFFFFFFULL, (uint64_t)llround(height * 100.0));
    uint64_t encodedGeneration =
        (sessionGeneration & 0x7FFFFFFFFFULL) << 24;
    uint64_t state = (visible ? (1ULL << 63) : 0) |
                     encodedGeneration | encodedHeight;
    notify_set_state(FLMKeyboardFrameToken, state);
    notify_post(FLYME_KEYBOARD_FRAME_NOTIFICATION);
    FLMPublishDiagnosticEvent(
        FLMKeyboardDiagnosticRole(),
        FLMDiagnosticEventFramePublish,
        sessionGeneration,
        visible ? FLMDiagnosticUnsignedValue(CGRectGetMinY(frame)) : 0,
        visible ? FLMDiagnosticUnsignedValue(CGRectGetHeight(frame)) : 0);
}

static CGRect FLMTargetApplicationLogicalBounds(void) {
    if (!FLMKeyboardTargetApplication || !FLMKeyboardRouteActive) {
        return CGRectZero;
    }
    for (UIScene *connectedScene in
         [UIApplication sharedApplication].connectedScenes) {
        if (![connectedScene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)connectedScene;
        if (!FLMSceneMatchesKeyboardRoute(windowScene)) {
            continue;
        }
        for (UIWindow *window in windowScene.windows) {
            if (CGRectGetWidth(window.bounds) > 1.0 &&
                CGRectGetHeight(window.bounds) > 1.0 &&
                window.windowLevel <= UIWindowLevelNormal + 1.0) {
                return window.bounds;
            }
        }
        CGRect coordinateBounds = windowScene.coordinateSpace.bounds;
        if (CGRectGetWidth(coordinateBounds) > 1.0 &&
            CGRectGetHeight(coordinateBounds) > 1.0) {
            return coordinateBounds;
        }
    }
    return CGRectZero;
}

static BOOL FLMIsKeyboardFrameNotification(NSString *name) {
    return [name isEqualToString:UIKeyboardWillShowNotification] ||
           [name isEqualToString:UIKeyboardDidShowNotification] ||
           [name isEqualToString:UIKeyboardWillHideNotification] ||
           [name isEqualToString:UIKeyboardDidHideNotification] ||
           [name isEqualToString:UIKeyboardWillChangeFrameNotification] ||
           [name isEqualToString:UIKeyboardDidChangeFrameNotification];
}

static CGFloat FLMLogicalAvoidanceForPhysicalKeyboardTop(CGFloat keyboardTop,
                                                          CGRect logicalBounds) {
    if (!FLMKeyboardCardGeometryActive ||
        FLMKeyboardCardGeometryGeneration !=
            (FLMKeyboardSessionGeneration & 0x7FFFULL) ||
        FLMKeyboardCardVisualScale <= 0.05 ||
        CGRectGetHeight(logicalBounds) <= 1.0) {
        return 0.0;
    }
    CGFloat physicalOverlap = MAX(0.0, FLMKeyboardCardBottom - keyboardTop);
    if (physicalOverlap <= 1.0) {
        return 0.0;
    }
    CGFloat logicalGap = 8.0 / FLMKeyboardCardVisualScale;
    CGFloat logicalHeight =
        physicalOverlap / FLMKeyboardCardVisualScale + logicalGap;
    return MIN(CGRectGetHeight(logicalBounds) * 0.72, logicalHeight);
}

static NSDictionary *FLMCorrectKeyboardNotificationUserInfo(NSString *name,
                                                             NSDictionary *userInfo) {
    if (!FLMKeyboardTargetApplication || !FLMKeyboardRouteActive ||
        !FLMIsKeyboardFrameNotification(name) ||
        ![userInfo isKindOfClass:[NSDictionary class]]) {
        return userInfo;
    }
    NSValue *endValue = userInfo[UIKeyboardFrameEndUserInfoKey];
    if (![endValue isKindOfClass:[NSValue class]]) {
        return userInfo;
    }
    CGRect rawEndFrame = endValue.CGRectValue;
    CGRect logicalBounds = FLMTargetApplicationLogicalBounds();
    CGSize physicalSize = FLMFullPhysicalScreenSize();
    BOOL landscape = CGRectGetWidth(logicalBounds) > CGRectGetHeight(logicalBounds);
    if (landscape && physicalSize.width < physicalSize.height) {
        physicalSize = CGSizeMake(physicalSize.height, physicalSize.width);
    }
    BOOL hideNotification =
        [name isEqualToString:UIKeyboardWillHideNotification] ||
        [name isEqualToString:UIKeyboardDidHideNotification];
    BOOL physicallyVisible =
        !hideNotification && CGRectGetHeight(rawEndFrame) > 1.0 &&
        CGRectGetMinY(rawEndFrame) < physicalSize.height - 1.0;

    uint16_t notificationFlags = physicallyVisible ? 1U : 0U;
    if ([name isEqualToString:UIKeyboardWillShowNotification]) {
        notificationFlags |= 1U << 1;
    } else if ([name isEqualToString:UIKeyboardDidShowNotification]) {
        notificationFlags |= 1U << 2;
    } else if ([name isEqualToString:UIKeyboardWillHideNotification]) {
        notificationFlags |= 1U << 3;
    } else if ([name isEqualToString:UIKeyboardDidHideNotification]) {
        notificationFlags |= 1U << 4;
    } else if ([name isEqualToString:UIKeyboardWillChangeFrameNotification]) {
        notificationFlags |= 1U << 5;
    } else if ([name isEqualToString:UIKeyboardDidChangeFrameNotification]) {
        notificationFlags |= 1U << 6;
    }
    FLMPublishDiagnosticEvent(
        FLMDiagnosticRoleApplication,
        FLMDiagnosticEventFrameObserved,
        FLMKeyboardSessionGeneration,
        notificationFlags,
        FLMDiagnosticUnsignedValue(CGRectGetHeight(rawEndFrame)));

    // SpringBoard still consumes the unmodified physical frame to host the
    // keyboard on the display. Only the target application receives the Scene-
    // logical replacement below.
    FLMPublishKeyboardFrame(rawEndFrame, physicallyVisible);

    BOOL geometryCurrent =
        FLMKeyboardCardGeometryActive &&
        FLMKeyboardCardGeometryGeneration ==
            (FLMKeyboardSessionGeneration & 0x7FFFULL) &&
        FLMKeyboardCardVisualScale > 0.05 &&
        CGRectGetWidth(logicalBounds) > 1.0 &&
        CGRectGetHeight(logicalBounds) > 1.0;
    if (!geometryCurrent) {
        FLMPublishDiagnosticEvent(
            FLMDiagnosticRoleApplication,
            FLMDiagnosticEventFrameCorrected,
            FLMKeyboardSessionGeneration,
            0,
            FLMDiagnosticUnsignedValue(CGRectGetHeight(logicalBounds)));
        return userInfo;
    }

    CGFloat previousHeight =
        FLMExternalKeyboardAvoidanceGeneration == FLMKeyboardSessionGeneration
            ? FLMExternalKeyboardAvoidanceHeight
            : 0.0;
    CGFloat logicalHeight = 0.0;
    if (physicallyVisible) {
        logicalHeight = FLMLogicalAvoidanceForPhysicalKeyboardTop(
            CGRectGetMinY(rawEndFrame), logicalBounds);
        FLMExternalKeyboardAvoidanceGeneration = FLMKeyboardSessionGeneration;
        FLMExternalKeyboardAvoidanceHeight = logicalHeight;
    } else {
        FLMExternalKeyboardAvoidanceGeneration = 0;
        FLMExternalKeyboardAvoidanceHeight = 0.0;
    }

    CGFloat width = CGRectGetWidth(logicalBounds);
    CGFloat height = CGRectGetHeight(logicalBounds);
    CGFloat endHeight = physicallyVisible ? logicalHeight : MAX(1.0, previousHeight);
    CGRect correctedEnd =
        CGRectMake(0.0,
                   physicallyVisible ? height - logicalHeight : height,
                   width,
                   endHeight);
    CGRect correctedBegin =
        previousHeight > 1.0
            ? CGRectMake(0.0,
                         height - previousHeight,
                         width,
                         previousHeight)
            : CGRectMake(0.0, height, width, MAX(1.0, logicalHeight));
    NSMutableDictionary *corrected = [userInfo mutableCopy];
    corrected[UIKeyboardFrameBeginUserInfoKey] =
        [NSValue valueWithCGRect:correctedBegin];
    corrected[UIKeyboardFrameEndUserInfoKey] =
        [NSValue valueWithCGRect:correctedEnd];
    FLMPublishDiagnosticEvent(
        FLMDiagnosticRoleApplication,
        FLMDiagnosticEventFrameCorrected,
        FLMKeyboardSessionGeneration,
        FLMDiagnosticUnsignedValue(logicalHeight),
        FLMDiagnosticUnsignedValue(CGRectGetHeight(logicalBounds)));
    return corrected;
}

%hook NSNotificationCenter

- (void)postNotificationName:(NSNotificationName)name
                      object:(id)object
                    userInfo:(NSDictionary *)userInfo {
    if (FLMDeliveringCorrectedKeyboardNotification) {
        %orig;
        return;
    }
    NSDictionary *correctedUserInfo =
        FLMCorrectKeyboardNotificationUserInfo(name, userInfo);
    FLMDeliveringCorrectedKeyboardNotification = YES;
    %orig(name, object, correctedUserInfo);
    FLMDeliveringCorrectedKeyboardNotification = NO;
}

- (void)postNotification:(NSNotification *)notification {
    if (FLMDeliveringCorrectedKeyboardNotification ||
        !FLMIsKeyboardFrameNotification(notification.name)) {
        %orig;
        return;
    }
    NSDictionary *correctedUserInfo =
        FLMCorrectKeyboardNotificationUserInfo(notification.name,
                                               notification.userInfo);
    NSNotification *correctedNotification =
        correctedUserInfo == notification.userInfo
            ? notification
            : [NSNotification notificationWithName:notification.name
                                            object:notification.object
                                          userInfo:correctedUserInfo];
    FLMDeliveringCorrectedKeyboardNotification = YES;
    %orig(correctedNotification);
    FLMDeliveringCorrectedKeyboardNotification = NO;
}

%end

%hook UITextEffectsWindow

- (CGSize)keyboardScreenReferenceSize {
    UIWindowScene *scene = ((UIWindow *)self).windowScene;
    BOOL matches = FLMSceneMatchesKeyboardRoute(scene);
    if (FLMKeyboardRouteActive) {
        FLMPublishDiagnosticEvent(
            FLMKeyboardDiagnosticRole(),
            FLMDiagnosticEventSceneMatch,
            FLMKeyboardSessionGeneration,
            matches ? 1 : 0,
            FLMKeyboardTargetSceneHash != 0 ? 1 : 0);
    }
    if (!matches) {
        return %orig;
    }
    CGSize size = FLMPhysicalReferenceBoundsForScene(scene).size;
    FLMPublishDiagnosticEvent(
        FLMKeyboardDiagnosticRole(),
        FLMDiagnosticEventFrameCorrected,
        FLMKeyboardSessionGeneration,
        FLMDiagnosticUnsignedValue(size.width),
        FLMDiagnosticUnsignedValue(size.height));
    return size;
}

- (CGRect)_referenceBounds {
    CGRect bounds = %orig;
    // TrollOpen's iOS 16 path leaves this contract untouched. Overriding it
    // changes the keyboard window's own coordinate space and breaks remote
    // Scene pairing. keyboardScreenReferenceSize is the physical-display
    // control point; _referenceBounds must remain UIKit-owned.
    return bounds;
}

%end

%group FLMRemoteKeyboardGeometry

%hook _UIRemoteKeyboards

- (CGFloat)intersectionHeightForWindowScene:(UIWindowScene *)windowScene
                    isLocalMinimumHeightOut:(BOOL *)isLocalMinimumHeightOut
                     ignoreHorizontalOffset:(BOOL)ignoreHorizontalOffset {
    CGFloat originalHeight = %orig(windowScene,
                                   isLocalMinimumHeightOut,
                                   ignoreHorizontalOffset);
    if (!FLMSceneMatchesKeyboardRoute(windowScene)) {
        return originalHeight;
    }
    if (!FLMKeyboardTargetApplication) {
        return originalHeight;
    }
    if (UIInterfaceOrientationIsLandscape(windowScene.interfaceOrientation)) {
        return 0.0;
    }

    if (FLMExternalKeyboardAvoidanceGeneration !=
            FLMKeyboardSessionGeneration ||
        FLMExternalKeyboardAvoidanceHeight <= 1.0) {
        CGRect logicalBounds = FLMTargetApplicationLogicalBounds();
        CGSize physicalSize = FLMFullPhysicalScreenSize();
        if (CGRectGetWidth(logicalBounds) > CGRectGetHeight(logicalBounds) &&
            physicalSize.width < physicalSize.height) {
            physicalSize = CGSizeMake(physicalSize.height, physicalSize.width);
        }
        CGFloat mappedHeight = FLMLogicalAvoidanceForPhysicalKeyboardTop(
            physicalSize.height - originalHeight, logicalBounds);
        if (mappedHeight <= 1.0) {
            FLMPublishDiagnosticEvent(
                FLMDiagnosticRoleApplication,
                FLMDiagnosticEventIntersection,
                FLMKeyboardSessionGeneration,
                FLMDiagnosticUnsignedValue(originalHeight),
                0);
            return originalHeight;
        }
        FLMExternalKeyboardAvoidanceGeneration = FLMKeyboardSessionGeneration;
        FLMExternalKeyboardAvoidanceHeight = mappedHeight;
    }

    // The keyboard surface remains full-screen, while the application consumes
    // the overlap mapped into its own Scene coordinates. This is populated
    // before the native notification is delivered, so UIKit and application
    // observers read the same value in the same layout transaction.
    FLMPublishDiagnosticEvent(
        FLMDiagnosticRoleApplication,
        FLMDiagnosticEventIntersection,
        FLMKeyboardSessionGeneration,
        FLMDiagnosticUnsignedValue(originalHeight),
        FLMDiagnosticUnsignedValue(FLMExternalKeyboardAvoidanceHeight));
    return FLMExternalKeyboardAvoidanceHeight;
}

%end

%end


static void FLMInstallRemoteKeyboardGeometryIfAvailable(void) {
    if (FLMRemoteKeyboardGeometryInstalled ||
        !NSClassFromString(@"_UIRemoteKeyboards")) {
        return;
    }
    %init(FLMRemoteKeyboardGeometry);
    FLMRemoteKeyboardGeometryInstalled = YES;
}

%ctor {
    @autoreleasepool {
        %init;
        notify_register_dispatch(FLYME_KEYBOARD_NOTIFICATION,
                                 &FLMKeyboardRouteToken,
                                 dispatch_get_main_queue(),
                                 ^(__unused int token) {
            FLMReloadKeyboardRoute();
        });
        notify_register_dispatch(FLYME_KEYBOARD_SCENE_NOTIFICATION,
                                 &FLMKeyboardSceneToken,
                                 dispatch_get_main_queue(),
                                 ^(__unused int token) {
            FLMReloadKeyboardRoute();
        });
        notify_register_dispatch(FLYME_KEYBOARD_SESSION_NOTIFICATION,
                                 &FLMKeyboardSessionToken,
                                 dispatch_get_main_queue(),
                                 ^(__unused int token) {
            FLMReloadKeyboardRoute();
        });
        notify_register_dispatch(FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION,
                                 &FLMKeyboardAvoidanceToken,
                                 dispatch_get_main_queue(),
                                 ^(__unused int token) {
            FLMReloadKeyboardAvoidance();
        });
        notify_register_dispatch(FLYME_KEYBOARD_CARD_GEOMETRY_NOTIFICATION,
                                 &FLMKeyboardCardGeometryToken,
                                 dispatch_get_main_queue(),
                                 ^(__unused int token) {
            FLMReloadKeyboardCardGeometry();
        });
        notify_register_dispatch(FLYME_KEYBOARD_DISMISS_NOTIFICATION,
                                 &FLMKeyboardDismissToken,
                                 dispatch_get_main_queue(),
                                 ^(int token) {
            uint64_t requestedSession = 0;
            notify_get_state(token, &requestedSession);
            if (FLMKeyboardTargetApplication && requestedSession != 0 &&
                requestedSession == FLMKeyboardSessionGeneration) {
                FLMKeyboardDismissRequestedGeneration = requestedSession;
                FLMPublishDiagnosticEvent(
                    FLMDiagnosticRoleApplication,
                    FLMDiagnosticEventDismissRequest,
                    requestedSession,
                    1,
                    FLMKeyboardActiveTextResponder ? 1 : 0);
                // This is a focus change inside the current centered session,
                // not the end of that session. Keep route/generation intact so
                // the next deliberate input tap can reuse the native keyboard
                // Scene pairing.
                FLMEndApplicationKeyboardSession();
                uint64_t dismissSessionGeneration =
                    requestedSession;
                for (NSNumber *delayValue in @[@0.06, @0.18]) {
                    NSTimeInterval delay = delayValue.doubleValue;
                    dispatch_after(
                        dispatch_time(DISPATCH_TIME_NOW,
                                      (int64_t)(delay * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{
                        if (FLMKeyboardRouteActive &&
                            dismissSessionGeneration ==
                                FLMKeyboardSessionGeneration) {
                            FLMEndApplicationKeyboardSession();
                        }
                    });
                }
                // Some third-party keyboards do not emit DidHide after their
                // extension has already torn down its remote scene. Always
                // acknowledge the concrete responder cleanup within a bounded
                // interval so SpringBoard can finish the old card generation.
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(0.26 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                    if (FLMKeyboardDismissRequestedGeneration ==
                            dismissSessionGeneration &&
                        FLMKeyboardSessionGeneration ==
                            dismissSessionGeneration) {
                        FLMPublishKeyboardDismissAck(dismissSessionGeneration);
                    }
                });
            }
        });
        FLMReloadKeyboardRoute();
        FLMReloadKeyboardCardGeometry();
        FLMInstallRemoteKeyboardGeometryIfAvailable();
        if (FLMKeyboardRouteActive) {
            FLMPublishDiagnosticEvent(
                FLMKeyboardDiagnosticRole(),
                FLMDiagnosticEventProcessReady,
                FLMKeyboardSessionGeneration,
                (uint16_t)(getpid() & 0xFFFF),
                FLMRemoteKeyboardGeometryInstalled ? 1 : 0);
        }
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        FLMKeyboardWillHideObserver =
            [center addObserverForName:UIKeyboardWillHideNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(__unused NSNotification *notification) {
            // The keyboard's own collapse control begins a UIKit hide
            // transaction, but apps such as WeChat can retain the remote text
            // responder and immediately keep it alive. End the concrete
            // responder without ending the centered-card route.
            if (FLMKeyboardTargetApplication) {
                FLMPublishDiagnosticEvent(
                    FLMDiagnosticRoleApplication,
                    FLMDiagnosticEventWillHide,
                    FLMKeyboardSessionGeneration,
                    FLMKeyboardActiveTextResponder ? 1 : 0,
                    FLMEndingApplicationKeyboardSession ? 1 : 0);
                FLMEndApplicationKeyboardSession();
            }
        }];
        FLMKeyboardHideObserver =
            [center addObserverForName:UIKeyboardDidHideNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                             usingBlock:^(__unused NSNotification *notification) {
            FLMExternalKeyboardAvoidanceGeneration = 0;
            FLMExternalKeyboardAvoidanceHeight = 0.0;
            FLMPublishKeyboardFrame(CGRectZero, NO);
            if (FLMKeyboardTargetApplication) {
                FLMPublishDiagnosticEvent(
                    FLMDiagnosticRoleApplication,
                    FLMDiagnosticEventDidHide,
                    FLMKeyboardSessionGeneration,
                    FLMKeyboardActiveTextResponder ? 1 : 0,
                    0);
                uint64_t acknowledgedSession =
                    FLMKeyboardDismissRequestedGeneration != 0
                        ? FLMKeyboardDismissRequestedGeneration
                        : FLMKeyboardSessionGeneration;
                FLMPublishKeyboardDismissAck(acknowledgedSession);
                if (acknowledgedSession ==
                    FLMKeyboardDismissRequestedGeneration) {
                    FLMKeyboardDismissRequestedGeneration = 0;
                }
            }
        }];
    }
}
