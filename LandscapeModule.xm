#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/message.h>

#import "FLMDiagnostics.h"
#import "FLMLandscapeKeyboardBridge.h"
#import "FLMSceneLifecycle.h"
#import "FLMLandscapeModule.h"

static const CGFloat FLMLandscapeDefaultTriggerSize = 58.0;
static const CGFloat FLMLandscapeMinimumTriggerSize = 36.0;
static const CGFloat FLMLandscapeMaximumTriggerSize = 96.0;
// The hosted application keeps the same complete portrait contract as the
// frozen portrait engine.  Landscape belongs to SpringBoard's outer workspace
// and to the native keyboard, never to the application's UIKit layout.
static const CGFloat FLMLandscapePortraitContentWidth = 390.0;
static const CGFloat FLMLandscapePortraitContentHeight = 844.0;
// Keep the visual card at the iPhone 13 Pro portrait aspect ratio.
static const CGFloat FLMLandscapePortraitCardWidthToHeightRatio =
    390.0 / 844.0;
static const CGFloat FLMLandscapeCardMaximumHeightRatio = 0.92;
static const CGFloat FLMLandscapeHandleWidth = 44.0;
static const CGFloat FLMLandscapeHandleBarWidth = 5.0;
// Portrait's hidden handle is 44 x 5 pt. Keep the same physical affordance
// after rotating the display; only its axis changes in landscape.
static const CGFloat FLMLandscapeHandleBarLength = 44.0;
static const CGFloat FLMLandscapeHandleGap = 10.0;
// Tweak.xm reserves Alert+120 for the wheel hotspot. The landscape ownership
// surface must sit above that arbitration window, while the native keyboard
// bridge is placed one level above this surface.
static const CGFloat FLMLandscapeExclusiveWindowLevelOffset = 121.0;
static const CGFloat FLMLandscapeSwipeThreshold = 32.0;
static const CGFloat FLMLandscapeTapMovementThreshold = 8.0;
static const CGFloat FLMLandscapeFastSwipeVelocity = 320.0;
static const CGFloat FLMLandscapeDockTopMargin = 15.0;
// Mirror the frozen portrait engine's 315pt centered -> 156pt docked width,
// while retaining its 96pt minimum usable dock presentation width.
static const CGFloat FLMLandscapeDockWidthRatio = 156.0 / 315.0;
static const CGFloat FLMLandscapeMinimumDockWidth = 96.0;
static const NSTimeInterval FLMLandscapeResolveInterval = 0.05;
static const NSTimeInterval FLMLandscapeResolveGraceDelay = 0.03;
static const NSTimeInterval FLMLandscapeSceneSettleDelay = 0.04;
static const NSTimeInterval FLMLandscapeHostRevealDelay = 0.05;
static const NSTimeInterval FLMLandscapeResolveTimeout = 6.5;
static const NSTimeInterval FLMLandscapeCloseAnimationDuration = 0.30;
static const NSTimeInterval FLMLandscapeOpenAnimationDuration = 0.40;
static const CGFloat FLMLandscapeSpringDamping = 0.84;
static const CGFloat FLMLandscapeSpringVelocity = 0.30;

typedef NS_ENUM(NSInteger, FLMLandscapeInteractionDomain) {
    FLMLandscapeInteractionDomainNone = 0,
    FLMLandscapeInteractionDomainBackdrop,
    FLMLandscapeInteractionDomainHandle,
    FLMLandscapeInteractionDomainDockCard,
};

@interface NSObject (FLMLandscapeRuntimePrivate)
- (id)settings;
- (id)mutableSettings;
- (CGRect)frame;
- (NSInteger)interfaceOrientation;
- (NSString *)identifier;
- (NSString *)sceneIdentifier;
- (id)uiPresentationManager;
- (id)presentationManager;
- (id)createPresenterWithIdentifier:(NSString *)identifier;
- (UIView *)presentationView;
- (void)activate;
- (void)deactivate;
- (void)invalidate;
- (void)setForeground:(BOOL)foreground;
- (void)setBackgrounded:(BOOL)backgrounded;
- (BOOL)foreground;
- (BOOL)backgrounded;
- (BOOL)isForeground;
- (BOOL)isBackgrounded;
- (BOOL)isActive;
- (NSInteger)activationState;
- (id)frontmostApplication;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleIdentifier;
- (void)setDeactivationReasons:(unsigned long long)reasons;
- (void)setFrame:(CGRect)frame;
- (void)setInterfaceOrientation:(NSInteger)orientation;
- (void)updateSettings:(id)settings withTransitionContext:(id)context;
- (void)_setContentState:(NSInteger)state;
@end

@interface FLMLandscapeApplicationController : NSObject
+ (instancetype)sharedInstance;
- (id)applicationWithBundleIdentifier:(NSString *)identifier;
@end

@interface FLMLandscapeApplicationSceneHandle : NSObject
- (NSInteger)currentInterfaceOrientation;
- (id)sceneIfExists;
- (id)scene;
@end

@interface FLMLandscapeSceneEntity : NSObject
- (instancetype)initWithApplicationForMainDisplay:(id)application
              generatingNewPrimarySceneIfRequired:(BOOL)required;
- (FLMLandscapeApplicationSceneHandle *)sceneHandle;
@end

@interface UIApplication (FLMLandscapeRuntimePrivate)
- (BOOL)launchApplicationWithIdentifier:(NSString *)identifier suspended:(BOOL)suspended;
- (id)_accessibilityFrontMostApplication;
@end

@interface FLMLandscapeRootView : UIView
@property(nonatomic, weak) UIView *cardView;
@property(nonatomic, weak) UIView *handleView;
@property(nonatomic, weak) UIView *hostView;
@property(nonatomic, assign) BOOL passesTouchesOutsideControls;
@end

@interface FLMLandscapeWindow : UIWindow
@end

@interface FLMLandscapeRootViewController : UIViewController
@end

@interface FLMLandscapeModule : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, strong) FLMLandscapeWindow *window;
@property(nonatomic, strong) FLMLandscapeRootView *rootView;
@property(nonatomic, strong) UIView *exclusiveBackdropView;
@property(nonatomic, strong) UIView *cardView;
// The application presentation host stays a native full-screen landscape
// surface. This wrapper is the only layer allowed to carry the card's visual
// transform; UIKit and the system keyboard never receive the card transform.
@property(nonatomic, strong) UIView *hostPresentationView;
@property(nonatomic, strong) UIView *hostView;
@property(nonatomic, strong) UIView *handleView;
@property(nonatomic, strong) UIView *handleBar;
@property(nonatomic, strong) UIView *launchCoverView;
@property(nonatomic, strong) UIView *dockInteractionShield;
@property(nonatomic, strong) UITapGestureRecognizer *outsideTap;
@property(nonatomic, strong) UIPanGestureRecognizer *handlePan;
@property(nonatomic, strong) UIPanGestureRecognizer *dockPan;
@property(nonatomic, strong) UITapGestureRecognizer *dockTap;
@property(nonatomic, weak) id sharedGestureController;
@property(nonatomic, strong) UIGestureRecognizer *sharedBackdropGesture;
@property(nonatomic, strong) UIGestureRecognizer *sharedDockGesture;
@property(nonatomic, assign) BOOL sharedBackdropPreviouslyEnabled;
@property(nonatomic, assign) BOOL sharedDockPreviouslyEnabled;
@property(nonatomic, assign) BOOL sharedInteractionActive;
@property(nonatomic, strong) NSTimer *lockTimer;
@property(nonatomic, weak) UIWindow *previousKeyWindow;
@property(nonatomic, strong) id sceneEntity;
@property(nonatomic, strong) id sceneHandle;
@property(nonatomic, strong) id scene;
@property(nonatomic, strong) id presentationManager;
@property(nonatomic, strong) id presenter;
@property(nonatomic, strong) id presenterScene;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, assign) CGRect displayBounds;
@property(nonatomic, assign) UIInterfaceOrientation displayOrientation;
@property(nonatomic, assign) NSUInteger generation;
@property(nonatomic, assign) uint64_t keyboardSessionCounter;
@property(nonatomic, assign) uint64_t keyboardSessionGeneration;
@property(nonatomic, assign) NSUInteger resolveAttempt;
@property(nonatomic, assign) NSUInteger presenterPendingAttempts;
@property(nonatomic, assign) NSTimeInterval openedAt;
@property(nonatomic, assign) NSTimeInterval scenePreparedAt;
@property(nonatomic, assign) CGRect expectedHostBounds;
@property(nonatomic, assign) uint64_t expectedHostGeneration;
@property(nonatomic, copy) NSString *expectedHostSceneIdentifier;
@property(nonatomic, assign) BOOL dockedCard;
@property(nonatomic, assign) BOOL hiddenCard;
@property(nonatomic, assign) BOOL dockedOnRight;
@property(nonatomic, assign) BOOL closing;
@property(nonatomic, assign) BOOL fullscreenPromotionInProgress;
@property(nonatomic, assign) CGRect handlePanStartCardFrame;
@property(nonatomic, assign) CGRect handlePanStartHandleFrame;
@property(nonatomic, assign) BOOL handlePanInteractive;
@property(nonatomic, assign) CGRect dockPanStartCardFrame;
@property(nonatomic, assign) CGRect dockPanStartHandleFrame;
@property(nonatomic, assign) BOOL dockPanInteractive;
@property(nonatomic, assign) FLMLandscapeInteractionDomain interactionDomain;
@property(nonatomic, assign) FLMLandscapeTouchContext interactionTouchContext;
@property(nonatomic, assign) CGPoint interactionStartPoint;
@property(nonatomic, assign) CGRect interactionStartCardFrame;
@property(nonatomic, assign) CGRect interactionStartHandleFrame;
@property(nonatomic, assign) CFTimeInterval interactionStartedAt;
@property(nonatomic, assign) BOOL started;
@property(nonatomic, copy) NSString *queuedIdentifier;
+ (instancetype)sharedModule;
- (void)start;
- (void)updateFrames;
- (void)orientationDidChange;
- (void)openIdentifier:(NSString *)identifier;
- (BOOL)prewarmIdentifier:(NSString *)identifier;
- (void)closeKeepingApplication:(BOOL)keepApplication;
- (void)refreshSceneForeground;
- (BOOL)validateHostGeometry;
- (BOOL)hasVisibleCard;
- (void)activateSharedInteractionGestures;
- (void)refreshSharedInteractionGestureState;
- (void)deactivateSharedInteractionGestures;
- (BOOL)ownsSharedGesture:(UIGestureRecognizer *)gesture
               controller:(id)controller;
- (BOOL)sharedGesture:(UIGestureRecognizer *)gesture
    shouldReceiveTouch:(UITouch *)touch;
- (BOOL)sharedGestureShouldBegin:(UIGestureRecognizer *)gesture;
- (void)handleSharedGesture:(UIGestureRecognizer *)gesture;
- (FLMLandscapeInteractionDomain)interactionDomainForPoint:(CGPoint)point
                                                    gesture:(UIGestureRecognizer *)gesture;
- (CGPoint)visualPointForGesture:(UIGestureRecognizer *)gesture
                         context:(FLMLandscapeTouchContext)context;
- (void)beginInteractionForGesture:(UIGestureRecognizer *)gesture
                             point:(CGPoint)point
                           context:(FLMLandscapeTouchContext)context;
- (void)updateInteractionForPoint:(CGPoint)point;
- (void)finishInteractionForGesture:(UIGestureRecognizer *)gesture
                                point:(CGPoint)point;
- (void)configureLocalInteractionState;
- (void)handleDockPan:(UIPanGestureRecognizer *)gesture;
- (void)handleDockTap:(UITapGestureRecognizer *)gesture;
- (CGRect)expandedCardFrame;
- (CGRect)dockedCardFrameOnRight:(BOOL)onRight;
- (void)dockCardAnimated:(BOOL)animated;
- (void)hideDockedCardAnimated:(BOOL)animated;
- (void)restoreExpandedCardAnimated:(BOOL)animated reason:(NSString *)reason;
- (void)snapDockedCardAnimated:(BOOL)animated;
- (void)beginExpandedKeyboardSessionIfPossible;
- (void)endKeyboardSessionForCollapsedState;
@end

static NSString *FLMLandscapeSceneIdentifier(id scene);
static BOOL FLMLandscapeReadBool(id object, SEL selector, BOOL *available);
static CGRect FLMLandscapePortraitSceneBounds(void);

