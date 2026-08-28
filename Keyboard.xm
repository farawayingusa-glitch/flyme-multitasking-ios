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
#define FLYME_KEYBOARD_SHARED_STATE_VERSION 4
#define FLYME_KEYBOARD_APP_CTOR_MAGIC 0xF150ULL
#define FLYME_KEYBOARD_APP_READY_MAGIC 0xF250ULL
#define FLYME_KEYBOARD_APP_ADAPTER_BUILD 51ULL

static NSString *const FLMKeyboardSharedStatePath =
    @"/var/mobile/Library/Preferences/FlymeMultitasking-KeyboardState.plist";
static NSString *const FLMKeyboardSharedStateRootlessPath =
    @"/var/jb/var/mobile/Library/Preferences/FlymeMultitasking-KeyboardState.plist";

static BOOL FLMKeyboardRouteActive = NO;
static BOOL FLMKeyboardTargetApplication = NO;
static BOOL FLMKeyboardExtensionProcess = NO;
static BOOL FLMRemoteKeyboardGeometryInstalled = NO;
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
static int FLMKeyboardDismissAckToken = -1;
static uint64_t FLMKeyboardLastRouteGeneration = 0;
static uint64_t FLMKeyboardLastGeometryGeneration = 0;
static uint64_t FLMKeyboardLastAvoidanceGeneration = 0;
static uint64_t FLMKeyboardLastDismissGeneration = 0;
static uint64_t FLMKeyboardLastProcessedSession = 0;
static uint64_t FLMKeyboardLastDismissSession = 0;
static uint64_t FLMKeyboardLastRouteTargetHash = 0;
static uint64_t FLMKeyboardLastRouteSceneHash = 0;
static uint64_t FLMKeyboardLastRouteSession = 0;
static uint64_t FLMKeyboardLastHandledSharedStateGeneration = 0;
static pid_t FLMKeyboardLifecyclePID = 0;
static uint64_t FLMKeyboardLifecycleBuildGeneration = 0;
static BOOL FLMKeyboardAdapterCtorPublished = NO;
static BOOL FLMKeyboardAdapterReadyPublished = NO;
static BOOL FLMKeyboardHooksInstalled = NO;

typedef NS_ENUM(NSUInteger, FLMKeyboardTransportChannelIndex) {
    FLMKeyboardTransportChannelRoute = 0,
    FLMKeyboardTransportChannelScene,
    FLMKeyboardTransportChannelSession,
    FLMKeyboardTransportChannelAvoidance,
    FLMKeyboardTransportChannelCardGeometry,
    FLMKeyboardTransportChannelSharedState,
    FLMKeyboardTransportChannelDismiss,
    FLMKeyboardTransportChannelCount,
};

typedef struct {
    const char *label;
    const char *notificationName;
    int token;
    int status;
    BOOL registered;
    BOOL statusLogged;
} FLMKeyboardTransportChannelState;

// ProcessGlobalTransport owns only transport lifetime and registration state.
// Actual observer registration is performed by the repeatable/idempotent
// FLMEnsureKeyboardObserversRegistered function below.
static dispatch_once_t FLMKeyboardTransportBootstrapOnceToken;
static dispatch_queue_t FLMKeyboardTransportQueue;
static char FLMKeyboardTransportQueueKey;
static NSUInteger FLMKeyboardTransportAttempt = 0;
static BOOL FLMKeyboardTransportRetryScheduled = NO;
static BOOL FLMKeyboardTransportReady = NO;
static BOOL FLMKeyboardTransportFailureLogged = NO;
static uint64_t FLMKeyboardTransportClaimedSession = 0;
static uint64_t FLMKeyboardTransportClaimedGeneration = 0;
static const NSUInteger FLMKeyboardTransportMaxAttempts = 6;
static const NSTimeInterval FLMKeyboardTransportRetryDelays[] = {
    0.25, 0.50, 1.00, 2.00, 4.00,
};
static FLMKeyboardTransportChannelState
    FLMKeyboardTransportChannels[FLMKeyboardTransportChannelCount] = {
        {"route", FLYME_KEYBOARD_NOTIFICATION, -1, -1, NO, NO},
        {"scene", FLYME_KEYBOARD_SCENE_NOTIFICATION, -1, -1, NO, NO},
        {"session", FLYME_KEYBOARD_SESSION_NOTIFICATION, -1, -1, NO, NO},
        {"avoidance", FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION, -1, -1, NO, NO},
        {"geometry", FLYME_KEYBOARD_CARD_GEOMETRY_NOTIFICATION, -1, -1, NO, NO},
        {"shared-state", FLYME_KEYBOARD_SHARED_STATE_NOTIFICATION, -1, -1, NO, NO},
        {"dismiss", FLYME_KEYBOARD_DISMISS_REQUEST_NOTIFICATION, -1, -1, NO, NO},
    };
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
static BOOL FLMEnsureKeyboardObserversRegistered(void);
static void FLMScheduleKeyboardTransportRetry(void);
static void FLMUpdateContentViewportAdapter(void);
static void FLMInstallInputGeometryDiagnosticsIfNeeded(void);
static void FLMCaptureInputGeometryForNotification(NSNotification *notification,
                                                    BOOL allowRetry);
static uint64_t FLMIdentifierHash(NSString *identifier);
static void FLMHandleKeyboardDismissRequest(void);
static void FLMHandleKeyboardDismissRequestWithSharedState(
    NSDictionary *sharedState);
static BOOL FLMClaimKeyboardDismissGeneration(uint64_t session,
                                              uint64_t generation);

