#import <UIKit/UIKit.h>
#import <math.h>
#import <notify.h>
#import <unistd.h>

#import "FLMDiagnostics.h"

// SpringBoard owns the real keyboard Scene and its touch routing. This adapter
// is injected into UIKit application clients, but installs functional hooks
// only after the shared route identifies the current card target. The card is
// a presentation transform; it must never become the keyboard's coordinate
// system. UIKit therefore receives the full display-sized reference. On the
// independent landscape route this is explicitly 844x390, allowing a
// third-party keyboard to select its native landscape layout. The card is
// only a SpringBoard presentation surface:
// the independent landscape route keeps the system display at 844x390 while
// the target application's root view remains untouched. SpringBoard scales
// and rotates only the presenter surface inside the visual card; it never
// changes the keyboard's coordinate system to the card's physical bounds.
#define FLYME_KEYBOARD_NOTIFICATION "com.codex.flymemultitasking.keyboard-state-changed"
#define FLYME_KEYBOARD_SCENE_NOTIFICATION "com.codex.flymemultitasking.keyboard-scene-changed"
#define FLYME_KEYBOARD_SESSION_NOTIFICATION "com.codex.flymemultitasking.keyboard-session-changed"
#define FLYME_KEYBOARD_ORIENTATION_NOTIFICATION "com.codex.flymemultitasking.keyboard-orientation-changed"
#define FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION "com.codex.flymemultitasking.keyboard-avoidance-changed"
#define FLYME_KEYBOARD_SHARED_STATE_NOTIFICATION "com.codex.flymemultitasking.keyboard-shared-state-changed"
#define FLYME_KEYBOARD_APP_CTOR_NOTIFICATION "com.codex.flymemultitasking.keyboard-app-ctor-v47"
#define FLYME_KEYBOARD_APP_READY_NOTIFICATION "com.codex.flymemultitasking.keyboard-app-ready-v47"
#define FLYME_KEYBOARD_SHARED_STATE_VERSION 2
#define FLYME_KEYBOARD_APP_CTOR_MAGIC 0xF147ULL
#define FLYME_KEYBOARD_APP_READY_MAGIC 0xF247ULL
#define FLYME_KEYBOARD_APP_ADAPTER_BUILD 47ULL

static NSString *const FLMKeyboardSharedStatePath =
    @"/var/mobile/Library/Preferences/FlymeMultitasking-KeyboardState.plist";
static NSString *const FLMKeyboardSharedStateRootlessPath =
    @"/var/jb/var/mobile/Library/Preferences/FlymeMultitasking-KeyboardState.plist";

static BOOL FLMKeyboardRouteActive = NO;
static BOOL FLMKeyboardTargetApplication = NO;
static BOOL FLMKeyboardExtensionProcess = NO;
static UIInterfaceOrientation FLMKeyboardSharedInterfaceOrientation =
    UIInterfaceOrientationUnknown;
static BOOL FLMRemoteKeyboardGeometryInstalled = NO;
static int FLMKeyboardRouteToken = -1;
static int FLMKeyboardSceneToken = -1;
static int FLMKeyboardSessionToken = -1;
static int FLMKeyboardOrientationToken = -1;
static int FLMKeyboardAvoidanceToken = -1;
static int FLMKeyboardSharedStateToken = -1;
static uint64_t FLMKeyboardTargetSceneHash = 0;
static uint64_t FLMKeyboardSessionGeneration = 0;
static uint64_t FLMExternalKeyboardAvoidanceGeneration = 0;
static CGFloat FLMExternalKeyboardAvoidanceHeight = 0.0;
static int FLMKeyboardAppCtorToken = -1;
static int FLMKeyboardAppReadyToken = -1;
static BOOL FLMKeyboardHooksInstalled = NO;
static BOOL FLMKeyboardRouteObserversInstalled = NO;
static BOOL FLMKeyboardIdentityRetryScheduled = NO;
static BOOL FLMKeyboardRawLoadDiagnosticPublished = NO;
static uint16_t FLMKeyboardLastIdentityFlags = UINT16_MAX;
static NSUInteger FLMKeyboardIdentityRetryCount = 0;
static const NSUInteger FLMKeyboardIdentityRetryLimit = 8;

