#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <notify.h>
#import <objc/message.h>

#import "FLMDiagnostics.h"
#import "FLMLandscapeRuntime.h"
#import "FLMSceneLifecycle.h"

#define FLYME_PREFERENCES_NOTIFICATION CFSTR("com.codex.flymemultitasking.preferences-changed")
#define FLYME_PREFERENCES_DOMAIN CFSTR("com.codex.flymemultitasking")
#define FLYME_LOCK_SCREEN_ITEM @"com.codex.flymemultitasking.lockscreen"

static const CGFloat FLMLLogicalWidth = 390.0;
static const CGFloat FLMLLogicalHeight = 844.0;
static const CGFloat FLMLDefaultCenteredWidth = 315.0;
static const CGFloat FLMLDefaultTopCrop = 37.0;
static const CGFloat FLMLDefaultBottomCrop = 19.0;
static const CGFloat FLMLDefaultDockWidth = 156.0;
static const CGFloat FLMLDefaultWheelRadius = 202.0;
static const CGFloat FLMLDefaultWheelIconSize = 56.0;
static const CGFloat FLMLDefaultCornerTriggerSize = 58.0;
static const CGFloat FLMLCardSideMargin = 8.0;
static const CGFloat FLMLCardVerticalMargin = 8.0;
static const CGFloat FLMLHandleThickness = 5.0;
static const CGFloat FLMLHandleHitWidth = 44.0;
static const CGFloat FLMLHandleHitPadding = 20.0;
static const CGFloat FLMLHideIntentDistance = 36.0;
static const CGFloat FLMLHideIntentRatio = 1.35;
static const CGFloat FLMLKeyboardAccessoryProtectionHeight = 56.0;
static const NSTimeInterval FLMLScenePollInterval = 0.05;
static const NSTimeInterval FLMLSceneSettleDelay = 0.10;
static const NSTimeInterval FLMLSceneGenerationDelay = 0.75;
static const NSTimeInterval FLMLLaunchTimeout = 6.5;

@interface NSObject (FLMLandscapePrivate)
+ (id)sharedInstance;
+ (id)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleIdentifier;
- (id)frontmostApplication;
- (NSString *)bundleIdentifier;
- (NSString *)displayIdentifier;
- (id)settings;
- (id)mutableSettings;
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
- (void)updateClientSettingsWithBlock:(void (^)(id mutableSettings))block;
- (void)_setContentState:(NSInteger)state;
@end

@interface FLMLDisplayConfiguration : NSObject
- (id)identity;
@end

@interface UIScreen (FLMLandscapePrivate)
- (FLMLDisplayConfiguration *)displayConfiguration;
@end

@interface FLMLSystemGestureManager : NSObject
+ (instancetype)sharedInstance;
- (void)addGestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       toDisplayWithIdentity:(id)displayIdentity;
@end

@interface UIApplication (FLMLandscapePrivate)
- (BOOL)launchApplicationWithIdentifier:(NSString *)identifier suspended:(BOOL)suspended;
- (void)_simulateLockButtonPress;
@end

@interface FLMLSBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (id)applicationWithBundleIdentifier:(NSString *)bundleIdentifier;
@end

@interface FLMLApplicationSceneHandle : NSObject
- (id)sceneIfExists;
- (id)scene;
@end

@interface FLMLDeviceApplicationSceneEntity : NSObject
- (instancetype)initWithApplicationForMainDisplay:(id)application
             generatingNewPrimarySceneIfRequired:(BOOL)required;
- (FLMLApplicationSceneHandle *)sceneHandle;
@end

typedef NS_ENUM(NSUInteger, FLMLCardState) {
    FLMLCardStateInactive = 0,
    FLMLCardStateLaunching,
    FLMLCardStateOperation,
    FLMLCardStateDockTransition,
    FLMLCardStateDocked,
    FLMLCardStateHiddenTransition,
    FLMLCardStateHidden,
    FLMLCardStateFullscreenHandoff,
    FLMLCardStateClosing,
};

@class FLMLandscapeCoordinator;

static BOOL FLMLIsLandscapeBounds(CGRect bounds) {
    return CGRectGetWidth(bounds) > CGRectGetHeight(bounds) &&
           CGRectGetHeight(bounds) > 1.0;
}

static BOOL FLMLPointInsideCornerTrigger(CGPoint point,
                                         CGRect bounds,
                                         CGFloat triggerSize,
                                         BOOL *fromRight) {
    CGFloat horizontalRadius = MAX(36.0, MIN(96.0, triggerSize));
    CGFloat verticalRadius = horizontalRadius * (65.0 / 58.0);
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    CGFloat bottomDistance = height - point.y;
    if (point.x < 0.0 || point.x > width || bottomDistance < 0.0 ||
        bottomDistance > verticalRadius) {
        return NO;
    }
    CGFloat vertical = bottomDistance / verticalRadius;
    CGFloat left = point.x / horizontalRadius;
    CGFloat right = (width - point.x) / horizontalRadius;
    BOOL insideLeft = left * left + vertical * vertical <= 1.0;
    BOOL insideRight = right * right + vertical * vertical <= 1.0;
    if (fromRight) {
        *fromRight = insideRight && !insideLeft;
    }
    return insideLeft || insideRight;
}

static CGRect FLMLInterpolateRect(CGRect from, CGRect to, CGFloat progress) {
    progress = MAX(0.0, MIN(1.0, progress));
    return CGRectMake(from.origin.x + (to.origin.x - from.origin.x) * progress,
                      from.origin.y + (to.origin.y - from.origin.y) * progress,
                      from.size.width + (to.size.width - from.size.width) * progress,
                      from.size.height + (to.size.height - from.size.height) * progress);
}

// SpringBoard's own UIWindowScene can remain portrait while the frontmost
// application is physically landscape.  The landscape entry route therefore
// cannot use that Scene as its orientation gate.  Keep the last confirmed
// physical orientation and prefer live landscape evidence from every source.
static UIInterfaceOrientation FLMLLastKnownInterfaceOrientation =
    UIInterfaceOrientationPortrait;

static UIInterfaceOrientation FLMLActiveInterfaceOrientation(void) {
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    BOOL screenBoundsLandscape = FLMLIsLandscapeBounds(screenBounds);
    UIInterfaceOrientation portraitCandidate = UIInterfaceOrientationUnknown;
    if (@available(iOS 13.0, *)) {
        for (UIScene *candidate in
             [UIApplication sharedApplication].connectedScenes) {
            if (![candidate isKindOfClass:[UIWindowScene class]] ||
                (candidate.activationState != UISceneActivationStateForegroundActive &&
                 candidate.activationState != UISceneActivationStateForegroundInactive)) {
                continue;
            }
            UIInterfaceOrientation orientation =
                ((UIWindowScene *)candidate).interfaceOrientation;
            if (UIInterfaceOrientationIsLandscape(orientation)) {
                FLMLLastKnownInterfaceOrientation = orientation;
                return orientation;
            }
            if (orientation != UIInterfaceOrientationUnknown) {
                portraitCandidate = orientation;
            }
        }
    }

    UIApplication *application = [UIApplication sharedApplication];
    SEL statusBarSelector = NSSelectorFromString(@"statusBarOrientation");
    if ([application respondsToSelector:statusBarSelector]) {
        UIInterfaceOrientation (*getter)(id, SEL) =
            (UIInterfaceOrientation (*)(id, SEL))
                [application methodForSelector:statusBarSelector];
        UIInterfaceOrientation orientation =
            getter ? getter(application, statusBarSelector)
                   : UIInterfaceOrientationUnknown;
        if (UIInterfaceOrientationIsLandscape(orientation)) {
            FLMLLastKnownInterfaceOrientation = orientation;
            return orientation;
        }
        if (orientation != UIInterfaceOrientationUnknown) {
            portraitCandidate = orientation;
        }
    }

    UIDeviceOrientation deviceOrientation = [UIDevice currentDevice].orientation;
    UIInterfaceOrientation physical = UIInterfaceOrientationUnknown;
    switch (deviceOrientation) {
        case UIDeviceOrientationLandscapeLeft:
            physical = UIInterfaceOrientationLandscapeRight;
            break;
        case UIDeviceOrientationLandscapeRight:
            physical = UIInterfaceOrientationLandscapeLeft;
            break;
        case UIDeviceOrientationPortrait:
            physical = UIInterfaceOrientationPortrait;
            break;
        case UIDeviceOrientationPortraitUpsideDown:
            physical = UIInterfaceOrientationPortraitUpsideDown;
            break;
        default:
            break;
    }
    if (UIInterfaceOrientationIsLandscape(physical)) {
        FLMLLastKnownInterfaceOrientation = physical;
        return physical;
    }

    // A physically landscape UIScreen is stronger evidence than the stale
    // portrait values SpringBoard can expose through its own Scene, status bar,
    // and UIDevice.  Do not let those portrait values rotate the wheel layout
    // back into a 390x844 coordinate contract.
    if (screenBoundsLandscape) {
        if (!UIInterfaceOrientationIsLandscape(
                FLMLLastKnownInterfaceOrientation)) {
            FLMLLastKnownInterfaceOrientation =
                UIInterfaceOrientationLandscapeRight;
        }
        return FLMLLastKnownInterfaceOrientation;
    }

    if (physical != UIInterfaceOrientationUnknown) {
        FLMLLastKnownInterfaceOrientation = physical;
        return physical;
    }

    // Face-up/face-down/unknown must not revert a landscape session to the
    // stale portrait orientation exposed by SpringBoard's home Scene.
    if (UIInterfaceOrientationIsLandscape(
            FLMLLastKnownInterfaceOrientation)) {
        return FLMLLastKnownInterfaceOrientation;
    }
    if (portraitCandidate != UIInterfaceOrientationUnknown) {
        FLMLLastKnownInterfaceOrientation = portraitCandidate;
    }
    return FLMLLastKnownInterfaceOrientation;
}

static CGRect FLMLPhysicalDisplayBounds(void) {
    CGRect bounds = [UIScreen mainScreen].bounds;
    BOOL targetLandscape = UIInterfaceOrientationIsLandscape(
        FLMLActiveInterfaceOrientation());
    BOOL boundsLandscape = CGRectGetWidth(bounds) > CGRectGetHeight(bounds);
    if (targetLandscape && !boundsLandscape) {
        bounds.size = CGSizeMake(bounds.size.height, bounds.size.width);
    }
    return CGRectMake(0.0,
                      0.0,
                      CGRectGetWidth(bounds),
                      CGRectGetHeight(bounds));
}

typedef NS_ENUM(NSInteger, FLMLRawCoordinateMode) {
    FLMLRawCoordinateModeUnknown = 0,
    FLMLRawCoordinateModeCurrent,
    FLMLRawCoordinateModeFixedLandscapeLeft,
    FLMLRawCoordinateModeFixedLandscapeRight,
};

static CGPoint FLMLVisualPointForRawCoordinateMode(
    CGPoint rawPoint,
    FLMLRawCoordinateMode mode) {
    CGRect visualBounds = FLMLPhysicalDisplayBounds();
    CGFloat portraitWidth = MIN(CGRectGetWidth(visualBounds),
                                CGRectGetHeight(visualBounds));
    CGFloat portraitHeight = MAX(CGRectGetWidth(visualBounds),
                                 CGRectGetHeight(visualBounds));
    switch (mode) {
        case FLMLRawCoordinateModeFixedLandscapeLeft:
            return CGPointMake(rawPoint.y, portraitWidth - rawPoint.x);
        case FLMLRawCoordinateModeFixedLandscapeRight:
            return CGPointMake(portraitHeight - rawPoint.y, rawPoint.x);
        case FLMLRawCoordinateModeCurrent:
        case FLMLRawCoordinateModeUnknown:
        default:
            return rawPoint;
    }
}

static NSString *FLMLRawCoordinateModeName(FLMLRawCoordinateMode mode) {
    switch (mode) {
        case FLMLRawCoordinateModeCurrent:
            return @"current";
        case FLMLRawCoordinateModeFixedLandscapeLeft:
            return @"fixed-left";
        case FLMLRawCoordinateModeFixedLandscapeRight:
            return @"fixed-right";
        case FLMLRawCoordinateModeUnknown:
        default:
            return @"unknown";
    }
}

// The system gesture manager is an arbitration boundary, not a regular view
// hierarchy.  Match the proven portrait recognizer contract so the bottom
// system gesture cannot prevent the landscape corner stream before it begins.
@interface FLMLandscapeCornerGestureRecognizer : UILongPressGestureRecognizer
@property(nonatomic, assign) CGPoint flmlFirstRawPoint;
@property(nonatomic, assign) BOOL flmlHasFirstRawPoint;
@property(nonatomic, assign) FLMLRawCoordinateMode flmlRawCoordinateMode;
@end

@implementation FLMLandscapeCornerGestureRecognizer

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *firstTouch = [touches anyObject];
    if (firstTouch && !self.flmlHasFirstRawPoint) {
        self.flmlFirstRawPoint = [firstTouch locationInView:nil];
        self.flmlHasFirstRawPoint = YES;
    }
    [super touchesBegan:touches withEvent:event];
}

- (void)reset {
    [super reset];
    self.flmlFirstRawPoint = CGPointZero;
    self.flmlHasFirstRawPoint = NO;
    self.flmlRawCoordinateMode = FLMLRawCoordinateModeUnknown;
}

- (BOOL)canBePreventedByGestureRecognizer:
    (UIGestureRecognizer *)preventingGestureRecognizer {
    (void)preventingGestureRecognizer;
    return NO;
}

- (BOOL)canPreventGestureRecognizer:
    (UIGestureRecognizer *)preventedGestureRecognizer {
    (void)preventedGestureRecognizer;
    return YES;
}

- (BOOL)shouldBeRequiredToFailByGestureRecognizer:
    (UIGestureRecognizer *)otherGestureRecognizer {
    (void)otherGestureRecognizer;
    return NO;
}

- (BOOL)shouldRequireFailureOfGestureRecognizer:
    (UIGestureRecognizer *)otherGestureRecognizer {
    (void)otherGestureRecognizer;
    return NO;
}

@end

@interface FLMLandscapeRootViewController : UIViewController
@property(nonatomic, copy) void (^layoutDidChange)(void);
@end

@implementation FLMLandscapeRootViewController

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.layoutDidChange) {
        self.layoutDidChange();
    }
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    if (self.layoutDidChange) {
        self.layoutDidChange();
    }
}

@end

@interface FLMLandscapeOverlayWindow : UIWindow
@end

@implementation FLMLandscapeOverlayWindow
- (BOOL)canBecomeKeyWindow {
    return NO;
}
@end

@interface FLMLandscapeCardWindow : UIWindow
@property(nonatomic, assign) BOOL passesTouchesOutsideCard;
@property(nonatomic, assign) CGRect cardInteractionFrame;
@property(nonatomic, assign) CGRect handleInteractionFrame;
@property(nonatomic, assign) CGRect keyboardPassThroughFrame;
@end

@implementation FLMLandscapeCardWindow

- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!CGRectIsNull(self.keyboardPassThroughFrame) &&
        CGRectContainsPoint(self.keyboardPassThroughFrame, point)) {
        return nil;
    }
    BOOL insideCard = !CGRectIsNull(self.cardInteractionFrame) &&
                      CGRectContainsPoint(CGRectInset(self.cardInteractionFrame,
                                                      -4.0,
                                                      -4.0),
                                          point);
    BOOL insideHandle = !CGRectIsNull(self.handleInteractionFrame) &&
                        CGRectContainsPoint(CGRectInset(self.handleInteractionFrame,
                                                        -8.0,
                                                        -8.0),
                                            point);
    if (self.passesTouchesOutsideCard && !insideCard && !insideHandle) {
        return nil;
    }
    UIView *hit = [super hitTest:point withEvent:event];
    return hit ?: self.rootViewController.view;
}

@end

@interface FLMLandscapeHotspotWindow : FLMLandscapeOverlayWindow
@property(nonatomic, assign) BOOL hotspotsEnabled;
@property(nonatomic, assign) CGFloat triggerSize;
@end

@implementation FLMLandscapeHotspotWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.hotspotsEnabled || !FLMLIsLandscapeBounds(self.bounds) ||
        !FLMLPointInsideCornerTrigger(point,
                                      self.bounds,
                                      self.triggerSize,
                                      NULL)) {
        return nil;
    }
    return [super hitTest:point withEvent:event];
}

@end

@interface FLMLandscapeKeyboardWindow : UIWindow
@property(nonatomic, assign) CGRect keyboardInteractionFrame;
@end


@implementation FLMLandscapeKeyboardWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (CGRectIsNull(self.keyboardInteractionFrame) ||
        !CGRectContainsPoint(self.keyboardInteractionFrame, point)) {
        return nil;
    }
    UIView *hit = [super hitTest:point withEvent:event];
    UIView *root = self.rootViewController.view;
    return hit == self || hit == root ? nil : hit;
}

@end

@interface FLMLandscapeWheelItemView : UIView
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, assign) BOOL highlighted;
@property(nonatomic, assign) CGPoint visualCenter;
- (instancetype)initWithIdentifier:(NSString *)identifier
                              image:(UIImage *)image
                               size:(CGFloat)size;
@end

@implementation FLMLandscapeWheelItemView