typedef NS_ENUM(uint8_t, FLMKeyboardDismissResult) {
    FLMKeyboardDismissResultSuccess = 1,
    FLMKeyboardDismissResultNoResponder = 2,
    FLMKeyboardDismissResultFailed = 3,
    FLMKeyboardDismissResultSceneFallbackSuccess = 4,
    FLMKeyboardDismissResultStaleGeneration = 5,
    FLMKeyboardDismissResultWrongProcess = 6,
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

static NSString *FLMKeyboardDismissResultName(FLMKeyboardDismissResult result) {
    switch (result) {
        case FLMKeyboardDismissResultSuccess:
            return @"success";
        case FLMKeyboardDismissResultNoResponder:
            return @"no-responder";
        case FLMKeyboardDismissResultFailed:
            return @"failed";
        case FLMKeyboardDismissResultSceneFallbackSuccess:
            return @"scene-fallback-success";
        case FLMKeyboardDismissResultStaleGeneration:
            return @"stale-generation";
        case FLMKeyboardDismissResultWrongProcess:
            return @"wrong-process";
        default:
            return @"unknown";
    }
}

static void FLMPublishKeyboardAppLifecycleStage(const char *notificationName,
                                                int *token,
                                                uint64_t magic,
                                                FLMDiagnosticEvent event) {
    pid_t currentPID = getpid();
    uint64_t currentBuildGeneration = FLYME_KEYBOARD_APP_ADAPTER_BUILD;
    if (FLMKeyboardLifecyclePID != currentPID ||
        FLMKeyboardLifecycleBuildGeneration != currentBuildGeneration) {
        FLMKeyboardLifecyclePID = currentPID;
        FLMKeyboardLifecycleBuildGeneration = currentBuildGeneration;
        FLMKeyboardAdapterCtorPublished = NO;
        FLMKeyboardAdapterReadyPublished = NO;
    }
    BOOL *published = event == FLMDiagnosticEventAdapterCtor
                          ? &FLMKeyboardAdapterCtorPublished
                          : &FLMKeyboardAdapterReadyPublished;
    if (*published) {
        NSLog(@"[FlymeKeyboard] adapter-%@ skipped=process-ready-once key={pid:%d build:%llu}",
              event == FLMDiagnosticEventAdapterCtor ? @"ctor" : @"ready",
              currentPID,
              (unsigned long long)currentBuildGeneration);
        return;
    }
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
    *published = YES;
    if (event == FLMDiagnosticEventAdapterCtor) {
        NSLog(@"[FlymeKeyboard] adapter-ctor pid=%d bundle=%@ process=%@ bundleHash=0x%04x",
              getpid(), bundleIdentifier ?: @"<none>",
              processName ?: @"<none>", bundleHash);
    } else {
        NSLog(@"[FlymeKeyboard] adapter-ready once=1 key={pid:%d build:%llu} bundle=%@ process=%@ bundleHash=0x%04x",
              currentPID, (unsigned long long)currentBuildGeneration,
              bundleIdentifier ?: @"<none>",
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
    state[@"version"] = @4;
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
    uint64_t routeGeneration = 0;
    uint64_t sharedStateGeneration = 0;
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
        routeGeneration =
            [sharedState[@"routeGeneration"] unsignedLongLongValue];
        sharedStateGeneration =
            [sharedState[@"stateGeneration"] unsignedLongLongValue];
    } else if (FLMKeyboardTransportChannels[
                   FLMKeyboardTransportChannelRoute]
                   .token >= 0) {
        notify_get_state(FLMKeyboardTransportChannels[
                             FLMKeyboardTransportChannelRoute]
                             .token,
                         &targetHash);
        if (FLMKeyboardTransportChannels[
                FLMKeyboardTransportChannelSession]
                .token >= 0) {
            notify_get_state(FLMKeyboardTransportChannels[
                                 FLMKeyboardTransportChannelSession]
                                 .token,
                             &sessionGeneration);
        }
        if (FLMKeyboardTransportChannels[FLMKeyboardTransportChannelScene]
                .token >= 0) {
            notify_get_state(FLMKeyboardTransportChannels[
                                 FLMKeyboardTransportChannelScene]
                                 .token,
                             &sceneHash);
        }
    }

    // The shared plist notification is only a wake-up.  Read the route
    // generation first and discard a repeated Darwin delivery before doing
    // any Scene, geometry, or lifecycle work.  The raw notify path remains a
    // compatibility fallback for an older writer, so it uses the complete
    // route tuple as its dedupe key.
    BOOL sameRawRoute = targetHash == FLMKeyboardLastRouteTargetHash &&
                        sceneHash == FLMKeyboardLastRouteSceneHash &&
                        sessionGeneration == FLMKeyboardLastRouteSession;
    if (sharedStateAvailable && sharedStateGeneration != 0 &&
        sharedStateGeneration <= FLMKeyboardLastHandledSharedStateGeneration &&
        routeGeneration <= FLMKeyboardLastRouteGeneration) {
        return;
    }
    // A newer shared-state generation can represent only avoidance, card
    // geometry, or a dismiss request. Those nodes have their own observers;
    // never re-run route/Scene work when the route generation is unchanged.
    if (sharedStateAvailable && routeGeneration != 0 &&
        routeGeneration <= FLMKeyboardLastRouteGeneration) {
        if (sharedStateGeneration > FLMKeyboardLastHandledSharedStateGeneration) {
            FLMKeyboardLastHandledSharedStateGeneration = sharedStateGeneration;
        }
        return;
    }
    if (routeGeneration != 0 &&
        routeGeneration <= FLMKeyboardLastRouteGeneration && sameRawRoute) {
        if (sharedStateGeneration > FLMKeyboardLastHandledSharedStateGeneration) {
            FLMKeyboardLastHandledSharedStateGeneration = sharedStateGeneration;
        }
        return;
    }
    if (routeGeneration == 0 && sameRawRoute &&
        FLMKeyboardLastProcessedSession == sessionGeneration) {
        return;
    }
    if (routeGeneration != 0) {
        FLMKeyboardLastRouteGeneration = routeGeneration;
    }
    if (sharedStateGeneration != 0) {
        FLMKeyboardLastHandledSharedStateGeneration = sharedStateGeneration;
    }
    FLMKeyboardLastRouteTargetHash = targetHash;
    FLMKeyboardLastRouteSceneHash = sceneHash;
    FLMKeyboardLastRouteSession = sessionGeneration;

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
    FLMKeyboardLastProcessedSession = sessionGeneration;
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
        NSLog(@"[FlymeKeyboard] route-applied generation=%llu session=%llu target=%d sceneHash=0x%016llx sharedState=%d",
              (unsigned long long)routeGeneration,
              (unsigned long long)sessionGeneration,
              FLMKeyboardTargetApplication,
              (unsigned long long)sceneHash,
              sharedStateAvailable);
    }
    FLMUpdateContentViewportAdapter();
}

static void FLMReloadKeyboardCardGeometry(void) {
    uint64_t state = 0;
    NSDictionary *sharedState = FLMReadKeyboardSharedState();
    uint64_t geometryGeneration =
        [sharedState[@"geometryGeneration"] unsignedLongLongValue];
    uint64_t geometrySession =
        [sharedState[@"sessionGeneration"] unsignedLongLongValue];
    if (sharedState && geometryGeneration != 0 &&
        geometryGeneration <= FLMKeyboardLastGeometryGeneration &&
        geometrySession == FLMKeyboardSessionGeneration) {
        return;
    }
    if (geometryGeneration != 0) {
        FLMKeyboardLastGeometryGeneration = geometryGeneration;
    }
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
        BOOL changed = FLMKeyboardCardGeometryActive != current ||
                       FLMKeyboardCardGeometryGeneration !=
                           (current ? generation : 0) ||
                       fabs(FLMKeyboardCardBottom - (current ? cardBottom : 0.0)) >
                           0.25 ||
                       fabs(FLMKeyboardCardVisualScale -
                            (current ? visualScale : 0.0)) > 0.0005;
        FLMKeyboardCardGeometryActive = current;
        FLMKeyboardCardGeometryGeneration = current ? generation : 0;
        FLMKeyboardCardBottom = current ? cardBottom : 0.0;
        FLMKeyboardCardVisualScale = current ? visualScale : 0.0;
        if (FLMKeyboardTargetApplication && changed) {
            FLMPublishDiagnosticEvent(
                FLMDiagnosticRoleApplication,
                FLMDiagnosticEventCardGeometry,
                FLMKeyboardSessionGeneration,
                FLMDiagnosticUnsignedValue(FLMKeyboardCardBottom),
                FLMDiagnosticUnsignedValue(FLMKeyboardCardVisualScale *
                                           1000.0));
        }
        if (changed) {
            FLMUpdateContentViewportAdapter();
        }
        return;
    }
    if (FLMKeyboardTransportChannels[FLMKeyboardTransportChannelCardGeometry]
            .token < 0 ||
        notify_get_state(
            FLMKeyboardTransportChannels[FLMKeyboardTransportChannelCardGeometry]
                .token,
            &state) !=
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
    BOOL changed = FLMKeyboardCardGeometryActive != current ||
                   FLMKeyboardCardGeometryGeneration !=
                       (current ? generation : 0) ||
                   fabs(FLMKeyboardCardBottom - (current ? cardBottom : 0.0)) >
                       0.25 ||
                   fabs(FLMKeyboardCardVisualScale -
                        (current ? visualScale : 0.0)) > 0.0005;
    FLMKeyboardCardGeometryActive = current;
    FLMKeyboardCardGeometryGeneration = current ? generation : 0;
    FLMKeyboardCardBottom = current ? cardBottom : 0.0;
    FLMKeyboardCardVisualScale = current ? visualScale : 0.0;
    if (FLMKeyboardTargetApplication && changed) {
        FLMPublishDiagnosticEvent(
            FLMDiagnosticRoleApplication,
            FLMDiagnosticEventCardGeometry,
            FLMKeyboardSessionGeneration,
            FLMDiagnosticUnsignedValue(FLMKeyboardCardBottom),
            FLMDiagnosticUnsignedValue(FLMKeyboardCardVisualScale * 1000.0));
    }
    if (changed) {
        FLMUpdateContentViewportAdapter();
    }
}

static void FLMReloadKeyboardAvoidance(void) {
    uint64_t state = 0;
    NSDictionary *sharedState = FLMReadKeyboardSharedState();
    uint64_t avoidanceGeneration =
        [sharedState[@"avoidanceGeneration"] unsignedLongLongValue];
    uint64_t avoidanceSession =
        [sharedState[@"sessionGeneration"] unsignedLongLongValue];
    if (sharedState && avoidanceGeneration != 0 &&
        avoidanceGeneration <= FLMKeyboardLastAvoidanceGeneration &&
        avoidanceSession == FLMKeyboardSessionGeneration) {
        // A route notification can carry a newer overall state generation
        // while the avoidance node itself is unchanged.
        return;
    }
    BOOL visible = NO;
    uint64_t generation = 0;
    CGFloat height = 0.0;
    if (sharedState) {
        visible = [sharedState[@"avoidanceVisible"] boolValue];
        generation =
            [sharedState[@"sessionGeneration"] unsignedLongLongValue];
        height = [sharedState[@"avoidanceHeight"] doubleValue];
    } else if (FLMKeyboardTransportChannels[FLMKeyboardTransportChannelAvoidance]
                   .token < 0 ||
               notify_get_state(
                   FLMKeyboardTransportChannels[
                       FLMKeyboardTransportChannelAvoidance]
                       .token,
                   &state) != NOTIFY_STATUS_OK) {
        return;
    } else {
        visible = (state & (1ULL << 63)) != 0;
        generation = (state >> 24) & 0x7FFFFFFFFFULL;
        height = (CGFloat)(state & 0xFFFFFFULL) / 100.0;
    }
    if (avoidanceGeneration != 0) {
        FLMKeyboardLastAvoidanceGeneration =
            MAX(FLMKeyboardLastAvoidanceGeneration, avoidanceGeneration);
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
    NSString *className = NSStringFromClass(window.class);
    if (window.windowLevel != UIWindowLevelNormal ||
        [className rangeOfString:@"TextEffects"].location != NSNotFound ||
        [className rangeOfString:@"Keyboard"
                          options:NSCaseInsensitiveSearch].location !=
            NSNotFound ||
        [className rangeOfString:@"Remote"
                          options:NSCaseInsensitiveSearch].location !=
            NSNotFound) {
        return NO;
    }
    return YES;
}

// Dismissal is validated by the immutable bundle/PID request tuple.  A
// routed Scene is only the preferred lookup; it is not a process boundary.
// In particular, WeChat can keep its remote Scene connected while another
// application is frontmost in SpringBoard.
static BOOL FLMIsProcessApplicationContentWindow(UIWindow *window) {
    if (!window || window.hidden || window.alpha <= 0.01 ||
        !window.rootViewController || !window.windowScene) {
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

static BOOL FLMSceneMatchesDismissHash(UIWindowScene *scene,
                                       uint64_t sceneHash) {
    return sceneHash != 0 && [scene isKindOfClass:[UIWindowScene class]] &&
           FLMIdentifierHash(FLMSceneIdentifier(scene)) == sceneHash;
}

static BOOL FLMHasDismissScene(uint64_t sceneHash) {
    if (sceneHash == 0) {
        return NO;
    }
    for (UIScene *connectedScene in
         [UIApplication sharedApplication].connectedScenes) {
        if (FLMSceneMatchesDismissHash((UIWindowScene *)connectedScene,
                                       sceneHash)) {
            return YES;
        }
    }
    return NO;
}

static UIView *FLMFirstResponderInDismissScene(uint64_t sceneHash) {
    if (sceneHash == 0) {
        return nil;
    }
    for (UIScene *connectedScene in
         [UIApplication sharedApplication].connectedScenes) {
        if (!FLMSceneMatchesDismissHash((UIWindowScene *)connectedScene,
                                        sceneHash)) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)connectedScene).windows) {
            if (!FLMIsProcessApplicationContentWindow(window)) {
                continue;
            }
            UIView *responder =
                FLMFirstResponderInView(window.rootViewController.view);
            if (responder) {
                return responder;
            }
        }
    }
    return nil;
}

static UIView *FLMFirstResponderInCurrentProcessWindows(UIWindow **windowOut) {
    UIWindow *fallbackWindow = nil;
    UIView *fallbackResponder = nil;
    for (UIScene *connectedScene in
         [UIApplication sharedApplication].connectedScenes) {
        if (![connectedScene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)connectedScene).windows) {
            if (!FLMIsProcessApplicationContentWindow(window)) {
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
                return responder;
            }
            fallbackWindow = window;
            fallbackResponder = responder;
        }
    }
    if (windowOut) {
        *windowOut = fallbackWindow;
    }
    return fallbackResponder;
}