static void FLMInstallRemoteKeyboardGeometryIfAvailable(void);
static void FLMReloadKeyboardAvoidance(void);
static void FLMAttemptKeyboardInitialization(void);
static void FLMRegisterKeyboardNotificationsAndInitialize(void);
static void FLMHandleKeyboardRouteNotification(void);
static CGRect FLMSystemDisplayBoundsForScene(UIWindowScene *scene);
static CGRect FLMKeyboardDisplayBoundsForScene(UIWindowScene *scene);

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

static BOOL FLMProcessIsSpringBoardOrSystemAgent(void) {
    NSString *bundleIdentifier = [NSBundle mainBundle].bundleIdentifier;
    NSString *processName = [NSProcessInfo processInfo].processName;
    NSString *executableName = [NSBundle mainBundle].executablePath.lastPathComponent;
    NSSet<NSString *> *excludedExecutables = [NSSet setWithObjects:
        @"SpringBoard", @"backboardd", @"runningboardd", @"mediaserverd",
        @"assertiond", @"frontboardd", @"lsd", nil];
    return [bundleIdentifier isEqualToString:@"com.apple.springboard"] ||
           [processName isEqualToString:@"SpringBoard"] ||
           [excludedExecutables containsObject:processName] ||
           [excludedExecutables containsObject:executableName];
}

static BOOL FLMProcessIsApplicationClient(void) {
    // The filter is deliberately broad enough to reach an arbitrary wheel
    // target, so this process gate is the security boundary.  Extensions,
    // SpringBoard and launch/system agents never install Logos groups.
    NSDictionary *extension = [NSBundle mainBundle].infoDictionary[@"NSExtension"];
    BOOL isExtension = [extension isKindOfClass:[NSDictionary class]];
    NSString *bundleIdentifier = [NSBundle mainBundle].bundleIdentifier;
    return bundleIdentifier.length > 0 && !isExtension &&
           !FLMProcessIsSpringBoardOrSystemAgent() &&
           NSClassFromString(@"UIApplication") != Nil;
}

static uint16_t FLMApplicationProcessIdentityFlags(void) {
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *bundleIdentifier = mainBundle.bundleIdentifier;
    NSString *processName = [NSProcessInfo processInfo].processName;
    NSString *executableName = mainBundle.executablePath.lastPathComponent;
    NSDictionary *extension = mainBundle.infoDictionary[@"NSExtension"];
    BOOL bundlePresent = bundleIdentifier.length > 0;
    BOOL applicationClient = FLMProcessIsApplicationClient();
    BOOL extensionProcess = [extension isKindOfClass:[NSDictionary class]];
    BOOL systemAgent = FLMProcessIsSpringBoardOrSystemAgent();
    BOOL executablePresent = executableName.length > 0;
    BOOL processPresent = processName.length > 0;
    return (bundlePresent ? 1U : 0U) |
           (applicationClient ? 2U : 0U) |
           (extensionProcess ? 4U : 0U) |
           (systemAgent ? 8U : 0U) |
           (executablePresent ? 16U : 0U) |
           (processPresent ? 32U : 0U);
}

// FlymeKeyboard.plist reaches UIKit application clients rather than naming a
// single app. The shared-state route is the second, exact gate: only the
// process whose main bundle hash equals the current wheel target can install
// functional hooks. A dylib loaded into another app is diagnostic-only until
// a later route notification selects that app.
static BOOL FLMIsEligibleApplicationProcess(void) {
    return (FLMApplicationProcessIdentityFlags() & 2U) != 0;
}