static UIWindowScene *FLMLandscapeWindowScene(void) {
    if (@available(iOS 13.0, *)) {
        UIWindowScene *fallback = nil;
        for (UIScene *candidate in [UIApplication sharedApplication].connectedScenes) {
            if (![candidate isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            UIWindowScene *scene = (UIWindowScene *)candidate;
            if (scene.activationState == UISceneActivationStateForegroundActive ||
                scene.activationState == UISceneActivationStateForegroundInactive) {
                CGRect coordinateBounds = scene.coordinateSpace.bounds;
                BOOL geometryLandscape =
                    CGRectGetWidth(coordinateBounds) >
                    CGRectGetHeight(coordinateBounds);
                if (UIInterfaceOrientationIsLandscape(scene.interfaceOrientation) ||
                    geometryLandscape) {
                    return scene;
                }
                if (!fallback) {
                    fallback = scene;
                }
            }
        }
        return fallback;
    }
    return nil;
}

static UIWindow *FLMLandscapeCurrentKeyWindow(void) {
    UIWindowScene *scene = FLMLandscapeWindowScene();
    if (@available(iOS 13.0, *)) {
        for (UIWindow *window in scene.windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    return nil;
}

static UIInterfaceOrientation FLMLandscapeInterfaceOrientation(void) {
    UIWindowScene *scene = FLMLandscapeWindowScene();
    BOOL sceneGeometryLandscape = NO;
    if (@available(iOS 13.0, *)) {
        UIInterfaceOrientation orientation = scene.interfaceOrientation;
        if (UIInterfaceOrientationIsLandscape(orientation)) {
            return orientation;
        }
        CGRect coordinateBounds = scene.coordinateSpace.bounds;
        sceneGeometryLandscape =
            CGRectGetWidth(coordinateBounds) > CGRectGetHeight(coordinateBounds);
    }
    UIApplication *application = [UIApplication sharedApplication];
    SEL selector = NSSelectorFromString(@"statusBarOrientation");
    if ([application respondsToSelector:selector]) {
        UIInterfaceOrientation (*getter)(id, SEL) =
            (UIInterfaceOrientation (*)(id, SEL))[application methodForSelector:selector];
        UIInterfaceOrientation orientation = getter ? getter(application, selector)
                                                    : UIInterfaceOrientationUnknown;
        if (UIInterfaceOrientationIsLandscape(orientation)) {
            return orientation;
        }
    }
    UIDeviceOrientation deviceOrientation = [UIDevice currentDevice].orientation;
    if (deviceOrientation == UIDeviceOrientationLandscapeLeft) {
        return UIInterfaceOrientationLandscapeRight;
    }
    if (deviceOrientation == UIDeviceOrientationLandscapeRight) {
        return UIInterfaceOrientationLandscapeLeft;
    }
    if (sceneGeometryLandscape) {
        // SpringBoard can leave UIWindowScene.interfaceOrientation at its
        // portrait value while its scene coordinate space has already rotated.
        // The old integrated wheel trusted that geometry and remained usable
        // during this transition; use a stable landscape mapping here too.
        return UIInterfaceOrientationLandscapeLeft;
    }
    UIScreen *screen = scene.screen ?: [UIScreen mainScreen];
    if (@available(iOS 8.0, *)) {
        CGRect coordinateBounds = screen.coordinateSpace.bounds;
        if (CGRectGetWidth(coordinateBounds) > CGRectGetHeight(coordinateBounds)) {
            return UIInterfaceOrientationLandscapeLeft;
        }
    }
    return UIInterfaceOrientationPortrait;
}

static CGRect FLMLandscapeSceneSettingsFrame(id scene) {
    if (!scene || ![scene respondsToSelector:@selector(settings)]) {
        return CGRectZero;
    }
    @try {
        id settings = [scene settings];
        if (!settings || ![settings respondsToSelector:@selector(frame)]) {
            return CGRectZero;
        }
        CGRect (*getter)(id, SEL) =
            (CGRect (*)(id, SEL))[settings methodForSelector:@selector(frame)];
        return getter ? getter(settings, @selector(frame)) : CGRectZero;
    } @catch (__unused NSException *exception) {
        return CGRectZero;
    }
}

static UIInterfaceOrientation FLMLandscapeSceneSettingsOrientation(id scene) {
    if (!scene || ![scene respondsToSelector:@selector(settings)]) {
        return UIInterfaceOrientationUnknown;
    }
    @try {
        id settings = [scene settings];
        if (!settings ||
            ![settings respondsToSelector:@selector(interfaceOrientation)]) {
            return UIInterfaceOrientationUnknown;
        }
        NSInteger (*getter)(id, SEL) =
            (NSInteger (*)(id, SEL))[settings
                methodForSelector:@selector(interfaceOrientation)];
        return getter ? (UIInterfaceOrientation)getter(
                              settings, @selector(interfaceOrientation))
                       : UIInterfaceOrientationUnknown;
    } @catch (__unused NSException *exception) {
        return UIInterfaceOrientationUnknown;
    }
}

static BOOL FLMLandscapeReadBool(id object,
                                 SEL selector,
                                 BOOL *available) {
    if (available) {
        *available = NO;
    }
    if (!object || ![object respondsToSelector:selector]) {
        return NO;
    }
    BOOL (*getter)(id, SEL) =
        (BOOL (*)(id, SEL))[object methodForSelector:selector];
    if (!getter) {
        return NO;
    }
    if (available) {
        *available = YES;
    }
    return getter(object, selector);
}

static NSInteger FLMLandscapeReadInteger(id object,
                                         SEL selector,
                                         BOOL *available) {
    if (available) {
        *available = NO;
    }
    if (!object || ![object respondsToSelector:selector]) {
        return -1;
    }
    NSInteger (*getter)(id, SEL) =
        (NSInteger (*)(id, SEL))[object methodForSelector:selector];
    if (!getter) {
        return -1;
    }
    if (available) {
        *available = YES;
    }
    return getter(object, selector);
}

static BOOL FLMLandscapeSceneRuntimeIsForeground(id scene,
                                                 BOOL *known,
                                                 NSInteger *activationState) {
    if (known) {
        *known = NO;
    }
    if (activationState) {
        *activationState = -1;
    }
    if (!scene) {
        return NO;
    }

    BOOL activationStateKnown = NO;
    NSInteger state = FLMLandscapeReadInteger(
        scene, @selector(activationState), &activationStateKnown);
    if (activationState) {
        *activationState = state;
    }
    if (activationStateKnown) {
        if (known) {
            *known = YES;
        }
        return state == UISceneActivationStateForegroundActive ||
               state == UISceneActivationStateForegroundInactive;
    }

    BOOL foregroundKnown = NO;
    BOOL foreground = FLMLandscapeReadBool(
        scene, @selector(isForeground), &foregroundKnown);
    if (foregroundKnown) {
        if (known) {
            *known = YES;
        }
        return foreground;
    }

    BOOL activeKnown = NO;
    BOOL active = FLMLandscapeReadBool(scene, @selector(isActive), &activeKnown);
    if (activeKnown) {
        if (known) {
            *known = YES;
        }
        return active;
    }

    // Some iOS 16 SpringBoard scene objects do not expose activation state to
    // SpringBoard. In that case the non-suspended application activation and
    // the protected-scene settings are the only available contract; do not
    // reject a valid scene merely because the private getter is absent.
    return YES;
}

static NSString *FLMLandscapeSceneRuntimeSummary(id scene) {
    BOOL activationStateKnown = NO;
    NSInteger activationState = FLMLandscapeReadInteger(
        scene, @selector(activationState), &activationStateKnown);
    BOOL foregroundKnown = NO;
    BOOL foreground = FLMLandscapeReadBool(
        scene, @selector(isForeground), &foregroundKnown);
    BOOL activeKnown = NO;
    BOOL active = FLMLandscapeReadBool(scene, @selector(isActive), &activeKnown);
    BOOL backgroundedKnown = NO;
    BOOL backgrounded = FLMLandscapeReadBool(
        scene, @selector(isBackgrounded), &backgroundedKnown);
    id settings = [scene respondsToSelector:@selector(settings)]
                      ? [scene settings]
                      : nil;
    BOOL settingsForegroundKnown = NO;
    BOOL settingsForeground = FLMLandscapeReadBool(
        settings, @selector(foreground), &settingsForegroundKnown);
    BOOL settingsBackgroundedKnown = NO;
    BOOL settingsBackgrounded = FLMLandscapeReadBool(
        settings, @selector(backgrounded), &settingsBackgroundedKnown);
    return [NSString stringWithFormat:
                       @"activationState=%ld/%d isForeground=%d/%d isActive=%d/%d isBackgrounded=%d/%d settingsForeground=%d/%d settingsBackgrounded=%d/%d",
                       (long)activationState, activationStateKnown,
                       foreground, foregroundKnown, active, activeKnown,
                       backgrounded, backgroundedKnown, settingsForeground,
                       settingsForegroundKnown, settingsBackgrounded,
                       settingsBackgroundedKnown];
}

static BOOL FLMLandscapeSceneHasPortraitCardSettings(id scene) {
    CGRect frame = FLMLandscapeSceneSettingsFrame(scene);
    UIInterfaceOrientation orientation =
        FLMLandscapeSceneSettingsOrientation(scene);
    CGRect expected = FLMLandscapePortraitSceneBounds();
    return CGRectGetHeight(frame) > CGRectGetWidth(frame) &&
           CGRectGetWidth(frame) > 1.0 && CGRectGetHeight(frame) > 1.0 &&
           fabs(CGRectGetWidth(frame) - CGRectGetWidth(expected)) < 1.0 &&
           fabs(CGRectGetHeight(frame) - CGRectGetHeight(expected)) < 1.0 &&
           orientation == UIInterfaceOrientationPortrait;
}

static BOOL FLMLandscapeTransformIsIdentity(CGAffineTransform transform) {
    return fabs(transform.a - 1.0) < 0.01 &&
           fabs(transform.d - 1.0) < 0.01 && fabs(transform.b) < 0.01 &&
           fabs(transform.c) < 0.01 && fabs(transform.tx) < 0.01 &&
           fabs(transform.ty) < 0.01;
}

static NSString *FLMLandscapeApplicationIdentifier(id application) {
    if (!application) {
        return nil;
    }
    SEL selectors[] = {
        @selector(bundleIdentifier),
        @selector(displayIdentifier),
    };
    for (NSUInteger index = 0;
         index < sizeof(selectors) / sizeof(selectors[0]);
         index++) {
        SEL selector = selectors[index];
        if (![application respondsToSelector:selector]) {
            continue;
        }
        NSString *(*getter)(id, SEL) =
            (NSString *(*)(id, SEL))[application methodForSelector:selector];
        NSString *identifier = getter ? getter(application, selector) : nil;
        if (identifier.length > 0) {
            return identifier;
        }
    }
    return nil;
}

static NSString *FLMLandscapeFrontmostApplicationIdentifier(void) {
    Class workspaceClass = NSClassFromString(@"SBMainWorkspace");
    id workspace = [workspaceClass respondsToSelector:@selector(sharedInstance)]
                       ? [workspaceClass sharedInstance]
                       : nil;
    if ([workspace respondsToSelector:@selector(frontmostApplication)]) {
        NSString *identifier = FLMLandscapeApplicationIdentifier(
            [workspace frontmostApplication]);
        if (identifier.length > 0) {
            return identifier;
        }
    }
    UIApplication *springBoard = [UIApplication sharedApplication];
    if ([springBoard respondsToSelector:
                     @selector(_accessibilityFrontMostApplication)]) {
        return FLMLandscapeApplicationIdentifier(
            [springBoard _accessibilityFrontMostApplication]);
    }
    return nil;
}

BOOL FLMLandscapeModuleIsLandscape(void) {
    if (UIInterfaceOrientationIsLandscape(FLMLandscapeInterfaceOrientation())) {
        return YES;
    }
    UIWindowScene *scene = FLMLandscapeWindowScene();
    if (@available(iOS 13.0, *)) {
        CGRect sceneBounds = scene.coordinateSpace.bounds;
        if (CGRectGetWidth(sceneBounds) > CGRectGetHeight(sceneBounds)) {
            return YES;
        }
    }
    UIScreen *screen = scene.screen ?: [UIScreen mainScreen];
    CGRect screenBounds = screen.bounds;
    if (CGRectGetWidth(screenBounds) > CGRectGetHeight(screenBounds)) {
        return YES;
    }
    if (@available(iOS 8.0, *)) {
        CGRect coordinateBounds = screen.coordinateSpace.bounds;
        if (CGRectGetWidth(coordinateBounds) > CGRectGetHeight(coordinateBounds)) {
            return YES;
        }
    }
    UIDeviceOrientation deviceOrientation = [UIDevice currentDevice].orientation;
    return deviceOrientation == UIDeviceOrientationLandscapeLeft ||
           deviceOrientation == UIDeviceOrientationLandscapeRight;
}

static CGRect FLMLandscapeVisualBoundsForScreen(
    UIScreen *screen,
    UIInterfaceOrientation orientation) {
    // The system gesture manager reports locations in the display's fixed
    // screen frame.  Use the same raw screen bounds as the frozen portrait
    // path and rotate only the visual frame; using coordinateSpace.bounds here
    // can make SpringBoard expose the pre-rotation portrait frame during the
    // first landscape touch stream.
    CGRect bounds = screen.bounds;
    if (CGRectGetWidth(bounds) <= 1.0 || CGRectGetHeight(bounds) <= 1.0) {
        if (@available(iOS 8.0, *)) {
            bounds = screen.fixedCoordinateSpace.bounds;
        }
    }
    if (CGRectGetWidth(bounds) <= 1.0 || CGRectGetHeight(bounds) <= 1.0) {
        bounds = screen.bounds;
    }
    if (CGRectGetWidth(bounds) < CGRectGetHeight(bounds) &&
        UIInterfaceOrientationIsLandscape(orientation)) {
        bounds.size = CGSizeMake(CGRectGetHeight(bounds), CGRectGetWidth(bounds));
    }
    bounds.origin = CGPointZero;
    return bounds;
}

CGRect FLMLandscapeModuleVisualBounds(void) {
    UIWindowScene *scene = FLMLandscapeWindowScene();
    UIScreen *screen = scene.screen;
    if (!screen) {
        screen = [UIScreen mainScreen];
    }
    if (@available(iOS 13.0, *)) {
        CGRect coordinateBounds = scene.coordinateSpace.bounds;
        if (CGRectGetWidth(coordinateBounds) > 1.0 &&
            CGRectGetHeight(coordinateBounds) > 1.0 &&
            CGRectGetWidth(coordinateBounds) > CGRectGetHeight(coordinateBounds)) {
            coordinateBounds.origin = CGPointZero;
            return coordinateBounds;
        }
    }
    return FLMLandscapeVisualBoundsForScreen(
        screen, FLMLandscapeInterfaceOrientation());
}

static CGRect FLMLandscapePortraitSceneBounds(void) {
    CGRect displayBounds = FLMLandscapeModuleVisualBounds();
    CGFloat shortSide = MIN(CGRectGetWidth(displayBounds),
                            CGRectGetHeight(displayBounds));
    CGFloat longSide = MAX(CGRectGetWidth(displayBounds),
                           CGRectGetHeight(displayBounds));
    if (shortSide <= 1.0 || longSide <= 1.0) {
        shortSide = FLMLandscapePortraitContentWidth;
        longSide = FLMLandscapePortraitContentHeight;
    }
    return CGRectMake(0.0, 0.0, shortSide, longSide);
}

UIInterfaceOrientation FLMLandscapeModuleVisualOrientation(void) {
    return FLMLandscapeInterfaceOrientation();
}

UIEdgeInsets FLMLandscapeModuleVisualSafeAreaInsets(void) {
    UIWindowScene *scene = FLMLandscapeWindowScene();
    UIWindow *moduleWindow = [FLMLandscapeModule sharedModule].window;
    // Do not union portrait and landscape windows. The old max-per-edge merge
    // turned a portrait {top=47,bottom=34} inset into a bogus landscape
    // {top=47,left=47,bottom=34,right=47} inset, which put the dock/handle in
    // the wrong coordinate space around the notch.
    UIWindow *(^landscapeWindow)(UIWindow *) = ^UIWindow *(UIWindow *window) {
        if (!window || window.hidden || CGRectGetWidth(window.bounds) <=
                            CGRectGetHeight(window.bounds)) {
            return nil;
        }
        return window;
    };
    UIEdgeInsets result = UIEdgeInsetsZero;
    BOOL foundLandscapeWindow = NO;
    UIWindow *preferred = landscapeWindow(moduleWindow);
    NSArray<UIWindow *> *sceneWindows = scene ? scene.windows : @[];
    NSArray<UIWindow *> *candidates = preferred
        ? [@[preferred] arrayByAddingObjectsFromArray:sceneWindows]
        : sceneWindows;
    for (UIWindow *window in candidates) {
        if (window == preferred && foundLandscapeWindow) {
            continue;
        }
        UIWindow *landscapeCandidate = landscapeWindow(window);
        if (!landscapeCandidate ||
            (foundLandscapeWindow && landscapeCandidate == preferred)) {
            continue;
        }
        UIEdgeInsets candidate = landscapeCandidate.safeAreaInsets;
        UIView *rootView = landscapeCandidate.rootViewController.view;
        if (rootView) {
            UIEdgeInsets rootInsets = rootView.safeAreaInsets;
            candidate.left = MAX(candidate.left, rootInsets.left);
            candidate.right = MAX(candidate.right, rootInsets.right);
            candidate.top = MAX(candidate.top, rootInsets.top);
            candidate.bottom = MAX(candidate.bottom, rootInsets.bottom);
        }
        if (!foundLandscapeWindow) {
            result = candidate;
            foundLandscapeWindow = YES;
        } else {
            // Combining only landscape windows preserves the physical notch
            // inset without reintroducing portrait top/bottom values.
            result.left = MAX(result.left, candidate.left);
            result.right = MAX(result.right, candidate.right);
            result.top = MAX(result.top, candidate.top);
            result.bottom = MAX(result.bottom, candidate.bottom);
        }
    }
    if (foundLandscapeWindow) {
        return result;
    }

    // During the first rotation transaction only a portrait window may have a
    // settled inset. Convert it conservatively: portrait top/bottom become the
    // two landscape side insets, while portrait left/right become vertical.
    UIEdgeInsets portraitInsets = UIEdgeInsetsZero;
    if (moduleWindow) {
        portraitInsets = moduleWindow.safeAreaInsets;
        UIView *rootView = moduleWindow.rootViewController.view;
        if (rootView) {
            UIEdgeInsets rootInsets = rootView.safeAreaInsets;
            portraitInsets.top = MAX(portraitInsets.top, rootInsets.top);
            portraitInsets.left = MAX(portraitInsets.left, rootInsets.left);
            portraitInsets.bottom = MAX(portraitInsets.bottom, rootInsets.bottom);
            portraitInsets.right = MAX(portraitInsets.right, rootInsets.right);
        }
    }
    CGFloat horizontal = MAX(portraitInsets.top, portraitInsets.bottom);
    CGFloat vertical = MAX(portraitInsets.left, portraitInsets.right);
    return UIEdgeInsetsMake(vertical, horizontal, vertical, horizontal);
}

static CGRect FLMLandscapeFixedCoordinateBounds(UIScreen *screen) {
    CGRect bounds = CGRectZero;
    if (@available(iOS 8.0, *)) {
        bounds = screen.fixedCoordinateSpace.bounds;
    }
    if (CGRectGetWidth(bounds) <= 1.0 || CGRectGetHeight(bounds) <= 1.0 ||
        CGRectGetWidth(bounds) >= CGRectGetHeight(bounds)) {
        // Some SpringBoard builds briefly expose the rotated frame through
        // fixedCoordinateSpace while the display transition is settling.
        // The frozen portrait screen frame is a safe fallback in that case.
        CGRect portraitCandidate = screen.bounds;
        if (CGRectGetWidth(portraitCandidate) > 1.0 &&
            CGRectGetHeight(portraitCandidate) > 1.0 &&
            CGRectGetWidth(portraitCandidate) < CGRectGetHeight(portraitCandidate)) {
            bounds = portraitCandidate;
        }
    }
    bounds.origin = CGPointZero;
    return bounds;
}

FLMLandscapeTouchContext FLMLandscapeModuleCaptureTouchContext(void) {
    FLMLandscapeTouchContext context = {
        NO, UIInterfaceOrientationUnknown, CGRectZero, CGRectZero};
    UIScreen *screen = FLMLandscapeWindowScene().screen;
    if (!screen) {
        screen = [UIScreen mainScreen];
    }

    // Capture the orientation and both coordinate spaces together.  Reading
    // them independently for every gesture callback is what allowed one
    // callback to see 390x844 and the next one to see 844x390 in an earlier
    // rotation-based implementation.
    context.orientation = FLMLandscapeInterfaceOrientation();
    context.visualBounds = FLMLandscapeModuleVisualBounds();
    context.fixedBounds = FLMLandscapeFixedCoordinateBounds(screen);

    CGFloat rawWidth = CGRectGetWidth(context.fixedBounds);
    CGFloat rawHeight = CGRectGetHeight(context.fixedBounds);
    if (rawWidth >= rawHeight) {
        // During the rotation transaction fixedCoordinateSpace can briefly
        // expose the already-rotated frame.  The visual frame still gives us
        // the authoritative long/short dimensions for this snapshot.
        rawWidth = CGRectGetHeight(context.visualBounds);
        rawHeight = CGRectGetWidth(context.visualBounds);
        context.fixedBounds = CGRectMake(0.0, 0.0, rawWidth, rawHeight);
    }
    context.valid = UIInterfaceOrientationIsLandscape(context.orientation) &&
                    rawWidth > 1.0 && rawHeight > 1.0 &&
                    CGRectGetWidth(context.visualBounds) > 1.0 &&
                    CGRectGetHeight(context.visualBounds) > 1.0;
    return context;
}

CGPoint FLMLandscapeModuleVisualPointFromRawPointInContext(
    FLMLandscapeTouchContext context,
    CGPoint rawPoint) {
    CGRect visualBounds = context.visualBounds;
    CGPoint point = rawPoint;
    if (context.valid) {
        CGRect fixedBounds = context.fixedBounds;
        CGFloat rawWidth = CGRectGetWidth(fixedBounds);
        CGFloat rawHeight = CGRectGetHeight(fixedBounds);
        if (rawWidth > 1.0 && rawHeight > 1.0 &&
            rawWidth < rawHeight &&
            rawPoint.x >= CGRectGetMinX(fixedBounds) - 1.0 &&
            rawPoint.x <= CGRectGetMaxX(fixedBounds) + 1.0 &&
            rawPoint.y >= CGRectGetMinY(fixedBounds) - 1.0 &&
            rawPoint.y <= CGRectGetMaxY(fixedBounds) + 1.0) {
            CGFloat fixedX = rawPoint.x - CGRectGetMinX(fixedBounds);
            CGFloat fixedY = rawPoint.y - CGRectGetMinY(fixedBounds);
            if (context.orientation == UIInterfaceOrientationLandscapeLeft) {
                point = CGPointMake(fixedY, rawWidth - fixedX);
            } else if (context.orientation == UIInterfaceOrientationLandscapeRight) {
                point = CGPointMake(rawHeight - fixedY, fixedX);
            }
        }
    }
    if (point.x < -1.0 || point.y < -1.0 ||
        point.x > CGRectGetWidth(visualBounds) + 1.0 ||
        point.y > CGRectGetHeight(visualBounds) + 1.0) {
        point.x = MAX(0.0, MIN(CGRectGetWidth(visualBounds), point.x));
        point.y = MAX(0.0, MIN(CGRectGetHeight(visualBounds), point.y));
    }
    return point;
}

CGPoint FLMLandscapeEnvironmentConvertPoint(CGPoint rawPoint) {
    return FLMLandscapeModuleVisualPointFromRawPointInContext(
        FLMLandscapeModuleCaptureTouchContext(), rawPoint);
}

CGPoint FLMLandscapeModuleVisualPointFromRawPoint(CGPoint rawPoint) {
    return FLMLandscapeEnvironmentConvertPoint(rawPoint);
}

static CGFloat FLMLandscapeTriggerSize(void) {
    CFPreferencesSynchronize(CFSTR("com.codex.flymemultitasking"),
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);
    id value = CFBridgingRelease(CFPreferencesCopyAppValue(
        CFSTR("cornerTriggerSizeV2"),
        CFSTR("com.codex.flymemultitasking")));
    CGFloat size = [value isKindOfClass:[NSNumber class]]
                       ? [(NSNumber *)value doubleValue]
                       : FLMLandscapeDefaultTriggerSize;
    return MAX(FLMLandscapeMinimumTriggerSize,
               MIN(FLMLandscapeMaximumTriggerSize, size));
}

BOOL FLMLandscapeModulePointInsideCornerTrigger(CGPoint point,
                                                CGRect bounds,
                                                BOOL *fromRight) {
    CGFloat horizontalRadius = FLMLandscapeTriggerSize();
    CGFloat verticalRadius = horizontalRadius * (65.0 / 58.0);
    CGFloat bottomDistance = CGRectGetHeight(bounds) - point.y;
    if (point.x < 0.0 || point.x > CGRectGetWidth(bounds) ||
        bottomDistance < 0.0 || bottomDistance > verticalRadius) {
        return NO;
    }
    CGFloat verticalComponent = bottomDistance / verticalRadius;
    CGFloat leftComponent = point.x / horizontalRadius;
    CGFloat rightComponent = (CGRectGetWidth(bounds) - point.x) / horizontalRadius;
    BOOL insideLeft = leftComponent * leftComponent +
                          verticalComponent * verticalComponent <= 1.0;
    BOOL insideRight = rightComponent * rightComponent +
                           verticalComponent * verticalComponent <= 1.0;
    if (fromRight) {
        *fromRight = insideRight && !insideLeft;
    }
    return insideLeft || insideRight;
}

static CGPoint FLMMiniWindowInputMapperPoint(FLMLandscapeRootView *rootView,
                                             CGPoint screenPoint,
                                             CGFloat *scaleOut) {
    UIView *hostView = rootView.hostView;
    if (hostView) {
        if (scaleOut) {
            // The real application host is deliberately kept at identity.
            // The visual card transform belongs to its SpringBoard-only
            // presentation container, and UIView conversion walks through
            // that container when mapping the touch back to Scene space.
            UIView *presentationView = hostView.superview;
            CGAffineTransform visualTransform = presentationView
                ? presentationView.transform
                : hostView.transform;
            *scaleOut = hypot(visualTransform.a, visualTransform.b);
        }
        // UIView conversion applies the inverse wrapper scale and returns
        // coordinates in the complete portrait application Scene.
        return [hostView convertPoint:screenPoint fromView:rootView];
    }
    UIView *cardView = rootView.cardView;
    if (!cardView) {
        if (scaleOut) {
            *scaleOut = 1.0;
        }
        return screenPoint;
    }
    CGPoint cardPoint = [cardView convertPoint:screenPoint fromView:rootView];
    CGSize cardSize = cardView.bounds.size;
    CGRect portraitBounds = FLMLandscapePortraitSceneBounds();
    CGFloat contentWidth = CGRectGetWidth(portraitBounds);
    CGFloat contentHeight = CGRectGetHeight(portraitBounds);
    CGFloat scale = MIN(cardSize.width / contentWidth,
                        cardSize.height / contentHeight);
    scale = MAX(0.05, scale);
    CGFloat renderedWidth = contentWidth * scale;
    CGFloat renderedHeight = contentHeight * scale;
    CGPoint renderedOrigin = CGPointMake(
        (cardSize.width - renderedWidth) * 0.5,
        (cardSize.height - renderedHeight) * 0.5);
    if (scaleOut) {
        *scaleOut = scale;
    }
    return CGPointMake((cardPoint.x - renderedOrigin.x) / scale,
                       (cardPoint.y - renderedOrigin.y) / scale);
}

@implementation FLMLandscapeRootView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit && self.cardView &&
        [hit isDescendantOfView:self.cardView] && event.allTouches.count > 0) {
        for (UITouch *touch in event.allTouches) {
            if (touch.phase != UITouchPhaseBegan) {
                continue;
            }
            CGPoint screenPoint = [touch locationInView:self];
            CGFloat scale = 1.0;
            CGPoint logicalPoint = FLMMiniWindowInputMapperPoint(
                self, screenPoint, &scale);
            FLMEnqueueDiagnosticLine(
                @"sb miniwindow-touch screen={%.1f,%.1f} logical={%.1f,%.1f} scale=%.6f rotation=%.0f",
                screenPoint.x, screenPoint.y,
                logicalPoint.x, logicalPoint.y, scale, 0.0);
            break;
        }
    }
    if (hit == self && self.passesTouchesOutsideControls) {
        if (FLMLandscapeModulePointInsideCornerTrigger(point,
                                                       self.bounds,
                                                       NULL)) {
            return self;
        }
        // The landscape card is a modal, full-display surface. The old
        // pass-through branch returned nil here, which handed every backdrop
        // touch to the application underneath and made the card non-exclusive.
        // Keep the property for compatibility with older callers, but return
        // the root view so the local outside-tap recognizer owns the stream.
        return self;
    }
    if (hit) {
        return hit;
    }
    return self;
}

@end

@implementation FLMLandscapeWindow

- (BOOL)canBecomeKeyWindow {
    // The card is the only interactive surface while it is visible. The
    // application Scene is hosted inside it, but the full-display SpringBoard
    // window remains the key owner of backdrop, handle and dock touches.
    return YES;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit && !self.hidden && self.rootViewController.view.userInteractionEnabled) {
        // A transparent root must still be an ownership boundary. Never let a
        // miss in the custom view tree fall through to the app window below.
        return self.rootViewController.view;
    }
    return hit;
}

@end

static BOOL FLMLandscapeDeviceIsLocked(void) {
    id managerClass = NSClassFromString(@"SBLockScreenManager");
    SEL selector = @selector(sharedInstance);
    id (*getter)(id, SEL) =
        (id (*)(id, SEL))[managerClass methodForSelector:selector];
    id manager = getter ? getter(managerClass, selector) : nil;
    if (!manager) {
        return NO;
    }
    for (NSString *name in @[@"isUILocked", @"isLockScreenVisible",
                             @"isLockScreenActive", @"isLocked"]) {
        SEL selector = NSSelectorFromString(name);
        if (![manager respondsToSelector:selector]) {
            continue;
        }
        BOOL (*getter)(id, SEL) = (BOOL (*)(id, SEL))[manager methodForSelector:selector];
        if (getter && getter(manager, selector)) {
            return YES;
        }
    }
    return NO;
}

static NSString *FLMLandscapeSceneIdentifier(id scene) {
    if (!scene) {
        return nil;
    }
    if ([scene respondsToSelector:@selector(sceneIdentifier)]) {
        NSString *identifier = [scene sceneIdentifier];
        if (identifier.length > 0) {
            return identifier;
        }
    }
    if ([scene respondsToSelector:@selector(identifier)]) {
        NSString *identifier = [scene identifier];
        if (identifier.length > 0) {
            return identifier;
        }
    }
    return nil;
}

static id FLMLandscapeSceneForHandle(id handle) {
    if (!handle) {
        return nil;
    }
    id scene = nil;
    @try {
        if ([handle respondsToSelector:@selector(sceneIfExists)]) {
            scene = [handle sceneIfExists];
        }
        if (!scene && [handle respondsToSelector:@selector(scene)]) {
            scene = [handle scene];
        }
    } @catch (__unused NSException *exception) {
        scene = nil;
    }
    return scene;
}

static id FLMLandscapeSharedRootController(void) {
    Class controllerClass = NSClassFromString(@"FLMWheelController");
    SEL selector = @selector(sharedController);
    if (!controllerClass || ![controllerClass respondsToSelector:selector]) {
        return nil;
    }
    id (*getter)(id, SEL) =
        (id (*)(id, SEL))[controllerClass methodForSelector:selector];
    return getter ? getter((id)controllerClass, selector) : nil;
}

static UIGestureRecognizer *FLMLandscapeSharedGestureValue(id controller,
                                                            NSString *key) {
    if (!controller || key.length == 0) {
        return nil;
    }
    @try {
        id value = [controller valueForKey:key];
        return [value isKindOfClass:[UIGestureRecognizer class]] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *FLMLandscapeInteractionDomainName(
    FLMLandscapeInteractionDomain domain) {
    switch (domain) {
        case FLMLandscapeInteractionDomainBackdrop:
            return @"backdrop";
        case FLMLandscapeInteractionDomainHandle:
            return @"handle";
        case FLMLandscapeInteractionDomainDockCard:
            return @"dock-card";
        case FLMLandscapeInteractionDomainNone:
        default:
            return @"none";
    }
}

@implementation FLMLandscapeModule

+ (instancetype)sharedModule {
    static FLMLandscapeModule *module;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        module = [[self alloc] init];
    });
    return module;
}

- (void)start {
    if (self.started) {
        return;
    }
    self.started = YES;
    FLMLandscapeKeyboardBridgeStart();
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(orientationNotification:)
               name:UIDeviceOrientationDidChangeNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(protectedSceneDidDisappear:)
               name:FLMProtectedSceneDidDisappearNotification
             object:nil];
    [self createWindowIfNeeded];
    [self updateFrames];
}

