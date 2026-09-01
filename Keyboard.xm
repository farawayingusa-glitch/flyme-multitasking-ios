#import <UIKit/UIKit.h>
#import <math.h>
#import <notify.h>
#import <unistd.h>

#import "FLMDiagnostics.h"

// SpringBoard owns the real keyboard Scene and its touch routing. This adapter
// is injected into UIKit application clients, but installs functional hooks
// only after the shared route identifies the current card target. The card is
// a presentation transform; it must never become the keyboard's coordinate
// system. UIKit therefore receives the display-sized reference (390x844 on
// the target device). The card is only a SpringBoard presentation surface:
// the app and keyboard continue to use the full-screen 390x844 logical space.
// SpringBoard applies one uniform presentation scale and clips only the
// explicitly selected top/bottom card crop; it never changes the app's
// keyboard coordinate system to the card's physical bounds.
#define FLYME_KEYBOARD_NOTIFICATION "com.codex.flymemultitasking.keyboard-state-changed"
#define FLYME_KEYBOARD_SCENE_NOTIFICATION "com.codex.flymemultitasking.keyboard-scene-changed"
#define FLYME_KEYBOARD_SESSION_NOTIFICATION "com.codex.flymemultitasking.keyboard-session-changed"
#define FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION "com.codex.flymemultitasking.keyboard-avoidance-changed"
#define FLYME_KEYBOARD_CARD_GEOMETRY_NOTIFICATION "com.codex.flymemultitasking.keyboard-card-geometry-changed"
#define FLYME_KEYBOARD_SHARED_STATE_NOTIFICATION "com.codex.flymemultitasking.keyboard-shared-state-changed"
#define FLYME_KEYBOARD_APP_CTOR_NOTIFICATION "com.codex.flymemultitasking.keyboard-app-ctor-v53"
#define FLYME_KEYBOARD_APP_READY_NOTIFICATION "com.codex.flymemultitasking.keyboard-app-ready-v53"
#define FLYME_KEYBOARD_DISMISS_REQUEST_NOTIFICATION "com.codex.flymemultitasking.keyboard-dismiss-request-reset-v1"
#define FLYME_KEYBOARD_SHARED_STATE_VERSION 3
#define FLYME_KEYBOARD_APP_CTOR_MAGIC 0xF153ULL
#define FLYME_KEYBOARD_APP_READY_MAGIC 0xF253ULL
#define FLYME_KEYBOARD_APP_ADAPTER_BUILD 53ULL

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
static int FLMKeyboardDismissRequestToken = -1;
static int FLMDockInputBlockToken = -1;
static NSMutableSet<UITouch *> *FLMDockInputSuppressedTouches;
static uint64_t FLMKeyboardLastTargetSessionGeneration = 0;
static uint64_t FLMKeyboardLastDismissRequestState = 0;
static BOOL FLMKeyboardHooksInstalled = NO;
static BOOL FLMKeyboardRouteObserversInstalled = NO;
static BOOL FLMContentViewportAdapterApplying = NO;
static BOOL FLMContentViewportAdapterActive = NO;
static uint64_t FLMContentViewportAdapterGeneration = 0;
static NSMapTable<UIView *, NSDictionary *> *FLMContentViewportOriginalLayouts;
static BOOL FLMKeyboardIdentityRetryScheduled = NO;
static BOOL FLMDockInputBarrierInstalled = NO;
static BOOL FLMDockInputBarrierRetryScheduled = NO;
static BOOL FLMKeyboardRawLoadDiagnosticPublished = NO;
static uint16_t FLMKeyboardLastIdentityFlags = UINT16_MAX;
static NSUInteger FLMKeyboardIdentityRetryCount = 0;
static NSUInteger FLMDockInputBarrierRetryCount = 0;
static const NSUInteger FLMKeyboardIdentityRetryLimit = 8;

// The application-side logical viewport is deliberately fixed at the full
// display size. Card width/crop values belong to SpringBoard presentation and
// must not turn into a second application layout viewport.
static CGSize FLMContentLogicalViewportSize = {
    390.0,
    844.0,
};
static CGFloat FLMContentExternalScale = 1.0;
static CGSize FLMPhysicalCardSize = {
    390.0,
    844.0,
};
static BOOL FLMContentViewportUsesSharedCardSize = NO;
// Shared-state v3 landscape contract. The target app owns a real landscape
// UIWindowScene for system keyboard semantics, but its visible root content is
// held on a 390x844 portrait logical canvas inside that Scene.
static BOOL FLMKeyboardLandscapeScene = NO;
static UIInterfaceOrientation FLMKeyboardInterfaceOrientation = UIInterfaceOrientationPortrait;
static CGSize FLMKeyboardSystemReferenceSize = CGSizeZero;

