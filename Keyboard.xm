#import <UIKit/UIKit.h>
#import <math.h>
#import <notify.h>

#define FLYME_KEYBOARD_NOTIFICATION "com.codex.flymemultitasking.keyboard-state-changed"
#define FLYME_KEYBOARD_SCENE_NOTIFICATION "com.codex.flymemultitasking.keyboard-scene-changed"
#define FLYME_KEYBOARD_FRAME_NOTIFICATION "com.codex.flymemultitasking.keyboard-frame-changed"
#define FLYME_KEYBOARD_PREPARE_NOTIFICATION "com.codex.flymemultitasking.keyboard-prepare-fullscreen-host"

static BOOL FLMKeyboardRouteActive = NO;
static int FLMKeyboardRouteToken = -1;
static int FLMKeyboardSceneToken = -1;
static int FLMKeyboardFrameToken = -1;
static uint64_t FLMKeyboardTargetSceneHash = 0;
static BOOL FLMLoggedPhysicalSceneBounds = NO;
static id FLMKeyboardFrameObserver = nil;
static id FLMKeyboardHideObserver = nil;
static BOOL FLMKeyboardPreparePosted = NO;

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

static UIWindow *FLMKeyWindowForScene(UIWindowScene *scene) {
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        return nil;
    }
    UIWindow *bestWindow = nil;
    CGFloat bestArea = 0.0;
    for (UIWindow *window in scene.windows) {
        if (window.isKeyWindow) {
            return window;
        }
        // SpringBoard's floating overlay is intentionally made key while the
        // card is interactive.  The application's scene then has no key
        // window, even though its normal content window is still the correct
        // coordinate space for _UIRemoteKeyboards.  Prefer the largest visible
        // app window as a deterministic fallback instead of silently skipping
        // the full-screen keyboard compensation.
        if (!window.hidden && window.alpha > 0.01 &&
            window.windowLevel <= UIWindowLevelNormal + 1.0) {
            CGFloat area = CGRectGetWidth(window.bounds) *
                           CGRectGetHeight(window.bounds);
            if (area > bestArea) {
                bestArea = area;
                bestWindow = window;
            }
        }
    }
    return bestWindow;
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
    return currentHash == 0 || currentHash == FLMKeyboardTargetSceneHash;
}

static CGRect FLMPhysicalReferenceBoundsForScene(UIWindowScene *scene) {
    CGSize size = FLMFullPhysicalScreenSize();
    if ([scene isKindOfClass:[UIWindowScene class]] &&
        UIInterfaceOrientationIsLandscape(scene.interfaceOrientation)) {
        size = CGSizeMake(size.height, size.width);
    }
    return CGRectMake(0.0, 0.0, size.width, size.height);
}

static void FLMReloadKeyboardRoute(void) {
    uint64_t targetHash = 0;
    if (FLMKeyboardRouteToken >= 0) {
        notify_get_state(FLMKeyboardRouteToken, &targetHash);
    }
    NSString *currentIdentifier = [NSBundle mainBundle].bundleIdentifier;
    uint64_t currentHash = FLMIdentifierHash(currentIdentifier);
    FLMKeyboardRouteActive =
        targetHash != 0 && currentHash != 0 && targetHash == currentHash;
    FLMKeyboardTargetSceneHash = 0;
    if (FLMKeyboardSceneToken >= 0) {
        notify_get_state(FLMKeyboardSceneToken,
                         &FLMKeyboardTargetSceneHash);
    }
    FLMLoggedPhysicalSceneBounds = NO;
    if (!FLMKeyboardRouteActive) {
        FLMKeyboardPreparePosted = NO;
    }
    NSLog(@"[FlymeKeyboard] route=%@ bundle=%@ targetSceneHash=%llu",
          FLMKeyboardRouteActive ? @"active" : @"inactive",
          currentIdentifier ?: @"<unknown>",
          (unsigned long long)FLMKeyboardTargetSceneHash);
}

static void FLMPrepareFullscreenKeyboardHost(void) {
    if (!FLMKeyboardRouteActive || FLMKeyboardPreparePosted) {
        return;
    }
    FLMKeyboardPreparePosted = YES;
    notify_post(FLYME_KEYBOARD_PREPARE_NOTIFICATION);
    NSLog(@"[FlymeKeyboard] requested physical-screen keyboard host");
}

%hook UIResponder

