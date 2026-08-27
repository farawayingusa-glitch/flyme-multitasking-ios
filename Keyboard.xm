#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <notify.h>
#import <sys/stat.h>
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
#define FLYME_KEYBOARD_APP_CTOR_NOTIFICATION "com.codex.flymemultitasking.keyboard-app-ctor-v50"
#define FLYME_KEYBOARD_APP_READY_NOTIFICATION "com.codex.flymemultitasking.keyboard-app-ready-v50"
#define FLYME_KEYBOARD_DISMISS_REQUEST_NOTIFICATION "com.codex.flymemultitasking.keyboard-dismiss-request-v1"
#define FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION "com.codex.flymemultitasking.keyboard-dismiss-ack-v1"
#define FLYME_KEYBOARD_SHARED_STATE_VERSION 3
#define FLYME_KEYBOARD_APP_CTOR_MAGIC 0xF150ULL
#define FLYME_KEYBOARD_APP_READY_MAGIC 0xF250ULL
#define FLYME_KEYBOARD_APP_ADAPTER_BUILD 50ULL

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
static int FLMKeyboardDismissAckToken = -1;
static BOOL FLMKeyboardDismissRetryScheduled = NO;
static uint64_t FLMKeyboardDismissRetryState = 0;
static uint64_t FLMKeyboardLastHandledDismissState = 0;
static BOOL FLMKeyboardLastHandledDismissTerminal = NO;
static BOOL FLMKeyboardHooksInstalled = NO;
static BOOL FLMKeyboardRouteObserversInstalled = NO;
static BOOL FLMContentViewportAdapterApplying = NO;
static BOOL FLMContentViewportAdapterActive = NO;
static uint64_t FLMContentViewportAdapterGeneration = 0;
static NSMapTable<UIView *, NSDictionary *> *FLMContentViewportOriginalLayouts;
static BOOL FLMKeyboardIdentityRetryScheduled = NO;
static BOOL FLMKeyboardRawLoadDiagnosticPublished = NO;
static uint16_t FLMKeyboardLastIdentityFlags = UINT16_MAX;
static NSUInteger FLMKeyboardIdentityRetryCount = 0;
static const NSUInteger FLMKeyboardIdentityRetryLimit = 8;
static int FLMInputGeometryStateToken = -1;
static int FLMInputKeyboardStateToken = -1;
static int FLMInputSpacingStateToken = -1;
static int FLMInputInsetsStateToken = -1;
static int FLMInputCommitToken = -1;
static BOOL FLMInputDiagnosticTokensReady = NO;
static BOOL FLMInputGeometryObserversInstalled = NO;
static BOOL FLMInputGeometryRetryScheduled = NO;
static id FLMInputGeometryFrameObserver = nil;
static id FLMInputGeometryShowObserver = nil;
static uint16_t FLMInputGeometrySequence = 0;
static uint64_t FLMInputGeometryLastSession = 0;
static uint64_t FLMInputGeometryLastFields[4] = {0, 0, 0, 0};
static BOOL FLMInputGeometryLastSampleValid = NO;

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

static void FLMInstallRemoteKeyboardGeometryIfAvailable(void);
static void FLMReloadKeyboardAvoidance(void);
static void FLMReloadKeyboardCardGeometry(void);
static void FLMReloadKeyboardRoute(void);
static void FLMReloadContentViewportSelection(NSDictionary *sharedState);
static void FLMAttemptKeyboardInitialization(void);
static void FLMRegisterKeyboardNotificationsAndInitialize(void);
static void FLMHandleKeyboardRouteNotification(void);
static void FLMUpdateContentViewportAdapter(void);
static void FLMInstallInputGeometryDiagnosticsIfNeeded(void);
static void FLMCaptureInputGeometryForNotification(NSNotification *notification,
                                                    BOOL allowRetry);
static uint64_t FLMIdentifierHash(NSString *identifier);
static void FLMHandleKeyboardDismissRequest(void);

typedef NS_ENUM(uint8_t, FLMKeyboardDismissResult) {
    FLMKeyboardDismissResultSuccess = 1,
    FLMKeyboardDismissResultNoResponder = 2,
    FLMKeyboardDismissResultFailed = 3,
    FLMKeyboardDismissResultStaleSession = 4,
    FLMKeyboardDismissResultWrongTarget = 5,
};

static uint64_t FLMPackKeyboardDismissAckState(
    uint64_t sessionGeneration,
    uint64_t requestGeneration,
    pid_t pid,
    FLMKeyboardDismissResult result) {
    return ((uint64_t)result << 56) |
           ((sessionGeneration & 0xFFFFFFULL) << 32) |
           ((requestGeneration & 0xFFFFULL) << 16) |
           ((uint64_t)pid & 0xFFFFULL);
}

static uint64_t FLMPackKeyboardDismissRequestState(
    uint64_t sessionGeneration,
    uint64_t requestGeneration) {
    return ((sessionGeneration & 0xFFFFFFFFULL) << 32) |
           (requestGeneration & 0xFFFFFFFFULL);
}

