#import "FLMSceneLifecycle.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>

NSNotificationName const FLMProtectedSceneDidDisappearNotification =
    @"com.codex.flymemultitasking.protected-scene-disappeared";

static id FLMProtectedScene = nil;
static id FLMProtectedSceneHandle = nil;
static NSString *FLMProtectedSceneIdentifier = nil;

static id FLMObjectGetter(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) {
        return nil;
    }
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *FLMDirectSceneIdentifier(id object) {
    if (!object) {
        return nil;
    }
    for (NSString *selectorName in
         @[@"sceneIdentifier", @"sceneID", @"identifier"]) {
        id value = FLMObjectGetter(object, NSSelectorFromString(selectorName));
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            return value;
        }
    }
    return nil;
}

static NSString *FLMSceneIdentifier(id object, NSUInteger depth) {
    if (!object || depth > 3) {
        return nil;
    }
    NSString *direct = FLMDirectSceneIdentifier(object);
    if (direct.length > 0) {
        return direct;
    }
    for (NSString *selectorName in
         @[@"sceneIfExists", @"scene", @"sceneHandle", @"applicationSceneHandle"]) {
        id nested = FLMObjectGetter(object, NSSelectorFromString(selectorName));
        if (!nested || nested == object) {
            continue;
        }
        NSString *identifier = FLMSceneIdentifier(nested, depth + 1);
        if (identifier.length > 0) {
            return identifier;
        }
    }
    return nil;
}

void FLMProtectScene(id scene, id sceneHandle) {
    @synchronized([NSObject class]) {
        FLMProtectedScene = scene;
        FLMProtectedSceneHandle = sceneHandle;
        FLMProtectedSceneIdentifier =
            [FLMSceneIdentifier(scene, 0) copy] ?: [FLMSceneIdentifier(sceneHandle, 0) copy];
    }
}

void FLMClearProtectedScene(id scene) {
    @synchronized([NSObject class]) {
        if (scene && scene != FLMProtectedScene &&
            !FLMObjectMatchesProtectedScene(scene)) {
            return;
        }
        FLMProtectedScene = nil;
        FLMProtectedSceneHandle = nil;
        FLMProtectedSceneIdentifier = nil;
    }
}

BOOL FLMObjectMatchesProtectedScene(id object) {
    if (!object) {
        return NO;
    }
    @synchronized([NSObject class]) {
        if (!FLMProtectedScene && !FLMProtectedSceneHandle &&
            FLMProtectedSceneIdentifier.length == 0) {
            return NO;
        }
        if (object == FLMProtectedScene || object == FLMProtectedSceneHandle) {
            return YES;
        }
        NSString *identifier = FLMSceneIdentifier(object, 0);
        return identifier.length > 0 &&
               [identifier isEqualToString:FLMProtectedSceneIdentifier];
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

static void FLMPruneProtectedSceneFromTransaction(id transaction) {
    for (NSString *key in @[@"_backgroundingAppSceneEntities",
                             @"_scenesToBackground"]) {
        NSMutableSet *set = nil;
        @try {
            id value = [transaction valueForKey:key];
            if ([value isKindOfClass:[NSMutableSet class]]) {
                set = value;
            }
        } @catch (__unused NSException *exception) {
            set = nil;
        }
        if (!set) {
            continue;
        }
        NSMutableArray *matches = [NSMutableArray array];
        for (id object in [set copy]) {
            if (FLMObjectMatchesProtectedScene(object)) {
                [matches addObject:object];
            }
        }
        [set minusSet:[NSSet setWithArray:matches]];
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

%hook _UIWindowSceneFBSSceneTransitionContextDrivenLifecycleSettingsDiffAction

- (void)_performActionsForUIScene:(id)uiScene
              withUpdatedFBSScene:(id)fbScene
                     settingsDiff:(id)settingsDiff
                     fromSettings:(id)fromSettings
                transitionContext:(id)transitionContext
              lifecycleActionType:(unsigned int)lifecycleActionType {
    if (FLMObjectMatchesProtectedScene(uiScene) ||
        FLMObjectMatchesProtectedScene(fbScene)) {
        %orig(uiScene,
              fbScene,
              settingsDiff,
              fromSettings,
              transitionContext,
              0);
        return;
    }
    %orig;
}

%end

%hook SBSceneLayoutWorkspaceTransaction

- (void)_prepareScenesForTransition {
    FLMPruneProtectedSceneFromTransaction(self);
    %orig;
    FLMPruneProtectedSceneFromTransaction(self);
}

- (void)_updateScenesForTransitionCompletion {
    FLMPruneProtectedSceneFromTransaction(self);
    %orig;
    FLMPruneProtectedSceneFromTransaction(self);
}

%end

%hook SBDeviceApplicationSceneHandle

- (void)_didDestroyScene:(id)scene {
    BOOL wasProtected = FLMObjectMatchesProtectedScene(scene) ||
                        FLMObjectMatchesProtectedScene(self);
    %orig;
    if (wasProtected) {
        FLMClearProtectedScene(scene);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:FLMProtectedSceneDidDisappearNotification
                              object:nil];
        });
    }
}

%end
