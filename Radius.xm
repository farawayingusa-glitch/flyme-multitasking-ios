#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

#include <dispatch/dispatch.h>
#include <math.h>

static CFStringRef const FLMRadiusPreferencesDomain =
    CFSTR("com.codex.flymemultitasking");
static CFStringRef const FLMRadiusPreferencesNotification =
    CFSTR("com.codex.flymemultitasking.preferences-changed");

static const CGFloat FLMRadiusDefaultValue = 22.0;
static const CGFloat FLMRadiusMinimumValue = 0.0;
static const CGFloat FLMRadiusMaximumValue = 44.0;
static const CGFloat FLMRadiusDefaultCardWidth = 315.0;
static const CGFloat FLMRadiusMinimumCardWidth = 240.0;
static const CGFloat FLMRadiusMaximumCardWidth = 360.0;

static __weak id FLMRadiusController;
static __weak CALayer *FLMRadiusCardLayer;

static CGFloat FLMRadiusPreferenceValue(void) {
    CFPropertyListRef value =
        CFPreferencesCopyValue(CFSTR("cardCornerRadius"),
                                FLMRadiusPreferencesDomain,
                                kCFPreferencesCurrentUser,
                                kCFPreferencesAnyHost);
    CGFloat radius = FLMRadiusDefaultValue;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        double storedValue = FLMRadiusDefaultValue;
        if (CFNumberGetValue((CFNumberRef)value,
                             kCFNumberDoubleType,
                             &storedValue) &&
            isfinite(storedValue)) {
            radius = (CGFloat)storedValue;
        }
    }
    if (value) {
        CFRelease(value);
    }
    return MAX(FLMRadiusMinimumValue,
               MIN(FLMRadiusMaximumValue, radius));
}

static id FLMRadiusControllerValue(NSString *key) {
    id controller = FLMRadiusController;
    if (!controller || key.length == 0) {
        return nil;
    }
    @try {
        return [controller valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static CGFloat FLMRadiusCenteredCardWidth(void) {
    CFPropertyListRef value =
        CFPreferencesCopyValue(CFSTR("centeredCardWidth"),
                                FLMRadiusPreferencesDomain,
                                kCFPreferencesCurrentUser,
                                kCFPreferencesAnyHost);
    CGFloat width = FLMRadiusDefaultCardWidth;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        double storedValue = FLMRadiusDefaultCardWidth;
        if (CFNumberGetValue((CFNumberRef)value,
                             kCFNumberDoubleType,
                             &storedValue) &&
            isfinite(storedValue)) {
            width = (CGFloat)storedValue;
        }
    }
    if (value) {
        CFRelease(value);
    }
    return MAX(FLMRadiusMinimumCardWidth,
               MIN(FLMRadiusMaximumCardWidth, width));
}

static CGFloat FLMRadiusDockWidth(void) {
    id value = FLMRadiusControllerValue(@"floatingDockWidth");
    if (![value isKindOfClass:[NSNumber class]]) {
        return 0.0;
    }
    CGFloat width = [value doubleValue];
    return isfinite(width) && width > 0.0 ? width : 0.0;
}

static BOOL FLMRadiusControllerFlag(NSString *key) {
    id value = FLMRadiusControllerValue(key);
    return [value isKindOfClass:[NSNumber class]] && [value boolValue];
}

static CGFloat FLMRadiusDockScaleForLayer(CALayer *layer) {
    BOOL docked = FLMRadiusControllerFlag(@"floatingDocked");
    BOOL hidden = FLMRadiusControllerFlag(@"floatingDockHidden");
    if (!docked && !hidden) {
        return 1.0;
    }

    CGFloat centeredWidth = FLMRadiusCenteredCardWidth();
    CGFloat dockWidth = FLMRadiusDockWidth();
    if (dockWidth <= 0.0) {
        id delegate = layer.delegate;
        if ([delegate isKindOfClass:[UIView class]]) {
            dockWidth = CGRectGetWidth([(UIView *)delegate bounds]);
        }
    }
    if (!isfinite(dockWidth) || dockWidth <= 0.0) {
        return 1.0;
    }

    return MAX(0.05, MIN(1.0, dockWidth / centeredWidth));
}

static CGFloat FLMRadiusScaleForRequestedRadius(CALayer *layer,
                                                CGFloat requestedRadius) {
    CGFloat scale = FLMRadiusDockScaleForLayer(layer);
    if (scale < 0.999) {
        return scale;
    }

    // The dock transition writes the proportional radius before it flips the
    // docked flag. Preserve that final proportional step without shrinking
    // the earlier transform-driven animation frame.
    if (requestedRadius < FLMRadiusDefaultValue - 0.5 &&
        FLMRadiusControllerFlag(@"floatingDockTransitionActive")) {
        CGFloat centeredWidth = FLMRadiusCenteredCardWidth();
        CGFloat dockWidth = FLMRadiusDockWidth();
        if (dockWidth > 0.0) {
            return MAX(0.05, MIN(1.0, dockWidth / centeredWidth));
        }
        return MAX(0.05,
                   MIN(1.0, requestedRadius / FLMRadiusDefaultValue));
    }
    return 1.0;
}

static CGFloat FLMRadiusEffectiveValue(CALayer *layer,
                                       CGFloat requestedRadius) {
    if (requestedRadius <= 0.01) {
        return requestedRadius;
    }
    CGFloat radius = FLMRadiusPreferenceValue();
    CGFloat scale = FLMRadiusScaleForRequestedRadius(layer, requestedRadius);
    return radius * scale;
}

static void FLMRadiusSetLayerRadius(CALayer *layer) {
    if (!layer) {
        return;
    }
    layer.cornerRadius =
        FLMRadiusEffectiveValue(layer, FLMRadiusDefaultValue);
}

static void FLMRadiusCaptureCardLayer(id controller) {
    if (!controller) {
        return;
    }

    id container = nil;
    @try {
        container = [controller valueForKey:@"floatingContainer"];
    } @catch (__unused NSException *exception) {
        container = nil;
    }

    if (![container isKindOfClass:[UIView class]]) {
        return;
    }

    FLMRadiusController = controller;
    FLMRadiusCardLayer = [(UIView *)container layer];
    FLMRadiusSetLayerRadius(FLMRadiusCardLayer);
}

static void (*FLMRadiusOriginalSetCornerRadius)(CALayer *, SEL, CGFloat);

static void FLMRadiusSetCornerRadius(CALayer *layer,
                                     SEL selector,
                                     CGFloat requestedRadius) {
    CALayer *cardLayer = FLMRadiusCardLayer;
    if (cardLayer && layer == cardLayer && requestedRadius > 0.01) {
        requestedRadius = FLMRadiusEffectiveValue(layer, requestedRadius);
    }

    if (FLMRadiusOriginalSetCornerRadius) {
        FLMRadiusOriginalSetCornerRadius(layer, selector, requestedRadius);
    }
}

static void (*FLMRadiusOriginalCreateFloatingWindow)(id, SEL);
static void FLMRadiusCreateFloatingWindow(id controller, SEL selector) {
    if (FLMRadiusOriginalCreateFloatingWindow) {
        FLMRadiusOriginalCreateFloatingWindow(controller, selector);
    }
    FLMRadiusCaptureCardLayer(controller);
}

static void (*FLMRadiusOriginalReloadPreferences)(id, SEL);
static void FLMRadiusReloadPreferences(id controller, SEL selector) {
    if (FLMRadiusOriginalReloadPreferences) {
        FLMRadiusOriginalReloadPreferences(controller, selector);
    }
    FLMRadiusCaptureCardLayer(controller);
}

static void (*FLMRadiusOriginalLayoutFloatingWindow)(id, SEL);
static void FLMRadiusLayoutFloatingWindow(id controller, SEL selector) {
    if (FLMRadiusOriginalLayoutFloatingWindow) {
        FLMRadiusOriginalLayoutFloatingWindow(controller, selector);
    }
    FLMRadiusCaptureCardLayer(controller);
}

static void FLMRadiusInstallControllerHooks(void);

static void FLMRadiusPreferencesChanged(CFNotificationCenterRef center,
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
        FLMRadiusSetLayerRadius(FLMRadiusCardLayer);
        FLMRadiusInstallControllerHooks();
    });
}