static void FLMUnpackKeyboardDismissRequestState(
    uint64_t state,
    uint64_t *sessionGeneration,
    uint64_t *requestGeneration) {
    if (sessionGeneration) {
        *sessionGeneration = (state >> 32) & 0xFFFFFFFFULL;
    }
    if (requestGeneration) {
        *requestGeneration = state & 0xFFFFFFFFULL;
    }
}

static NSString *FLMKeyboardDismissResultName(FLMKeyboardDismissResult result) {
    switch (result) {
        case FLMKeyboardDismissResultSuccess:
            return @"success";
        case FLMKeyboardDismissResultNoResponder:
            return @"no-responder";
        case FLMKeyboardDismissResultFailed:
            return @"failed";
        case FLMKeyboardDismissResultStaleSession:
            return @"stale-session";
        case FLMKeyboardDismissResultWrongTarget:
            return @"wrong-target";
        default:
            return @"unknown";
    }
}

static void FLMPublishKeyboardAppLifecycleStage(const char *notificationName,
                                                int *token,
                                                uint64_t magic,
                                                FLMDiagnosticEvent event) {
    if (*token < 0 &&
        notify_register_check(notificationName, token) != NOTIFY_STATUS_OK) {
        *token = -1;
        return;
    }
    NSString *bundleIdentifier = [NSBundle mainBundle].bundleIdentifier;
    NSString *processName = [NSProcessInfo processInfo].processName;
    uint16_t bundleHash =
        (uint16_t)(FLMIdentifierHash(bundleIdentifier) & 0xFFFFULL);
    uint16_t processPID = (uint16_t)(getpid() & 0xFFFF);
    uint64_t state = (magic << 48) |
                     (FLYME_KEYBOARD_APP_ADAPTER_BUILD << 32) |
                     ((uint64_t)processPID << 16) |
                     bundleHash;
    notify_set_state(*token, state);
    notify_post(notificationName);
    if (event == FLMDiagnosticEventAdapterCtor) {
        NSLog(@"[FlymeKeyboard] adapter-ctor pid=%d bundle=%@ process=%@ bundleHash=0x%04x",
              getpid(), bundleIdentifier ?: @"<none>",
              processName ?: @"<none>", bundleHash);
    } else {
        NSLog(@"[FlymeKeyboard] adapter-ready pid=%d bundle=%@ process=%@ bundleHash=0x%04x",
              getpid(), bundleIdentifier ?: @"<none>",
              processName ?: @"<none>", bundleHash);
    }
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

static void FLMPublishKeyboardDismissAckToSharedState(
    uint64_t sessionGeneration,
    uint64_t requestGeneration,
    pid_t pid,
    FLMKeyboardDismissResult result) {
    if (sessionGeneration == 0 || requestGeneration == 0 || pid <= 1) {
        return;
    }
    NSString *path = nil;
    NSDictionary *existing =
        [NSDictionary dictionaryWithContentsOfFile:FLMKeyboardSharedStatePath];
    if ([existing isKindOfClass:[NSDictionary class]]) {
        path = FLMKeyboardSharedStatePath;
    } else {
        existing = [NSDictionary dictionaryWithContentsOfFile:
                                             FLMKeyboardSharedStateRootlessPath];
        if ([existing isKindOfClass:[NSDictionary class]]) {
            path = FLMKeyboardSharedStateRootlessPath;
        }
    }
    if (!path || ![existing isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSMutableDictionary *state = [existing mutableCopy];
    state[@"version"] = @3;
    state[@"dismissAckGeneration"] = @(requestGeneration);
    state[@"dismissAckSession"] = @(sessionGeneration);
    state[@"dismissAckPID"] = @(pid);
    state[@"dismissAckResult"] = @(result);
    state[@"updatedAt"] = @([[NSDate date] timeIntervalSince1970]);
    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization
        dataWithPropertyList:state
                      format:NSPropertyListBinaryFormat_v1_0
                     options:0
                       error:&serializationError];
    NSError *writeError = nil;
    BOOL wrote = data && !serializationError &&
                 [data writeToFile:path
                           options:NSDataWritingAtomic
                             error:&writeError];
    if (wrote) {
        chmod(path.fileSystemRepresentation, 0644);
        notify_post(FLYME_KEYBOARD_SHARED_STATE_NOTIFICATION);
    }
    NSLog(@"[FlymeKeyboard] dismiss-ack shared-state write=%d path=%@ sessionGeneration=%llu requestGeneration=%llu pid=%d result=%@ error=%@",
          wrote, path ?: @"<none>",
          (unsigned long long)sessionGeneration,
          (unsigned long long)requestGeneration,
          pid,
          FLMKeyboardDismissResultName(result),
          writeError.localizedDescription ?: serializationError.localizedDescription ?: @"<none>");
}

static void FLMReloadContentViewportSelection(NSDictionary *sharedState) {
    // Keep the app-side layout full-screen. The 0.8.59 presentation model
    // crops the already-scaled host in SpringBoard; it does not ask the target
    // application to lay out inside the physical card.
    (void)sharedState;
    const CGSize fallback = {390.0, 844.0};
    FLMContentLogicalViewportSize = fallback;
    FLMContentExternalScale = 1.0;
    FLMPhysicalCardSize = fallback;
    FLMContentViewportUsesSharedCardSize = NO;
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

static BOOL FLMIsExplicitWeChatAdapterProcess(void) {
    return FLMIsEligibleApplicationProcess() &&
           [[NSBundle mainBundle].bundleIdentifier
               isEqualToString:@"com.tencent.xin"];
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
        return FLMPhysicalReferenceBounds();
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

static uint16_t FLMInputDiagnosticUnsignedTenths(CGFloat value) {
    if (!isfinite(value) || value <= 0.0) {
        return 0;
    }
    return (uint16_t)MIN(65535.0, llround(value * 10.0));
}

static uint16_t FLMInputDiagnosticSignedTenths(CGFloat value) {
    if (!isfinite(value)) {
        return 0;
    }
    long long tenths = llround(value * 10.0);
    tenths = MAX((long long)INT16_MIN,
                  MIN((long long)INT16_MAX, tenths));
    return (uint16_t)(int16_t)tenths;
}

static UIView *FLMFirstResponderInView(UIView *view) {
    if (!view || view.hidden || view.alpha <= 0.01) {
        return nil;
    }
    if (view.isFirstResponder) {
        return view;
    }
    for (UIView *subview in view.subviews) {
        UIView *responder = FLMFirstResponderInView(subview);
        if (responder) {
            return responder;
        }
    }
    return nil;
}

static UIView *FLMInputContainerForResponder(UIView *responder,
                                             UIWindow *window) {
    if (!responder || !window) {
        return responder;
    }
    CGRect inputRect = [responder convertRect:responder.bounds toView:window];
    CGFloat inputHeight = CGRectGetHeight(inputRect);
    CGFloat minimumWidth = CGRectGetWidth(window.bounds) * 0.55;
    UIView *best = nil;
    CGFloat bestScore = CGFLOAT_MAX;
    for (UIView *ancestor = responder.superview;
         ancestor && ancestor != window;
         ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha <= 0.01) {
            continue;
        }
        CGRect rect = [ancestor convertRect:ancestor.bounds toView:window];
        CGFloat width = CGRectGetWidth(rect);
        CGFloat height = CGRectGetHeight(rect);
        if (width < minimumWidth || height + 0.5 < inputHeight ||
            height > 180.0 ||
            !CGRectContainsPoint(CGRectInset(rect, -1.0, -1.0),
                                 CGPointMake(CGRectGetMidX(inputRect),
                                             CGRectGetMidY(inputRect)))) {
            continue;
        }
        // Prefer the shallow, wide composer ancestor.  This avoids selecting
        // the full conversation/root view while still including padding below
        // a UITextView or custom input control.
        CGFloat score = height +
                        (CGRectGetWidth(window.bounds) - width) * 0.10;
        if (score < bestScore) {
            best = ancestor;
            bestScore = score;
        }
    }
    return best ?: responder;
}

static UIScrollView *FLMNearestScrollViewForView(UIView *view) {
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:[UIScrollView class]]) {
            return (UIScrollView *)ancestor;
        }
    }
    return nil;
}

