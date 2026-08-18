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
static const CGFloat FLMLandscapeCardWidthRatio = 0.50;
static const CGFloat FLMLandscapeCardMinimumWidth = 168.0;
static const CGFloat FLMLandscapeCardMaximumWidth = 240.0;
static const CGFloat FLMLandscapeCardMaximumHeightRatio = 0.92;
static const CGFloat FLMLandscapeHandleWidth = 44.0;
static const CGFloat FLMLandscapeHandleBarWidth = 5.0;
static const CGFloat FLMLandscapeSwipeThreshold = 32.0;
static const CGFloat FLMLandscapeHiddenRevealWidth = 8.0;
static const NSTimeInterval FLMLandscapePresenterSettleDelay = 0.08;
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
@end

@interface FLMLandscapeRootView : UIView
@property(nonatomic, weak) UIView *cardView;
@property(nonatomic, weak) UIView *handleView;
@end

@interface FLMLandscapeWindow : UIWindow
@end

@interface FLMLandscapeRootViewController : UIViewController
@end

@interface FLMLandscapeModule : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, strong) FLMLandscapeWindow *window;
@property(nonatomic, strong) FLMLandscapeRootView *rootView;
@property(nonatomic, strong) UIView *cardView;
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
@property(nonatomic, assign) uint64_t keyboardSessionGeneration;
@property(nonatomic, assign) BOOL keyboardRoutePublished;
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
- (void)closeKeepingApplication:(BOOL)keepApplication;
- (void)refreshSceneForeground;
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
                if (UIInterfaceOrientationIsLandscape(scene.interfaceOrientation)) {
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
    if (@available(iOS 13.0, *)) {
        UIInterfaceOrientation orientation = scene.interfaceOrientation;
        if (UIInterfaceOrientationIsLandscape(orientation)) {
            return orientation;
        }
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

static CGRect FLMLandscapeLogicalSceneFrame(CGRect visualBounds,
                                            UIInterfaceOrientation orientation) {
    CGRect frame = visualBounds;
    frame.origin = CGPointZero;
    if (UIInterfaceOrientationIsLandscape(orientation) &&
        CGRectGetWidth(frame) > CGRectGetHeight(frame)) {
        // FBScene settings.frame remains in the scene's logical/fixed space.
        // The layer host is laid out in the rotated visual space below.
        frame.size = CGSizeMake(CGRectGetHeight(frame), CGRectGetWidth(frame));
    }
    return frame;
}

BOOL FLMLandscapeModuleIsLandscape(void) {
    return UIInterfaceOrientationIsLandscape(FLMLandscapeInterfaceOrientation());
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
    UIScreen *screen = FLMLandscapeWindowScene().screen;
    if (!screen) {
        screen = [UIScreen mainScreen];
    }
    return FLMLandscapeVisualBoundsForScreen(
        screen, FLMLandscapeInterfaceOrientation());
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
    // callback to see 390x844 and the next one to see 844x390 in build 0.9.44.
    context.orientation = FLMLandscapeInterfaceOrientation();
    context.visualBounds = FLMLandscapeVisualBoundsForScreen(
        screen, context.orientation);
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

CGPoint FLMLandscapeModuleVisualPointFromRawPoint(CGPoint rawPoint) {
    return FLMLandscapeModuleVisualPointFromRawPointInContext(
        FLMLandscapeModuleCaptureTouchContext(), rawPoint);
}

static CGFloat FLMLandscapeTriggerSize(void) {
    CFPreferencesSynchronize(CFSTR("com.codex.flymemultitasking"),
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);
    id value = CFBridgingRelease(CFPreferencesCopyAppValue(
        CFSTR("cornerTriggerSizeV2"), CFSTR("com.codex.flymemultitasking")));
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

@implementation FLMLandscapeRootView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit) {
        return hit;
    }
    return self;
}

@end

@implementation FLMLandscapeWindow

- (BOOL)canBecomeKeyWindow {
    return YES;
}

@end

static BOOL FLMLandscapeDeviceIsLocked(void) {
    id manager = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
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
    window.windowLevel = UIWindowLevelAlert + 93.0;
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
    if (self.keyboardRoutePublished) {
        FLMLandscapeKeyboardRouteClose(self.keyboardSessionGeneration);
        self.keyboardRoutePublished = NO;
    }
    [self.hostView removeFromSuperview];
    self.hostView = nil;
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
    [self layoutHost];
}

- (BOOL)hasVisibleCard {
    return self.window && !self.window.hidden && self.identifier.length > 0;
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
    self.keyboardRoutePublished = NO;
    self.keyboardSessionGeneration =
        ((uint64_t)self.generation << 1) | 1ULL;
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
    FLMEnqueueDiagnosticLine(
        @"sb landscape-module-open app=%@ generation=%lu bounds=%@ orientation=%ld card=%@",
        self.identifier, (unsigned long)self.generation,
        NSStringFromCGRect(self.displayBounds), (long)self.displayOrientation,
        NSStringFromCGRect(target));
    [self prewarmIdentifier:self.identifier];
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
        // SceneLifecycle protects this scene from normal deactivation, but a
        // keyboard presentation can still amend its client settings. Reassert
        // the foreground contract while the independent landscape card lives.
        [self refreshSceneForeground];
    }
    if (self.hasVisibleCard && FLMLandscapeDeviceIsLocked()) {
        FLMEnqueueDiagnosticLine(@"sb landscape-module-close reason=lock-screen");
        [self closeKeepingApplication:YES];
    }
}

- (void)prewarmIdentifier:(NSString *)identifier {
    UIApplication *application = [UIApplication sharedApplication];
    if ([application respondsToSelector:
                         @selector(launchApplicationWithIdentifier:suspended:)]) {
        [application launchApplicationWithIdentifier:identifier suspended:YES];
    }
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
        [self scheduleResolveForGeneration:generation delay:FLMLandscapePresenterSettleDelay];
        return;
    }
    if (CACurrentMediaTime() - self.scenePreparedAt < FLMLandscapePresenterSettleDelay) {
        [self scheduleResolveForGeneration:generation delay:FLMLandscapeResolveInterval];
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
    if (self.hostView != host) {
        [self.hostView removeFromSuperview];
        self.hostView = host;
        host.backgroundColor = [UIColor blackColor];
        host.userInteractionEnabled = YES;
        host.clipsToBounds = NO;
        [self.cardView insertSubview:host belowSubview:self.launchCoverView];
    }
    self.presenterScene = scene;
    [self layoutHost];
    self.launchCoverView.hidden = YES;
    self.launchCoverView.alpha = 1.0;
    FLMEnqueueDiagnosticLine(
        @"sb landscape-module-attached app=%@ generation=%lu scene=%@ host=%p card=%@ display=%@",
        self.identifier, (unsigned long)generation,
        FLMLandscapeSceneIdentifier(scene), (__bridge void *)host,
        NSStringFromCGRect(self.cardView.frame), NSStringFromCGRect(self.displayBounds));
}

- (BOOL)prepareScene:(id)scene handle:(id)handle {
    if (!scene) {
        return NO;
    }
    FLMProtectScene(scene, handle);
    @try {
        if ([scene respondsToSelector:@selector(_setContentState:)]) {
            [scene _setContentState:2];
        }
        if ([scene respondsToSelector:@selector(activate)]) {
            [scene activate];
        }
        id settings = [scene respondsToSelector:@selector(settings)] ? [scene settings] : nil;
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
        CGRect visualBounds = self.displayBounds;
        if (CGRectGetWidth(visualBounds) <= 1.0 ||
            CGRectGetHeight(visualBounds) <= 1.0) {
            visualBounds = FLMLandscapeModuleVisualBounds();
        }
        UIInterfaceOrientation orientation = self.displayOrientation;
        if (!UIInterfaceOrientationIsLandscape(orientation)) {
            orientation = FLMLandscapeInterfaceOrientation();
        }
        CGRect logicalFrame = FLMLandscapeLogicalSceneFrame(visualBounds,
                                                              orientation);
        if ([mutableSettings respondsToSelector:@selector(setFrame:)]) {
            [mutableSettings setFrame:logicalFrame];
        }
        if ([mutableSettings respondsToSelector:@selector(setInterfaceOrientation:)]) {
            [mutableSettings setInterfaceOrientation:(NSInteger)orientation];
        }
        if (![scene respondsToSelector:@selector(updateSettings:withTransitionContext:)]) {
            FLMClearProtectedScene(scene);
            return NO;
        }
        [scene updateSettings:mutableSettings withTransitionContext:nil];
        CGRect appliedFrame = FLMLandscapeSceneSettingsFrame(scene);
        UIInterfaceOrientation appliedOrientation =
            FLMLandscapeSceneSettingsOrientation(scene);
        FLMEnqueueDiagnosticLine(
            @"sb landscape-module-scene-frame app=%@ logical=%@ visual=%@ requestedOrientation=%ld applied=%@ appliedOrientation=%ld",
            self.identifier, NSStringFromCGRect(logicalFrame),
            NSStringFromCGRect(visualBounds), (long)orientation,
            NSStringFromCGRect(appliedFrame), (long)appliedOrientation);
        self.keyboardRoutePublished = YES;
        FLMLandscapeKeyboardRouteOpen(self.identifier,
                                      scene,
                                      self.keyboardSessionGeneration);
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
    // Landscape is intentionally a side card, not a scaled copy of the full
    // display. Keep it tall and narrow so the right-side handle has a stable
    // physical position and the card remains a vertical long rectangle.
    CGFloat cardWidth = MAX(FLMLandscapeCardMinimumWidth,
                            MIN(FLMLandscapeCardMaximumWidth,
                                displayHeight * FLMLandscapeCardWidthRatio));
    CGFloat cardHeight = displayHeight * FLMLandscapeCardMaximumHeightRatio;
    CGRect visibleFrame = CGRectMake(0.0,
                                     floor((displayHeight - cardHeight) * 0.5),
                                     floor(cardWidth),
                                     floor(cardHeight));
    CGRect target = self.hiddenCard
        ? CGRectMake(-CGRectGetWidth(visibleFrame) + FLMLandscapeHiddenRevealWidth,
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
    CGFloat x = hidden ? 0.0 : CGRectGetMaxX(cardFrame);
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
                [mutableSettings setFrame:FLMLandscapeLogicalSceneFrame(
                                                visualBounds, orientation)];
            }
            if ([mutableSettings respondsToSelector:@selector(setInterfaceOrientation:)]) {
                [mutableSettings setInterfaceOrientation:(NSInteger)orientation];
            }
        }
        [scene updateSettings:mutableSettings withTransitionContext:nil];
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
    CGRect logicalFrame = FLMLandscapeSceneSettingsFrame(self.scene);
    UIInterfaceOrientation sceneOrientation =
        FLMLandscapeSceneSettingsOrientation(self.scene);
    if (!UIInterfaceOrientationIsLandscape(sceneOrientation)) {
        sceneOrientation = self.displayOrientation;
    }
    CGSize reference = self.displayBounds.size;
    if (CGRectGetWidth(logicalFrame) > 1.0 &&
        CGRectGetHeight(logicalFrame) > 1.0) {
        // The landscape Scene stays display-landscape so UIKit exposes the
        // full-display horizontal keyboard.  Its settings frame is still the
        // fixed 390x844 logical surface used by the vertical card. Do not
        // rotate this reference back to 844x390 here: that was the source of
        // the non-uniform {0.231043,0.917949} stretch in diagnostic 86.
        reference = logicalFrame.size;
    }
    if (reference.width <= 1.0 || reference.height <= 1.0) {
        reference = self.displayBounds.size;
    }
    CGSize target = self.cardView.bounds.size;
    // Fill the vertical card without distorting the application surface. The
    // card clips the small top/bottom crop produced by aspect-fill, just like
    // the frozen centered presentation path.
    CGFloat uniformScale = MAX(target.width / reference.width,
                               target.height / reference.height);
    CGFloat renderedWidth = reference.width * uniformScale;
    CGFloat renderedHeight = reference.height * uniformScale;
    self.hostView.transform = CGAffineTransformIdentity;
    self.hostView.bounds = CGRectMake(0.0, 0.0, reference.width, reference.height);
    self.hostView.center = CGPointMake(target.width * 0.5, target.height * 0.5);
    self.hostView.transform = CGAffineTransformMakeScale(uniformScale,
                                                         uniformScale);
    FLMEnqueueDiagnosticLine(
        @"sb landscape-module-layout display={%.1f,%.1f} logical={%.1f,%.1f} card={%.1f,%.1f} host={%.1f,%.1f} uniformScale=%.6f rendered={%.1f,%.1f} cropY=%.1f orientation=%ld",
        self.displayBounds.size.width, self.displayBounds.size.height,
        logicalFrame.size.width, logicalFrame.size.height,
        target.width, target.height,
        self.hostView.bounds.size.width, self.hostView.bounds.size.height,
        uniformScale, renderedWidth, renderedHeight,
        MAX(0.0, (renderedHeight - target.height) * 0.5),
        (long)sceneOrientation);
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
    id scene = self.scene;
    id presenter = self.presenter;
    if (self.keyboardRoutePublished) {
        FLMLandscapeKeyboardRouteClose(self.keyboardSessionGeneration);
        self.keyboardRoutePublished = NO;
    }
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

uint64_t FLMLandscapeModuleKeyboardSessionGeneration(void) {
    FLMLandscapeModule *module = [FLMLandscapeModule sharedModule];
    return module.hasVisibleCard && !module.closing
               ? module.keyboardSessionGeneration
               : 0;
}