- (instancetype)initWithIdentifier:(NSString *)identifier
                              image:(UIImage *)image
                               size:(CGFloat)size {
    self = [super initWithFrame:CGRectMake(0.0, 0.0, size, size)];
    if (self) {
        _identifier = [identifier copy];
        BOOL lockItem = [identifier isEqualToString:FLYME_LOCK_SCREEN_ITEM];
        self.backgroundColor = lockItem ? [UIColor systemBlueColor]
                                        : [UIColor clearColor];
        self.layer.cornerRadius = size * 0.5;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.22;
        self.layer.shadowRadius = 8.0;
        self.layer.shadowOffset = CGSizeMake(0.0, 3.0);
        _iconView = [[UIImageView alloc] initWithImage:image];
        _iconView.frame = lockItem ? CGRectInset(self.bounds,
                                                 size * 15.0 / 56.0,
                                                 size * 15.0 / 56.0)
                                   : self.bounds;
        _iconView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                     UIViewAutoresizingFlexibleHeight;
        _iconView.contentMode = lockItem ? UIViewContentModeScaleAspectFit
                                         : UIViewContentModeScaleAspectFill;
        _iconView.clipsToBounds = YES;
        _iconView.layer.cornerRadius = lockItem ? 0.0 : size * 0.5;
        [self addSubview:_iconView];
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    if (_highlighted == highlighted) {
        return;
    }
    _highlighted = highlighted;
    [UIView animateWithDuration:0.20
                     animations:^{
                         self.transform = CGAffineTransformMakeScale(
                             highlighted ? 1.22 : 1.0,
                             highlighted ? 1.22 : 1.0);
                         self.layer.shadowOpacity = highlighted ? 0.32 : 0.22;
                     }];
}

@end

@interface FLMLandscapeCoordinator : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, strong) FLMLandscapeOverlayWindow *wheelWindow;
@property(nonatomic, strong) UIView *wheelContainer;
@property(nonatomic, strong) FLMLandscapeHotspotWindow *hotspotWindow;
@property(nonatomic, strong) FLMLandscapeCardWindow *cardWindow;
@property(nonatomic, strong) FLMLandscapeKeyboardWindow *keyboardWindow;
@property(nonatomic, strong) UIView *dimView;
@property(nonatomic, strong) UIView *shadowView;
@property(nonatomic, strong) UIView *cardContainer;
@property(nonatomic, strong) UIView *contentShield;
@property(nonatomic, strong) UIView *edgeHandle;
@property(nonatomic, strong) UIView *edgeHandleBar;
@property(nonatomic, strong) UIView *hostView;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIView *launchCoverView;
@property(nonatomic, strong) UIImageView *launchIconView;
@property(nonatomic, strong) UITapGestureRecognizer *wheelTapGesture;
@property(nonatomic, strong) UILongPressGestureRecognizer *globalCornerGuard;
@property(nonatomic, strong) UILongPressGestureRecognizer *globalCornerGesture;
@property(nonatomic, strong) UILongPressGestureRecognizer *globalModalGesture;
@property(nonatomic, strong) UILongPressGestureRecognizer *localCornerGuard;
@property(nonatomic, strong) UILongPressGestureRecognizer *localCornerGesture;
@property(nonatomic, strong) UIPanGestureRecognizer *operationHandlePan;
@property(nonatomic, strong) UIPanGestureRecognizer *dockPan;
@property(nonatomic, strong) UITapGestureRecognizer *dockTap;
@property(nonatomic, strong) UIPanGestureRecognizer *hiddenHandlePan;
@property(nonatomic, strong) UITapGestureRecognizer *backdropTap;
@property(nonatomic, strong) NSArray<FLMLandscapeWheelItemView *> *itemViews;
@property(nonatomic, copy) NSArray<NSString *> *itemIdentifiers;
@property(nonatomic, weak) FLMLandscapeWheelItemView *highlightedItem;
@property(nonatomic, assign) BOOL enabled;
@property(nonatomic, assign) BOOL usesSystemGestureManager;
@property(nonatomic, assign) BOOL wheelPinned;
@property(nonatomic, assign) BOOL wheelGestureActive;
@property(nonatomic, assign) BOOL wheelDismissInProgress;
@property(nonatomic, assign) FLMLRawCoordinateMode wheelRawCoordinateMode;
@property(nonatomic, assign) BOOL presentingFromRight;
@property(nonatomic, assign) CGPoint cornerStartPoint;
@property(nonatomic, assign) CGFloat wheelRadius;
@property(nonatomic, assign) CGFloat wheelIconSize;
@property(nonatomic, assign) CGFloat cornerTriggerSize;
@property(nonatomic, assign) CGFloat centeredCardWidth;
@property(nonatomic, assign) CGFloat centeredTopCrop;
@property(nonatomic, assign) CGFloat centeredBottomCrop;
@property(nonatomic, assign) CGFloat centeredDockSwipeThreshold;
@property(nonatomic, assign) FLMLCardState cardState;
@property(nonatomic, assign) BOOL dockedOnRight;
@property(nonatomic, assign) CGFloat dockVerticalCenter;
@property(nonatomic, assign) CGRect operationPanStartFrame;
@property(nonatomic, assign) CGRect dockPanStartFrame;
@property(nonatomic, assign) CGPoint dockPanStartPoint;
@property(nonatomic, assign) CGRect hiddenPanStartFrame;
@property(nonatomic, assign) CGPoint hiddenPanStartPoint;
@property(nonatomic, assign) NSUInteger transitionGeneration;
@property(nonatomic, assign) BOOL transitionActive;
@property(nonatomic, strong) UIView *transitionSnapshot;
@property(nonatomic, assign) FLMLCardState transitionTargetState;
@property(nonatomic, assign) CGRect transitionTargetFrame;
@property(nonatomic, assign) NSUInteger orientationEpoch;
@property(nonatomic, assign) BOOL layoutPassActive;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *queuedIdentifier;
@property(nonatomic, copy) NSString *queuedFullscreenIdentifier;
@property(nonatomic, strong) id sceneEntity;
@property(nonatomic, strong) FLMLApplicationSceneHandle *sceneHandle;
@property(nonatomic, strong) id scene;
@property(nonatomic, strong) id presentationManager;
@property(nonatomic, strong) id presenter;
@property(nonatomic, strong) id presenterScene;
@property(nonatomic, assign) NSUInteger launchGeneration;
@property(nonatomic, assign) NSTimeInterval launchStartedAt;
@property(nonatomic, assign) NSTimeInterval scenePreparedAt;
@property(nonatomic, assign) NSUInteger keyboardSessionCounter;
@property(nonatomic, assign) NSUInteger keyboardSessionGeneration;
@property(nonatomic, assign) BOOL keyboardVisible;
@property(nonatomic, assign) CGRect keyboardFrame;
@property(nonatomic, assign) CGRect pendingKeyboardFrame;
@property(nonatomic, assign) BOOL keyboardFramePending;
@property(nonatomic, weak) UIView *keyboardLayerHostView;
@property(nonatomic, strong) UIView *keyboardOriginalSuperview;
@property(nonatomic, assign) NSInteger keyboardOriginalSubviewIndex;
@property(nonatomic, assign) CGRect keyboardOriginalFrame;
@property(nonatomic, assign) CGAffineTransform keyboardOriginalTransform;
@property(nonatomic, assign) UIViewAutoresizing keyboardOriginalAutoresizingMask;
@property(nonatomic, assign) BOOL keyboardOriginalTranslatesAutoresizingMask;
@property(nonatomic, assign) NSUInteger keyboardHostSessionGeneration;
@property(nonatomic, strong) id keyboardScene;
@property(nonatomic, strong) id keyboardPreferredHostIdentity;
@property(nonatomic, assign) NSUInteger keyboardPairingSessionGeneration;
@property(nonatomic, assign) NSUInteger keyboardHostRetrySession;
@property(nonatomic, assign) NSUInteger keyboardHostRetryAttempt;
@property(nonatomic, weak) UIWindow *previousKeyWindow;
+ (instancetype)sharedCoordinator;
- (void)start;
- (void)reloadPreferences;
- (void)keyboardLayerHostView:(UIView *)hostView
            didUpdateForScene:(id _Nullable)scene
            sessionGeneration:(NSUInteger)sessionGeneration;
@end

static void FLMLPreferencesChanged(CFNotificationCenterRef center,
                                   void *observer,
                                   CFStringRef name,
                                   const void *object,
                                   CFDictionaryRef userInfo);

@implementation FLMLandscapeCoordinator

+ (instancetype)sharedCoordinator {
    static FLMLandscapeCoordinator *coordinator = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [[self alloc] init];
    });
    return coordinator;
}

- (void)start {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        self.cardState = FLMLCardStateInactive;
        self.keyboardFrame = CGRectNull;
        self.pendingKeyboardFrame = CGRectNull;
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            FLMLPreferencesChanged,
            FLYME_PREFERENCES_NOTIFICATION,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(orientationDidChange:)
                   name:UIDeviceOrientationDidChangeNotification
                 object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(keyboardFrameWillChange:)
                   name:UIKeyboardWillChangeFrameNotification
                 object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(keyboardDidHide:)
                   name:UIKeyboardDidHideNotification
                 object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(protectedSceneDidDisappear:)
                   name:FLMProtectedSceneDidDisappearNotification
                 object:nil];
        [self createWindows];
        [self reloadPreferences];
        [self updateForCurrentOrientationWithReason:@"start"];
    });
}

- (UIWindowScene *)foregroundWindowScene {
    if (@available(iOS 13.0, *)) {
        for (UIScene *candidate in
             [UIApplication sharedApplication].connectedScenes) {
            if ([candidate isKindOfClass:[UIWindowScene class]] &&
                candidate.activationState ==
                    UISceneActivationStateForegroundActive) {
                return (UIWindowScene *)candidate;
            }
        }
    }
    return nil;
}

- (CGRect)displayBounds {
    CGRect bounds = FLMLPhysicalDisplayBounds();
    if (CGRectGetWidth(bounds) < 1.0 || CGRectGetHeight(bounds) < 1.0) {
        bounds = [UIScreen mainScreen].bounds;
    }
    return CGRectMake(0.0,
                      0.0,
                      CGRectGetWidth(bounds),
                      CGRectGetHeight(bounds));
}

- (BOOL)isLandscapeActive {
    UIInterfaceOrientation orientation = FLMLActiveInterfaceOrientation();
    if (UIInterfaceOrientationIsLandscape(orientation)) {
        return YES;
    }
    return FLMLIsLandscapeBounds([self displayBounds]);
}

- (UIEdgeInsets)resolvedSafeAreaInsets {
    UIEdgeInsets insets = self.cardWindow.rootViewController.view.safeAreaInsets;
    UIWindowScene *scene = self.cardWindow.windowScene;
    for (UIWindow *window in scene.windows) {
        if (window == self.cardWindow || window == self.wheelWindow ||
            window == self.hotspotWindow || window == self.keyboardWindow) {
            continue;
        }
        UIEdgeInsets candidate = window.safeAreaInsets;
        insets.top = MAX(insets.top, candidate.top);
        insets.left = MAX(insets.left, candidate.left);
        insets.bottom = MAX(insets.bottom, candidate.bottom);
        insets.right = MAX(insets.right, candidate.right);
    }
    if (UIInterfaceOrientationIsLandscape(
            FLMLActiveInterfaceOrientation())) {
        // A portrait-stale SpringBoard Scene reports the notch as top inset.
        // Convert it to a conservative symmetric lateral exclusion so either
        // physical landscape direction remains clear of the sensor housing.
        CGFloat lateral = MAX(insets.top, MAX(insets.left, insets.right));
        insets = UIEdgeInsetsMake(MIN(insets.top, 16.0),
                                  lateral,
                                  insets.bottom,
                                  lateral);
    }
    return insets;
}

- (CGRect)safeRect {
    CGRect bounds = [self displayBounds];
    CGRect safe = UIEdgeInsetsInsetRect(bounds, [self resolvedSafeAreaInsets]);
    if (CGRectGetWidth(safe) < 120.0 || CGRectGetHeight(safe) < 120.0) {
        return bounds;
    }
    return safe;
}

- (id)windowWithClass:(Class)windowClass frame:(CGRect)frame {
    UIWindowScene *scene = [self foregroundWindowScene];
    if (@available(iOS 13.0, *)) {
        if (scene) {
            UIWindow *window = [[windowClass alloc] initWithWindowScene:scene];
            window.frame = frame;
            return window;
        }
    }
    return [[windowClass alloc] initWithFrame:frame];
}

- (FLMLandscapeRootViewController *)newRootControllerWithLayoutCallback:(BOOL)callback {
    FLMLandscapeRootViewController *controller =
        [[FLMLandscapeRootViewController alloc] init];
    controller.view.backgroundColor = [UIColor clearColor];
    if (callback) {
        __weak typeof(self) weakSelf = self;
        controller.layoutDidChange = ^{
            [weakSelf rootLayoutDidChange];
        };
    }
    return controller;
}

- (UILongPressGestureRecognizer *)cornerRecognizerWithAction:(SEL)action
                                                   duration:(NSTimeInterval)duration {
    UILongPressGestureRecognizer *recognizer =
        [[FLMLandscapeCornerGestureRecognizer alloc]
            initWithTarget:self
                    action:action];
    recognizer.delegate = self;
    recognizer.minimumPressDuration = duration;
    recognizer.allowableMovement = CGFLOAT_MAX;
    recognizer.numberOfTouchesRequired = 1;
    recognizer.cancelsTouchesInView = YES;
    recognizer.delaysTouchesBegan = NO;
    recognizer.delaysTouchesEnded = NO;
    return recognizer;
}

- (void)createWindows {
    CGRect bounds = [self displayBounds];

    self.wheelWindow = [self windowWithClass:[FLMLandscapeOverlayWindow class]
                                       frame:bounds];
    self.wheelWindow.windowLevel = UIWindowLevelAlert + 121.0;
    self.wheelWindow.backgroundColor = [UIColor clearColor];
    self.wheelWindow.rootViewController =
        [self newRootControllerWithLayoutCallback:NO];
    self.wheelWindow.hidden = YES;
    self.wheelWindow.userInteractionEnabled = NO;
    self.wheelContainer = [[UIView alloc] initWithFrame:bounds];
    [self.wheelWindow.rootViewController.view addSubview:self.wheelContainer];
    self.wheelTapGesture =
        [[UITapGestureRecognizer alloc] initWithTarget:self
                                               action:@selector(handleWheelTap:)];
    [self.wheelWindow.rootViewController.view
        addGestureRecognizer:self.wheelTapGesture];

    self.cardWindow = [self windowWithClass:[FLMLandscapeCardWindow class]
                                      frame:bounds];
    self.cardWindow.windowLevel = UIWindowLevelAlert + 92.0;
    self.cardWindow.backgroundColor = [UIColor clearColor];
    self.cardWindow.rootViewController =
        [self newRootControllerWithLayoutCallback:YES];
    self.cardWindow.hidden = YES;
    self.cardWindow.cardInteractionFrame = CGRectNull;
    self.cardWindow.handleInteractionFrame = CGRectNull;
    self.cardWindow.keyboardPassThroughFrame = CGRectNull;

    UIView *root = self.cardWindow.rootViewController.view;
    self.dimView = [[UIView alloc] initWithFrame:bounds];
    self.dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.12];
    [root addSubview:self.dimView];

    self.shadowView = [[UIView alloc] initWithFrame:CGRectZero];
    self.shadowView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.01];
    self.shadowView.userInteractionEnabled = NO;
    self.shadowView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.shadowView.layer.shadowOpacity = 0.20;
    self.shadowView.layer.shadowRadius = 14.0;
    self.shadowView.layer.shadowOffset = CGSizeMake(0.0, 3.0);
    [root addSubview:self.shadowView];

    self.cardContainer = [[UIView alloc] initWithFrame:CGRectZero];
    self.cardContainer.backgroundColor = [UIColor blackColor];
    self.cardContainer.layer.cornerRadius = 18.0;
    self.cardContainer.layer.masksToBounds = YES;
    [root addSubview:self.cardContainer];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.text = @"正在打开…";
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    self.statusLabel.font = [UIFont systemFontOfSize:13.0
                                             weight:UIFontWeightMedium];
    [self.cardContainer addSubview:self.statusLabel];

    self.launchCoverView = [[UIView alloc] initWithFrame:CGRectZero];
    self.launchCoverView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    [self.cardContainer addSubview:self.launchCoverView];
    self.launchIconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.launchIconView.contentMode = UIViewContentModeScaleAspectFit;
    self.launchIconView.layer.cornerRadius = 14.0;
    self.launchIconView.layer.masksToBounds = YES;
    [self.launchCoverView addSubview:self.launchIconView];

    self.contentShield = [[UIView alloc] initWithFrame:CGRectZero];
    self.contentShield.backgroundColor = [UIColor clearColor];
    self.contentShield.hidden = YES;
    self.contentShield.userInteractionEnabled = YES;
    [self.cardContainer addSubview:self.contentShield];

    self.edgeHandle = [[UIView alloc] initWithFrame:CGRectZero];
    self.edgeHandle.backgroundColor = [UIColor clearColor];
    self.edgeHandleBar = [[UIView alloc] initWithFrame:CGRectZero];
    self.edgeHandleBar.backgroundColor =
        [UIColor colorWithWhite:1.0 alpha:0.78];
    self.edgeHandleBar.layer.cornerRadius = FLMLHandleThickness * 0.5;
    self.edgeHandleBar.userInteractionEnabled = NO;
    [self.edgeHandle addSubview:self.edgeHandleBar];
    [root addSubview:self.edgeHandle];

    self.operationHandlePan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self
                                               action:@selector(handleOperationPan:)];
    self.operationHandlePan.delegate = self;
    [self.edgeHandle addGestureRecognizer:self.operationHandlePan];

    self.hiddenHandlePan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self
                                               action:@selector(handleHiddenPan:)];
    self.hiddenHandlePan.delegate = self;
    [root addGestureRecognizer:self.hiddenHandlePan];

    self.dockPan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(handleDockPan:)];
    self.dockPan.delegate = self;
    [root addGestureRecognizer:self.dockPan];
    self.dockTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(handleDockTap:)];
    self.dockTap.delegate = self;
    [self.dockTap requireGestureRecognizerToFail:self.dockPan];
    [root addGestureRecognizer:self.dockTap];

    self.backdropTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(handleBackdropTap:)];
    self.backdropTap.delegate = self;
    [root addGestureRecognizer:self.backdropTap];

    self.globalCornerGuard =
        [self cornerRecognizerWithAction:@selector(handleCornerGuard:)
                                duration:0.0];
    self.globalCornerGesture =
        [self cornerRecognizerWithAction:@selector(handleCornerGesture:)
                                duration:0.12];
    self.globalModalGesture =
        [self cornerRecognizerWithAction:@selector(handleModalGesture:)
                                duration:0.0];
    self.globalModalGesture.enabled = NO;
    self.localCornerGuard =
        [self cornerRecognizerWithAction:@selector(handleCornerGuard:)
                                duration:0.0];
    self.localCornerGesture =
        [self cornerRecognizerWithAction:@selector(handleCornerGesture:)
                                duration:0.12];
    self.hotspotWindow = [self windowWithClass:[FLMLandscapeHotspotWindow class]
                                         frame:bounds];
    self.hotspotWindow.windowLevel = UIWindowLevelAlert + 120.0;
    self.hotspotWindow.backgroundColor = [UIColor clearColor];
    self.hotspotWindow.rootViewController =
        [self newRootControllerWithLayoutCallback:NO];
    self.hotspotWindow.hidden = YES;
    // Always keep an in-window pair as a fallback. A private system-manager
    // registration can succeed yet receive no callbacks on some iOS builds.
    [self.hotspotWindow.rootViewController.view
        addGestureRecognizer:self.localCornerGuard];
    [self.hotspotWindow.rootViewController.view
        addGestureRecognizer:self.localCornerGesture];

    self.usesSystemGestureManager = [self registerGlobalGestures];
}