- (void)createWindowIfNeeded {
    if (self.window) {
        return;
    }
    CGRect bounds = FLMLandscapeModuleVisualBounds();
    UIWindowScene *scene = FLMLandscapeWindowScene();
    FLMLandscapeWindow *window = scene
        ? [[FLMLandscapeWindow alloc] initWithWindowScene:scene]
        : [[FLMLandscapeWindow alloc] initWithFrame:bounds];
    window.frame = bounds;
    // This is a full-display modal ownership window, not a small floating
    // window. Keep it at the same high SpringBoard level used by the portrait
    // dock gate; the native keyboard bridge is placed one level above it.
    window.windowLevel = UIWindowLevelAlert +
                         FLMLandscapeExclusiveWindowLevelOffset;
    window.backgroundColor = [UIColor clearColor];
    window.userInteractionEnabled = YES;
    FLMLandscapeRootViewController *controller =
        [[FLMLandscapeRootViewController alloc] init];
    FLMLandscapeRootView *root =
        [[FLMLandscapeRootView alloc] initWithFrame:bounds];
    root.backgroundColor = [UIColor clearColor];
    controller.view = root;
    window.rootViewController = controller;
    window.hidden = YES;

    // A transparent full-screen view is intentional: it consumes backdrop
    // touches so another application cannot receive input through the card.
    // The outside-tap recognizer is attached to the root and excludes the
    // card/handle descendants, so a single tap here closes the expanded card.
    UIView *exclusiveBackdrop = [[UIView alloc] initWithFrame:bounds];
    exclusiveBackdrop.backgroundColor = [UIColor clearColor];
    exclusiveBackdrop.userInteractionEnabled = YES;
    [root addSubview:exclusiveBackdrop];

    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = [UIColor blackColor];
    card.layer.cornerRadius = 18.0;
    card.layer.masksToBounds = YES;
    card.userInteractionEnabled = YES;
    [root addSubview:card];

    UIView *hostPresentation = [[UIView alloc] initWithFrame:CGRectZero];
    hostPresentation.backgroundColor = [UIColor clearColor];
    hostPresentation.userInteractionEnabled = YES;
    hostPresentation.clipsToBounds = NO;
    [card addSubview:hostPresentation];

    UIView *cover = [[UIView alloc] initWithFrame:CGRectZero];
    cover.backgroundColor = [UIColor secondarySystemBackgroundColor];
    cover.hidden = YES;
    cover.userInteractionEnabled = YES;
    [card addSubview:cover];

    // Docked mode must have an in-window drag owner. The private global
    // recognizer remains disabled while this full-screen window is active;
    // relying on it alone loses the touch stream as the card crosses Scenes.
    UIView *dockShield = [[UIView alloc] initWithFrame:CGRectZero];
    dockShield.backgroundColor = [UIColor clearColor];
    dockShield.hidden = YES;
    dockShield.userInteractionEnabled = NO;
    [card addSubview:dockShield];

    UIView *handle = [[UIView alloc] initWithFrame:CGRectZero];
    handle.backgroundColor = [UIColor clearColor];
    handle.userInteractionEnabled = YES;
    UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
    bar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.76];
    bar.layer.cornerRadius = FLMLandscapeHandleBarWidth * 0.5;
    bar.userInteractionEnabled = NO;
    [handle addSubview:bar];
    [root addSubview:handle];

    UITapGestureRecognizer *outsideTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self
                                                action:@selector(outsideTap:)];
    outsideTap.delegate = self;
    outsideTap.cancelsTouchesInView = NO;
    [root addGestureRecognizer:outsideTap];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                action:@selector(handlePan:)];
    pan.cancelsTouchesInView = YES;
    pan.maximumNumberOfTouches = 1;
    [handle addGestureRecognizer:pan];

    UIPanGestureRecognizer *dockPan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                action:@selector(handleDockPan:)];
    dockPan.cancelsTouchesInView = YES;
    dockPan.maximumNumberOfTouches = 1;
    dockPan.enabled = NO;
    [dockShield addGestureRecognizer:dockPan];

    UITapGestureRecognizer *dockTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self
                                                action:@selector(handleDockTap:)];
    dockTap.cancelsTouchesInView = YES;
    dockTap.enabled = NO;
    [dockTap requireGestureRecognizerToFail:dockPan];
    [dockShield addGestureRecognizer:dockTap];

    self.window = window;
    self.rootView = root;
    self.exclusiveBackdropView = exclusiveBackdrop;
    self.cardView = card;
    self.hostPresentationView = hostPresentation;
    self.hostView = nil;
    self.handleView = handle;
    self.handleBar = bar;
    self.launchCoverView = cover;
    self.dockInteractionShield = dockShield;
    self.outsideTap = outsideTap;
    self.handlePan = pan;
    self.dockPan = dockPan;
    self.dockTap = dockTap;
    root.cardView = card;
    root.handleView = handle;
}

- (void)activateSharedInteractionGestures {
    if (self.sharedInteractionActive) {
        return;
    }
    id controller = FLMLandscapeSharedRootController();
    UIGestureRecognizer *backdrop =
        FLMLandscapeSharedGestureValue(controller,
                                       @"floatingExclusiveGesture");
    UIGestureRecognizer *dock =
        FLMLandscapeSharedGestureValue(controller,
                                       @"floatingDockInputGesture");
    if (!controller || !backdrop || !dock) {
        self.rootView.passesTouchesOutsideControls = NO;
        [self configureLocalInteractionState];
        FLMEnqueueDiagnosticLine(
            @"sb landscape-card-global-route unavailable controller=%d backdrop=%d dock=%d policy=window-exclusive-local-fallback",
            controller != nil, backdrop != nil, dock != nil);
        return;
    }
    self.sharedGestureController = controller;
    self.sharedBackdropGesture = backdrop;
    self.sharedDockGesture = dock;
    self.sharedBackdropPreviouslyEnabled = backdrop.enabled;
    self.sharedDockPreviouslyEnabled = dock.enabled;
    // Reset any touch tail left by the wheel-selection stream before lending
    // these already-registered recognizers to the landscape card.
    backdrop.enabled = NO;
    dock.enabled = NO;
    self.sharedInteractionActive = YES;
    [self refreshSharedInteractionGestureState];
    // The full-display card window owns the touch stream now. Keep the
    // already-registered portrait recognizers disabled so they cannot race the
    // local handle/dock recognizers or reopen the wheel underneath the card.
    self.rootView.passesTouchesOutsideControls = NO;
    [self configureLocalInteractionState];
    FLMEnqueueDiagnosticLine(
        @"sb landscape-card-global-route active controller=%@ backdrop=%p dock=%p previous=%d/%d policy=window-exclusive-local-gestures",
        NSStringFromClass([controller class]), (__bridge void *)backdrop,
        (__bridge void *)dock, self.sharedBackdropPreviouslyEnabled,
        self.sharedDockPreviouslyEnabled);
}