static BOOL FLMFindInputResponderWindow(UIWindow **windowOut,
                                        UIView **responderOut) {
    UIWindow *fallbackWindow = nil;
    UIView *fallbackResponder = nil;
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
            UIView *responder =
                FLMFirstResponderInView(window.rootViewController.view);
            if (!responder) {
                continue;
            }
            if (window.isKeyWindow) {
                if (windowOut) {
                    *windowOut = window;
                }
                if (responderOut) {
                    *responderOut = responder;
                }
                return YES;
            }
            fallbackWindow = window;
            fallbackResponder = responder;
        }
    }
    if (fallbackWindow && fallbackResponder) {
        if (windowOut) {
            *windowOut = fallbackWindow;
        }
        if (responderOut) {
            *responderOut = fallbackResponder;
        }
        return YES;
    }
    return NO;
}

static UIView *FLMFirstResponderInTargetScene(void) {
    for (UIScene *connectedScene in
         [UIApplication sharedApplication].connectedScenes) {
        if (![connectedScene isKindOfClass:[UIWindowScene class]] ||
            !FLMSceneMatchesKeyboardRoute((UIWindowScene *)connectedScene)) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)connectedScene).windows) {
            UIView *responder =
                FLMFirstResponderInView(window.rootViewController.view);
            if (responder) {
                return responder;
            }
        }
    }
    return nil;
}

static BOOL FLMHasTargetApplicationScene(void) {
    for (UIScene *connectedScene in
         [UIApplication sharedApplication].connectedScenes) {
        if ([connectedScene isKindOfClass:[UIWindowScene class]] &&
            FLMSceneMatchesKeyboardRoute((UIWindowScene *)connectedScene)) {
            return YES;
        }
    }
    return NO;
}

