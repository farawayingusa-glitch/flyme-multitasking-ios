#import "FLMSceneLifecycle.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>

NSNotificationName const FLMProtectedSceneDidDisappearNotification =
    @"com.codex.flymemultitasking.protected-scene-disappeared";

static id FLMProtectedScene = nil;
static id FLMProtectedSceneHandle = nil;

void FLMProtectScene(id scene, id sceneHandle) {
    @synchronized([NSObject class]) {
        FLMProtectedScene = scene;
        FLMProtectedSceneHandle = sceneHandle;
    }
}

void FLMClearProtectedScene(id scene) {
    @synchronized([NSObject class]) {
        // A scene can be destroyed through its handle.  iOS 16 reports the
        // handle to _didDestroyScene: on some paths and the scene on others;
        // accepting either prevents a stale protection lease from surviving a
        // scene replacement and subsequently pinning the next launch.
        if (scene && scene != FLMProtectedScene &&
            scene != FLMProtectedSceneHandle) {
            return;
        }
        FLMProtectedScene = nil;
        FLMProtectedSceneHandle = nil;
    }
}

BOOL FLMProtectedSceneIsAlive(void) {
    @synchronized([NSObject class]) {
        return FLMProtectedScene != nil || FLMProtectedSceneHandle != nil;
    }
}

BOOL FLMObjectMatchesProtectedScene(id object) {
    if (!object) {
        return NO;
    }
    @synchronized([NSObject class]) {
        return object == FLMProtectedScene ||
               object == FLMProtectedSceneHandle;
    }
}

static void FLMPatchSceneSettings(id settings) {
    if (!settings) {
        return;
    }
    @try {
        SEL reasonsSelector = NSSelectorFromString(@"setDeactivationReasons:");
        if ([settings respondsToSelector:reasonsSelector]) {
            ((void (*)(id, SEL, unsigned long long))objc_msgSend)(
                settings, reasonsSelector, 0);
        }
        SEL foregroundSelector = NSSelectorFromString(@"setForeground:");
        if ([settings respondsToSelector:foregroundSelector]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                settings, foregroundSelector, YES);
        }
        SEL backgroundedSelector = NSSelectorFromString(@"setBackgrounded:");
        if ([settings respondsToSelector:backgroundedSelector]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                settings, backgroundedSelector, NO);
        }
    } @catch (__unused NSException *exception) {
    }
}

%hook UIApplicationSceneDeactivationManager

- (void)_setDeactivationReasons:(unsigned long long)reasons
                         onScene:(id)scene
                     withSettings:(id)settings
                           reason:(id)reason {
    if (FLMObjectMatchesProtectedScene(scene)) {
        FLMPatchSceneSettings(settings);
        %orig(0, scene, settings, reason);
        return;
    }
    %orig;
}

- (void)amendSceneSettings:(id)settings forScene:(id)scene {
    %orig;
    if (FLMObjectMatchesProtectedScene(scene)) {
        FLMPatchSceneSettings(settings);
    }
}

%end

%hook SBDeviceApplicationSceneHandle

- (void)_didDestroyScene:(id)scene {
    BOOL wasProtected = FLMObjectMatchesProtectedScene(scene) ||
                        FLMObjectMatchesProtectedScene(self);
    %orig;
    if (wasProtected) {
        // Clear by handle as well as the destroyed scene.  Passing only
        // `scene` is insufficient when SpringBoard has already replaced the
        // primary scene object before this callback arrives.
        FLMClearProtectedScene(self);
        FLMClearProtectedScene(scene);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:FLMProtectedSceneDidDisappearNotification
                              object:nil];
        });
    }
}

%end