static void FLMInstallRemoteKeyboardGeometryIfAvailable(void);
static void FLMReloadKeyboardAvoidance(void);
static void FLMReloadKeyboardCardGeometry(void);
static void FLMReloadContentViewportSelection(NSDictionary *sharedState);
static void FLMAttemptKeyboardInitialization(void);
static void FLMRegisterKeyboardNotificationsAndInitialize(void);
static void FLMRegisterKeyboardDismissObserverIfNeeded(void);
static void FLMHandleKeyboardRouteNotification(void);
static void FLMUpdateContentViewportAdapter(void);
static void FLMInstallDockInputBarrierIfEligible(void);
static void FLMScheduleDockInputBarrierRetry(void);

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

static void FLMReloadContentViewportSelection(NSDictionary *sharedState) {
    const CGSize fallback = {390.0, 844.0};
    FLMContentLogicalViewportSize = fallback;
    FLMContentExternalScale = 1.0;
    FLMPhysicalCardSize = fallback;
    FLMContentViewportUsesSharedCardSize = NO;
    FLMKeyboardLandscapeScene = NO;
    FLMKeyboardInterfaceOrientation = UIInterfaceOrientationPortrait;
    FLMKeyboardSystemReferenceSize = CGSizeZero;
    if (![sharedState isKindOfClass:[NSDictionary class]]) {
        return;
    }
    BOOL active = [sharedState[@"active"] boolValue];
    BOOL landscape = active && [sharedState[@"landscapeScene"] boolValue];
    CGFloat systemWidth = [sharedState[@"systemWidth"] doubleValue];
    CGFloat systemHeight = [sharedState[@"systemHeight"] doubleValue];
    NSInteger orientation = [sharedState[@"interfaceOrientation"] integerValue];
    if (!landscape || systemWidth <= systemHeight + 1.0 ||
        systemWidth < 1.0 || systemHeight < 1.0) {
        return;
    }
    FLMKeyboardLandscapeScene = YES;
    FLMKeyboardSystemReferenceSize = CGSizeMake(systemWidth, systemHeight);
    FLMKeyboardInterfaceOrientation =
        (orientation == UIInterfaceOrientationLandscapeLeft ||
         orientation == UIInterfaceOrientationLandscapeRight)
            ? (UIInterfaceOrientation)orientation
            : UIInterfaceOrientationLandscapeLeft;
    FLMContentExternalScale = systemHeight / fallback.height;
    FLMPhysicalCardSize = CGSizeMake(fallback.width * FLMContentExternalScale,
                                     systemHeight);
    FLMContentViewportUsesSharedCardSize = YES;
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

static uint64_t FLMCurrentApplicationIdentifierHash(void) {
    static uint64_t identifierHash = 0;
    if (identifierHash == 0) {
        identifierHash =
            FLMIdentifierHash([NSBundle mainBundle].bundleIdentifier);
    }
    return identifierHash;
}

static BOOL FLMDockInputBlockedForCurrentApplication(void) {
    if (FLMDockInputBlockToken < 0 &&
        notify_register_check(FLYME_DOCK_INPUT_BLOCK_NOTIFICATION,
                              &FLMDockInputBlockToken) != NOTIFY_STATUS_OK) {
        FLMDockInputBlockToken = -1;
        return NO;
    }
    uint64_t state = 0;
    if (notify_get_state(FLMDockInputBlockToken, &state) !=
        NOTIFY_STATUS_OK) {
        return NO;
    }
    return FLMDockInputBlockStateMatches(
        state, FLMCurrentApplicationIdentifierHash());
}

static BOOL FLMShouldSuppressDockTouchEvent(UIEvent *event,
                                            BOOL routeBlocked,
                                            BOOL *containsBeganTouch) {
    NSSet<UITouch *> *touches = event.allTouches;
    if (!FLMDockInputSuppressedTouches) {
        FLMDockInputSuppressedTouches = [NSMutableSet set];
    }
    BOOL began = NO;
    BOOL containsSuppressedTouch = NO;
    for (UITouch *touch in touches) {
        if (touch.phase == UITouchPhaseBegan) {
            began = YES;
        }
        if ([FLMDockInputSuppressedTouches containsObject:touch]) {
            containsSuppressedTouch = YES;
        }
    }
    if (containsBeganTouch) {
        *containsBeganTouch = began;
    }

    BOOL suppress = routeBlocked || containsSuppressedTouch;
    if (!suppress) {
        // A new Began with none of the retained touch identities proves any
        // missing terminal callback belonged to an obsolete stream. Do not
        // let a stale retained UITouch consume the first centered-mode tap.
        if (began && FLMDockInputSuppressedTouches.count > 0) {
            [FLMDockInputSuppressedTouches removeAllObjects];
        }
        return NO;
    }

    // Latch every touch identity in a suppressed UIEvent. If SpringBoard
    // clears the route while that physical stream is still ending, its
    // Changed/Ended tail remains suppressed and can never reach the app
    // without the Began event that was intentionally dropped.
    for (UITouch *touch in touches) {
        if (touch.phase == UITouchPhaseEnded ||
            touch.phase == UITouchPhaseCancelled) {
            [FLMDockInputSuppressedTouches removeObject:touch];
        } else {
            [FLMDockInputSuppressedTouches addObject:touch];
        }
    }
    return YES;
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
// single app. The generic Dock event boundary is installed in each eligible
// app but acts only when its exact bundle hash matches SpringBoard's current
// block state. Keyboard geometry hooks keep their separate target route and
// are installed only after that route selects this application.
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
    if (FLMKeyboardLandscapeScene &&
        FLMKeyboardSystemReferenceSize.width > FLMKeyboardSystemReferenceSize.height + 1.0) {
        return FLMKeyboardSystemReferenceSize;
    }
    UIScreen *screen = [UIScreen mainScreen];
    CGRect nativeBounds = screen.nativeBounds;
    CGFloat scale = screen.nativeScale;
    if (scale <= 0.0) scale = screen.scale;
    if (scale <= 0.0) scale = 1.0;
    CGFloat width = CGRectGetWidth(nativeBounds) / scale;
    CGFloat height = CGRectGetHeight(nativeBounds) / scale;
    if (width > height) {
        CGFloat value = width; width = height; height = value;
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

static CGRect FLMPhysicalReferenceBounds(void) {
    CGSize size = FLMFullPhysicalScreenSize();
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
        // Never use the hosted window/card bounds here. The hosted content
        // view remains display-sized at 390x844 before the single proportional
        // card transform; keyboard avoidance therefore stays in the same
        // 390x844 application coordinate space.
        if (FLMKeyboardLandscapeScene) {
            return CGRectMake(0.0, 0.0, FLMContentLogicalViewportSize.width,
                              FLMContentLogicalViewportSize.height);
        }
        return FLMPhysicalReferenceBounds();
    }
    if (FLMKeyboardLandscapeScene) {
        return CGRectMake(0.0, 0.0, FLMContentLogicalViewportSize.width,
                          FLMContentLogicalViewportSize.height);
    }
    CGSize size = FLMFullPhysicalScreenSize();
    return CGRectMake(0.0, 0.0, size.width, size.height);
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

static void FLMHandleKeyboardDismissRequest(int deliveredToken) {
    uint64_t requestState = 0;
    if (deliveredToken < 0 ||
        notify_get_state(deliveredToken, &requestState) != NOTIFY_STATUS_OK ||
        requestState == 0 ||
        requestState == FLMKeyboardLastDismissRequestState) {
        return;
    }

    uint64_t requestedSession = (requestState >> 32) & 0xFFFFFFFFULL;
    uint64_t requestedBundleHash = requestState & 0xFFFFFFFFULL;
    uint64_t currentBundleHash =
        FLMIdentifierHash([NSBundle mainBundle].bundleIdentifier) &
        0xFFFFFFFFULL;
    uint64_t activeSession =
        FLMKeyboardSessionGeneration & 0xFFFFFFFFULL;
    uint64_t lastTargetSession =
        FLMKeyboardLastTargetSessionGeneration & 0xFFFFFFFFULL;
    BOOL sessionMatches =
        requestedSession != 0 &&
        (activeSession == requestedSession ||
         (activeSession == 0 &&
          (lastTargetSession == 0 ||
           lastTargetSession == requestedSession)));
    if (!FLMIsEligibleApplicationProcess() || currentBundleHash == 0 ||
        currentBundleHash != requestedBundleHash || !sessionMatches) {
        return;
    }

    FLMKeyboardLastDismissRequestState = requestState;
    FLMPublishDiagnosticEvent(
        FLMDiagnosticRoleApplication,
        FLMDiagnosticEventDismissRequest,
        requestedSession,
        (uint16_t)(requestedBundleHash & 0xFFFFULL),
        0);
    FLMEndPreviousApplicationKeyboardSession(requestedSession);
    FLMPublishDiagnosticEvent(FLMDiagnosticRoleApplication,
                              FLMDiagnosticEventDismissAck,
                              requestedSession,
                              1,
                              0);

    // Some retained Scenes restore their saved responder during the route
    // teardown transaction. Repeat once inside the existing 0.24 s close
    // animation, but never touch a newer session if the card has already been
    // reopened.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.16 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        uint64_t lastSession =
            FLMKeyboardLastTargetSessionGeneration & 0xFFFFFFFFULL;
        if (FLMKeyboardLastDismissRequestState != requestState ||
            (lastSession != 0 && lastSession != requestedSession)) {
            return;
        }
        uint64_t repeatedActiveSession =
            FLMKeyboardSessionGeneration & 0xFFFFFFFFULL;
        if (repeatedActiveSession != 0 &&
            repeatedActiveSession != requestedSession) {
            return;
        }
        FLMEndPreviousApplicationKeyboardSession(requestedSession);
        FLMPublishDiagnosticEvent(FLMDiagnosticRoleApplication,
                                  FLMDiagnosticEventDismissAck,
                                  requestedSession,
                                  2,
                                  0);
    });
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
    uint16_t applicationIdentityFlags = FLMApplicationProcessIdentityFlags();
    FLMKeyboardExtensionProcess = FLMProcessIsKeyboardExtension();
    FLMKeyboardTargetApplication =
        sessionGeneration != 0 && targetHash != 0 &&
        currentHash != 0 && targetHash == currentHash &&
        FLMIsEligibleApplicationProcess();
    FLMKeyboardRouteActive =
        FLMKeyboardTargetApplication ||
        (FLMKeyboardExtensionProcess && sessionGeneration != 0 && targetHash != 0);
    FLMKeyboardSessionGeneration = sessionGeneration;
    FLMKeyboardTargetSceneHash = sceneHash;
    if (FLMKeyboardTargetApplication && sessionGeneration != 0) {
        FLMKeyboardLastTargetSessionGeneration = sessionGeneration;
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
            ((applicationIdentityFlags & 1U) != 0 ? 32U : 0U) |
            ((applicationIdentityFlags & 2U) != 0 ? 64U : 0U) |
            ((applicationIdentityFlags & 4U) != 0 ? 128U : 0U) |
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
    FLMUpdateContentViewportAdapter();
}

static void FLMReloadKeyboardCardGeometry(void) {
    uint64_t state = 0;
    NSDictionary *sharedState = FLMReadKeyboardSharedState();
    FLMReloadContentViewportSelection(sharedState);
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
        FLMUpdateContentViewportAdapter();
        return;
    }
    if (FLMKeyboardCardGeometryToken < 0 ||
        notify_get_state(FLMKeyboardCardGeometryToken, &state) !=
            NOTIFY_STATUS_OK) {
        return;
    }
    // The legacy notify payload contains only card bottom/scale.  The
    // Version C dimensions live in the shared plist, so the helper above has
    // already selected the safe 390x844 fallback when that plist is absent.
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
    FLMUpdateContentViewportAdapter();
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
    CGFloat physicalOverlap = MAX(0.0, physicalSize.height - keyboardTop);
    if (physicalOverlap <= 1.0) {
        return 0.0;
    }
    CGFloat logicalHeight = physicalOverlap;
    return MIN(CGRectGetHeight(logicalBounds) * 0.72, logicalHeight);
}

static BOOL FLMIsApplicationContentWindow(UIWindow *window) {
    if (!window || window.hidden || window.alpha <= 0.01 ||
        !window.rootViewController || !window.windowScene ||
        !FLMSceneMatchesKeyboardRoute(window.windowScene)) {
        return NO;
    }
    if (window.windowLevel != UIWindowLevelNormal) {
        return NO;
    }
    NSString *className = NSStringFromClass(window.class);
    if ([className rangeOfString:@"TextEffects"].location != NSNotFound ||
        [className rangeOfString:@"Keyboard" options:NSCaseInsensitiveSearch].location !=
            NSNotFound ||
        [className rangeOfString:@"Remote" options:NSCaseInsensitiveSearch].location !=
            NSNotFound) {
        return NO;
    }
    return YES;
}

static void FLMLogContentViewportLayout(NSString *stage,
                                        UIWindow *window,
                                        UIView *contentView,
                                        CGRect sceneLogicalBounds,
                                        CGRect contentViewportBounds,
                                        CGRect previousBounds,
                                        CGRect currentBounds) {
    (void)contentView;
    CGRect windowBounds = window ? window.bounds : CGRectZero;
    NSLog(@"[FlymeKeyboard] content-viewport %@ bundle=%@ session=%llu sceneLogicalBounds=%@ contentViewportBounds=%@ externalScale=%.6f physicalCard={%.1f,%.1f} viewportSource=%@ windowBounds=%@ contentBefore=%@ contentAfter=%@ route=%d cardGeometry=%d",
          stage ?: @"unknown", [NSBundle mainBundle].bundleIdentifier ?: @"<none>",
          (unsigned long long)FLMKeyboardSessionGeneration,
          NSStringFromCGRect(sceneLogicalBounds),
          NSStringFromCGRect(contentViewportBounds),
          FLMContentExternalScale, FLMPhysicalCardSize.width,
          FLMPhysicalCardSize.height,
          FLMContentViewportUsesSharedCardSize ? @"shared-card" : @"fullscreen-fallback",
          NSStringFromCGRect(windowBounds),
          NSStringFromCGRect(previousBounds), NSStringFromCGRect(currentBounds),
          FLMKeyboardRouteActive, FLMKeyboardCardGeometryActive);
}

static void FLMRestoreContentViewportLayouts(void) {
    if (!FLMContentViewportOriginalLayouts ||
        FLMContentViewportOriginalLayouts.count == 0) {
        FLMContentViewportAdapterActive = NO;
        FLMContentViewportAdapterGeneration = 0;
        return;
    }
    if (FLMContentViewportAdapterApplying) {
        return;
    }
    FLMContentViewportAdapterApplying = YES;
    @try {
        for (UIView *contentView in FLMContentViewportOriginalLayouts.keyEnumerator) {
            NSDictionary *layout =
                [FLMContentViewportOriginalLayouts objectForKey:contentView];
            NSValue *savedFrame = layout[@"frame"];
            NSValue *savedBounds = layout[@"bounds"];
            NSValue *savedCenter = layout[@"center"];
            NSValue *savedTransform = layout[@"transform"];
            if (!contentView || !savedFrame || !savedBounds) {
                continue;
            }
            CGRect previousBounds = contentView.bounds;
            contentView.transform = CGAffineTransformIdentity;
            contentView.bounds = savedBounds.CGRectValue;
            if (savedCenter) {
                contentView.center = savedCenter.CGPointValue;
            } else {
                contentView.frame = savedFrame.CGRectValue;
            }
            if (savedTransform) {
                contentView.transform = savedTransform.CGAffineTransformValue;
            }
            [contentView setNeedsLayout];
            UIWindow *window = contentView.window;
            FLMLogContentViewportLayout(
                @"layout-restored", window, contentView,
                window ? FLMPhysicalReferenceBounds()
                       : CGRectZero,
                CGRectMake(0.0, 0.0, FLMContentLogicalViewportSize.width,
                           FLMContentLogicalViewportSize.height),
                previousBounds, contentView.bounds);
        }
    } @finally {
        [FLMContentViewportOriginalLayouts removeAllObjects];
        FLMContentViewportAdapterApplying = NO;
        FLMContentViewportAdapterActive = NO;
        FLMContentViewportAdapterGeneration = 0;
    }
}

static void FLMApplyContentViewportToRootView(UIView *contentView,
                                              UIWindow *window) {
    if (!contentView || !window || !FLMContentViewportAdapterActive ||
        FLMContentViewportAdapterApplying ||
        !FLMIsApplicationContentWindow(window)) {
        return;
    }
    if (!FLMContentViewportOriginalLayouts) {
        FLMContentViewportOriginalLayouts =
            [NSMapTable weakToStrongObjectsMapTable];
    }
    if (![FLMContentViewportOriginalLayouts objectForKey:contentView]) {
        [FLMContentViewportOriginalLayouts setObject:@{
            @"frame": [NSValue valueWithCGRect:contentView.frame],
            @"bounds": [NSValue valueWithCGRect:contentView.bounds],
            @"center": [NSValue valueWithCGPoint:contentView.center],
            @"transform": [NSValue valueWithCGAffineTransform:contentView.transform],
        }
                                       forKey:contentView];
    }
    CGRect previousBounds = contentView.bounds;
    CGRect targetBounds = CGRectMake(0.0, 0.0,
                                     FLMContentLogicalViewportSize.width,
                                     FLMContentLogicalViewportSize.height);
    CGSize systemSize = FLMFullPhysicalScreenSize();
    CGFloat portraitStripScale = FLMKeyboardLandscapeScene ? FLMContentExternalScale : 1.0;
    CGPoint targetCenter = FLMKeyboardLandscapeScene
        ? CGPointMake(FLMContentLogicalViewportSize.width * portraitStripScale * 0.5,
                      systemSize.height * 0.5)
        : CGPointMake(targetBounds.size.width * 0.5, targetBounds.size.height * 0.5);
    CGAffineTransform targetTransform = FLMKeyboardLandscapeScene
        ? CGAffineTransformMakeScale(portraitStripScale, portraitStripScale)
        : CGAffineTransformIdentity;
    CGAffineTransform currentTransform = contentView.transform;
    BOOL alreadyApplied =
        fabs(CGRectGetWidth(previousBounds) - targetBounds.size.width) < 0.25 &&
        fabs(CGRectGetHeight(previousBounds) - targetBounds.size.height) < 0.25 &&
        fabs(contentView.center.x - targetCenter.x) < 0.25 &&
        fabs(contentView.center.y - targetCenter.y) < 0.25 &&
        fabs(currentTransform.a - targetTransform.a) < 0.0005 &&
        fabs(currentTransform.d - targetTransform.d) < 0.0005;
    if (alreadyApplied) return;
    FLMContentViewportAdapterApplying = YES;
    @try {
        contentView.transform = CGAffineTransformIdentity;
        contentView.bounds = targetBounds;
        contentView.center = targetCenter;
        contentView.transform = targetTransform;
        [contentView setNeedsLayout];
        [contentView setNeedsUpdateConstraints];
        [contentView layoutIfNeeded];
        CGRect sceneLogicalBounds = FLMPhysicalReferenceBounds();
        FLMLogContentViewportLayout(@"layout-applied", window, contentView,
                                    sceneLogicalBounds, targetBounds,
                                    previousBounds, contentView.bounds);
        if (FLMKeyboardLandscapeScene) {
            NSLog(@"[FlymeKeyboard] landscape-content-strip session=%llu orientation=%ld system={%.1f,%.1f} logical={%.1f,%.1f} stripScale=%.6f stripWidth=%.2f",
                  (unsigned long long)FLMKeyboardSessionGeneration,
                  (long)FLMKeyboardInterfaceOrientation, systemSize.width, systemSize.height,
                  targetBounds.size.width, targetBounds.size.height, portraitStripScale,
                  targetBounds.size.width * portraitStripScale);
        }
        FLMPublishDiagnosticEvent(
            FLMDiagnosticRoleApplication, FLMDiagnosticEventLayoutRefresh,
            FLMKeyboardSessionGeneration,
            FLMDiagnosticUnsignedValue(targetBounds.size.width),
            FLMDiagnosticUnsignedValue(targetBounds.size.height));
    } @finally {
        FLMContentViewportAdapterApplying = NO;
    }
}

static void FLMApplyContentViewportToVisibleApplicationWindows(void) {
    if (!FLMContentViewportAdapterActive ||
        !FLMIsEligibleApplicationProcess()) {
        return;
    }
    for (UIScene *connectedScene in
         [UIApplication sharedApplication].connectedScenes) {
        if (![connectedScene isKindOfClass:[UIWindowScene class]] ||
            !FLMSceneMatchesKeyboardRoute((UIWindowScene *)connectedScene)) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)connectedScene).windows) {
            if (!FLMIsApplicationContentWindow(window)) {
                continue;
            }
            FLMApplyContentViewportToRootView(window.rootViewController.view,
                                              window);
        }
    }
}

