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
#define FLYME_KEYBOARD_SHARED_STATE_NOTIFICATION "com.codex.flymemultitasking.keyboard-shared-state-changed"
#define FLYME_KEYBOARD_APP_CTOR_NOTIFICATION "com.codex.flymemultitasking.keyboard-app-ctor-v46"
#define FLYME_KEYBOARD_APP_READY_NOTIFICATION "com.codex.flymemultitasking.keyboard-app-ready-v46"
#define FLYME_KEYBOARD_SHARED_STATE_VERSION 2
#define FLYME_KEYBOARD_APP_CTOR_MAGIC 0xF146ULL
#define FLYME_KEYBOARD_APP_READY_MAGIC 0xF246ULL
#define FLYME_KEYBOARD_APP_ADAPTER_BUILD 46ULL

static NSString *const FLMKeyboardSharedStatePath =
    @"/var/mobile/Library/Preferences/FlymeMultitasking-KeyboardState.plist";
static NSString *const FLMKeyboardSharedStateRootlessPath =
    @"/var/jb/var/mobile/Library/Preferences/FlymeMultitasking-KeyboardState.plist";

static BOOL FLMKeyboardRouteActive = NO;
static BOOL FLMKeyboardTargetApplication = NO;
static BOOL FLMKeyboardExtensionProcess = NO;
static BOOL FLMRemoteKeyboardGeometryInstalled = NO;
static int FLMKeyboardRouteToken = -1;
static int FLMKeyboardSceneToken = -1;
static int FLMKeyboardSessionToken = -1;
static int FLMKeyboardAvoidanceToken = -1;
static int FLMKeyboardCardGeometryToken = -1;
static int FLMKeyboardSharedStateToken = -1;
static uint64_t FLMKeyboardTargetSceneHash = 0;
static uint64_t FLMKeyboardSessionGeneration = 0;
static uint64_t FLMExternalKeyboardAvoidanceGeneration = 0;
static CGFloat FLMExternalKeyboardAvoidanceHeight = 0.0;
static BOOL FLMKeyboardCardGeometryActive = NO;
static uint64_t FLMKeyboardCardGeometryGeneration = 0;
static CGFloat FLMKeyboardCardBottom = 0.0;
static CGFloat FLMKeyboardCardVisualScale = 0.0;
static int FLMKeyboardAppCtorToken = -1;
static int FLMKeyboardAppReadyToken = -1;

static void FLMInstallRemoteKeyboardGeometryIfAvailable(void);
static void FLMReloadKeyboardAvoidance(void);
static void FLMReloadKeyboardCardGeometry(void);

static void FLMPublishKeyboardAppLifecycleStage(const char *notificationName,
                                                int *token,
                                                uint64_t magic,
                                                FLMDiagnosticEvent event) {
    if (*token < 0 &&
        notify_register_check(notificationName, token) != NOTIFY_STATUS_OK) {
        *token = -1;
        return;
    }
    uint64_t state = (magic << 48) |
                     (FLYME_KEYBOARD_APP_ADAPTER_BUILD << 32) |
                     (uint32_t)getpid();
    notify_set_state(*token, state);
    notify_post(notificationName);
    FLMPublishDiagnosticEvent(FLMDiagnosticRoleApplication,
                              event,
                              0,
                              (uint16_t)FLYME_KEYBOARD_APP_ADAPTER_BUILD,
                              (uint16_t)(getpid() & 0xFFFF));
}

