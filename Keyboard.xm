#import <UIKit/UIKit.h>
#import <math.h>
#import <notify.h>

#define FLYME_KEYBOARD_NOTIFICATION "com.codex.flymemultitasking.keyboard-state-changed"
#define FLYME_KEYBOARD_FRAME_NOTIFICATION "com.codex.flymemultitasking.keyboard-frame-changed"

static BOOL FLMKeyboardRouteActive = NO;
static int FLMKeyboardRouteToken = -1;
static int FLMKeyboardFrameToken = -1;
static id FLMKeyboardFrameObserver = nil;
static id FLMKeyboardHideObserver = nil;

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
    for (UIWindow *window in scene.windows) {
        if (window.isKeyWindow) {
            return window;
        }
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

static void FLMReloadKeyboardRoute(void) {
    uint64_t targetHash = 0;
    if (FLMKeyboardRouteToken >= 0) {
        notify_get_state(FLMKeyboardRouteToken, &targetHash);
    }
    NSString *currentIdentifier = [NSBundle mainBundle].bundleIdentifier;
    uint64_t currentHash = FLMIdentifierHash(currentIdentifier);
    FLMKeyboardRouteActive =
        targetHash != 0 && currentHash != 0 && targetHash == currentHash;
}

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
    if (!FLMKeyboardRouteActive) {
        return %orig;
    }
    return FLMFullPhysicalScreenSize();
}

%end

%hook UIWindowScene

- (CGRect)_referenceBounds {
    CGRect bounds = %orig;
    // TrollOpen only uses this hook to make sure the physical reference size
    // has been resolved. Changing the scene bounds itself also changes the app
    // layout and is the reason the previous bridge still behaved incorrectly.
    if (FLMKeyboardRouteActive) {
        (void)FLMFullPhysicalScreenSize();
    }
    return bounds;
}

%end

%hook _UIRemoteKeyboards

- (CGFloat)intersectionHeightForWindowScene:(UIWindowScene *)windowScene
                    isLocalMinimumHeightOut:(BOOL *)isLocalMinimumHeightOut
                     ignoreHorizontalOffset:(BOOL)ignoreHorizontalOffset {
    CGFloat height = %orig(windowScene,
                           isLocalMinimumHeightOut,
                           ignoreHorizontalOffset);
    if (!FLMKeyboardRouteActive || height <= 0.0 ||
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
            FLMPublishKeyboardFrame(frame, visible);
        }];
        FLMKeyboardHideObserver =
            [center addObserverForName:UIKeyboardWillHideNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(__unused NSNotification *notification) {
            FLMPublishKeyboardFrame(CGRectZero, NO);
        }];
    }
}