static void FLMUpdateContentViewportAdapter(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FLMUpdateContentViewportAdapter();
        });
        return;
    }
    if (FLMContentViewportAdapterApplying) {
        return;
    }
    // 0.8.60 keeps the target application and keyboard in their native
    // full-screen 390x844 coordinate system.  The card is clipped and
    // scaled only by SpringBoard's presentation host; this adapter must not
    // rewrite an application's root view during Scene handoff.  The old
    // Version C branch could repeatedly fight UIKit's own layout pass and
    // was also capable of resurrecting a stale root after a rapid reopen.
    BOOL shouldApply = FLMKeyboardTargetApplication &&
                       FLMKeyboardRouteActive &&
                       FLMKeyboardLandscapeScene &&
                       FLMKeyboardSessionGeneration != 0;
    if (!shouldApply) {
        if (FLMContentViewportAdapterActive ||
            FLMContentViewportOriginalLayouts.count > 0) {
            NSLog(@"[FlymeKeyboard] content-viewport layout-restore-request bundle=%@ session=%llu route=%d cardGeometry=%d",
                  [NSBundle mainBundle].bundleIdentifier ?: @"<none>",
                  (unsigned long long)FLMKeyboardSessionGeneration,
                  FLMKeyboardRouteActive, FLMKeyboardCardGeometryActive);
            FLMRestoreContentViewportLayouts();
        }
        return;
    }
    if (FLMContentViewportAdapterActive &&
        FLMContentViewportAdapterGeneration != FLMKeyboardSessionGeneration) {
        FLMRestoreContentViewportLayouts();
    }
    if (!FLMContentViewportAdapterActive) {
        FLMContentViewportAdapterActive = YES;
        FLMContentViewportAdapterGeneration = FLMKeyboardSessionGeneration;
        NSLog(@"[FlymeKeyboard] content-viewport layout-route-active bundle=%@ session=%llu sceneLogicalBounds={390.0000,844.0000} contentViewportBounds={%.13f,%.13f} externalScale=%.6f physicalCard={%.1f,%.1f} viewportSource=%@",
              [NSBundle mainBundle].bundleIdentifier ?: @"<none>",
              (unsigned long long)FLMKeyboardSessionGeneration,
              FLMContentLogicalViewportSize.width,
              FLMContentLogicalViewportSize.height, FLMContentExternalScale,
              FLMPhysicalCardSize.width, FLMPhysicalCardSize.height,
              FLMContentViewportUsesSharedCardSize ? @"shared-card"
                                                    : @"fullscreen-fallback");
    }
    FLMApplyContentViewportToVisibleApplicationWindows();
}