static FLMKeyboardDismissResult FLMResignTargetApplicationResponder(
    uint64_t sessionGeneration,
    uint64_t requestGeneration) {
    UIView *beforeResponder = nil;
    beforeResponder = FLMFirstResponderInTargetScene();
    BOOL hadResponder = beforeResponder != nil;
    NSUInteger endedWindows = 0;
    BOOL cleanupThrew = NO;
    @try {
        // This is the application-wide UIKit action requested by the close
        // transaction. The explicit window pass below is deliberately limited
        // to the current routed Scene, so another connected Scene is never
        // used as a keyboard-cleanup target.
        [[UIApplication sharedApplication]
            sendAction:@selector(resignFirstResponder)
                   to:nil
                 from:nil
             forEvent:nil];
        for (UIScene *connectedScene in
             [UIApplication sharedApplication].connectedScenes) {
            if (![connectedScene isKindOfClass:[UIWindowScene class]] ||
                !FLMSceneMatchesKeyboardRoute((UIWindowScene *)connectedScene)) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)connectedScene).windows) {
                if ([window endEditing:YES]) {
                    endedWindows += 1;
                }
            }
        }
    } @catch (__unused NSException *exception) {
        cleanupThrew = YES;
    }

    UIView *afterResponder = nil;
    afterResponder = FLMFirstResponderInTargetScene();
    BOOL responderRemains = afterResponder != nil;
    FLMKeyboardDismissResult result = responderRemains
                                          ? FLMKeyboardDismissResultFailed
                                      : cleanupThrew
                                          ? FLMKeyboardDismissResultFailed
                                      : hadResponder
                                          ? FLMKeyboardDismissResultSuccess
                                          : FLMKeyboardDismissResultNoResponder;
    FLMPublishDiagnosticEvent(
        FLMDiagnosticRoleApplication,
        FLMDiagnosticEventResponderResign,
        sessionGeneration,
        FLMDiagnosticUnsignedValue(endedWindows),
        (uint16_t)(requestGeneration & 0xFFFFULL));
    NSLog(@"[FlymeKeyboard] dismiss-resign session=%llu sessionGeneration=%llu requestGeneration=%llu before=%@ after=%@ endedWindows=%lu result=%@",
          (unsigned long long)sessionGeneration,
          (unsigned long long)sessionGeneration,
          (unsigned long long)requestGeneration,
          beforeResponder ? NSStringFromClass([beforeResponder class]) : @"<none>",
          afterResponder ? NSStringFromClass([afterResponder class]) : @"<none>",
          (unsigned long)endedWindows,
          FLMKeyboardDismissResultName(result));
    return result;
}

static void FLMSendKeyboardDismissAck(uint64_t sessionGeneration,
                                      uint64_t requestGeneration,
                                      FLMKeyboardDismissResult result) {
    if (sessionGeneration == 0 || requestGeneration == 0) {
        return;
    }
    // The plist/notify shared-state route is authoritative. Publish it even
    // when the optional Darwin compatibility token cannot be registered.
    FLMPublishKeyboardDismissAckToSharedState(
        sessionGeneration, requestGeneration, getpid(), result);
    uint64_t ackState = FLMPackKeyboardDismissAckState(
        sessionGeneration, requestGeneration, getpid(), result);
    if (FLMKeyboardDismissAckToken < 0 &&
        notify_register_check(FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION,
                              &FLMKeyboardDismissAckToken) !=
            NOTIFY_STATUS_OK) {
        NSLog(@"[FlymeKeyboard] dismiss-ack publish-failed session=%llu sessionGeneration=%llu requestGeneration=%llu result=%@",
              (unsigned long long)sessionGeneration,
              (unsigned long long)sessionGeneration,
              (unsigned long long)requestGeneration,
              FLMKeyboardDismissResultName(result));
        return;
    }
    notify_set_state(FLMKeyboardDismissAckToken, ackState);
    FLMPublishDiagnosticEvent(FLMDiagnosticRoleApplication,
                              FLMDiagnosticEventDismissAck,
                              sessionGeneration,
                              (uint16_t)(requestGeneration & 0xFFFFULL),
                              (uint16_t)result);
    notify_post(FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION);
    NSLog(@"[FlymeKeyboard] dismiss-ack session=%llu sessionGeneration=%llu requestGeneration=%llu pid=%d result=%@ state=0x%016llx",
          (unsigned long long)sessionGeneration,
          (unsigned long long)sessionGeneration,
          (unsigned long long)requestGeneration,
          getpid(), FLMKeyboardDismissResultName(result),
          (unsigned long long)ackState);
}