static FLMKeyboardDismissResult FLMResignTargetApplicationResponder(
    uint64_t sessionGeneration,
    uint64_t requestGeneration,
    uint64_t preferredSceneHash,
    BOOL sceneFallback,
    BOOL sendApplicationAction) {
    NSLog(@"[FlymeKeyboard] responder-resign begin session=%llu requestGeneration=%llu sceneFallback=%d action=%d",
          (unsigned long long)sessionGeneration,
          (unsigned long long)requestGeneration,
          sceneFallback,
          sendApplicationAction);
    UIView *beforeResponder = nil;
    UIWindow *responderWindow = nil;
    beforeResponder = sceneFallback
                          ? FLMFirstResponderInCurrentProcessWindows(
                                &responderWindow)
                          : FLMFirstResponderInDismissScene(preferredSceneHash);
    BOOL hadResponder = beforeResponder != nil;
    NSUInteger endedWindows = 0;
    BOOL cleanupThrew = NO;
    @try {
        // The action is sent once in the precise-target phase. A same-request
        // next-run-loop retry only repeats endEditing, which avoids a second
        // application-wide resign storm while still allowing a late UIKit
        // responder to settle.
        if (sendApplicationAction) {
            [[UIApplication sharedApplication]
                sendAction:@selector(resignFirstResponder)
                       to:nil
                     from:nil
                 forEvent:nil];
        }
        for (UIScene *connectedScene in
             [UIApplication sharedApplication].connectedScenes) {
            if (![connectedScene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)connectedScene).windows) {
                BOOL eligibleWindow = sceneFallback
                                           ? FLMIsProcessApplicationContentWindow(
                                                 window)
                                           : FLMSceneMatchesDismissHash(
                                                 (UIWindowScene *)connectedScene,
                                                 preferredSceneHash) &&
                                             FLMIsProcessApplicationContentWindow(
                                                 window);
                if (!eligibleWindow) {
                    continue;
                }
                if ([window endEditing:YES]) {
                    endedWindows += 1;
                }
            }
        }
    } @catch (__unused NSException *exception) {
        cleanupThrew = YES;
    }

    UIView *afterResponder = nil;
    afterResponder = sceneFallback
                         ? FLMFirstResponderInCurrentProcessWindows(NULL)
                         : FLMFirstResponderInDismissScene(preferredSceneHash);
    BOOL responderRemains = afterResponder != nil;
    FLMKeyboardDismissResult result = responderRemains
                                          ? FLMKeyboardDismissResultFailed
                                      : cleanupThrew
                                          ? FLMKeyboardDismissResultFailed
                                      : sceneFallback
                                          ? FLMKeyboardDismissResultSceneFallbackSuccess
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
    NSLog(@"[FlymeKeyboard] responder-resign end session=%llu requestGeneration=%llu sceneFallback=%d result=%@ window=%@",
          (unsigned long long)sessionGeneration,
          (unsigned long long)requestGeneration,
          sceneFallback,
          FLMKeyboardDismissResultName(result),
          responderWindow ? NSStringFromClass(responderWindow.class) : @"<none>");
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
    FLMHandleKeyboardDismissRequestWithSharedState(FLMReadKeyboardSharedState());
}