- (BOOL)registerGlobalGestures {
    Class managerClass = NSClassFromString(@"_UISystemGestureManager");
    FLMLSystemGestureManager *manager =
        (FLMLSystemGestureManager *)[managerClass sharedInstance];
    id identity = [[[UIScreen mainScreen] displayConfiguration] identity];
    SEL selector = @selector(addGestureRecognizer:toDisplayWithIdentity:);
    if (!manager || !identity || ![manager respondsToSelector:selector]) {
        return NO;
    }
    [manager addGestureRecognizer:self.globalCornerGuard
           toDisplayWithIdentity:identity];
    [manager addGestureRecognizer:self.globalCornerGesture
           toDisplayWithIdentity:identity];
    [manager addGestureRecognizer:self.globalModalGesture
           toDisplayWithIdentity:identity];
    return YES;
}

- (void)reloadPreferences {
    CFPreferencesSynchronize(FLYME_PREFERENCES_DOMAIN,
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);
    id enabledValue = FLMCopyPreference(@"enabled");
    id itemsValue = FLMCopyPreference(@"wheelItems");
    id radiusValue = FLMCopyPreference(@"wheelRadius");
    id iconValue = FLMCopyPreference(@"wheelIconSize");
    id triggerValue = FLMCopyPreference(@"cornerTriggerSizeV2");
    id widthValue = FLMCopyPreference(@"centeredCardWidth");
    id topCropValue = FLMCopyPreference(@"centeredCardTopCrop");
    id bottomCropValue = FLMCopyPreference(@"centeredCardBottomCrop");
    id swipeValue = FLMCopyPreference(@"centeredDockSwipeThreshold");

    self.enabled = [enabledValue isKindOfClass:[NSNumber class]] &&
                   [enabledValue boolValue];
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    if ([itemsValue isKindOfClass:[NSArray class]]) {
        for (id candidate in (NSArray *)itemsValue) {
            if (![candidate isKindOfClass:[NSString class]] ||
                [candidate length] == 0 ||
                [candidate isEqualToString:
                    @"com.codex.flymemultitasking.screensense"]) {
                continue;
            }
            [items addObject:candidate];
        }
    }
    self.itemIdentifiers = items;
    self.wheelRadius = [radiusValue isKindOfClass:[NSNumber class]]
                           ? MAX(170.0, MIN(225.0, [radiusValue doubleValue]))
                           : FLMLDefaultWheelRadius;
    self.wheelIconSize = [iconValue isKindOfClass:[NSNumber class]]
                             ? MAX(44.0, MIN(68.0, [iconValue doubleValue]))
                             : FLMLDefaultWheelIconSize;
    self.cornerTriggerSize = [triggerValue isKindOfClass:[NSNumber class]]
                                 ? MAX(36.0,
                                       MIN(96.0,
                                           [triggerValue doubleValue]))
                                 : FLMLDefaultCornerTriggerSize;
    self.centeredCardWidth = [widthValue isKindOfClass:[NSNumber class]]
                                 ? MAX(240.0,
                                       MIN(360.0,
                                           [widthValue doubleValue]))
                                 : FLMLDefaultCenteredWidth;
    self.centeredTopCrop = [topCropValue isKindOfClass:[NSNumber class]]
                               ? MAX(0.0,
                                     MIN(260.0,
                                         [topCropValue doubleValue]))
                               : FLMLDefaultTopCrop;
    self.centeredBottomCrop =
        [bottomCropValue isKindOfClass:[NSNumber class]]
            ? MAX(0.0, MIN(260.0, [bottomCropValue doubleValue]))
            : FLMLDefaultBottomCrop;
    self.centeredDockSwipeThreshold =
        [swipeValue isKindOfClass:[NSNumber class]]
            ? MAX(8.0, MIN(120.0, [swipeValue doubleValue]))
            : 20.0;
    self.hotspotWindow.triggerSize = self.cornerTriggerSize;
    [self refreshGestureAvailability];
    [self layoutForCurrentState];
}

- (void)refreshGestureAvailability {
    BOOL landscape = [self isLandscapeActive];
    BOOL configured = self.enabled && self.itemIdentifiers.count > 0 &&
                      !self.wheelPinned && !self.wheelDismissInProgress;
    BOOL canSummon = configured && landscape && !FLMDeviceIsLocked();
    // Never disable the cross-Scene recognizers merely because SpringBoard's
    // own Scene is portrait. They must remain alive so each new touch can
    // evaluate the current physical orientation at the delegate boundary.
    self.globalCornerGuard.enabled = configured;
    self.globalCornerGesture.enabled = configured;
    self.localCornerGuard.enabled = canSummon && !self.wheelPinned;
    self.localCornerGesture.enabled = canSummon && !self.wheelPinned;
    self.hotspotWindow.hotspotsEnabled = canSummon && !self.wheelPinned;
    self.hotspotWindow.hidden = !self.hotspotWindow.hotspotsEnabled;
    FLMEnqueueDiagnosticLine(
        @"landscape gesture-route configured=%d active=%d orientation=%ld bounds=%@ system=%d globalEnabled=%d hotspot=%d",
        configured,
        landscape,
        (long)FLMLActiveInterfaceOrientation(),
        NSStringFromCGRect([self displayBounds]),
        self.usesSystemGestureManager,
        self.globalCornerGesture.enabled,
        self.hotspotWindow.hotspotsEnabled);
}

- (void)rootLayoutDidChange {
    if (self.layoutPassActive || ![self isLandscapeActive]) {
        return;
    }
    self.layoutPassActive = YES;
    [self updateWindowFrames];
    [self layoutForCurrentState];
    self.layoutPassActive = NO;
}

- (void)orientationDidChange:(NSNotification *)notification {
    (void)notification;
    NSUInteger epoch = ++self.orientationEpoch;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (epoch != self.orientationEpoch) {
            return;
        }
        [self updateForCurrentOrientationWithReason:@"orientation-notification"];
    });
}

- (void)updateForCurrentOrientationWithReason:(NSString *)reason {
    [self updateWindowFrames];
    BOOL landscape = [self isLandscapeActive];
    FLMEnqueueDiagnosticLine(
        @"landscape orientation-update active=%d orientation=%ld bounds=%@ safe=%@ epoch=%lu reason=%@ state=%lu",
        landscape,
        (long)FLMLActiveInterfaceOrientation(),
        NSStringFromCGRect([self displayBounds]),
        NSStringFromUIEdgeInsets([self resolvedSafeAreaInsets]),
        (unsigned long)self.orientationEpoch,
        reason ?: @"<none>",
        (unsigned long)self.cardState);
    if (!landscape) {
        [self dismissWheelLaunchingItem:nil];
        self.hotspotWindow.hidden = YES;
        if (self.cardState != FLMLCardStateInactive &&
            self.cardState != FLMLCardStateClosing) {
            [self closeCardKeepingApplication:YES fullscreenIdentifier:nil];
        }
        [self refreshGestureAvailability];
        return;
    }
    FLMQuiescePortraitControllerForLandscape();
    [self takeOverCurrentTransitionIfNeeded];
    [self layoutForCurrentState];
    [self refreshGestureAvailability];
}

- (void)updateWindowFrames {
    CGRect bounds = [self displayBounds];
    NSArray<UIWindow *> *windows = @[
        self.wheelWindow ?: (UIWindow *)[NSNull null],
        self.hotspotWindow ?: (UIWindow *)[NSNull null],
        self.cardWindow ?: (UIWindow *)[NSNull null],
        self.keyboardWindow ?: (UIWindow *)[NSNull null],
    ];
    for (id candidate in windows) {
        if (![candidate isKindOfClass:[UIWindow class]]) {
            continue;
        }
        UIWindow *window = candidate;
        if (!CGRectEqualToRect(window.frame, bounds)) {
            window.frame = bounds;
        }
        window.rootViewController.view.frame = window.bounds;
    }
    self.wheelContainer.frame = self.wheelWindow.bounds;
    self.dimView.frame = self.cardWindow.bounds;
    if (self.keyboardWindow) {
        self.keyboardWindow.rootViewController.view.frame =
            self.keyboardWindow.bounds;
        if (self.keyboardLayerHostView.superview ==
            self.keyboardWindow.rootViewController.view) {
            self.keyboardLayerHostView.frame =
                self.keyboardWindow.rootViewController.view.bounds;
        }
    }
}

- (CGFloat)operationHandleLength {
    return MAX(54.0, MIN(108.0, self.centeredCardWidth * 0.30));
}

- (CGRect)operationFrame {
    CGRect safe = [self safeRect];
    CGFloat configuredWidth = MAX(240.0, self.centeredCardWidth);
    CGFloat baseScale = configuredWidth / FLMLLogicalWidth;
    CGFloat baseHeight = FLMLLogicalHeight * baseScale -
                         self.centeredTopCrop -
                         self.centeredBottomCrop;
    CGFloat availableHeight = MAX(120.0,
                                  CGRectGetHeight(safe) -
                                      FLMLCardVerticalMargin * 2.0);
    CGFloat fit = baseHeight > availableHeight
                      ? availableHeight / MAX(1.0, baseHeight)
                      : 1.0;
    CGFloat width = configuredWidth * fit;
    CGFloat height = baseHeight * fit;
    CGFloat x = CGRectGetMinX(safe) + FLMLCardSideMargin;
    CGFloat y = CGRectGetMidY(safe) - height * 0.5;
    y = MAX(CGRectGetMinY(safe) + FLMLCardVerticalMargin,
            MIN(CGRectGetMaxY(safe) - FLMLCardVerticalMargin - height, y));
    return CGRectIntegral(CGRectMake(x, y, width, height));
}

- (CGRect)dockFrameOnRight:(BOOL)onRight
            verticalCenter:(CGFloat)verticalCenter {
    CGRect safe = [self safeRect];
    CGRect operation = [self operationFrame];
    CGFloat width = MIN(FLMLDefaultDockWidth,
                        MAX(96.0, CGRectGetWidth(operation) * 0.92));
    CGFloat aspect = CGRectGetHeight(operation) /
                     MAX(1.0, CGRectGetWidth(operation));
    CGFloat height = width * aspect;
    CGFloat x = onRight
                    ? CGRectGetMaxX(safe) - FLMLCardSideMargin - width
                    : CGRectGetMinX(safe) + FLMLCardSideMargin;
    CGFloat minimumCenterY = CGRectGetMinY(safe) +
                             FLMLCardVerticalMargin + height * 0.5;
    CGFloat maximumCenterY = CGRectGetMaxY(safe) -
                             FLMLCardVerticalMargin - height * 0.5;
    if (maximumCenterY < minimumCenterY) {
        maximumCenterY = minimumCenterY;
    }
    CGFloat centerY = verticalCenter > 1.0
                          ? MAX(minimumCenterY,
                                MIN(maximumCenterY, verticalCenter))
                          : CGRectGetMidY(safe);
    return CGRectIntegral(
        CGRectMake(x, centerY - height * 0.5, width, height));
}

- (CGRect)hiddenFrameOnRight:(BOOL)onRight
              verticalCenter:(CGFloat)verticalCenter {
    CGRect safe = [self safeRect];
    CGRect frame = [self dockFrameOnRight:onRight
                           verticalCenter:verticalCenter];
    frame.origin.x = onRight ? CGRectGetMaxX(safe) + 12.0
                             : CGRectGetMinX(safe) -
                                   CGRectGetWidth(frame) - 12.0;
    return frame;
}

- (CGRect)handleFrameForCardFrame:(CGRect)cardFrame hiddenSide:(NSInteger)side {
    CGFloat length = [self operationHandleLength];
    if (side < 0) {
        CGRect safe = [self safeRect];
        CGFloat x = CGRectGetMinX(safe) - FLMLHandleHitWidth * 0.5;
        CGFloat y = CGRectGetMidY(cardFrame) -
                    (length + FLMLHandleHitPadding * 2.0) * 0.5;
        return CGRectMake(x,
                          y,
                          FLMLHandleHitWidth,
                          length + FLMLHandleHitPadding * 2.0);
    }
    if (side > 0) {
        CGRect safe = [self safeRect];
        CGFloat x = CGRectGetMaxX(safe) - FLMLHandleHitWidth * 0.5;
        CGFloat y = CGRectGetMidY(cardFrame) -
                    (length + FLMLHandleHitPadding * 2.0) * 0.5;
        return CGRectMake(x,
                          y,
                          FLMLHandleHitWidth,
                          length + FLMLHandleHitPadding * 2.0);
    }
    return CGRectMake(CGRectGetMaxX(cardFrame) - FLMLHandleHitWidth * 0.5,
                      CGRectGetMidY(cardFrame) -
                          (length + FLMLHandleHitPadding * 2.0) * 0.5,
                      FLMLHandleHitWidth,
                      length + FLMLHandleHitPadding * 2.0);
}

- (void)layoutHandleForFrame:(CGRect)cardFrame hiddenSide:(NSInteger)side {
    self.edgeHandle.frame = [self handleFrameForCardFrame:cardFrame
                                                hiddenSide:side];
    CGFloat length = [self operationHandleLength];
    CGFloat barX = side < 0
                       ? FLMLHandleHitWidth * 0.5
                       : (side > 0
                              ? FLMLHandleHitWidth * 0.5 - FLMLHandleThickness
                              : FLMLHandleHitWidth * 0.5);
    self.edgeHandleBar.frame =
        CGRectMake(barX,
                   FLMLHandleHitPadding,
                   FLMLHandleThickness,
                   length);
    self.cardWindow.handleInteractionFrame = self.edgeHandle.frame;
}

- (void)layoutHostView {
    CGRect bounds = self.cardContainer.bounds;
    self.statusLabel.frame = bounds;
    self.launchCoverView.frame = bounds;
    self.contentShield.frame = bounds;
    CGFloat iconSide = MIN(58.0,
                           MAX(38.0,
                               MIN(CGRectGetWidth(bounds),
                                   CGRectGetHeight(bounds)) * 0.26));
    self.launchIconView.frame =
        CGRectMake(CGRectGetMidX(bounds) - iconSide * 0.5,
                   CGRectGetMidY(bounds) - iconSide * 0.5,
                   iconSide,
                   iconSide);
    if (!self.hostView || CGRectGetWidth(bounds) < 1.0) {
        return;
    }
    CGFloat scale = CGRectGetWidth(bounds) / FLMLLogicalWidth;
    CGFloat configuredScale = self.centeredCardWidth / FLMLLogicalWidth;
    CGFloat cropFactor = scale / MAX(0.05, configuredScale);
    CGFloat cropOffset = (self.centeredBottomCrop - self.centeredTopCrop) *
                         cropFactor * 0.5;
    self.hostView.transform = CGAffineTransformIdentity;
    self.hostView.bounds = CGRectMake(0.0,
                                      0.0,
                                      FLMLLogicalWidth,
                                      FLMLLogicalHeight);
    self.hostView.center = CGPointMake(CGRectGetMidX(bounds),
                                       CGRectGetMidY(bounds) + cropOffset);
    self.hostView.clipsToBounds = NO;
    self.hostView.transform = CGAffineTransformMakeScale(scale, scale);
    BOOL cardActive = self.cardState == FLMLCardStateOperation &&
                      self.keyboardSessionGeneration != 0 &&
                      !self.cardWindow.hidden;
    FLMPublishKeyboardCardGeometry(self.keyboardSessionGeneration,
                                   CGRectGetMaxY(self.cardContainer.frame),
                                   scale,
                                   CGRectGetWidth(self.cardContainer.frame),
                                   CGRectGetHeight(self.cardContainer.frame),
                                   cardActive);
    FLMEnqueueDiagnosticLine(
        @"landscape content-layout state=%lu logical={390.0,844.0} card=%@ scale=%.6f cropOffset=%.2f safe=%@",
        (unsigned long)self.cardState,
        NSStringFromCGRect(self.cardContainer.frame),
        scale,
        cropOffset,
        NSStringFromCGRect([self safeRect]));
}

- (void)setCardFrameWithoutAnimation:(CGRect)frame {
    self.cardContainer.transform = CGAffineTransformIdentity;
    self.cardContainer.frame = frame;
    self.shadowView.frame = frame;
    self.shadowView.layer.cornerRadius = self.cardContainer.layer.cornerRadius;
    self.cardWindow.cardInteractionFrame = frame;
    [self layoutHostView];
}

- (void)layoutForCurrentState {
    if (!self.cardWindow || self.cardWindow.hidden ||
        ![self isLandscapeActive]) {
        return;
    }
    if (self.transitionActive) {
        return;
    }
    CGRect frame = self.cardContainer.frame;
    switch (self.cardState) {
        case FLMLCardStateLaunching:
        case FLMLCardStateOperation:
            frame = [self operationFrame];
            [self setCardFrameWithoutAnimation:frame];
            [self layoutHandleForFrame:frame hiddenSide:0];
            self.edgeHandle.hidden = self.cardState == FLMLCardStateLaunching;
            self.cardWindow.passesTouchesOutsideCard = NO;
            self.dimView.alpha = 1.0;
            break;
        case FLMLCardStateDocked:
            frame = [self dockFrameOnRight:self.dockedOnRight
                            verticalCenter:self.dockVerticalCenter];
            self.dockVerticalCenter = CGRectGetMidY(frame);
            [self setCardFrameWithoutAnimation:frame];
            self.edgeHandle.hidden = YES;
            self.cardWindow.handleInteractionFrame = CGRectNull;
            self.cardWindow.passesTouchesOutsideCard = YES;
            self.dimView.alpha = 0.0;
            break;
        case FLMLCardStateHidden:
            frame = [self hiddenFrameOnRight:self.dockedOnRight
                              verticalCenter:self.dockVerticalCenter];
            [self setCardFrameWithoutAnimation:frame];
            [self layoutHandleForFrame:frame
                            hiddenSide:self.dockedOnRight ? 1 : -1];
            self.edgeHandle.hidden = NO;
            self.edgeHandleBar.alpha = 1.0;
            self.cardWindow.cardInteractionFrame = CGRectNull;
            self.cardWindow.passesTouchesOutsideCard = YES;
            self.dimView.alpha = 0.0;
            break;
        default:
            break;
    }
}

