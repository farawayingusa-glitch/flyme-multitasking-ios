#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/message.h>

#import "FLMDiagnostics.h"
#import "FLMSceneLifecycle.h"
#import "FLMLandscapeModule.h"

static const CGFloat FLMLandscapeDefaultTriggerSize = 58.0;
static const CGFloat FLMLandscapeMinimumTriggerSize = 36.0;
static const CGFloat FLMLandscapeMaximumTriggerSize = 96.0;
// The target application Scene remains a real full-screen landscape surface.
// The portrait-shaped card is only a SpringBoard presentation surface.
static const CGFloat FLMLandscapeFullScreenContentWidth = 844.0;
static const CGFloat FLMLandscapeFullScreenContentHeight = 390.0;
// Keep the visual card at the iPhone 13 Pro portrait aspect ratio.
static const CGFloat FLMLandscapePortraitCardWidthToHeightRatio =
    390.0 / 844.0;
static const CGFloat FLMLandscapeCardMaximumHeightRatio = 0.92;
static const CGFloat FLMLandscapeHandleWidth = 44.0;
static const CGFloat FLMLandscapeHandleBarWidth = 5.0;
static const CGFloat FLMLandscapeSwipeThreshold = 32.0;
static const CGFloat FLMLandscapeHiddenRevealWidth = 8.0;
static const NSTimeInterval FLMLandscapeResolveInterval = 0.05;
static const NSTimeInterval FLMLandscapeResolveTimeout = 6.5;
static const NSTimeInterval FLMLandscapeCloseAnimationDuration = 0.18;
static const NSTimeInterval FLMLandscapeOpenAnimationDuration = 0.22;

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
@end

@interface FLMLandscapeWindow : UIWindow
@end

@interface FLMLandscapeRootViewController : UIViewController
@end

@interface FLMLandscapeModule : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, strong) FLMLandscapeWindow *window;
@property(nonatomic, strong) FLMLandscapeRootView *rootView;
@property(nonatomic, strong) UIView *cardView;
// The application presentation host stays a native full-screen landscape
// surface. This wrapper is the only layer allowed to carry the card's visual
// transform; UIKit and the keyboard never receive the card transform.
@property(nonatomic, strong) UIView *hostPresentationView;
@property(nonatomic, strong) UIView *hostView;
@property(nonatomic, strong) UIView *handleView;
@property(nonatomic, strong) UIView *handleBar;
@property(nonatomic, strong) UIView *launchCoverView;
@property(nonatomic, strong) UITapGestureRecognizer *outsideTap;
@property(nonatomic, strong) UIPanGestureRecognizer *handlePan;
@property(nonatomic, strong) NSTimer *resolveTimer;
@property(nonatomic, strong) NSTimer *lockTimer;
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
@property(nonatomic, assign) NSTimeInterval openedAt;
@property(nonatomic, assign) NSTimeInterval scenePreparedAt;
@property(nonatomic, assign) CGRect expectedHostBounds;
@property(nonatomic, assign) uint64_t expectedHostGeneration;
@property(nonatomic, copy) NSString *expectedHostSceneIdentifier;
@property(nonatomic, assign) BOOL hiddenCard;
@property(nonatomic, assign) BOOL closing;
@property(nonatomic, assign) BOOL handleDecisionMade;
@property(nonatomic, assign) BOOL started;
@property(nonatomic, copy) NSString *queuedIdentifier;
+ (instancetype)sharedModule;
- (void)start;
- (void)updateFrames;
- (void)orientationDidChange;
- (void)openIdentifier:(NSString *)identifier;
- (void)activateIdentifier:(NSString *)identifier;
- (void)closeKeepingApplication:(BOOL)keepApplication;
- (void)refreshSceneForeground;
- (BOOL)validateHostGeometry;
- (BOOL)hasVisibleCard;
@end

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