static void FLMHandleKeyboardDismissRequestWithSharedState(
    NSDictionary *sharedState) {
    if (![NSThread isMainThread]) {
        NSDictionary *snapshot = [sharedState copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            FLMHandleKeyboardDismissRequestWithSharedState(snapshot);
        });
        return;
    }
    BOOL sharedRequest =
        [sharedState[@"dismissRequestGeneration"] isKindOfClass:[NSNumber class]] &&
        [sharedState[@"dismissSession"] isKindOfClass:[NSNumber class]] &&
        [sharedState[@"dismissSessionGeneration"] isKindOfClass:[NSNumber class]] &&
        [sharedState[@"dismissRequestGeneration"] unsignedLongLongValue] != 0;
    if (!sharedRequest) {
        // The v1 command is authenticated by the immutable shared snapshot.
        // A packed Darwin compatibility state without bundle/PID fields is not
        // sufficient to identify the application that may resign input.
        return;
    }

    uint64_t requestedSession =
        [sharedState[@"dismissSession"] unsignedLongLongValue];
    uint64_t requestedSessionGeneration =
        [sharedState[@"dismissSessionGeneration"] unsignedLongLongValue];
    uint64_t requestGeneration =
        [sharedState[@"dismissRequestGeneration"] unsignedLongLongValue];
    uint64_t requestedSceneHash =
        [sharedState[@"dismissSceneHash"] unsignedLongLongValue];
    uint64_t requestedBundleHash =
        [sharedState[@"dismissBundleHash"] unsignedLongLongValue];
    pid_t requestedAdapterPID =
        (pid_t)[sharedState[@"dismissAdapterPID"] intValue];
    uint64_t sharedSessionGeneration =
        [sharedState[@"sessionGeneration"] unsignedLongLongValue];
    uint64_t requestState = FLMPackKeyboardDismissRequestState(
        requestedSession, requestGeneration);

    NSString *bundleIdentifier = [NSBundle mainBundle].bundleIdentifier;
    NSString *processName = [NSProcessInfo processInfo].processName;
    uint64_t currentBundleHash = FLMIdentifierHash(bundleIdentifier);
    BOOL bundleMatches = requestedBundleHash != 0 &&
                         requestedBundleHash == currentBundleHash;
    BOOL processMatches = requestedAdapterPID > 1 &&
                          requestedAdapterPID == getpid();
    if (!FLMIsEligibleApplicationProcess() || !bundleMatches ||
        !processMatches) {
        // Bundle/PID validation is the process boundary. It intentionally does
        // not consult FLMKeyboardRouteActive or FLMKeyboardTargetApplication.
        NSLog(@"[FlymeKeyboard] target-validation result=wrong-process bundle=%@ bundleMatches=%d requestedBundleHash=0x%016llx currentBundleHash=0x%016llx requestedAdapterPID=%d currentPID=%d",
              bundleIdentifier ?: @"<none>", bundleMatches,
              (unsigned long long)requestedBundleHash,
              (unsigned long long)currentBundleHash,
              requestedAdapterPID, getpid());
        return;
    }

    FLMPublishDiagnosticEvent(FLMDiagnosticRoleApplication,
                              FLMDiagnosticEventDismissRequest,
                              requestedSessionGeneration,
                              (uint16_t)(requestGeneration & 0xFFFFULL),
                              (uint16_t)(requestedSceneHash & 0xFFFFULL));
    NSLog(@"[FlymeKeyboard] application dismiss-request received count=1 pid=%d bundle=%@ process=%@ requestedSceneHash=0x%016llx session=%llu sessionGeneration=%llu sharedSessionGeneration=%llu requestGeneration=%llu adapterPID=%d state=0x%016llx",
          getpid(), bundleIdentifier ?: @"<none>", processName ?: @"<none>",
          (unsigned long long)requestedSceneHash,
          (unsigned long long)requestedSession,
          (unsigned long long)requestedSessionGeneration,
          (unsigned long long)sharedSessionGeneration,
          (unsigned long long)requestGeneration,
          requestedAdapterPID, (unsigned long long)requestState);

    if (requestedSession == 0 || requestGeneration == 0 ||
        requestedSessionGeneration == 0 || sharedSessionGeneration == 0 ||
        requestedSession != sharedSessionGeneration ||
        requestedSessionGeneration != sharedSessionGeneration) {
        NSLog(@"app dismiss-request rejected=stale-generation bundle=%@ session=%llu sharedSession=%llu sessionGeneration=%llu requestGeneration=%llu",
              bundleIdentifier ?: @"<none>",
              (unsigned long long)requestedSession,
              (unsigned long long)sharedSessionGeneration,
              (unsigned long long)requestedSessionGeneration,
              (unsigned long long)requestGeneration);
        FLMSendKeyboardDismissAck(requestedSession, requestGeneration,
                                  FLMKeyboardDismissResultStaleGeneration);
        return;
    }

    // Claim before any Scene lookup or responder work. Duplicate Darwin
    // deliveries therefore cannot enqueue a second main-thread cleanup.
    if (!FLMClaimKeyboardDismissGeneration(requestedSession,
                                            requestGeneration)) {
        NSLog(@"[FlymeKeyboard] dismiss-request ignored=claimed session=%llu requestGeneration=%llu claimedSession=%llu claimedGeneration=%llu",
              (unsigned long long)requestedSession,
              (unsigned long long)requestGeneration,
              (unsigned long long)FLMKeyboardTransportClaimedSession,
              (unsigned long long)FLMKeyboardTransportClaimedGeneration);
        return;
    }
    FLMKeyboardLastDismissSession = requestedSession;
    FLMKeyboardLastDismissGeneration = requestGeneration;
    FLMKeyboardLastProcessedSession = requestedSession;

    BOOL preciseSceneAvailable = FLMHasDismissScene(requestedSceneHash);
    BOOL sceneFallback = !preciseSceneAvailable;
    NSLog(@"[FlymeKeyboard] target-validation result=process-match bundle=%@ pid=%d requestedAdapterPID=%d scenePreferred=%d sceneFallback=%d requestedSceneHash=0x%016llx",
          bundleIdentifier ?: @"<none>", getpid(), requestedAdapterPID,
          preciseSceneAvailable, sceneFallback,
          (unsigned long long)requestedSceneHash);
    FLMKeyboardDismissResult result = FLMResignTargetApplicationResponder(
        requestedSessionGeneration, requestGeneration, requestedSceneHash,
        sceneFallback, YES);
    if (result == FLMKeyboardDismissResultFailed) {
        NSLog(@"app dismiss-request retry-scheduled bundle=%@ session=%llu sessionGeneration=%llu requestGeneration=%llu delay=0.08 action=already-sent",
              bundleIdentifier ?: @"<none>",
              (unsigned long long)requestedSession,
              (unsigned long long)requestedSessionGeneration,
              (unsigned long long)requestGeneration);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.08 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSDictionary *currentState = FLMReadKeyboardSharedState();
            uint64_t currentSession =
                [currentState[@"sessionGeneration"] unsignedLongLongValue];
            uint64_t currentRequest =
                [currentState[@"dismissRequestGeneration"] unsignedLongLongValue];
            if (currentSession != requestedSessionGeneration ||
                currentRequest != requestGeneration) {
                FLMSendKeyboardDismissAck(
                    requestedSession, requestGeneration,
                    FLMKeyboardDismissResultStaleGeneration);
                return;
            }
            BOOL retrySceneFallback = !FLMHasDismissScene(requestedSceneHash);
            FLMKeyboardDismissResult retryResult =
                FLMResignTargetApplicationResponder(
                    requestedSessionGeneration, requestGeneration,
                    requestedSceneHash, retrySceneFallback, NO);
            FLMSendKeyboardDismissAck(requestedSession, requestGeneration,
                                      retryResult);
        });
        return;
    }
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
    if (!FLMKeyboardTargetApplication) {
        return;
    }
    static dispatch_once_t inputObserverOnceToken;
    dispatch_once(&inputObserverOnceToken, ^{
        if (!FLMRegisterInputDiagnosticTokens()) {
            return;
        }
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
        NSLog(@"[FlymeKeyboard] input-geometry-observers registered-once=1");
    });
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