- (void)refreshSharedInteractionGestureState {
    if (!self.sharedInteractionActive) {
        return;
    }
    // The private recognizers are retained only as a compatibility lease for
    // the portrait controller. A full-screen landscape window now owns every
    // touch locally, so neither recognizer may arbitrate a second stream.
    self.sharedBackdropGesture.enabled = NO;
    self.sharedDockGesture.enabled = NO;
    FLMEnqueueDiagnosticLine(
        @"sb landscape-card-global-route state=%@ backdrop=%d dock=%d policy=window-exclusive-local-gestures",
        self.hiddenCard ? @"hidden" : (self.dockedCard ? @"docked" : @"expanded"),
        self.sharedBackdropGesture.enabled,
        self.sharedDockGesture.enabled);
}

- (void)deactivateSharedInteractionGestures {
    if (!self.sharedInteractionActive) {
        return;
    }
    UIGestureRecognizer *backdrop = self.sharedBackdropGesture;
    UIGestureRecognizer *dock = self.sharedDockGesture;
    backdrop.enabled = NO;
    dock.enabled = NO;
    backdrop.enabled = self.sharedBackdropPreviouslyEnabled;
    dock.enabled = self.sharedDockPreviouslyEnabled;
    FLMEnqueueDiagnosticLine(
        @"sb landscape-card-global-route inactive backdrop=%p dock=%p restored=%d/%d",
        (__bridge void *)backdrop, (__bridge void *)dock,
        self.sharedBackdropPreviouslyEnabled,
        self.sharedDockPreviouslyEnabled);
    self.sharedInteractionActive = NO;
    self.sharedGestureController = nil;
    self.sharedBackdropGesture = nil;
    self.sharedDockGesture = nil;
    self.interactionDomain = FLMLandscapeInteractionDomainNone;
    self.interactionTouchContext = (FLMLandscapeTouchContext){
        NO, UIInterfaceOrientationUnknown, CGRectZero, CGRectZero};
    self.rootView.passesTouchesOutsideControls = NO;
    [self configureLocalInteractionState];
}

- (void)configureLocalInteractionState {
    BOOL visible = self.window && !self.window.hidden &&
                   self.identifier.length > 0;
    BOOL interactive = visible && !self.closing &&
                       !self.fullscreenPromotionInProgress;
    BOOL docked = interactive && self.dockedCard && !self.hiddenCard;

    // Keep the transparent backdrop interactive for the entire visible
    // lifetime, including the close animation. This is the actual modal
    // barrier that prevents the previous application from receiving touches.
    self.exclusiveBackdropView.userInteractionEnabled = visible;
    self.rootView.userInteractionEnabled = visible;
    self.dockInteractionShield.hidden = !docked;
    self.dockInteractionShield.userInteractionEnabled = docked;
    self.dockPan.enabled = docked;
    self.dockTap.enabled = docked;
    self.handlePan.enabled = interactive;
    self.outsideTap.enabled = interactive && !self.dockedCard &&
                              !self.hiddenCard;
}

- (BOOL)ownsSharedGesture:(UIGestureRecognizer *)gesture
               controller:(id)controller {
    return self.sharedInteractionActive && self.hasVisibleCard &&
           !self.closing && controller == self.sharedGestureController &&
           (gesture == self.sharedBackdropGesture ||
            gesture == self.sharedDockGesture);
}

- (FLMLandscapeInteractionDomain)interactionDomainForPoint:(CGPoint)point
                                                    gesture:(UIGestureRecognizer *)gesture {
    if (!self.hasVisibleCard || self.closing || self.fullscreenPromotionInProgress ||
        FLMLandscapeKeyboardBridgeContainsVisualPoint(point)) {
        return FLMLandscapeInteractionDomainNone;
    }
    CGRect handleHitFrame = CGRectInset(self.handleView.frame, -12.0, -12.0);
    if (gesture == self.sharedDockGesture) {
        if (CGRectContainsPoint(handleHitFrame, point)) {
            return FLMLandscapeInteractionDomainHandle;
        }
        if (self.dockedCard && !self.hiddenCard &&
            CGRectContainsPoint(self.cardView.frame, point)) {
            return FLMLandscapeInteractionDomainDockCard;
        }
        return FLMLandscapeInteractionDomainNone;
    }
    if (gesture == self.sharedBackdropGesture && !self.dockedCard &&
        !self.hiddenCard) {
        if (CGRectContainsPoint(handleHitFrame, point)) {
            return FLMLandscapeInteractionDomainHandle;
        }
        if (CGRectContainsPoint(self.cardView.frame, point)) {
            return FLMLandscapeInteractionDomainNone;
        }
        if (FLMLandscapeModulePointInsideCornerTrigger(
                point, self.displayBounds, NULL)) {
            // Keep the wheel's proven lower-corner route above backdrop close.
            return FLMLandscapeInteractionDomainNone;
        }
        return FLMLandscapeInteractionDomainBackdrop;
    }
    return FLMLandscapeInteractionDomainNone;
}

- (CGPoint)visualPointForGesture:(UIGestureRecognizer *)gesture
                         context:(FLMLandscapeTouchContext)context {
    CGPoint rawPoint = [gesture locationInView:nil];
    return FLMLandscapeModuleVisualPointFromRawPointInContext(context,
                                                               rawPoint);
}

- (BOOL)sharedGesture:(UIGestureRecognizer *)gesture
    shouldReceiveTouch:(UITouch *)touch {
    if (!touch || !self.sharedInteractionActive || !self.hasVisibleCard ||
        self.closing || FLMLandscapeDeviceIsLocked()) {
        return NO;
    }
    FLMLandscapeTouchContext context =
        FLMLandscapeModuleCaptureTouchContext();
    CGPoint rawPoint = [touch locationInView:nil];
    CGPoint point = FLMLandscapeModuleVisualPointFromRawPointInContext(
        context, rawPoint);
    FLMLandscapeInteractionDomain domain =
        [self interactionDomainForPoint:point gesture:gesture];
    BOOL accepted = domain != FLMLandscapeInteractionDomainNone;
    if (accepted) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-card-touch accepted domain=%@ raw={%.1f,%.1f} point={%.1f,%.1f} state=%@ visual=%@ fixed=%@",
            FLMLandscapeInteractionDomainName(domain), rawPoint.x, rawPoint.y,
            point.x, point.y,
            self.hiddenCard ? @"hidden" : (self.dockedCard ? @"docked" : @"expanded"),
            NSStringFromCGRect(context.visualBounds),
            NSStringFromCGRect(context.fixedBounds));
    }
    return accepted;
}

- (BOOL)sharedGestureShouldBegin:(UIGestureRecognizer *)gesture {
    if (!self.sharedInteractionActive || !self.hasVisibleCard || self.closing ||
        FLMLandscapeDeviceIsLocked()) {
        return NO;
    }
    FLMLandscapeTouchContext context =
        FLMLandscapeModuleCaptureTouchContext();
    CGPoint point = [self visualPointForGesture:gesture context:context];
    return [self interactionDomainForPoint:point gesture:gesture] !=
           FLMLandscapeInteractionDomainNone;
}

- (void)beginInteractionForGesture:(UIGestureRecognizer *)gesture
                             point:(CGPoint)point
                           context:(FLMLandscapeTouchContext)context {
    FLMLandscapeInteractionDomain domain =
        [self interactionDomainForPoint:point gesture:gesture];
    self.interactionDomain = domain;
    self.interactionTouchContext = context;
    self.interactionStartPoint = point;
    self.interactionStartCardFrame = self.cardView.frame;
    self.interactionStartHandleFrame = self.handleView.frame;
    self.interactionStartedAt = CACurrentMediaTime();
    FLMEnqueueDiagnosticLine(
        @"sb landscape-card-input began domain=%@ point={%.1f,%.1f} card=%@ handle=%@ state=%@ side=%@",
        FLMLandscapeInteractionDomainName(domain), point.x, point.y,
        NSStringFromCGRect(self.cardView.frame),
        NSStringFromCGRect(self.handleView.frame),
        self.hiddenCard ? @"hidden" : (self.dockedCard ? @"docked" : @"expanded"),
        self.dockedOnRight ? @"right" : @"left");
}

- (void)updateInteractionForPoint:(CGPoint)point {
    CGFloat dx = point.x - self.interactionStartPoint.x;
    CGFloat dy = point.y - self.interactionStartPoint.y;
    if (self.interactionDomain == FLMLandscapeInteractionDomainHandle) {
        if (self.hiddenCard) {
            dx = MAX(0.0, dx);
            dx = MIN(CGRectGetWidth([self dockedCardFrameOnRight:NO]), dx);
        } else {
            CGFloat resistanceStart = CGRectGetWidth(self.displayBounds) * 0.42;
            if (!self.dockedCard && dx > resistanceStart) {
                dx = resistanceStart + (dx - resistanceStart) * 0.24;
            }
            dx = MAX(-CGRectGetWidth(self.interactionStartCardFrame), dx);
        }
        [UIView performWithoutAnimation:^{
            CGRect cardFrame = self.interactionStartCardFrame;
            cardFrame.origin.x += dx;
            self.cardView.frame = cardFrame;
            CGRect handleFrame = self.interactionStartHandleFrame;
            handleFrame.origin.x += dx;
            self.handleView.frame = handleFrame;
        }];
        return;
    }
    if (self.interactionDomain != FLMLandscapeInteractionDomainDockCard) {
        return;
    }
    CGRect bounds = self.displayBounds;
    CGRect cardFrame = self.interactionStartCardFrame;
    cardFrame.origin.x = MAX(0.0,
                             MIN(CGRectGetWidth(bounds) -
                                     CGRectGetWidth(cardFrame),
                                 cardFrame.origin.x + dx));
    cardFrame.origin.y = MAX(0.0,
                             MIN(CGRectGetHeight(bounds) -
                                     CGRectGetHeight(cardFrame),
                                 cardFrame.origin.y + dy));
    [UIView performWithoutAnimation:^{
        self.cardView.frame = cardFrame;
        CGRect handleFrame = self.interactionStartHandleFrame;
        handleFrame.origin.x += cardFrame.origin.x -
                                self.interactionStartCardFrame.origin.x;
        handleFrame.origin.y += cardFrame.origin.y -
                                self.interactionStartCardFrame.origin.y;
        self.handleView.frame = handleFrame;
    }];
}

- (void)finishInteractionForGesture:(UIGestureRecognizer *)gesture
                               point:(CGPoint)point {
    FLMLandscapeInteractionDomain domain = self.interactionDomain;
    CGFloat dx = point.x - self.interactionStartPoint.x;
    CGFloat dy = point.y - self.interactionStartPoint.y;
    CGFloat movement = hypot(dx, dy);
    CFTimeInterval duration = MAX(0.01,
        CACurrentMediaTime() - self.interactionStartedAt);
    CGFloat velocityX = dx / duration;
    BOOL ended = gesture.state == UIGestureRecognizerStateEnded;
    FLMEnqueueDiagnosticLine(
        @"sb landscape-card-input ended domain=%@ recognizerState=%ld delta={%.1f,%.1f} movement=%.1f velocityX=%.1f card=%@",
        FLMLandscapeInteractionDomainName(domain), (long)gesture.state,
        dx, dy, movement, velocityX, NSStringFromCGRect(self.cardView.frame));
    self.interactionDomain = FLMLandscapeInteractionDomainNone;
    self.interactionTouchContext = (FLMLandscapeTouchContext){
        NO, UIInterfaceOrientationUnknown, CGRectZero, CGRectZero};
    if (!ended) {
        [self layoutCardAnimated:YES];
        return;
    }
    if (domain == FLMLandscapeInteractionDomainBackdrop) {
        if (movement <= FLMLandscapeTapMovementThreshold) {
            FLMEnqueueDiagnosticLine(
                @"sb landscape-module-close reason=global-outside-tap");
            [self closeKeepingApplication:YES];
        }
        return;
    }
    if (domain == FLMLandscapeInteractionDomainDockCard) {
        if (movement < FLMLandscapeTapMovementThreshold) {
            [self restoreExpandedCardAnimated:YES reason:@"dock-tap"];
        } else {
            [self snapDockedCardAnimated:YES];
        }
        return;
    }
    if (domain != FLMLandscapeInteractionDomainHandle) {
        [self layoutCardAnimated:YES];
        return;
    }
    BOOL moveLeft = dx <= -FLMLandscapeSwipeThreshold ||
                    velocityX <= -FLMLandscapeFastSwipeVelocity;
    BOOL moveRight = dx >= FLMLandscapeSwipeThreshold ||
                     velocityX >= FLMLandscapeFastSwipeVelocity;
    if (self.hiddenCard) {
        if (moveRight) {
            [self restoreExpandedCardAnimated:YES reason:@"hidden-bar-right-swipe"];
        } else {
            [self layoutCardAnimated:YES];
        }
    } else if (self.dockedCard) {
        if (moveLeft) {
            [self hideDockedCardAnimated:YES];
        } else {
            [self layoutCardAnimated:YES];
        }
    } else if (moveLeft) {
        [self dockCardAnimated:YES];
    } else if (moveRight) {
        [self promoteToFullscreen];
    } else {
        [self layoutCardAnimated:YES];
    }
}

- (void)handleSharedGesture:(UIGestureRecognizer *)gesture {
    if (![self ownsSharedGesture:gesture
                       controller:self.sharedGestureController]) {
        return;
    }
    if (gesture.state == UIGestureRecognizerStateBegan) {
        FLMLandscapeTouchContext context =
            FLMLandscapeModuleCaptureTouchContext();
        CGPoint point = [self visualPointForGesture:gesture context:context];
        [self beginInteractionForGesture:gesture point:point context:context];
        return;
    }
    FLMLandscapeTouchContext context = self.interactionTouchContext;
    if (!context.valid) {
        context = FLMLandscapeModuleCaptureTouchContext();
    }
    CGPoint point = [self visualPointForGesture:gesture context:context];
    if (gesture.state == UIGestureRecognizerStateChanged) {
        [self updateInteractionForPoint:point];
    } else if (gesture.state == UIGestureRecognizerStateEnded ||
               gesture.state == UIGestureRecognizerStateCancelled ||
               gesture.state == UIGestureRecognizerStateFailed) {
        [self finishInteractionForGesture:gesture point:point];
    }
}

- (void)orientationNotification:(NSNotification *)notification {
    (void)notification;
    [self orientationDidChange];
}

- (void)orientationDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!FLMLandscapeModuleIsLandscape()) {
            if (self.hasVisibleCard) {
                [self closeKeepingApplication:YES];
            }
            return;
        }
        [self updateFrames];
    });
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer != self.outsideTap) {
        return YES;
    }
    UIView *touchView = touch.view;
    if (touchView == self.cardView ||
        [touchView isDescendantOfView:self.cardView] ||
        touchView == self.handleView ||
        [touchView isDescendantOfView:self.handleView]) {
        return NO;
    }
    return YES;
}

- (void)protectedSceneDidDisappear:(NSNotification *)notification {
    (void)notification;
    if (!self.hasVisibleCard || self.closing) {
        return;
    }
    FLMEnqueueDiagnosticLine(
        @"sb landscape-module-scene-disappeared app=%@ generation=%lu",
        self.identifier, (unsigned long)self.generation);
    FLMLandscapeKeyboardBridgeEnd(self.keyboardSessionGeneration);
    self.keyboardSessionGeneration = 0;
    if (!self.dockedCard && !self.hiddenCard) {
        self.keyboardSessionCounter += 1;
        if (self.keyboardSessionCounter == 0) {
            self.keyboardSessionCounter = 1;
        }
        self.keyboardSessionGeneration = self.keyboardSessionCounter;
    }
    [self.hostView removeFromSuperview];
    self.hostView = nil;
    self.hostPresentationView.transform = CGAffineTransformIdentity;
    self.hostPresentationView.bounds = CGRectZero;
    self.scene = nil;
    self.sceneHandle = nil;
    self.sceneEntity = nil;
    self.presentationManager = nil;
    self.presenter = nil;
    self.presenterScene = nil;
    self.presenterPendingAttempts = 0;
    self.scenePreparedAt = 0.0;
    [self scheduleResolveForGeneration:self.generation
                                  delay:FLMLandscapeResolveInterval];
}

- (void)updateFrames {
    [self createWindowIfNeeded];
    self.displayBounds = FLMLandscapeModuleVisualBounds();
    self.displayOrientation = FLMLandscapeInterfaceOrientation();
    self.window.frame = self.displayBounds;
    CGRect rootBounds = CGRectMake(0.0,
                                   0.0,
                                   CGRectGetWidth(self.displayBounds),
                                   CGRectGetHeight(self.displayBounds));
    self.rootView.bounds = rootBounds;
    self.rootView.frame = rootBounds;
    if (!self.hasVisibleCard) {
        return;
    }
    [self layoutCardAnimated:NO];
    if ([self validateHostGeometry]) {
        [self layoutHost];
    }
}

- (BOOL)hasVisibleCard {
    return self.window && !self.window.hidden && self.identifier.length > 0;
}