static void FLMPublishKeyboardRawLoadDiagnostic(void) {
    if (!FLMIsEligibleApplicationProcess()) {
        return;
    }
    uint16_t flags = FLMApplicationProcessIdentityFlags();
    if (FLMKeyboardRawLoadDiagnosticPublished &&
        flags == FLMKeyboardLastIdentityFlags) {
        return;
    }
    FLMKeyboardRawLoadDiagnosticPublished = YES;
    FLMKeyboardLastIdentityFlags = flags;

    // This is deliberately the only pre-gate side effect.  It contains no
    // UI access, hook installation, route registration, or shared-state read.
    // A raw adapter-loaded event proves that the dylib reached this process;
    // its identity bits show whether the later target gate was premature.
    FLMDiagnosticRole role = FLMDiagnosticRoleApplication;
    FLMPublishDiagnosticEvent(role,
                              FLMDiagnosticEventAdapterLoaded,
                              0,
                              flags,
                              (uint16_t)(getpid() & 0xFFFF));
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
    if (currentHash == FLMKeyboardTargetSceneHash) {
        return YES;
    }
    // Once SpringBoard publishes a concrete scene hash, accepting a different
    // scene merely because it is the only connected scene is unsafe during
    // scene replacement. That fallback could route a stale keyboard into the
    // wrong application/card session.
    return NO;
}

static UIInterfaceOrientation FLMKeyboardEffectiveInterfaceOrientation(
    UIWindowScene *scene) {
    if (FLMKeyboardRouteActive &&
        UIInterfaceOrientationIsLandscape(
            FLMKeyboardSharedInterfaceOrientation)) {
        return FLMKeyboardSharedInterfaceOrientation;
    }
    return [scene isKindOfClass:[UIWindowScene class]]
               ? scene.interfaceOrientation
               : UIInterfaceOrientationUnknown;
}

static CGRect FLMSystemDisplayBoundsForScene(UIWindowScene *scene) {
    CGSize size = FLMFullPhysicalScreenSize();
    if (UIInterfaceOrientationIsLandscape(
            FLMKeyboardEffectiveInterfaceOrientation(scene))) {
        size = CGSizeMake(size.height, size.width);
    }
    return CGRectMake(0.0, 0.0, size.width, size.height);
}

static CGRect FLMKeyboardDisplayBoundsForScene(UIWindowScene *scene) {
    // Native keyboard geometry is always measured in the system display
    // coordinate space. This function must never consult the App viewport.
    return FLMSystemDisplayBoundsForScene(scene);
}