static void FLMHandleKeyboardDismissRequest(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FLMHandleKeyboardDismissRequest();
        });
        return;
    }
    NSDictionary *sharedState = FLMReadKeyboardSharedState();
    BOOL sharedRequest =
        [sharedState[@"dismissRequestGeneration"] isKindOfClass:[NSNumber class]] &&
        [sharedState[@"dismissSession"] isKindOfClass:[NSNumber class]] &&
        [sharedState[@"dismissSessionGeneration"] isKindOfClass:[NSNumber class]] &&
        [sharedState[@"dismissRequestGeneration"] unsignedLongLongValue] != 0;
    uint64_t requestState = 0;
    uint64_t requestedSession = 0;
    uint64_t requestGeneration = 0;
    uint64_t requestedSessionGeneration = 0;
    uint64_t requestedSceneHash = 0;
    uint64_t requestedBundleHash = 0;
    if (sharedRequest) {
        requestedSession =
            [sharedState[@"dismissSession"] unsignedLongLongValue];
        requestedSessionGeneration =
            [sharedState[@"dismissSessionGeneration"] unsignedLongLongValue];
        requestGeneration =
            [sharedState[@"dismissRequestGeneration"] unsignedLongLongValue];
        requestedSceneHash =
            [sharedState[@"dismissSceneHash"] unsignedLongLongValue];
        requestedBundleHash =
            [sharedState[@"dismissBundleHash"] unsignedLongLongValue];
        requestState = FLMPackKeyboardDismissRequestState(
            requestedSession, requestGeneration);
    } else {
        if (FLMKeyboardDismissRequestToken < 0 ||
            notify_get_state(FLMKeyboardDismissRequestToken, &requestState) !=
                NOTIFY_STATUS_OK ||
            requestState == 0) {
            return;
        }
        FLMUnpackKeyboardDismissRequestState(requestState, &requestedSession,
                                             &requestGeneration);
        requestedSessionGeneration = requestedSession;
    }
    FLMReloadKeyboardRoute();

    NSString *bundleIdentifier = [NSBundle mainBundle].bundleIdentifier;
    NSString *processName = [NSProcessInfo processInfo].processName;
    if (!FLMIsEligibleApplicationProcess() || !FLMKeyboardRouteActive ||
        !FLMKeyboardTargetApplication) {
        // The dylib is intentionally loaded by the broad UIKit filter. A
        // non-target process must stay silent; otherwise two apps could ack a
        // request that was meant for the card's current Scene.
        return;
    }

    FLMPublishDiagnosticEvent(FLMDiagnosticRoleApplication,
                              FLMDiagnosticEventDismissRequest,
                              requestedSessionGeneration,
                              (uint16_t)(requestGeneration & 0xFFFFULL),
                              (uint16_t)(FLMKeyboardTargetSceneHash & 0xFFFFULL));
    NSLog(@"[FlymeKeyboard] dismiss-request received pid=%d bundle=%@ process=%@ sceneHash=0x%016llx session=%llu sessionGeneration=%llu requestGeneration=%llu state=0x%016llx sharedState=%d",
          getpid(), bundleIdentifier ?: @"<none>", processName ?: @"<none>",
          (unsigned long long)FLMKeyboardTargetSceneHash,
          (unsigned long long)requestedSession,
          (unsigned long long)requestedSessionGeneration,
          (unsigned long long)requestGeneration,
          (unsigned long long)requestState,
          sharedRequest);

    if (requestedSession == 0 || requestGeneration == 0 ||
        requestedSessionGeneration == 0 ||
        requestedSession != FLMKeyboardSessionGeneration ||
        requestedSessionGeneration != FLMKeyboardSessionGeneration) {
        NSLog(
            @"app dismiss-request rejected=stale-session bundle=%@ session=%llu currentSession=%llu sessionGeneration=%llu requestGeneration=%llu",
            bundleIdentifier ?: @"<none>",
            (unsigned long long)requestedSession,
            (unsigned long long)FLMKeyboardSessionGeneration,
            (unsigned long long)requestedSessionGeneration,
            (unsigned long long)requestGeneration);
        FLMSendKeyboardDismissAck(requestedSession, requestGeneration,
                                  FLMKeyboardDismissResultStaleSession);
        return;
    }
    uint64_t currentBundleHash = FLMIdentifierHash(bundleIdentifier);
    if (!FLMHasTargetApplicationScene() ||
        (sharedRequest &&
         (requestedSceneHash == 0 ||
          requestedSceneHash != FLMKeyboardTargetSceneHash ||
          requestedBundleHash == 0 || requestedBundleHash != currentBundleHash))) {
        NSLog(
            @"app dismiss-request rejected=wrong-target bundle=%@ sceneHash=0x%016llx requestedSceneHash=0x%016llx session=%llu sessionGeneration=%llu requestGeneration=%llu",
            bundleIdentifier ?: @"<none>",
            (unsigned long long)FLMKeyboardTargetSceneHash,
            (unsigned long long)requestedSceneHash,
            (unsigned long long)requestedSession,
            (unsigned long long)requestedSessionGeneration,
            (unsigned long long)requestGeneration);
        FLMSendKeyboardDismissAck(requestedSession, requestGeneration,
                                  FLMKeyboardDismissResultWrongTarget);
        return;
    }

    if (FLMKeyboardLastHandledDismissTerminal &&
        FLMKeyboardLastHandledDismissState == requestState) {
        return;
    }
    if (FLMKeyboardDismissRetryScheduled &&
        FLMKeyboardDismissRetryState == requestState) {
        return;
    }
    FLMKeyboardDismissResult result = FLMResignTargetApplicationResponder(
        requestedSessionGeneration, requestGeneration);
    if (result == FLMKeyboardDismissResultFailed) {
        FLMKeyboardDismissRetryScheduled = YES;
        FLMKeyboardDismissRetryState = requestState;
        NSLog(
            @"app dismiss-request retry-scheduled bundle=%@ session=%llu sessionGeneration=%llu requestGeneration=%llu delay=0.08",
            bundleIdentifier ?: @"<none>",
            (unsigned long long)requestedSession,
            (unsigned long long)requestedSessionGeneration,
            (unsigned long long)requestGeneration);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.08 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            FLMKeyboardDismissRetryScheduled = NO;
            FLMKeyboardDismissRetryState = 0;
            FLMReloadKeyboardRoute();
            if (!FLMKeyboardTargetApplication ||
                FLMKeyboardSessionGeneration != requestedSessionGeneration) {
                FLMSendKeyboardDismissAck(
                    requestedSession, requestGeneration,
                    FLMKeyboardDismissResultStaleSession);
                return;
            }
            FLMKeyboardDismissResult retryResult =
                FLMResignTargetApplicationResponder(requestedSessionGeneration,
                                                    requestGeneration);
            FLMKeyboardLastHandledDismissState = requestState;
            FLMKeyboardLastHandledDismissTerminal =
                retryResult != FLMKeyboardDismissResultFailed;
            FLMSendKeyboardDismissAck(requestedSession, requestGeneration,
                                      retryResult);
        });
        return;
    }
    FLMKeyboardLastHandledDismissState = requestState;
    FLMKeyboardLastHandledDismissTerminal = YES;
    FLMSendKeyboardDismissAck(requestedSession, requestGeneration, result);
}