%group FLMDockInputBarrier

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    if (event && event.type == UIEventTypeTouches) {
        BOOL routeBlocked = FLMDockInputBlockedForCurrentApplication();
        if (!routeBlocked && FLMDockInputSuppressedTouches.count == 0) {
            // Centered/fullscreen is the hot path. One shared-state read is
            // sufficient; avoid allocating or walking UITouch objects when no
            // suppressed stream needs a terminal tail.
            %orig;
            return;
        }
        BOOL containsBeganTouch = NO;
        BOOL suppress = FLMShouldSuppressDockTouchEvent(
            event, routeBlocked, &containsBeganTouch);
        if (!suppress) {
            %orig;
            return;
        }
        NSSet<UITouch *> *touches = event.allTouches;
        if (containsBeganTouch) {
            FLMPublishDiagnosticEvent(
                FLMDiagnosticRoleApplication,
                FLMDiagnosticEventInputSuppressed,
                0,
                (uint16_t)(FLMCurrentApplicationIdentifierHash() & 0xFFFFULL),
                (uint16_t)MIN((NSUInteger)UINT16_MAX, touches.count));
        }
        // SpringBoard's display-level recognizer still receives this stream
        // and performs Dock tap/drag/hide control. Returning here removes the
        // duplicate delivery only from the hosted application's Scene.
        return;
    }
    %orig;
}