- (BOOL)validateHostGeometry {
    if (!self.hostView) {
        return YES;
    }
    CGRect actual = self.hostView.bounds;
    NSString *sceneIdentifier = FLMLandscapeSceneIdentifier(self.presenterScene);
    BOOL geometryMatches = fabs(CGRectGetWidth(actual) -
                                CGRectGetWidth(self.expectedHostBounds)) < 1.0 &&
                           fabs(CGRectGetHeight(actual) -
                                CGRectGetHeight(self.expectedHostBounds)) < 1.0;
    BOOL sceneMatches = self.expectedHostSceneIdentifier.length == 0 ||
                        [self.expectedHostSceneIdentifier
                            isEqualToString:sceneIdentifier ?: @""];
    CGAffineTransform hostTransform = self.hostView.transform;
    BOOL hostTransformIsIdentity =
        fabs(hostTransform.a - 1.0) < 0.01 &&
        fabs(hostTransform.d - 1.0) < 0.01 &&
        fabs(hostTransform.b) < 0.01 && fabs(hostTransform.c) < 0.01 &&
        fabs(hostTransform.tx) < 0.01 && fabs(hostTransform.ty) < 0.01;
    BOOL hostAttachedToPresentation =
        self.hostPresentationView == self.hostView.superview;
    if (geometryMatches && sceneMatches &&
        self.expectedHostGeneration == self.generation &&
        hostTransformIsIdentity && hostAttachedToPresentation) {
        return YES;
    }
    FLMEnqueueDiagnosticLine(
        @"sb host-geometry-mismatch generation=%lu expectedContent=%@ actualHost=%@ expectedScene=%@ actualScene=%@ hostTransform=%@ hostPresentation=%d action=reacquire-native-host",
        (unsigned long)self.generation,
        NSStringFromCGRect(self.expectedHostBounds), NSStringFromCGRect(actual),
        self.expectedHostSceneIdentifier ?: @"<none>",
        sceneIdentifier ?: @"<none>", NSStringFromCGAffineTransform(hostTransform),
        hostAttachedToPresentation);
    UIView *staleHost = self.hostView;
    id stalePresenter = self.presenter;
    [staleHost removeFromSuperview];
    self.hostView = nil;
    self.rootView.hostView = nil;
    @try {
        if ([stalePresenter respondsToSelector:@selector(deactivate)]) {
            [stalePresenter deactivate];
        }
        if ([stalePresenter respondsToSelector:@selector(invalidate)]) {
            [stalePresenter invalidate];
        }
    } @catch (__unused NSException *exception) {
    }
    self.presenter = nil;
    self.presentationManager = nil;
    self.presenterScene = nil;
    self.presenterPendingAttempts = 0;
    [self scheduleResolveForGeneration:self.generation
                                  delay:FLMLandscapeResolveInterval];
    return NO;
}

- (void)openIdentifier:(NSString *)identifier {
    if (identifier.length == 0 || FLMLandscapeDeviceIsLocked() ||
        !FLMLandscapeModuleIsLandscape()) {
        return;
    }
    [self createWindowIfNeeded];
    if (self.hasVisibleCard && [self.identifier isEqualToString:identifier]) {
        return;
    }
    if (self.hasVisibleCard || self.closing) {
        self.queuedIdentifier = [identifier copy];
        [self closeKeepingApplication:YES];
        return;
    }
    self.identifier = [identifier copy];
    self.generation += 1;
    if (self.generation == 0) {
        self.generation = 1;
    }
    self.keyboardSessionCounter += 1;
    if (self.keyboardSessionCounter == 0) {
        self.keyboardSessionCounter = 1;
    }
    self.keyboardSessionGeneration = self.keyboardSessionCounter;
    self.openedAt = CACurrentMediaTime();
    self.resolveAttempt = 0;
    self.presenterPendingAttempts = 0;
    self.scenePreparedAt = 0.0;
    self.expectedHostBounds = FLMLandscapePortraitSceneBounds();
    self.expectedHostGeneration = self.generation;
    self.expectedHostSceneIdentifier = nil;
    self.dockedCard = NO;
    self.hiddenCard = NO;
    self.dockedOnRight = NO;
    self.closing = NO;
    self.displayBounds = FLMLandscapeModuleVisualBounds();
    self.displayOrientation = FLMLandscapeInterfaceOrientation();
    self.window.frame = self.displayBounds;
    self.rootView.bounds = CGRectMake(0.0,
                                      0.0,
                                      CGRectGetWidth(self.displayBounds),
                                      CGRectGetHeight(self.displayBounds));
    self.rootView.frame = self.rootView.bounds;
    self.previousKeyWindow = FLMLandscapeCurrentKeyWindow();
    [self.window makeKeyAndVisible];
    self.window.alpha = 1.0;
    self.cardView.alpha = 1.0;
    self.cardView.transform = CGAffineTransformIdentity;
    self.launchCoverView.hidden = NO;
    self.launchCoverView.alpha = 1.0;
    self.window.userInteractionEnabled = YES;
    [self layoutCardAnimated:NO];
    CGRect target = self.cardView.frame;
    self.cardView.frame = CGRectOffset(target, -CGRectGetWidth(target) - 24.0, 0.0);
    [self setHandleVisible:YES];
    [self layoutCardAnimated:YES];
    [self activateSharedInteractionGestures];
    UIEdgeInsets safeArea = FLMLandscapeModuleVisualSafeAreaInsets();
    FLMEnqueueDiagnosticLine(
        @"sb landscape-environment display={%.1f,%.1f} orientation=%ld safeArea={%.1f,%.1f,%.1f,%.1f}",
        self.displayBounds.size.width, self.displayBounds.size.height,
        (long)self.displayOrientation, safeArea.top, safeArea.left,
        safeArea.bottom, safeArea.right);
    FLMEnqueueDiagnosticLine(
        @"sb landscape-content-contract appScene=%@ appOrientation=%ld outerDisplay=%@ outerOrientation=%ld mode=hosted-portrait-scene visual=uniform-scale",
        NSStringFromCGRect(self.expectedHostBounds),
        (long)UIInterfaceOrientationPortrait,
        NSStringFromCGRect(self.displayBounds),
        (long)self.displayOrientation);
    FLMEnqueueDiagnosticLine(
        @"sb landscape-module-open app=%@ generation=%lu authoritySurface=%@ visualCard=%@ orientation=%ld policy=visual-small-window-system-full-display safeAreaLeft=%.1f safeAreaRight=%.1f",
        self.identifier, (unsigned long)self.generation,
        NSStringFromCGRect(self.displayBounds), NSStringFromCGRect(target),
        (long)self.displayOrientation, safeArea.left, safeArea.right);
    [self prewarmIdentifier:self.identifier];
    FLMEnqueueDiagnosticLine(
        @"sb landscape-scene-bootstrap app=%@ generation=%lu mode=suspended-prewarm-hosted-portrait cardWindowKey=%d workspaceOwner=unchanged keyboardOwner=system-bridge windowLevel=%.1f",
        self.identifier, (unsigned long)self.generation,
        self.window.isKeyWindow, self.window.windowLevel);
    [self.lockTimer invalidate];
    self.lockTimer = [NSTimer timerWithTimeInterval:0.25
                                             target:self
                                           selector:@selector(lockTimerFired:)
                                           userInfo:nil
                                            repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.lockTimer forMode:NSRunLoopCommonModes];
    [self scheduleResolveForGeneration:self.generation
                                  delay:FLMLandscapeResolveGraceDelay];
}

- (void)lockTimerFired:(NSTimer *)timer {
    (void)timer;
    if (self.hasVisibleCard) {
        id scene = self.scene;
        BOOL runtimeStateKnown = NO;
        NSInteger activationState = -1;
        BOOL runtimeForeground = FLMLandscapeSceneRuntimeIsForeground(
            scene, &runtimeStateKnown, &activationState);
        BOOL serverDrifted =
            scene && !FLMLandscapeSceneHasPortraitCardSettings(scene);
        BOOL foregroundDrifted =
            scene && runtimeStateKnown && !runtimeForeground;
        if (serverDrifted || foregroundDrifted) {
            FLMEnqueueDiagnosticLine(
                @"sb landscape-scene-drift app=%@ server=%d foreground=%d activationState=%ld frontmost=%@ action=reassert-hosted-scene",
                self.identifier, serverDrifted,
                foregroundDrifted, (long)activationState,
                FLMLandscapeFrontmostApplicationIdentifier() ?: @"<none>");
            [self refreshSceneForeground];
        }
        [self validateHostGeometry];
    }
    if (self.hasVisibleCard && FLMLandscapeDeviceIsLocked()) {
        FLMEnqueueDiagnosticLine(@"sb landscape-module-close reason=lock-screen");
        [self closeKeepingApplication:YES];
        return;
    }
    if (self.hasVisibleCard && !self.hostView && self.openedAt > 0.0 &&
        CACurrentMediaTime() - self.openedAt > FLMLandscapeResolveTimeout) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-host-timeout generation=%lu contract=hosted-portrait-scene action=close-without-fullscreen-fallback",
            (unsigned long)self.generation);
        [self closeKeepingApplication:YES];
    }
}

- (BOOL)prewarmIdentifier:(NSString *)identifier {
    if (identifier.length == 0) {
        return NO;
    }
    UIApplication *application = [UIApplication sharedApplication];
    BOOL prewarmRequested = NO;
    if ([application respondsToSelector:
                          @selector(launchApplicationWithIdentifier:suspended:)]) {
        // Match the proven portrait route. Publish the target's primary Scene
        // without committing a Workspace transition; the SpringBoard card
        // remains the visual and input owner while the hosted Scene is made
        // foreground at the Scene level by prepareScene:.
        prewarmRequested =
            [application launchApplicationWithIdentifier:identifier
                                                suspended:YES];
    }
    FLMEnqueueDiagnosticLine(
        @"sb landscape-scene-prewarm app=%@ suspended=1 requested=%d frontmost=%@ cardWindowKey=%d workspaceTransition=0",
        identifier, prewarmRequested,
        FLMLandscapeFrontmostApplicationIdentifier() ?: @"<none>",
        self.window.isKeyWindow);
    return prewarmRequested;
}

- (void)scheduleResolveForGeneration:(NSUInteger)generation delay:(NSTimeInterval)delay {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != self.generation || self.closing ||
            self.identifier.length == 0 || self.window.hidden) {
            return;
        }
        [self resolveAndAttachForGeneration:generation];
    });
}