- (CGPoint)visualPointForGesture:(UIGestureRecognizer *)gesture {
    UIWindow *gestureWindow = gesture.view.window;
    if (gestureWindow == self.cardWindow ||
        gestureWindow == self.hotspotWindow ||
        gestureWindow == self.wheelWindow) {
        return [gesture locationInView:gestureWindow.rootViewController.view];
    }
    CGPoint raw = [gesture locationInView:nil];
    FLMLRawCoordinateMode mode =
        gesture == self.globalModalGesture &&
                self.wheelRawCoordinateMode != FLMLRawCoordinateModeUnknown
            ? self.wheelRawCoordinateMode
            : FLMLRawCoordinateModeCurrent;
    if ([gesture isKindOfClass:
                     [FLMLandscapeCornerGestureRecognizer class]]) {
        FLMLandscapeCornerGestureRecognizer *cornerGesture =
            (FLMLandscapeCornerGestureRecognizer *)gesture;
        FLMLRawCoordinateMode resolved =
            cornerGesture.flmlRawCoordinateMode;
        if (resolved != FLMLRawCoordinateModeUnknown) {
            mode = resolved;
        }
    }
    return FLMLVisualPointForRawCoordinateMode(raw, mode);
}

- (CGPoint)visualPointForTouch:(UITouch *)touch
                       gesture:(UIGestureRecognizer *)gesture {
    UIWindow *gestureWindow = gesture.view.window;
    if (gestureWindow == self.cardWindow ||
        gestureWindow == self.hotspotWindow ||
        gestureWindow == self.wheelWindow) {
        return [touch locationInView:gestureWindow.rootViewController.view];
    }
    CGPoint raw = [touch locationInView:nil];
    FLMLRawCoordinateMode mode =
        gesture == self.globalModalGesture &&
                self.wheelRawCoordinateMode != FLMLRawCoordinateModeUnknown
            ? self.wheelRawCoordinateMode
            : FLMLRawCoordinateModeCurrent;
    if ([gesture isKindOfClass:
                     [FLMLandscapeCornerGestureRecognizer class]]) {
        FLMLandscapeCornerGestureRecognizer *cornerGesture =
            (FLMLandscapeCornerGestureRecognizer *)gesture;
        FLMLRawCoordinateMode resolved =
            cornerGesture.flmlRawCoordinateMode;
        if (resolved != FLMLRawCoordinateModeUnknown) {
            mode = resolved;
        }
    }
    return FLMLVisualPointForRawCoordinateMode(raw, mode);
}

- (BOOL)isCornerRecognizer:(UIGestureRecognizer *)gesture {
    return gesture == self.globalCornerGuard ||
           gesture == self.globalCornerGesture ||
           gesture == self.localCornerGuard ||
           gesture == self.localCornerGesture;
}

- (BOOL)isOpeningCornerRecognizer:(UIGestureRecognizer *)gesture {
    return gesture == self.globalCornerGesture ||
           gesture == self.localCornerGesture;
}

- (BOOL)primeCornerContextForGesture:(UIGestureRecognizer *)gesture
                               point:(CGPoint)point {
    BOOL fromRight = NO;
    BOOL accepted = FLMLPointInsideCornerTrigger(point,
                                                 [self displayBounds],
                                                 self.cornerTriggerSize,
                                                 &fromRight);
    if (accepted && [self isOpeningCornerRecognizer:gesture]) {
        self.presentingFromRight = fromRight;
        self.cornerStartPoint = point;
    }
    return accepted;
}

- (BOOL)resolveAndPrimeGlobalCornerGesture:(UIGestureRecognizer *)gesture
                                  rawPoint:(CGPoint)rawPoint
                             resolvedPoint:(CGPoint *)resolvedPoint {
    FLMLandscapeCornerGestureRecognizer *cornerGesture =
        [gesture isKindOfClass:
                     [FLMLandscapeCornerGestureRecognizer class]]
            ? (FLMLandscapeCornerGestureRecognizer *)gesture
            : nil;
    FLMLRawCoordinateMode lockedMode =
        cornerGesture ? cornerGesture.flmlRawCoordinateMode
                      : FLMLRawCoordinateModeUnknown;
    FLMLRawCoordinateMode modes[] = {
        FLMLRawCoordinateModeCurrent,
        FLMLRawCoordinateModeFixedLandscapeLeft,
        FLMLRawCoordinateModeFixedLandscapeRight,
    };
    NSUInteger modeCount = sizeof(modes) / sizeof(modes[0]);
    for (NSUInteger index = 0; index < modeCount; index++) {
        FLMLRawCoordinateMode mode =
            lockedMode != FLMLRawCoordinateModeUnknown
                ? lockedMode
                : modes[index];
        CGPoint candidate =
            FLMLVisualPointForRawCoordinateMode(rawPoint, mode);
        if (![self primeCornerContextForGesture:gesture point:candidate]) {
            if (lockedMode != FLMLRawCoordinateModeUnknown) {
                break;
            }
            continue;
        }
        if (cornerGesture) {
            cornerGesture.flmlRawCoordinateMode = mode;
        }
        if ([self isOpeningCornerRecognizer:gesture]) {
            self.wheelRawCoordinateMode = mode;
        }
        if (resolvedPoint) {
            *resolvedPoint = candidate;
        }
        return YES;
    }
    return NO;
}

- (BOOL)resolveAndPrimeCornerGesture:(UIGestureRecognizer *)gesture
                               touch:(UITouch * _Nullable)touch
                       resolvedPoint:(CGPoint *)resolvedPoint {
    UIWindow *gestureWindow = gesture.view.window;
    if (gestureWindow == self.cardWindow ||
        gestureWindow == self.hotspotWindow) {
        CGPoint point = touch
                            ? [touch locationInView:
                                         gestureWindow.rootViewController.view]
                            : [gesture locationInView:
                                           gestureWindow.rootViewController.view];
        BOOL accepted = [self primeCornerContextForGesture:gesture point:point];
        FLMLandscapeCornerGestureRecognizer *cornerGesture =
            [gesture isKindOfClass:
                         [FLMLandscapeCornerGestureRecognizer class]]
                ? (FLMLandscapeCornerGestureRecognizer *)gesture
                : nil;
        if (accepted && cornerGesture) {
            cornerGesture.flmlRawCoordinateMode = FLMLRawCoordinateModeCurrent;
        }
        if (accepted && [self isOpeningCornerRecognizer:gesture]) {
            self.wheelRawCoordinateMode = FLMLRawCoordinateModeCurrent;
        }
        if (accepted && resolvedPoint) {
            *resolvedPoint = point;
        }
        return accepted;
    }
    FLMLandscapeCornerGestureRecognizer *cornerGesture =
        [gesture isKindOfClass:
                     [FLMLandscapeCornerGestureRecognizer class]]
            ? (FLMLandscapeCornerGestureRecognizer *)gesture
            : nil;
    CGPoint raw = touch ? [touch locationInView:nil]
                        : (cornerGesture.flmlHasFirstRawPoint
                               ? cornerGesture.flmlFirstRawPoint
                               : [gesture locationInView:nil]);
    return [self resolveAndPrimeGlobalCornerGesture:gesture
                                           rawPoint:raw
                                      resolvedPoint:resolvedPoint];
}