static BOOL FLMLandscapeSceneHasNativeLandscapeSettings(id scene) {
    CGRect frame = FLMLandscapeSceneSettingsFrame(scene);
    UIInterfaceOrientation orientation =
        FLMLandscapeSceneSettingsOrientation(scene);
    return CGRectGetWidth(frame) > CGRectGetHeight(frame) &&
           CGRectGetWidth(frame) > 1.0 && CGRectGetHeight(frame) > 1.0 &&
           UIInterfaceOrientationIsLandscape(orientation);
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

UIInterfaceOrientation FLMLandscapeModuleVisualOrientation(void) {
    return FLMLandscapeInterfaceOrientation();
}

UIEdgeInsets FLMLandscapeModuleVisualSafeAreaInsets(void) {
    UIEdgeInsets result = UIEdgeInsetsZero;
    UIWindowScene *scene = FLMLandscapeWindowScene();
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    if (scene) {
        [windows addObjectsFromArray:scene.windows];
    }
    UIWindow *moduleWindow = [FLMLandscapeModule sharedModule].window;
    if (moduleWindow && ![windows containsObject:moduleWindow]) {
        [windows addObject:moduleWindow];
    }

    // The module window is sometimes the only window whose safe-area has
    // already settled when the first landscape touch arrives. Include it
    // explicitly, then use the largest edge reported by the scene windows so
    // the notch inset is still available while SpringBoard is transitioning.
    for (UIWindow *window in windows) {
        if (![window isKindOfClass:[UIWindow class]]) {
            continue;
        }
        UIEdgeInsets candidate = window.safeAreaInsets;
        result.left = MAX(result.left, candidate.left);
        result.right = MAX(result.right, candidate.right);
        result.top = MAX(result.top, candidate.top);
        result.bottom = MAX(result.bottom, candidate.bottom);
        UIView *rootView = window.rootViewController.view;
        if (rootView) {
            candidate = rootView.safeAreaInsets;
            result.left = MAX(result.left, candidate.left);
            result.right = MAX(result.right, candidate.right);
            result.top = MAX(result.top, candidate.top);
            result.bottom = MAX(result.bottom, candidate.bottom);
        }
    }
    return result;
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
    NSArray<NSString *> *domains = @[
        @"com.codex.flymelandscape",
        @"com.codex.flymemultitasking",
    ];
    id value = nil;
    for (NSString *domain in domains) {
        CFPreferencesSynchronize((__bridge CFStringRef)domain,
                                 kCFPreferencesCurrentUser,
                                 kCFPreferencesAnyHost);
        value = CFBridgingRelease(CFPreferencesCopyAppValue(
            CFSTR("cornerTriggerSizeV2"), (__bridge CFStringRef)domain));
        if (value != nil) {
            break;
        }
    }
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
        // UIView conversion applies the inverse of the visual-only card
        // container rotation/scale, returning coordinates in the real
        // full-screen landscape Scene.
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
    CGFloat scale = MIN(cardSize.width / FLMLandscapeFullScreenContentHeight,
                        cardSize.height / FLMLandscapeFullScreenContentWidth);
    scale = MAX(0.05, scale);
    CGFloat renderedWidth = FLMLandscapeFullScreenContentHeight * scale;
    CGFloat renderedHeight = FLMLandscapeFullScreenContentWidth * scale;
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
                @"sb miniwindow-touch screen={%.1f,%.1f} logical={%.1f,%.1f} scale=%.6f rotation=0",
                screenPoint.x, screenPoint.y,
                logicalPoint.x, logicalPoint.y, scale);
            break;
        }
    }
    if (hit) {
        return hit;
    }
    return self;
}

@end

@implementation FLMLandscapeWindow