static BOOL FLMRegisterInputDiagnosticTokens(void) {
    if (FLMInputDiagnosticTokensReady) {
        return YES;
    }
    BOOL ready =
        notify_register_check(FLYME_DIAGNOSTIC_INPUT_GEOMETRY_STATE,
                              &FLMInputGeometryStateToken) == NOTIFY_STATUS_OK;
    ready = ready &&
            notify_register_check(FLYME_DIAGNOSTIC_INPUT_KEYBOARD_STATE,
                                  &FLMInputKeyboardStateToken) ==
                NOTIFY_STATUS_OK;
    ready = ready &&
            notify_register_check(FLYME_DIAGNOSTIC_INPUT_SPACING_STATE,
                                  &FLMInputSpacingStateToken) ==
                NOTIFY_STATUS_OK;
    ready = ready &&
            notify_register_check(FLYME_DIAGNOSTIC_INPUT_INSETS_STATE,
                                  &FLMInputInsetsStateToken) ==
                NOTIFY_STATUS_OK;
    ready = ready &&
            notify_register_check(FLYME_DIAGNOSTIC_INPUT_COMMIT_NOTIFICATION,
                                  &FLMInputCommitToken) == NOTIFY_STATUS_OK;
    FLMInputDiagnosticTokensReady = ready;
    return ready;
}

static void FLMPublishCommittedInputGeometry(uint16_t inputHeight,
                                             uint16_t containerHeight,
                                             uint16_t containerBottom,
                                             uint16_t keyboardTop,
                                             uint16_t gap,
                                             uint16_t safeBottom,
                                             uint16_t contentBottom,
                                             uint16_t adjustedBottom) {
    if (!FLMRegisterInputDiagnosticTokens()) {
        return;
    }
    uint64_t payloads[4] = {
        ((uint64_t)inputHeight << 16) | containerHeight,
        ((uint64_t)containerBottom << 16) | keyboardTop,
        ((uint64_t)gap << 16) | safeBottom,
        ((uint64_t)contentBottom << 16) | adjustedBottom,
    };
    BOOL unchanged =
        FLMInputGeometryLastSampleValid &&
        FLMInputGeometryLastSession == FLMKeyboardSessionGeneration;
    for (NSUInteger index = 0; index < 4 && unchanged; index++) {
        unchanged = FLMInputGeometryLastFields[index] == payloads[index];
    }
    if (unchanged) {
        return;
    }

    FLMInputGeometrySequence += 1;
    if (FLMInputGeometrySequence == 0) {
        FLMInputGeometrySequence = 1;
    }
    uint16_t sequence = FLMInputGeometrySequence;
    uint64_t states[4] = {
        FLMPackDiagnosticState(FLMDiagnosticRoleApplication,
                               FLMDiagnosticEventInputGeometry,
                               sequence,
                               inputHeight,
                               containerHeight),
        FLMPackDiagnosticState(FLMDiagnosticRoleApplication,
                               FLMDiagnosticEventInputKeyboardFrame,
                               sequence,
                               containerBottom,
                               keyboardTop),
        FLMPackDiagnosticState(FLMDiagnosticRoleApplication,
                               FLMDiagnosticEventInputSpacing,
                               sequence,
                               gap,
                               safeBottom),
        FLMPackDiagnosticState(FLMDiagnosticRoleApplication,
                               FLMDiagnosticEventInputInsets,
                               sequence,
                               contentBottom,
                               adjustedBottom),
    };
    notify_set_state(FLMInputGeometryStateToken, states[0]);
    notify_set_state(FLMInputKeyboardStateToken, states[1]);
    notify_set_state(FLMInputSpacingStateToken, states[2]);
    notify_set_state(FLMInputInsetsStateToken, states[3]);
    uint16_t monotonicTick =
        (uint16_t)((uint64_t)llround(CACurrentMediaTime() * 1000.0) &
                   0xFFFFULL);
    uint64_t commit =
        FLMPackDiagnosticState(
            FLMDiagnosticRoleApplication,
            FLMDiagnosticEventInputSampleCommit,
            sequence,
            (uint16_t)(FLMKeyboardSessionGeneration & 0xFFFFULL),
            monotonicTick);
    notify_set_state(FLMInputCommitToken, commit);
    notify_post(FLYME_DIAGNOSTIC_INPUT_COMMIT_NOTIFICATION);

    FLMInputGeometryLastSession = FLMKeyboardSessionGeneration;
    for (NSUInteger index = 0; index < 4; index++) {
        FLMInputGeometryLastFields[index] = payloads[index];
    }
    FLMInputGeometryLastSampleValid = YES;
}