static NSDictionary *FLMReadKeyboardSharedState(void) {
    NSDictionary *state =
        [NSDictionary dictionaryWithContentsOfFile:FLMKeyboardSharedStatePath];
    if (![state isKindOfClass:[NSDictionary class]]) {
        state = [NSDictionary
            dictionaryWithContentsOfFile:FLMKeyboardSharedStateRootlessPath];
    }
    NSNumber *version = [state[@"version"] isKindOfClass:[NSNumber class]]
                            ? state[@"version"]
                            : nil;
    return version.integerValue >= FLYME_KEYBOARD_SHARED_STATE_VERSION
               ? state
               : nil;
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

static uint16_t FLMWeChatProcessIdentityFlags(void) {
    static NSString *const bundleIdentifier = @"com.tencent.xin";
    BOOL containsBundle = NO;
    for (NSBundle *bundle in [NSBundle allBundles]) {
        if ([bundle.bundleIdentifier isEqualToString:bundleIdentifier]) {
            containsBundle = YES;
            break;
        }
    }
    if (!containsBundle &&
        [[NSBundle mainBundle].bundleIdentifier isEqualToString:bundleIdentifier]) {
        containsBundle = YES;
    }

    NSString *processName = [NSProcessInfo processInfo].processName;
    NSString *executableName =
        [NSBundle mainBundle].executablePath.lastPathComponent;
    BOOL executableMatches =
        [processName isEqualToString:@"WeChat"] ||
        [executableName isEqualToString:@"WeChat"];
    return (containsBundle ? 1U : 0U) | (executableMatches ? 2U : 0U);
}

// The original TrollOpen keyboard adapter is filtered through UIKit, not the
// application bundle. That reaches the process that owns the UIKit keyboard
// contract on this iOS version, but it also maps the dylib into many processes.
// Do not initialise hooks, notify state, or UI access unless both independent
// checks prove that this is WeChat's main process.
static BOOL FLMIsTargetWeChatProcess(void) {
    return (FLMWeChatProcessIdentityFlags() & 3U) == 3U;
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

static void FLMSuppressRestoredApplicationResponder(uint64_t generation) {
    if (generation == 0) {
        return;
    }
    FLMEndPreviousApplicationKeyboardSession(generation);
    // The hosted Scene may restore its saved first responder shortly after the
    // route becomes active.  Clear exactly once after that restore window but
    // before SpringBoard exposes the centered card for user interaction.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.22 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!FLMKeyboardTargetApplication || !FLMKeyboardRouteActive ||
            FLMKeyboardSessionGeneration != generation) {
            return;
        }
        FLMEndPreviousApplicationKeyboardSession(generation);
    });
}

static void FLMReloadKeyboardRoute(void) {
    uint64_t targetHash = 0;
    uint64_t sessionGeneration = 0;
    uint64_t sceneHash = 0;
    NSDictionary *sharedState = FLMReadKeyboardSharedState();
    BOOL sharedStateAvailable = sharedState != nil;
    BOOL sharedStateActive =
        [sharedState[@"active"] isKindOfClass:[NSNumber class]] &&
        [sharedState[@"active"] boolValue];
    NSString *sharedTargetIdentifier =
        [sharedState[@"bundleID"] isKindOfClass:[NSString class]]
            ? sharedState[@"bundleID"]
            : nil;
    if (sharedStateAvailable) {
        targetHash = sharedStateActive
                         ? FLMIdentifierHash(sharedTargetIdentifier)
                         : 0;
        sessionGeneration =
            [sharedState[@"sessionGeneration"] unsignedLongLongValue];
        sceneHash = [sharedState[@"sceneHash"] unsignedLongLongValue];
    } else if (FLMKeyboardRouteToken >= 0) {
        notify_get_state(FLMKeyboardRouteToken, &targetHash);
        if (FLMKeyboardSessionToken >= 0) {
            notify_get_state(FLMKeyboardSessionToken, &sessionGeneration);
        }
        if (FLMKeyboardSceneToken >= 0) {
            notify_get_state(FLMKeyboardSceneToken, &sceneHash);
        }
    }

    BOOL previousTargetApplication = FLMKeyboardTargetApplication;
    uint64_t previousGeneration = FLMKeyboardSessionGeneration;
    uint64_t currentHash =
        FLMIdentifierHash([NSBundle mainBundle].bundleIdentifier);
    uint16_t weChatIdentityFlags = FLMWeChatProcessIdentityFlags();
    BOOL explicitWeChatTarget =
        targetHash == FLMIdentifierHash(@"com.tencent.xin") &&
        (weChatIdentityFlags & 1U) != 0 &&
        (weChatIdentityFlags & 2U) != 0;
    FLMKeyboardExtensionProcess = FLMProcessIsKeyboardExtension();
    FLMKeyboardTargetApplication =
        sessionGeneration != 0 && targetHash != 0 &&
        ((currentHash != 0 && targetHash == currentHash) ||
         explicitWeChatTarget);
    FLMKeyboardRouteActive =
        FLMKeyboardTargetApplication ||
        (FLMKeyboardExtensionProcess && sessionGeneration != 0 && targetHash != 0);
    FLMKeyboardSessionGeneration = sessionGeneration;
    FLMKeyboardTargetSceneHash = sceneHash;

    BOOL startingTargetSession =
        FLMKeyboardTargetApplication && sessionGeneration != 0 &&
        (!previousTargetApplication || previousGeneration != sessionGeneration);
    if (startingTargetSession) {
        FLMSuppressRestoredApplicationResponder(sessionGeneration);
    } else if (previousTargetApplication && previousGeneration != 0 &&
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
             (sceneHash != 0 ? 16U : 0U) |
             (explicitWeChatTarget ? 32U : 0U) |
             ((weChatIdentityFlags & 1U) != 0 ? 64U : 0U) |
             ((weChatIdentityFlags & 2U) != 0 ? 128U : 0U) |
             (sharedStateAvailable ? 256U : 0U) |
             (sharedStateActive ? 512U : 0U);
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
    NSDictionary *sharedState = FLMReadKeyboardSharedState();
    if (sharedState) {
        BOOL active = [sharedState[@"cardActive"] boolValue];
        uint64_t generation =
            [sharedState[@"sessionGeneration"] unsignedLongLongValue] &
            0x7FFFULL;
        CGFloat cardBottom = [sharedState[@"cardBottom"] doubleValue];
        CGFloat visualScale = [sharedState[@"cardScale"] doubleValue];
        BOOL current = FLMKeyboardTargetApplication && active &&
                       generation != 0 &&
                       generation ==
                           (FLMKeyboardSessionGeneration & 0x7FFFULL) &&
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
                FLMDiagnosticUnsignedValue(FLMKeyboardCardVisualScale *
                                           1000.0));
        }
        return;
    }
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
            FLMDiagnosticUnsignedValue(FLMKeyboardCardVisualScale * 1000.0));
    }
}