- (void)resolveAndAttachForGeneration:(NSUInteger)generation {
    if (generation != self.generation || self.closing) {
        return;
    }
    self.resolveAttempt += 1;
    NSTimeInterval elapsed = CACurrentMediaTime() - self.openedAt;
    if (elapsed > FLMLandscapeResolveTimeout) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-module-open timeout app=%@ generation=%lu",
            self.identifier, (unsigned long)generation);
        [self closeKeepingApplication:YES];
        return;
    }
    if (FLMLandscapeDeviceIsLocked()) {
        [self closeKeepingApplication:YES];
        return;
    }
    if (!FLMLandscapeModuleIsLandscape()) {
        if (self.resolveAttempt <= 3 || self.resolveAttempt % 20 == 0) {
            FLMEnqueueDiagnosticLine(
                @"sb landscape-scene-resolve gated=orientation generation=%lu attempt=%lu elapsed=%.2f interfaceOrientation=%ld visualBounds=%@ cardWindowKey=%d action=retry",
                (unsigned long)generation, (unsigned long)self.resolveAttempt,
                elapsed, (long)FLMLandscapeInterfaceOrientation(),
                NSStringFromCGRect(FLMLandscapeModuleVisualBounds()),
                self.window.isKeyWindow);
        }
        [self scheduleResolveForGeneration:generation
                                      delay:FLMLandscapeResolveInterval];
        return;
    }
    id scene = FLMLandscapeSceneForHandle(self.sceneHandle);
    if (!scene && (self.sceneHandle || self.sceneEntity)) {
        if (self.resolveAttempt <= 3 || self.resolveAttempt % 20 == 0) {
            FLMEnqueueDiagnosticLine(
                @"sb landscape-scene-handle-stale app=%@ generation=%lu attempt=%lu elapsed=%.2f handle=%@ action=reacquire",
                self.identifier, (unsigned long)generation,
                (unsigned long)self.resolveAttempt, elapsed,
                self.sceneHandle ? NSStringFromClass([self.sceneHandle class])
                                 : @"<none>");
        }
        self.scene = nil;
        self.sceneHandle = nil;
        self.sceneEntity = nil;
        self.scenePreparedAt = 0.0;
    }
    if (!scene) {
        Class controllerClass = NSClassFromString(@"SBApplicationController");
        FLMLandscapeApplicationController *controller =
            [controllerClass respondsToSelector:@selector(sharedInstance)]
                ? [controllerClass sharedInstance]
                : nil;
        id application = [controller respondsToSelector:
                                      @selector(applicationWithBundleIdentifier:)]
                              ? [controller applicationWithBundleIdentifier:self.identifier]
                              : nil;
        Class entityClass = NSClassFromString(@"SBDeviceApplicationSceneEntity");
        SEL initializer =
            @selector(initWithApplicationForMainDisplay:
                      generatingNewPrimarySceneIfRequired:);
        id allocatedEntity = entityClass ? [entityClass alloc] : nil;
        BOOL generate = elapsed >= 0.75;
        id entity = nil;
        id handle = nil;
        if (application && allocatedEntity &&
            [allocatedEntity respondsToSelector:initializer]) {
            entity = [(FLMLandscapeSceneEntity *)allocatedEntity
                initWithApplicationForMainDisplay:application
                generatingNewPrimarySceneIfRequired:generate];
            handle = [entity respondsToSelector:@selector(sceneHandle)]
                         ? [entity sceneHandle]
                         : nil;
            scene = FLMLandscapeSceneForHandle(handle);
            // A normal foreground launch can replace its primary Scene after
            // this entity is created. Keep only a handle that already resolves,
            // or a generated-primary handle for the next bounded retry.
            if (entity && handle && (scene || generate)) {
                self.sceneEntity = entity;
                self.sceneHandle = handle;
            }
        }
        if (self.resolveAttempt == 1 || self.resolveAttempt == 5 ||
            self.resolveAttempt % 20 == 0 || scene) {
            FLMEnqueueDiagnosticLine(
                @"sb landscape-scene-resolve app=%@ generation=%lu attempt=%lu elapsed=%.2f generate=%d application=%@ entity=%@ handle=%@ scene=%@",
                self.identifier, (unsigned long)generation,
                (unsigned long)self.resolveAttempt, elapsed, generate,
                application ? NSStringFromClass([application class]) : @"<none>",
                entity ? NSStringFromClass([entity class]) : @"<none>",
                handle ? NSStringFromClass([handle class]) : @"<none>",
                scene ? FLMLandscapeSceneIdentifier(scene) : @"<none>");
        }
    }
    if (!scene) {
        [self scheduleResolveForGeneration:generation delay:FLMLandscapeResolveInterval];
        return;
    }
    BOOL sceneChanged = self.scene && self.scene != scene;
    if (sceneChanged) {
        self.scenePreparedAt = 0.0;
        self.presenter = nil;
        self.presentationManager = nil;
        self.presenterScene = nil;
        self.presenterPendingAttempts = 0;
    }
    if (!self.scenePreparedAt || sceneChanged) {
        self.scene = scene;
        if (![self prepareScene:scene handle:self.sceneHandle]) {
            [self scheduleResolveForGeneration:generation delay:FLMLandscapeResolveInterval];
            return;
        }
        self.scenePreparedAt = CACurrentMediaTime();
        self.presenter = nil;
        self.presentationManager = nil;
        self.presenterScene = nil;
        self.presenterPendingAttempts = 0;
        // Keep Scene activation and Presenter creation in separate compositor
        // turns, exactly as the frozen portrait path does on a cold launch.
        [self scheduleResolveForGeneration:generation
                                      delay:FLMLandscapeSceneSettleDelay];
        return;
    }
    NSTimeInterval preparedFor = CACurrentMediaTime() - self.scenePreparedAt;
    if (preparedFor < FLMLandscapeSceneSettleDelay) {
        [self scheduleResolveForGeneration:generation
                                      delay:MAX(0.01,
                                                FLMLandscapeSceneSettleDelay -
                                                    preparedFor)];
        return;
    }
    BOOL runtimeStateKnown = NO;
    NSInteger activationState = -1;
    BOOL runtimeForeground = FLMLandscapeSceneRuntimeIsForeground(
        scene, &runtimeStateKnown, &activationState);
    if (runtimeStateKnown && !runtimeForeground) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-scene-ready rejected=not-foreground app=%@ activationState=%ld runtime={%@}",
            self.identifier, (long)activationState,
            FLMLandscapeSceneRuntimeSummary(scene));
        [self refreshSceneForeground];
        [self scheduleResolveForGeneration:generation
                                      delay:FLMLandscapeResolveInterval];
        return;
    }
    if (!FLMLandscapeSceneHasPortraitCardSettings(scene)) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-scene-ready rejected=not-hosted-portrait app=%@ frame=%@ orientation=%ld expected=%@ runtime={%@}",
            self.identifier, NSStringFromCGRect(FLMLandscapeSceneSettingsFrame(scene)),
            (long)FLMLandscapeSceneSettingsOrientation(scene),
            NSStringFromCGRect(FLMLandscapePortraitSceneBounds()),
            FLMLandscapeSceneRuntimeSummary(scene));
        [self refreshSceneForeground];
        [self scheduleResolveForGeneration:generation
                                      delay:FLMLandscapeResolveInterval];
        return;
    }
    id manager = self.presentationManager;
    UIView *host = nil;
    @try {
        if (!manager &&
            [scene respondsToSelector:@selector(uiPresentationManager)]) {
            manager = [scene uiPresentationManager];
        }
        if (!manager &&
            [scene respondsToSelector:@selector(presentationManager)]) {
            manager = [scene presentationManager];
        }
        self.presentationManager = manager;
        if (!self.presenter &&
            [manager respondsToSelector:@selector(createPresenterWithIdentifier:)]) {
            FLMEnqueueDiagnosticLine(
                @"sb landscape-presenter phase=create-begin app=%@ scene=%@ manager=%p attempt=%lu",
                self.identifier,
                FLMLandscapeSceneIdentifier(scene) ?: @"<none>",
                (__bridge void *)manager, (unsigned long)self.resolveAttempt);
            self.presenter = [manager createPresenterWithIdentifier:
                                      @"com.codex.flymemultitasking.landscape"];
            if ([self.presenter respondsToSelector:@selector(activate)]) {
                [self.presenter activate];
            }
            FLMEnqueueDiagnosticLine(
                @"sb landscape-presenter phase=create-complete app=%@ scene=%@ presenter=%p",
                self.identifier,
                FLMLandscapeSceneIdentifier(scene) ?: @"<none>",
                (__bridge void *)self.presenter);
        }
        host = [self.presenter respondsToSelector:@selector(presentationView)]
                   ? [self.presenter presentationView]
                   : nil;
    } @catch (NSException *exception) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-presenter failed app=%@ scene=%@ exception=%@ reason=%@ action=retry",
            self.identifier, FLMLandscapeSceneIdentifier(scene) ?: @"<none>",
            exception.name ?: @"<none>", exception.reason ?: @"<none>");
        self.presenter = nil;
        self.presentationManager = nil;
        self.presenterPendingAttempts = 0;
        [self scheduleResolveForGeneration:generation
                                      delay:FLMLandscapeResolveInterval];
        return;
    }
    if (![host isKindOfClass:[UIView class]]) {
        self.presenterPendingAttempts += 1;
        if (self.presenterPendingAttempts <= 3 ||
            self.presenterPendingAttempts % 6 == 0) {
            FLMEnqueueDiagnosticLine(
                @"sb landscape-presenter pending app=%@ scene=%@ manager=%p presenter=%p attempt=%lu pending=%lu action=retry",
                self.identifier,
                FLMLandscapeSceneIdentifier(scene) ?: @"<none>",
                (__bridge void *)manager, (__bridge void *)self.presenter,
                (unsigned long)self.resolveAttempt,
                (unsigned long)self.presenterPendingAttempts);
        }
        if (self.presenter && self.presenterPendingAttempts >= 12) {
            id stalePresenter = self.presenter;
            @try {
                if ([stalePresenter respondsToSelector:@selector(deactivate)]) {
                    [stalePresenter deactivate];
                }
                if ([stalePresenter respondsToSelector:@selector(invalidate)]) {
                    [stalePresenter invalidate];
                }
            } @catch (__unused NSException *exception) {
            }
            self.presenter = nil;
            self.presentationManager = nil;
            self.presenterPendingAttempts = 0;
            FLMEnqueueDiagnosticLine(
                @"sb landscape-presenter recovery app=%@ scene=%@ attempt=%lu action=recreate",
                self.identifier,
                FLMLandscapeSceneIdentifier(scene) ?: @"<none>",
                (unsigned long)self.resolveAttempt);
        }
        [self scheduleResolveForGeneration:generation delay:FLMLandscapeResolveInterval];
        return;
    }
    CGRect initialHostBounds = host.bounds;
    BOOL initialHostHasGeometry = CGRectGetWidth(initialHostBounds) > 1.0 &&
                                   CGRectGetHeight(initialHostBounds) > 1.0;
    CGRect sceneFrame = FLMLandscapeSceneSettingsFrame(scene);
    BOOL hostMatchesScene = initialHostHasGeometry &&
        fabs(CGRectGetWidth(initialHostBounds) - CGRectGetWidth(sceneFrame)) < 1.0 &&
        fabs(CGRectGetHeight(initialHostBounds) - CGRectGetHeight(sceneFrame)) < 1.0;
    // FrontBoard may decorate a portrait Presenter with the outer display's
    // rotation. Bounds are the application contract; the transform belongs to
    // presentation and is safely normalized after the host is attached.
    BOOL nativeHostReady = hostMatchesScene &&
        CGRectGetHeight(initialHostBounds) > CGRectGetWidth(initialHostBounds);
    if (!nativeHostReady) {
        self.presenterPendingAttempts += 1;
        FLMEnqueueDiagnosticLine(
            @"sb landscape-host-pending reason=non-portrait-host hostBounds=%@ hostTransform=%@ sceneFrame=%@ sceneOrientation=%ld runtime={%@} pending=%lu action=wait-portrait-bounds",
            NSStringFromCGRect(initialHostBounds),
            NSStringFromCGAffineTransform(host.transform),
            NSStringFromCGRect(sceneFrame),
            (long)FLMLandscapeSceneSettingsOrientation(scene),
            FLMLandscapeSceneRuntimeSummary(scene),
            (unsigned long)self.presenterPendingAttempts);
        if (self.presenterPendingAttempts >= 12) {
            id stalePresenter = self.presenter;
            @try {
                if ([stalePresenter respondsToSelector:@selector(deactivate)]) {
                    [stalePresenter deactivate];
                }
                if ([stalePresenter respondsToSelector:@selector(invalidate)]) {
                    [stalePresenter invalidate];
                }
            } @catch (__unused NSException *exception) {
            }
            self.presenter = nil;
            self.presentationManager = nil;
            self.presenterPendingAttempts = 0;
            FLMEnqueueDiagnosticLine(
                @"sb landscape-presenter recovery app=%@ scene=%@ attempt=%lu action=recreate-portrait-host",
                self.identifier,
                FLMLandscapeSceneIdentifier(scene) ?: @"<none>",
                (unsigned long)self.resolveAttempt);
        }
        [self scheduleResolveForGeneration:generation
                                      delay:FLMLandscapeResolveInterval];
        return;
    }
    self.presenterPendingAttempts = 0;
    if (self.hostView != host) {
        [self.hostView removeFromSuperview];
        self.hostView = host;
        host.backgroundColor = [UIColor blackColor];
        host.userInteractionEnabled = YES;
        host.clipsToBounds = NO;
        [self.hostPresentationView addSubview:host];
    } else if (host.superview != self.hostPresentationView) {
        [host removeFromSuperview];
        [self.hostPresentationView addSubview:host];
    }
    self.presenterScene = scene;
    self.expectedHostBounds = CGRectMake(0.0, 0.0,
                                         CGRectGetWidth(sceneFrame),
                                         CGRectGetHeight(sceneFrame));
    self.expectedHostGeneration = generation;
    self.expectedHostSceneIdentifier = FLMLandscapeSceneIdentifier(scene);
    host.hidden = NO;
    CGAffineTransform initialHostTransform = host.transform;
    host.transform = CGAffineTransformIdentity;
    host.userInteractionEnabled = !self.dockedCard && !self.hiddenCard;
    if (!self.dockedCard && !self.hiddenCard) {
        if (self.keyboardSessionGeneration == 0) {
            self.keyboardSessionCounter += 1;
            if (self.keyboardSessionCounter == 0) {
                self.keyboardSessionCounter = 1;
            }
            self.keyboardSessionGeneration = self.keyboardSessionCounter;
        }
        FLMLandscapeKeyboardBridgeBegin(self.identifier,
                                        scene,
                                        self.keyboardSessionGeneration,
                                        self.window);
    }
    [self layoutHost];
    self.launchCoverView.alpha = 1.0;
    self.launchCoverView.hidden = NO;
    [self.cardView bringSubviewToFront:self.launchCoverView];
    UIView *attachedHost = host;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(FLMLandscapeHostRevealDelay *
                                           NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != self.generation || self.closing ||
            self.window.hidden || self.hostView != attachedHost) {
            return;
        }
        [attachedHost setNeedsLayout];
        [attachedHost layoutIfNeeded];
        self.launchCoverView.hidden = YES;
        FLMEnqueueDiagnosticLine(
            @"sb landscape-host-reveal app=%@ generation=%lu host=%p delay=%.2f contract=hosted-portrait",
            self.identifier, (unsigned long)generation,
            (__bridge void *)attachedHost, FLMLandscapeHostRevealDelay);
    });
    FLMEnqueueDiagnosticLine(
        @"sb host-attach generation=%lu contentContract=full-screen-portrait-hosted host=%@ expectedHost=%@ serverScene=%@ serverOrientation=%ld initialHostTransform=%@ hostTransform=identity workspaceOwner=%@",
        (unsigned long)generation, NSStringFromCGRect(host.bounds),
        NSStringFromCGRect(self.expectedHostBounds),
        NSStringFromCGRect(FLMLandscapeSceneSettingsFrame(scene)),
        (long)FLMLandscapeSceneSettingsOrientation(scene),
        NSStringFromCGAffineTransform(initialHostTransform),
        FLMLandscapeFrontmostApplicationIdentifier() ?: @"<none>");
    FLMEnqueueDiagnosticLine(
        @"sb landscape-module-attached app=%@ generation=%lu scene=%@ host=%p card=%@ display=%@ sceneRuntime={%@} frontmost=%@ cardWindowKey=%d windowLevel=%.1f",
        self.identifier, (unsigned long)generation,
        FLMLandscapeSceneIdentifier(scene), (__bridge void *)host,
        NSStringFromCGRect(self.cardView.frame), NSStringFromCGRect(self.displayBounds),
        FLMLandscapeSceneRuntimeSummary(scene),
        FLMLandscapeFrontmostApplicationIdentifier() ?: @"<none>",
        self.window.isKeyWindow, self.window.windowLevel);
}

- (BOOL)prepareScene:(id)scene handle:(id)handle {
    if (!scene ||
        ![scene respondsToSelector:@selector(updateSettings:withTransitionContext:)]) {
        return NO;
    }
    FLMProtectScene(scene, handle);
    NSString *phase = @"begin";
    @try {
        CGRect portraitBounds = FLMLandscapePortraitSceneBounds();
        if (CGRectGetWidth(portraitBounds) <= 1.0 ||
            CGRectGetHeight(portraitBounds) <= 1.0 ||
            CGRectGetHeight(portraitBounds) <= CGRectGetWidth(portraitBounds)) {
            FLMClearProtectedScene(scene);
            return NO;
        }
        UIInterfaceOrientation orientation = UIInterfaceOrientationPortrait;

        FLMEnqueueDiagnosticLine(
            @"sb landscape-scene-prepare phase=begin app=%@ scene=%@ class=%@ appFrame=%@ appOrientation=%ld outerFrame=%@ outerOrientation=%ld",
            self.identifier, FLMLandscapeSceneIdentifier(scene) ?: @"<none>",
            NSStringFromClass([scene class]), NSStringFromCGRect(portraitBounds),
            (long)orientation, NSStringFromCGRect(self.displayBounds),
            (long)self.displayOrientation);

        phase = @"content-state";
        if ([scene respondsToSelector:@selector(_setContentState:)]) {
            [scene _setContentState:2];
        }
        FLMEnqueueDiagnosticLine(
            @"sb landscape-scene-prepare phase=content-state-complete app=%@ scene=%@",
            self.identifier, FLMLandscapeSceneIdentifier(scene) ?: @"<none>");
        phase = @"activate";
        if ([scene respondsToSelector:@selector(activate)]) {
            [scene activate];
        }
        FLMEnqueueDiagnosticLine(
            @"sb landscape-scene-prepare phase=activate-complete app=%@ scene=%@",
            self.identifier, FLMLandscapeSceneIdentifier(scene) ?: @"<none>");

        phase = @"copy-settings";
        id settings = [scene respondsToSelector:@selector(settings)]
                          ? [scene settings]
                          : nil;
        id mutableSettings = [settings mutableCopy];
        if (!mutableSettings && [scene respondsToSelector:@selector(mutableSettings)]) {
            mutableSettings = [scene mutableSettings];
        }
        if (!mutableSettings) {
            FLMClearProtectedScene(scene);
            return NO;
        }
        if ([mutableSettings respondsToSelector:@selector(setDeactivationReasons:)]) {
            [mutableSettings setDeactivationReasons:0];
        }
        if ([mutableSettings respondsToSelector:@selector(setForeground:)]) {
            [mutableSettings setForeground:YES];
        }
        if ([mutableSettings respondsToSelector:@selector(setBackgrounded:)]) {
            [mutableSettings setBackgrounded:NO];
        }
        if ([mutableSettings respondsToSelector:@selector(setFrame:)]) {
            [mutableSettings setFrame:portraitBounds];
        }
        if ([mutableSettings respondsToSelector:@selector(setInterfaceOrientation:)]) {
            [mutableSettings setInterfaceOrientation:(NSInteger)orientation];
        }

        // Match the proven portrait ordering: commit one complete display-sized
        // portrait Scene transaction, then wait one compositor turn before the
        // Presenter is created. The physical card never becomes Scene geometry.
        phase = @"server-settings";
        FLMEnqueueDiagnosticLine(
            @"sb landscape-scene-prepare phase=server-settings-begin app=%@ scene=%@ frame=%@ orientation=%ld workspaceTransition=0",
            self.identifier, FLMLandscapeSceneIdentifier(scene) ?: @"<none>",
            NSStringFromCGRect(portraitBounds), (long)orientation);
        [scene updateSettings:mutableSettings withTransitionContext:nil];
        FLMEnqueueDiagnosticLine(
            @"sb landscape-scene-prepare phase=server-settings-complete app=%@ scene=%@",
            self.identifier, FLMLandscapeSceneIdentifier(scene) ?: @"<none>");

        // Committing geometry can amend activation. Reassert only this hosted
        // Scene; never promote the application into the real Workspace.
        phase = @"post-settings-focus";
        if ([scene respondsToSelector:@selector(activate)]) {
            [scene activate];
        }
        if ([scene respondsToSelector:@selector(setForeground:)]) {
            [scene setForeground:YES];
        }
        if ([scene respondsToSelector:@selector(setBackgrounded:)]) {
            [scene setBackgrounded:NO];
        }
        FLMEnqueueDiagnosticLine(
            @"sb landscape-scene-prepare phase=post-settings-focus-complete app=%@ scene=%@ cardWindowKey=%d",
            self.identifier, FLMLandscapeSceneIdentifier(scene) ?: @"<none>",
            self.window.isKeyWindow);

        CGRect appliedFrame = FLMLandscapeSceneSettingsFrame(scene);
        UIInterfaceOrientation appliedOrientation =
            FLMLandscapeSceneSettingsOrientation(scene);
        BOOL portraitContract =
            CGRectGetHeight(appliedFrame) > CGRectGetWidth(appliedFrame) &&
            CGRectGetWidth(appliedFrame) > 1.0 &&
            CGRectGetHeight(appliedFrame) > 1.0 &&
            appliedOrientation == UIInterfaceOrientationPortrait;
        BOOL runtimeStateKnown = NO;
        NSInteger activationState = -1;
        BOOL runtimeForeground = FLMLandscapeSceneRuntimeIsForeground(
            scene, &runtimeStateKnown, &activationState);
        FLMEnqueueDiagnosticLine(
            @"sb landscape-scene-contract app=%@ requestedFrame=%@ requestedOrientation=%ld appliedFrame=%@ appliedOrientation=%ld portraitContract=%d runtimeForeground=%d/%d activationState=%ld contract=full-screen-portrait-hosted keyboard=system-bridge frontmost=%@",
            self.identifier, NSStringFromCGRect(portraitBounds),
            (long)orientation, NSStringFromCGRect(appliedFrame),
            (long)appliedOrientation, portraitContract,
            runtimeForeground, runtimeStateKnown, (long)activationState,
            FLMLandscapeFrontmostApplicationIdentifier() ?: @"<none>");
        // Settings and foreground state are asynchronous. Readiness is checked
        // after a short settle and requires an identity portrait host.
        return YES;
    } @catch (NSException *exception) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-scene-prepare failed app=%@ scene=%@ phase=%@ exception=%@ reason=%@",
            self.identifier, FLMLandscapeSceneIdentifier(scene) ?: @"<none>",
            phase, exception.name ?: @"<none>",
            exception.reason ?: @"<none>");
        FLMClearProtectedScene(scene);
        return NO;
    }
}

- (CGRect)expandedCardFrame {
    CGRect bounds = self.displayBounds;
    CGFloat displayWidth = CGRectGetWidth(bounds);
    CGFloat displayHeight = CGRectGetHeight(bounds);
    if (displayWidth <= displayHeight || displayWidth <= 1.0 || displayHeight <= 1.0) {
        return CGRectZero;
    }
    CGFloat cardHeight = displayHeight * FLMLandscapeCardMaximumHeightRatio;
    CGFloat cardWidth = cardHeight *
                        FLMLandscapePortraitCardWidthToHeightRatio;
    UIEdgeInsets safeArea = FLMLandscapeModuleVisualSafeAreaInsets();
    CGFloat maximumCardOriginX = MAX(0.0, displayWidth - cardWidth);
    CGFloat cardOriginX = MAX(0.0, MIN(maximumCardOriginX, safeArea.left));
    return CGRectMake(floor(cardOriginX),
                      floor((displayHeight - cardHeight) * 0.5),
                      floor(cardWidth), floor(cardHeight));
}