static void FLMCaptureInputGeometryForNotification(NSNotification *notification,
                                                    BOOL allowRetry) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FLMCaptureInputGeometryForNotification(notification, allowRetry);
        });
        return;
    }
    if (!FLMKeyboardTargetApplication || !FLMKeyboardRouteActive ||
        FLMKeyboardSessionGeneration == 0) {
        return;
    }
    UIWindow *window = nil;
    UIView *responder = nil;
    if (!FLMFindInputResponderWindow(&window, &responder)) {
        if (allowRetry && !FLMInputGeometryRetryScheduled) {
            FLMInputGeometryRetryScheduled = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                FLMInputGeometryRetryScheduled = NO;
                FLMCaptureInputGeometryForNotification(notification, NO);
            });
        }
        return;
    }
    NSValue *keyboardValue =
        [notification.userInfo[UIKeyboardFrameEndUserInfoKey]
            isKindOfClass:[NSValue class]]
            ? notification.userInfo[UIKeyboardFrameEndUserInfoKey]
            : nil;
    if (!keyboardValue) {
        return;
    }
    [window layoutIfNeeded];
    UIView *container = FLMInputContainerForResponder(responder, window);
    UIScreen *screen = window.windowScene.screen ?: [UIScreen mainScreen];
    id<UICoordinateSpace> fixedSpace = screen.fixedCoordinateSpace;
    id<UICoordinateSpace> screenSpace = screen.coordinateSpace;
    CGRect keyboardFixed =
        [fixedSpace convertRect:keyboardValue.CGRectValue
            fromCoordinateSpace:screenSpace];
    CGRect keyboardVisible =
        CGRectIntersection(fixedSpace.bounds, keyboardFixed);
    if (CGRectIsNull(keyboardVisible) || CGRectIsEmpty(keyboardVisible)) {
        return;
    }
    CGRect inputWindow =
        [responder convertRect:responder.bounds toView:window];
    CGRect containerWindow =
        [container convertRect:container.bounds toView:window];
    CGRect inputFixed =
        [fixedSpace convertRect:inputWindow fromCoordinateSpace:window];
    CGRect containerFixed =
        [fixedSpace convertRect:containerWindow fromCoordinateSpace:window];
    CGFloat keyboardVisualTop = CGRectGetMinY(keyboardVisible);
    CGFloat visualGap = keyboardVisualTop - CGRectGetMaxY(containerFixed);
    UIScrollView *scrollView = FLMNearestScrollViewForView(responder);
    CGFloat contentInsetBottom = scrollView ? scrollView.contentInset.bottom : 0.0;
    CGFloat adjustedInsetBottom =
        scrollView ? scrollView.adjustedContentInset.bottom : 0.0;

    uint16_t inputHeight =
        FLMInputDiagnosticUnsignedTenths(CGRectGetHeight(inputFixed));
    uint16_t containerHeight =
        FLMInputDiagnosticUnsignedTenths(CGRectGetHeight(containerFixed));
    uint16_t containerBottom =
        FLMInputDiagnosticUnsignedTenths(CGRectGetMaxY(containerFixed));
    uint16_t keyboardTop =
        FLMInputDiagnosticUnsignedTenths(keyboardVisualTop);
    uint16_t gap = FLMInputDiagnosticSignedTenths(visualGap);
    uint16_t safeBottom =
        FLMInputDiagnosticUnsignedTenths(window.safeAreaInsets.bottom);
    uint16_t contentBottom =
        FLMInputDiagnosticUnsignedTenths(contentInsetBottom);
    uint16_t adjustedBottom =
        FLMInputDiagnosticUnsignedTenths(adjustedInsetBottom);
    FLMPublishCommittedInputGeometry(inputHeight,
                                     containerHeight,
                                     containerBottom,
                                     keyboardTop,
                                     gap,
                                     safeBottom,
                                     contentBottom,
                                     adjustedBottom);
    NSLog(@"[FlymeKeyboard] input-sample session=%llu space=fixed-screen responder=%@ container=%@ input=%@ containerRect=%@ keyboardVisual=%@ gap=%.1f safeBottom=%.1f contentInsetBottom=%.1f adjustedInsetBottom=%.1f",
          (unsigned long long)FLMKeyboardSessionGeneration,
          NSStringFromClass(responder.class),
          NSStringFromClass(container.class),
          NSStringFromCGRect(inputFixed),
          NSStringFromCGRect(containerFixed),
          NSStringFromCGRect(keyboardVisible),
          visualGap,
          window.safeAreaInsets.bottom,
          contentInsetBottom,
          adjustedInsetBottom);
}