- (BOOL)canBecomeKeyWindow {
    // The target application Scene, not the SpringBoard card window, owns
    // first responder and keyboard focus. The card remains visible and
    // touchable without entering the system keyboard responder chain.
    return NO;
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
    // Keep the visual card below the native keyboard surface. It is a
    // presentation window only and must not win key-window arbitration.
    window.windowLevel = UIWindowLevelAlert + 92.0;
    window.backgroundColor = [UIColor clearColor];
    FLMLandscapeRootViewController *controller =
        [[FLMLandscapeRootViewController alloc] init];
    FLMLandscapeRootView *root =
        [[FLMLandscapeRootView alloc] initWithFrame:bounds];
    root.backgroundColor = [UIColor clearColor];
    controller.view = root;
    window.rootViewController = controller;
    window.hidden = YES;

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
    cover.userInteractionEnabled = NO;
    [card addSubview:cover];

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

    self.window = window;
    self.rootView = root;
    self.cardView = card;
    self.hostPresentationView = hostPresentation;
    self.hostView = nil;
    self.handleView = handle;
    self.handleBar = bar;
    self.launchCoverView = cover;
    self.outsideTap = outsideTap;
    self.handlePan = pan;
    root.cardView = card;
    root.handleView = handle;
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
        @"sb host-geometry-mismatch generation=%lu expectedContent=%@ actualHost=%@ expectedScene=%@ actualScene=%@ hostTransform=%@ hostPresentation=%d action=visual-relayout",
        (unsigned long)self.generation,
        NSStringFromCGRect(self.expectedHostBounds), NSStringFromCGRect(actual),
        self.expectedHostSceneIdentifier ?: @"<none>",
        sceneIdentifier ?: @"<none>", NSStringFromCGAffineTransform(hostTransform),
        hostAttachedToPresentation);
    [self layoutHost];
    return YES;
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
    self.openedAt = CACurrentMediaTime();
    self.scenePreparedAt = 0.0;
    self.expectedHostBounds = CGRectMake(0.0, 0.0,
                                         FLMLandscapeFullScreenContentWidth,
                                         FLMLandscapeFullScreenContentHeight);
    self.expectedHostGeneration = self.generation;
    self.expectedHostSceneIdentifier = nil;
    self.hiddenCard = NO;
    self.handleDecisionMade = NO;
    self.closing = NO;
    self.displayBounds = FLMLandscapeModuleVisualBounds();
    self.displayOrientation = FLMLandscapeInterfaceOrientation();
    self.window.frame = self.displayBounds;
    self.rootView.bounds = CGRectMake(0.0,
                                      0.0,
                                      CGRectGetWidth(self.displayBounds),
                                      CGRectGetHeight(self.displayBounds));
    self.rootView.frame = self.rootView.bounds;
    self.window.hidden = NO;
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
    UIEdgeInsets safeArea = FLMLandscapeModuleVisualSafeAreaInsets();
    FLMEnqueueDiagnosticLine(
        @"sb landscape-environment display={%.1f,%.1f} orientation=%ld safeArea={%.1f,%.1f,%.1f,%.1f}",
        self.displayBounds.size.width, self.displayBounds.size.height,
        (long)self.displayOrientation, safeArea.top, safeArea.left,
        safeArea.bottom, safeArea.right);
    FLMEnqueueDiagnosticLine(
        @"sb landscape-content-contract scene={%.1f,%.1f} orientation=%ld mode=full-screen-native",
        self.displayBounds.size.width, self.displayBounds.size.height,
        (long)self.displayOrientation);
    FLMEnqueueDiagnosticLine(
        @"sb landscape-module-open app=%@ generation=%lu bounds=%@ orientation=%ld card=%@ safeAreaLeft=%.1f safeAreaRight=%.1f",
        self.identifier, (unsigned long)self.generation,
        NSStringFromCGRect(self.displayBounds), (long)self.displayOrientation,
        NSStringFromCGRect(target), safeArea.left, safeArea.right);
    [self activateIdentifier:self.identifier];
    [self.lockTimer invalidate];
    self.lockTimer = [NSTimer timerWithTimeInterval:0.25
                                             target:self
                                           selector:@selector(lockTimerFired:)
                                           userInfo:nil
                                            repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.lockTimer forMode:NSRunLoopCommonModes];
    [self scheduleResolveForGeneration:self.generation delay:0.0];
}

- (void)lockTimerFired:(NSTimer *)timer {
    (void)timer;
    if (self.hasVisibleCard) {
        NSString *frontmostIdentifier =
            FLMLandscapeFrontmostApplicationIdentifier();
        if (frontmostIdentifier.length > 0 &&
            ![frontmostIdentifier isEqualToString:self.identifier]) {
            [self activateIdentifier:self.identifier];
        }
        // SceneLifecycle protects this scene from normal deactivation. Reassert
        // the foreground contract while the independent landscape card lives.
        [self refreshSceneForeground];
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
            @"sb landscape-host-timeout generation=%lu contract=full-screen-landscape",
            (unsigned long)self.generation);
        [self closeKeepingApplication:YES];
    }
}

