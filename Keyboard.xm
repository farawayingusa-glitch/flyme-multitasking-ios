#import <UIKit/UIKit.h>
#import <math.h>
#import <notify.h>

#define FLYME_KEYBOARD_NOTIFICATION "com.codex.flymemultitasking.keyboard-state-changed"
#define FLYME_KEYBOARD_SCENE_NOTIFICATION "com.codex.flymemultitasking.keyboard-scene-changed"
#define FLYME_KEYBOARD_SESSION_NOTIFICATION "com.codex.flymemultitasking.keyboard-session-changed"
#define FLYME_KEYBOARD_FRAME_NOTIFICATION "com.codex.flymemultitasking.keyboard-frame-changed"
#define FLYME_KEYBOARD_DISMISS_NOTIFICATION "com.codex.flymemultitasking.keyboard-dismiss-requested"
#define FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION "com.codex.flymemultitasking.keyboard-dismiss-acknowledged"

static BOOL FLMKeyboardRouteActive = NO;
static int FLMKeyboardRouteToken = -1;
static int FLMKeyboardSceneToken = -1;
static int FLMKeyboardSessionToken = -1;
static int FLMKeyboardFrameToken = -1;
static int FLMKeyboardDismissToken = -1;
static uint64_t FLMKeyboardTargetSceneHash = 0;
static uint64_t FLMKeyboardSessionGeneration = 0;
static uint64_t FLMKeyboardEndedSessionGeneration = 0;
static __weak UIResponder *FLMKeyboardActiveTextResponder = nil;
static id FLMKeyboardFrameObserver = nil;
static id FLMKeyboardWillHideObserver = nil;
static id FLMKeyboardHideObserver = nil;
static BOOL FLMEndingApplicationKeyboardSession = NO;
static BOOL FLMRemoteKeyboardGeometryInstalled = NO;

static void FLMRefreshApplicationKeyboardLayout(void);
static void FLMInstallRemoteKeyboardGeometryIfAvailable(void);

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
    uint64_t sessionGeneration = 0;
    if (FLMKeyboardSessionToken >= 0) {
        notify_get_state(FLMKeyboardSessionToken, &sessionGeneration);
    }
    uint64_t previousSessionGeneration = FLMKeyboardSessionGeneration;
    BOOL sessionChanged =
        sessionGeneration != previousSessionGeneration;
    FLMKeyboardSessionGeneration = sessionGeneration;
    FLMKeyboardRouteActive = sessionGeneration != 0 && targetHash != 0 &&
                             currentHash != 0 && targetHash == currentHash;
    FLMKeyboardTargetSceneHash = 0;
    if (FLMKeyboardSceneToken >= 0) {
        notify_get_state(FLMKeyboardSceneToken,
                         &FLMKeyboardTargetSceneHash);
    }
    if (sessionChanged) {
        // Close any responder and keyboard Scene retained by the previous
        // centered card before the new generation is allowed to focus. This
        // does not depend on delivery of the
        // short-lived route-off notification between two openings.
        if (previousSessionGeneration != 0 && previousRouteActive) {
            FLMKeyboardEndedSessionGeneration = previousSessionGeneration;
            FLMEndApplicationKeyboardSession();
        }
        if (sessionGeneration != 0) {
            FLMKeyboardEndedSessionGeneration = 0;
        }
    }
}

%hook UIResponder

- (BOOL)becomeFirstResponder {
    BOOL routedTextInput =
        FLMKeyboardRouteActive && [self conformsToProtocol:@protocol(UITextInput)];
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
    if (UIInterfaceOrientationIsLandscape(windowScene.interfaceOrientation)) {
        return 0.0;
    }

    UIWindow *keyWindow = windowScene.keyWindow;
    CGFloat sceneHeight = keyWindow ? CGRectGetHeight(keyWindow.frame) : 0.0;
    CGFloat physicalHeight =
        CGRectGetHeight(FLMPhysicalReferenceBoundsForScene(windowScene));
    if (sceneHeight < 1.0 || physicalHeight <= sceneHeight + 1.0) {
        return originalHeight;
    }

    // The application Scene is intentionally shorter than the physical
    // display while centered. UIKit reports only the local intersection; add
    // the missing display segment so its real keyboard-layout machinery moves
    // accessories such as WeChat's input bar. This is system state, not a
    // synthetic notification.
    return MAX(0.0, originalHeight + physicalHeight - sceneHeight);
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
        notify_register_dispatch(FLYME_KEYBOARD_DISMISS_NOTIFICATION,
                                 &FLMKeyboardDismissToken,
                                 dispatch_get_main_queue(),
                                 ^(__unused int token) {
            if (FLMKeyboardRouteActive) {
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
            if (!FLMKeyboardRouteActive) {
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
                FLMPublishKeyboardFrame(frame, YES);
                FLMRefreshApplicationKeyboardLayout();
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
            if (FLMKeyboardRouteActive) {
                FLMEndApplicationKeyboardSession();
            }
        }];
        FLMKeyboardHideObserver =
            [center addObserverForName:UIKeyboardDidHideNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                             usingBlock:^(__unused NSNotification *notification) {
            FLMPublishKeyboardFrame(CGRectZero, NO);
            if (FLMKeyboardRouteActive) {
                notify_post(FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION);
            }
        }];
    }
}
