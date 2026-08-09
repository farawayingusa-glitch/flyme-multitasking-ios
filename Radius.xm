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

static void FLMRadiusSetLayerRadius(CALayer *layer) {
    if (!layer) {
        return;
    }
    layer.cornerRadius = FLMRadiusPreferenceValue();
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
        requestedRadius = FLMRadiusPreferenceValue();
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
