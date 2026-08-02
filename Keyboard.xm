#import <UIKit/UIKit.h>
#import <math.h>
#import <notify.h>
#import <unistd.h>

#import "FLMDiagnostics.h"

// SpringBoard owns the real keyboard Scene and its touch routing.  This UIKit
// client never resizes the application Scene or moves the floating card.  It
// only tells UIKit the full-screen keyboard reference size and the logical
// overlap seen by the active floating application, allowing the application to
// perform its normal responder/input-bar avoidance.
#define FLYME_KEYBOARD_NOTIFICATION "com.codex.flymemultitasking.keyboard-state-changed"
#define FLYME_KEYBOARD_SCENE_NOTIFICATION "com.codex.flymemultitasking.keyboard-scene-changed"
#define FLYME_KEYBOARD_SESSION_NOTIFICATION "com.codex.flymemultitasking.keyboard-session-changed"
#define FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION "com.codex.flymemultitasking.keyboard-avoidance-changed"
#define FLYME_KEYBOARD_CARD_GEOMETRY_NOTIFICATION "com.codex.flymemultitasking.keyboard-card-geometry-changed"

static BOOL FLMKeyboardRouteActive = NO;
static BOOL FLMKeyboardTargetApplication = NO;
static BOOL FLMKeyboardExtensionProcess = NO;
static BOOL FLMRemoteKeyboardGeometryInstalled = NO;
static int FLMKeyboardRouteToken = -1;
static int FLMKeyboardSceneToken = -1;
static int FLMKeyboardSessionToken = -1;
static int FLMKeyboardAvoidanceToken = -1;
static int FLMKeyboardCardGeometryToken = -1;
static uint64_t FLMKeyboardTargetSceneHash = 0;
static uint64_t FLMKeyboardSessionGeneration = 0;
static uint64_t FLMExternalKeyboardAvoidanceGeneration = 0;
static CGFloat FLMExternalKeyboardAvoidanceHeight = 0.0;
static BOOL FLMKeyboardCardGeometryActive = NO;
static uint64_t FLMKeyboardCardGeometryGeneration = 0;
static CGFloat FLMKeyboardCardBottom = 0.0;
static CGFloat FLMKeyboardCardVisualScale = 0.0;

static void FLMInstallRemoteKeyboardGeometryIfAvailable(void);
static void FLMReloadKeyboardAvoidance(void);
static void FLMReloadKeyboardCardGeometry(void);

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

static BOOL FLMProcessIsKeyboardExtension(void) {
    NSDictionary *extension = [NSBundle mainBundle].infoDictionary[@"NSExtension"];
    NSString *pointIdentifier =
        [extension isKindOfClass:[NSDictionary class]]
            ? extension[@"NSExtensionPointIdentifier"]
            : nil;
    return [pointIdentifier isKindOfClass:[NSString class]] &&
           [pointIdentifier rangeOfString:@"keyboard"
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
        NSString *identifier = scene.session.persistentIdentifier;
        if (identifier.length > 0) {
            return identifier;
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
    if (FLMKeyboardExtensionProcess) {
        return YES;
    }
    if (!FLMKeyboardTargetApplication) {
        return NO;
    }
    if (FLMKeyboardTargetSceneHash == 0) {
        return YES;
    }
    uint64_t currentHash = FLMIdentifierHash(FLMSceneIdentifier(scene));
    if (currentHash == 0 || currentHash == FLMKeyboardTargetSceneHash) {
        return YES;
    }
    NSSet<UIScene *> *connectedScenes =
        [UIApplication sharedApplication].connectedScenes;
    return connectedScenes.count == 1 && [connectedScenes containsObject:scene];
}

static CGRect FLMPhysicalReferenceBoundsForScene(UIWindowScene *scene) {
    CGSize size = FLMFullPhysicalScreenSize();
    if ([scene isKindOfClass:[UIWindowScene class]] &&
        UIInterfaceOrientationIsLandscape(scene.interfaceOrientation)) {
        size = CGSizeMake(size.height, size.width);
    }
    return CGRectMake(0.0, 0.0, size.width, size.height);
}

static CGRect FLMTargetApplicationLogicalBounds(void) {
    if (!FLMKeyboardTargetApplication || !FLMKeyboardRouteActive) {
        return CGRectZero;
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
            if (!window.hidden && window.alpha > 0.01 &&
                window.windowLevel <= UIWindowLevelNormal + 1.0 &&
                CGRectGetWidth(window.bounds) > 1.0 &&
                CGRectGetHeight(window.bounds) > 1.0) {
                return window.bounds;
            }
        }
        CGRect bounds = windowScene.coordinateSpace.bounds;
        if (CGRectGetWidth(bounds) > 1.0 && CGRectGetHeight(bounds) > 1.0) {
            return bounds;
        }
    }
    return CGRectZero;
}

static void FLMRefreshApplicationKeyboardLayout(void) {
    if (!FLMKeyboardTargetApplication || !FLMKeyboardRouteActive) {
        return;
    }
    CGRect logicalBounds = FLMTargetApplicationLogicalBounds();
    FLMPublishDiagnosticEvent(
        FLMDiagnosticRoleApplication,
        FLMDiagnosticEventLayoutRefresh,
        FLMKeyboardSessionGeneration,
        FLMDiagnosticUnsignedValue(CGRectGetWidth(logicalBounds)),
        FLMDiagnosticUnsignedValue(CGRectGetHeight(logicalBounds)));
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
}

static void FLMEndPreviousApplicationKeyboardSession(uint64_t generation) {
    if (generation == 0) {
        return;
    }
    NSUInteger endedWindows = 0;
    @try {
        [[UIApplication sharedApplication]
            sendAction:@selector(resignFirstResponder)
                   to:nil
                 from:nil
             forEvent:nil];
        for (UIScene *connectedScene in
             [UIApplication sharedApplication].connectedScenes) {
            if (![connectedScene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)connectedScene).windows) {
                if ([window endEditing:YES]) {
                    endedWindows += 1;
                }
            }
        }
    } @catch (__unused NSException *exception) {
    }
    FLMPublishDiagnosticEvent(
        FLMDiagnosticRoleApplication,
        FLMDiagnosticEventResponderResign,
        generation,
        FLMDiagnosticUnsignedValue(endedWindows),
        0);
}