- (CGRect)dockedCardFrameOnRight:(BOOL)onRight {
    CGRect bounds = self.displayBounds;
    CGRect expandedFrame = [self expandedCardFrame];
    CGFloat dockWidth = MAX(
        FLMLandscapeMinimumDockWidth,
        floor(CGRectGetWidth(expandedFrame) * FLMLandscapeDockWidthRatio));
    dockWidth = MIN(floor(CGRectGetWidth(expandedFrame)), dockWidth);
    CGFloat dockHeight = floor(dockWidth /
                               FLMLandscapePortraitCardWidthToHeightRatio);
    UIEdgeInsets safeArea = FLMLandscapeModuleVisualSafeAreaInsets();
    CGFloat leftX = CGRectGetMinX(expandedFrame);
    CGFloat rightX = CGRectGetWidth(bounds) - safeArea.right - dockWidth;
    rightX = MAX(0.0,
                 MIN(CGRectGetWidth(bounds) - dockWidth, rightX));
    CGFloat topLimit = MAX(0.0, safeArea.top + FLMLandscapeDockTopMargin);
    CGFloat bottomLimit = CGRectGetHeight(bounds) - safeArea.bottom - dockHeight;
    if (bottomLimit < topLimit) {
        topLimit = MAX(0.0,
                       MIN(CGRectGetHeight(bounds) - dockHeight,
                           FLMLandscapeDockTopMargin));
        bottomLimit = topLimit;
    }
    CGFloat topY = topLimit;
    return CGRectMake(floor(onRight ? rightX : leftX), floor(topY),
                      dockWidth, dockHeight);
}

- (void)layoutCardAnimated:(BOOL)animated {
    CGRect expandedFrame = [self expandedCardFrame];
    if (CGRectIsEmpty(expandedFrame)) {
        return;
    }
    CGRect dockedFrame =
        [self dockedCardFrameOnRight:self.dockedOnRight];
    CGRect visibleFrame = self.dockedCard ? dockedFrame : expandedFrame;
    CGRect target = visibleFrame;
    if (self.hiddenCard) {
        // Hidden is a deterministic left-edge state: the app disappears
        // completely and the same handle remains available for a right swipe.
        visibleFrame = [self dockedCardFrameOnRight:NO];
        target = visibleFrame;
        target.origin.x = -CGRectGetWidth(target);
    }
    CGFloat cornerRadius = self.dockedCard
        ? MAX(10.0, 18.0 * CGRectGetWidth(dockedFrame) /
                          MAX(1.0, CGRectGetWidth(expandedFrame)))
        : 18.0;
    void (^layoutBlock)(void) = ^{
        self.cardView.frame = target;
        self.cardView.layer.cornerRadius = cornerRadius;
        // Never pass backdrop touches to the application below. The root
        // window is the modal ownership boundary in every card state.
        self.rootView.passesTouchesOutsideControls = NO;
        self.hostView.userInteractionEnabled =
            !self.dockedCard && !self.hiddenCard;
        self.dockInteractionShield.frame = self.cardView.bounds;
        [self layoutHandleForCardFrame:target visibleFrame:visibleFrame];
        self.launchCoverView.frame = self.cardView.bounds;
        [self configureLocalInteractionState];
        [self layoutHost];
    };
    if (animated) {
        [UIView animateWithDuration:FLMLandscapeOpenAnimationDuration
                              delay:0.0
             usingSpringWithDamping:FLMLandscapeSpringDamping
              initialSpringVelocity:FLMLandscapeSpringVelocity
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseOut |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:layoutBlock
                         completion:nil];
    } else {
        [UIView performWithoutAnimation:layoutBlock];
    }
}

- (void)layoutHandleForCardFrame:(CGRect)cardFrame visibleFrame:(CGRect)visibleFrame {
    BOOL hidden = self.hiddenCard;
    // One physical bar is reused in every state.  It sits to the right of the
    // left/expanded card, to the left of a right-docked card, and at the left
    // screen edge while hidden.
    BOOL barOnRightEdge = self.dockedCard && self.dockedOnRight && !hidden;
    CGFloat x = 0.0;
    if (hidden) {
        // A landscape notch occupies the physical edge. Keep the hidden bar
        // just inside the left safe inset so it remains visible and draggable.
        x = MAX(0.0, FLMLandscapeModuleVisualSafeAreaInsets().left);
    } else if (barOnRightEdge) {
        x = CGRectGetMinX(cardFrame) - FLMLandscapeHandleGap -
            FLMLandscapeHandleWidth;
    } else {
        x = CGRectGetMaxX(cardFrame) + FLMLandscapeHandleGap;
    }
    x = MAX(0.0,
            MIN(CGRectGetWidth(self.displayBounds) - FLMLandscapeHandleWidth,
                x));
    CGFloat height = MAX(72.0, CGRectGetHeight(visibleFrame) * 0.32);
    UIEdgeInsets safeArea = FLMLandscapeModuleVisualSafeAreaInsets();
    CGFloat minimumY = MAX(0.0, safeArea.top);
    CGFloat maximumY = CGRectGetHeight(self.displayBounds) - safeArea.bottom - height;
    if (maximumY < minimumY) {
        minimumY = 0.0;
        maximumY = MAX(0.0, CGRectGetHeight(self.displayBounds) - height);
    }
    CGFloat y = MAX(minimumY,
                    MIN(maximumY,
                        CGRectGetMidY(visibleFrame) - height * 0.5));
    self.handleView.frame = CGRectMake(x, floor(y), FLMLandscapeHandleWidth, height);
    CGFloat barLength = MIN(FLMLandscapeHandleBarLength, height);
    CGFloat barX = barOnRightEdge
        ? FLMLandscapeHandleWidth - FLMLandscapeHandleBarWidth
        : (hidden ? 3.0 : 0.0);
    self.handleBar.frame = CGRectMake(barX,
                                      floor((height - barLength) * 0.5),
                                      FLMLandscapeHandleBarWidth,
                                      barLength);
}

- (void)refreshSceneForeground {
    id scene = self.scene;
    if (!scene || self.closing || !self.hasVisibleCard) {
        return;
    }
    @try {
        id settings = [scene respondsToSelector:@selector(settings)]
                          ? [scene settings]
                          : nil;
        id mutableSettings = [settings mutableCopy];
        if (!mutableSettings && [scene respondsToSelector:@selector(mutableSettings)]) {
            mutableSettings = [scene mutableSettings];
        }
        if (!mutableSettings ||
            ![scene respondsToSelector:@selector(updateSettings:withTransitionContext:)]) {
            return;
        }
        if ([scene respondsToSelector:@selector(activate)]) {
            [scene activate];
        }
        if ([mutableSettings respondsToSelector:@selector(setDeactivationReasons:)]) {
            [mutableSettings setDeactivationReasons:0];
        }
        if ([mutableSettings respondsToSelector:@selector(setForeground:)]) {
            [mutableSettings setForeground:YES];
        }
        if ([mutableSettings respondsToSelector:@selector(setBackgrounded:)]) {
            [mutableSettings setBackgrounded:NO];
        }
        CGRect portraitBounds = FLMLandscapePortraitSceneBounds();
        UIInterfaceOrientation orientation = UIInterfaceOrientationPortrait;
        if (CGRectGetWidth(portraitBounds) > 1.0 &&
            CGRectGetHeight(portraitBounds) > CGRectGetWidth(portraitBounds)) {
            if ([mutableSettings respondsToSelector:@selector(setFrame:)]) {
                [mutableSettings setFrame:portraitBounds];
            }
            if ([mutableSettings respondsToSelector:@selector(setInterfaceOrientation:)]) {
                [mutableSettings setInterfaceOrientation:(NSInteger)orientation];
            }
        }
        [scene updateSettings:mutableSettings withTransitionContext:nil];
        if ([scene respondsToSelector:@selector(activate)]) {
            [scene activate];
        }
        if ([scene respondsToSelector:@selector(setForeground:)]) {
            [scene setForeground:YES];
        }
        if ([scene respondsToSelector:@selector(setBackgrounded:)]) {
            [scene setBackgrounded:NO];
        }
        // The application stays portrait and full-sized. Landscape belongs to
        // the outer SpringBoard workspace and the keyboard forwarding surface.
        BOOL runtimeStateKnown = NO;
        NSInteger activationState = -1;
        BOOL runtimeForeground = FLMLandscapeSceneRuntimeIsForeground(
            scene, &runtimeStateKnown, &activationState);
        if (runtimeStateKnown && !runtimeForeground) {
            FLMEnqueueDiagnosticLine(
                @"sb landscape-scene-foreground reactivation-pending app=%@ activationState=%ld runtime={%@} frontmost=%@",
                self.identifier, (long)activationState,
                FLMLandscapeSceneRuntimeSummary(scene),
                FLMLandscapeFrontmostApplicationIdentifier() ?: @"<none>");
        }
    } @catch (NSException *exception) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-scene-reassert failed app=%@ scene=%@ exception=%@ reason=%@",
            self.identifier, FLMLandscapeSceneIdentifier(scene) ?: @"<none>",
            exception.name ?: @"<none>", exception.reason ?: @"<none>");
    }
}

- (void)setHandleVisible:(BOOL)visible {
    self.handleView.hidden = !visible;
    self.handleView.alpha = visible ? 1.0 : 0.0;
}

- (void)layoutHost {
    if (!self.hostView || self.cardView.bounds.size.width <= 1.0 ||
        self.displayBounds.size.width <= 1.0) {
        return;
    }
    UIView *presentationView = self.hostPresentationView;
    if (!presentationView) {
        return;
    }
    if (self.hostView.superview != presentationView) {
        [self.hostView removeFromSuperview];
        [presentationView addSubview:self.hostView];
    }

    CGRect sceneFrame = FLMLandscapeSceneSettingsFrame(self.scene);
    UIInterfaceOrientation sceneOrientation =
        FLMLandscapeSceneSettingsOrientation(self.scene);
    if (CGRectGetHeight(sceneFrame) <= CGRectGetWidth(sceneFrame) ||
        CGRectGetHeight(sceneFrame) <= 1.0 ||
        sceneOrientation != UIInterfaceOrientationPortrait) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-layout rejected=scene-not-fullscreen-portrait scene=%@ orientation=%ld display=%@",
            NSStringFromCGRect(sceneFrame), (long)sceneOrientation,
            NSStringFromCGRect(self.displayBounds));
        return;
    }

    CGRect nativeHostBounds = CGRectMake(0.0, 0.0,
                                         CGRectGetWidth(sceneFrame),
                                         CGRectGetHeight(sceneFrame));
    CGRect actualHostBounds = self.hostView.bounds;
    if (fabs(CGRectGetWidth(actualHostBounds) -
             CGRectGetWidth(nativeHostBounds)) >= 1.0 ||
        fabs(CGRectGetHeight(actualHostBounds) -
             CGRectGetHeight(nativeHostBounds)) >= 1.0 ||
        !FLMLandscapeTransformIsIdentity(self.hostView.transform)) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-layout rejected=host-not-native actual=%@ expected=%@ transform=%@ action=preserve-app-root",
            NSStringFromCGRect(actualHostBounds),
            NSStringFromCGRect(nativeHostBounds),
            NSStringFromCGAffineTransform(self.hostView.transform));
        return;
    }
    self.expectedHostBounds = nativeHostBounds;
    CGSize cardSize = self.cardView.bounds.size;
    CGSize presentedSize = nativeHostBounds.size;
    CGFloat uniformScale =
        MIN(cardSize.width / presentedSize.width,
            cardSize.height / presentedSize.height);
    uniformScale = MAX(0.01, uniformScale);
    CGFloat visualWidth = presentedSize.width * uniformScale;
    CGFloat visualHeight = presentedSize.height * uniformScale;
    CGFloat visualLetterboxX = MAX(0.0, (cardSize.width - visualWidth) * 0.5);
    CGFloat visualLetterboxY = MAX(0.0, (cardSize.height - visualHeight) * 0.5);
    // The application and Presenter stay identity portrait. Only this
    // SpringBoard-owned wrapper applies one uniform scale into the card.
    presentationView.transform = CGAffineTransformIdentity;
    presentationView.bounds = nativeHostBounds;
    presentationView.center = CGPointMake(cardSize.width * 0.5,
                                           cardSize.height * 0.5);
    self.hostView.transform = CGAffineTransformIdentity;
    self.hostView.bounds = nativeHostBounds;
    self.hostView.center = CGPointMake(CGRectGetMidX(presentationView.bounds),
                                       CGRectGetMidY(presentationView.bounds));
    presentationView.transform =
        CGAffineTransformMakeScale(uniformScale, uniformScale);
    presentationView.hidden = NO;
    self.rootView.hostView = self.hostView;
    FLMLandscapeKeyboardBridgeUpdateCard(
        self.cardView.frame,
        uniformScale,
        !self.dockedCard && !self.hiddenCard && !self.closing);
    FLMEnqueueDiagnosticLine(
        @"sb landscape-visual-card appScene=%@ appOrientation=%ld outerDisplay=%@ outerOrientation=%ld host=%@ hostTransform=identity card=%@ presented={%.1f,%.1f} scale=%.6f letterbox={%.1f,%.1f} visualRotation=0 state=%@",
        NSStringFromCGRect(sceneFrame), (long)sceneOrientation,
        NSStringFromCGRect(self.displayBounds), (long)self.displayOrientation,
        NSStringFromCGRect(self.hostView.bounds),
        NSStringFromCGRect(self.cardView.bounds), presentedSize.width,
        presentedSize.height, uniformScale, visualLetterboxX,
        visualLetterboxY,
        self.hiddenCard ? @"hidden" : (self.dockedCard ? @"docked" : @"expanded"));
}
- (void)outsideTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded || !self.hasVisibleCard ||
        self.dockedCard || self.hiddenCard) {
        return;
    }
    FLMEnqueueDiagnosticLine(@"sb landscape-module-close reason=outside-tap");
    [self closeKeepingApplication:YES];
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    if (!self.hasVisibleCard || FLMLandscapeDeviceIsLocked()) {
        return;
    }
    CGPoint translation = [gesture translationInView:self.rootView];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.handlePanInteractive = YES;
        self.handlePanStartCardFrame = self.cardView.frame;
        self.handlePanStartHandleFrame = self.handleView.frame;
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged &&
        self.handlePanInteractive) {
        CGFloat dx = translation.x;
        if (self.hiddenCard) {
            dx = MAX(0.0, dx);
        } else {
            CGFloat resistanceStart = CGRectGetWidth(self.displayBounds) * 0.42;
            if (dx > resistanceStart) {
                dx = resistanceStart + (dx - resistanceStart) * 0.24;
            }
            dx = MAX(-CGRectGetWidth(self.handlePanStartCardFrame), dx);
        }
        [UIView performWithoutAnimation:^{
            CGRect cardFrame = self.handlePanStartCardFrame;
            cardFrame.origin.x += dx;
            self.cardView.frame = cardFrame;
            CGRect handleFrame = self.handlePanStartHandleFrame;
            handleFrame.origin.x += dx;
            self.handleView.frame = handleFrame;
        }];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        self.handlePanInteractive = NO;
        CGPoint velocity = [gesture velocityInView:self.rootView];
        BOOL cancelled = gesture.state != UIGestureRecognizerStateEnded;
        BOOL moveRight = !cancelled &&
            (translation.x >= FLMLandscapeSwipeThreshold ||
             velocity.x >= FLMLandscapeFastSwipeVelocity);
        BOOL moveLeft = !cancelled &&
            (translation.x <= -FLMLandscapeSwipeThreshold ||
             velocity.x <= -FLMLandscapeFastSwipeVelocity);
        if (self.hiddenCard && moveRight) {
            [self restoreExpandedCardAnimated:YES
                                       reason:@"hidden-bar-right-swipe-fallback"];
        } else if (self.dockedCard && moveLeft) {
            [self hideDockedCardAnimated:YES];
        } else if (!self.dockedCard && !self.hiddenCard && moveLeft) {
            [self dockCardAnimated:YES];
        } else if (!self.dockedCard && !self.hiddenCard && moveRight) {
            [self promoteToFullscreen];
        } else {
            [self layoutCardAnimated:YES];
        }
    }
}

- (void)handleDockPan:(UIPanGestureRecognizer *)gesture {
    if (!self.hasVisibleCard || self.closing || !self.dockedCard ||
        self.hiddenCard || FLMLandscapeDeviceIsLocked()) {
        return;
    }
    CGPoint translation = [gesture translationInView:self.rootView];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.dockPanInteractive = YES;
        self.dockPanStartCardFrame = self.cardView.frame;
        self.dockPanStartHandleFrame = self.handleView.frame;
        FLMEnqueueDiagnosticLine(
            @"sb landscape-card-dock-drag began card=%@ safeArea=%@",
            NSStringFromCGRect(self.dockPanStartCardFrame),
            NSStringFromUIEdgeInsets(FLMLandscapeModuleVisualSafeAreaInsets()));
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged &&
        self.dockPanInteractive) {
        CGRect bounds = self.displayBounds;
        UIEdgeInsets safeArea = FLMLandscapeModuleVisualSafeAreaInsets();
        CGRect frame = self.dockPanStartCardFrame;
        CGFloat minimumX = MAX(0.0, safeArea.left);
        CGFloat maximumX = CGRectGetWidth(bounds) - safeArea.right -
                           CGRectGetWidth(frame);
        CGFloat minimumY = MAX(0.0, safeArea.top);
        CGFloat maximumY = CGRectGetHeight(bounds) - safeArea.bottom -
                           CGRectGetHeight(frame);
        if (maximumX < minimumX) {
            minimumX = 0.0;
            maximumX = MAX(0.0, CGRectGetWidth(bounds) - CGRectGetWidth(frame));
        }
        if (maximumY < minimumY) {
            minimumY = 0.0;
            maximumY = MAX(0.0, CGRectGetHeight(bounds) - CGRectGetHeight(frame));
        }
        frame.origin.x = MAX(minimumX,
                             MIN(maximumX,
                                 self.dockPanStartCardFrame.origin.x +
                                     translation.x));
        frame.origin.y = MAX(minimumY,
                             MIN(maximumY,
                                 self.dockPanStartCardFrame.origin.y +
                                     translation.y));
        self.dockedOnRight = CGRectGetMidX(frame) > CGRectGetMidX(bounds);
        [UIView performWithoutAnimation:^{
            self.cardView.frame = frame;
            self.dockInteractionShield.frame = self.cardView.bounds;
            [self layoutHandleForCardFrame:frame visibleFrame:frame];
            self.launchCoverView.frame = self.cardView.bounds;
        }];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        self.dockPanInteractive = NO;
        if (gesture.state == UIGestureRecognizerStateEnded) {
            // Release always snaps back to the deterministic safe top margin;
            // the drag's vertical position is never persisted.
            [self snapDockedCardAnimated:YES];
        } else {
            [self layoutCardAnimated:YES];
        }
    }
}