- (BOOL)gestureRecognizerShouldBegin:
    (UIGestureRecognizer *)gestureRecognizer {
    if ([self isCornerRecognizer:gestureRecognizer]) {
        if (![self isLandscapeActive] || !self.enabled || self.wheelPinned ||
            self.itemIdentifiers.count == 0 || FLMDeviceIsLocked()) {
            return NO;
        }
        CGPoint point = CGPointZero;
        BOOL accepted = [self resolveAndPrimeCornerGesture:gestureRecognizer
                                                     touch:nil
                                             resolvedPoint:&point];
        if (accepted) {
            [self updateWindowFrames];
            FLMLandscapeCornerGestureRecognizer *cornerGesture =
                [gestureRecognizer isKindOfClass:
                                      [FLMLandscapeCornerGestureRecognizer class]]
                    ? (FLMLandscapeCornerGestureRecognizer *)gestureRecognizer
                    : nil;
            FLMEnqueueDiagnosticLine(
                @"landscape wheel-entry accepted phase=should-begin route=%@ point={%.1f,%.1f} mode=%@ orientation=%ld bounds=%@",
                gestureRecognizer.view.window == self.hotspotWindow
                    ? @"hotspot"
                    : @"system",
                point.x,
                point.y,
                FLMLRawCoordinateModeName(
                    cornerGesture ? cornerGesture.flmlRawCoordinateMode
                                  : FLMLRawCoordinateModeCurrent),
                (long)FLMLActiveInterfaceOrientation(),
                NSStringFromCGRect([self displayBounds]));
        }
        return accepted;
    }
    if (gestureRecognizer == self.globalModalGesture) {
        return self.wheelPinned && [self isLandscapeActive] &&
               !FLMDeviceIsLocked();
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldReceiveTouch:(UITouch *)touch {
    if (![self isLandscapeActive] || !self.enabled || FLMDeviceIsLocked()) {
        return NO;
    }
    if ([self isCornerRecognizer:gestureRecognizer]) {
        if (self.wheelPinned || self.itemIdentifiers.count == 0) {
            return NO;
        }
        CGPoint point = CGPointZero;
        BOOL accepted = [self resolveAndPrimeCornerGesture:gestureRecognizer
                                                     touch:touch
                                             resolvedPoint:&point];
        if (accepted) {
            [self updateWindowFrames];
        }
        return accepted;
    }
    CGPoint point = [self visualPointForTouch:touch gesture:gestureRecognizer];
    if (gestureRecognizer == self.globalModalGesture) {
        return self.wheelPinned;
    }
    if (gestureRecognizer == self.operationHandlePan) {
        return self.cardState == FLMLCardStateOperation &&
               CGRectContainsPoint(CGRectInset(self.edgeHandle.frame,
                                               -8.0,
                                               -8.0),
                                   point);
    }
    if (gestureRecognizer == self.dockPan ||
        gestureRecognizer == self.dockTap) {
        return self.cardState == FLMLCardStateDocked &&
               CGRectContainsPoint(CGRectInset(self.cardWindow.cardInteractionFrame,
                                               -6.0,
                                               -6.0),
                                   point);
    }
    if (gestureRecognizer == self.hiddenHandlePan) {
        return self.cardState == FLMLCardStateHidden &&
               CGRectContainsPoint(CGRectInset(self.edgeHandle.frame,
                                               -10.0,
                                               -10.0),
                                   point);
    }
    if (gestureRecognizer == self.backdropTap) {
        if (self.cardState != FLMLCardStateOperation) {
            return NO;
        }
        if (FLMLPointInsideCornerTrigger(point,
                                         [self displayBounds],
                                         self.cornerTriggerSize,
                                         NULL)) {
            return NO;
        }
        UIView *view = touch.view;
        BOOL insideCard = view == self.cardContainer ||
                          [view isDescendantOfView:self.cardContainer];
        BOOL insideHandle = view == self.edgeHandle ||
                            [view isDescendantOfView:self.edgeHandle];
        return !insideCard && !insideHandle;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer {
    NSArray *wheelFamily = @[
        self.globalCornerGuard,
        self.globalCornerGesture,
        self.localCornerGuard,
        self.localCornerGesture,
    ];
    return [wheelFamily containsObject:gestureRecognizer] &&
           [wheelFamily containsObject:otherGestureRecognizer];
}

- (void)handleCornerGuard:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        CGPoint point = [self visualPointForGesture:gesture];
        FLMEnqueueDiagnosticLine(
            @"landscape wheel-guard point={%.1f,%.1f} orientation=%ld safe=%@",
            point.x,
            point.y,
            (long)FLMLActiveInterfaceOrientation(),
            NSStringFromCGRect([self safeRect]));
    }
}

- (BOOL)shouldActivateWheelAtPoint:(CGPoint)point {
    CGFloat dx = point.x - self.cornerStartPoint.x;
    CGFloat dy = point.y - self.cornerStartPoint.y;
    CGFloat inward = self.presentingFromRight ? -dx : dx;
    CGFloat upward = -dy;
    return hypot(dx, dy) >= 14.0 && (inward >= 4.0 || upward >= 4.0);
}

- (void)handleCornerGesture:(UILongPressGestureRecognizer *)gesture {
    if (![self isLandscapeActive]) {
        return;
    }
    if (gesture.state == UIGestureRecognizerStateBegan) {
        CGPoint initial = CGPointZero;
        if (![self resolveAndPrimeCornerGesture:gesture
                                          touch:nil
                                  resolvedPoint:&initial]) {
            return;
        }
        [self updateWindowFrames];
    }
    CGPoint point = [self visualPointForGesture:gesture];
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            if (!self.wheelGestureActive &&
                [self shouldActivateWheelAtPoint:point]) {
                self.wheelGestureActive = YES;
                [self presentWheelFromRight:self.presentingFromRight];
            }
            if (self.wheelGestureActive) {
                [self updateWheelHighlightForPoint:point];
            }
            break;
        case UIGestureRecognizerStateEnded:
            if (self.wheelGestureActive) {
                FLMLandscapeWheelItemView *item = self.highlightedItem;
                if (item) {
                    [self dismissWheelLaunchingItem:item];
                } else {
                    [self pinWheel];
                }
            }
            self.wheelGestureActive = NO;
            break;
        case UIGestureRecognizerStateCancelled:
            if (self.wheelGestureActive) {
                [self pinWheel];
            }
            self.wheelGestureActive = NO;
            break;
        case UIGestureRecognizerStateFailed:
            [self dismissWheelLaunchingItem:nil];
            self.wheelGestureActive = NO;
            break;
        default:
            break;
    }
}

- (NSArray<NSNumber *> *)wheelRingCountsForCount:(NSUInteger)count {
    NSMutableArray<NSNumber *> *counts = [NSMutableArray array];
    NSUInteger remaining = count;
    NSUInteger capacity = 4;
    while (remaining > 0) {
        NSUInteger ring = MIN(remaining, capacity);
        [counts addObject:@(ring)];
        remaining -= ring;
        capacity += 1;
    }
    return counts;
}

- (CGPoint)wheelLocalPointForVisualPoint:(CGPoint)visualPoint {
    if (!self.wheelWindow || !self.wheelContainer) {
        return visualPoint;
    }
    UIScreen *screen = self.wheelWindow.screen ?: [UIScreen mainScreen];
    id<UICoordinateSpace> screenSpace = screen.coordinateSpace;
    CGPoint windowPoint =
        [screenSpace convertPoint:visualPoint
               toCoordinateSpace:self.wheelWindow];
    return [self.wheelContainer convertPoint:windowPoint
                                    fromView:self.wheelWindow];
}

- (void)presentWheelFromRight:(BOOL)fromRight {
    if (![self isLandscapeActive] || self.itemIdentifiers.count == 0) {
        return;
    }
    [self updateWindowFrames];
    FLMQuiescePortraitControllerForLandscape();
    [self.itemViews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.wheelPinned = NO;
    self.wheelDismissInProgress = NO;
    self.wheelWindow.userInteractionEnabled = NO;
    self.hotspotWindow.hotspotsEnabled = NO;
    CGRect visualBounds = [self displayBounds];
    UIEdgeInsets safeInsets = [self resolvedSafeAreaInsets];
    CGFloat centerMargin = self.wheelIconSize * 0.5 + 6.0;
    CGFloat startAngle = -82.0 * (CGFloat)M_PI / 180.0;
    CGFloat endAngle = -10.0 * (CGFloat)M_PI / 180.0;
    CGPoint anchor =
        CGPointMake(fromRight ? CGRectGetMaxX(visualBounds) - 4.0
                              : CGRectGetMinX(visualBounds) + 4.0,
                    CGRectGetMaxY(visualBounds) - 4.0);
    CGFloat horizontalRoom =
        CGRectGetWidth(visualBounds) - 4.0 - centerMargin;
    CGFloat verticalRoom =
        CGRectGetHeight(visualBounds) - 4.0 - centerMargin;
    CGFloat maximumRadius = MIN(horizontalRoom / MAX(0.05, cos(endAngle)),
                                verticalRoom /
                                    MAX(0.05, fabs(sin(startAngle))));
    maximumRadius = MAX(120.0, maximumRadius);
    NSArray<NSNumber *> *ringCounts =
        [self wheelRingCountsForCount:self.itemIdentifiers.count];
    CGFloat firstRadius = MIN(self.wheelRadius, maximumRadius);
    CGFloat spacing = 0.0;
    if (ringCounts.count > 1) {
        CGFloat intervals = (CGFloat)(ringCounts.count - 1);
        CGFloat desired = self.wheelIconSize + 20.0;
        CGFloat minimum = self.wheelIconSize + 6.0;
        if (firstRadius + desired * intervals <= maximumRadius) {
            spacing = desired;
        } else {
            firstRadius = MIN(firstRadius,
                              MAX(120.0,
                                  maximumRadius - minimum * intervals));
            spacing = MAX(0.0,
                          (maximumRadius - firstRadius) / intervals);
        }
    }

    NSMutableArray *views = [NSMutableArray array];
    NSMutableArray<NSString *> *centers = [NSMutableArray array];
    CGFloat minimumX = CGRectGetMinX(visualBounds) + centerMargin +
                       MAX(0.0, safeInsets.left);
    CGFloat maximumX = CGRectGetMaxX(visualBounds) - centerMargin -
                       MAX(0.0, safeInsets.right);
    if (maximumX < minimumX) {
        minimumX = CGRectGetMinX(visualBounds) + centerMargin;
        maximumX = CGRectGetMaxX(visualBounds) - centerMargin;
    }
    CGFloat minimumY = CGRectGetMinY(visualBounds) + centerMargin +
                       MIN(16.0, MAX(0.0, safeInsets.top));
    CGFloat maximumY = CGRectGetMaxY(visualBounds) - centerMargin;
    NSUInteger itemIndex = 0;
    for (NSUInteger ringIndex = 0; ringIndex < ringCounts.count; ringIndex++) {
        NSUInteger count = ringCounts[ringIndex].unsignedIntegerValue;
        CGFloat radius = firstRadius + ringIndex * spacing;
        for (NSUInteger position = 0; position < count; position++) {
            CGFloat fraction = count == 1
                                   ? 0.5
                                   : (CGFloat)position / (CGFloat)(count - 1);
            CGFloat angle = startAngle + (endAngle - startAngle) * fraction;
            CGFloat horizontal = radius * cos(angle);
            CGPoint center = CGPointMake(fromRight ? anchor.x - horizontal
                                                   : anchor.x + horizontal,
                                         anchor.y + radius * sin(angle));
            center.x = MAX(minimumX, MIN(maximumX, center.x));
            center.y = MAX(minimumY, MIN(maximumY, center.y));
            NSString *identifier = self.itemIdentifiers[itemIndex++];
            FLMLandscapeWheelItemView *item =
                [[FLMLandscapeWheelItemView alloc]
                    initWithIdentifier:identifier
                                 image:FLMApplicationIcon(identifier)
                                  size:self.wheelIconSize];
            item.visualCenter = center;
            CGPoint localCenter = [self wheelLocalPointForVisualPoint:center];
            item.center = localCenter;
            [centers addObject:[NSString stringWithFormat:
                                @"%lu:v{%.1f,%.1f}/l{%.1f,%.1f}",
                                (unsigned long)(itemIndex - 1),
                                center.x,
                                center.y,
                                localCenter.x,
                                localCenter.y]];
            item.alpha = 0.0;
            item.transform = CGAffineTransformMakeScale(0.42, 0.42);
            [self.wheelContainer addSubview:item];
            [views addObject:item];
        }
    }
    self.itemViews = views;
    self.wheelWindow.hidden = NO;
    [views enumerateObjectsUsingBlock:^(FLMLandscapeWheelItemView *item,
                                        NSUInteger index,
                                        BOOL *stop) {
        (void)stop;
        [UIView animateWithDuration:0.38
                              delay:MIN(index * 0.018, 0.12)
             usingSpringWithDamping:0.74
              initialSpringVelocity:0.45
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
                             item.alpha = 1.0;
                             item.transform = CGAffineTransformIdentity;
                         }
                         completion:nil];
    }];
    FLMEnqueueDiagnosticLine(
        @"landscape wheel-present side=%@ bounds=%@ safeInsets=%@ anchor={%.1f,%.1f} radius=%.1f rings=%lu centers=[%@] windowFrame=%@ windowBounds=%@ root=%@",
        fromRight ? @"right" : @"left",
        NSStringFromCGRect(visualBounds),
        NSStringFromUIEdgeInsets(safeInsets),
        anchor.x,
        anchor.y,
        firstRadius,
        (unsigned long)ringCounts.count,
        [centers componentsJoinedByString:@","],
        NSStringFromCGRect(self.wheelWindow.frame),
        NSStringFromCGRect(self.wheelWindow.bounds),
        NSStringFromCGRect(self.wheelWindow.rootViewController.view.bounds));
}

- (FLMLandscapeWheelItemView *)wheelItemNearPoint:(CGPoint)point {
    FLMLandscapeWheelItemView *nearest = nil;
    CGFloat distance = CGFLOAT_MAX;
    for (FLMLandscapeWheelItemView *item in self.itemViews) {
        CGFloat candidate = hypot(point.x - item.visualCenter.x,
                                  point.y - item.visualCenter.y);
        if (candidate < distance) {
            distance = candidate;
            nearest = item;
        }
    }
    return distance <= self.wheelIconSize * 0.5 + 12.0 ? nearest : nil;
}

- (FLMLandscapeWheelItemView *)wheelItemNearLocalPoint:(CGPoint)point {
    FLMLandscapeWheelItemView *nearest = nil;
    CGFloat distance = CGFLOAT_MAX;
    for (FLMLandscapeWheelItemView *item in self.itemViews) {
        CGFloat candidate = hypot(point.x - item.center.x,
                                  point.y - item.center.y);
        if (candidate < distance) {
            distance = candidate;
            nearest = item;
        }
    }
    return distance <= self.wheelIconSize * 0.5 + 12.0 ? nearest : nil;
}

- (void)updateWheelHighlightForPoint:(CGPoint)point {
    FLMLandscapeWheelItemView *nearest = [self wheelItemNearPoint:point];
    if (nearest == self.highlightedItem) {
        return;
    }
    self.highlightedItem.highlighted = NO;
    self.highlightedItem = nearest;
    self.highlightedItem.highlighted = YES;
    if (nearest) {
        if (@available(iOS 10.0, *)) {
            [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
        }
    }
}

- (void)pinWheel {
    if (self.wheelWindow.hidden) {
        return;
    }
    self.highlightedItem.highlighted = NO;
    self.highlightedItem = nil;
    self.wheelPinned = YES;
    self.wheelWindow.userInteractionEnabled = YES;
    // The visible full-display wheel window is now the sole owner of pinned
    // taps. A system-manager modal recognizer receives raw display coordinates
    // and can end first, dismissing the wheel with a nil item before UIKit's
    // window-local tap recognizer sees the icon.
    self.globalModalGesture.enabled = NO;
    self.wheelTapGesture.enabled = YES;
    [self refreshGestureAvailability];
    FLMEnqueueDiagnosticLine(
        @"landscape wheel-pinned input=window-local mode=%@ frame=%@ bounds=%@",
        FLMLRawCoordinateModeName(self.wheelRawCoordinateMode),
        NSStringFromCGRect(self.wheelWindow.frame),
        NSStringFromCGRect(self.wheelWindow.bounds));
}

- (void)handleModalGesture:(UILongPressGestureRecognizer *)gesture {
    if (!self.wheelPinned) {
        return;
    }
    CGPoint point = [self visualPointForGesture:gesture];
    if (gesture.state == UIGestureRecognizerStateBegan ||
        gesture.state == UIGestureRecognizerStateChanged) {
        [self updateWheelHighlightForPoint:point];
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        [self dismissWheelLaunchingItem:[self wheelItemNearPoint:point]];
    }
}

- (void)handleWheelTap:(UITapGestureRecognizer *)gesture {
    if (!self.wheelPinned || gesture.state != UIGestureRecognizerStateEnded) {
        return;
    }
    CGPoint localPoint = [gesture locationInView:self.wheelContainer];
    FLMLandscapeWheelItemView *item =
        [self wheelItemNearLocalPoint:localPoint];
    NSString *localCenter = item ? NSStringFromCGPoint(item.center) : @"<none>";
    NSString *visualCenter =
        item ? NSStringFromCGPoint(item.visualCenter) : @"<none>";
    FLMEnqueueDiagnosticLine(
        @"landscape wheel-tap input=window-local local={%.1f,%.1f} selected=%@ localCenter=%@ visualCenter=%@",
        localPoint.x,
        localPoint.y,
        item.identifier ?: @"<none>",
        localCenter,
        visualCenter);
    [self dismissWheelLaunchingItem:item];
}

- (void)dismissWheelLaunchingItem:(FLMLandscapeWheelItemView *)item {
    if (!self.wheelWindow ||
        (self.wheelWindow.hidden && !self.wheelPinned && !item)) {
        return;
    }
    NSString *identifier = [item.identifier copy];
    FLMEnqueueDiagnosticLine(
        @"landscape wheel-dismiss selected=%@ pinned=%d hidden=%d mode=%@",
        identifier ?: @"<none>",
        self.wheelPinned,
        self.wheelWindow.hidden,
        FLMLRawCoordinateModeName(self.wheelRawCoordinateMode));
    self.highlightedItem.highlighted = NO;
    self.highlightedItem = nil;
    self.wheelPinned = NO;
    self.wheelGestureActive = NO;
    self.wheelDismissInProgress = YES;
    self.globalModalGesture.enabled = NO;
    self.wheelWindow.userInteractionEnabled = NO;
    [self refreshGestureAvailability];
    if (self.wheelWindow.hidden) {
        self.wheelDismissInProgress = NO;
        [self refreshGestureAvailability];
        if (identifier.length > 0) {
            [self activateIdentifier:identifier];
        }
        return;
    }
    [UIView animateWithDuration:0.22
                     animations:^{
                         self.wheelContainer.alpha = 0.0;
                         for (FLMLandscapeWheelItemView *view in self.itemViews) {
                             view.alpha = 0.0;
                             view.transform = CGAffineTransformMakeScale(0.78,
                                                                          0.78);
                         }
                     }
                     completion:^(__unused BOOL finished) {
                         self.wheelWindow.hidden = YES;
                         self.wheelContainer.alpha = 1.0;
                         [self.itemViews makeObjectsPerformSelector:
                                             @selector(removeFromSuperview)];
                         self.itemViews = @[];
                         self.wheelDismissInProgress = NO;
                         [self refreshGestureAvailability];
                         if (identifier.length > 0) {
                             [self activateIdentifier:identifier];
                         }
                     }];
}

- (void)activateIdentifier:(NSString *)identifier {
    if (identifier.length == 0 || ![self isLandscapeActive] ||
        FLMDeviceIsLocked()) {
        FLMEnqueueDiagnosticLine(
            @"landscape wheel-activate rejected app=%@ landscape=%d locked=%d",
            identifier ?: @"<none>",
            [self isLandscapeActive],
            FLMDeviceIsLocked());
        return;
    }
    NSString *frontmostIdentifier = FLMFrontmostApplicationIdentifier();
    FLMEnqueueDiagnosticLine(
        @"landscape wheel-activate request app=%@ frontmost=%@ state=%lu",
        identifier,
        frontmostIdentifier ?: @"<none>",
        (unsigned long)self.cardState);
    if ([identifier isEqualToString:FLYME_LOCK_SCREEN_ITEM]) {
        UIApplication *application = [UIApplication sharedApplication];
        if ([application respondsToSelector:@selector(_simulateLockButtonPress)]) {
            [application _simulateLockButtonPress];
        }
        return;
    }
    if (self.cardState == FLMLCardStateClosing) {
        self.queuedIdentifier = [identifier copy];
        return;
    }
    if (self.cardState != FLMLCardStateInactive) {
        if ([identifier isEqualToString:self.identifier]) {
            [self beginFullscreenHandoff];
        } else {
            self.queuedIdentifier = [identifier copy];
            [self closeCardKeepingApplication:YES fullscreenIdentifier:nil];
        }
        return;
    }
    if ([identifier isEqualToString:frontmostIdentifier]) {
        FLMEnqueueDiagnosticLine(
            @"landscape wheel-activate ignored=frontmost app=%@",
            identifier);
        return;
    }
    [self openIdentifier:identifier];
}

- (void)configureLaunchCoverForIdentifier:(NSString *)identifier {
    self.launchIconView.image = FLMApplicationIcon(identifier);
    self.launchCoverView.hidden = NO;
    self.launchCoverView.alpha = 1.0;
    self.statusLabel.hidden = NO;
    self.statusLabel.text = @"正在打开…";
    [self layoutHostView];
}

- (void)beginKeyboardRouteForCurrentScene {
    if (!self.scene || self.identifier.length == 0 ||
        self.cardState != FLMLCardStateOperation) {
        return;
    }
    self.keyboardSessionCounter += 1;
    if (self.keyboardSessionCounter == 0) {
        self.keyboardSessionCounter = 1;
    }
    self.keyboardSessionGeneration = 0x10000ULL |
                                     self.keyboardSessionCounter;
    FLMPublishKeyboardState(self.identifier,
                            self.scene,
                            self.keyboardSessionGeneration);
    [self layoutHostView];
    FLMEnqueueDiagnosticLine(
        @"landscape route-begin app=%@ scene=%@ session=%lu card=%@",
        self.identifier,
        FLMSceneIdentifier(self.scene) ?: @"<none>",
        (unsigned long)self.keyboardSessionGeneration,
        NSStringFromCGRect(self.cardContainer.frame));
}

- (void)openIdentifier:(NSString *)identifier {
    if (identifier.length == 0 || ![self isLandscapeActive] ||
        self.cardState != FLMLCardStateInactive) {
        return;
    }
    FLMQuiescePortraitControllerForLandscape();
    FLMPublishKeyboardState(nil, nil, 0);
    self.identifier = [identifier copy];
    self.cardState = FLMLCardStateLaunching;
    self.dockedOnRight = NO;
    self.dockVerticalCenter = 0.0;
    self.launchGeneration += 1;
    NSUInteger generation = self.launchGeneration;
    self.launchStartedAt = CACurrentMediaTime();
    self.scenePreparedAt = 0.0;
    self.sceneEntity = nil;
    self.sceneHandle = nil;
    self.scene = nil;
    self.presentationManager = nil;
    self.presenter = nil;
    self.presenterScene = nil;
    self.hostView = nil;
    self.keyboardSessionGeneration = 0;
    self.keyboardVisible = NO;
    self.keyboardFrame = CGRectNull;
    self.keyboardFramePending = NO;
    self.pendingKeyboardFrame = CGRectNull;
    [self discardKeyboardLayerHost];
    self.previousKeyWindow = FLMCurrentKeyWindow();
    self.cardWindow.passesTouchesOutsideCard = NO;
    self.cardWindow.keyboardPassThroughFrame = CGRectNull;
    self.contentShield.hidden = YES;
    self.edgeHandle.hidden = YES;
    self.edgeHandleBar.alpha = 1.0;
    self.dimView.alpha = 0.0;
    [self setCardFrameWithoutAnimation:[self operationFrame]];
    [self configureLaunchCoverForIdentifier:identifier];
    self.cardContainer.alpha = 0.0;
    self.cardContainer.transform = CGAffineTransformMakeScale(0.90, 0.90);
    self.shadowView.alpha = 0.0;
    [self.cardWindow makeKeyAndVisible];
    [UIView animateWithDuration:0.38
                          delay:0.0
         usingSpringWithDamping:0.84
          initialSpringVelocity:0.30
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         self.dimView.alpha = 1.0;
                         self.cardContainer.alpha = 1.0;
                         self.cardContainer.transform = CGAffineTransformIdentity;
                         self.shadowView.alpha = 1.0;
                     }
                     completion:nil];
    FLMPrewarmApplicationIdentifier(identifier);
    FLMEnqueueDiagnosticLine(
        @"landscape card-open app=%@ generation=%lu frame=%@ orientation=%ld safe=%@",
        identifier,
        (unsigned long)generation,
        NSStringFromCGRect(self.cardContainer.frame),
        (long)FLMLActiveInterfaceOrientation(),
        NSStringFromCGRect([self safeRect]));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.03 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self attachIdentifier:identifier generation:generation attempt:0];
    });
}