- (void)activateIdentifier:(NSString *)identifier {
    if (identifier.length == 0) {
        return;
    }
    UIApplication *application = [UIApplication sharedApplication];
    BOOL launchRequested = NO;
    if ([application respondsToSelector:
                         @selector(launchApplicationWithIdentifier:suspended:)]) {
        // The landscape card is only a visual presentation. The target app
        // must be a real foreground application so UIKit attaches the native
        // keyboard to its full-screen landscape Scene.
        launchRequested =
            [application launchApplicationWithIdentifier:identifier
                                                suspended:NO];
    }
    BOOL workspaceRequested = NO;
    if (!launchRequested) {
        Class workspaceClass = NSClassFromString(@"SBMainWorkspace");
        id workspace =
            [workspaceClass respondsToSelector:@selector(sharedInstance)]
                ? [workspaceClass sharedInstance]
                : nil;
        if ([workspace respondsToSelector:@selector(openApplicationWithBundleID:)]) {
            workspaceRequested =
                [workspace openApplicationWithBundleID:identifier];
        }
    }
    FLMEnqueueDiagnosticLine(
        @"sb landscape-scene-activate app=%@ suspended=0 launchRequested=%d workspaceRequested=%d frontmost=%@",
        identifier, launchRequested, workspaceRequested,
        FLMLandscapeFrontmostApplicationIdentifier() ?: @"<none>");
}