- (BOOL)becomeFirstResponder {
    if (FLMKeyboardRouteActive &&
        [self conformsToProtocol:@protocol(UITextInput)]) {
        // Request the physical display host before UIKit creates or pairs the
        // remote keyboard scene. The SpringBoard-side notification is handled
        // on its main queue while this responder transaction is still being
        // committed, so the keyboard originates at the device bottom instead
        // of the reduced floating application scene.
        FLMPrepareFullscreenKeyboardHost();
    }
    return %orig;
}

%end

static void FLMPublishKeyboardFrame(CGRect frame, BOOL visible) {
    if (!FLMKeyboardRouteActive) {
        return;
    }
    if (FLMKeyboardFrameToken < 0 &&
        notify_register_check(FLYME_KEYBOARD_FRAME_NOTIFICATION,
                              &FLMKeyboardFrameToken) != NOTIFY_STATUS_OK) {
        return;
    }
    CGFloat height = visible ? MAX(0.0, CGRectGetHeight(frame)) : 0.0;
    uint64_t encodedHeight = (uint64_t)llround(height * 100.0);
    uint64_t state = (visible ? (1ULL << 63) : 0) | encodedHeight;
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
    UIWindowScene *scene = ((UIWindow *)self).windowScene;
    if (!FLMSceneMatchesKeyboardRoute(scene)) {
        return bounds;
    }
    // On iOS 16 this is consulted by the remote keyboard layout before the
    // host application's reduced scene bounds. Keep only the matched floating
    // scene's keyboard in physical-display coordinates.
    CGRect physicalBounds = FLMPhysicalReferenceBoundsForScene(scene);
    if (CGRectGetWidth(physicalBounds) < 1.0 ||
        CGRectGetHeight(physicalBounds) < 1.0) {
        return bounds;
    }
    return physicalBounds;
}

%end

%hook UIWindowScene

- (CGRect)_referenceBounds {
    CGRect bounds = %orig;
    if (!FLMSceneMatchesKeyboardRoute(self)) {
        return bounds;
    }
    CGRect physicalBounds = FLMPhysicalReferenceBoundsForScene(self);
    if (!FLMLoggedPhysicalSceneBounds) {
        FLMLoggedPhysicalSceneBounds = YES;
        NSLog(@"[FlymeKeyboard] scene=%@ reference %@ -> %@",
              FLMSceneIdentifier(self) ?: @"<unknown>",
              NSStringFromCGRect(bounds),
              NSStringFromCGRect(physicalBounds));
    }
    return physicalBounds;
}

%end

%hook _UIRemoteKeyboards

- (CGFloat)intersectionHeightForWindowScene:(UIWindowScene *)windowScene
                    isLocalMinimumHeightOut:(BOOL *)isLocalMinimumHeightOut
                     ignoreHorizontalOffset:(BOOL)ignoreHorizontalOffset {
    CGFloat height = %orig(windowScene,
                           isLocalMinimumHeightOut,
                           ignoreHorizontalOffset);
    if (!FLMSceneMatchesKeyboardRoute(windowScene) || height <= 0.0 ||
        ![windowScene isKindOfClass:[UIWindowScene class]] ||
        UIInterfaceOrientationIsLandscape(windowScene.interfaceOrientation)) {
        return height;
    }

    UIWindow *keyWindow = FLMKeyWindowForScene(windowScene);
    CGFloat sceneHeight = CGRectGetHeight(keyWindow.frame);
    CGFloat physicalHeight = FLMFullPhysicalScreenSize().height;
    if (sceneHeight < 1.0 || physicalHeight <= sceneHeight) {
        return height;
    }

    // The centered scene is intentionally shorter than the physical screen.
    // Compensate that missing bottom segment so the remote keyboard is laid
    // out against the device screen instead of inside the centered card.
    return height + (physicalHeight - sceneHeight);
}

%end

%ctor {
    @autoreleasepool {
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
        FLMReloadKeyboardRoute();
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
                FLMPrepareFullscreenKeyboardHost();
            }
            if (visible) {
                FLMPublishKeyboardFrame(frame, YES);
            }
        }];
        FLMKeyboardHideObserver =
            [center addObserverForName:UIKeyboardDidHideNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(__unused NSNotification *notification) {
            FLMKeyboardPreparePosted = NO;
            FLMPublishKeyboardFrame(CGRectZero, NO);
        }];
    }
}