- (void)handleDockTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded ||
        !self.hasVisibleCard || self.closing || !self.dockedCard ||
        self.hiddenCard) {
        return;
    }
    [self restoreExpandedCardAnimated:YES reason:@"dock-tap"];
}

- (void)beginExpandedKeyboardSessionIfPossible {
    if (self.keyboardSessionGeneration != 0 || !self.scene || !self.hostView ||
        self.dockedCard || self.hiddenCard || self.closing) {
        return;
    }
    self.keyboardSessionCounter += 1;
    if (self.keyboardSessionCounter == 0) {
        self.keyboardSessionCounter = 1;
    }
    self.keyboardSessionGeneration = self.keyboardSessionCounter;
    FLMLandscapeKeyboardBridgeBegin(self.identifier,
                                    self.scene,
                                    self.keyboardSessionGeneration,
                                    self.window);
    [self layoutHost];
    FLMEnqueueDiagnosticLine(
        @"sb landscape-keyboard session-restarted app=%@ session=%llu state=expanded",
        self.identifier,
        (unsigned long long)self.keyboardSessionGeneration);
}

- (void)endKeyboardSessionForCollapsedState {
    uint64_t session = self.keyboardSessionGeneration;
    if (session == 0) {
        return;
    }
    FLMLandscapeKeyboardBridgeEnd(session);
    self.keyboardSessionGeneration = 0;
    FLMEnqueueDiagnosticLine(
        @"sb landscape-keyboard session-collapsed app=%@ session=%llu",
        self.identifier, (unsigned long long)session);
}

- (void)dockCardAnimated:(BOOL)animated {
    [self.hostView endEditing:YES];
    [self endKeyboardSessionForCollapsedState];
    self.dockedCard = YES;
    self.hiddenCard = NO;
    self.dockedOnRight = NO;
    [self refreshSharedInteractionGestureState];
    [self layoutCardAnimated:animated];
    FLMEnqueueDiagnosticLine(
        @"sb landscape-card-state app=%@ transition=expanded-to-docked side=left verticalPolicy=fixed-top",
        self.identifier);
}

- (void)hideDockedCardAnimated:(BOOL)animated {
    [self.hostView endEditing:YES];
    [self endKeyboardSessionForCollapsedState];
    self.dockedCard = YES;
    self.hiddenCard = YES;
    self.dockedOnRight = NO;
    [self refreshSharedInteractionGestureState];
    [self layoutCardAnimated:animated];
    FLMEnqueueDiagnosticLine(
        @"sb landscape-card-state app=%@ transition=docked-to-hidden side=left appSliver=0 handle=reused",
        self.identifier);
}

- (void)restoreExpandedCardAnimated:(BOOL)animated reason:(NSString *)reason {
    self.dockedCard = NO;
    self.hiddenCard = NO;
    self.dockedOnRight = NO;
    [self refreshSharedInteractionGestureState];
    self.hostView.userInteractionEnabled = YES;
    [self.window makeKeyWindow];
    [self refreshSceneForeground];
    [self beginExpandedKeyboardSessionIfPossible];
    [self layoutCardAnimated:animated];
    FLMEnqueueDiagnosticLine(
        @"sb landscape-card-state app=%@ transition=collapsed-to-expanded reason=%@ side=left",
        self.identifier, reason ?: @"unspecified");
}

- (void)snapDockedCardAnimated:(BOOL)animated {
    if (!self.dockedCard || self.hiddenCard) {
        return;
    }
    CGFloat cardMidX = CGRectGetMidX(self.cardView.frame);
    CGFloat displayMidX = CGRectGetMidX(self.displayBounds);
    // A strict comparison deliberately resolves an exact center-line tie to
    // the left, as specified for the landscape dock.
    self.dockedOnRight = cardMidX > displayMidX;
    [self layoutCardAnimated:animated];
    FLMEnqueueDiagnosticLine(
        @"sb landscape-card-state app=%@ transition=dock-snap side=%@ cardMidX=%.1f displayMidX=%.1f tiePolicy=left verticalPolicy=fixed-top",
        self.identifier, self.dockedOnRight ? @"right" : @"left",
        cardMidX, displayMidX);
}

- (void)promoteToFullscreen {
    if (self.fullscreenPromotionInProgress || self.closing ||
        self.identifier.length == 0) {
        return;
    }
    NSString *identifier = [self.identifier copy];
    self.fullscreenPromotionInProgress = YES;
    [self deactivateSharedInteractionGestures];
    self.handlePan.enabled = NO;
    self.outsideTap.enabled = NO;
    [self.hostView endEditing:YES];
    FLMLandscapeKeyboardBridgeEnd(self.keyboardSessionGeneration);
    self.keyboardSessionGeneration = 0;
    FLMClearProtectedScene(self.scene);
    FLMEnqueueDiagnosticLine(
        @"sb landscape-module-fullscreen begin app=%@ frontmostBefore=%@ source=handle-right-swipe",
        identifier,
        FLMLandscapeFrontmostApplicationIdentifier() ?: @"<none>");
    [UIView animateWithDuration:0.32
                          delay:0.0
         usingSpringWithDamping:0.88
          initialSpringVelocity:0.24
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         self.cardView.transform =
                             CGAffineTransformMakeScale(1.06, 1.06);
                         self.cardView.alpha = 0.0;
                         self.handleView.transform =
                             CGAffineTransformMakeTranslation(18.0, 0.0);
                         self.handleView.alpha = 0.0;
                     }
                     completion:^(__unused BOOL finished) {
                         [self closeKeepingApplication:NO];
                     }];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *application = [UIApplication sharedApplication];
        if ([application respondsToSelector:
                         @selector(launchApplicationWithIdentifier:suspended:)] &&
            [application launchApplicationWithIdentifier:identifier suspended:NO]) {
            return;
        }
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        id workspace = nil;
        if (workspaceClass &&
            [workspaceClass respondsToSelector:@selector(defaultWorkspace)]) {
            id (*getWorkspace)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            workspace = getWorkspace((id)workspaceClass,
                                     @selector(defaultWorkspace));
        }
        if ([workspace respondsToSelector:@selector(openApplicationWithBundleID:)]) {
            BOOL (*openApplication)(id, SEL, NSString *) =
                (BOOL (*)(id, SEL, NSString *))objc_msgSend;
            openApplication(workspace,
                            @selector(openApplicationWithBundleID:),
                            identifier);
        }
    });
}

- (void)closeKeepingApplication:(BOOL)keepApplication {
    if (!self.window || self.window.hidden || self.closing) {
        if (self.sharedInteractionActive &&
            (!self.window || self.window.hidden)) {
            [self deactivateSharedInteractionGestures];
        }
        if (self.queuedIdentifier.length > 0 && FLMLandscapeModuleIsLandscape()) {
            NSString *queued = [self.queuedIdentifier copy];
            self.queuedIdentifier = nil;
            [self openIdentifier:queued];
        }
        return;
    }
    self.closing = YES;
    [self deactivateSharedInteractionGestures];
    self.handlePan.enabled = NO;
    self.outsideTap.enabled = NO;
    [self.lockTimer invalidate];
    self.lockTimer = nil;
    NSUInteger closingGeneration = self.generation;
    uint64_t endingKeyboardSession = self.keyboardSessionGeneration;
    [self.hostView endEditing:YES];
    FLMLandscapeKeyboardBridgeEnd(endingKeyboardSession);
    self.keyboardSessionGeneration = 0;
    [self.hostView removeFromSuperview];
    self.hostView = nil;
    self.hostPresentationView.transform = CGAffineTransformIdentity;
    self.hostPresentationView.bounds = CGRectZero;
    self.rootView.hostView = nil;
    id scene = self.scene;
    id presenter = self.presenter;
    UIWindow *previousKeyWindow = self.previousKeyWindow;
    self.previousKeyWindow = nil;
    FLMEnqueueDiagnosticLine(
        @"sb landscape-content-exit appScene=%@ contract=hosted-portrait outerDisplay=%@ outerOrientation=%ld",
        NSStringFromCGRect(FLMLandscapeSceneSettingsFrame(scene)),
        NSStringFromCGRect(self.displayBounds), (long)self.displayOrientation);
    self.scene = nil;
    self.sceneHandle = nil;
    self.sceneEntity = nil;
    self.presentationManager = nil;
    self.presenter = nil;
    self.presenterScene = nil;
    self.presenterPendingAttempts = 0;
    if (keepApplication) {
        [self backgroundScene:scene];
    } else {
        FLMClearProtectedScene(scene);
    }
    @try {
        if ([presenter respondsToSelector:@selector(deactivate)]) {
            [presenter deactivate];
        }
        if ([presenter respondsToSelector:@selector(invalidate)]) {
            [presenter invalidate];
        }
    } @catch (__unused NSException *exception) {
    }
    if (!self.fullscreenPromotionInProgress && previousKeyWindow &&
        previousKeyWindow != self.window) {
        [previousKeyWindow makeKeyWindow];
    }
    NSString *queued = [self.queuedIdentifier copy];
    self.queuedIdentifier = nil;
    [UIView animateWithDuration:FLMLandscapeCloseAnimationDuration
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseIn
                     animations:^{
                         self.window.alpha = 0.0;
                     }
                     completion:^(__unused BOOL finished) {
                         if (closingGeneration != self.generation) {
                             return;
                         }
                          self.window.hidden = YES;
                          self.window.alpha = 1.0;
                           self.cardView.frame = CGRectZero;
                           self.cardView.alpha = 1.0;
                           self.cardView.transform = CGAffineTransformIdentity;
                            self.handleView.frame = CGRectZero;
                            self.handleView.alpha = 1.0;
                            self.handleView.transform = CGAffineTransformIdentity;
                            self.dockInteractionShield.hidden = YES;
                            self.dockInteractionShield.userInteractionEnabled = NO;
                            self.dockPan.enabled = NO;
                            self.dockTap.enabled = NO;
                            self.identifier = nil;
                           self.dockedCard = NO;
                           self.hiddenCard = NO;
                           self.dockedOnRight = NO;
                           self.expectedHostSceneIdentifier = nil;
                           self.fullscreenPromotionInProgress = NO;
                           self.closing = NO;
                           [self configureLocalInteractionState];
                         FLMEnqueueDiagnosticLine(
                             @"sb landscape-module-close-complete generation=%lu",
                             (unsigned long)closingGeneration);
                         if (queued.length > 0 && FLMLandscapeModuleIsLandscape()) {
                             [self openIdentifier:queued];
                         }
                     }];
}

- (void)backgroundScene:(id)scene {
    if (!scene) {
        FLMClearProtectedScene(nil);
        return;
    }
    // Release SceneLifecycle's foreground lease before issuing the real
    // background/deactivate transaction. Otherwise its frozen portrait guard
    // correctly rewrites the request back to foreground and leaves this
    // landscape Scene active for the next card open.
    FLMClearProtectedScene(scene);
    @try {
        BOOL activeBeforeAvailable = NO;
        BOOL activeBefore =
            FLMLandscapeReadBool(scene, @selector(isActive),
                                 &activeBeforeAvailable);
        id settings = [scene respondsToSelector:@selector(settings)] ? [scene settings] : nil;
        id mutableSettings = [settings mutableCopy];
        if (!mutableSettings && [scene respondsToSelector:@selector(mutableSettings)]) {
            mutableSettings = [scene mutableSettings];
        }
        CGRect bounds = FLMLandscapePortraitSceneBounds();
        if ([mutableSettings respondsToSelector:@selector(setFrame:)]) {
            [mutableSettings setFrame:bounds];
        }
        UIInterfaceOrientation orientation = UIInterfaceOrientationPortrait;
        if ([mutableSettings respondsToSelector:@selector(setInterfaceOrientation:)]) {
            [mutableSettings setInterfaceOrientation:(NSInteger)orientation];
        }
        if ([mutableSettings respondsToSelector:@selector(setForeground:)]) {
            [mutableSettings setForeground:NO];
        }
        if ([mutableSettings respondsToSelector:@selector(setBackgrounded:)]) {
            [mutableSettings setBackgrounded:YES];
        }
        if ([scene respondsToSelector:@selector(updateSettings:withTransitionContext:)]) {
            [scene updateSettings:mutableSettings withTransitionContext:nil];
        }
        if ([scene respondsToSelector:@selector(setForeground:)]) {
            [scene setForeground:NO];
        }
        if ([scene respondsToSelector:@selector(setBackgrounded:)]) {
            [scene setBackgrounded:YES];
        }
        if ([scene respondsToSelector:@selector(deactivate)]) {
            [scene deactivate];
        }
        BOOL activeAfterAvailable = NO;
        BOOL activeAfter =
            FLMLandscapeReadBool(scene, @selector(isActive),
                                 &activeAfterAvailable);
        FLMEnqueueDiagnosticLine(
            @"sb landscape-scene-background app=%@ orientation=%ld activeBefore=%d/%d activeAfter=%d/%d action=deactivate",
            self.identifier ?: @"<none>", (long)orientation,
            activeBefore, activeBeforeAvailable,
            activeAfter, activeAfterAvailable);
    } @catch (NSException *exception) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-scene-background failed app=%@ exception=%@ reason=%@",
            self.identifier ?: @"<none>", exception.name ?: @"<none>",
            exception.reason ?: @"<none>");
    }
}

@end

@implementation FLMLandscapeRootViewController

- (BOOL)shouldAutorotate {
    return NO;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end

void FLMLandscapeModuleStart(void) {
    void (^startBlock)(void) = ^{
        [[FLMLandscapeModule sharedModule] start];
    };
    if ([NSThread isMainThread]) {
        startBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), startBlock);
    }
}

UIView *FLMLandscapeModuleWheelGestureView(void) {
    return [FLMLandscapeModule sharedModule].rootView;
}

void FLMLandscapeModuleUpdateFrames(void) {
    void (^updateBlock)(void) = ^{
        [[FLMLandscapeModule sharedModule] updateFrames];
    };
    if ([NSThread isMainThread]) {
        updateBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), updateBlock);
    }
}

void FLMLandscapeModuleOrientationDidChange(void) {
    [[FLMLandscapeModule sharedModule] orientationDidChange];
}

void FLMLandscapeModuleOpenIdentifier(NSString * _Nonnull identifier) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[FLMLandscapeModule sharedModule] openIdentifier:identifier];
    });
}

void FLMLandscapeModuleClose(BOOL keepApplication) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[FLMLandscapeModule sharedModule] closeKeepingApplication:keepApplication];
    });
}

BOOL FLMLandscapeModuleHasVisibleCard(void) {
    return [[FLMLandscapeModule sharedModule] hasVisibleCard];
}

BOOL FLMLandscapeCardOwnsSharedGesture(
    id _Nullable wheelController,
    UIGestureRecognizer * _Nullable gestureRecognizer) {
    return [[FLMLandscapeModule sharedModule]
        ownsSharedGesture:gestureRecognizer
                 controller:wheelController];
}

BOOL FLMLandscapeCardShouldReceiveSharedTouch(
    id _Nullable wheelController,
    UIGestureRecognizer * _Nullable gestureRecognizer,
    UITouch * _Nullable touch) {
    FLMLandscapeModule *module = [FLMLandscapeModule sharedModule];
    if (![module ownsSharedGesture:gestureRecognizer
                        controller:wheelController]) {
        return NO;
    }
    return [module sharedGesture:gestureRecognizer
              shouldReceiveTouch:touch];
}

BOOL FLMLandscapeCardShouldBeginSharedGesture(
    id _Nullable wheelController,
    UIGestureRecognizer * _Nullable gestureRecognizer) {
    FLMLandscapeModule *module = [FLMLandscapeModule sharedModule];
    if (![module ownsSharedGesture:gestureRecognizer
                        controller:wheelController]) {
        return NO;
    }
    return [module sharedGestureShouldBegin:gestureRecognizer];
}

void FLMLandscapeCardHandleSharedGesture(
    id _Nullable wheelController,
    UIGestureRecognizer * _Nullable gestureRecognizer) {
    FLMLandscapeModule *module = [FLMLandscapeModule sharedModule];
    if (![module ownsSharedGesture:gestureRecognizer
                        controller:wheelController]) {
        return;
    }
    [module handleSharedGesture:gestureRecognizer];
}