- (void)scheduleResolveForGeneration:(NSUInteger)generation delay:(NSTimeInterval)delay {
    [self.resolveTimer invalidate];
    self.resolveTimer = nil;
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
    if (generation != self.generation || self.closing ||
        !FLMLandscapeModuleIsLandscape() || FLMLandscapeDeviceIsLocked()) {
        return;
    }
    if (CACurrentMediaTime() - self.openedAt > FLMLandscapeResolveTimeout) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-module-open timeout app=%@ generation=%lu",
            self.identifier, (unsigned long)generation);
        [self closeKeepingApplication:YES];
        return;
    }
    if (!self.sceneHandle) {
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
        if (application && allocatedEntity &&
            [allocatedEntity respondsToSelector:initializer]) {
            BOOL generate = CACurrentMediaTime() - self.openedAt >= 0.75;
            id entity = [(FLMLandscapeSceneEntity *)allocatedEntity
                initWithApplicationForMainDisplay:application
                generatingNewPrimarySceneIfRequired:generate];
            id handle = [entity respondsToSelector:@selector(sceneHandle)]
                            ? [entity sceneHandle]
                            : nil;
            id scene = FLMLandscapeSceneForHandle(handle);
            if (entity && handle) {
                self.sceneEntity = entity;
                self.sceneHandle = handle;
            }
            if (scene) {
                self.scene = scene;
            }
        }
    }
    id scene = self.scene ?: FLMLandscapeSceneForHandle(self.sceneHandle);
    if (!scene) {
        [self scheduleResolveForGeneration:generation delay:FLMLandscapeResolveInterval];
        return;
    }
    if (!self.scenePreparedAt || self.scene != scene) {
        self.scene = scene;
        if (![self prepareScene:scene handle:self.sceneHandle]) {
            [self scheduleResolveForGeneration:generation delay:FLMLandscapeResolveInterval];
            return;
        }
        self.scenePreparedAt = CACurrentMediaTime();
        self.presenter = nil;
        self.presentationManager = nil;
        self.presenterScene = nil;
        // The Scene itself is the readiness contract. The application remains
        // full-screen landscape; only the presenter view is transformed
        // inside the visual card.
        [self scheduleResolveForGeneration:generation delay:0.0];
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
    if (!FLMLandscapeSceneHasNativeLandscapeSettings(scene)) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-scene-ready rejected=not-native-landscape app=%@ frame=%@ orientation=%ld runtime={%@}",
            self.identifier, NSStringFromCGRect(FLMLandscapeSceneSettingsFrame(scene)),
            (long)FLMLandscapeSceneSettingsOrientation(scene),
            FLMLandscapeSceneRuntimeSummary(scene));
        [self refreshSceneForeground];
        [self scheduleResolveForGeneration:generation
                                      delay:FLMLandscapeResolveInterval];
        return;
    }
    id manager = self.presentationManager;
    if (!manager && [scene respondsToSelector:@selector(uiPresentationManager)]) {
        manager = [scene uiPresentationManager];
    }
    if (!manager && [scene respondsToSelector:@selector(presentationManager)]) {
        manager = [scene presentationManager];
    }
    self.presentationManager = manager;
    if (!self.presenter && [manager respondsToSelector:@selector(createPresenterWithIdentifier:)]) {
        self.presenter = [manager createPresenterWithIdentifier:
                                   @"com.codex.flymemultitasking.landscape"];
        if ([self.presenter respondsToSelector:@selector(activate)]) {
            [self.presenter activate];
        }
    }
    UIView *host = [self.presenter respondsToSelector:@selector(presentationView)]
                       ? [self.presenter presentationView]
                       : nil;
    if (![host isKindOfClass:[UIView class]]) {
        [self scheduleResolveForGeneration:generation delay:FLMLandscapeResolveInterval];
        return;
    }
    CGRect initialHostBounds = host.bounds;
    BOOL initialHostHasGeometry = CGRectGetWidth(initialHostBounds) > 1.0 &&
                                  CGRectGetHeight(initialHostBounds) > 1.0;
    if (initialHostHasGeometry &&
        (CGRectGetWidth(initialHostBounds) <= CGRectGetHeight(initialHostBounds) ||
         !FLMLandscapeTransformIsIdentity(host.transform))) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-host-rejected reason=non-native-host hostBounds=%@ hostTransform=%@ sceneFrame=%@ sceneOrientation=%ld runtime={%@}",
            NSStringFromCGRect(initialHostBounds),
            NSStringFromCGAffineTransform(host.transform),
            NSStringFromCGRect(FLMLandscapeSceneSettingsFrame(scene)),
            (long)FLMLandscapeSceneSettingsOrientation(scene),
            FLMLandscapeSceneRuntimeSummary(scene));
        [self scheduleResolveForGeneration:generation
                                      delay:FLMLandscapeResolveInterval];
        return;
    }
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
    CGRect sceneFrame = FLMLandscapeSceneSettingsFrame(scene);
    if (CGRectGetWidth(sceneFrame) <= 1.0 || CGRectGetHeight(sceneFrame) <= 1.0) {
        sceneFrame = self.displayBounds;
    }
    self.expectedHostBounds = CGRectMake(0.0, 0.0,
                                         CGRectGetWidth(sceneFrame),
                                         CGRectGetHeight(sceneFrame));
    self.expectedHostGeneration = generation;
    self.expectedHostSceneIdentifier = FLMLandscapeSceneIdentifier(scene);
    host.hidden = NO;
    host.transform = CGAffineTransformIdentity;
    [self layoutHost];
    self.launchCoverView.hidden = YES;
    self.launchCoverView.alpha = 1.0;
    FLMEnqueueDiagnosticLine(
        @"sb host-attach generation=%lu contentContract=full-screen-landscape host=%@ expectedScene=%@",
        (unsigned long)generation, NSStringFromCGRect(host.bounds),
        NSStringFromCGRect(self.expectedHostBounds));
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
    @try {
        CGRect systemBounds = self.displayBounds;
        if (CGRectGetWidth(systemBounds) <= 1.0 ||
            CGRectGetHeight(systemBounds) <= 1.0) {
            systemBounds = FLMLandscapeModuleVisualBounds();
        }
        if (CGRectGetWidth(systemBounds) < CGRectGetHeight(systemBounds)) {
            systemBounds.size = CGSizeMake(CGRectGetHeight(systemBounds),
                                           CGRectGetWidth(systemBounds));
        }
        systemBounds.origin = CGPointZero;
        UIInterfaceOrientation orientation = self.displayOrientation;
        if (!UIInterfaceOrientationIsLandscape(orientation)) {
            orientation = FLMLandscapeModuleVisualOrientation();
        }
        if (!UIInterfaceOrientationIsLandscape(orientation)) {
            FLMClearProtectedScene(scene);
            return NO;
        }

        if ([scene respondsToSelector:@selector(_setContentState:)]) {
            [scene _setContentState:2];
        }
        if ([scene respondsToSelector:@selector(activate)]) {
            [scene activate];
        }

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
            [mutableSettings setFrame:systemBounds];
        }
        if ([mutableSettings respondsToSelector:@selector(setInterfaceOrientation:)]) {
            [mutableSettings setInterfaceOrientation:(NSInteger)orientation];
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

        // A settings transaction can be applied asynchronously. Commit the
        // same full-display contract once more, but never replace it with the
        // card's portrait geometry while waiting for the Scene to settle.
        id committedSettings = [scene respondsToSelector:@selector(settings)]
                                   ? [[scene settings] mutableCopy]
                                   : nil;
        if (!committedSettings && [scene respondsToSelector:@selector(mutableSettings)]) {
            committedSettings = [scene mutableSettings];
        }
        if (committedSettings) {
            if ([committedSettings respondsToSelector:@selector(setDeactivationReasons:)]) {
                [committedSettings setDeactivationReasons:0];
            }
            if ([committedSettings respondsToSelector:@selector(setForeground:)]) {
                [committedSettings setForeground:YES];
            }
            if ([committedSettings respondsToSelector:@selector(setBackgrounded:)]) {
                [committedSettings setBackgrounded:NO];
            }
            if ([committedSettings respondsToSelector:@selector(setFrame:)]) {
                [committedSettings setFrame:systemBounds];
            }
            if ([committedSettings respondsToSelector:@selector(setInterfaceOrientation:)]) {
                [committedSettings setInterfaceOrientation:(NSInteger)orientation];
            }
            [scene updateSettings:committedSettings withTransitionContext:nil];
        }
        if ([scene respondsToSelector:@selector(activate)]) {
            [scene activate];
        }

        CGRect appliedFrame = FLMLandscapeSceneSettingsFrame(scene);
        UIInterfaceOrientation appliedOrientation =
            FLMLandscapeSceneSettingsOrientation(scene);
        BOOL nativeLandscape =
            CGRectGetWidth(appliedFrame) > CGRectGetHeight(appliedFrame) &&
            CGRectGetWidth(appliedFrame) > 1.0 &&
            CGRectGetHeight(appliedFrame) > 1.0 &&
            UIInterfaceOrientationIsLandscape(appliedOrientation);
        BOOL runtimeStateKnown = NO;
        NSInteger activationState = -1;
        BOOL runtimeForeground = FLMLandscapeSceneRuntimeIsForeground(
            scene, &runtimeStateKnown, &activationState);
        FLMEnqueueDiagnosticLine(
            @"sb landscape-scene-contract app=%@ systemFrame=%@ requestedOrientation=%ld appliedFrame=%@ appliedOrientation=%ld nativeLandscape=%d runtimeForeground=%d/%d activationState=%ld contract=full-screen-scene-card-visual-only",
            self.identifier, NSStringFromCGRect(systemBounds),
            (long)orientation, NSStringFromCGRect(appliedFrame),
            (long)appliedOrientation, nativeLandscape,
            runtimeForeground, runtimeStateKnown, (long)activationState);
        if (!nativeLandscape ||
            (runtimeStateKnown && !runtimeForeground)) {
            return NO;
        }
        return YES;
    } @catch (__unused NSException *exception) {
        FLMClearProtectedScene(scene);
        return NO;
    }
}
- (void)layoutCardAnimated:(BOOL)animated {
    CGRect bounds = self.displayBounds;
    CGFloat displayWidth = CGRectGetWidth(bounds);
    CGFloat displayHeight = CGRectGetHeight(bounds);
    if (displayWidth <= displayHeight || displayWidth <= 1.0 || displayHeight <= 1.0) {
        return;
    }
    CGFloat cardHeight = displayHeight * FLMLandscapeCardMaximumHeightRatio;
    CGFloat cardWidth = cardHeight *
                        FLMLandscapePortraitCardWidthToHeightRatio;
    UIEdgeInsets safeArea = FLMLandscapeModuleVisualSafeAreaInsets();
    CGFloat maximumCardOriginX = MAX(0.0, displayWidth - cardWidth);
    CGFloat cardOriginX = MAX(0.0, MIN(maximumCardOriginX, safeArea.left));
    CGRect visibleFrame = CGRectMake(floor(cardOriginX),
                                     floor((displayHeight - cardHeight) * 0.5),
                                     floor(cardWidth),
                                     floor(cardHeight));
    CGRect target = self.hiddenCard
        ? CGRectMake(CGRectGetMinX(visibleFrame) -
                         CGRectGetWidth(visibleFrame) +
                         FLMLandscapeHiddenRevealWidth,
                     CGRectGetMinY(visibleFrame),
                     CGRectGetWidth(visibleFrame),
                     CGRectGetHeight(visibleFrame))
        : visibleFrame;
    void (^layoutBlock)(void) = ^{
        self.cardView.frame = target;
        self.cardView.layer.cornerRadius = 18.0;
        [self layoutHandleForCardFrame:target visibleFrame:visibleFrame];
        self.launchCoverView.frame = self.cardView.bounds;
    };
    if (animated) {
        [UIView animateWithDuration:FLMLandscapeOpenAnimationDuration
                              delay:0.0
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
    // Keep the reveal handle on the safe side of the left notch as well. The
    // card is always a left-attached landscape card, so visibleFrame already
    // contains the horizontal safe-area correction calculated above.
    CGFloat x = hidden ? MAX(0.0, CGRectGetMinX(visibleFrame))
                       : CGRectGetMaxX(cardFrame);
    CGFloat y = CGRectGetMidY(visibleFrame) - CGRectGetHeight(visibleFrame) * 0.16;
    CGFloat height = CGRectGetHeight(visibleFrame) * 0.32;
    self.handleView.frame = CGRectMake(x, floor(y), FLMLandscapeHandleWidth, height);
    self.handleBar.frame = CGRectMake(0.0,
                                      floor((height - 5.0) * 0.5),
                                      FLMLandscapeHandleBarWidth,
                                      5.0);
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
        CGRect visualBounds = self.displayBounds;
        UIInterfaceOrientation orientation = self.displayOrientation;
        if (CGRectGetWidth(visualBounds) > 1.0 &&
            CGRectGetHeight(visualBounds) > 1.0 &&
            UIInterfaceOrientationIsLandscape(orientation)) {
            if ([mutableSettings respondsToSelector:@selector(setFrame:)]) {
                [mutableSettings setFrame:visualBounds];
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
    } @catch (__unused NSException *exception) {
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
    if (CGRectGetWidth(sceneFrame) <= CGRectGetHeight(sceneFrame) ||
        CGRectGetHeight(sceneFrame) <= 1.0 ||
        !UIInterfaceOrientationIsLandscape(sceneOrientation)) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-layout rejected=scene-not-fullscreen-landscape scene=%@ orientation=%ld display=%@",
            NSStringFromCGRect(sceneFrame), (long)sceneOrientation,
            NSStringFromCGRect(self.displayBounds));
        return;
    }

    self.expectedHostBounds = CGRectMake(0.0, 0.0,
                                         CGRectGetWidth(sceneFrame),
                                         CGRectGetHeight(sceneFrame));
    CGSize cardSize = self.cardView.bounds.size;
    CGFloat uniformScale =
        MIN(cardSize.width / CGRectGetHeight(sceneFrame),
            cardSize.height / CGRectGetWidth(sceneFrame));
    uniformScale = MAX(0.01, uniformScale);
    CGFloat visualWidth = CGRectGetHeight(sceneFrame) * uniformScale;
    CGFloat visualHeight = CGRectGetWidth(sceneFrame) * uniformScale;
    CGFloat visualLetterboxX = MAX(0.0, (cardSize.width - visualWidth) * 0.5);
    CGFloat visualLetterboxY = MAX(0.0, (cardSize.height - visualHeight) * 0.5);

    // Only this SpringBoard-owned wrapper is transformed. The hosted Scene
    // remains an identity 844x390 landscape surface; UIKit, first-responder
    // routing, and the native keyboard never see the card's portrait frame.
    presentationView.transform = CGAffineTransformIdentity;
    presentationView.bounds = sceneFrame;
    presentationView.center = CGPointMake(cardSize.width * 0.5,
                                           cardSize.height * 0.5);
    self.hostView.transform = CGAffineTransformIdentity;
    self.hostView.bounds = sceneFrame;
    self.hostView.center = CGPointMake(CGRectGetMidX(presentationView.bounds),
                                       CGRectGetMidY(presentationView.bounds));
    CGFloat visualRotation = sceneOrientation == UIInterfaceOrientationLandscapeRight
                                 ? -M_PI_2
                                 : M_PI_2;
    presentationView.transform =
        CGAffineTransformRotate(CGAffineTransformMakeScale(uniformScale,
                                                            uniformScale),
                                visualRotation);
    presentationView.hidden = NO;
    self.rootView.hostView = self.hostView;
    FLMEnqueueDiagnosticLine(
        @"sb landscape-visual-card systemScene=%@ host=%@ hostTransform=identity card=%@ visualSurface={%.1f,%.1f} scale=%.6f letterbox={%.1f,%.1f} visualRotation=%.0f keyboardContract=native-scene",
        NSStringFromCGRect(sceneFrame), NSStringFromCGRect(self.hostView.bounds),
        NSStringFromCGRect(self.cardView.bounds), visualWidth, visualHeight,
        uniformScale, visualLetterboxX, visualLetterboxY,
        visualRotation * 180.0 / M_PI);
}
- (void)outsideTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded || !self.hasVisibleCard ||
        self.hiddenCard) {
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
        self.handleDecisionMade = NO;
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged &&
        !self.handleDecisionMade) {
        if (translation.x <= -FLMLandscapeSwipeThreshold) {
            self.handleDecisionMade = YES;
            [self hideCardAnimated:YES];
        } else if (translation.x >= FLMLandscapeSwipeThreshold) {
            self.handleDecisionMade = YES;
            [self promoteToFullscreen];
        }
        return;
    }
    if ((gesture.state == UIGestureRecognizerStateEnded ||
         gesture.state == UIGestureRecognizerStateCancelled) &&
        !self.handleDecisionMade) {
        if (self.hiddenCard && translation.x > FLMLandscapeSwipeThreshold * 0.5) {
            [self revealCardAnimated:YES];
        }
        self.handleDecisionMade = NO;
    }
}