static void FLMReloadKeyboardRoute(void) {
    uint64_t targetHash = 0;
    uint64_t sessionGeneration = 0;
    uint64_t sceneHash = 0;
    if (FLMKeyboardRouteToken >= 0) {
        notify_get_state(FLMKeyboardRouteToken, &targetHash);
    }
    if (FLMKeyboardSessionToken >= 0) {
        notify_get_state(FLMKeyboardSessionToken, &sessionGeneration);
    }
    if (FLMKeyboardSceneToken >= 0) {
        notify_get_state(FLMKeyboardSceneToken, &sceneHash);
    }

    BOOL previousTargetApplication = FLMKeyboardTargetApplication;
    uint64_t previousGeneration = FLMKeyboardSessionGeneration;
    uint64_t currentHash =
        FLMIdentifierHash([NSBundle mainBundle].bundleIdentifier);
    FLMKeyboardExtensionProcess = FLMProcessIsKeyboardExtension();
    FLMKeyboardTargetApplication =
        sessionGeneration != 0 && targetHash != 0 && currentHash != 0 &&
        targetHash == currentHash;
    FLMKeyboardRouteActive =
        FLMKeyboardTargetApplication ||
        (FLMKeyboardExtensionProcess && sessionGeneration != 0 && targetHash != 0);
    FLMKeyboardSessionGeneration = sessionGeneration;
    FLMKeyboardTargetSceneHash = sceneHash;

    if (previousTargetApplication && previousGeneration != 0 &&
        previousGeneration != sessionGeneration) {
        FLMEndPreviousApplicationKeyboardSession(previousGeneration);
    }
    if (FLMKeyboardTargetApplication) {
        FLMInstallRemoteKeyboardGeometryIfAvailable();
    }
    if (!FLMKeyboardRouteActive || previousGeneration != sessionGeneration) {
        FLMExternalKeyboardAvoidanceGeneration = 0;
        FLMExternalKeyboardAvoidanceHeight = 0.0;
    }
    FLMReloadKeyboardCardGeometry();
    FLMReloadKeyboardAvoidance();

    if (FLMKeyboardRouteActive || previousTargetApplication ||
        previousGeneration != sessionGeneration) {
        FLMDiagnosticRole role =
            (FLMKeyboardTargetApplication || previousTargetApplication)
                ? FLMDiagnosticRoleApplication
                : (FLMKeyboardExtensionProcess
                       ? FLMDiagnosticRoleKeyboardExtension
                       : FLMDiagnosticRoleUIKitOther);
        uint16_t flags =
            (FLMKeyboardRouteActive ? 1U : 0U) |
            (FLMKeyboardTargetApplication ? 2U : 0U) |
            (FLMKeyboardExtensionProcess ? 4U : 0U) |
            (FLMRemoteKeyboardGeometryInstalled ? 8U : 0U) |
            (sceneHash != 0 ? 16U : 0U);
        FLMPublishDiagnosticEvent(
            role,
            FLMDiagnosticEventRouteReload,
            sessionGeneration ?: previousGeneration,
            flags,
            (uint16_t)(getpid() & 0xFFFF));
        if (FLMKeyboardTargetApplication) {
            FLMPublishDiagnosticEvent(
                FLMDiagnosticRoleApplication,
                FLMDiagnosticEventProcessReady,
                sessionGeneration,
                (uint16_t)(getpid() & 0xFFFF),
                FLMRemoteKeyboardGeometryInstalled ? 1 : 0);
        }
    }
}

