#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "FLMDiagnostics.h"
#import "FLMSceneLifecycle.h"
#import "FLMLandscapeModule.h"

static const CGFloat FLMLandscapeDefaultTriggerSize = 58.0;
static const CGFloat FLMLandscapeMinimumTriggerSize = 36.0;
static const CGFloat FLMLandscapeMaximumTriggerSize = 96.0;
static const CGFloat FLMLandscapePortraitCanvasWidth = 390.0;
static const CGFloat FLMLandscapePortraitCanvasHeight = 844.0;
static const CGFloat FLMLandscapeCardMaximumHeightRatio = 0.92;
static const CGFloat FLMLandscapeCardAspectRatio = 390.0 / 844.0;

@interface NSObject (FLMLandscapeRuntimePrivate)
+ (id)sharedInstance;
- (id)settings;
- (id)mutableSettings;
- (void)_setContentState:(NSInteger)state;
- (void)activate;
- (void)setDeactivationReasons:(unsigned long long)reasons;
- (void)setForeground:(BOOL)foreground;
- (void)setBackgrounded:(BOOL)backgrounded;
- (void)setFrame:(CGRect)frame;
- (void)setInterfaceOrientation:(NSInteger)orientation;
- (void)updateSettings:(id)settings withTransitionContext:(id)context;
- (void)updateClientSettingsWithBlock:(void (^)(id clientSettings))block;
@end

@interface FLMWheelController : NSObject
+ (instancetype)sharedController;
@property(nonatomic, strong) UIWindow *overlayWindow;
@property(nonatomic, strong) UIView *wheelContainer;
@property(nonatomic, strong) UIWindow *hotspotWindow;
@property(nonatomic, strong) UIWindow *homeDockWindow;
@property(nonatomic, strong) UIWindow *floatingWindow;
@property(nonatomic, strong) UIWindow *floatingDockTouchGateWindow;
@property(nonatomic, strong) UIView *floatingDimView;
@property(nonatomic, strong) UIView *floatingContainer;
@property(nonatomic, strong) id floatingScene;
@property(nonatomic, strong) id floatingSceneHandle;
- (void)updateWindowFrames;
- (void)layoutFloatingWindow;
- (void)updateFloatingDockTouchGate;
- (void)refreshWheelPriorityWindow;
- (BOOL)prepareFloatingScene:(id)scene handle:(id)sceneHandle;
@end

static __weak FLMWheelController *FLMLandscapeRootController = nil;
static char FLMLandscapeSharedSceneKey;
static char FLMLandscapeClientCanvasKey;