- (void)hideCardAnimated:(BOOL)animated {
    self.hiddenCard = YES;
    [self layoutCardAnimated:animated];
    self.handleDecisionMade = NO;
    FLMEnqueueDiagnosticLine(@"sb landscape-module-hidden app=%@", self.identifier);
}

- (void)revealCardAnimated:(BOOL)animated {
    self.hiddenCard = NO;
    [self layoutCardAnimated:animated];
    self.handleDecisionMade = NO;
    FLMEnqueueDiagnosticLine(@"sb landscape-module-revealed app=%@", self.identifier);
}

- (void)promoteToFullscreen {
    NSString *identifier = [self.identifier copy];
    FLMEnqueueDiagnosticLine(@"sb landscape-module-fullscreen app=%@", identifier);
    [self closeKeepingApplication:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
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
        if (self.queuedIdentifier.length > 0 && FLMLandscapeModuleIsLandscape()) {
            NSString *queued = [self.queuedIdentifier copy];
            self.queuedIdentifier = nil;
            [self openIdentifier:queued];
        }
        return;
    }
    self.closing = YES;
    [self.lockTimer invalidate];
    self.lockTimer = nil;
    NSUInteger closingGeneration = self.generation;
    [self.resolveTimer invalidate];
    self.resolveTimer = nil;
    [self.hostView removeFromSuperview];
    self.hostView = nil;
    self.hostPresentationView.transform = CGAffineTransformIdentity;
    self.hostPresentationView.bounds = CGRectZero;
    self.rootView.hostView = nil;
    id scene = self.scene;
    id presenter = self.presenter;
    FLMEnqueueDiagnosticLine(
        @"sb landscape-content-exit scene={%.1f,%.1f} contract=full-screen-landscape orientation=%ld",
        self.displayBounds.size.width, self.displayBounds.size.height,
        (long)self.displayOrientation);
    self.scene = nil;
    self.sceneHandle = nil;
    self.sceneEntity = nil;
    self.presentationManager = nil;
    self.presenter = nil;
    self.presenterScene = nil;
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
                          self.handleView.frame = CGRectZero;
                          self.identifier = nil;
                          self.hiddenCard = NO;
                          self.expectedHostSceneIdentifier = nil;
                          self.closing = NO;
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
    @try {
        id settings = [scene respondsToSelector:@selector(settings)] ? [scene settings] : nil;
        id mutableSettings = [settings mutableCopy];
        if (!mutableSettings && [scene respondsToSelector:@selector(mutableSettings)]) {
            mutableSettings = [scene mutableSettings];
        }
        CGRect bounds = FLMLandscapeModuleVisualBounds();
        if ([mutableSettings respondsToSelector:@selector(setFrame:)]) {
            [mutableSettings setFrame:bounds];
        }
        UIInterfaceOrientation orientation = FLMLandscapeInterfaceOrientation();
        if (UIInterfaceOrientationIsLandscape(orientation) &&
            [mutableSettings respondsToSelector:@selector(setInterfaceOrientation:)]) {
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
    } @catch (__unused NSException *exception) {
    }
    FLMClearProtectedScene(scene);
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
