#import <UIKit/UIKit.h>
#import <math.h>
#import <notify.h>
#import <unistd.h>

#import "FLMDiagnostics.h"

#define FLYME_KEYBOARD_NOTIFICATION "com.codex.flymemultitasking.keyboard-state-changed"
#define FLYME_KEYBOARD_SCENE_NOTIFICATION "com.codex.flymemultitasking.keyboard-scene-changed"
#define FLYME_KEYBOARD_SESSION_NOTIFICATION "com.codex.flymemultitasking.keyboard-session-changed"
#define FLYME_KEYBOARD_FRAME_NOTIFICATION "com.codex.flymemultitasking.keyboard-frame-changed"
#define FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION "com.codex.flymemultitasking.keyboard-avoidance-changed"
#define FLYME_KEYBOARD_CARD_GEOMETRY_NOTIFICATION "com.codex.flymemultitasking.keyboard-card-geometry-changed"
#define FLYME_KEYBOARD_DISMISS_NOTIFICATION "com.codex.flymemultitasking.keyboard-dismiss-requested"
#define FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION "com.codex.flymemultitasking.keyboard-dismiss-acknowledged"

static BOOL FLMKeyboardRouteActive = NO;
static BOOL FLMKeyboardTargetApplication = NO;
static BOOL FLMKeyboardExtensionProcess = NO;
static int FLMKeyboardRouteToken = -1;
static int FLMKeyboardSceneToken = -1;
static int FLMKeyboardSessionToken = -1;
static int FLMKeyboardFrameToken = -1;
static int FLMKeyboardAvoidanceToken = -1;
static int FLMKeyboardCardGeometryToken = -1;
static int FLMKeyboardDismissToken = -1;
static uint64_t FLMKeyboardTargetSceneHash = 0;
static uint64_t FLMKeyboardSessionGeneration = 0;
static uint64_t FLMKeyboardEndedSessionGeneration = 0;
static uint64_t FLMExternalKeyboardAvoidanceGeneration = 0;
static CGFloat FLMExternalKeyboardAvoidanceHeight = 0.0;
static __weak UIResponder *FLMKeyboardActiveTextResponder = nil;
static id FLMKeyboardWillHideObserver = nil;
static id FLMKeyboardHideObserver = nil;
static BOOL FLMEndingApplicationKeyboardSession = NO;
static BOOL FLMRemoteKeyboardGeometryInstalled = NO;
static BOOL FLMKeyboardCardGeometryActive = NO;
static BOOL FLMDeliveringCorrectedKeyboardNotification = NO;
static uint64_t FLMKeyboardCardGeometryGeneration = 0;
static CGFloat FLMKeyboardCardBottom = 0.0;
static CGFloat FLMKeyboardCardVisualScale = 0.0;

static FLMDiagnosticRole FLMKeyboardDiagnosticRole(void) {
    if (FLMKeyboardExtensionProcess) {
        return FLMDiagnosticRoleKeyboardExtension;
    }
    if (FLMKeyboardTargetApplication) {
        return FLMDiagnosticRoleApplication;
    }
    return FLMDiagnosticRoleUIKitOther;
}

static void FLMRefreshApplicationKeyboardLayout(void);
static void FLMInstallRemoteKeyboardGeometryIfAvailable(void);
static void FLMReloadKeyboardAvoidance(void);
static void FLMReloadKeyboardCardGeometry(void);

static BOOL FLMProcessIsKeyboardExtension(void) {
    NSDictionary *extension =
        [NSBundle mainBundle].infoDictionary[@"NSExtension"];
    NSString *pointIdentifier =
        [extension isKindOfClass:[NSDictionary class]]
            ? extension[@"NSExtensionPointIdentifier"]
            : nil;
    return [pointIdentifier isKindOfClass:[NSString class]] &&
           [pointIdentifier rangeOfString:@"keyboard-service"
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
        NSString *persistentIdentifier = scene.session.persistentIdentifier;
        if (persistentIdentifier.length > 0) {
            return persistentIdentifier;
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
    if (FLMKeyboardTargetSceneHash == 0) {
        return YES;
    }
    // A third-party keyboard extension owns a remote keyboard Scene, not the
    // target application's UIWindowScene identifier. The active Darwin
    // session already limits this route to the selected keyboard lifetime;
    // do not query UIApplication from an extension process.
    if (FLMKeyboardExtensionProcess) {
        return YES;
    }
    uint64_t currentHash = FLMIdentifierHash(FLMSceneIdentifier(scene));
    // Some iOS 16 app scenes hide their private sceneIdentifier until the
    // first keyboard transaction. The process-level bundle route is still a
    // safer fallback than leaving the keyboard trapped in the card.
    if (currentHash == 0 || currentHash == FLMKeyboardTargetSceneHash) {
        return YES;
    }

    // SpringBoard's private sceneIdentifier and the application process's
    // UISceneSession persistentIdentifier are not guaranteed to be the same
    // string on iOS 16. The bundle route already limits this tweak to the one
    // target application process, so accept its connected UIWindowScene as a
    // safe process-local fallback instead of silently skipping all avoidance.
    NSSet<UIScene *> *connectedScenes =
        [UIApplication sharedApplication].connectedScenes;
    for (UIScene *connectedScene in connectedScenes) {
        if (connectedScene == scene) {
            return YES;
        }
    }
    return connectedScenes.count <= 1;
}

static CGRect FLMPhysicalReferenceBoundsForScene(UIWindowScene *scene) {
    CGSize size = FLMFullPhysicalScreenSize();
    if ([scene isKindOfClass:[UIWindowScene class]] &&
        UIInterfaceOrientationIsLandscape(scene.interfaceOrientation)) {
        size = CGSizeMake(size.height, size.width);
    }
    return CGRectMake(0.0, 0.0, size.width, size.height);
}

static BOOL FLMResignFirstResponderInView(UIView *view) {
    if (!view) {
        return NO;
    }
    BOOL resigned = NO;
    @try {
        if (view.isFirstResponder) {
            resigned = [view resignFirstResponder] || resigned;
        }
        for (UIView *subview in [view.subviews copy]) {
            resigned = FLMResignFirstResponderInView(subview) || resigned;
        }
    } @catch (__unused NSException *exception) {
    }
    return resigned;
}

static void FLMEndApplicationKeyboardSession(void) {
    if (FLMEndingApplicationKeyboardSession) {
        return;
    }
    FLMEndingApplicationKeyboardSession = YES;
    UIResponder *activeResponder = FLMKeyboardActiveTextResponder;
    @try {
        if (activeResponder) {
            [activeResponder resignFirstResponder];
        }
    } @catch (__unused NSException *exception) {
    }
    if (@available(iOS 13.0, *)) {
        for (UIScene *connectedScene in
             [UIApplication sharedApplication].connectedScenes) {
            if (![connectedScene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)connectedScene).windows) {
                FLMResignFirstResponderInView(window);
                [window endEditing:YES];
            }
        }
    }
    [[UIApplication sharedApplication]
        sendAction:@selector(resignFirstResponder)
               to:nil
             from:nil
         forEvent:nil];
    FLMKeyboardActiveTextResponder = nil;
    FLMEndingApplicationKeyboardSession = NO;
}

static void FLMRefreshApplicationKeyboardLayout(void) {
    if (!FLMKeyboardTargetApplication) {
        return;
    }
    FLMPublishDiagnosticEvent(
        FLMDiagnosticRoleApplication,
        FLMDiagnosticEventLayoutRefresh,
        FLMKeyboardSessionGeneration,
        FLMDiagnosticUnsignedValue(FLMExternalKeyboardAvoidanceHeight),
        FLMKeyboardCardGeometryActive ? 1 : 0);
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
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!FLMKeyboardRouteActive) {
            return;
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
                [window layoutIfNeeded];
                [window.rootViewController.view layoutIfNeeded];
            }
        }
    });
}

