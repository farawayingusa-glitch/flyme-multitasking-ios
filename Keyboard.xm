#import <UIKit/UIKit.h>
#import <math.h>
#import <notify.h>

#define FLYME_KEYBOARD_NOTIFICATION CFSTR("com.codex.flymemultitasking.keyboard-state-changed")
#define FLYME_KEYBOARD_FRAME_NOTIFICATION "com.codex.flymemultitasking.keyboard-frame-changed"
#define FLYME_KEYBOARD_ROUTE_PATH @"/var/mobile/FlymeMultitasking/keyboard_route.plist"

static BOOL FLMKeyboardRouteActive = NO;
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

static void FLMReloadKeyboardRoute(void) {
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:FLYME_KEYBOARD_ROUTE_PATH];
    id activeValue = state[@"active"];
    id identifierValue = state[@"bundleIdentifier"];
    NSString *targetIdentifier =
        [identifierValue isKindOfClass:[NSString class]] ? identifierValue : nil;
    NSString *currentIdentifier = [NSBundle mainBundle].bundleIdentifier;
    FLMKeyboardRouteActive =
        [activeValue isKindOfClass:[NSNumber class]] && [activeValue boolValue] &&
        targetIdentifier.length > 0 && currentIdentifier.length > 0 &&
        [targetIdentifier isEqualToString:currentIdentifier];
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

static void FLMKeyboardRouteChanged(CFNotificationCenterRef center,
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
        FLMReloadKeyboardRoute();
    });
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
        FLMReloadKeyboardRoute();
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            FLMKeyboardRouteChanged,
            FLYME_KEYBOARD_NOTIFICATION,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
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