%end

%end

static void FLMScheduleDockInputBarrierRetry(void) {
    if (FLMDockInputBarrierInstalled ||
        FLMDockInputBarrierRetryScheduled ||
        FLMDockInputBarrierRetryCount >= FLMKeyboardIdentityRetryLimit ||
        FLMProcessIsSpringBoardOrSystemAgent() ||
        FLMProcessIsKeyboardExtension()) {
        return;
    }
    NSDictionary *extension =
        [NSBundle mainBundle].infoDictionary[@"NSExtension"];
    if ([extension isKindOfClass:[NSDictionary class]]) {
        return;
    }
    FLMDockInputBarrierRetryScheduled = YES;
    NSUInteger attempt = ++FLMDockInputBarrierRetryCount;
    NSTimeInterval delay = MIN(1.0, 0.05 * pow(2.0, (double)attempt));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       FLMDockInputBarrierRetryScheduled = NO;
                       FLMInstallDockInputBarrierIfEligible();
                   });
}

static void FLMInstallDockInputBarrierIfEligible(void) {
    if (FLMDockInputBarrierInstalled) {
        return;
    }
    if (!FLMIsEligibleApplicationProcess() ||
        FLMCurrentApplicationIdentifierHash() == 0) {
        FLMScheduleDockInputBarrierRetry();
        return;
    }
    %init(FLMDockInputBarrier);
    FLMDockInputBarrierInstalled = YES;
}