static void FLMReloadKeyboardCardGeometry(void) {
    uint64_t state = 0;
    if (FLMKeyboardCardGeometryToken < 0 ||
        notify_get_state(FLMKeyboardCardGeometryToken, &state) !=
            NOTIFY_STATUS_OK) {
        return;
    }
    BOOL active = (state & (1ULL << 63)) != 0;
    uint64_t generation = (state >> 48) & 0x7FFFULL;
    CGFloat cardBottom = (CGFloat)((state >> 24) & 0xFFFFFFULL) / 100.0;
    CGFloat visualScale = (CGFloat)(state & 0xFFFFFFULL) / 1000000.0;
    BOOL current = FLMKeyboardTargetApplication && active && generation != 0 &&
                   generation == (FLMKeyboardSessionGeneration & 0x7FFFULL) &&
                   cardBottom > 1.0 && visualScale > 0.05;
    FLMKeyboardCardGeometryActive = current;
    FLMKeyboardCardGeometryGeneration = current ? generation : 0;
    FLMKeyboardCardBottom = current ? cardBottom : 0.0;
    FLMKeyboardCardVisualScale = current ? visualScale : 0.0;
    if (FLMKeyboardTargetApplication) {
        FLMPublishDiagnosticEvent(
            FLMDiagnosticRoleApplication,
            FLMDiagnosticEventCardGeometry,
            FLMKeyboardSessionGeneration,
            FLMDiagnosticUnsignedValue(FLMKeyboardCardBottom),
            FLMDiagnosticUnsignedValue(FLMKgÍ|ó[h‘éì¶»§q«^v;
    }
    if ([identifier isEqualToString:FLMFrontmostApplicationIdentifier()]) {
        self.prewarmedIdentifier = nil;
        return;
    }
    [self openFloatingIdentifier:identifier];
}

@end

%hook _UIKeyboardLayerHostView

- (void)scene:(id)scene
    didUpdateClientSettingsWithDiff:(id)diff
                  oldClientSettings:(id)oldClientSettings
                  transitionContext:(id)transitionContext {
    %orig;
    (void)diff;
    (void)oldClientSettings;
    (void)transitionContext;

    // UIKit must finish its private keyboard Scene transaction before the host
    // changes superviews.  Moving it synchronously is what leaves the remote
    // keyboard half-paired and makes keys or the collapse control stop routing.
    FLMWheelController *controller = [FLMWheelController sharedController];
    NSUInteger sessionGeneration =
        controller.floatingKeyboardSessionGeneration;
    FLMEnqueueDiagnosticLine(
        @"sb host-hook callback host=%p updatedScene=%@ session=%lu",
        (__bridge void *)self, FLMSceneIdentifier(scene) ?: @"<none>",
        (unsigned long)sessionGeneration);
    __weak UIView *weakHostView = (UIView *)self;
    __weak id weakUpdatedScene = scene;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *hostView = weakHostView;
        id updatedScene = weakUpdatedScene;
        if (!hostView) {
            FLMEnqueueDiagnosticLine(
                @"sb host-hook expired updatedScene=%@ session=%lu",
                FLMSceneIdentifier(updatedScene) ?: @"<none>",
                (unsigned long)sessionGeneration);
            return;
        }
        [controller keyboardLayerHostView:hostView
                        didUpdateForScene:updatedScene
                        sessionGeneration:sessionGeneration];
    });
}

%end

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    (void)application;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [[FLMWheelController sharedController] start];
                   });
    // Diagnostics are deliberately initialized after SpringBoard launch and
    // away from keyboard host callbacks. UIKit clients only publish compact
    // Darwin events; this process is the sole asynchronous file writer.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       FLMStartDiagnosticWriter();
                       FLMPublishDiagnosticEvent(
                           FLMDiagnosticRoleSpringBoard,
                           FLMDiagnosticEventProcessReady,
                           0,
                           (uint16_t)(getpid() & 0xFFFF),
                           0);
                   });
}

%end

%ctor {
    if (notify_register_check(FLYME_RUNTIME_NOTIFICATION, &FlymeRuntimeToken) ==
        NOTIFY_STATUS_OK) {
        uint64_t state = (FLYME_RUNTIME_MAGIC << 32) | (uint32_t)getpid();
        notify_set_state(FlymeRuntimeToken, state);
        notify_post(FLYME_RUNTIME_NOTIFICATION);
    }
}