- (id)sceneForHandle:(FLMLApplicationSceneHandle *)handle {
    if (!handle) {
        return nil;
    }
    @try {
        id scene = [handle respondsToSelector:@selector(sceneIfExists)]
                       ? [handle sceneIfExists]
                       : nil;
        if (!scene && [handle respondsToSelector:@selector(scene)]) {
            scene = [handle scene];
        }
        return scene;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

- (FLMLApplicationSceneHandle *)sceneHandleForIdentifier:(NSString *)identifier {
    if (identifier.length == 0) {
        return nil;
    }
    @try {
        if (self.sceneEntity &&
            [self.sceneEntity respondsToSelector:@selector(sceneHandle)]) {
            FLMLApplicationSceneHandle *existing = [self.sceneEntity sceneHandle];
            if ([self sceneForHandle:existing]) {
                return existing;
            }
            self.sceneEntity = nil;
            self.sceneHandle = nil;
        }
        Class controllerClass = NSClassFromString(@"SBApplicationController");
        FLMLSBApplicationController *controller =
            (FLMLSBApplicationController *)[controllerClass sharedInstance];
        if (![controller respondsToSelector:
                         @selector(applicationWithBundleIdentifier:)]) {
            return nil;
        }
        id application = [controller applicationWithBundleIdentifier:identifier];
        if (!application) {
            return nil;
        }
        Class entityClass = NSClassFromString(@"SBDeviceApplicationSceneEntity");
        SEL initializer =
            @selector(initWithApplicationForMainDisplay:
                 generatingNewPrimarySceneIfRequired:);
        id allocated = [entityClass alloc];
        if (!allocated || ![allocated respondsToSelector:initializer]) {
            return nil;
        }
        BOOL generate = self.launchStartedAt > 0.0 &&
                        CACurrentMediaTime() - self.launchStartedAt >=
                            FLMLSceneGenerationDelay;
        FLMLDeviceApplicationSceneEntity *entity =
            [(FLMLDeviceApplicationSceneEntity *)allocated
                initWithApplicationForMainDisplay:application
                generatingNewPrimarySceneIfRequired:generate];
        FLMLApplicationSceneHandle *handle =
            [entity respondsToSelector:@selector(sceneHandle)]
                ? [entity sceneHandle]
                : nil;
        if (handle && (generate || [self sceneForHandle:handle])) {
            self.sceneEntity = entity;
        }
        return handle;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

- (BOOL)prepareScene:(id)scene handle:(FLMLApplicationSceneHandle *)handle {
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
        id settings = [scene respondsToSelector:@selector(settings)]
                          ? [scene settings]
                          : nil;
        id mutableSettings = [settings mutableCopy];
        if (!mutableSettings &&
            [scene respondsToSelector:@selector(mutableSettings)]) {
            mutableSettings = [scene mutableSettings];
        }
        if (!mutableSettings) {
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
            [mutableSettings setFrame:CGRectMake(0.0,
                                                  0.0,
                                                  FLMLLogicalWidth,
                                                  FLMLLogicalHeight)];
        }
        if ([mutableSettings respondsToSelector:
                                 @selector(setInterfaceOrientation:)]) {
            [mutableSettings setInterfaceOrientation:
                                 UIInterfaceOrientationPortrait];
        }
        if (![scene respondsToSelector:
                       @selector(updateSettings:withTransitionContext:)]) {
            FLMClearProtectedScene(scene);
            return NO;
        }
        [scene updateSettings:mutableSettings withTransitionContext:nil];
        FLMEnqueueDiagnosticLine(
            @"landscape scene-prepare scene=%@ logical={390.0,844.0} orientation=portrait physical=%@",
            FLMSceneIdentifier(scene) ?: @"<none>",
            NSStringFromCGRect([self displayBounds]));
        return YES;
    } @catch (__unused NSException *exception) {
        FLMClearProtectedScene(scene);
        return NO;
    }
}

- (UIView *)hostViewForHandle:(FLMLApplicationSceneHandle *)handle {
    id scene = [self sceneForHandle:handle];
    if (![self prepareScene:scene handle:handle]) {
        return nil;
    }
    BOOL changed = scene != self.scene;
    if (changed) {
        self.scene = scene;
        self.scenePreparedAt = CACurrentMediaTime();
        self.presentationManager = nil;
        self.presenter = nil;
        self.presenterScene = nil;
        return nil;
    }
    if (self.scenePreparedAt > 0.0 &&
        CACurrentMediaTime() - self.scenePreparedAt < FLMLSceneSettleDelay) {
        return nil;
    }
    @try {
        id manager = self.presentationManager;
        if (!manager &&
            [scene respondsToSelector:@selector(uiPresentationManager)]) {
            manager = [scene uiPresentationManager];
        }
        if (!manager &&
            [scene respondsToSelector:@selector(presentationManager)]) {
            manager = [scene presentationManager];
        }
        id presenter = self.presenter;
        if (!presenter &&
            [manager respondsToSelector:
                         @selector(createPresenterWithIdentifier:)]) {
            presenter = [manager createPresenterWithIdentifier:
                                     @"com.codex.flymemultitasking.landscape"];
            if ([presenter respondsToSelector:@selector(activate)]) {
                [presenter activate];
            }
        }
        self.presentationManager = manager;
        self.presenter = presenter;
        self.presenterScene = scene;
        UIView *host =
            [presenter respondsToSelector:@selector(presentationView)]
                ? [presenter presentationView]
                : nil;
        if (![host isKindOfClass:[UIView class]]) {
            return nil;
        }
        host.backgroundColor = [UIColor blackColor];
        host.clipsToBounds = NO;
        return host;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

- (void)attachIdentifier:(NSString *)identifier
               generation:(NSUInteger)generation
                  attempt:(NSUInteger)attempt {
    if (generation != self.launchGeneration ||
        ![identifier isEqualToString:self.identifier] ||
        self.cardState != FLMLCardStateLaunching || self.cardWindow.hidden) {
        return;
    }
    if (CACurrentMediaTime() - self.launchStartedAt > FLMLLaunchTimeout) {
        [self failLaunchForIdentifier:identifier generation:generation];
        return;
    }
    FLMLApplicationSceneHandle *handle =
        [self sceneHandleForIdentifier:identifier];
    id resolvedScene = [self sceneForHandle:handle];
    if (!handle || !resolvedScene) {
        self.statusLabel.text = @"正在准备应用…";
        if (attempt > 0 && attempt % 6 == 0) {
            self.sceneEntity = nil;
            self.sceneHandle = nil;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(FLMLScenePollInterval *
                                               NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self attachIdentifier:identifier
                        generation:generation
                           attempt:attempt + 1];
        });
        return;
    }
    UIView *host = [self hostViewForHandle:handle];
    if (!host) {
        self.statusLabel.text = @"正在连接画面…";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(FLMLScenePollInterval *
                                               NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self attachIdentifier:identifier
                        generation:generation
                           attempt:attempt + 1];
        });
        return;
    }
    self.sceneHandle = handle;
    self.hostView = host;
    host.autoresizingMask = UIViewAutoresizingNone;
    host.userInteractionEnabled = YES;
    [self.cardContainer insertSubview:host atIndex:0];
    self.cardState = FLMLCardStateOperation;
    self.statusLabel.hidden = YES;
    self.contentShield.hidden = YES;
    self.edgeHandle.hidden = NO;
    self.edgeHandleBar.alpha = 1.0;
    self.cardWindow.passesTouchesOutsideCard = NO;
    [self setCardFrameWithoutAnimation:[self operationFrame]];
    [self layoutHandleForFrame:self.cardContainer.frame hiddenSide:0];
    [self beginKeyboardRouteForCurrentScene];
    [UIView animateWithDuration:0.10
                     animations:^{
                         self.launchCoverView.alpha = 0.0;
                     }
                     completion:^(__unused BOOL finished) {
                         self.launchCoverView.hidden = YES;
                         self.launchCoverView.alpha = 1.0;
                     }];
    [self.cardWindow makeKeyWindow];
    FLMEnqueueDiagnosticLine(
        @"landscape content-ready app=%@ generation=%lu attempt=%lu scene=%@ host=%p logical={390.0,844.0} card=%@ scale=%.6f",
        identifier,
        (unsigned long)generation,
        (unsigned long)attempt,
        FLMSceneIdentifier(self.scene) ?: @"<none>",
        (__bridge void *)host,
        NSStringFromCGRect(self.cardContainer.frame),
        CGRectGetWidth(self.cardContainer.frame) / FLMLLogicalWidth);
}

- (void)failLaunchForIdentifier:(NSString *)identifier
                      generation:(NSUInteger)generation {
    if (generation != self.launchGeneration ||
        self.cardState != FLMLCardStateLaunching) {
        return;
    }
    FLMEnqueueDiagnosticLine(
        @"landscape launch-failed app=%@ generation=%lu fallback=ios-fullscreen",
        identifier,
        (unsigned long)generation);
    [self closeCardKeepingApplication:YES fullscreenIdentifier:identifier];
}

- (CGRect)presentationFrameForView:(UIView *)view {
    if (!view) {
        return CGRectNull;
    }
    CGRect frame = view.frame;
    CALayer *presentation = (CALayer *)view.layer.presentationLayer;
    if (presentation) {
        CGRect candidate = presentation.frame;
        if (!CGRectIsNull(candidate) && !CGRectIsEmpty(candidate) &&
            isfinite(CGRectGetMinX(candidate)) &&
            isfinite(CGRectGetMinY(candidate)) &&
            isfinite(CGRectGetWidth(candidate)) &&
            isfinite(CGRectGetHeight(candidate))) {
            frame = candidate;
        }
    }
    return frame;
}

- (UIView *)movingCardView {
    return self.transitionSnapshot ?: self.cardContainer;
}

- (void)beginTransitionSnapshot {
    if (self.transitionSnapshot) {
        CGRect frame = [self presentationFrameForView:self.transitionSnapshot];
        [self.transitionSnapshot.layer removeAllAnimations];
        self.transitionSnapshot.frame = frame;
        self.cardWindow.cardInteractionFrame = frame;
        self.transitionGeneration += 1;
        return;
    }
    CGRect source = [self presentationFrameForView:self.cardContainer];
    [self.cardContainer.layer removeAllAnimations];
    self.cardContainer.frame = source;
    UIView *snapshot = [self.cardContainer snapshotViewAfterScreenUpdates:NO];
    if (snapshot) {
        snapshot.frame = source;
        snapshot.userInteractionEnabled = NO;
        snapshot.layer.cornerRadius = self.cardContainer.layer.cornerRadius;
        snapshot.layer.masksToBounds = YES;
        [self.cardWindow.rootViewController.view
            insertSubview:snapshot
               belowSubview:self.edgeHandle];
        self.transitionSnapshot = snapshot;
        self.cardContainer.alpha = 0.0;
    }
    self.cardWindow.cardInteractionFrame = source;
    self.transitionGeneration += 1;
}

- (void)setMovingCardFrame:(CGRect)frame {
    UIView *moving = [self movingCardView];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    moving.transform = CGAffineTransformIdentity;
    moving.frame = frame;
    self.shadowView.frame = frame;
    self.cardWindow.cardInteractionFrame = frame;
    [CATransaction commit];
}

- (void)finishTransitionAtFrame:(CGRect)frame {
    [self.transitionSnapshot.layer removeAllAnimations];
    [self.cardContainer.layer removeAllAnimations];
    [self.transitionSnapshot removeFromSuperview];
    self.transitionSnapshot = nil;
    self.cardContainer.alpha = 1.0;
    self.transitionActive = NO;
    self.transitionTargetState = FLMLCardStateInactive;
    self.transitionTargetFrame = CGRectNull;
    [self setCardFrameWithoutAnimation:frame];
}

- (void)takeOverCurrentTransitionIfNeeded {
    if (!self.transitionActive && !self.transitionSnapshot) {
        return;
    }
    UIView *moving = [self movingCardView];
    CGRect visual = [self presentationFrameForView:moving];
    FLMLCardState targetState = self.transitionTargetState;
    self.transitionGeneration += 1;
    [moving.layer removeAllAnimations];
    [self.edgeHandle.layer removeAllAnimations];
    [self.edgeHandleBar.layer removeAllAnimations];
    [self.dimView.layer removeAllAnimations];
    [self finishTransitionAtFrame:visual];
    if (targetState == FLMLCardStateOperation) {
        self.cardState = FLMLCardStateOperation;
        self.contentShield.hidden = YES;
        self.hostView.userInteractionEnabled = YES;
        self.cardWindow.passesTouchesOutsideCard = NO;
        self.edgeHandle.hidden = NO;
        self.edgeHandleBar.alpha = 1.0;
    } else if (targetState == FLMLCardStateHidden) {
        self.cardState = FLMLCardStateHidden;
        self.cardWindow.cardInteractionFrame = CGRectNull;
        self.cardWindow.passesTouchesOutsideCard = YES;
        self.contentShield.hidden = NO;
        self.hostView.userInteractionEnabled = NO;
        self.edgeHandle.hidden = NO;
        self.edgeHandleBar.alpha = 1.0;
    } else {
        self.cardState = FLMLCardStateDocked;
        self.cardWindow.passesTouchesOutsideCard = YES;
        self.contentShield.hidden = NO;
        self.hostView.userInteractionEnabled = NO;
        self.edgeHandle.hidden = YES;
    }
    FLMEnqueueDiagnosticLine(
        @"landscape transition-takeover target=%lu visual=%@ generation=%lu",
        (unsigned long)targetState,
        NSStringFromCGRect(visual),
        (unsigned long)self.transitionGeneration);
}

- (void)animateMovingCardToFrame:(CGRect)target
                     targetState:(FLMLCardState)targetState
                        duration:(NSTimeInterval)duration
                      animations:(void (^ _Nullable)(void))animations
                      completion:(void (^ _Nullable)(void))completion {
    [self beginTransitionSnapshot];
    NSUInteger generation = ++self.transitionGeneration;
    self.transitionActive = YES;
    self.transitionTargetState = targetState;
    self.transitionTargetFrame = target;
    CGRect source = [self presentationFrameForView:[self movingCardView]];
    self.cardWindow.cardInteractionFrame = CGRectUnion(source, target);
    [UIView animateWithDuration:duration
                          delay:0.0
         usingSpringWithDamping:0.86
          initialSpringVelocity:0.25
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         [self movingCardView].frame = target;
                         self.shadowView.frame = target;
                         if (animations) {
                             animations();
                         }
                     }
                     completion:^(__unused BOOL finished) {
                         if (generation != self.transitionGeneration ||
                             self.transitionTargetState != targetState) {
                             return;
                         }
                         [self finishTransitionAtFrame:target];
                         self.cardState = targetState;
                         if (completion) {
                             completion();
                         }
                     }];
}

- (void)handleOperationPan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:
                                      self.cardWindow.rootViewController.view];
    CGPoint velocity = [gesture velocityInView:
                                self.cardWindow.rootViewController.view];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.cardState = FLMLCardStateDockTransition;
        self.operationPanStartFrame =
            [self presentationFrameForView:self.cardContainer];
        self.contentShield.hidden = NO;
        self.hostView.userInteractionEnabled = NO;
        [self beginTransitionSnapshot];
        self.transitionActive = YES;
        self.transitionTargetState = FLMLCardStateOperation;
        self.transitionTargetFrame = self.operationPanStartFrame;
        return;
    }
    if (self.cardState != FLMLCardStateDockTransition) {
        return;
    }
    CGFloat threshold = MAX(32.0, self.centeredDockSwipeThreshold);
    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGRect frame = self.operationPanStartFrame;
        CGFloat progress = MIN(1.0, fabs(translation.x) /
                                      MAX(72.0,
                                          CGRectGetWidth(frame) * 0.48));
        if (translation.x < 0.0) {
            CGRect dock = [self dockFrameOnRight:NO
                                  verticalCenter:CGRectGetMidY(frame)];
            frame = FLMLInterpolateRect(self.operationPanStartFrame,
                                        dock,
                                        progress);
        } else {
            frame.origin.x += translation.x * 0.42;
            frame.origin.y += translation.y * 0.08;
        }
        [self setMovingCardFrame:frame];
        [self layoutHandleForFrame:frame hiddenSide:0];
        self.edgeHandleBar.alpha = 1.0 - progress;
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        BOOL commitDock = gesture.state == UIGestureRecognizerStateEnded &&
                          (translation.x <= -threshold || velocity.x <= -520.0);
        BOOL commitFullscreen = gesture.state == UIGestureRecognizerStateEnded &&
                                (translation.x >= threshold || velocity.x >= 520.0);
        if (commitDock) {
            [self commitOperationToDock];
        } else if (commitFullscreen) {
            [self beginFullscreenHandoff];
        } else {
            [self cancelOperationTransition];
        }
    }
}

- (void)cancelOperationTransition {
    CGRect target = [self operationFrame];
    [self animateMovingCardToFrame:target
                       targetState:FLMLCardStateOperation
                          duration:0.26
                        animations:^{
                            self.edgeHandleBar.alpha = 1.0;
                            self.dimView.alpha = 1.0;
                            [self layoutHandleForFrame:target hiddenSide:0];
                        }
                        completion:^{
                            self.contentShield.hidden = YES;
                            self.hostView.userInteractionEnabled = YES;
                            self.cardWindow.passesTouchesOutsideCard = NO;
                            self.edgeHandle.hidden = NO;
                            self.cardWindow.handleInteractionFrame =
                                self.edgeHandle.frame;
                        }];
}

- (void)commitOperationToDock {
    [self endKeyboardSession];
    self.dockedOnRight = NO;
    CGRect target = [self dockFrameOnRight:NO
                            verticalCenter:CGRectGetMidY(
                                               self.operationPanStartFrame)];
    self.dockVerticalCenter = CGRectGetMidY(target);
    [self animateMovingCardToFrame:target
                       targetState:FLMLCardStateDocked
                          duration:0.34
                        animations:^{
                            self.edgeHandleBar.alpha = 0.0;
                            self.dimView.alpha = 0.0;
                            [self layoutHandleForFrame:target hiddenSide:0];
                        }
                        completion:^{
                            self.edgeHandle.hidden = YES;
                            self.cardWindow.handleInteractionFrame = CGRectNull;
                            self.cardWindow.passesTouchesOutsideCard = YES;
                            self.contentShield.hidden = NO;
                            self.hostView.userInteractionEnabled = NO;
                            if (self.previousKeyWindow &&
                                self.previousKeyWindow != self.cardWindow) {
                                [self.previousKeyWindow makeKeyWindow];
                            }
                            FLMEnqueueDiagnosticLine(
                                @"landscape dock-entry settled side=left frame=%@ contentBlocked=1",
                                NSStringFromCGRect(target));
                        }];
}

- (void)handleDockTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded ||
        self.cardState != FLMLCardStateDocked) {
        return;
    }
    [self returnDockToOperation];
}

- (void)returnDockToOperation {
    CGRect target = [self operationFrame];
    self.cardState = FLMLCardStateDockTransition;
    self.contentShield.hidden = NO;
    self.hostView.userInteractionEnabled = NO;
    self.edgeHandle.hidden = NO;
    self.edgeHandleBar.alpha = 0.0;
    [self layoutHandleForFrame:target hiddenSide:0];
    self.cardWindow.passesTouchesOutsideCard = NO;
    [self.cardWindow makeKeyWindow];
    [self animateMovingCardToFrame:target
                       targetState:FLMLCardStateOperation
                          duration:0.36
                        animations:^{
                            self.dimView.alpha = 1.0;
                            self.edgeHandleBar.alpha = 1.0;
                        }
                        completion:^{
                            self.contentShield.hidden = YES;
                            self.hostView.userInteractionEnabled = YES;
                            self.edgeHandle.hidden = NO;
                            self.cardWindow.passesTouchesOutsideCard = NO;
                            [self beginKeyboardRouteForCurrentScene];
                            FLMEnqueueDiagnosticLine(
                                @"landscape dock-tap return=operation-left frame=%@ contentEnabled=1",
                                NSStringFromCGRect(target));
                        }];
}

- (CGRect)freeDraggedDockFrameForTranslation:(CGPoint)translation {
    CGRect frame = self.dockPanStartFrame;
    frame.origin.x += translation.x;
    frame.origin.y += translation.y;
    CGRect safe = [self safeRect];
    frame.origin.x = MAX(CGRectGetMinX(safe),
                         MIN(CGRectGetMaxX(safe) - CGRectGetWidth(frame),
                             frame.origin.x));
    frame.origin.y = MAX(CGRectGetMinY(safe) + FLMLCardVerticalMargin,
                         MIN(CGRectGetMaxY(safe) - FLMLCardVerticalMargin -
                                 CGRectGetHeight(frame),
                             frame.origin.y));
    return frame;
}

- (void)handleDockPan:(UIPanGestureRecognizer *)gesture {
    UIView *root = self.cardWindow.rootViewController.view;
    CGPoint translation = [gesture translationInView:root];
    CGPoint velocity = [gesture velocityInView:root];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self beginTransitionSnapshot];
        self.transitionActive = YES;
        self.transitionTargetState = FLMLCardStateDocked;
        self.dockPanStartFrame =
            [self presentationFrameForView:[self movingCardView]];
        self.dockPanStartPoint = [gesture locationInView:root];
        self.edgeHandle.hidden = YES;
        return;
    }
    if (self.cardState != FLMLCardStateDocked) {
        return;
    }
    CGFloat outward = self.dockedOnRight ? translation.x : -translation.x;
    BOOL horizontalIntent = fabs(translation.x) >=
                            fabs(translation.y) * FLMLHideIntentRatio;
    if (gesture.state == UIGestureRecognizerStateChanged) {
        if (outward > 0.0 && horizontalIntent) {
            CGFloat progress = MIN(1.0,
                                   outward /
                                       MAX(64.0,
                                           CGRectGetWidth(
                                               self.dockPanStartFrame) * 0.60));
            CGRect hidden = [self hiddenFrameOnRight:self.dockedOnRight
                                      verticalCenter:CGRectGetMidY(
                                                         self.dockPanStartFrame)];
            CGRect frame = FLMLInterpolateRect(self.dockPanStartFrame,
                                               hidden,
                                               progress);
            [self setMovingCardFrame:frame];
            [self layoutHandleForFrame:frame
                            hiddenSide:self.dockedOnRight ? 1 : -1];
            self.edgeHandle.hidden = NO;
            self.edgeHandleBar.alpha = progress;
        } else {
            self.edgeHandle.hidden = YES;
            self.edgeHandleBar.alpha = 0.0;
            [self setMovingCardFrame:
                      [self freeDraggedDockFrameForTranslation:translation]];
        }
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        CGFloat outwardVelocity = self.dockedOnRight ? velocity.x : -velocity.x;
        BOOL hide = gesture.state == UIGestureRecognizerStateEnded &&
                    horizontalIntent &&
                    (outward >= FLMLHideIntentDistance ||
                     outwardVelocity >= 620.0);
        if (hide) {
            [self settleDockToHidden];
        } else {
            [self settleDraggedDock];
        }
    }
}