static UIWindowScene *FLMLandscapeWindowScene(void) {
    if (@available(iOS 13.0, *)) {
        UIWindowScene *fallback = nil;
        for (UIScene *candidate in
             [UIApplication sharedApplication].connectedScenes) {
            if (![candidate isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            UIWindowScene *scene = (UIWindowScene *)candidate;
            if (scene.activationState != UISceneActivationStateForegroundActive &&
                scene.activationState != UISceneActivationStateForegroundInactive) {
                continue;
            }
            CGRect bounds = scene.coordinateSpace.bounds;
            if (UIInterfaceOrientationIsLandscape(scene.interfaceOrientation) ||
                CGRectGetWidth(bounds) > CGRectGetHeight(bounds)) {
                return scene;
            }
            if (!fallback) {
                fallback = scene;
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
        CGRect bounds = scene.coordinateSpace.bounds;
        if (CGRectGetWidth(bounds) > CGRectGetHeight(bounds)) {
            UIDeviceOrientation device = [UIDevice currentDevice].orientation;
            return device == UIDeviceOrientationLandscapeLeft
                       ? UIInterfaceOrientationLandscapeRight
                       : UIInterfaceOrientationLandscapeLeft;
        }
    }
    UIApplication *application = [UIApplication sharedApplication];
    SEL selector = NSSelectorFromString(@"statusBarOrientation");
    if ([application respondsToSelector:selector]) {
        UIInterfaceOrientation (*getter)(id, SEL) =
            (UIInterfaceOrientation (*)(id, SEL))
                [application methodForSelector:selector];
        UIInterfaceOrientation orientation = getter
                                                 ? getter(application, selector)
                                                 : UIInterfaceOrientationUnknown;
        if (UIInterfaceOrientationIsLandscape(orientation)) {
            return orientation;
        }
    }
    UIDeviceOrientation device = [UIDevice currentDevice].orientation;
    if (device == UIDeviceOrientationLandscapeLeft) {
        return UIInterfaceOrientationLandscapeRight;
    }
    if (device == UIDeviceOrientationLandscapeRight) {
        return UIInterfaceOrientationLandscapeLeft;
    }
    return UIInterfaceOrientationPortrait;
}

BOOL FLMLandscapeModuleIsLandscape(void) {
    if (UIInterfaceOrientationIsLandscape(FLMLandscapeInterfaceOrientation())) {
        return YES;
    }
    UIWindowScene *scene = FLMLandscapeWindowScene();
    if (@available(iOS 13.0, *)) {
        CGRect bounds = scene.coordinateSpace.bounds;
        if (CGRectGetWidth(bounds) > CGRectGetHeight(bounds)) {
            return YES;
        }
    }
    UIScreen *screen = scene.screen ?: [UIScreen mainScreen];
    CGRect bounds = screen.bounds;
    if (CGRectGetWidth(bounds) > CGRectGetHeight(bounds)) {
        return YES;
    }
    if (@available(iOS 8.0, *)) {
        bounds = screen.coordinateSpace.bounds;
        if (CGRectGetWidth(bounds) > CGRectGetHeight(bounds)) {
            return YES;
        }
    }
    UIDeviceOrientation device = [UIDevice currentDevice].orientation;
    return device == UIDeviceOrientationLandscapeLeft ||
           device == UIDeviceOrientationLandscapeRight;
}

static CGRect FLMLandscapeVisualBoundsForScreen(
    UIScreen *screen,
    UIInterfaceOrientation orientation) {
    CGRect bounds = screen.bounds;
    if (CGRectGetWidth(bounds) <= 1.0 || CGRectGetHeight(bounds) <= 1.0) {
        if (@available(iOS 8.0, *)) {
            bounds = screen.fixedCoordinateSpace.bounds;
        }
    }
    if (CGRectGetWidth(bounds) < CGRectGetHeight(bounds) &&
        UIInterfaceOrientationIsLandscape(orientation)) {
        bounds.size = CGSizeMake(CGRectGetHeight(bounds),
                                 CGRectGetWidth(bounds));
    }
    bounds.origin = CGPointZero;
    return bounds;
}

CGRect FLMLandscapeModuleVisualBounds(void) {
    UIWindowScene *scene = FLMLandscapeWindowScene();
    UIScreen *screen = scene.screen ?: [UIScreen mainScreen];
    if (@available(iOS 13.0, *)) {
        CGRect bounds = scene.coordinateSpace.bounds;
        if (CGRectGetWidth(bounds) > 1.0 &&
            CGRectGetHeight(bounds) > 1.0 &&
            CGRectGetWidth(bounds) > CGRectGetHeight(bounds)) {
            bounds.origin = CGPointZero;
            return bounds;
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
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    UIWindowScene *scene = FLMLandscapeWindowScene();
    if (scene) {
        [windows addObjectsFromArray:scene.windows];
    }
    UIWindow *rootWindow = FLMLandscapeRootController.floatingWindow;
    if (rootWindow && ![windows containsObject:rootWindow]) {
        [windows addObject:rootWindow];
    }
    for (UIWindow *window in windows) {
        if (![window isKindOfClass:[UIWindow class]]) {
            continue;
        }
        UIEdgeInsets candidate = window.safeAreaInsets;
        result.top = MAX(result.top, candidate.top);
        result.left = MAX(result.left, candidate.left);
        result.bottom = MAX(result.bottom, candidate.bottom);
        result.right = MAX(result.right, candidate.right);
        UIView *rootView = window.rootViewController.view;
        if (rootView) {
            candidate = rootView.safeAreaInsets;
            result.top = MAX(result.top, candidate.top);
            result.left = MAX(result.left, candidate.left);
            result.bottom = MAX(result.bottom, candidate.bottom);
            result.right = MAX(result.right, candidate.right);
        }
    }
    return result;
}

CGSize FLMLandscapeModulePortraitCanvasSize(void) {
    return CGSizeMake(FLMLandscapePortraitCanvasWidth,
                      FLMLandscapePortraitCanvasHeight);
}

CGRect FLMLandscapeModuleCardFrame(void) {
    CGRect bounds = FLMLandscapeModuleVisualBounds();
    CGFloat displayWidth = CGRectGetWidth(bounds);
    CGFloat displayHeight = CGRectGetHeight(bounds);
    if (displayWidth <= displayHeight || displayHeight <= 1.0) {
        return CGRectZero;
    }
    CGFloat cardHeight = floor(displayHeight *
                               FLMLandscapeCardMaximumHeightRatio);
    CGFloat cardWidth = floor(cardHeight * FLMLandscapeCardAspectRatio);
    UIEdgeInsets safeArea = FLMLandscapeModuleVisualSafeAreaInsets();
    CGFloat maximumX = MAX(0.0, displayWidth - cardWidth);
    CGFloat originX = floor(MAX(0.0, MIN(maximumX, safeArea.left)));
    CGFloat originY = floor((displayHeight - cardHeight) * 0.5);
    return CGRectMake(originX, originY, cardWidth, cardHeight);
}

static CGRect FLMLandscapeFixedCoordinateBounds(UIScreen *screen) {
    CGRect bounds = CGRectZero;
    if (@available(iOS 8.0, *)) {
        bounds = screen.fixedCoordinateSpace.bounds;
    }
    if (CGRectGetWidth(bounds) <= 1.0 || CGRectGetHeight(bounds) <= 1.0 ||
        CGRectGetWidth(bounds) >= CGRectGetHeight(bounds)) {
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
    UIScreen *screen = FLMLandscapeWindowScene().screen ?: [UIScreen mainScreen];
    context.orientation = FLMLandscapeInterfaceOrientation();
    context.visualBounds = FLMLandscapeModuleVisualBounds();
    context.fixedBounds = FLMLandscapeFixedCoordinateBounds(screen);
    CGFloat rawWidth = CGRectGetWidth(context.fixedBounds);
    CGFloat rawHeight = CGRectGetHeight(context.fixedBounds);
    if (rawWidth >= rawHeight) {
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
        if (rawWidth > 1.0 && rawHeight > 1.0 && rawWidth < rawHeight &&
            rawPoint.x >= CGRectGetMinX(fixedBounds) - 1.0 &&
            rawPoint.x <= CGRectGetMaxX(fixedBounds) + 1.0 &&
            rawPoint.y >= CGRectGetMinY(fixedBounds) - 1.0 &&
            rawPoint.y <= CGRectGetMaxY(fixedBounds) + 1.0) {
            CGFloat fixedX = rawPoint.x - CGRectGetMinX(fixedBounds);
            CGFloat fixedY = rawPoint.y - CGRectGetMinY(fixedBounds);
            if (context.orientation == UIInterfaceOrientationLandscapeLeft) {
                point = CGPointMake(fixedY, rawWidth - fixedX);
            } else if (context.orientation ==
                       UIInterfaceOrientationLandscapeRight) {
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
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat bottomDistance = CGRectGetHeight(bounds) - point.y;
    if (point.x < 0.0 || point.x > width || bottomDistance < 0.0 ||
        bottomDistance > verticalRadius) {
        return NO;
    }
    CGFloat verticalComponent = bottomDistance / verticalRadius;
    CGFloat leftComponent = point.x / horizontalRadius;
    CGFloat rightComponent = (width - point.x) / horizontalRadius;
    BOOL insideLeft = leftComponent * leftComponent +
                          verticalComponent * verticalComponent <=
                      1.0;
    BOOL insideRight = rightComponent * rightComponent +
                           verticalComponent * verticalComponent <=
                       1.0;
    if (fromRight) {
        *fromRight = insideRight && !insideLeft;
    }
    return insideLeft || insideRight;
}

static void FLMLandscapeApplyFrame(UIWindow *window, CGRect bounds) {
    if (!window) {
        return;
    }
    window.frame = bounds;
    UIView *rootView = window.rootViewController.view;
    if (rootView) {
        rootView.frame = CGRectMake(0.0, 0.0,
                                    CGRectGetWidth(bounds),
                                    CGRectGetHeight(bounds));
    }
}

static void FLMLandscapeSynchronizeRootNow(FLMWheelController *root) {
    if (!root || !FLMLandscapeModuleIsLandscape()) {
        return;
    }
    CGRect bounds = FLMLandscapeModuleVisualBounds();
    if (CGRectGetWidth(bounds) <= CGRectGetHeight(bounds) ||
        CGRectGetHeight(bounds) <= 1.0) {
        return;
    }
    FLMLandscapeApplyFrame(root.overlayWindow, bounds);
    FLMLandscapeApplyFrame(root.hotspotWindow, bounds);
    FLMLandscapeApplyFrame(root.homeDockWindow, bounds);
    FLMLandscapeApplyFrame(root.floatingWindow, bounds);
    FLMLandscapeApplyFrame(root.floatingDockTouchGateWindow, bounds);
    root.wheelContainer.frame = CGRectMake(0.0, 0.0,
                                           CGRectGetWidth(bounds),
                                           CGRectGetHeight(bounds));
    root.floatingDimView.frame = CGRectMake(0.0, 0.0,
                                            CGRectGetWidth(bounds),
                                            CGRectGetHeight(bounds));
    [root layoutFloatingWindow];
    [root updateFloatingDockTouchGate];
    [root refreshWheelPriorityWindow];
}

void FLMLandscapeModuleSynchronizeRootController(id rootController) {
    if (![rootController isKindOfClass:NSClassFromString(@"FLMWheelController")]) {
        return;
    }
    FLMWheelController *root = (FLMWheelController *)rootController;
    FLMLandscapeRootController = root;
    if (!FLMLandscapeModuleIsLandscape()) {
        return;
    }
    FLMLandscapeSynchronizeRootNow(root);
    FLMEnqueueDiagnosticLine(
        @"sb landscape-adapter-sync root=%p bounds=%@ card=%@ source=portrait-controller",
        (__bridge void *)root,
        NSStringFromCGRect(FLMLandscapeModuleVisualBounds()),
        NSStringFromCGRect(FLMLandscapeModuleCardFrame()));
}

@interface FLMLandscapeAdapterCoordinator : NSObject
@property(nonatomic, assign) BOOL started;
@property(nonatomic, assign) NSUInteger orientationGeneration;
@property(nonatomic, assign) UIInterfaceOrientation lastStableOrientation;
+ (instancetype)sharedCoordinator;
- (void)start;
@end

@implementation FLMLandscapeAdapterCoordinator

+ (instancetype)sharedCoordinator {
    static FLMLandscapeAdapterCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [[self alloc] init];
    });
    return coordinator;
}

- (void)start {
    if (self.started) {
        return;
    }
    self.started = YES;
    self.lastStableOrientation = FLMLandscapeModuleVisualOrientation();
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(orientationDidChange:)
               name:UIDeviceOrientationDidChangeNotification
             object:nil];
    Class controllerClass = NSClassFromString(@"FLMWheelController");
    id root = [controllerClass respondsToSelector:@selector(sharedController)]
                  ? [controllerClass sharedController]
                  : nil;
    FLMLandscapeModuleSynchronizeRootController(root);
}

- (void)orientationDidChange:(NSNotification *)notification {
    (void)notification;
    FLMWheelController *root = FLMLandscapeRootController;
    if (!root) {
        return;
    }
    self.orientationGeneration += 1;
    NSUInteger generation = self.orientationGeneration;
    NSArray<NSNumber *> *delays = @[@0.0, @0.05, @0.15, @0.35];
    for (NSNumber *delayValue in delays) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(delayValue.doubleValue * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if (generation != self.orientationGeneration) {
                    return;
                }
                if (FLMLandscapeModuleIsLandscape()) {
                    FLMLandscapeSynchronizeRootNow(root);
                } else {
                    [root updateWindowFrames];
                }
                BOOL finalPass = delayValue == delays.lastObject;
                if (!finalPass) {
                    return;
                }
                UIInterfaceOrientation orientation =
                    FLMLandscapeModuleVisualOrientation();
                BOOL orientationChanged =
                    orientation != self.lastStableOrientation;
                self.lastStableOrientation = orientation;
                if (orientationChanged && !root.floatingWindow.hidden &&
                    root.floatingScene && root.floatingSceneHandle) {
                    FLMEnqueueDiagnosticLine(
                        @"sb landscape-adapter-orientation generation=%lu orientation=%ld action=single-scene-commit",
                        (unsigned long)generation, (long)orientation);
                    [root prepareFloatingScene:root.floatingScene
                                         handle:root.floatingSceneHandle];
                }
            });
    }
}

@end

void FLMLandscapeModuleStart(void) {
    void (^startBlock)(void) = ^{
        [[FLMLandscapeAdapterCoordinator sharedCoordinator] start];
    };
    if ([NSThread isMainThread]) {
        startBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), startBlock);
    }
}

BOOL FLMLandscapeModuleOwnsSharedScene(id scene) {
    return scene &&
           [objc_getAssociatedObject(scene, &FLMLandscapeSharedSceneKey)
               boolValue];
}

static void FLMLandscapeSetSharedSceneMarkers(id scene, BOOL managed) {
    if (!scene) {
        return;
    }
    id value = managed ? @YES : nil;
    objc_setAssociatedObject(scene,
                             &FLMLandscapeSharedSceneKey,
                             value,
                             managed ? OBJC_ASSOCIATION_RETAIN_NONATOMIC
                                     : OBJC_ASSOCIATION_ASSIGN);
    if (!managed) {
        objc_setAssociatedObject(scene,
                                 &FLMLandscapeClientCanvasKey,
                                 nil,
                                 OBJC_ASSOCIATION_ASSIGN);
    }
}

BOOL FLMLandscapeModulePrepareSharedScene(id rootController,
                                          id scene,
                                          id sceneHandle) {
    if (!scene || !FLMLandscapeModuleIsLandscape() ||
        ![scene respondsToSelector:
                    @selector(updateSettings:withTransitionContext:)]) {
        return NO;
    }
    CGRect serverFrame = FLMLandscapeModuleVisualBounds();
    UIInterfaceOrientation serverOrientation =
        FLMLandscapeModuleVisualOrientation();
    if (CGRectGetWidth(serverFrame) <= CGRectGetHeight(serverFrame) ||
        !UIInterfaceOrientationIsLandscape(serverOrientation)) {
        return NO;
    }
    serverFrame.origin = CGPointZero;
    FLMEnqueueDiagnosticLine(
        @"sb landscape-bridge-prepare stage=begin root=%p scene=%p frame=%@ orientation=%ld",
        (__bridge void *)rootController, (__bridge void *)scene,
        NSStringFromCGRect(serverFrame), (long)serverOrientation);
    // Mark ownership before the first private Scene call. If a later stage
    // fails, the root failure path must still close the card instead of taking
    // its portrait-only fullscreen fallback.
    FLMLandscapeSetSharedSceneMarkers(scene, YES);
    FLMProtectScene(scene, sceneHandle);
    @try {
        if ([scene respondsToSelector:@selector(_setContentState:)]) {
            [scene _setContentState:2];
        }
        FLMEnqueueDiagnosticLine(
            @"sb landscape-bridge-prepare stage=content-state scene=%p",
            (__bridge void *)scene);
        if ([scene respondsToSelector:@selector(activate)]) {
            [scene activate];
        }
        FLMEnqueueDiagnosticLine(
            @"sb landscape-bridge-prepare stage=activated scene=%p",
            (__bridge void *)scene);

        id settings = [scene respondsToSelector:@selector(settings)]
                          ? [scene settings]
                          : nil;
        id mutableSettings = [settings mutableCopy];
        if (!mutableSettings &&
            [scene respondsToSelector:@selector(mutableSettings)]) {
            mutableSettings = [scene mutableSettings];
        }
        if (!mutableSettings) {
            FLMEnqueueDiagnosticLine(
                @"sb landscape-bridge-prepare stage=server-settings result=missing");
            FLMClearProtectedScene(scene);
            return NO;
        }
        if ([mutableSettings respondsToSelector:
                                 @selector(setDeactivationReasons:)]) {
            [mutableSettings setDeactivationReasons:0];
        }
        if ([mutableSettings respondsToSelector:@selector(setForeground:)]) {
            [mutableSettings setForeground:YES];
        }
        if ([mutableSettings respondsToSelector:@selector(setBackgrounded:)]) {
            [mutableSettings setBackgrounded:NO];
        }
        if ([mutableSettings respondsToSelector:@selector(setFrame:)]) {
            [mutableSettings setFrame:serverFrame];
        }
        if ([mutableSettings respondsToSelector:
                                 @selector(setInterfaceOrientation:)]) {
            [mutableSettings setInterfaceOrientation:serverOrientation];
        }
        [scene updateSettings:mutableSettings withTransitionContext:nil];
        FLMEnqueueDiagnosticLine(
            @"sb landscape-bridge-prepare stage=server-settings result=committed frame=%@ orientation=%ld",
            NSStringFromCGRect(serverFrame), (long)serverOrientation);

        BOOL clientAlreadyConfigured =
            [objc_getAssociatedObject(scene, &FLMLandscapeClientCanvasKey)
                boolValue];
        if (!clientAlreadyConfigured) {
            if (![scene respondsToSelector:
                            @selector(updateClientSettingsWithBlock:)]) {
                FLMEnqueueDiagnosticLine(
                    @"sb landscape-bridge-prepare stage=client-settings result=unsupported");
                FLMClearProtectedScene(scene);
                return NO;
            }
            FLMEnqueueDiagnosticLine(
                @"sb landscape-bridge-prepare stage=client-settings result=begin canvas={%.1f,%.1f}",
                FLMLandscapePortraitCanvasWidth,
                FLMLandscapePortraitCanvasHeight);
            [scene updateClientSettingsWithBlock:^(id clientSettings) {
                if ([clientSettings respondsToSelector:
                                        @selector(setInterfaceOrientation:)]) {
                    [clientSettings
                        setInterfaceOrientation:UIInterfaceOrientationPortrait];
                }
            }];
            objc_setAssociatedObject(scene,
                                     &FLMLandscapeClientCanvasKey,
                                     @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            FLMEnqueueDiagnosticLine(
                @"sb landscape-bridge-prepare stage=client-settings result=committed orientation=1");
        }
        FLMEnqueueDiagnosticLine(
            @"sb landscape-bridge-prepare stage=complete scene=%p contract=portrait-engine+landscape-adapter",
            (__bridge void *)scene);
        return YES;
    } @catch (NSException *exception) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-bridge-prepare stage=exception name=%@ reason=%@",
            exception.name ?: @"<none>", exception.reason ?: @"<none>");
        FLMClearProtectedScene(scene);
        return NO;
    }
}

void FLMLandscapeModuleBackgroundSharedScene(id rootController, id scene) {
    (void)rootController;
    if (!scene) {
        FLMClearProtectedScene(nil);
        return;
    }
    @try {
        id settings = [scene respondsToSelector:@selector(settings)]
                          ? [scene settings]
                          : nil;
        id mutableSettings = [settings mutableCopy];
        if (!mutableSettings &&
            [scene respondsToSelector:@selector(mutableSettings)]) {
            mutableSettings = [scene mutableSettings];
        }
        if (mutableSettings) {
            CGRect frame = FLMLandscapeModuleIsLandscape()
                               ? FLMLandscapeModuleVisualBounds()
                               : [UIScreen mainScreen].bounds;
            frame.origin = CGPointZero;
            UIInterfaceOrientation orientation =
                FLMLandscapeModuleIsLandscape()
                    ? FLMLandscapeModuleVisualOrientation()
                    : UIInterfaceOrientationPortrait;
            if ([mutableSettings respondsToSelector:@selector(setFrame:)]) {
                [mutableSettings setFrame:frame];
            }
            if ([mutableSettings respondsToSelector:
                                     @selector(setInterfaceOrientation:)]) {
                [mutableSettings setInterfaceOrientation:orientation];
            }
            if ([mutableSettings respondsToSelector:@selector(setForeground:)]) {
                [mutableSettings setForeground:NO];
            }
            if ([mutableSettings respondsToSelector:@selector(setBackgrounded:)]) {
                [mutableSettings setBackgrounded:YES];
            }
            if ([scene respondsToSelector:
                           @selector(updateSettings:withTransitionContext:)]) {
                [scene updateSettings:mutableSettings
                    withTransitionContext:nil];
            }
        }
    } @catch (NSException *exception) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-bridge-background result=exception name=%@ reason=%@",
            exception.name ?: @"<none>", exception.reason ?: @"<none>");
    }
    FLMLandscapeSetSharedSceneMarkers(scene, NO);
    FLMClearProtectedScene(scene);
    FLMEnqueueDiagnosticLine(
        @"sb landscape-bridge-background scene=%p result=complete",
        (__bridge void *)scene);
}
