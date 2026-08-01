#import <UIKit/UIKit.h>
#import <math.h>
#import <notify.h>
#import <objc/runtime.h>

#define FLYME_KEYBOARD_NOTIFICATION "com.codex.flymemultitasking.keyboard-state-changed"
#define FLYME_KEYBOARD_SCENE_NOTIFICATION "com.codex.flymemultitasking.keyboard-scene-changed"
#define FLYME_KEYBOARD_SESSION_NOTIFICATION "com.codex.flymemultitasking.keyboard-session-changed"
#define FLYME_KEYBOARD_FRAME_NOTIFICATION "com.codex.flymemultitasking.keyboard-frame-changed"
#define FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION "com.codex.flymemultitasking.keyboard-avoidance-changed"
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
static int FLMKeyboardDismissToken = -1;
static uint64_t FLMKeyboardTargetSceneHash = 0;
static uint64_t FLMKeyboardSessionGeneration = 0;
static uint64_t FLMKeyboardEndedSessionGeneration = 0;
static uint64_t FLMExternalKeyboardAvoidanceGeneration = 0;
static CGFloat FLMExternalKeyboardAvoidanceHeight = 0.0;
static __weak UIResponder *FLMKeyboardActiveTextResponder = nil;
static id FLMKeyboardFrameObserver = nil;
static id FLMKeyboardWillHideObserver = nil;
static id FLMKeyboardHideObserver = nil;
static BOOL FLMEndingApplicationKeyboardSession = NO;
static BOOL FLMRemoteKeyboardGeometryInstalled = NO;
static const void *FLMKeyboardBaseSafeAreaInsetsKey =
    &FLMKeyboardBaseSafeAreaInsetsKey;

static void FLMRefreshApplicationKeyboardLayout(void);
static void FLMInstallRemoteKeyboardGeometryIfAvailable(void);
static void FLMReloadKeyboardAvoidance(void);

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

static void FLMApplyApplicationKeyboardSafeArea(CGFloat avoidanceHeight) {
    CGFloat height = MAX(0.0, avoidanceHeight);
    if (height > 1.0 && !FLMKeyboardTargetApplication) {
        return;
    }
    for (UIScene *connectedScene in
         [UIApplication sharedApplication].connectedScenes) {
        if (![connectedScene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)connectedScene;
        if (height > 1.0 && !FLMSceneMatchesKeyboardRoute(windowScene)) {
            continue;
        }
        for (UIWindow *window in windowScene.windows) {
            UIViewController *rootController = window.rootViewController;
            if (!rootController || window.hidden || window.alpha <= 0.01 ||
                (height > 1.0 &&
                 window.windowLevel > UIWindowLevelNormal + 1.0)) {
                continue;
            }
            NSValue *baseValue =
                objc_getAssociatedObject(rootController,
                                         FLMKeyboardBaseSafeAreaInsetsKey);
            if (height > 1.0 && !baseValue) {
                baseValue = [NSValue valueWithUIEdgeInsets:
                    rootController.additionalSafeAreaInsets];
                objc_setAssociatedObject(rootController,
                                         FLMKeyboardBaseSafeAreaInsetsKey,
                                         baseValue,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (!baseValue) {
                continue;
            }
            UIEdgeInsets baseInsets = baseValue.UIEdgeInsetsValue;
            UIEdgeInsets targetInsets = baseInsets;
            if (height > 1.0) {
                targetInsets.bottom += height;
            }
            rootController.additionalSafeAreaInsets = targetInsets;
            [rootController.view setNeedsLayout];
            if (height <= 1.0) {
                objc_setAssociatedObject(rootController,
                                         FLMKeyboardBaseSafeAreaInsetsKey,
                                         nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    [UIView animateWithDuration:0.25
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseInOut |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        for (UIScene *connectedScene in
             [UIApplication sharedApplication].connectedScenes) {
            if (![connectedScene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)connectedScene).windows) {
                [window.rootViewController.view layoutIfNeeded];
            }
        }
    } completion:nil];
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
            FLMApplyApplicationKeyboardSafeArea(0.0);
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
        if (FLMKeyboardTargetApplication) {
            FLMApplyApplicationKeyboardSafeArea(0.0);
        }
        FLMRefreshApplicationKeyboardLayout();
        return;
    }
    FLMExternalKeyboardAvoidanceGeneration = sessionGeneration;
    // SpringBoard already mapped the physical card/keyboard overlap into the
    // target Scene's logical coordinate space. Avoid another UIScreen query
    // here so this Darwin path stays safe during process initialization.
    FLMExternalKeyboardAvoidanceHeight = MAX(0.0, height);
    FLMApplyApplicationKeyboardSafeArea(FLMExternalKeyboardAvoidanceHeight);
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
    return result;
}

- (BOOL)resignFirstResponder {
    BOOL result = %orig;
    if (result && FLMKeyboardActiveTextResponder == self) {
        FLMKeyboardActiveTextResponder = nil;
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
}

%hook UITextEffectsWindow

- (CGSize)keyboardScreenReferenceSize {
    UIWindowScene *scene = ((UIWindow *)self).windowScene;
    if (!FLMSceneMatchesKeyboardRoute(scene)) {
        return %orig;
    }
    return FLMPhysicalReferenceBoundsForScene(scene).size;
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
        return originalHeight;
    }

    // SpringBoard owns the full-screen keyboard surface. Feed UIKit that real
    // physical keyboard height directly; do not derive it from the visually
    // scaled card Scene and do not synthesize keyboard notifications.
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
        notify_register_dispatch(FLYME_KEYBOARD_DISMISS_NOTIFICATION,
                                 &FLMKeyboardDismissToken,
                                 dispatch_get_main_queue(),
                                 ^(__unused int token) {
            if (FLMKeyboardTargetApplication) {
                // This is a focus change inside the current centered session,
                // not the end of that session. Keep route/generation intact so
                // the next deliberate input tap can reuse the native keyboard
                // Scene pairing.
                FLMEndApplicationKeyboardSession();
                uint64_t dismissSessionGeneration =
                    FLMKeyboardSessionGeneration;
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
            }
        });
        FLMReloadKeyboardRoute();
        FLMInstallRemoteKeyboardGeometryIfAvailable();
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        FLMKeyboardFrameObserver =
            [center addObserverForName:UIKeyboardWillChangeFrameNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *notification) {
            if (!FLMKeyboardTargetApplication) {
                return;
            }
            NSValue *value = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
            if (![value isKindOfClass:[NSValue class]]) {
                return;
            }
            CGRect frame = value.CGRectValue;
            CGSize screenSize = FLMFullPhysicalScreenSize();
            BOOL visible = CGRectGetHeight(frame) > 0.0 &&
                           CGRectGetMinY(frame) < screenSize.height;
            if (visible) {
                // SpringBoard maps the physical keyboard/card overlap back to
                // the app Scene's logical coordinates. Do not install the raw
                // frame height here; that creates a one-frame scale mismatch.
                FLMPublishKeyboardFrame(frame, YES);
            }
        }];
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
            if (FLMKeyboardTargetApplication) {
                FLMApplyApplicationKeyboardSafeArea(0.0);
            }
            FLMPublishKeyboardFrame(CGRectZero, NO);
            if (FLMKeyboardTargetApplication) {
                notify_post(FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION);
            }
        }];
    }
}