- (void)settleDraggedDock {
    CGRect current = [self presentationFrameForView:[self movingCardView]];
    CGRect safe = [self safeRect];
    self.dockedOnRight = CGRectGetMidX(current) > CGRectGetMidX(safe);
    self.dockVerticalCenter = CGRectGetMidY(current);
    CGRect target = [self dockFrameOnRight:self.dockedOnRight
                            verticalCenter:self.dockVerticalCenter];
    self.dockVerticalCenter = CGRectGetMidY(target);
    [self animateMovingCardToFrame:target
                       targetState:FLMLCardStateDocked
                          duration:0.34
                        animations:^{
                            self.edgeHandleBar.alpha = 0.0;
                            self.edgeHandle.alpha = 0.0;
                        }
                        completion:^{
                            self.edgeHandle.hidden = YES;
                            self.edgeHandle.alpha = 1.0;
                            self.cardWindow.handleInteractionFrame = CGRectNull;
                            self.cardWindow.passesTouchesOutsideCard = YES;
                            self.contentShield.hidden = NO;
                            self.hostView.userInteractionEnabled = NO;
                            FLMEnqueueDiagnosticLine(
                                @"landscape dock-snap side=%@ frame=%@ centerRule=right-only-when-greater",
                                self.dockedOnRight ? @"right" : @"left",
                                NSStringFromCGRect(target));
                        }];
}

- (void)settleDockToHidden {
    self.cardState = FLMLCardStateHiddenTransition;
    CGRect current = [self presentationFrameForView:[self movingCardView]];
    self.dockVerticalCenter = CGRectGetMidY(current);
    CGRect target = [self hiddenFrameOnRight:self.dockedOnRight
                              verticalCenter:self.dockVerticalCenter];
    [self layoutHandleForFrame:target
                    hiddenSide:self.dockedOnRight ? 1 : -1];
    self.edgeHandle.hidden = NO;
    [self animateMovingCardToFrame:target
                       targetState:FLMLCardStateHidden
                          duration:0.30
                        animations:^{
                            self.edgeHandle.alpha = 1.0;
                            self.edgeHandleBar.alpha = 1.0;
                        }
                        completion:^{
                            self.cardWindow.cardInteractionFrame = CGRectNull;
                            self.cardWindow.passesTouchesOutsideCard = YES;
                            self.contentShield.hidden = NO;
                            self.hostView.userInteractionEnabled = NO;
                            FLMEnqueueDiagnosticLine(
                                @"landscape dock-hidden side=%@ card=%@ handle=%@",
                                self.dockedOnRight ? @"right" : @"left",
                                NSStringFromCGRect(target),
                                NSStringFromCGRect(self.edgeHandle.frame));
                        }];
}

- (void)handleHiddenPan:(UIPanGestureRecognizer *)gesture {
    UIView *root = self.cardWindow.rootViewController.view;
    CGPoint translation = [gesture translationInView:root];
    CGPoint velocity = [gesture velocityInView:root];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.cardState = FLMLCardStateHiddenTransition;
        self.hiddenPanStartFrame = self.cardContainer.frame;
        self.hiddenPanStartPoint = [gesture locationInView:root];
        self.transitionGeneration += 1;
        self.transitionActive = YES;
        self.transitionTargetState = FLMLCardStateHidden;
        self.transitionTargetFrame = self.hiddenPanStartFrame;
        return;
    }
    if (self.cardState != FLMLCardStateHiddenTransition) {
        return;
    }
    CGFloat inward = self.dockedOnRight ? -translation.x : translation.x;
    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGFloat progress = MIN(1.0,
                               MAX(0.0, inward) /
                                   MAX(64.0,
                                       CGRectGetWidth(
                                           self.hiddenPanStartFrame) * 0.60));
        CGRect dock = [self dockFrameOnRight:self.dockedOnRight
                              verticalCenter:self.dockVerticalCenter];
        CGRect frame = FLMLInterpolateRect(self.hiddenPanStartFrame,
                                           dock,
                                           progress);
        [self setCardFrameWithoutAnimation:frame];
        [self layoutHandleForFrame:frame
                        hiddenSide:self.dockedOnRight ? 1 : -1];
        self.edgeHandleBar.alpha = 1.0 - progress;
        self.cardWindow.cardInteractionFrame = frame;
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        CGFloat inwardVelocity = self.dockedOnRight ? -velocity.x : velocity.x;
        BOOL restore = gesture.state == UIGestureRecognizerStateEnded &&
                       (inward >= FLMLHideIntentDistance ||
                        inwardVelocity >= 620.0);
        [self finishHiddenPanRestoring:restore];
    }
}

- (void)finishHiddenPanRestoring:(BOOL)restore {
    CGRect target = restore
                        ? [self dockFrameOnRight:self.dockedOnRight
                                 verticalCenter:self.dockVerticalCenter]
                        : [self hiddenFrameOnRight:self.dockedOnRight
                                   verticalCenter:self.dockVerticalCenter];
    FLMLCardState targetState = restore ? FLMLCardStateDocked
                                        : FLMLCardStateHidden;
    NSUInteger generation = ++self.transitionGeneration;
    self.transitionTargetState = targetState;
    self.transitionTargetFrame = target;
    [UIView animateWithDuration:0.28
                          delay:0.0
         usingSpringWithDamping:0.88
          initialSpringVelocity:0.20
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         [self setCardFrameWithoutAnimation:target];
                         self.edgeHandleBar.alpha = restore ? 0.0 : 1.0;
                         [self layoutHandleForFrame:target
                                         hiddenSide:self.dockedOnRight ? 1 : -1];
                     }
                     completion:^(__unused BOOL finished) {
                         if (generation != self.transitionGeneration) {
                             return;
                         }
                         self.transitionActive = NO;
                         self.transitionTargetState = FLMLCardStateInactive;
                         self.transitionTargetFrame = CGRectNull;
                         self.cardState = targetState;
                         self.cardWindow.passesTouchesOutsideCard = YES;
                         self.contentShield.hidden = NO;
                         self.hostView.userInteractionEnabled = NO;
                         if (restore) {
                             self.edgeHandle.hidden = YES;
                             self.cardWindow.handleInteractionFrame = CGRectNull;
                             self.cardWindow.cardInteractionFrame = target;
                         } else {
                             self.edgeHandle.hidden = NO;
                             self.cardWindow.cardInteractionFrame = CGRectNull;
                         }
                         FLMEnqueueDiagnosticLine(
                             @"landscape hidden-pan restore=%d side=%@ frame=%@",
                             restore,
                             self.dockedOnRight ? @"right" : @"left",
                             NSStringFromCGRect(target));
                     }];
}

- (void)handleBackdropTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateEnded &&
        self.cardState == FLMLCardStateOperation) {
        [self closeCardKeepingApplication:YES fullscreenIdentifier:nil];
    }
}

- (void)beginFullscreenHandoff {
    if ((self.cardState != FLMLCardStateOperation &&
         self.cardState != FLMLCardStateDockTransition) ||
        self.identifier.length == 0) {
        return;
    }
    NSString *identifier = [self.identifier copy];
    [self endKeyboardSession];
    self.cardState = FLMLCardStateFullscreenHandoff;
    [self beginTransitionSnapshot];
    NSUInteger generation = ++self.transitionGeneration;
    self.transitionActive = YES;
    self.transitionTargetState = FLMLCardStateFullscreenHandoff;
    UIView *moving = [self movingCardView];
    CGRect target = [self presentationFrameForView:moving];
    target.origin.x += MAX(86.0, CGRectGetWidth(target) * 0.45);
    self.transitionTargetFrame = target;
    [UIView animateWithDuration:0.20
                     animations:^{
                         moving.frame = target;
                         moving.alpha = 0.36;
                         self.edgeHandle.alpha = 0.0;
                         self.dimView.alpha = 0.0;
                     }
                     completion:^(__unused BOOL finished) {
                         if (generation != self.transitionGeneration) {
                             return;
                         }
                         [self closeCardKeepingApplication:YES
                                      fullscreenIdentifier:identifier];
                     }];
    FLMEnqueueDiagnosticLine(
        @"landscape fullscreen-handoff app=%@ policy=ios-normal orientation=%ld",
        identifier,
        (long)FLMLActiveInterfaceOrientation());
}

- (void)backgroundScene:(id)scene {
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
        CGRect physical = [self displayBounds];
        if ([mutableSettings respondsToSelector:@selector(setFrame:)]) {
            [mutableSettings setFrame:physical];
        }
        if ([mutableSettings respondsToSelector:
                                 @selector(setInterfaceOrientation:)]) {
            [mutableSettings setInterfaceOrientation:
                                 FLMLActiveInterfaceOrientation()];
        }
        if ([mutableSettings respondsToSelector:@selector(setForeground:)]) {
            [mutableSettings setForeground:NO];
        }
        if ([mutableSettings respondsToSelector:@selector(setBackgrounded:)]) {
            [mutableSettings setBackgrounded:YES];
        }
        if (mutableSettings &&
            [scene respondsToSelector:
                       @selector(updateSettings:withTransitionContext:)]) {
            [scene updateSettings:mutableSettings withTransitionContext:nil];
        }
    } @catch (__unused NSException *exception) {
    }
    FLMClearProtectedScene(scene);
}

- (void)activateFullscreenIdentifier:(NSString *)identifier {
    if (identifier.length == 0) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.02 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIApplication *application = [UIApplication sharedApplication];
        if ([application respondsToSelector:
                         @selector(launchApplicationWithIdentifier:suspended:)] &&
            [application launchApplicationWithIdentifier:identifier
                                                suspended:NO]) {
            return;
        }
        id workspace = [NSClassFromString(@"LSApplicationWorkspace")
            defaultWorkspace];
        if ([workspace respondsToSelector:
                          @selector(openApplicationWithBundleID:)]) {
            [workspace openApplicationWithBundleID:identifier];
        }
    });
}

- (void)closeCardKeepingApplication:(BOOL)keepApplication
                fullscreenIdentifier:(NSString *)fullscreenIdentifier {
    if (self.cardState == FLMLCardStateInactive ||
        self.cardState == FLMLCardStateClosing) {
        if (fullscreenIdentifier.length > 0) {
            [self activateFullscreenIdentifier:fullscreenIdentifier];
        }
        return;
    }
    self.cardState = FLMLCardStateClosing;
    self.launchGeneration += 1;
    self.transitionGeneration += 1;
    self.transitionActive = NO;
    [self.transitionSnapshot.layer removeAllAnimations];
    [self.transitionSnapshot removeFromSuperview];
    self.transitionSnapshot = nil;
    self.cardContainer.alpha = 1.0;
    [self endKeyboardSession];
    id scene = self.scene;
    id presenter = self.presenter;
    UIView *host = self.hostView;
    UIWindow *previous = self.previousKeyWindow;
    NSString *closedIdentifier = [self.identifier copy];
    NSString *queuedIdentifier = [self.queuedIdentifier copy];
    self.queuedIdentifier = nil;
    self.scene = nil;
    self.sceneHandle = nil;
    self.sceneEntity = nil;
    self.presentationManager = nil;
    self.presenter = nil;
    self.presenterScene = nil;
    self.hostView = nil;
    self.identifier = nil;
    self.previousKeyWindow = nil;
    self.cardWindow.cardInteractionFrame = CGRectNull;
    self.cardWindow.handleInteractionFrame = CGRectNull;
    self.cardWindow.keyboardPassThroughFrame = CGRectNull;
    if (previous && previous != self.cardWindow) {
        [previous makeKeyWindow];
    }
    NSUInteger closeGeneration = self.transitionGeneration;
    [UIView animateWithDuration:0.22
                     animations:^{
                         self.cardContainer.alpha = 0.0;
                         self.shadowView.alpha = 0.0;
                         self.edgeHandle.alpha = 0.0;
                         self.dimView.alpha = 0.0;
                     }
                     completion:^(__unused BOOL finished) {
                         if (closeGeneration != self.transitionGeneration ||
                             self.cardState != FLMLCardStateClosing) {
                             return;
                         }
                         [host removeFromSuperview];
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
                         self.cardWindow.hidden = YES;
                         self.cardState = FLMLCardStateInactive;
                         self.cardContainer.alpha = 1.0;
                         self.shadowView.alpha = 1.0;
                         self.edgeHandle.alpha = 1.0;
                         self.edgeHandle.hidden = NO;
                         self.edgeHandleBar.alpha = 1.0;
                         self.launchCoverView.hidden = YES;
                         self.statusLabel.hidden = YES;
                         [self refreshGestureAvailability];
                         NSString *nextIdentifier =
                             self.queuedIdentifier.length > 0
                                 ? [self.queuedIdentifier copy]
                                 : queuedIdentifier;
                         self.queuedIdentifier = nil;
                         FLMEnqueueDiagnosticLine(
                             @"landscape card-close app=%@ fullscreen=%@ queued=%@ keep=%d",
                             closedIdentifier ?: @"<none>",
                             fullscreenIdentifier ?: @"<none>",
                             nextIdentifier ?: @"<none>",
                             keepApplication);
                         if (fullscreenIdentifier.length > 0 &&
                             !FLMDeviceIsLocked()) {
                             [self activateFullscreenIdentifier:
                                       fullscreenIdentifier];
                         } else if (nextIdentifier.length > 0 &&
                                    [self isLandscapeActive] &&
                                    !FLMDeviceIsLocked()) {
                             [self openIdentifier:nextIdentifier];
                         }
                     }];
}

- (void)protectedSceneDidDisappear:(NSNotification *)notification {
    (void)notification;
    if (self.cardState != FLMLCardStateInactive &&
        self.cardState != FLMLCardStateClosing) {
        FLMEnqueueDiagnosticLine(
            @"landscape protected-scene-disappeared app=%@ state=%lu",
            self.identifier ?: @"<none>",
            (unsigned long)self.cardState);
        [self closeCardKeepingApplication:NO fullscreenIdentifier:nil];
    }
}

- (void)prepareKeyboardWindowIfNeeded {
    UIWindowScene *targetScene = self.cardWindow.windowScene ?: [self foregroundWindowScene];
    if (!targetScene) {
        return;
    }
    if (self.keyboardWindow && self.keyboardWindow.windowScene != targetScene) {
        [self discardKeyboardLayerHost];
        self.keyboardWindow.hidden = YES;
        self.keyboardWindow.rootViewController = nil;
        self.keyboardWindow = nil;
    }
    if (!self.keyboardWindow) {
        self.keyboardWindow =
            [[FLMLandscapeKeyboardWindow alloc] initWithWindowScene:targetScene];
        self.keyboardWindow.windowLevel = self.cardWindow.windowLevel + 1.0;
        self.keyboardWindow.backgroundColor = [UIColor clearColor];
        self.keyboardWindow.opaque = NO;
        self.keyboardWindow.userInteractionEnabled = YES;
        self.keyboardWindow.keyboardInteractionFrame = CGRectNull;
        self.keyboardWindow.rootViewController =
            [self newRootControllerWithLayoutCallback:NO];
        self.keyboardWindow.hidden = YES;
    }
    self.keyboardWindow.frame = [self displayBounds];
    self.keyboardWindow.rootViewController.view.frame = self.keyboardWindow.bounds;
    self.keyboardWindow.windowLevel = self.cardWindow.windowLevel + 1.0;
}

- (BOOL)propagateKeyboardScenePairing:(id)keyboardScene
                preferredHostIdentity:(id)preferredHostIdentity
                    sessionGeneration:(NSUInteger)sessionGeneration {
    if (!keyboardScene || !preferredHostIdentity || sessionGeneration == 0 ||
        sessionGeneration != self.keyboardSessionGeneration ||
        self.cardState != FLMLCardStateOperation) {
        return NO;
    }
    if (self.keyboardScene == keyboardScene &&
        self.keyboardPreferredHostIdentity == preferredHostIdentity &&
        self.keyboardPairingSessionGeneration == sessionGeneration) {
        return YES;
    }
    SEL updateSelector = NSSelectorFromString(@"updateClientSettingsWithBlock:");
    if (![keyboardScene respondsToSelector:updateSelector]) {
        return NO;
    }
    self.keyboardScene = keyboardScene;
    self.keyboardPreferredHostIdentity = preferredHostIdentity;
    self.keyboardPairingSessionGeneration = sessionGeneration;
    __block BOOL applied = NO;
    void (^settingsBlock)(id) = ^(id mutableSettings) {
        @try {
            id currentIdentity = nil;
            @try {
                currentIdentity =
                    [mutableSettings valueForKey:@"preferredSceneHostIdentity"];
            } @catch (__unused NSException *exception) {
            }
            if (currentIdentity && currentIdentity != preferredHostIdentity &&
                ![currentIdentity isEqual:preferredHostIdentity]) {
                return;
            }
            SEL setter = NSSelectorFromString(@"setPreferredSceneHostIdentity:");
            if ([mutableSettings respondsToSelector:setter]) {
                ((void (*)(id, SEL, id))objc_msgSend)(mutableSettings,
                                                     setter,
                                                     preferredHostIdentity);
            } else {
                [mutableSettings setValue:preferredHostIdentity
                                   forKey:@"preferredSceneHostIdentity"];
            }
            applied = YES;
        } @catch (__unused NSException *exception) {
        }
    };
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(keyboardScene,
                                             updateSelector,
                                             settingsBlock);
    } @catch (__unused NSException *exception) {
        applied = NO;
    }
    if (!applied) {
        self.keyboardScene = nil;
        self.keyboardPreferredHostIdentity = nil;
        self.keyboardPairingSessionGeneration = 0;
    }
    FLMEnqueueDiagnosticLine(
        @"landscape keyboard-pair apply=%d session=%lu keyboardScene=%@ preferred=%p",
        applied,
        (unsigned long)sessionGeneration,
        FLMSceneIdentifier(keyboardScene) ?: @"<none>",
        (__bridge void *)preferredHostIdentity);
    return applied;
}