static void FLMReloadKeyboardRoute(void) {
    uint64_t targetHash = 0;
    if (FLMKeyboardRouteToken >= 0) {
        notify_get_state(FLMKeyboardRouteToken, &targetHash);
    }
    NSString *currentIdentifier = [NSBundle mainBundle].bundleIdentifier;
    uint64_t currentHash = FLMIdentifierHash(currentIdentifier);
    BOOL previousRouteActive = FLMKeyboardRouteActive;
    BOOL previousTargetApplication = FLMKeyboardTargetApplication;
    uint64_t sessionGeneration = 0;
    if (FLMKeyboardSessionToken >= 0) {
        notify_get_state(FLMKeyboardSessionToken, &sessionGeneration);
    }
    uint64_t previousSessionGeneration = FLMKeyboardSessionGeneration;
    BOOL sessionChanged =
        sessionGeneration != previousSessionGeneration;
    FLMKeyboardSessionGeneration = sessionGeneration;
    FLMKeyboardTargetApplication =
        sessionGeneration != 0 && targetHash != 0 && currentHash != 0 &&
        targetHash == currentHash;
    FLMKeyboardExtensionProcess = FLMProcessIsKeyboardExtension();
    FLMKeyboardRouteActive =
        FLMKeyboardTargetApplication ||
        (sessionGeneration != 0 && targetHash != 0 &&
         FLMKeyboardExtensionProcess);
    FLMKeyboardTargetSceneHash = 0;
    if (FLMKeyboardSceneToken >= 0) {
        notify_get_state(FLMKeyboardSceneToken,
                         &FLMKeyboardTargetSceneHash);
    }
    if (sessionChanged) {
        FLMExternalKeyboardAvoidanceGeneration = 0;
        FLMExternalKeyboardAvoidanceHeight = 0.0;
        // Close any responder and keyboard Scene retained by the previous
        // centered card before the new generation is allowed to focus. This
        // does not depend on delivery of the
        // short-lived route-off notification between two openings.
        if (previousSessionGeneration != 0 && previousRouteActive &&
            previousTargetApplication) {
            FLMKeyboardEndedSessionGeneration = previousSessionGeneration;
            FLMEndApplicationKeyboardSession();
        }
        if (sessionGeneration != 0) {
            FLMKeyboardEndedSessionGeneration = 0;
        }
    }
    if (!FLMKeyboardTargetApplication) {
        FLMExternalKeyboardAvoidanceGeneration = 0;
        FLMExternalKeyboardAvoidanceHeight = 0.0;
    }
    FLMReloadKeyboardCardGeometry();
    uint16_t routeFlags =
        (FLMKeyboardRouteActive ? 1U : 0U) |
        (FLMKeyboardTargetApplication ? 2U : 0U) |
        (FLMKeyboardExtensionProcess ? 4U : 0U) |
        (sessionChanged ? 8U : 0U) |
        (previousRouteActive ? 16U : 0U) |
        (FLMKeyboardTargetSceneHash != 0 ? 32U : 0U);
    if (sessionChanged || FLMKeyboardRouteActive || previousRouteActive) {
        FLMPublishDiagnosticEvent(
            FLMKeyboardDiagnosticRole(),
            FLMDiagnosticEventRouteReload,
            FLMKeyboardSessionGeneration,
            routeFlags,
            (uint16_t)(targetHash & 0xFFFFULL));
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
    BOOL currentSession =
        FLMKeyboardTargetApplication && active && generation != 0 &&
        generation == (FLMKeyboardSessionGeneration & 0x7FFFULL) &&
        cardBottom > 1.0 && visualScale > 0.05;
    FLMKeyboardCardGeometryActive = currentSession;
    FLMKeyboardCardGeometryGeneration = currentSession ? generation : 0;
    FLMKeyboardCardBottom = currentSession ? cardBottom : 0.0;
    FLMKeyboardCardVisualScale = currentSession ? visualScale : 0.0;
    if (FLMKeyboardTargetApplication || FLMKeyboardExtensionProcess) {
        FLMPublishDiagnosticEvent(
            FLMKeyboardDiagnosticRole(),
            FLMDiagnosticEventCardGeometry,
            FLMKeyboardSessionGeneration,
            FLMDiagnosticUnsignedValue(FLMKeyboardCardBottom),
            FLMDiagnosticUnsignedValue(FLMKeyboardCardVisualScale * 1000.0));
    }
}

static void FLMReloadKeyboardAvoidance(void) {
    uint64_t state = 0;
    if (FLMKeyboardAvoidanceToken < 0 ||
        notify_get_state(FLMKeyboardAvoidanceToken, &state) != NOTIFY_STATUS_OK) {
        return;
    }
    BOOL visible = (state & (1ULL << 63)) != 0;
    uint64_t sessionGeneration = (state >> 24) & 0x7FFFFFFFFFULL;
    CGFloat heiÛ­·¶‰ËkºwµçA¥ÍÅÕ…±Q½MÑÉ¥¹œéU%-•å‰½…É‘]¥±±!¥‘•9½Ñ¥™¥…Ñ¥½¹tñğ(€€€€€€€m¹…µ”¥ÍÅÕ…±Q½MÑÉ¥¹œéU%-•å‰½…É‘¥‘!¥‘•9½Ñ¥™¥…Ñ¥½¹tì(€€€	==0Á¡åÍ¥…±±åY¥Í¥‰±”€ô(€€€€€€€€…¡¥‘•9½Ñ¥™¥…Ñ¥½¸€˜˜I•Ñ•Ñ!•¥¡Ğ¡É…İ¹‘É…µ”¤€ø€Ä¸À€˜˜(€€€€€€€I•Ñ•Ñ5¥¹d¡É…İ¹‘É…µ”¤€ğÁ¡åÍ¥…±M¥é”¹¡•¥¡Ğ€´€Ä¸Àì((€€€Õ¥¹ĞÄÙ}Ğ¹½Ñ¥™¥…Ñ¥½¹±…Ì€ôÁ¡åÍ¥…±±åY¥Í¥‰±”€ü€ÅT€è€ÁTì(€€€¥˜€¡m¹…µ”¥ÍÅÕ…±Q½MÑÉ¥¹œéU%-•å‰½…É‘]¥±±M¡½İ9½Ñ¥™¥…Ñ¥½¹t¤ì(€€€€€€€¹½Ñ¥™¥…Ñ¥½¹±…Ìğô€ÅT€ğğ€Äì(€€€ô•±Í”¥˜€¡m¹…µ”¥ÍÅÕ…±Q½MÑÉ¥¹œéU%-•å‰½…É‘¥‘M¡½İ9½Ñ¥™¥…Ñ¥½¹t¤ì(€€€€€€€¹½Ñ¥™¥…Ñ¥½¹±…Ìğô€ÅT€ğğ€Èì(€€€ô•±Í”¥˜€¡m¹…µ”¥ÍÅÕ…±Q½MÑÉ¥¹œéU%-•å‰½…É‘]¥±±!¥‘•9½Ñ¥™¥…Ñ¥½¹t¤ì(€€€€€€€¹½Ñ¥™¥…Ñ¥½¹±…Ìğô€ÅT€ğğ€Ìì(€€€ô•±Í”¥˜€¡m¹…µ”¥ÍÅÕ…±Q½MÑÉ¥¹œéU%-•å‰½…É‘¥‘!¥‘•9½Ñ¥™¥…Ñ¥½¹t¤ì(€€€€€€€¹½Ñ¥™¥…Ñ¥½¹±…Ìğô€ÅT€ğğ€Ğì(€€€ô•±Í”¥˜€¡m¹…µ”¥ÍÅÕ…±Q½MÑÉ¥¹œéU%-•å‰½…É‘]¥±±¡…¹•É…µ•9½Ñ¥™¥…Ñ¥½¹t¤ì(€€€€€€€¹½Ñ¥™¥…Ñ¥½¹±…Ìğô€ÅT€ğğ€Ôì(€€€ô•±Í”¥˜€¡m¹…µ”¥ÍÅÕ…±Q½MÑÉ¥¹œéU%-•å‰½…É‘¥‘¡…¹•É…µ•9½Ñ¥™¥…Ñ¥½¹t¤ì(€€€€€€€¹½Ñ¥™¥…Ñ¥½¹±…Ìğô€ÅT€ğğ€Øì(€€€ô(€€€15AÕ‰±¥Í¡¥…¹½ÍÑ¥Ù•¹Ğ (€€€€€€€15¥…¹½ÍÑ¥I½±•ÁÁ±¥…Ñ¥½¸°(€€€€€€€15¥…¹½ÍÑ¥Ù•¹ÑÉ…µ•=‰Í•ÉÙ•°(€€€€€€€15-•å‰½…É‘M•ÍÍ¥½¹•¹•É…Ñ¥½¸°(€€€€€€€¹½Ñ¥™¥…Ñ¥½¹±…Ì°(€€€€€€€15¥…¹½ÍÑ¥U¹Í¥¹•‘Y…±Õ”¡I•Ñ•Ñ!•¥¡Ğ¡É…İ¹‘É…µ”¤¤¤ì((€€€€¼¼MÁÉ¥¹	½…ÉÍÑ¥±°½¹ÍÕµ•ÌÑ¡”Õ¹µ½‘¥™¥•Á¡åÍ¥…°™É…µ”Ñ¼¡½ÍĞÑ¡”(€€€€¼¼­•å‰½…É½¸Ñ¡”‘¥ÍÁ±…ä¸=¹±äÑ¡”Ñ…É•Ğ…ÁÁ±¥…Ñ¥½¸É••¥Ù•ÌÑ¡”M•¹”´(€€€€¼¼±½¥…°É•Á±…•µ•¹Ğ‰•±½Ü¸(€€€15AÕ‰±¥Í¡-•å‰½…É‘É…µ”¡É…İ¹‘É…µ”°Á¡åÍ¥…±±åY¥Í¥‰±”¤ì((€€€	==0•½µ•ÑÉåÕÉÉ•¹Ğ€ô(€€€€€€€15-•å‰½…É‘…É‘•½µ•ÑÉåÑ¥Ù”€˜˜(€€€€€€€15-•å‰½…É‘…É‘•½µ•ÑÉå•¹•É…Ñ¥½¸€ôô(€€€€€€€€€€€€¡15-•å‰½…É‘M•ÍÍ¥½¹•¹•É…Ñ¥½¸€˜€ÁàİU10¤€˜˜(€€€€€€€15-•å‰½…É‘…É‘Y¥ÍÕ…±M…±”€ø€À¸ÀÔ€˜˜(€€€€€€€I•Ñ•Ñ]¥‘Ñ ¡±½¥…±	½Õ¹‘Ì¤€ø€Ä¸À€˜˜(€€€€€€€I•Ñ•Ñ!•¥¡Ğ¡±½¥…±	½Õ¹‘Ì¤€ø€Ä¸Àì(€€€¥˜€ …•½µ•ÑÉåÕÉÉ•¹Ğ¤ì(€€€€€€€15AÕ‰±¥Í¡¥…¹½ÍÑ¥Ù•¹Ğ (€€€€€€€€€€€15¥…¹½ÍÑ¥I½±•ÁÁ±¥…Ñ¥½¸°(€€€€€€€€€€€15¥…¹½ÍÑ¥Ù•¹ÑÉ…µ•½ÉÉ•Ñ•°(€€€€€€€€€€€15-•å‰½…É‘M•ÍÍ¥½¹•¹•É…Ñ¥½¸°(€€€€€€€€€€€€À°(€€€€€€€€€€€15¥…¹½ÍÑ¥U¹Í¥¹•‘Y…±Õ”¡I•Ñ•Ñ!•¥¡Ğ¡±½¥…±	½Õ¹‘Ì¤¤¤ì(€€€€€€€É•ÑÕÉ¸ÕÍ•É%¹™¼ì(€€€ô((€€€±½…ĞÁÉ•Ù¥½ÕÍ!•¥¡Ğ€ô(€€€€€€€15áÑ•É¹…±-•å‰½…É‘Ù½¥‘…¹••¹•É…Ñ¥½¸€ôô15-•å‰½…É‘M•ÍÍ¥½¹•¹•É…Ñ¥½¸(€€€€€€€€€€€€ü15áÑ•É¹…±-•å‰½…É‘Ù½¥‘…¹•!•¥¡Ğ(€€€€€€€€€€€€è€À¸Àì(€€€±½…Ğ±½¥…±!•¥¡Ğ€ô€À¸Àì(€€€¥˜€¡Á¡åÍ¥…±±åY¥Í¥‰±”¤ì(€€€€€€€±½¥…±!•¥¡Ğ€ô151½¥…±Ù½¥‘…¹•½ÉA¡åÍ¥…±-•å‰½…É‘Q½À (€€€€€€€€€€€I•Ñ•Ñ5¥¹d¡É…İ¹‘É…µ”¤°±½¥…±	½Õ¹‘Ì¤ì(€€€€€€€15áÑ•É¹…±-•å‰½…É‘Ù½¥‘…¹••¹•É…Ñ¥½¸€ô15-•å‰½…É‘M•ÍÍ¥½¹•¹•É…Ñ¥½¸ì(€€€€€€€15áÑ•É¹…±-•å‰½…É‘Ù½¥‘…¹•!•¥¡Ğ€ô±½¥…±!•¥¡Ğì(€€€ô•±Í”ì(€€€€€€€15áÑ•É¹…±-•å‰½…É‘Ù½¥‘…¹••¹•É…Ñ¥½¸€ô€Àì(€€€€€€€15áÑ•É¹…±-•å‰½…É‘Ù½¥‘…¹•!•¥¡Ğ€ô€À¸Àì(€€€ô((€€€±½…Ğİ¥‘Ñ €ôI•Ñ•Ñ]¥‘Ñ ¡±½¥…±	½Õ¹‘Ì¤ì(€€€±½…Ğ¡•¥¡Ğ€ôI•Ñ•Ñ!•¥¡Ğ¡±½¥…±	½Õ¹‘Ì¤ì(€€€±½…Ğ•¹‘!•¥¡Ğ€ôÁ¡åÍ¥…±±åY¥Í¥‰±”€ü±½¥…±!•¥¡Ğ€è5` Ä¸À°ÁÉ•Ù¥½ÕÍ!•¥¡Ğ¤ì(€€€I•Ğ½ÉÉ•Ñ•‘¹€ô(€€€€€€€I•Ñ5…­” À¸À°(€€€€€€€€€€€€€€€€€€Á¡åÍ¥…±±åY¥Í¥‰±”€ü¡•¥¡Ğ€´±½¥…±!•¥¡Ğ€è¡•¥¡Ğ°(€€€€€€€€€€€€€€€€€€İ¥‘Ñ °(€€€€€€€€€€€€€€€€€€•¹‘!•¥¡Ğ¤ì(€€€I•Ğ½ÉÉ•Ñ•‘	•¥¸€ô(€€€€€€€ÁÉ•Ù¥½ÕÍ!•¥¡Ğ€ø€Ä¸À(€€€€€€€€€€€€üI•Ñ5…­” À¸À°(€€€€€€€€€€€€€€€€€€€€€€€€¡•¥¡Ğ€´ÁÉ•Ù¥½ÕÍ!•¥¡Ğ°(€€€€€€€€€€€€€€€€€€€€€€€€İ¥‘Ñ °(€€€€€€€€€€€€€€€€€€€€€€€€ÁÉ•Ù¥½ÕÍ!•¥¡Ğ¤(€€€€€€€€€€€€èI•Ñ5…­” À¸À°¡•¥¡Ğ°İ¥‘Ñ °5` Ä¸À°±½¥…±!•¥¡Ğ¤¤ì(€€€9M5ÕÑ…‰±•¥Ñ¥½¹…Éä€©½ÉÉ•Ñ•€ômÕÍ•É%¹™¼µÕÑ…‰±•½Áåtì(€€€½ÉÉ•Ñ•‘mU%-•å‰½…É‘É…µ•	•¥¹UÍ•É%¹™½-•åt€ô(€€€€€€€m9MY…±Õ”Ù…±Õ•]¥Ñ¡I•Ğé½ÉÉ•Ñ•‘	•¥¹tì(€€€½ÉÉ•Ñ•‘mU%-•å‰½…É‘É…µ•¹‘UÍ•É%¹™½-•åt€ô(€€€€€€€m9MY…±Õ”Ù…±Õ•]¥Ñ¡I•Ğé½ÉÉ•Ñ•‘¹‘tì(€€€15AÕ‰±¥Í¡¥…¹½ÍÑ¥Ù•¹Ğ (€€€€€€€15¥…¹½ÍÑ¥I½±•ÁÁ±¥…Ñ¥½¸°(€€€€€€€15¥…¹½ÍÑ¥Ù•¹ÑÉ…µ•½ÉÉ•Ñ•°(€€€€€€€15-•å‰½…É‘M•ÍÍ¥½¹•¹•É…Ñ¥½¸°(€€€€€€€15¥…¹½ÍÑ¥U¹Í¥¹•‘Y…±Õ”¡±½¥…±!•¥¡Ğ¤°(€€€€€€€15¥…¹½ÍÑ¥U¹Í¥¹•‘Y…±Õ”¡I•Ñ•Ñ!•¥¡Ğ¡±½¥…±	½Õ¹‘Ì¤¤¤ì(€€€É•ÑÕÉ¸½ÉÉ•Ñ•ì)ô((•¡½½¬9M9½Ñ¥™¥…Ñ¥½¹•¹Ñ•È((´€¡Ù½¥¥Á½ÍÑ9½Ñ¥™¥…Ñ¥½¹9…µ”è¡9M9½Ñ¥™¥…Ñ¥½¹9…µ”¥¹…µ”(€€€€€€€€€€€€€€€€€€€€€½‰©•Ğè¡¥¥½‰©•Ğ(€€€€€€€€€€€€€€€€€€€ÕÍ•É%¹™¼è¡9M¥Ñ¥½¹…Éä€¨¥ÕÍ•É%¹™¼ì(€€€¥˜€¡15•±¥Ù•É¥¹½ÉÉ•Ñ•‘-•å‰½…É‘9½Ñ¥™¥…Ñ¥½¸¤ì(€€€€€€€€•½É¥œì(€€€€€€€É•ÑÕÉ¸ì(€€€ô(€€€9M¥Ñ¥½¹…Éä€©½ÉÉ•Ñ•‘UÍ•É%¹™¼€ô(€€€€€€€15½ÉÉ•Ñ-•å‰½…É‘9½Ñ¥™¥…Ñ¥½¹UÍ•É%¹™¼¡¹…µ”°ÕÍ•É%¹™¼¤ì(€€€15•±¥Ù•É¥¹½ÉÉ•Ñ•‘-•å‰½…É‘9½Ñ¥™¥…Ñ¥½¸€ôeLì(€€€€•½É¥œ¡¹…µ”°½‰©•Ğ°½ÉÉ•Ñ•‘UÍ•É%¹™¼¤ì(€€€15•±¥Ù•É¥¹½ÉÉ•Ñ•‘-•å‰½…É‘9½Ñ¥™¥…Ñ¥½¸€ô9<ì)ô((´€¡Ù½¥¥Á½ÍÑ9½Ñ¥™¥…Ñ¥½¸è¡9M9½Ñ¥™¥…Ñ¥½¸€¨¥¹½Ñ¥™¥…Ñ¥½¸ì(€€€¥˜€¡15•±¥Ù•É¥¹½ÉÉ•Ñ•‘-•å‰½…É‘9½Ñ¥™¥…Ñ¥½¸ñğ(€€€€€€€€…15%Í-•å‰½…É‘É…µ•9½Ñ¥™¥…Ñ¥½¸¡¹½Ñ¥™¥…Ñ¥½¸¹¹…µ”¤¤ì(€€€€€€€€•½É¥œì(€€€€€€€É•ÑÕÉ¸ì(€€€ô(€€€9M¥Ñ¥½¹…Éä€©½ÉÉ•Ñ•‘UÍ•É%¹™¼€ô(€€€€€€€15½ÉÉ•Ñ-•å‰½…É‘9½Ñ¥™¥…Ñ¥½¹UÍ•É%¹™¼¡¹½Ñ¥™¥…Ñ¥½¸¹¹…µ”°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€¹½Ñ¥™¥…Ñ¥½¸¹ÕÍ•É%¹™¼¤ì(€€€9M9½Ñ¥™¥…Ñ¥½¸€©½ÉÉ•Ñ•‘9½Ñ¥™¥…Ñ¥½¸€ô(€€€€€€€½ÉÉ•Ñ•‘UÍ•É%¹™¼€ôô¹½Ñ¥™¥…Ñ¥½¸¹ÕÍ•É%¹™¼(€€€€€€€€€€€€ü¹½Ñ¥™¥…Ñ¥½¸(€€€€€€€€€€€€èm9M9½Ñ¥™¥…Ñ¥½¸¹½Ñ¥™¥…Ñ¥½¹]¥Ñ¡9…µ”é¹½Ñ¥™¥…Ñ¥½¸¹¹…µ”(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€½‰©•Ğé¹½Ñ¥™¥…Ñ¥½¸¹½‰©•Ğ(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€ÕÍ•É%¹™¼é½ÉÉ•Ñ•‘UÍ•É%¹™½tì(€€€15•±¥Ù•É¥¹½ÉÉ•Ñ•‘-•å‰½…É‘9½Ñ¥™¥…Ñ¥½¸€ôeLì(€€€€•½É¥œ¡½ÉÉ•Ñ•‘9½Ñ¥™¥…Ñ¥½¸¤ì(€€€15•±¥Ù•É¥¹½ÉÉ•Ñ•‘-•å‰½…É‘9½Ñ¥™¥…Ñ¥½¸€ô9<ì)ô((••¹((•¡½½¬U%Q•áÑ™™•ÑÍ]¥¹‘½Ü((´€¡M¥é”¥­•å‰½…É‘MÉ••¹I•™•É•¹•M¥é”ì(€€€U%]¥¹‘½İM•¹”€©Í•¹”€ô€ ¡U%]¥¹‘½Ü€¨¥Í•±˜¤¹İ¥¹‘½İM•¹”ì(€€€	==0µ…Ñ¡•Ì€ô15M•¹•5…Ñ¡•Í-•å‰½…É‘I½ÕÑ”¡Í•¹”¤ì(€€€¥˜€¡15-•å‰½…É‘I½ÕÑ•Ñ¥Ù”¤ì(€€€€€€€15AÕ‰±¥Í¡¥…¹½ÍÑ¥Ù•¹Ğ (€€€€€€€€€€€15-•å‰½…É‘¥…¹½ÍÑ¥I½±” ¤°(€€€€€€€€€€€15¥…¹½ÍÑ¥Ù•¹ÑM•¹•5…Ñ °(€€€€€€€€€€€15-•å‰½…É‘M•ÍÍ¥½¹•¹•É…Ñ¥½¸°(€€€€€€€€€€€µ…Ñ¡•Ì€ü€Ä€è€À°(€€€€€€€€€€€15-•å‰½…É‘Q…É•ÑM•¹•!…Í €„ô€À€ü€Ä€è€À¤ì(€€€ô(€€€¥˜€ …µ…Ñ¡•Ì¤ì(€€€€€€€É•ÑÕÉ¸€•½É¥œì(€€€ô(€€€M¥é”Í¥é”€ô15A¡åÍ¥…±I•™•É•¹•	½Õ¹‘Í½ÉM•¹”¡Í•¹”¤¹Í¥é”ì(€€€15AÕ‰±¥Í¡¥…¹½ÍÑ¥Ù•¹Ğ (€€€€€€€15-•å‰½…É‘¥…¹½ÍÑ¥I½±” ¤°(€€€€€€€15¥…¹½ÍÑ¥Ù•¹ÑÉ…µ•½ÉÉ•Ñ•°(€€€€€€€15-•å‰½…É‘M•ÍÍ¥½¹•¹•É…Ñ¥½¸°(€€€€€€€15¥…¹½ÍÑ¥U¹Í¥¹•‘Y…±Õ”¡Í¥é”¹İ¥‘Ñ ¤°(€€€€€€€15¥…¹½ÍÑ¥U¹Í¥¹•‘Y…±Õ”¡Í¥é”¹¡•¥¡Ğ¤¤ì(€€€É•ÑÕÉ¸Í¥é”ì)ô((´€¡I•Ğ¥}É•™•É•¹•	½Õ¹‘Ìì(€€€I•Ğ‰½Õ¹‘Ì€ô€•½É¥œì(€€€€¼¼QÉ½±±=Á•¸Ì¥=L€ÄØÁ…Ñ ±•…Ù•ÌÑ¡¥Ì½¹ÑÉ…ĞÕ¹Ñ½Õ¡•¸=Ù•ÉÉ¥‘¥¹œ¥Ğ(€€€€¼¼¡…¹•ÌÑ¡”­•å‰½…Éİ¥¹‘½ÜÌ½İ¸½½É‘¥¹…Ñ”ÍÁ…”…¹‰É•…­ÌÉ•µ½Ñ”(€€€€¼¼M•¹”Á…¥É¥¹œ¸­•å‰½…É‘MÉ••¹I•™•É•¹•M¥é”¥ÌÑ¡”Á¡åÍ¥…°µ‘¥ÍÁ±…ä(€€€€¼¼½¹ÑÉ½°Á½¥¹Ğì}É•™•É•¹•	½Õ¹‘ÌµÕÍĞÉ•µ…¥¸U%-¥Ğµ½İ¹•¸(€€€É•ÑÕÉ¸‰½Õ¹‘Ìì)ô((••¹((•É½ÕÀ15I•µ½Ñ•-•å‰½…É‘•½µ•ÑÉä((•¡½½¬}U%I•µ½Ñ•-•å‰½…É‘Ì((´€¡±½…Ğ¥¥¹Ñ•ÉÍ•Ñ¥½¹!•¥¡Ñ½É]¥¹‘½İM•¹”è¡U%]¥¹‘½İM•¹”€¨¥İ¥¹‘½İM•¹”(€€€€€€€€€€€€€€€€€€€¥Í1½…±5¥¹¥µÕµ!•¥¡Ñ=ÕĞè¡	==0€¨¥¥Í1½…±5¥¹¥µÕµ!•¥¡Ñ=ÕĞ(€€€€€€€€€€€€€€€€€€€€¥¹½É•!½É¥é½¹Ñ…±=™™Í•Ğè¡	==0¥¥¹½É•!½É¥é½¹Ñ…±=™™Í•Ğì(€€€±½…Ğ½É¥¥¹…±!•¥¡Ğ€ô€•½É¥œ¡İ¥¹‘½İM•¹”°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€¥Í1½…±5¥¹¥µÕµ!•¥¡Ñ=ÕĞ°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€¥¹½É•!½É¥é½¹Ñ…±=™™Í•Ğ¤ì(€€€¥˜€ …15M•¹•5…Ñ¡•Í-•å‰½…É‘I½ÕÑ”¡İ¥¹‘½İM•¹”¤¤ì(€€€€€€€É•ÑÕÉ¸½É¥¥¹…±!•¥¡Ğì(€€€ô(€€€¥˜€ …15-•å‰½…É‘Q…É•ÑÁÁ±¥…Ñ¥½¸¤ì(€€€€€€€É•ÑÕÉ¸½É¥¥¹…±!•¥¡Ğì(€€€ô(€€€¥˜€¡U%%¹Ñ•É™…•=É¥•¹Ñ…Ñ¥½¹%Í1…¹‘Í…Á”¡İ¥¹‘½İM•¹”¹¥¹Ñ•É™…•=É¥•¹Ñ…Ñ¥½¸¤¤ì(€€€€€€€É•ÑÕÉ¸€À¸Àì(€€€ô((€€€¥˜€¡15áÑ•É¹…±-•å‰½…É‘Ù½¥‘…¹••¹•É…Ñ¥½¸€„ô(€€€€€€€€€€€15-•å‰½…É‘M•ÍÍ¥½¹•¹•É…Ñ¥½¸ñğ(€€€€€€€15áÑ•É¹…±-•å‰½…É‘Ù½¥‘…¹•!•¥¡Ğ€ğô€Ä¸À¤ì(€€€€€€€I•Ğ±½¥…±	½Õ¹‘Ì€ô15Q…É•ÑÁÁ±¥…Ñ¥½¹1½¥…±	½Õ¹‘Ì ¤ì(€€€€€€€M¥é”Á¡åÍ¥…±M¥é”€ô15Õ±±A¡åÍ¥…±MÉ••¹M¥é” ¤ì(€€€€€€€¥˜€¡I•Ñ•Ñ]¥‘Ñ ¡±½¥…±	½Õ¹‘Ì¤€øI•Ñ•Ñ!•¥¡Ğ¡±½¥…±	½Õ¹‘Ì¤€˜˜(€€€€€€€€€€€Á¡åÍ¥…±M¥é”¹İ¥‘Ñ €ğÁ¡åÍ¥…±M¥é”¹¡•¥¡Ğ¤ì(€€€€€€€€€€€Á¡åÍ¥…±M¥é”€ôM¥é•5…­”¡Á¡åÍ¥…±M¥é”¹¡•¥¡Ğ°Á¡åÍ¥…±M¥é”¹İ¥‘Ñ ¤ì(€€€€€€€ô(€€€€€€€±½…Ğµ…ÁÁ•‘!•¥¡Ğ€ô151½¥…±Ù½¥‘…¹•½ÉA¡åÍ¥…±-•å‰½…É‘Q½À (€€€€€€€€€€€Á¡åÍ¥…±M¥é”¹¡•¥¡Ğ€´½É¥¥¹…±!•¥¡Ğ°±½¥…±	½Õ¹‘Ì¤ì(€€€€€€€¥˜€¡µ…ÁÁ•‘!•¥¡Ğ€ğô€Ä¸À¤ì(€€€€€€€€€€€15AÕ‰±¥Í¡¥…¹½ÍÑ¥Ù•¹Ğ (€€€€€€€€€€€€€€€15¥…¹½ÍÑ¥I½±•ÁÁ±¥…Ñ¥½¸°(€€€€€€€€€€€€€€€15¥…¹½ÍÑ¥Ù•¹Ñ%¹Ñ•ÉÍ•Ñ¥½¸°(€€€€€€€€€€€€€€€15-•å‰½…É‘M•ÍÍ¥½¹•¹•É…Ñ¥½¸°(€€€€€€€€€€€€€€€15¥…¹½ÍÑ¥U¹Í¥¹•‘Y…±Õ”¡½É¥¥¹…±!•¥¡Ğ¤°(€€€€€€€€€€€€€€€€À¤ì(€€€€€€€€€€€É•ÑÕÉ¸½É¥¥¹…±!•¥¡Ğì(€€€€€€€ô(€€€€€€€15áÑ•É¹…±-•å‰½…É‘Ù½¥‘…¹••¹•É…Ñ¥½¸€ô15-•å‰½…É‘M•ÍÍ¥½¹•¹•É…Ñ¥½¸ì(€€€€€€€15áÑ•É¹…±-•å‰½…É‘Ù½¥‘…¹•!•¥¡Ğ€ôµ…ÁÁ•‘!•¥¡Ğì(€€€ô((€€€€¼¼Q¡”­•å‰½…ÉÍÕÉ™…”É•µ…¥¹Ì™Õ±°µÍÉ••¸°İ¡¥±”Ñ¡”…ÁÁ±¥…Ñ¥½¸½¹ÍÕµ•Ì(€€€€¼¼Ñ¡”½Ù•É±…Àµ…ÁÁ•¥¹Ñ¼¥ÑÌ½İ¸M•¹”½½É‘¥¹…Ñ•Ì¸Q¡¥Ì¥ÌÁ½ÁÕ±…Ñ•(€€€€¼¼‰•™½É”Ñ¡”¹…Ñ¥Ù”¹½Ñ¥™¥…Ñ¥½¸¥Ì‘•±¥Ù•É•°Í¼U%-¥Ğ…¹…ÁÁ±¥…Ñ¥½¸(€€€€¼¼½‰Í•ÉÙ•ÉÌÉ•…Ñ¡”Í…µ”Ù…±Õ”¥¸Ñ¡”Í…µ”±…å½ÕĞÑÉ…¹Í…Ñ¥½¸¸(€€€15AÕ‰±¥Í¡¥…¹½ÍÑ¥Ù•¹Ğ (€€€€€€€15¥…¹½ÍÑ¥I½±•ÁÁ±¥…Ñ¥½¸°(€€€€€€€15¥…¹½ÍÑ¥Ù•¹Ñ%¹Ñ•ÉÍ•Ñ¥½¸°(€€€€€€€15-•å‰½…É‘M•ÍÍ¥½¹•¹•É…Ñ¥½¸°(€€€€€€€15¥…¹½ÍÑ¥U¹Í¥¹•‘Y…±Õ”¡½É¥¥¹…±!•¥¡Ğ¤°(€€€€€€€15¥…¹½ÍÑ¥U¹Í¥¹•‘Y…±Õ”¡15áÑ•É¹…±-•å‰½…É‘Ù½¥‘…¹•!•¥¡Ğ¤¤ì(€€€É•ÑÕÉ¸15áÑ•É¹…±-•å‰½…É‘Ù½¥‘…¹•!•¥¡Ğì)ô((••¹((••¹(()ÍÑ…Ñ¥ŒÙ½¥15%¹ÍÑ…±±I•µ½Ñ•-•å‰½…É‘•½µ•ÑÉå%™Ù…¥±…‰±”¡Ù½¥¤ì(€€€¥˜€¡15I•µ½Ñ•-•å‰½…É‘•½µ•ÑÉå%¹ÍÑ…±±•ñğ(€€€€€€€€…9M±…ÍÍÉ½µMÑÉ¥¹œ¡ ‰}U%I•µ½Ñ•-•å‰½…É‘Ìˆ¤¤ì(€€€€€€€É•ÑÕÉ¸ì(€€€ô(€€€€•¥¹¥Ğ¡15I•µ½Ñ•-•å‰½…É‘•½µ•ÑÉä¤ì(€€€15I•µ½Ñ•-•å‰½…É‘•½µ•ÑÉå%¹ÍÑ…±±•€ôeLì)ô((•Ñ½Èì(€€€…ÕÑ½É•±•…Í•Á½½°ì(€€€€€€€€•¥¹¥Ğì(€€€€€€€¹½Ñ¥™å}É•¥ÍÑ•É}‘¥ÍÁ…Ñ ¡1e5}-e	=I}9=Q%%Q%=8°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€™15-•å‰½…É‘I½ÕÑ•Q½­•¸°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€‘¥ÍÁ…Ñ¡}•Ñ}µ…¥¹}ÅÕ•Õ” ¤°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€x¡}}Õ¹ÕÍ•¥¹ĞÑ½­•¸¤ì(€€€€€€€€€€€15I•±½…‘-•å‰½…É‘I½ÕÑ” ¤ì(€€€€€€€ô¤ì(€€€€€€€¹½Ñ¥™å}É•¥ÍÑ•É}‘¥ÍÁ…Ñ ¡1e5}-e	=I}M9}9=Q%%Q%=8°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€™15-•å‰½…É‘M•¹•Q½­•¸°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€‘¥ÍÁ…Ñ¡}•Ñ}µ…¥¹}ÅÕ•Õ” ¤°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€x¡}}Õ¹ÕÍ•¥¹ĞÑ½­•¸¤ì(€€€€€€€€€€€15I•±½…‘-•å‰½…É‘I½ÕÑ” ¤ì(€€€€€€€ô¤ì(€€€€€€€¹½Ñ¥™å}É•¥ÍÑ•É}‘¥ÍÁ…Ñ ¡1e5}-e	=I}MMM%=9}9=Q%%Q%=8°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€™15-•å‰½…É‘M•ÍÍ¥½¹Q½­•¸°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€‘¥ÍÁ…Ñ¡}•Ñ}µ…¥¹}ÅÕ•Õ” ¤°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€x¡}}Õ¹ÕÍ•¥¹ĞÑ½­•¸¤ì(€€€€€€€€€€€15I•±½…‘-•å‰½…É‘I½ÕÑ” ¤ì(€€€€€€€ô¤ì(€€€€€€€¹½Ñ¥™å}É•¥ÍÑ•É}‘¥ÍÁ…Ñ ¡1e5}-e	=I}Y=%9}9=Q%%Q%=8°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€™15-•å‰½…É‘Ù½¥‘…¹•Q½­•¸°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€‘¥ÍÁ…Ñ¡}•Ñ}µ…¥¹}ÅÕ•Õ” ¤°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€x¡}}Õ¹ÕÍ•¥¹ĞÑ½­•¸¤ì(€€€€€€€€€€€15I•±½…‘-•å‰½…É‘Ù½¥‘…¹” ¤ì(€€€€€€€ô¤ì(€€€€€€€¹½Ñ¥™å}É•¥ÍÑ•É}‘¥ÍÁ…Ñ ¡1e5}-e	=I}I}=5QIe}9=Q%%Q%=8°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€™15-•å‰½…É‘…É‘•½µ•ÑÉåQ½­•¸°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€‘¥ÍÁ…Ñ¡}•Ñ}µ…¥¹}ÅÕ•Õ” ¤°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€x¡}}Õ¹ÕÍ•¥¹ĞÑ½­•¸¤ì(€€€€€€€€€€€15I•±½…‘-•å‰½…É‘…É‘•½µ•ÑÉä ¤ì(€€€€€€€ô¤ì(€€€€€€€¹½Ñ¥™å}É•¥ÍÑ•É}‘¥ÍÁ…Ñ ¡1e5}-e	=I}%M5%MM}9=Q%%Q%=8°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€™15-•å‰½…É‘¥Íµ¥ÍÍQ½­•¸°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€‘¥ÍÁ…Ñ¡}•Ñ}µ…¥¹}ÅÕ•Õ” ¤°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€x¡}}Õ¹ÕÍ•¥¹ĞÑ½­•¸¤ì(€€€€€€€€€€€¥˜€¡15-•å‰½…É‘Q…É•ÑÁÁ±¥…Ñ¥½¸¤ì(€€€€€€€€€€€€€€€15AÕ‰±¥Í¡¥…¹½ÍÑ¥Ù•¹Ğ (€€€€€€€€€€€€€€€€€€€15¥…¹½ÍÑ¥I½±•ÁÁ±¥…Ñ¥½¸°(€€€€€€€€€€€€€€€€€€€15¥…¹½ÍÑ¥Ù•¹Ñ¥Íµ¥ÍÍI•ÅÕ•ÍĞ°(€€€€€€€€€€€€€€€€€€€15-•å‰½…É‘M•ÍÍ¥½¹•¹•É…Ñ¥½¸°(€€€€€€€€€€€€€€€€€€€€Ä°(€€€€€€€€€€€€€€€€€€€15-•å‰½…É‘Ñ¥Ù•Q•áÑI•ÍÁ½¹‘•È€ü€Ä€è€À¤ì(€€€€€€€€€€€€€€€€¼¼Q¡¥Ì¥Ì„™½ÕÌ¡…¹”¥¹Í¥‘”Ñ¡”ÕÉÉ•¹Ğ•¹Ñ•É•Í•ÍÍ¥½¸°(€€€€€€€€€€€€€€€€¼¼¹½ĞÑ¡”•¹½˜Ñ¡…ĞÍ•ÍÍ¥½¸¸-••ÀÉ½ÕÑ”½•¹•É…Ñ¥½¸¥¹Ñ…ĞÍ¼(€€€€€€€€€€€€€€€€¼¼Ñ¡”¹•áĞ‘•±¥‰•É…Ñ”¥¹ÁÕĞÑ…À…¸É•ÕÍ”Ñ¡”¹…Ñ¥Ù”­•å‰½…É(€€€€€€€€€€€€€€€€¼¼M•¹”Á…¥É¥¹œ¸(€€€€€€€€€€€€€€€15¹‘ÁÁ±¥…Ñ¥½¹-•å‰½…É‘M•ÍÍ¥½¸ ¤ì(€€€€€€€€€€€€€€€Õ¥¹ĞØÑ}Ğ‘¥Íµ¥ÍÍM•ÍÍ¥½¹•¹•É…Ñ¥½¸€ô(€€€€€€€€€€€€€€€€€€€15-•å‰½…É‘M•ÍÍ¥½¹•¹•É…Ñ¥½¸ì(€€€€€€€€€€€€€€€™½È€¡9M9Õµ‰•È€©‘•±…åY…±Õ”¥¸m À¸ÀØ° À¸Äát¤ì(€€€€€€€€€€€€€€€€€€€9MQ¥µ•%¹Ñ•ÉÙ…°‘•±…ä€ô‘•±…åY…±Õ”¹‘½Õ‰±•Y…±Õ”ì(€€€€€€€€€€€€€€€€€€€‘¥ÍÁ…Ñ¡}…™Ñ•È (€€€€€€€€€€€€€€€€€€€€€€€‘¥ÍÁ…Ñ¡}Ñ¥µ”¡%MAQ!}Q%5}9=\°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€¡¥¹ĞØÑ}Ğ¤¡‘•±…ä€¨9M}AI}M¤¤°(€€€€€€€€€€€€€€€€€€€€€€€‘¥ÍÁ…Ñ¡}•Ñ}µ…¥¹}ÅÕ•Õ” ¤°yì(€€€€€€€€€€€€€€€€€€€€€€€¥˜€¡15-•å‰½…É‘I½ÕÑ•Ñ¥Ù”€˜˜(€€€€€€€€€€€€€€€€€€€€€€€€€€€‘¥Íµ¥ÍÍM•ÍÍ¥½¹•¹•É…Ñ¥½¸€ôô(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€15-•å‰½…É‘M•ÍÍ¥½¹•¹•É…Ñ¥½¸¤ì(€€€€€€€€€€€€€€€€€€€€€€€€€€€15¹‘ÁÁ±¥…Ñ¥½¹-•å‰½…É‘M•ÍÍ¥½¸ ¤ì(€€€€€€€€€€€€€€€€€€€€€€€ô(€€€€€€€€€€€€€€€€€€€ô¤ì(€€€€€€€€€€€€€€€ô(€€€€€€€€€€€ô(€€€€€€€ô¤ì(€€€€€€€15I•±½…‘-•å‰½…É‘I½ÕÑ” ¤ì(€€€€€€€15I•±½…‘-•å‰½…É‘…É‘•½µ•ÑÉä ¤ì(€€€€€€€15%¹ÍÑ…±±I•µ½Ñ•-•å‰½…É‘•½µ•ÑÉå%™Ù…¥±…‰±” ¤ì(€€€€€€€¥˜€¡15-•å‰½…É‘I½ÕÑ•Ñ¥Ù”¤ì(€€€€€€€€€€€15AÕ‰±¥Í¡¥…¹½ÍÑ¥Ù•¹Ğ (€€€€€€€€€€€€€€€15-•å‰½…É‘¥…¹½ÍÑ¥I½±” ¤°(€€€€€€€€€€€€€€€15¥…¹½ÍÑ¥Ù•¹ÑAÉ½•ÍÍI•…‘ä°(€€€€€€€€€€€€€€€15-•å‰½…É‘M•ÍÍ¥½¹•¹•É…Ñ¥½¸°(€€€€€€€€€€€€€€€€¡Õ¥¹ĞÄÙ}Ğ¤¡•ÑÁ¥ ¤€˜€Áá¤°(€€€€€€€€€€€€€€€15I•µ½Ñ•-•å‰½…É‘•½µ•ÑÉå%¹ÍÑ…±±•€ü€Ä€è€À¤ì(€€€€€€€ô(€€€€€€€9M9½Ñ¥™¥…Ñ¥½¹•¹Ñ•È€©•¹Ñ•È€ôm9M9½Ñ¥™¥…Ñ¥½¹•¹Ñ•È‘•™…Õ±Ñ•¹Ñ•Étì(€€€€€€€15-•å‰½…É‘]¥±±!¥‘•=‰Í•ÉÙ•È€ô(€€€€€€€€€€€m•¹Ñ•È…‘‘=‰Í•ÉÙ•É½É9…µ”éU%-•å‰½…É‘]¥±±!¥‘•9½Ñ¥™¥…Ñ¥½¸(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€½‰©•Ğé¹¥°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€ÅÕ•Õ”ém9M=Á•É…Ñ¥½¹EÕ•Õ”µ…¥¹EÕ•Õ•t(€€€€€€€€€€€€€€€€€€€€€€€€€€€ÕÍ¥¹	±½¬éx¡}}Õ¹ÕÍ•9M9½Ñ¥™¥…Ñ¥½¸€©¹½Ñ¥™¥…Ñ¥½¸¤ì(€€€€€€€€€€€€¼¼Q¡”­•å‰½…ÉÌ½İ¸½±±…ÁÍ”½¹ÑÉ½°‰•¥¹Ì„U%-¥Ğ¡¥‘”(€€€€€€€€€€€€¼¼ÑÉ…¹Í…Ñ¥½¸°‰ÕĞ…ÁÁÌÍÕ …Ì]•¡…Ğ…¸É•Ñ…¥¸Ñ¡”É•µ½Ñ”Ñ•áĞ(€€€€€€€€€€€€¼¼É•ÍÁ½¹‘•È…¹¥µµ•‘¥…Ñ•±ä­••À¥Ğ…±¥Ù”¸¹Ñ¡”½¹É•Ñ”(€€€€€€€€€€€€¼¼É•ÍÁ½¹‘•Èİ¥Ñ¡½ÕĞ•¹‘¥¹œÑ¡”•¹Ñ•É•µ…ÉÉ½ÕÑ”¸(€€€€€€€€€€€¥˜€¡15-•å‰½…É‘Q…É•ÑÁÁ±¥…Ñ¥½¸¤ì(€€€€€€€€€€€€€€€15AÕ‰±¥Í¡¥…¹½ÍÑ¥Ù•¹Ğ (€€€€€€€€€€€€€€€€€€€15¥…¹½ÍÑ¥I½±•ÁÁ±¥…Ñ¥½¸°(€€€€€€€€€€€€€€€€€€€15¥…¹½ÍÑ¥Ù•¹Ñ]¥±±!¥‘”°(€€€€€€€€€€€€€€€€€€€15-•å‰½…É‘M•ÍÍ¥½¹•¹•É…Ñ¥½¸°(€€€€€€€€€€€€€€€€€€€15-•å‰½…É‘Ñ¥Ù•Q•áÑI•ÍÁ½¹‘•È€ü€Ä€è€À°(€€€€€€€€€€€€€€€€€€€15¹‘¥¹ÁÁ±¥…Ñ¥½¹-•å‰½…É‘M•ÍÍ¥½¸€ü€Ä€è€À¤ì(€€€€€€€€€€€€€€€15¹‘ÁÁ±¥…Ñ¥½¹-•å‰½…É‘M•ÍÍ¥½¸ ¤ì(€€€€€€€€€€€ô(€€€€€€€õtì(€€€€€€€15-•å‰½…É‘!¥‘•=‰Í•ÉÙ•È€ô(€€€€€€€€€€€m•¹Ñ•È…‘‘=‰Í•ÉÙ•É½É9…µ”éU%-•å‰½…É‘¥‘!¥‘•9½Ñ¥™¥…Ñ¥½¸(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€½‰©•Ğé¹¥°(€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€ÅÕ•Õ”ém9M=Á•É…Ñ¥½¹EÕ•Õ”µ…¥¹EÕ•Õ•t(€€€€€€€€€€€€€€€€€€€€€€€€€€€€ÕÍ¥¹	±½¬éx¡}}Õ¹ÕÍ•9M9½Ñ¥™¥…Ñ¥½¸€©¹½Ñ¥™¥…Ñ¥½¸¤ì(€€€€€€€€€€€15áÑ•É¹…±-•å‰½…É‘Ù½¥‘…¹••¹•É…Ñ¥½¸€ô€Àì(€€€€€€€€€€€15áÑ•É¹…±-•å‰½…É‘Ù½¥‘…¹•!•¥¡Ğ€ô€À¸Àì(€€€€€€€€€€€15AÕ‰±¥Í¡-•å‰½…É‘É…µ”¡I•Ñi•É¼°9<¤ì(€€€€€€€€€€€¥˜€¡15-•å‰½…É‘Q…É•ÑÁÁ±¥…Ñ¥½¸¤ì(€€€€€€€€€€€€€€€15AÕ‰±¥Í¡¥…¹½ÍÑ¥Ù•¹Ğ (€€€€€€€€€€€€€€€€€€€15¥…¹½ÍÑ¥I½±•ÁÁ±¥…Ñ¥½¸°(€€€€€€€€€€€€€€€€€€€15¥…¹½ÍÑ¥Ù•¹Ñ¥‘!¥‘”°(€€€€€€€€€€€€€€€€€€€15-•å‰½…É‘M•ÍÍ¥½¹•¹•É…Ñ¥½¸°(€€€€€€€€€€€€€€€€€€€15-•å‰½…É‘Ñ¥Ù•Q•áÑI•ÍÁ½¹‘•È€ü€Ä€è€À°(€€€€€€€€€€€€€€€€€€€€À¤ì(€€€€€€€€€€€€€€€¹½Ñ¥™å}Á½ÍĞ¡1e5}-e	=I}%M5%MM}-}9=Q%%Q%=8¤ì(€€€€€€€€€€€ô(€€€€€€€õtì(€€€ô)ô(