static void FLMInstallInputGeometryDiagnosticsIfNeeded(void) {
    if (FLMInputGeometryObserversInstalled ||
        !FLMKeyboardTargetApplication || !FLMRegisterInputDiagnosticTokens()) {
        return;
    }
    FLMInputGeometryObserversInstalled = YES;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    FLMInputGeometryFrameObserver =
        [center addObserverForName:UIKeyboardDidChangeFrameNotification
                           object:nil
                            queue:[NSOperationQueue mainQueue]
                       usingBlock:^(NSNotification *notification) {
        FLMCaptureInputGeometryForNotification(notification, YES);
    }];
    FLMInputGeometryShowObserver =
        [center addObserverForName:UIKeyboardDidShowNotification
                           object:nil
                            queue:[NSOperationQueue mainQueue]
                       usingBlock:^(NSNotification *notification) {
        FLMCaptureInputGeometryForNotification(notification, YES);
    }];
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
            if (!contentView || !savedFrame || !savedBounds) {
                continue;
            }
            CGRect previousBounds = contentView.bounds;
            contentView.frame = savedFrame.CGRectValue;
            contentView.bounds = savedBounds.CGRectValue;
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
        }
                                       forKey:contentView];
    }
    CGRect previousBounds = contentView.bounds;
    CGRect targetBounds = CGRectMake(0.0, 0.0,
                                     FLMContentLogicalViewportSize.width,
                                     FLMContentLogicalViewportSize.height);
    CGRect currentFrame = contentView.frame;
    CGRect targetFrame = CGRectMake(0.0,
                                    0.0,
                                    FLMContentLogicalViewportSize.width,
                                    FLMContentLogicalViewportSize.height);
    BOOL alreadyApplied =
        fabs(CGRectGetWidth(previousBounds) - targetBounds.size.width) < 0.25 &&
        fabs(CGRectGetHeight(previousBounds) - targetBounds.size.height) < 0.25 &&
        fabs(CGRectGetWidth(currentFrame) - targetFrame.size.width) < 0.25 &&
        fabs(CGRectGetHeight(currentFrame) - targetFrame.size.height) < 0.25;
    if (alreadyApplied) {
        return;
    }
    FLMContentViewportAdapterApplying = YES;
    @try {
        contentView.bounds = targetBounds;
        contentView.frame = targetFrame;
        [contentView setNeedsLayout];
        [contentView setNeedsUpdateConstraints];
        [contentView layoutIfNeeded];
        CGRect sceneLogicalBounds =
            FLMPhysicalReferenceBounds();
        FLMLogContentViewportLayout(@"layout-applied", window, contentView,
                                    sceneLogicalBounds, targetBounds,
                                    previousBounds, contentView.bounds);
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
    BOOL shouldApply = NO;
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
    notify_register_dispatch(FLYME_KEYBOARD_DISMISS_REQUEST_NOTIFICATION,
                             &FLMKeyboardDismissRequestToken,
                             dispatch_get_main_queue(),
                             ^(__unused int token) {
                                 FLMHandleKeyboardDismissRequest();
                             });
}

static void FLMHandleKeyboardRouteNotification(void) {
    FLMReloadKeyboardRoute();
    // Shared-state delivery is the reliable request wake-up. The Darwin
    // request notification is retained for compatibility, but this path also
    // works when its delivery races the atomic plist replacement.
    FLMHandleKeyboardDismissRequest();
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
        (!FLMKeyboardTargetApplication &&
         !FLMIsExplicitWeChatAdapterProcess())) {
        return;
    }
    FLMKeyboardHooksInstalled = YES;

    // The two independent notify states make a failed device run
    // unambiguous: no ctor token means the explicit WeChat/startup adapter did
    // not load; ctor without ready means initialization did not complete. The
    // raw-loaded diagnostic published before this function additionally
    // distinguishes a missing injection from a constructor that ran before
    // identity settled.
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
    // Geometry-only observer: it samples the active responder, composer
    // container and UIKit keyboard visual frame after layout.  It never
    // changes frames, constraints, insets or keyboard intersection returns.
    FLMInstallInputGeometryDiagnosticsIfNeeded();
    FLMReloadKeyboardRoute();
    NSLog(@"[FlymeKeyboard] adapter-initialized-at-startup bundle=%@ process=%@ target=%d route=%d session=%llu",
          [NSBundle mainBundle].bundleIdentifier ?: @"<none>",
          [NSProcessInfo processInfo].processName ?: @"<none>",
          FLMKeyboardTargetApplication, FLMKeyboardRouteActive,
          (unsigned long long)FLMKeyboardSessionGeneration);
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
    if (!FLMKeyboardTargetApplication &&
        !FLMIsExplicitWeChatAdapterProcess()) {
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
