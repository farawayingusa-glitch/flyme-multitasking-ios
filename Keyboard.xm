#import <UIKit/UIKit.h>
#import <math.h>
#import <notify.h>

#define FLYME_KEYBOARD_NOTIFICATION "com.codex.flymemultitasking.keyboard-state-changed"
#define FLYME_KEYBOARD_SCENE_NOTIFICATION "com.codex.flymemultitasking.keyboard-scene-changed"
#define FLYME_KEYBOARD_SESSION_NOTIFICATION "com.codex.flymemultitasking.keyboard-session-changed"
#define FLYME_KEYBOARD_FRAME_NOTIFICATION "com.codex.flymemultitasking.keyboard-frame-changed"
#define FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION "com.codex.flymemultitasking.keyboard-avoidance-changed"
#define FLYME_KEYBOARD_DISMISS_NOTIFICATION "com.codex.flymemultitasking.keyboard-dismiss-requested"
#define FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION "com.codex.flymemultitasking.keyboard-dismiss-acknowledged"

static BOOL FLMKeyboardRouteActive = NO;
static int FLMKeyboardRouteToken = -1;
static int FLMKeyboardSceneToken = -1;
static int FLMKeyboardSessionToken = -1;
static int FLMKeyboardFrameToken = -1;
static int FLMKeyboardAvoidanceToken = -1;
static int FLMKeyboardDismissToken = -1;
static uint64_t FLMKeyboardTargetSceneHash = 0;
static uint64_t FLMKeyboardSessionGeneration = 0;
static uint64_t FLMKeyboardEndedSessionGeneration = 0;
static uint64_t FLMExternalKeyboardAvoidanceGeneration = 0;
static CGFloat FLMExternalKeyboardAvoidanceHeight = 0.0;
static __weak UIResponder *FLMKeyboardActiveTextResponder = nil;
static id FLMKeyboardFrameObserver = nil;
static id FLMKeyboardWillHideObserver = nil;
static id FLMKeyboardHideObserver = nil;
static BOOL FLMEndingApplicationKeyboardSession = NO;
static BOOL FLMRemoteKeyboardGeometryInstalled = NO;

static void FLMRefreshApplicationKeyboardLayout(void);
static void FLMInstallRemoteKeyboardGeometryIfAvailable(void);
static void FLMReloadKeyboardAvoidance(void);

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
    uint64_t sessionGeneration = 0;
    if (FLMKeyboardSessionToken >= 0) {
        notify_get_state(FLMKeyboardSessionToken, &sessionGeneration);
    }
    uint64_t previousSessionGeneration = FLMKeyboardSessionGeneration;
    BOOL sessionChanged =
        sessionGeneration != previousSessionGeneration;
    FLMKeyboardSessionGeneration = sessionGeneration;
    FLMKeyboardRouteActive = sessionGeneration != 0 && targetHash != 0 &&
                             currentHash != 0 && targetHash == currentHash;
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
        if (previousSessionGeneration != 0 && previousRouteActive) {
            FLMKeyboardEndedSessionGeneration = previousSessionGeneration;
            FLMEndApplicationKeyboardSession();
        }
        if (sessionGeneration != 0) {
            FLMKeyboardEndedSessionGeneration = 0;
        }
    }
    if (!FLMKeyboardRouteActive) {
        FLMExternalKeyboardAvoidanceGeneration = 0;
        FLMExternalKeyboardAvoidanceHeight = 0.0;
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
    CGFloat height = (CGFloat)(state & 0xFFFFFFULL) / 100.0;
    BOOL currentSession = FLMKeyboardRouteActive && visible &&
                          sessionGeneration != 0 &&
                          sessionGeneration == FLMKeyboardSessionGeneration;
    if (!currentSession) {
        // FlymeKeyboard is injected into UIKit clients, including SpringBoard.
        // Never touch UIScreen/UIApplication from a dyld initializer or an
        // inactive route: iOS 16 asserts when +[UIScreen mainScreen] is used
        // before SpringBoard has finished creating its display environment.
        FLMExternalKeyboardAvoidanceGeneration = 0;
        FLMExternalKeyboardAvoidanceHeight = 0.0;
        FLMRefreshApplicationKeyboardLayout();
        return;
    }
    FLMExternalKeyboardAvoidanceGeneration = sessionGeneration;
    // SpringBoard already normalized and clamped this physical keyboard
    // height before publishing it. Avoid another UIScreen query here so this
    // Darwin-notification path stays safe during process initialization.
    FLMExternalKeyboardAvoidanceHeight = MAX(0.0, height);
    FLMRefreshApplicationKeyboardLayout();
}

