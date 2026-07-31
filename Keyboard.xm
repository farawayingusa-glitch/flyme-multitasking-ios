#import <UIKit/UIKit.h>

#define FLYME_PREFERENCES_DOMAIN CFSTR("com.codex.flymemultitasking")
#define FLYME_KEYBOARD_NOTIFICATION CFSTR("com.codex.flymemultitasking.keyboard-state-changed")
#define FLYME_KEYBOARD_IDENTIFIER_KEY CFSTR("ActiveKeyboardBundleIdentifier")

static BOOL FLMKeyboardRouteActive = NO;
static CGRect FLMPhysicalScreenBounds = {{0.0, 0.0}, {0.0, 0.0}};

static CGRect FLMFullPhysicalScreenBounds(void) {
    CGRect nativeBounds = [UIScreen mainScreen].nativeBounds;
    CGFloat scale = [UIScreen mainScreen].nativeScale;
    if (scale <= 0.0) {
        scale = [UIScreen mainScreen].scale;
    }
    if (scale <= 0.0) {
        scale = 1.0;
    }
    CGFloat width = CGRectGetWidth(nativeBounds) / scale;
    CGFloat height = CGRectGetHeight(nativeBounds) / scale;
    if (width > height) {
        CGFloat temporary = width;
        width = height;
        height = temporary;
    }
    if (width < 1.0 || height < 1.0) {
        CGRect fallback = [UIScreen mainScreen].bounds;
        width = MIN(CGRectGetWidth(fallback), CGRectGetHeight(fallback));
        height = MAX(CGRectGetWidth(fallback), CGRectGetHeight(fallback));
    }
    return CGRectMake(0.0, 0.0, width, height);
}

static void FLMReloadKeyboardRoute(void) {
    CFPropertyListRef value =
        CFPreferencesCopyValue(FLYME_KEYBOARD_IDENTIFIER_KEY,
                               FLYME_PREFERENCES_DOMAIN,
                               kCFPreferencesCurrentUser,
                               kCFPreferencesAnyHost);
    NSString *targetIdentifier = CFBridgingRelease(value);
    NSString *currentIdentifier = [NSBundle mainBundle].bundleIdentifier;
    FLMKeyboardRouteActive =
        targetIdentifier.length > 0 && currentIdentifier.length > 0 &&
        [targetIdentifier isEqualToString:currentIdentifier];
    FLMPhysicalScreenBounds = FLMFullPhysicalScreenBounds();
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

%group FLMKeyboardHooks

%hook UITextEffectsWindow

- (CGSize)keyboardScreenReferenceSize {
    if (!FLMKeyboardRouteActive) {
        return %orig;
    }
    if (CGRectIsEmpty(FLMPhysicalScreenBounds)) {
        FLMPhysicalScreenBounds = FLMFullPhysicalScreenBounds();
    }
    return FLMPhysicalScreenBounds.size;
}

%end

%hook UIWindowScene

- (CGRect)_referenceBounds {
    CGRect referenceBounds = %orig;
    if (CGRectIsEmpty(FLMPhysicalScreenBounds)) {
        FLMPhysicalScreenBounds = FLMFullPhysicalScreenBounds();
    }
    return referenceBounds;
}

%end

%hook _UIRemoteKeyboards

- (CGFloat)intersectionHeightForWindowScene:(UIWindowScene *)windowScene
                    isLocalMinimumHeightOut:(BOOL *)isLocalMinimumHeightOut
                     ignoreHorizontalOffset:(BOOL)ignoreHorizontalOffset {
    CGFloat height = %orig(windowScene,
                           isLocalMinimumHeightOut,
                           ignoreHorizontalOffset);
    if (!FLMKeyboardRouteActive || height <= 0.0) {
        return height;
    }
    return height;
}

%end

%end

%ctor {
    NSString *currentIdentifier = [NSBundle mainBundle].bundleIdentifier;
    if (currentIdentifier.length == 0 ||
        [currentIdentifier isEqualToString:@"com.apple.springboard"]) {
        return;
    }
    %init(FLMKeyboardHooks);
    FLMReloadKeyboardRoute();
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        FLMKeyboardRouteChanged,
        FLYME_KEYBOARD_NOTIFICATION,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}