static void FLMRadiusInstallControllerHooks(void) {
    static BOOL installed = NO;
    Class controllerClass = NSClassFromString(@"FLMWheelController");
    if (!controllerClass) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                      (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            FLMRadiusInstallControllerHooks();
        });
        return;
    }
    if (installed) {
        return;
    }

    SEL createSelector = NSSelectorFromString(@"createFloatingWindow");
    if (class_getInstanceMethod(controllerClass, createSelector)) {
        MSHookMessageEx(controllerClass,
                        createSelector,
                        (IMP)FLMRadiusCreateFloatingWindow,
                        (IMP *)&FLMRadiusOriginalCreateFloatingWindow);
    }

    SEL reloadSelector = NSSelectorFromString(@"reloadPreferences");
    if (class_getInstanceMethod(controllerClass, reloadSelector)) {
        MSHookMessageEx(controllerClass,
                        reloadSelector,
                        (IMP)FLMRadiusReloadPreferences,
                        (IMP *)&FLMRadiusOriginalReloadPreferences);
    }

    SEL layoutSelector = NSSelectorFromString(@"layoutFloatingWindow");
    if (class_getInstanceMethod(controllerClass, layoutSelector)) {
        MSHookMessageEx(controllerClass,
                        layoutSelector,
                        (IMP)FLMRadiusLayoutFloatingWindow,
                        (IMP *)&FLMRadiusOriginalLayoutFloatingWindow);
    }
    installed = YES;
}

%ctor {
    MSHookMessageEx([CALayer class],
                    @selector(setCornerRadius:),
                    (IMP)FLMRadiusSetCornerRadius,
                    (IMP *)&FLMRadiusOriginalSetCornerRadius);

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    FLMRadiusPreferencesChanged,
                                    FLMRadiusPreferencesNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    dispatch_async(dispatch_get_main_queue(), ^{
        FLMRadiusInstallControllerHooks();
    });
}