- (void)clearKeyboardScenePairingForSession:(NSUInteger)sessionGeneration {
    id keyboardScene = self.keyboardScene;
    id ownedIdentity = self.keyboardPreferredHostIdentity;
    BOOL owned = keyboardScene && sessionGeneration != 0 &&
                 self.keyboardPairingSessionGeneration == sessionGeneration;
    SEL updateSelector = NSSelectorFromString(@"updateClientSettingsWithBlock:");
    if (owned && [keyboardScene respondsToSelector:updateSelector]) {
        void (^settingsBlock)(id) = ^(id mutableSettings) {
            @try {
                id currentIdentity = nil;
                @try {
                    currentIdentity =
                        [mutableSettings valueForKey:
                                             @"preferredSceneHostIdentity"];
                } @catch (__unused NSException *exception) {
                }
                if (currentIdentity && ownedIdentity &&
                    currentIdentity != ownedIdentity &&
                    ![currentIdentity isEqual:ownedIdentity]) {
                    return;
                }
                SEL setter =
                    NSSelectorFromString(@"setPreferredSceneHostIdentity:");
                if ([mutableSettings respondsToSelector:setter]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(mutableSettings,
                                                         setter,
                                                         nil);
                } else {
                    [mutableSettings setValue:nil
                                       forKey:@"preferredSceneHostIdentity"];
                }
            } @catch (__unused NSException *exception) {
            }
        };
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(keyboardScene,
                                                 updateSelector,
                                                 settingsBlock);
        } @catch (__unused NSException *exception) {
        }
    }
    self.keyboardScene = nil;
    self.keyboardPreferredHostIdentity = nil;
    self.keyboardPairingSessionGeneration = 0;
}

- (void)keyboardLayerHostView:(UIView *)hostView
            didUpdateForScene:(id)updatedScene
            sessionGeneration:(NSUInteger)sessionGeneration {
    if (!hostView || sessionGeneration == 0 ||
        sessionGeneration != self.keyboardSessionGeneration ||
        self.cardState != FLMLCardStateOperation || !self.scene ||
        !self.hostView || self.identifier.length == 0) {
        return;
    }
    id owningScene = nil;
    id keyboardScene = nil;
    id preferredIdentity = nil;
    BOOL paired = NO;
    @try {
        owningScene = [hostView valueForKey:@"_owningScene"];
        keyboardScene = [hostView valueForKey:@"_keyboardScene"];
        preferredIdentity =
            [hostView valueForKey:@"_keyboardPreferredHostIdentity"];
        id value = [hostView valueForKey:@"_isPaired"];
        paired = [value respondsToSelector:@selector(boolValue)] &&
                 [value boolValue];
    } @catch (__unused NSException *exception) {
    }
    if (!paired || !keyboardScene || !preferredIdentity) {
        FLMEnqueueDiagnosticLine(
            @"landscape keyboard-host deferred paired=%d keyboardScene=%@ preferred=%p session=%lu",
            paired,
            FLMSceneIdentifier(keyboardScene) ?: @"<none>",
            (__bridge void *)preferredIdentity,
            (unsigned long)sessionGeneration);
        if (self.keyboardHostRetrySession != sessionGeneration) {
            self.keyboardHostRetrySession = sessionGeneration;
            self.keyboardHostRetryAttempt = 0;
        }
        if (self.keyboardHostRetryAttempt < 20) {
            self.keyboardHostRetryAttempt += 1;
            NSUInteger retryAttempt = self.keyboardHostRetryAttempt;
            __weak UIView *weakHost = hostView;
            __weak id weakUpdatedScene = updatedScene;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.03 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (self.keyboardSessionGeneration != sessionGeneration ||
                    self.cardState != FLMLCardStateOperation ||
                    retryAttempt != self.keyboardHostRetryAttempt) {
                    return;
                }
                UIView *retryHost = weakHost;
                if (retryHost) {
                    [self keyboardLayerHostView:retryHost
                              didUpdateForScene:weakUpdatedScene
                              sessionGeneration:sessionGeneration];
                }
            });
        }
        return;
    }
    self.keyboardHostRetrySession = 0;
    self.keyboardHostRetryAttempt = 0;
    NSString *targetIdentifier = FLMSceneIdentifier(self.scene);
    NSString *ownerIdentifier = FLMSceneIdentifier(owningScene);
    NSString *updatedIdentifier = FLMSceneIdentifier(updatedScene);
    BOOL matches = owningScene == self.scene || updatedScene == self.scene;
    if (!matches && targetIdentifier.length > 0) {
        matches = [targetIdentifier isEqualToString:ownerIdentifier] ||
                  [targetIdentifier isEqualToString:updatedIdentifier];
    }
    if (!matches) {
        FLMEnqueueDiagnosticLine(
            @"landscape keyboard-host rejected=scene target=%@ owner=%@ updated=%@",
            targetIdentifier ?: @"<none>",
            ownerIdentifier ?: @"<none>",
            updatedIdentifier ?: @"<none>");
        return;
    }
    if (self.keyboardLayerHostView &&
        hostView != self.keyboardLayerHostView &&
        self.keyboardHostSessionGeneration == sessionGeneration) {
        FLMEnqueueDiagnosticLine(
            @"landscape keyboard-host rejected=alternate active=%p incoming=%p session=%lu",
            (__bridge void *)self.keyboardLayerHostView,
            (__bridge void *)hostView,
            (unsigned long)sessionGeneration);
        return;
    }
    [self propagateKeyboardScenePairing:keyboardScene
                  preferredHostIdentity:preferredIdentity
                      sessionGeneration:sessionGeneration];
    [self prepareKeyboardWindowIfNeeded];
    UIView *forwardingRoot = self.keyboardWindow.rootViewController.view;
    if (!forwardingRoot) {
        return;
    }
    if (hostView != self.keyboardLayerHostView ||
        self.keyboardHostSessionGeneration != sessionGeneration) {
        [self discardKeyboardLayerHost];
        UIView *originalSuperview = hostView.superview;
        self.keyboardOriginalSuperview = originalSuperview;
        self.keyboardOriginalSubviewIndex =
            originalSuperview
                ? [originalSuperview.subviews indexOfObject:hostView]
                : NSNotFound;
        self.keyboardOriginalFrame = hostView.frame;
        self.keyboardOriginalTransform = hostView.transform;
        self.keyboardOriginalAutoresizingMask = hostView.autoresizingMask;
        self.keyboardOriginalTranslatesAutoresizingMask =
            hostView.translatesAutoresizingMaskIntoConstraints;
        self.keyboardLayerHostView = hostView;
        self.keyboardHostSessionGeneration = sessionGeneration;
    }
    if (hostView.superview != forwardingRoot) {
        [hostView removeFromSuperview];
        hostView.translatesAutoresizingMaskIntoConstraints = YES;
        hostView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                    UIViewAutoresizingFlexibleHeight;
        hostView.transform = CGAffineTransformIdentity;
        hostView.frame = forwardingRoot.bounds;
        [forwardingRoot addSubview:hostView];
    } else {
        hostView.transform = CGAffineTransformIdentity;
        hostView.frame = forwardingRoot.bounds;
    }
    [hostView setNeedsLayout];
    [hostView layoutIfNeeded];
    if (self.keyboardVisible) {
        [self.keyboardWindow makeKeyAndVisible];
    } else {
        self.keyboardWindow.hidden = YES;
    }
    if (self.keyboardFramePending) {
        CGRect pending = self.pendingKeyboardFrame;
        self.keyboardFramePending = NO;
        self.pendingKeyboardFrame = CGRectNull;
        [self applyKeyboardFrame:pending visible:YES];
    }
    FLMEnqueueDiagnosticLine(
        @"landscape keyboard-host paired host=%p session=%lu frame=%@ key=%d",
        (__bridge void *)hostView,
        (unsigned long)sessionGeneration,
        NSStringFromCGRect(hostView.frame),
        self.keyboardWindow.isKeyWindow);
}

- (void)deactivateKeyboardWindow {
    BOOL wasKey = self.keyboardWindow.isKeyWindow;
    self.keyboardWindow.keyboardInteractionFrame = CGRectNull;
    self.keyboardWindow.hidden = YES;
    if (wasKey && self.cardState == FLMLCardStateOperation &&
        !self.cardWindow.hidden) {
        [self.cardWindow makeKeyWindow];
    }
}

- (void)discardKeyboardLayerHost {
    UIView *host = self.keyboardLayerHostView;
    @try {
        [host removeFromSuperview];
    } @catch (__unused NSException *exception) {
    }
    self.keyboardLayerHostView = nil;
    self.keyboardOriginalSuperview = nil;
    self.keyboardOriginalSubviewIndex = NSNotFound;
    self.keyboardHostSessionGeneration = 0;
    [self deactivateKeyboardWindow];
}

- (CGRect)convertedKeyboardFrameFromScreenFrame:(CGRect)screenFrame {
    UIScreen *screen = self.cardWindow.windowScene.screen ?: [UIScreen mainScreen];
    CGRect bounds = self.cardWindow.bounds;
    CGRect current = [screen.coordinateSpace
        convertRect:screenFrame
  toCoordinateSpace:self.cardWindow];
    CGRect fixed = [screen.fixedCoordinateSpace
        convertRect:screenFrame
  toCoordinateSpace:self.cardWindow];
    CGRect direct = screenFrame;
    CGRect candidates[] = {current, fixed, direct};
    CGRect best = CGRectNull;
    CGFloat bestScore = -CGFLOAT_MAX;
    for (NSUInteger index = 0; index < 3; index++) {
        CGRect intersection = CGRectIntersection(bounds, candidates[index]);
        if (CGRectIsNull(intersection) || CGRectIsEmpty(intersection)) {
            continue;
        }
        CGFloat area = CGRectGetWidth(intersection) *
                       CGRectGetHeight(intersection);
        CGFloat widthCoverage = CGRectGetWidth(intersection) /
                                MAX(1.0, CGRectGetWidth(bounds));
        CGFloat bottomDistance = fabs(CGRectGetMaxY(intersection) -
                                      CGRectGetMaxY(bounds));
        CGFloat score = area + widthCoverage * 10000.0 -
                        bottomDistance * 20.0;
        if (score > bestScore) {
            bestScore = score;
            best = intersection;
        }
    }
    return best;
}

- (CGFloat)logicalAvoidanceForKeyboardFrame:(CGRect)keyboardFrame {
    if (CGRectIsNull(keyboardFrame) || CGRectIsEmpty(keyboardFrame)) {
        return 0.0;
    }
    CGRect overlap = CGRectIntersection(self.cardContainer.frame,
                                        keyboardFrame);
    if (CGRectIsNull(overlap) || CGRectIsEmpty(overlap)) {
        return 0.0;
    }
    CGFloat scale = CGRectGetWidth(self.cardContainer.frame) /
                    FLMLLogicalWidth;
    scale = MAX(0.05, scale);
    CGFloat logical = CGRectGetHeight(overlap) / scale + 8.0 / scale;
    return MIN(FLMLLogicalHeight * 0.72, logical);
}

- (void)applyKeyboardFrame:(CGRect)frame visible:(BOOL)visible {
    if (self.cardState != FLMLCardStateOperation ||
        self.keyboardSessionGeneration == 0 || !self.scene) {
        visible = NO;
    }
    if (visible && (!self.keyboardLayerHostView ||
                    self.keyboardHostSessionGeneration !=
                        self.keyboardSessionGeneration)) {
        self.keyboardFramePending = YES;
        self.pendingKeyboardFrame = frame;
        FLMEnqueueDiagnosticLine(
            @"landscape keyboard-frame deferred session=%lu frame=%@ host=%p",
            (unsigned long)self.keyboardSessionGeneration,
            NSStringFromCGRect(frame),
            (__bridge void *)self.keyboardLayerHostView);
        return;
    }
    if (!visible) {
        self.keyboardVisible = NO;
        self.keyboardFrame = CGRectNull;
        self.keyboardFramePending = NO;
        self.pendingKeyboardFrame = CGRectNull;
        self.cardWindow.keyboardPassThroughFrame = CGRectNull;
        [self deactivateKeyboardWindow];
        FLMPublishKeyboardAvoidance(self.keyboardSessionGeneration, 0.0, NO);
        return;
    }
    [self prepareKeyboardWindowIfNeeded];
    self.keyboardVisible = YES;
    self.keyboardFrame = frame;
    CGFloat protectedTop = MAX(CGRectGetMinY(self.cardWindow.bounds),
                               CGRectGetMinY(frame) -
                                   FLMLKeyboardAccessoryProtectionHeight);
    CGRect interaction = CGRectMake(CGRectGetMinX(self.cardWindow.bounds),
                                    protectedTop,
                                    CGRectGetWidth(self.cardWindow.bounds),
                                    CGRectGetMaxY(self.cardWindow.bounds) -
                                        protectedTop);
    self.cardWindow.keyboardPassThroughFrame = interaction;
    self.keyboardWindow.keyboardInteractionFrame = interaction;
    CGFloat avoidance = [self logicalAvoidanceForKeyboardFrame:frame];
    FLMPublishKeyboardAvoidance(self.keyboardSessionGeneration,
                                avoidance,
                                YES);
    [self.keyboardWindow makeKeyAndVisible];
    FLMEnqueueDiagnosticLine(
        @"landscape keyboard-frame visible=1 physical=%@ interaction=%@ card=%@ intersection=%@ logicalAvoidance=%.2f scale=%.6f orientation=%ld",
        NSStringFromCGRect(frame),
        NSStringFromCGRect(interaction),
        NSStringFromCGRect(self.cardContainer.frame),
        NSStringFromCGRect(CGRectIntersection(self.cardContainer.frame, frame)),
        avoidance,
        CGRectGetWidth(self.cardContainer.frame) / FLMLLogicalWidth,
        (long)FLMLActiveInterfaceOrientation());
}

- (void)keyboardFrameWillChange:(NSNotification *)notification {
    if (self.cardState != FLMLCardStateOperation ||
        self.keyboardSessionGeneration == 0) {
        return;
    }
    NSValue *value = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (![value isKindOfClass:[NSValue class]]) {
        return;
    }
    CGRect raw = value.CGRectValue;
    CGRect converted = [self convertedKeyboardFrameFromScreenFrame:raw];
    BOOL visible = !CGRectIsNull(converted) && !CGRectIsEmpty(converted) &&
                   CGRectGetHeight(converted) > 40.0 &&
                   CGRectGetWidth(converted) > 100.0 &&
                   CGRectGetMinY(converted) <
                       CGRectGetMaxY(self.cardWindow.bounds) - 1.0;
    FLMEnqueueDiagnosticLine(
        @"landscape keyboard-notification raw=%@ converted=%@ visible=%d bounds=%@ orientation=%ld",
        NSStringFromCGRect(raw),
        NSStringFromCGRect(converted),
        visible,
        NSStringFromCGRect(self.cardWindow.bounds),
        (long)FLMLActiveInterfaceOrientation());
    if (visible) {
        [self applyKeyboardFrame:converted visible:YES];
    } else {
        // Interactive dismissal may finish with only a frame-change
        // notification. Clear the forwarding window immediately instead of
        // depending on UIKeyboardDidHideNotification arriving afterwards.
        [self applyKeyboardFrame:CGRectNull visible:NO];
    }
}

- (void)keyboardDidHide:(NSNotification *)notification {
    (void)notification;
    if (self.keyboardSessionGeneration != 0) {
        [self applyKeyboardFrame:CGRectNull visible:NO];
    }
}

- (void)endKeyboardSession {
    NSUInteger endingSession = self.keyboardSessionGeneration;
    UIView *endingHost = self.keyboardLayerHostView;
    self.keyboardFramePending = NO;
    self.pendingKeyboardFrame = CGRectNull;
    if (endingSession == 0) {
        [self deactivateKeyboardWindow];
        return;
    }
    [self.hostView endEditing:YES];
    FLMPublishKeyboardAvoidance(endingSession, 0.0, NO);
    FLMPublishKeyboardCardGeometry(endingSession,
                                   0.0,
                                   0.0,
                                   0.0,
                                   0.0,
                                   NO);
    [self clearKeyboardScenePairingForSession:endingSession];
    self.keyboardSessionGeneration = 0;
    self.keyboardHostRetrySession = 0;
    self.keyboardHostRetryAttempt += 1;
    FLMPublishKeyboardState(nil, nil, 0);
    self.keyboardVisible = NO;
    self.keyboardFrame = CGRectNull;
    self.cardWindow.keyboardPassThroughFrame = CGRectNull;
    [self deactivateKeyboardWindow];
    FLMEnqueueDiagnosticLine(
        @"landscape route-end session=%lu host=%p",
        (unsigned long)endingSession,
        (__bridge void *)endingHost);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.24 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.keyboardSessionGeneration == 0 && endingHost &&
            self.keyboardLayerHostView == endingHost &&
            self.keyboardHostSessionGeneration == endingSession) {
            [self discardKeyboardLayerHost];
        }
    });
}

@end

static void FLMLPreferencesChanged(CFNotificationCenterRef center,
                                   void *observer,
                                   CFStringRef name,
                                   const void *object,
                                   CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[FLMLandscapeCoordinator sharedCoordinator] reloadPreferences];
    });
}

void FLMLandscapeStart(void) {
    [[FLMLandscapeCoordinator sharedCoordinator] start];
}

NSUInteger FLMLandscapeKeyboardSessionGeneration(void) {
    FLMLandscapeCoordinator *coordinator =
        [FLMLandscapeCoordinator sharedCoordinator];
    return coordinator.cardState == FLMLCardStateOperation
               ? coordinator.keyboardSessionGeneration
               : 0;
}

void FLMLandscapeKeyboardHostDidUpdate(UIView *hostView,
                                       id scene,
                                       NSUInteger sessionGeneration) {
    [[FLMLandscapeCoordinator sharedCoordinator]
        keyboardLayerHostView:hostView
             didUpdateForScene:scene
             sessionGeneration:sessionGeneration];
}