static void FLMProcessGlobalTransportBootstrap(void) {
    dispatch_once(&FLMKeyboardTransportBootstrapOnceToken, ^{
        FLMKeyboardTransportQueue =
            dispatch_queue_create("com.codex.flymemultitasking.keyboard-transport",
                                  DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(FLMKeyboardTransportQueue,
                                    &FLMKeyboardTransportQueueKey,
                                    &FLMKeyboardTransportQueueKey,
                                    NULL);
        NSLog(@"[FlymeKeyboard] keyboard-transport bootstrap transport=global");
    });
}

static uint64_t FLMKeyboardTransportUnsignedValue(NSDictionary *state,
                                                  NSString *key) {
    id value = state[key];
    return [value respondsToSelector:@selector(unsignedLongLongValue)]
               ? [value unsignedLongLongValue]
               : 0;
}

static BOOL FLMClaimKeyboardDismissGeneration(uint64_t session,
                                              uint64_t generation) {
    if (session == 0 || generation == 0) {
        return NO;
    }
    FLMProcessGlobalTransportBootstrap();
    __block BOOL claimed = NO;
    void (^claimBlock)(void) = ^{
        if (session != FLMKeyboardTransportClaimedSession) {
            FLMKeyboardTransportClaimedSession = session;
            FLMKeyboardTransportClaimedGeneration = 0;
        }
        if (generation <= FLMKeyboardTransportClaimedGeneration) {
            return;
        }
        FLMKeyboardTransportClaimedGeneration = generation;
        claimed = YES;
    };
    if (dispatch_get_specific(&FLMKeyboardTransportQueueKey)) {
        claimBlock();
    } else {
        dispatch_sync(FLMKeyboardTransportQueue, claimBlock);
    }
    return claimed;
}

static void FLMLogKeyboardTransportReceive(
    FLMKeyboardTransportChannelIndex channel,
    NSDictionary *sharedState) {
    NSString *bundleIdentifier = [NSBundle mainBundle].bundleIdentifier;
    uint64_t session = FLMKeyboardTransportUnsignedValue(
        sharedState, @"sessionGeneration");
    uint64_t routeGeneration = FLMKeyboardTransportUnsignedValue(
        sharedState, @"routeGeneration");
    if (channel == FLMKeyboardTransportChannelDismiss) {
        uint64_t requestedBundleHash = FLMKeyboardTransportUnsignedValue(
            sharedState, @"dismissBundleHash");
        uint64_t currentBundleHash = FLMIdentifierHash(bundleIdentifier);
        uint64_t requestGeneration = FLMKeyboardTransportUnsignedValue(
            sharedState, @"dismissRequestGeneration");
        uint64_t requestedSession = FLMKeyboardTransportUnsignedValue(
            sharedState, @"dismissSession");
        pid_t requestedPID =
            (pid_t)FLMKeyboardTransportUnsignedValue(sharedState,
                                                      @"dismissAdapterPID");
        NSLog(@"[FlymeKeyboard] transport-recv channel=dismiss session=%llu generation=%llu pid=%d requestedPID=%d bundleMatch=%d",
              (unsigned long long)requestedSession,
              (unsigned long long)requestGeneration,
              getpid(), requestedPID,
              requestedBundleHash != 0 &&
                  requestedBundleHash == currentBundleHash);
        return;
    }
    const char *label = FLMKeyboardTransportChannels[channel].label;
    NSLog(@"[FlymeKeyboard] transport-recv channel=%s routeGeneration=%llu session=%llu pid=%d",
          label, (unsigned long long)routeGeneration,
          (unsigned long long)session, getpid());
}

static void FLMHandleKeyboardTransportChannel(
    FLMKeyboardTransportChannelIndex channel) {
    NSDictionary *sharedState = FLMReadKeyboardSharedState();
    FLMLogKeyboardTransportReceive(channel, sharedState);
    switch (channel) {
        case FLMKeyboardTransportChannelRoute:
        case FLMKeyboardTransportChannelScene:
        case FLMKeyboardTransportChannelSession:
            FLMHandleKeyboardRouteNotification();
            break;
        case FLMKeyboardTransportChannelSharedState:
            // Shared-state publication is also the reliable wake-up after
            // SpringBoard atomically writes a dismiss tuple. Process that
            // tuple directly here; it must not wait for route reload to have
            // succeeded or for the compatibility dismiss event to win a
            // delivery race.
            FLMHandleKeyboardDismissRequestWithSharedState(sharedState);
            FLMHandleKeyboardRouteNotification();
            break;
        case FLMKeyboardTransportChannelAvoidance:
            FLMReloadKeyboardAvoidance();
            break;
        case FLMKeyboardTransportChannelCardGeometry:
            FLMReloadKeyboardCardGeometry();
            break;
        case FLMKeyboardTransportChannelDismiss:
            FLMHandleKeyboardDismissRequest();
            break;
        default:
            break;
    }
}

static void FLMRegisterKeyboardTransportChannel(
    FLMKeyboardTransportChannelIndex channelIndex,
    NSUInteger attempt) {
    FLMKeyboardTransportChannelState *channel =
        &FLMKeyboardTransportChannels[channelIndex];
    if (channel->registered) {
        return;
    }
    int previousStatus = channel->status;
    BOOL previousRegistered = channel->registered;
    channel->token = -1;
    channel->status = notify_register_dispatch(
        channel->notificationName, &channel->token, dispatch_get_main_queue(),
        ^(__unused int token) {
            FLMHandleKeyboardTransportChannel(channelIndex);
        });
    channel->registered = channel->status == NOTIFY_STATUS_OK &&
                         channel->token >= 0;
    if (!channel->registered) {
        channel->token = -1;
    }
    if (!channel->statusLogged || previousStatus != channel->status ||
        previousRegistered != channel->registered) {
        NSLog(@"[FlymeKeyboard] keyboard-transport register channel=%s status=%d token=%d attempt=%lu",
              channel->label, channel->status, channel->token,
              (unsigned long)attempt);
        channel->statusLogged = YES;
    }
}

static BOOL FLMEnsureKeyboardObserversRegistered(void) {
    if (!FLMIsEligibleApplicationProcess()) {
        return NO;
    }
    FLMProcessGlobalTransportBootstrap();
    if (FLMKeyboardTransportReady) {
        return YES;
    }

    __block BOOL ready = NO;
    void (^registrationBlock)(void) = ^{
        if (FLMKeyboardTransportReady) {
            ready = YES;
            return;
        }
        if (FLMKeyboardTransportAttempt >= FLMKeyboardTransportMaxAttempts) {
            ready = NO;
            return;
        }
        NSUInteger attempt = ++FLMKeyboardTransportAttempt;
        for (NSUInteger index = 0;
             index < FLMKeyboardTransportChannelCount; index++) {
            FLMRegisterKeyboardTransportChannel(
                (FLMKeyboardTransportChannelIndex)index, attempt);
        }
        NSUInteger registeredCount = 0;
        for (NSUInteger index = 0;
             index < FLMKeyboardTransportChannelCount; index++) {
            if (FLMKeyboardTransportChannels[index].registered) {
                registeredCount += 1;
            }
        }
        ready = registeredCount == FLMKeyboardTransportChannelCount;
        if (ready) {
            FLMKeyboardTransportReady = YES;
            NSLog(@"[FlymeKeyboard] keyboard-transport ready registered=%lu/7 pid=%d",
                  (unsigned long)registeredCount, getpid());
        } else if (attempt >= FLMKeyboardTransportMaxAttempts &&
                   !FLMKeyboardTransportFailureLogged) {
            NSMutableString *failedChannels = [NSMutableString string];
            for (NSUInteger index = 0;
                 index < FLMKeyboardTransportChannelCount; index++) {
                if (!FLMKeyboardTransportChannels[index].registered) {
                    if (failedChannels.length > 0) {
                        [failedChannels appendString:@","];
                    }
                    [failedChannels appendFormat:@"%s",
                                                  FLMKeyboardTransportChannels[index].label];
                }
            }
            FLMKeyboardTransportFailureLogged = YES;
            NSLog(@"[FlymeKeyboard] keyboard-transport failed registered=%lu/7 failedChannels=%@",
                  (unsigned long)registeredCount, failedChannels);
        }
    };
    if (dispatch_get_specific(&FLMKeyboardTransportQueueKey)) {
        registrationBlock();
    } else {
        dispatch_sync(FLMKeyboardTransportQueue, registrationBlock);
    }
    return ready;
}

static void FLMScheduleKeyboardTransportRetry(void) {
    if (FLMKeyboardTransportReady || FLMKeyboardTransportRetryScheduled ||
        FLMKeyboardTransportAttempt >= FLMKeyboardTransportMaxAttempts) {
        return;
    }
    // Attempt 1 is the immediate registration. The first retry is therefore
    // the 250 ms slot, followed by 500 ms, 1 s, 2 s and 4 s.
    NSUInteger retryIndex = FLMKeyboardTransportAttempt > 0
                                ? FLMKeyboardTransportAttempt - 1
                                : 0;
    if (retryIndex >= sizeof(FLMKeyboardTransportRetryDelays) /
                            sizeof(FLMKeyboardTransportRetryDelays[0])) {
        return;
    }
    FLMKeyboardTransportRetryScheduled = YES;
    NSTimeInterval delay = FLMKeyboardTransportRetryDelays[retryIndex];
    NSLog(@"[FlymeKeyboard] keyboard-transport retry-scheduled attempt=%lu delay=%.2f",
          (unsigned long)(retryIndex + 2), delay);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FLMKeyboardTransportRetryScheduled = NO;
        if (FLMEnsureKeyboardObserversRegistered()) {
            FLMReloadKeyboardRoute();
            if (!FLMKeyboardHooksInstalled &&
                FLMIsEligibleApplicationProcess() &&
                (FLMKeyboardTargetApplication ||
                 FLMIsExplicitWeChatAdapterProcess())) {
                FLMRegisterKeyboardNotificationsAndInitialize();
            }
        } else {
            FLMScheduleKeyboardTransportRetry();
        }
    });
}