static void FLMReloadKeyboardAvoidance(void) {
    uint64_t state = 0;
    NSDictionary *sharedState = FLMReadKeyboardSharedState();
    BOOL visible = NO;
    uint64_t generation = 0;
    CGFloat height = 0.0;
    if (sharedState) {
        visible = [sharedState[@"avoidanceVisible"] boolValue];
        generation =
            [sharedState[@"sessionGeneration"] unsignedLongLongValue];
        height = [sharedState[@"avoidanceHeight"] doubleValue];
    } else if (FLMKeyboardAvoidanceToken < 0 ||
        notify_get_state(FLMKeyboardAvoidanceToken, &state) != NOTIFY_STATUS_OK) {
        return;
    } else {
        visible = (state & (1ULL << 63)) != 0;
        generation = (state >> 24) & 0x7FFFFFFFFFULL;
        height = (CGFloat)(state & 0xFFFFFFULL) / 100.0;
    }
    uint64_t previousGeneration = FLMExternalKeyboardAvoidanceGeneration;
    CGFloat previousHeight = FLMExternalKeyboardAvoidanceHeight;
    BOOL current = FLMKeyboardTargetApplication && visible && generation != 0 &&
                   generation == FLMKeyboardSessionGeneration;
    FLMExternalKeyboardAvoidanceGeneration = current ? generation : 0;
    FLMExternalKeyboardAvoidanceHeight = current ? MAX(0.0, height) : 0.0;
    BOOL changed = previousGeneration != FLMExternalKeyboardAvoidanceGeneration ||
                   fabs(previousHeight - FLMExternalKeyboardAvoidanceHeight) >
                       0.25;
    if (FLMKeyboardTargetApplication && changed) {
        FLMPublishDiagnosticEvent(
            FLMDiagnosticRoleApplication,
            FLMDiagnosticEventAvoidanceReload,
            FLMKeyboardSessionGeneration,
            current ? 1 : 0,
            FLMDiagnosticUnsignedValue(FLMExternalKeyboardAvoidanceHeight));
        FLMRefreshApplicationKeyboardLayout();
    }
}

static CGFloat FLMLogicalAvoidanceForPhysicalKeyboardTop(CGFloat keyboardTop,
                                                          CGRect logicalBounds) {
    if (!FLMKeyboardCardGeometryActive ||
        FLMKeyboardCardGeometryGeneration !=
            (FLMKeyboardSessionGeneration & 0x7FFFULL) ||
        FLMKeyboardCardVisualScale <= 0.05 ||
        CGRectGetHeight(logicalBounds) <= 1.0) {
        return 0.0;
    }
    CGFloat physicalOverlap = MAX(0.0, FLMKeyboardCardBottom - keyboardTop);
    if (physicalOverlap <= 1.0) {
        return 0.0;
    }
    CGFloat logicalHeight =
        physicalOverlap / FLMKeyboardCardVisualScale +
        8.0 / FLMKeyboardCardVisualScale;
    return MIN(CGRectGetHeight(logicalBounds) * 0.72, logicalHeight);
}

%hook UITextEffectsWindow