%group FLMContentViewportAdapter

%hook UIWindow

- (void)layoutSubviews {
    %orig;
    FLMUpdateContentViewportAdapter();
}

%end

%hook UIViewController

- (void)viewDidLayoutSubviews {
    %orig;
    if (!FLMContentViewportAdapterActive || FLMContentViewportAdapterApplying ||
        ![self.view isKindOfClass:[UIView class]]) {
        return;
    }
    UIWindow *window = self.view.window;
    if (window.rootViewController == self &&
        FLMIsApplicationContentWindow(window)) {
        FLMApplyContentViewportToRootView(self.view, window);
    }
}

%end

%end

%group FLMRemoteKeyboardGeometry

%hook UITextEffectsWindow

- (CGSize)keyboardScreenReferenceSize {
    FLMReloadKeyboardRoute();
    UIWindowScene *scene = ((UIWindow *)self).windowScene;
    if (!FLMSceneMatchesKeyboardRoute(scene)) {
        return %orig;
    }
    CGSize size = FLMPhysicalReferenceBounds().size;
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
        !FLMSceneMatchesKeyboardRoute(windowScene)) {
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
                                 FLMHandleKeyboardRouteNotification();
                             });
}

static void FLMRegisterKeyboardDismissObserverIfNeeded(void) {
    if (FLMKeyboardDismissRequestToken >= 0 ||
        !FLMIsEligibleApplicationProcess()) {
        return;
    }
    int status = notify_register_dispatch(
        FLYME_KEYBOARD_DISMISS_REQUEST_NOTIFICATION,
        &FLMKeyboardDismissRequestToken,
        dispatch_get_main_queue(),
        ^(int token) {
            FLMHandleKeyboardDismissRequest(token);
        });
    if (status != NOTIFY_STATUS_OK) {
        FLMKeyboardDismissRequestToken = -1;
    }
}

static void FLMHandleKeyboardRouteNotification(void) {
    // Registration is independently retryable; a transient failure must not
    // become permanent merely because the route hooks already initialized.
    FLMRegisterKeyboardDismissObserverIfNeeded();
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
    // Keep the legacy adapter group initialized so Logos does not leave an
    // uninitialized hook group behind.  Its update routine is deliberately
    // hard-disabled (shouldApply=NO), so it never rewrites the application's
    // full-screen root layout.  The remote keyboard hook below remains gated
    // by the exact Scene route.
    %init(FLMContentViewportAdapter);
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
    FLMRegisterKeyboardDismissObserverIfNeeded();
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
        // Install the event boundary in every ordinary UIKit application. It
        // remains a no-op unless SpringBoard's synchronous state names this
        // exact bundle; keyboard behavior keeps its independent route gate.
        FLMInstallDockInputBarrierIfEligible();
        FLMPublishKeyboardRawLoadDiagnostic();
        FLMAttemptKeyboardInitialization();
    }
}