static void FLMRegisterKeyboardRouteObserversIfNeeded(void) {
    if (!FLMIsEligibleApplicationProcess()) {
        return;
    }
    if (!FLMEnsureKeyboardObserversRegistered()) {
        FLMScheduleKeyboardTransportRetry();
    }
}

static void FLMHandleKeyboardRouteNotification(void) {
    FLMReloadKeyboardRoute();
    if (!FLMKeyboardHooksInstalled && FLMIsEligibleApplicationProcess() &&
        FLMKeyboardTargetApplication) {
        // UIKit may load this generic adapter before SpringBoard publishes
        // the wheel target. A later route event must be able to complete the
        // target-gated initialization without waiting for the retry budget.
        FLMPublishKeyboardAppLifecycleStage(
            FLYME_KEYBOARD_APP_CTOR_NOTIFICATION,
            &FLMKeyboardAppCtorToken,
            FLYME_KEYBOARD_APP_CTOR_MAGIC,
            FLMDiagnosticEventAdapterCtor);
        FLMRegisterKeyboardNotificationsAndInitialize();
    }
}

static void FLMRegisterKeyboardNotificationsAndInitialize(void) {
    if (FLMKeyboardHooksInstalled || !FLMIsEligibleApplicationProcess() ||
        (!FLMKeyboardTargetApplication &&
         !FLMIsExplicitWeChatAdapterProcess())) {
        return;
    }
    if (!FLMEnsureKeyboardObserversRegistered()) {
        FLMScheduleKeyboardTransportRetry();
        return;
    }
    FLMKeyboardHooksInstalled = YES;

    // The ctor marker is intentionally published before transport readiness;
    // the ready marker below is reserved for a complete 7/7 transport.
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
    FLMPublishKeyboardAppLifecycleStage(
        FLYME_KEYBOARD_APP_CTOR_NOTIFICATION,
        &FLMKeyboardAppCtorToken,
        FLYME_KEYBOARD_APP_CTOR_MAGIC,
        FLMDiagnosticEventAdapterCtor);
    if (!FLMKeyboardTransportReady) {
        FLMScheduleKeyboardTransportRetry();
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