- (CGSize)keyboardScreenReferenceSize {
    FLMReloadKeyboardRoute();
    UIWindowScene *scene = ((UIWindow *)self).windowScene;
    if (!FLMSceneMatchesKeyboardRoute(scene)) {
        return %orig;
    }
    CGSize size = FLMPhysicalReferenceBoundsForScene(scene).size;
    FLMPublishDiagnosticEvent(
        FLMKeyboardTargetApplication ? FLMDiagnosticRoleApplication
                                     : FLMDiagnosticRoleKeyboardExtension,
        FLMDiagnosticEventFrameCorrected,
        FLMKeyboardSessionGeneration,
        FLMDiagnosticUnsignedValue(size.width),
        FLMDiagnosticUnsignedValue(size.height));
    return size;
}

%end

%group FLMRemoteKeyboardGeometry

%hook _UIRemoteKeyboards

- (CGFloat)intersectionHeightForWindowScene:(UIWindowScene *)windowScene
                    isLocalMinimumHeightOut:(BOOL *)isLocalMinimumHeightOut
                     ignoreHorizontalOffset:(BOOL)ignoreHorizontalOffset {
    FLMReloadKeyboardRoute();
    CGFloat originalHeight = %orig(windowScene,
                                   isLocalMinimumHeightOut,
                                   ignoreHorizontalOffset);
    if (!FLMKeyboardTargetApplication ||
        !FLMSceneMatchesKeyboardRoute(windowScene) ||
        UIInterfaceOrientationIsLandscape(windowScene.interfaceOrientation)) {
        return originalHeight;
    }

    CGFloat mappedHeight = 0.0;
    if (FLMExternalKeyboardAvoidanceGeneration ==
            FLMKeyboardSessionGeneration &&
        FLMExternalKeyboardAvoidanceHeight > 1.0) {
        mappedHeight = FLMExternalKeyboardAvoidanceHeight;
    } else {
        CGRect logicalBounds = FLMTargetApplicationLogicalBounds();
        CGSize physicalSize = FLMFullPhysicalScreenSize();
        mappedHeight = FLMLogicalAvoidanceForPhysicalKeyboardTop(
            physicalSize.height - MAX(0.0, originalHeight), logicalBounds);
    }
    if (mappedHeight <= 1.0) {
        mappedHeight = originalHeight;
    }
    FLMPublishDiagnosticEvent(
        FLMDiagnosticRoleApplication,
        FLMDiagnosticEventIntersection,
        FLMKeyboardSessionGeneration,
        FLMDiagnosticUnsignedValue(originalHeight),
        FLMDiagnosticUnsignedValue(mappedHeight));
    // A hosted Scene can already receive a valid UIKit intersection computed
    // from the physical keyboard. Flyme only supplies missing external-card
    // avoidance; it must never reduce UIKit's native value.
    return MAX(originalHeight, mappedHeight);
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
        if (!FLMIsTargetWeChatProcess()) {
            return;
        }
        // The two independent notify states make a failed device run
        // unambiguous: no ctor token means no injection; ctor without ready
        // means initialization did not complete; both mean SpringBoard can
        // validate the exact build and live process without relying on logs
        // written from the sandboxed application.
        FLMPublishKeyboardAppLifecycleStage(
            FLYME_KEYBOARD_APP_CTOR_NOTIFICATION,
            &FLMKeyboardAppCtorToken,
            FLYME_KEYBOARD_APP_CTOR_MAGIC,
            FLMDiagnosticEventAdapterCtor);
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
        notify_register_dispatch(FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION,
                                 &FLMKeyboardAvoidanceToken,
                                 dispatch_get_main_queue(),
                                 ^(__unused int token) {
            FLMReloadKeyboardAvoidance();
        });
        notify_register_dispatch(FLYME_KEYBOARD_CARD_GEOMETRY_NOTIFICATION,
                                 &FLMKeyboardCardGeometryToken,
                                 dispatch_get_main_queue(),
                                 ^(__unused int token) {
            FLMReloadKeyboardCardGeometry();
        });
        notify_register_dispatch(FLYME_KEYBOARD_SHARED_STATE_NOTIFICATION,
                                 &FLMKeyboardSharedStateToken,
                                 dispatch_get_main_queue(),
                                 ^(__unused int token) {
            FLMReloadKeyboardRoute();
        });
        FLMInstallRemoteKeyboardGeometryIfAvailable();
        FLMReloadKeyboardRoute();
        FLMPublishKeyboardAppLifecycleStage(
            FLYME_KEYBOARD_APP_READY_NOTIFICATION,
            &FLMKeyboardAppReadyToken,
            FLYME_KEYBOARD_APP_READY_MAGIC,
            FLMDiagnosticEventAdapterReady);
    }
}