static CGRect FLMTargetApplicationLogicalBounds(void) {
    if (!FLMKeyboardTargetApplication || !FLMKeyboardRouteActive) {
        return CGRectZero;
    }
    // Avoidance is measured in the same full-screen Scene coordinate space as
    // the native landscape keyboard, never in the visual card's bounds.
    for (UIScene *connectedScene in
         [UIApplication sharedApplication].connectedScenes) {
        if (![connectedScene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)connectedScene;
        if (!FLMSceneMatchesKeyboardRoute(windowScene)) {
            continue;
        }
        // The selected Scene is the application's native full-screen
        // coordinate space for both content and keyboard geometry.
        return FLMSystemDisplayBoundsForScene(windowScene);
    }
    // During the initial Scene handoff there may be no connected window yet.
    // Keep the keyboard contract landscape from the shared route instead of
    // falling back to the old portrait virtual viewport.
    return FLMSystemDisplayBoundsForScene(nil);
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
    uint64_t orientationState = 0;
    if (FLMKeyboardOrientationToken < 0) {
        notify_register_check(FLYME_KEYBOARD_ORIENTATION_NOTIFICATION,
                              &FLMKeyboardOrientationToken);
    }
    if (FLMKeyboardRouteToken < 0) {
        notify_register_check(FLYME_KEYBOARD_NOTIFICATION,
                              &FLMKeyboardRouteToken);
    }
    if (FLMKeyboardSessionToken < 0) {
        notify_register_check(FLYME_KEYBOARD_SESSION_NOTIFICATION,
                              &FLMKeyboardSessionToken);
    }
    if (FLMKeyboardSceneToken < 0) {
        notify_register_check(FLYME_KEYBOARD_SCENE_NOTIFICATION,
                              &FLMKeyboardSceneToken);
    }
    if (FLMKeyboardOrientationToken >= 0) {
        notify_get_state(FLMKeyboardOrientationToken, &orientationState);
    }
    NSDictionary *sharedState = FLMReadKeyboardSharedState();
    BOOL sharedStateAvailable = sharedState != nil;
    BOOL sharedStateActive =
        [sharedState[@"active"] isKindOfClass:[NSNumber class]] &&
        [sharedState[@"active"] boolValue];
    NSString *sharedTargetIdentifier =
        [sharedState[@"bundleID"] isKindOfClass:[NSString class]]
            ? sharedState[@"bundleID"]
            : nil;
    NSNumber *sharedOrientationNumber =
        [sharedState[@"interfaceOrientation"] isKindOfClass:[NSNumber class]]
            ? sharedState[@"interfaceOrientation"]
            : nil;
    UIInterfaceOrientation sharedOrientation =
        sharedOrientationNumber
            ? (UIInterfaceOrientation)sharedOrientationNumber.integerValue
            : UIInterfaceOrientationUnknown;
    UIInterfaceOrientation notifiedOrientation =
        (UIInterfaceOrientation)orientationState;
    if (UIInterfaceOrientationIsLandscape(notifiedOrientation)) {
        // The notify state is updated before the route notification and before
        // the asynchronous plist write, so the first keyboard frame already
        // receives the landscape contract.
        sharedOrientation = notifiedOrientation;
    }
    BOOL notifyRouteStateAvailable =
        FLMKeyboardRouteToken >= 0 && FLMKeyboardSessionToken >= 0 &&
        FLMKeyboardSceneToken >= 0 &&
        notify_get_state(FLMKeyboardRouteToken, &targetHash) ==
            NOTIFY_STATUS_OK &&
        notify_get_state(FLMKeyboardSessionToken, &sessionGeneration) ==
            NOTIFY_STATUS_OK &&
        notify_get_state(FLMKeyboardSceneToken, &sceneHash) ==
            NOTIFY_STATUS_OK;
    if (!notifyRouteStateAvailable && sharedStateAvailable) {
        targetHash = sharedStateActive
                         ? FLMIdentifierHash(sharedTargetIdentifier)
                         : 0;
        sessionGeneration =
            [sharedState[@"sessionGeneration"] unsignedLongLongValue];
        sceneHash = [sharedState[@"sceneHash"] unsignedLongLongValue];
    }

    BOOL previousTargetApplication = FLMKeyboardTargetApplication;
    uint64_t previousGeneration = FLMKeyboardSessionGeneration;
    uint64_t currentHash =
        FLMIdentifierHash([NSBundle mainBundle].bundleIdentifier);
    uint16_t applicationIdentityFlags = FLMApplicationProcessIdentityFlags();
    FLMKeyboardExtensionProcess = FLMProcessIsKeyboardExtension();
    FLMKeyboardTargetApplication =
        sessionGeneration != 0 && targetHash != 0 &&
        currentHash != 0 && targetHash == currentHash &&
        FLMIsEligibleApplicationProcess();
    FLMKeyboardRouteActive =
        FLMKeyboardTargetApplication ||
        (FLMKeyboardExtensionProcess && sessionGeneration != 0 && targetHash != 0);
    if (!FLMKeyboardRouteActive) {
        FLMKeyboardSharedInterfaceOrientation = UIInterfaceOrientationUnknown;
    } else {
        // SpringBoard publishes this independently of the target app Scene.
        // Prefer it over the transient Scene orientation during rotation.
        FLMKeyboardSharedInterfaceOrientation = sharedOrientation;
    }
    FLMKeyboardSessionGeneration = sessionGeneration;
    FLMKeyboardTargetSceneHash = sceneHash;
    if (FLMKeyboardRouteActive || previousTargetApplication ||
        previousGeneration != sessionGeneration) {
        NSLog(@"[FlymeKeyboard] keyboard-route-state session=%llu active=%d target=%d orientation=%ld display=%@ contentContract=full-screen-landscape source=%@",
              (unsigned long long)FLMKeyboardSessionGeneration,
              FLMKeyboardRouteActive, FLMKeyboardTargetApplication,
              (long)FLMKeyboardSharedInterfaceOrientation,
              NSStringFromCGRect(FLMKeyboardDisplayBoundsForScene(nil)),
              notifyRouteStateAvailable ? @"notify" : @"plist");
    }

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
            ((applicationIdentityFlags & 1U) != 0 ? 32U : 0U) |
            ((applicationIdentityFlags & 2U) != 0 ? 64U : 0U) |
            ((applicationIdentityFlags & 4U) != 0 ? 128U : 0U) |
             (sharedStateAvailable ? 256U : 0U) |
            (sharedStateActive ? 512U : 0U) |
            (UIInterfaceOrientationIsLandscape(
                 FLMKeyboardSharedInterfaceOrientation)
                 ? 1024U
                 : 0U);
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
    // This fallback is deliberately full-screen. Card bottom and card scale
    // belong to presentation, not to the UIKit keyboard contract.
    if (CGRectGetHeight(logicalBounds) <= 1.0) {
        return 0.0;
    }
    CGSize physicalSize = FLMFullPhysicalScreenSize();
    if (UIInterfaceOrientationIsLandscape(
            FLMKeyboardSharedInterfaceOrientation)) {
        physicalSize = CGSizeMake(physicalSize.height, physicalSize.width);
    }
    CGFloat physicalOverlap = MAX(0.0, physicalSize.height - keyboardTop);
    if (physicalOverlap <= 1.0) {
        return 0.0;
    }
    CGFloat logicalHeight = physicalOverlap;
    return MIN(CGRectGetHeight(logicalBounds) * 0.72, logicalHeight);
}

%group FLMRemoteKeyboardGeometry

%hook UITextEffectsWindow

- (CGSize)keyboardScreenReferenceSize {
    FLMReloadKeyboardRoute();
    UIWindowScene *scene = ((UIWindow *)self).windowScene;
    if (!FLMSceneMatchesKeyboardRoute(scene)) {
        return %orig;
    }
    CGSize size = FLMKeyboardDisplayBoundsForScene(scene).size;
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
        UIInterfaceOrientationIsLandscape(
            FLMKeyboardEffectiveInterfaceOrientation(windowScene))) {
        return originalHeight;
    }

    // Prefer UIKit's native full-screen intersection. If UIKit reports no
    // intersection during a Scene handoff, derive the same value from the
    // full-screen reference only; never substitute the card's shared geometry
    // or its scaled bottom edge as the keyboard coordinate source.
    CGRect logicalBounds = FLMTargetApplicationLogicalBounds();
    CGSize physicalSize = FLMFullPhysicalScreenSize();
    CGFloat mappedHeight = FLMLogicalAvoidanceForPhysicalKeyboardTop(
        physicalSize.height - MAX(0.0, originalHeight), logicalBounds);
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

static void FLMRegisterKeyboardRouteObserversIfNeeded(void) {
    if (FLMKeyboardRouteObserversInstalled || !FLMIsEligibleApplicationProcess()) {
        return;
    }
    FLMKeyboardRouteObserversInstalled = YES;
    notify_register_dispatch(FLYME_KEYBOARD_NOTIFICATION,
                             &FLMKeyboardRouteToken,
                             dispatch_get_main_queue(),
                             ^(__unused int token) {
                                 FLMHandleKeyboardRouteNotification();
                             });
    notify_register_dispatch(FLYME_KEYBOARD_SCENE_NOTIFICATION,
                             &FLMKeyboardSceneToken,
                             dispatch_get_main_queue(),
                             ^(__unused int token) {
                                 FLMHandleKeyboardRouteNotification();
                             });
    notify_register_dispatch(FLYME_KEYBOARD_SESSION_NOTIFICATION,
                             &FLMKeyboardSessionToken,
                             dispatch_get_main_queue(),
                             ^(__unused int token) {
                                 FLMHandleKeyboardRouteNotification();
                             });
    notify_register_dispatch(FLYME_KEYBOARD_ORIENTATION_NOTIFICATION,
                             &FLMKeyboardOrientationToken,
                             dispatch_get_main_queue(),
                             ^(__unused int token) {
                                 FLMHandleKeyboardRouteNotification();
                             });
    notify_register_dispatch(FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION,
                             &FLMKeyboardAvoidanceToken,
                             dispatch_get_main_queue(),
                             ^(__unused int token) {
                                 FLMReloadKeyboardAvoidance();
                             });
    notify_register_dispatch(FLYME_KEYBOARD_SHARED_STATE_NOTIFICATION,
                             &FLMKeyboardSharedStateToken,
                             dispatch_get_main_queue(),
                             ^(__unused int token) {
                                 FLMHandleKeyboardRouteNotification();
                             });
}

static void FLMHandleKeyboardRouteNotification(void) {
    FLMReloadKeyboardRoute();
    if (!FLMKeyboardHooksInstalled && FLMIsEligibleApplicationProcess() &&
        FLMKeyboardTargetApplication) {
        // UIKit may load this generic adapter before SpringBoard publishes
        // the wheel target. A later route event must be able to complete the
        // target-gated initialization without waiting for the retry budget.
        FLMRegisterKeyboardNotificationsAndInitialize();
    }
}

static void FLMRegisterKeyboardNotificationsAndInitialize(void) {
    if (FLMKeyboardHooksInstalled || !FLMIsEligibleApplicationProcess() ||
        !FLMKeyboardTargetApplication) {
        return;
    }
    FLMKeyboardHooksInstalled = YES;

    // The two independent notify states make a failed device run
    // unambiguous: no ctor token means no target-gated initialization; ctor
    // without ready means initialization did not complete.  The raw-loaded
    // diagnostic published before this function additionally distinguishes a
    // missing injection from a constructor that ran before identity settled.
    FLMPublishKeyboardAppLifecycleStage(
        FLYME_KEYBOARD_APP_CTOR_NOTIFICATION,
        &FLMKeyboardAppCtorToken,
        FLYME_KEYBOARD_APP_CTOR_MAGIC,
        FLMDiagnosticEventAdapterCtor);
    // Do not install any application-window or root-view layout hooks here.
    // The target Scene is already full-screen landscape; the card transform
    // belongs exclusively to SpringBoard's presenter surface.
    FLMInstallRemoteKeyboardGeometryIfAvailable();
    FLMReloadKeyboardRoute();
    FLMPublishKeyboardAppLifecycleStage(
        FLYME_KEYBOARD_APP_READY_NOTIFICATION,
        &FLMKeyboardAppReadyToken,
        FLYME_KEYBOARD_APP_READY_MAGIC,
        FLMDiagnosticEventAdapterReady);
}

static void FLMScheduleKeyboardIdentityRetry(void) {
    if (FLMKeyboardHooksInstalled || !FLMIsEligibleApplicationProcess() ||
        FLMKeyboardIdentityRetryScheduled ||
        FLMKeyboardIdentityRetryCount >= FLMKeyboardIdentityRetryLimit) {
        return;
    }
    FLMKeyboardIdentityRetryScheduled = YES;
    NSUInteger attempt = ++FLMKeyboardIdentityRetryCount;
    NSTimeInterval delay = MIN(2.0, 0.10 * pow(2.0, (double)attempt));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       FLMKeyboardIdentityRetryScheduled = NO;
                       FLMPublishKeyboardRawLoadDiagnostic();
                       FLMAttemptKeyboardInitialization();
                   });
}

static void FLMAttemptKeyboardInitialization(void) {
    if (FLMKeyboardHooksInstalled) {
        return;
    }
    FLMPublishKeyboardRawLoadDiagnostic();
    if (!FLMIsEligibleApplicationProcess()) {
        // Do not install observers, Logos groups, or UI hooks in SpringBoard,
        // keyboard extensions, system agents, or app extensions.
        return;
    }
    // The observer is lightweight and target-agnostic. It lets a process that
    // loaded before the wheel published its target become the selected app
    // later, while all functional hooks remain behind the exact bundle-hash
    // route gate.
    FLMRegisterKeyboardRouteObserversIfNeeded();
    FLMReloadKeyboardRoute();
    if (!FLMKeyboardTargetApplication) {
        FLMScheduleKeyboardIdentityRetry();
        return;
    }
    FLMRegisterKeyboardNotificationsAndInitialize();
}

%ctor {
    @autoreleasepool {
        // This first call is intentionally safe even when the broad UIKit
        // filter loads the dylib before the route has selected this app. All
        // functional setup remains behind the application/process and exact
        // shared bundle-hash gates.
        FLMPublishKeyboardRawLoadDiagnostic();
        FLMAttemptKeyboardInitialization();
    }
}