%hook UIResponder

- (BOOL)becomeFirstResponder {
    BOOL routedTextInput =
        FLMKeyboardRouteActive && [self conformsToProtocol:@protocol(UITextInput)];
    if (routedTextInput) {
        FLMInstallRemoteKeyboardGeometryIfAvailable();
    }
    BOOL result = %orig;
    if (routedTextInput && result) {
        // Keep the concrete responder, not just its containing windows. Several
        // applications restore a text responder while their Scene is brought
        // forward again; window-wide endEditing alone does not reliably clear
        // that retained responder between centered-card generations.
        FLMKeyboardActiveTextResponder = self;
    }
    return result;
}

- (BOOL)resignFirstResponder {
    BOOL result = %orig;
    if (result && FLMKeyboardActiveTextResponder == self) {
        FLMKeyboardActiveTextResponder = nil;
    }
    return result;
}

%end

static void FLMPublishKeyboardFrame(CGRect frame, BOOL visible) {
    if (visible && !FLMKeyboardRouteActive) {
        return;
    }
    uint64_t sessionGeneration = FLMKeyboardRouteActive
                                     ? FLMKeyboardSessionGeneration
                                     : FLMKeyboardEndedSessionGeneration;
    if (sessionGeneration == 0) {
        return;
    }
    if (FLMKeyboardFrameToken < 0 &&
        notify_register_check(FLYME_KEYBOARD_FRAME_NOTIFIMüÛÛh‘éì¶»§q«^u}±¥¹”ˆ€ˆ‘­•å‰½…É‘}Í½ÕÉ”ˆìÑ¡•¸(€€€€€€€•¡¼€‰Í…™”­•å‰½…É‰É¥‘”¡…¹•è€‘­•å‰½…É‘}±¥¹”ˆ€ø˜È(€€€€€€€•á¥Ð€Ä(€€€™¤)‘½¹”()™½È½Ù•É±…å}±¥¹”¥¸p(€€€€½¹ÍÐ±½…ÐÝ¥‘Ñ¡½µÁ±•Ñ¥½¸€ô€À¸àÈìœp(€€€€½¹ÍÐ±½…ÐÙ•ÉÑ¥…±I•Ù•…±MÑ…ÉÐ€ô€À¸ÈÈìœp(€€€€‰…­É½Õ¹¹…±Á¡„€ôÙ•ÉÑ¥…±AÉ½É•ÍÌ€ø€À¸ÀÀÀÄ€ü€Ä¸À€è€À¸Àìœp(€€€€mU%Y¥•ÜÁ•É™½Éµ]¥Ñ¡½ÕÑ¹¥µ…Ñ¥½¸éyìœì‘¼(€€€¥˜€„É•À€µÄ€ˆ‘½Ù•É±…å}±¥¹”ˆ€ˆ‘Í½ÕÉ•}™¥±”ˆìÑ¡•¸(€€€€€€€•¡¼€‰­•å‰½…É½Ù•É±…ä½È½¹Ñ¥¹Õ½ÕÌ™Õ±±ÍÉ••¸µ½ÉÁ ¡…¹•è€‘½Ù•É±…å}±¥¹”ˆ€ø˜È(€€€€€€€•á¥Ð€Ä(€€€™¤)‘½¹”()™½È­•å‰½…É‘}¡…¹‘½™™}±¥¹”¥¸p(€€€€15-•å‰½…É‘Ñ¥Ù•Q•áÑI•ÍÁ½¹‘•Èœp(€€€€É•Í½±Ù•‘M•¹”€„ôÍ•±˜¹™±½…Ñ¥¹M•¹”œp(€€€€¹••‘Í%¹¥Ñ¥…±M•¹•M•ÑÑ±”œp(€€€€œÀ¸ÔÀ€¨9M}AI}Mœp(€€€€1e5}-e	=I}%M5%MM}9=Q%%Q%=8œp(€€€€½¹ÍÕµ•=ÕÑÍ¥‘•Q…Á½É-•å‰½…É‘¥Íµ¥ÍÍ…°œp(€€€€½¹¹•Ñ•‘M•¹•Ì¹½Õ¹Ð€ðô€Äœp(€€€€15I•Í¥¹¥ÉÍÑI•ÍÁ½¹‘•É%¹Y¥•Üœp(€€€€1e5}-e	=I}%M5%MM}-}9=Q%%Q%=8œp(€€€€15-•å‰½…É‘¹‘•‘M•ÍÍ¥½¹•¹•É…Ñ¥½¸œp(€€€€Í•¹‘Ñ¥½¸éÍ•±•Ñ½È¡É•Í¥¹¥ÉÍÑI•ÍÁ½¹‘•È¤œp(€€€€¥¹Ñ•É™…”15-•å‰½…É‘½ÉÝ…É‘¥¹]¥¹‘½Ü€èU%]¥¹‘½Üœp(€€€€Ý¥¹‘½Ü¹Ý¥¹‘½Ý1•Ù•°€ôÍ•±˜¹™±½…Ñ¥¹]¥¹‘½Ü¹Ý¥¹‘½Ý1•Ù•°€¬€Ä¸Àìœp(€€€€­•å‰½…É‘%¹Ñ•É…Ñ¥½¹É…µ”œp(€€€€15AÕ‰±¥Í¡-•å‰½…É‘Ù½¥‘…¹”œp(€€€€É•ÑÕÉ¸15áÑ•É¹…±-•å‰½…É‘Ù½¥‘…¹•!•¥¡Ðìœp(€€€€¥˜€ …ÕÉÉ•¹ÑM•ÍÍ¥½¸¤œp(€€€€9•Ù•ÈÑ½Õ U%MÉ••¸½U%ÁÁ±¥…Ñ¥½¸™É½´„‘å±¥¹¥Ñ¥…±¥é•Èœp(€€€€¥¹¥Ñ]¥Ñ¡]¥¹‘½ÝM•¹”éÑ…É•Ñ]¥¹‘½ÝM•¹”œp(€€€€Í•ÑÕÑ½É½Ñ…Ñ•Ìé™½É•UÁ‘…Ñ•%¹Ñ•É™…•=É¥•¹Ñ…Ñ¥½¸èœp(€€€€¡¥ÑY¥•Ü€ôôÍ•±˜ñð¡¥ÑY¥•Ü€ôôÉ½½ÑY¥•Üœp(€€€€œ•¡½½¬}U%-•å‰½…É‘1…å•É!½ÍÑY¥•Üœp(€€€€‘¥‘UÁ‘…Ñ•±¥•¹ÑM•ÑÑ¥¹Í]¥Ñ¡¥™˜èœp(€€€€m™½ÉÝ…É‘¥¹I½½Ð…‘‘MÕ‰Ù¥•Üé¡½ÍÑY¥•Ýtìœp(€€€€mÍ•±˜‘¥Í…É‘±½…Ñ¥¹-•å‰½…É‘1…å•É!½ÍÑtìœp(€€€€•¹‘±½…Ñ¥¹-•å‰½…É‘M•ÍÍ¥½¸œp(€€€€™±½…Ñ¥¹1…Õ¹¡½Ù•ÉY¥•Üœp(€€€€É•Ù•…±±½…Ñ¥¹½¹Ñ•¹Ñ½É•¹•É…Ñ¥½¸œì‘¼(€€€¥˜€„É•À€µÄ€´´€ˆ‘­•å‰½…É‘}¡…¹‘½™™}±¥¹”ˆ€ˆ‘Í½ÕÉ•}™¥±”ˆ€˜˜(€€€€€€€„É•À€µÄ€´´€ˆ‘­•å‰½…É‘}¡…¹‘½™™}±¥¹”ˆ€ˆ‘­•å‰½…É‘}Í½ÕÉ”ˆìÑ¡•¸(€€€€€€€•¡¼€‰­•å‰½…É¡…¹‘½™˜½È±…Õ¹ É•Ù•…°¡…¹•è€‘­•å‰½…É‘}¡…¹‘½™™}±¥¹”ˆ€ø˜È(€€€€€€€•á¥Ð€Ä(€€€™¤)‘½¹”()¥˜É•À€µAé½Ä€15I•±½…‘-•å‰½…É‘I½ÕÑ•p¡p¤íqÌ©15I•±½…‘-•å‰½…É‘Ù½¥‘…¹•p¡p¤ìœ€ˆ‘­•å‰½…É‘}Í½ÕÉ”ˆìÑ¡•¸(€€€•¡¼€‰­•å‰½…É…Ù½¥‘…¹”É•¥¹ÑÉ½‘Õ•¥¹Ñ¼„É½ÕÑ”½È‘å±¥¹¥Ñ¥…±¥é•ÈÁ…Ñ ˆ€ø˜È(€€€•á¥Ð€Ä)™¤()™½ÈÉ•µ½Ù•‘}­•å‰½…É‘}Á…Ñ ¥¸p(€€€€15I•µ½Ñ•-•å‰½…É‘Ù½¥‘…¹”œp(€€€€15ÁÁ±å½ÉÉ•Ñ•‘-•å‰½…É‘=±ÕÍ¥½¸œp(€€€€Á½ÍÑ9½Ñ¥™¥…Ñ¥½¹9…µ”éU%-•å‰½…É‘]¥±±¡…¹•É…µ•9½Ñ¥™¥…Ñ¥½¸œp(€€€€¥¹Ñ•É™…”15-•å‰½…É‘=Ù•É±…å]¥¹‘½Üœp(€€€€¥¹Ñ•É™…”15-•å‰½…É‘!½ÍÑ	É¥‘•Y¥•Üœp(€€€€15AÕ‰±¥Í¡-•å‰½…É‘=±ÕÍ¥½¸œì‘¼(€€€¥˜É•À€µÄ€ˆ‘É•µ½Ù•‘}­•å‰½…É‘}Á…Ñ ˆ€ˆ‘­•å‰½…É‘}Í½ÕÉ”ˆñð(€€€€€€É•À€µÄ€ˆ‘É•µ½Ù•‘}­•å‰½…É‘}Á…Ñ ˆ€ˆ‘Í½ÕÉ•}™¥±”ˆìÑ¡•¸(€€€€€€€•¡¼€‰É•µ½Ù•­•å‰½…ÉÁ…Ñ …É¡¥Ñ•ÑÕÉ”Ý…ÌÉ•¥¹ÑÉ½‘Õ•è€‘É•µ½Ù•‘}­•å‰½…É‘}Á…Ñ ˆ€ø˜È(€€€€€€€•á¥Ð€Ä(€€€™¤)‘½¹”()¥˜É•À€µÄ€Í•Ñ±½…Ñ¥¹M•¹•UÍ•ÍÕ±±ÍÉ••¹-•å‰½…É‘!½ÍÐœ€ˆ‘Í½ÕÉ•}™¥±”ˆìÑ¡•¸(€€€•¡¼€‰Ý¡½±”…ÁÁ±¥…Ñ¥½¸M•¹”­•å‰½…É•áÁ…¹Í¥½¸Ý…ÌÉ•¥¹ÑÉ½‘Õ•ˆ€ø˜È(€€€•á¥Ð€Ä)™¤()™½ÈÕ¹Í…™•}­•å‰½…É‘}±¥¹”¥¸p(€€€€œ´€¡Ù½¥¥‘¥‘5½Ù•Q½]¥¹‘½Üœp(€€€€15-•å‰½…É‘AÉ•Á…É•A½ÍÑ•œp(€€€€™±½…Ñ¥¹I•ÕÍ…‰±•-•å‰½…É‘1…å•É!½ÍÑY¥•Üœp(€€€€Í¡•‘Õ±•±½…Ñ¥¹-•å‰½…É‘1…å•É!½ÍÑ•Ñ… œp(€€€€15-•å‰½…É‘¥…¹½ÍÑ¥1½œœì‘¼(€€€¥˜É•À€µÄ€´´€ˆ‘Õ¹Í…™•}­•å‰½…É‘}±¥¹”ˆ€ˆ‘Í½ÕÉ•}™¥±”ˆñð(€€€€€€É•À€µÄ€´´€ˆ‘Õ¹Í…™•}­•å‰½…É‘}±¥¹”ˆ€ˆ‘­•å‰½…É‘}Í½ÕÉ”ˆìÑ¡•¸(€€€€€€€•¡¼€‰Õ¹Í…™”½È½¹”µÍ¡½Ð­•å‰½…ÉÁ…Ñ ‘•Ñ•Ñ•è€‘Õ¹Í…™•}­•å‰½…É‘}±¥¹”ˆ€ø˜È(€€€€€€€•á¥Ð€Ä(€€€™¤)‘½¹”()¥˜É•À€µÄ€œ•¡½½¬U%]¥¹‘½ÝM•¹”œ€ˆ‘­•å‰½…É‘}Í½ÕÉ”ˆìÑ¡•¸(€€€•¡¼€‰…ÁÁ±¥…Ñ¥½¸M•¹”É•™•É•¹”‰½Õ¹‘Ì…É”‰•¥¹œ½Ù•ÉÉ¥‘‘•¸……¥¸ˆ€ø˜È(€€€•á¥Ð€Ä)™¤()¥˜É•À€µÄ€x•¡½½¬U%]¥¹‘½ÝmléÍÁ…”éut¨œ€ˆ‘­•å‰½…É‘}Í½ÕÉ”ˆìÑ¡•¸(€€€•¡¼€‰­•å‰½…É‰É¥‘”É•Ü‰•å½¹Ñ¡”Ù•É¥™¥•µ¥¹¥µ…°¡½½¬ÍÕÉ™…”ˆ€ø˜È(€€€•á¥Ð€Ä)™¤()Õ…É‘}±¥¹”ôˆ¡É•À€µ¹€‰…‘‘•ÍÑÕÉ•I•½¹¥é•ÈéÍ•±˜¹½É¹•ÉÕ…É‘•ÍÑÕÉ”ˆ€ˆ‘Í½ÕÉ•}™¥±”ˆð(€€€¡•…€µ¸ÄðÕÐ€µè€µ˜Ä¤ˆ)Ý¡••±}±¥¹”ôˆ¡É•À€µ¹€‰…‘‘•ÍÑÕÉ•I•½¹¥é•ÈéÍ•±˜¹½É¹•É•ÍÑÕÉ”Ñ½¥ÍÁ±…å]¥Ñ¡%‘•¹Ñ¥Ñäé¥‘•¹Ñ¥Ñäˆ€ˆ‘Í½ÕÉ•}™¥±”ˆð(€€€¡•…€µ¸ÄðÕÐ€µè€µ˜Ä¤ˆ)¥˜ml€µè€ˆ‘Õ…É‘}±¥¹”ˆñð€µè€ˆ‘Ý¡••±}±¥¹”ˆñð€ˆ‘Õ…É‘}±¥¹”ˆ€µ”€ˆ‘Ý¡••±}±¥¹”ˆutìÑ¡•¸(€€€•¡¼€‰™É½é•¸€À¸Ì¸Ð™¥ÉÍÐµ™É…µ”Õ…ÉÉ•¥ÍÑÉ…Ñ¥½¸½É‘•È¡…¹•ˆ€ø˜È(€€€•á¥Ð€Ä)™¤()•¡¼€‰™É½é•¸€À¸Ì¸Ð•ÍÑÕÉ”…¹Ý¡••°™½Õ¹‘…Ñ¥½¸Ù•É¥™¥•ˆ