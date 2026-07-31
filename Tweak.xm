#import <UIKit/UIKit.h>
#import <math.h>
#import <notify.h>
#import <objc/message.h>
#import <stdint.h>
#import <unistd.h>

#import "FLMSceneLifecycle.h"

#define FLYME_RUNTIME_NOTIFICATION "com.codex.flymemultitasking.runtime"
#define FLYME_PREFERENCES_NOTIFICATION CFSTR("com.codex.flymemultitasking.preferences-changed")
#define FLYME_PREFERENCES_DOMAIN CFSTR("com.codex.flymemultitasking")
#define FLYME_RUNTIME_MAGIC 0x464C594DULL
#define FLYME_LOCK_SCREEN_ITEM @"com.codex.flymemultitasking.lockscreen"

static const CGFloat FLMDefaultWheelRadius = 202.0;
static const CGFloat FLMMinimumWheelRadius = 170.0;
static const CGFloat FLMMaximumWheelRadius = 225.0;
static const CGFloat FLMDefaultWheelIconSize = 56.0;
static const CGFloat FLMMinimumWheelIconSize = 44.0;
static const CGFloat FLMMaximumWheelIconSize = 68.0;

@interface NSObject (FLMRuntimePrivate)
+ (id)defaultWorkspace;
+ (id)sharedInstance;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleIdentifier;
- (void)lockUIFromSource:(NSInteger)source withOptions:(id)options;
- (id)frontmostApplication;
- (id)_accessibilityFrontMostApplication;
- (NSString *)bundleIdentifier;
- (NSString *)displayIdentifier;
@end

@interface FLMDisplayConfiguration : NSObject
- (id)identity;
@end

@interface UIScreen (FLMRuntimePrivate)
- (FLMDisplayConfiguration *)displayConfiguration;
@end

@interface FLMSystemGestureManager : NSObject
+ (instancetype)sharedInstance;
- (void)addGestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       toDisplayWithIdentity:(id)displayIdentity;
@end

@interface UIApplication (FLMRuntimePrivate)
- (BOOL)launchApplicationWithIdentifier:(NSString *)identifier suspended:(BOOL)suspended;
- (void)_simulateLockButtonPress;
- (UIInterfaceOrientation)statusBarOrientation;
@end

@interface UIImage (FLMRuntimePrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier
                                               format:(NSInteger)format
                                                scale:(CGFloat)scale;
@end

@interface FLMSBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (id)applicationWithBundleIdentifier:(NSString *)bundleIdentifier;
@end

@interface FLMSBApplication : NSObject
@end

@interface FLMApplicationSceneHandle : NSObject
- (NSInteger)currentInterfaceOrientation;
- (id)sceneIfExists;
- (id)scene;
@end

@interface FLMDeviceApplicationSceneEntity : NSObject
- (instancetype)initWithApplicationForMainDisplay:(id)application
             generatingNewPrimarySceneIfRequired:(BOOL)required;
- (FLMApplicationSceneHandle *)sceneHandle;
@end

@interface NSObject (FLMSceneHostingPrivate)
- (id)settings;
- (id)mutableSettings;
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

static BOOL FLMDeviceIsLocked(void) {
    id manager = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
    if (!manager) {
        return NO;
    }
    NSArray<NSString *> *selectorNames =
        @[@"isUILocked", @"isLockScreenVisible", @"isLockScreenActive", @"isLocked"];
    for (NSString *selectorName in selectorNames) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![manager respondsToSelector:selector]) {
            continue;
        }
        BOOL (*getter)(id, SEL) =
            (BOOL (*)(id, SEL))[manager methodForSelector:selector];
        if (getter && getter(manager, selector)) {
            return YES;
        }
    }
    return NO;
}

static UIInterfaceOrientation FLMActiveInterfaceOrientation(void) {
    UIInterfaceOrientation portraitCandidate = UIInterfaceOrientationUnknown;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            if (scene.activationState == UISceneActivationStateForegroundActive ||
                scene.activationState == UISceneActivationStateForegroundInactive) {
                UIInterfaceOrientation orientation =
                    ((UIWindowScene *)scene).interfaceOrientation;
                if (UIInterfaceOrientationIsLandscape(orientation)) {
                    return orientation;
                }
                if (orientation != UIInterfaceOrientationUnknown) {
                    portraitCandidate = orientation;
                }
            }
        }
    }
    UIApplication *application = [UIApplication sharedApplication];
    if ([application respondsToSelector:@selector(statusBarOrientation)]) {
        UIInterfaceOrientation statusBarOrientation =
            [application statusBarOrientation];
        if (UIInterfaceOrientationIsLandscape(statusBarOrientation)) {
            return statusBarOrientation;
        }
        if (statusBarOrientation != UIInterfaceOrientationUnknown) {
            portraitCandidate = statusBarOrientation;
        }
    }
    UIDeviceOrientation deviceOrientation = [UIDevice currentDevice].orientation;
    if (deviceOrientation == UIDeviceOrientationLandscapeLeft) {
        return UIInterfaceOrientationLandscapeRight;
    }
    if (deviceOrientation == UIDeviceOrientationLandscapeRight) {
        return UIInterfaceOrientationLandscapeLeft;
    }
    if (deviceOrientation == UIDeviceOrientationPortraitUpsideDown) {
        return UIInterfaceOrientationPortraitUpsideDown;
    }
    return portraitCandidate != UIInterfaceOrientationUnknown
               ? portraitCandidate
               : UIInterfaceOrientationPortrait;
}

static CGRect FLMVisualScreenBounds(void) {
    CGRect bounds = [UIScreen mainScreen].bounds;
    UIInterfaceOrientation orientation = FLMActiveInterfaceOrientation();
    BOOL targetLandscape = UIInterfaceOrientationIsLandscape(orientation);
    BOOL boundsLandscape =
        CGRectGetWidth(bounds) > CGRectGetHeight(bounds);
    if (targetLandscape && !boundsLandscape) {
        bounds.size = CGSizeMake(bounds.size.height, bounds.size.width);
    }
    return bounds;
}

static CGPoint FLMVisualPointFromRawPoint(CGPoint rawPoint) {
    CGRect rawBounds = [UIScreen mainScreen].bounds;
    UIInterfaceOrientation orientation = FLMActiveInterfaceOrientation();
    BOOL targetLandscape = UIInterfaceOrientationIsLandscape(orientation);
    BOOL rawBoundsLandscape =
        CGRectGetWidth(rawBounds) > CGRectGetHeight(rawBounds);
    if (rawBoundsLandscape || !targetLandscape) {
        return rawPoint;
    }

    CGFloat rawWidth = CGRectGetWidth(rawBounds);
    CGFloat rawHeight = CGRectGetHeight(rawBounds);
    if (orientation == UIInterfaceOrientationLandscapeLeft) {
        return CGPointMake(rawPoint.y, rawWidth - rawPoint.x);
    }
    if (orientation == UIInterfaceOrientationLandscapeRight) {
        return CGPointMake(rawHeight - rawPoint.y, rawPoint.x);
    }
    if (orientation == UIInterfaceOrientationPortraitUpsideDown) {
        return CGPointMake(rawHeight - rawPoint.y, rawWidth - rawPoint.x);
    }
    return rawPoint;
}

static NSString *FLMIdentifierForApplication(id application) {
    if ([application respondsToSelector:@selector(bundleIdentifier)]) {
        NSString *identifier = [application bundleIdentifier];
        if (identifier.length > 0) {
            return identifier;
        }
    }
    if ([application respondsToSelector:@selector(displayIdentifier)]) {
        NSString *identifier = [application displayIdentifier];
        if (identifier.length > 0) {
            return identifier;
        }
    }
    return nil;
}

static NSString *FLMFrontmostApplicationIdentifier(void) {
    id workspaceClass = NSClassFromString(@"SBMainWorkspace");
    id workspace =
        [workspaceClass respondsToSelector:@selector(sharedInstance)]
            ? [workspaceClass sharedInstance]
            : nil;
    if ([workspace respondsToSelector:@selector(frontmostApplication)]) {
        NSString *identifier =
            FLMIdentifierForApplication([workspace frontmostApplication]);
        if (identifier.length > 0) {
            return identifier;
        }
    }
    UIApplication *springBoard = [UIApplication sharedApplication];
    if ([springBoard respondsToSelector:
                         @selector(_accessibilityFrontMostApplication)]) {
        return FLMIdentifierForApplication(
            [springBoard _accessibilityFrontMostApplication]);
    }
    return nil;
}

static BOOL FLMPointInsideCornerTrigger(CGPoint point,
                                        CGRect bounds,
                                        BOOL *fromRight) {
    // User-locked trigger geometry. Do not tune these values in later versions.
    const CGFloat horizontalRadius = 58.0;
    const CGFloat verticalRadius = 65.0;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    CGFloat bottomDistance = height - point.y;
    if (point.x < 0.0 || point.x > width ||
        bottomDistance < 0.0 || bottomDistance > verticalRadius) {
        return NO;
    }

    CGFloat verticalComponent = bottomDistance / verticalRadius;
    CGFloat leftComponent = point.x / horizontalRadius;
    CGFloat rightComponent = (width - point.x) / horizontalRadius;
    BOOL insideLeft =
        leftComponent * leftComponent +
            verticalComponent * verticalComponent <=
        1.0;
    BOOL insideRight =
        rightComponent * rightComponent +
            verticalComponent * verticalComponent <=
        1.0;
    if (fromRight) {
        *fromRight = insideRight && !insideLeft;
    }
    return insideLeft || insideRight;
}

@interface FLMOverlayViewController : UIViewController
@end

@implementation FLMOverlayViewController

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

@end

@interface FLMOverlayWindow : UIWindow
@end

@implementation FLMOverlayWindow

- (BOOL)canBecomeKeyWindow {
    return NO;
}

@end

@interface FLMFloatingWindow : FLMOverlayWindow
@end

@implementation FLMFloatingWindow

- (BOOL)canBecomeKeyWindow {
    return YES;
}

@end

@interface FLMHotspotWindow : UIWindow
@property(nonatomic, assign) BOOL hotspotsEnabled;
@end

@implementation FLMHotspotWindow

- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.hotspotsEnabled) {
        return nil;
    }
    if (!FLMPointInsideCornerTrigger(point, self.bounds, NULL)) {
        return nil;
    }
    return [super hitTest:point withEvent:event];
}

@end

@interface FLMCornerGestureRecognizer : UILongPressGestureRecognizer
@end

@implementation FLMCornerGestureRecognizer

- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)preventingGestureRecognizer {
    (void)preventingGestureRecognizer;
    return NO;
}

- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)preventedGestureRecognizer {
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

@interface FLMOutsideTapGestureRecognizer : UIGestureRecognizer
@property(nonatomic, weak) UIView *protectedView;
@property(nonatomic, weak) UIView *secondaryProtectedView;
@property(nonatomic, assign) CGRect additionalProtectedFrame;
@property(nonatomic, strong) NSMutableDictionary<NSValue *, NSValue *> *startPoints;
@property(nonatomic, assign) NSTimeInterval firstTouchTimestamp;
@end

@implementation FLMOutsideTapGestureRecognizer

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    self = [super initWithTarget:target action:action];
    if (self) {
        _startPoints = [NSMutableDictionary dictionary];
        _additionalProtectedFrame = CGRectNull;
        self.cancelsTouchesInView = NO;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
    }
    return self;
}

- (NSValue *)keyForTouch:(UITouch *)touch {
    return [NSValue valueWithNonretainedObject:touch];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (self.firstTouchTimestamp <= 0.0) {
        UITouch *firstTouch = [touches anyObject];
        self.firstTouchTimestamp = firstTouch.timestamp;
    }
    for (UITouch *touch in touches) {
        CGPoint point = [touch locationInView:self.view];
        if (self.protectedView &&
            CGRectContainsPoint(self.protectedView.frame, point)) {
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
        if (self.secondaryProtectedView &&
            CGRectContainsPoint(self.secondaryProtectedView.frame, point)) {
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
        if (!CGRectIsNull(self.additionalProtectedFrame) &&
            CGRectContainsPoint(self.additionalProtectedFrame, point)) {
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
        self.startPoints[[self keyForTouch:touch]] = [NSValue valueWithCGPoint:point];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for (UITouch *touch in touches) {
        NSValue *startValue = self.startPoints[[self keyForTouch:touch]];
        if (!startValue) {
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
        CGPoint start = startValue.CGPointValue;
        CGPoint current = [touch locationInView:self.view];
        if (hypot(current.x - start.x, current.y - start.y) > 12.0) {
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    NSTimeInterval lastTimestamp = self.firstTouchTimestamp;
    for (UITouch *touch in touches) {
        lastTimestamp = MAX(lastTimestamp, touch.timestamp);
        [self.startPoints removeObjectForKey:[self keyForTouch:touch]];
    }
    if (self.startPoints.count != 0) {
        return;
    }
    self.state =
        lastTimestamp - self.firstTouchTimestamp <= 0.35
            ? UIGestureRecognizerStateRecognized
            : UIGestureRecognizerStateFailed;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    self.state = UIGestureRecognizerStateCancelled;
}

- (void)reset {
    [super reset];
    [self.startPoints removeAllObjects];
    self.firstTouchTimestamp = 0.0;
}

- (BOOL)canBePreventedByGestureRecognizer:
    (UIGestureRecognizer *)preventingGestureRecognizer {
    (void)preventingGestureRecognizer;
    return NO;
}

@end

@interface FLMWheelItemView : UIView
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, assign) BOOL highlighted;
@end

@implementation FLMWheelItemView

- (instancetype)initWithIdentifier:(NSString *)identifier
                             image:(UIImage *)image
                              size:(CGFloat)size {
    self = [super initWithFrame:CGRectMake(0.0, 0.0, size, size)];
    if (self) {
        _identifier = [identifier copy];
        BOOL isLockItem = [identifier isEqualToString:FLYME_LOCK_SCREEN_ITEM];
        self.backgroundColor = isLockItem ? [UIColor systemBlueColor] : [UIColor clearColor];
        self.layer.cornerRadius = size * 0.5;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.22;
        self.layer.shadowRadius = 8.0;
        self.layer.shadowOffset = CGSizeMake(0.0, 3.0);
        self.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:self.bounds].CGPath;

        _iconView = [[UIImageView alloc] initWithImage:image];
        CGFloat lockInset = size * (15.0 / FLMDefaultWheelIconSize);
        _iconView.frame =
            isLockItem ? CGRectInset(self.bounds, lockInset, lockInset) : self.bounds;
        _iconView.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _iconView.contentMode =
            isLockItem ? UIViewContentModeScaleAspectFit : UIViewContentModeScaleAspectFill;
        _iconView.clipsToBounds = YES;
        _iconView.layer.cornerRadius = isLockItem ? 0.0 : size * 0.5;
        [self addSubview:_iconView];
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    if (_highlighted == highlighted) {
        return;
    }
    _highlighted = highlighted;
    CGFloat scale = highlighted ? 1.24 : 1.0;
    self.layer.shadowOpacity = highlighted ? 0.32 : 0.18;
    [UIView animateWithDuration:0.28
                          delay:0.0
         usingSpringWithDamping:0.64
          initialSpringVelocity:0.45
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         self.transform = CGAffineTransformMakeScale(scale, scale);
                     }
                     completion:nil];
}

@end

@interface FLMWheelController : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, strong) FLMOverlayWindow *overlayWindow;
@property(nonatomic, strong) UIView *wheelContainer;
@property(nonatomic, strong) FLMHotspotWindow *hotspotWindow;
@property(nonatomic, strong) FLMOverlayWindow *floatingWindow;
@property(nonatomic, strong) UIView *floatingDimView;
@property(nonatomic, strong) UIView *floatingContainer;
@property(nonatomic, strong) UIView *floatingHandle;
@property(nonatomic, strong) UIView *floatingHandleBar;
@property(nonatomic, strong) UIView *floatingHostView;
@property(nonatomic, strong) UILabel *floatingStatusLabel;
@property(nonatomic, strong) FLMOutsideTapGestureRecognizer *floatingBackdropTap;
@property(nonatomic, strong) UILongPressGestureRecognizer *floatingHandlePress;
@property(nonatomic, strong) UITapGestureRecognizer *floatingHandleTap;
@property(nonatomic, strong) FLMCornerGestureRecognizer *floatingExclusiveGesture;
@property(nonatomic, weak) UIWindow *previousKeyWindow;
@property(nonatomic, strong) FLMCornerGestureRecognizer *cornerGuardGesture;
@property(nonatomic, strong) FLMCornerGestureRecognizer *cornerGesture;
@property(nonatomic, strong) FLMCornerGestureRecognizer *modalGesture;
@property(nonatomic, strong) UITapGestureRecognizer *wheelTapGesture;
@property(nonatomic, strong) id systemGestureManager;
@property(nonatomic, strong) id displayIdentity;
@property(nonatomic, strong) NSArray<FLMWheelItemView *> *itemViews;
@property(nonatomic, copy) NSArray<NSString *> *itemIdentifiers;
@property(nonatomic, weak) FLMWheelItemView *highlightedItem;
@property(nonatomic, assign) BOOL enabled;
@property(nonatomic, assign) BOOL presentingFromRight;
@property(nonatomic, assign) BOOL usesSystemGestureManager;
@property(nonatomic, assign) BOOL wheelPinned;
@property(nonatomic, assign) BOOL wheelGestureActive;
@property(nonatomic, assign) CGFloat wheelRadius;
@property(nonatomic, assign) CGFloat wheelIconSize;
@property(nonatomic, assign) CGPoint floatingHandleStartPoint;
@property(nonatomic, assign) CGRect floatingHandleInitialContainerFrame;
@property(nonatomic, assign) BOOL floatingHandleMoved;
@property(nonatomic, assign) BOOL floatingInteractiveFullscreenTransition;
@property(nonatomic, assign) BOOL floatingInteractiveScenePrepared;
@property(nonatomic, assign) CGSize floatingCenteredReferenceSize;
@property(nonatomic, strong) UIView *floatingInteractiveSnapshot;
@property(nonatomic, assign) BOOL floatingReconnectSuppressed;
@property(nonatomic, assign) BOOL floatingKeyboardVisible;
@property(nonatomic, assign) CGRect floatingKeyboardFrame;
@property(nonatomic, assign) CGFloat lastPortraitKeyboardHeight;
@property(nonatomic, strong) NSMapTable<UIWindow *, NSValue *> *keyboardOriginalFrames;
@property(nonatomic, strong) NSMapTable<UIWindow *, NSNumber *> *keyboardOriginalLevels;
@property(nonatomic, assign) CGPoint cornerGestureStartPoint;
@property(nonatomic, copy) NSString *floatingIdentifier;
@property(nonatomic, strong) FLMDeviceApplicationSceneEntity *floatingSceneEntity;
@property(nonatomic, strong) FLMApplicationSceneHandle *floatingSceneHandle;
@property(nonatomic, strong) id floatingScene;
@property(nonatomic, strong) id floatingPresentationManager;
@property(nonatomic, strong) id floatingPresenter;
@property(nonatomic, assign) CGSize floatingHostReferenceSize;
@property(nonatomic, assign) NSUInteger floatingLaunchGeneration;
@property(nonatomic, strong) NSTimer *lockMonitorTimer;
+ (instancetype)sharedController;
- (void)start;
- (void)reloadPreferences;
- (void)createWindows;
- (void)createFloatingWindow;
- (BOOL)registerGlobalCornerGesture;
- (void)updateWindowFrames;
- (void)orientationDidChange:(NSNotification *)notification;
- (void)handleCornerGuardGesture:(UIGestureRecognizer *)gesture;
- (void)handleCornerGesture:(UIGestureRecognizer *)gesture;
- (void)handleModalGesture:(UIGestureRecognizer *)gesture;
- (BOOL)shouldActivateWheelAtPoint:(CGPoint)point;
- (NSArray<NSNumber *> *)itemCountsByRingForCount:(NSUInteger)count;
- (void)presentWheelFromRight:(BOOL)fromRight;
- (void)updateHighlightForPoint:(CGPoint)point;
- (void)pinWheel;
- (void)handleWheelTap:(UITapGestureRecognizer *)gesture;
- (void)handleFloatingBackdropTap:(UIGestureRecognizer *)gesture;
- (void)handleFloatingHandlePress:(UILongPressGestureRecognizer *)gesture;
- (void)handleFloatingHandleTap:(UITapGestureRecognizer *)gesture;
- (void)handleFloatingExclusiveGesture:(UIGestureRecognizer *)gesture;
- (void)keyboardFrameWillChange:(NSNotification *)notification;
- (void)keyboardWillHide:(NSNotification *)notification;
- (void)applyLandscapeKeyboardLayout;
- (void)restoreKeyboardWindowFrames;
- (void)resetFloatingInteractiveLayoutAnimated:(BOOL)animated;
- (void)layoutFloatingHandleForCurrentContainer;
- (void)prepareFloatingSceneForInteractiveFullscreen;
- (void)restoreFloatingSceneAfterCancelledTransition;
- (BOOL)updateFloatingSceneToReferenceSize:(CGSize)referenceSize
                               orientation:(NSInteger)orientation;
- (void)transitionFloatingWindowToFullscreen;
- (void)finishFullscreenHandoffWithCover:(UIView *)cover
                              identifier:(NSString *)identifier
                                 attempt:(NSUInteger)attempt;
- (void)protectedSceneDidDisappear:(NSNotification *)notification;
- (void)openFloatingIdentifier:(NSString *)identifier;
- (void)attachFloatingIdentifier:(NSString *)identifier
                      generation:(NSUInteger)generation
                         attempt:(NSUInteger)attempt;
- (FLMApplicationSceneHandle *)sceneHandleForIdentifier:(NSString *)identifier;
- (id)sceneForHandle:(FLMApplicationSceneHandle *)sceneHandle;
- (BOOL)prepareFloatingScene:(id)scene
                      handle:(FLMApplicationSceneHandle *)sceneHandle;
- (void)backgroundFloatingScene:(id)scene;
- (UIView *)hostViewForSceneHandle:(FLMApplicationSceneHandle *)sceneHandle;
- (void)layoutFloatingWindow;
- (void)layoutFloatingHostView;
- (CGSize)floatingSceneReferenceSize;
- (void)closeFloatingWindowKeepingApplication:(BOOL)keepApplication;
- (void)activateIdentifierFullscreen:(NSString *)identifier;
- (void)beginLockMonitoring;
- (void)stopLockMonitoringIfIdle;
- (void)checkLockState:(NSTimer *)timer;
- (FLMWheelItemView *)itemNearPoint:(CGPoint)point maximumDistance:(CGFloat)distance;
- (void)dismissWheelLaunchingItem:(FLMWheelItemView *)item;
- (void)activateIdentifier:(NSString *)identifier;
@end

static int FlymeRuntimeToken = -1;

static id FLMCopyPreference(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyValue((__bridge CFStringRef)key,
                                                      FLYME_PREFERENCES_DOMAIN,
                                                      kCFPreferencesCurrentUser,
                                                      kCFPreferencesAnyHost);
    return CFBridgingRelease(value);
}

static UIWindowScene *FLMForegroundWindowScene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                return (UIWindowScene *)scene;
            }
        }
    }
    return nil;
}

static UIWindow *FLMCurrentKeyWindow(void) {
    UIWindowScene *scene = FLMForegroundWindowScene();
    if (@available(iOS 13.0, *)) {
        for (UIWindow *window in scene.windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    return nil;
}

static UIWindow *FLMCreateWindow(CGRect frame) {
    UIWindowScene *scene = FLMForegroundWindowScene();
    if (@available(iOS 13.0, *)) {
        if (scene) {
            FLMOverlayWindow *window = [[FLMOverlayWindow alloc] initWithWindowScene:scene];
            window.frame = frame;
            return window;
        }
    }
    return [[FLMOverlayWindow alloc] initWithFrame:frame];
}

static FLMFloatingWindow *FLMCreateFloatingWindow(CGRect frame) {
    UIWindowScene *scene = FLMForegroundWindowScene();
    if (@available(iOS 13.0, *)) {
        if (scene) {
            FLMFloatingWindow *window =
                [[FLMFloatingWindow alloc] initWithWindowScene:scene];
            window.frame = frame;
            return window;
        }
    }
    return [[FLMFloatingWindow alloc] initWithFrame:frame];
}

static FLMHotspotWindow *FLMCreateHotspotWindow(CGRect frame) {
    UIWindowScene *scene = FLMForegroundWindowScene();
    if (@available(iOS 13.0, *)) {
        if (scene) {
            FLMHotspotWindow *window =
                [[FLMHotspotWindow alloc] initWithWindowScene:scene];
            window.frame = frame;
            return window;
        }
    }
    return [[FLMHotspotWindow alloc] initWithFrame:frame];
}

static UIImage *FLMLockImage(void) {
    UIImage *image = [UIImage systemImageNamed:@"lock.fill"];
    return [image imageWithTintColor:[UIColor whiteColor]
                       renderingMode:UIImageRenderingModeAlwaysOriginal];
}

static UIImage *FLMApplicationIcon(NSString *bundleIdentifier) {
    if ([bundleIdentifier isEqualToString:FLYME_LOCK_SCREEN_ITEM]) {
        return FLMLockImage();
    }
    if ([UIImage respondsToSelector:
                     @selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        UIImage *image = [UIImage _applicationIconImageForBundleIdentifier:bundleIdentifier
                                                                    format:2
                                                                     scale:[UIScreen mainScreen].scale];
        if (image) {
            return image;
        }
    }
    return [UIImage systemImageNamed:@"app.fill"];
}

static void FLMPreferencesChanged(CFNotificationCenterRef center,
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
        [[FLMWheelController sharedController] reloadPreferences];
    });
}

@implementation FLMWheelController

+ (instancetype)sharedController {
    static FLMWheelController *controller = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [[self alloc] init];
    });
    return controller;
}

- (void)start {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        FLMPreferencesChanged,
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
               selector:@selector(protectedSceneDidDisappear:)
                   name:FLMProtectedSceneDidDisappearNotification
                 object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(keyboardFrameWillChange:)
                   name:UIKeyboardWillChangeFrameNotification
                 object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(keyboardWillHide:)
                   name:UIKeyboardWillHideNotification
                 object:nil];
        self.lastPortraitKeyboardHeight = 291.0;
        self.floatingKeyboardFrame = CGRectNull;
        self.keyboardOriginalFrames = [NSMapTable weakToStrongObjectsMapTable];
        self.keyboardOriginalLevels = [NSMapTable weakToStrongObjectsMapTable];
        [self createWindows];
        [self reloadPreferences];
    });
}

- (void)createWindows {
    CGRect bounds = FLMVisualScreenBounds();
    self.overlayWindow = (FLMOverlayWindow *)FLMCreateWindow(bounds);
    self.overlayWindow.windowLevel = UIWindowLevelAlert + 91.0;
    self.overlayWindow.backgroundColor = [UIColor clearColor];
    self.overlayWindow.userInteractionEnabled = NO;
    self.overlayWindow.rootViewController = [[FLMOverlayViewController alloc] init];
    self.overlayWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.overlayWindow.hidden = YES;

    self.wheelContainer = [[UIView alloc] initWithFrame:bounds];
    self.wheelContainer.userInteractionEnabled = YES;
    [self.overlayWindow.rootViewController.view addSubview:self.wheelContainer];

    self.wheelTapGesture =
        [[UITapGestureRecognizer alloc] initWithTarget:self
                                               action:@selector(handleWheelTap:)];
    self.wheelTapGesture.cancelsTouchesInView = YES;
    self.wheelTapGesture.delaysTouchesEnded = NO;
    [self.overlayWindow.rootViewController.view addGestureRecognizer:self.wheelTapGesture];

    [self createFloatingWindow];

    self.hotspotWindow = FLMCreateHotspotWindow(bounds);
    self.hotspotWindow.windowLevel = UIWindowLevelAlert + 90.0;
    self.hotspotWindow.backgroundColor = [UIColor clearColor];
    UIViewController *hotspotController = [[UIViewController alloc] init];
    hotspotController.view.backgroundColor = [UIColor clearColor];
    self.hotspotWindow.rootViewController = hotspotController;

    self.cornerGesture =
        [[FLMCornerGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(handleCornerGesture:)];
    self.cornerGesture.delegate = self;
    self.cornerGesture.cancelsTouchesInView = YES;
    self.cornerGesture.numberOfTouchesRequired = 1;
    self.cornerGesture.minimumPressDuration = 0.12;
    self.cornerGesture.allowableMovement = CGFLOAT_MAX;

    self.cornerGuardGesture =
        [[FLMCornerGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleCornerGuardGesture:)];
    self.cornerGuardGesture.delegate = self;
    self.cornerGuardGesture.cancelsTouchesInView = YES;
    self.cornerGuardGesture.delaysTouchesBegan = NO;
    self.cornerGuardGesture.delaysTouchesEnded = NO;
    self.cornerGuardGesture.numberOfTouchesRequired = 1;
    self.cornerGuardGesture.minimumPressDuration = 0.0;
    self.cornerGuardGesture.allowableMovement = CGFLOAT_MAX;

    self.modalGesture =
        [[FLMCornerGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(handleModalGesture:)];
    self.modalGesture.delegate = self;
    self.modalGesture.cancelsTouchesInView = YES;
    self.modalGesture.numberOfTouchesRequired = 1;
    self.modalGesture.minimumPressDuration = 0.0;
    self.modalGesture.allowableMovement = CGFLOAT_MAX;
    self.modalGesture.enabled = NO;

    self.floatingExclusiveGesture =
        [[FLMCornerGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingExclusiveGesture:)];
    self.floatingExclusiveGesture.delegate = self;
    self.floatingExclusiveGesture.cancelsTouchesInView = NO;
    self.floatingExclusiveGesture.delaysTouchesBegan = NO;
    self.floatingExclusiveGesture.delaysTouchesEnded = NO;
    self.floatingExclusiveGesture.numberOfTouchesRequired = 1;
    self.floatingExclusiveGesture.minimumPressDuration = 0.0;
    self.floatingExclusiveGesture.allowableMovement = CGFLOAT_MAX;
    self.floatingExclusiveGesture.enabled = NO;

    self.usesSystemGestureManager = [self registerGlobalCornerGesture];
    if (!self.usesSystemGestureManager) {
        [self.hotspotWindow.rootViewController.view
            addGestureRecognizer:self.cornerGuardGesture];
        [self.hotspotWindow.rootViewController.view addGestureRecognizer:self.cornerGesture];
    }
    [self updateWindowFrames];
}

- (void)createFloatingWindow {
    CGRect bounds = FLMVisualScreenBounds();
    self.floatingWindow = FLMCreateFloatingWindow(bounds);
    self.floatingWindow.windowLevel = UIWindowLevelAlert + 92.0;
    self.floatingWindow.backgroundColor = [UIColor clearColor];
    self.floatingWindow.rootViewController = [[FLMOverlayViewController alloc] init];
    self.floatingWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.floatingWindow.hidden = YES;

    self.floatingDimView = [[UIView alloc] initWithFrame:bounds];
    self.floatingDimView.backgroundColor =
        [UIColor colorWithWhite:0.0 alpha:0.12];
    [self.floatingWindow.rootViewController.view addSubview:self.floatingDimView];

    self.floatingContainer = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingContainer.backgroundColor = [UIColor blackColor];
    self.floatingContainer.layer.cornerRadius = 18.0;
    self.floatingContainer.layer.masksToBounds = YES;
    [self.floatingWindow.rootViewController.view addSubview:self.floatingContainer];

    self.floatingStatusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.floatingStatusLabel.text = @"正在打开…";
    self.floatingStatusLabel.textAlignment = NSTextAlignmentCenter;
    self.floatingStatusLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    self.floatingStatusLabel.font = [UIFont systemFontOfSize:15.0
                                                     weight:UIFontWeightMedium];
    [self.floatingContainer addSubview:self.floatingStatusLabel];

    self.floatingHandle = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingHandle.backgroundColor = [UIColor clearColor];
    self.floatingHandleBar = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingHandleBar.backgroundColor =
        [UIColor colorWithWhite:1.0 alpha:0.72];
    self.floatingHandleBar.layer.cornerRadius = 2.5;
    self.floatingHandleBar.userInteractionEnabled = NO;
    [self.floatingHandle addSubview:self.floatingHandleBar];
    [self.floatingWindow.rootViewController.view addSubview:self.floatingHandle];

    self.floatingBackdropTap =
        [[FLMOutsideTapGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingBackdropTap:)];
    self.floatingBackdropTap.protectedView = self.floatingContainer;
    self.floatingBackdropTap.secondaryProtectedView = self.floatingHandle;
    self.floatingBackdropTap.delegate = self;
    [self.floatingWindow.rootViewController.view
        addGestureRecognizer:self.floatingBackdropTap];

    self.floatingHandlePress =
        [[UILongPressGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingHandlePress:)];
    self.floatingHandlePress.minimumPressDuration = 0.12;
    self.floatingHandlePress.allowableMovement = CGFLOAT_MAX;
    self.floatingHandlePress.cancelsTouchesInView = YES;
    [self.floatingHandle addGestureRecognizer:self.floatingHandlePress];

    self.floatingHandleTap =
        [[UITapGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingHandleTap:)];
    self.floatingHandleTap.cancelsTouchesInView = YES;
    [self.floatingHandleTap
        requireGestureRecognizerToFail:self.floatingHandlePress];
    [self.floatingHandle addGestureRecognizer:self.floatingHandleTap];
    self.floatingHandle.userInteractionEnabled = YES;
    [self layoutFloatingWindow];
}

- (BOOL)registerGlobalCornerGesture {
    Class managerClass = NSClassFromString(@"_UISystemGestureManager");
    FLMSystemGestureManager *manager =
        (FLMSystemGestureManager *)[managerClass sharedInstance];
    FLMDisplayConfiguration *displayConfiguration =
        [[UIScreen mainScreen] displayConfiguration];
    id identity = [displayConfiguration identity];
    SEL registrationSelector =
        @selector(addGestureRecognizer:toDisplayWithIdentity:);
    if (!manager || !identity || ![manager respondsToSelector:registrationSelector]) {
        return NO;
    }

    [manager addGestureRecognizer:self.cornerGuardGesture
            toDisplayWithIdentity:identity];
    [manager addGestureRecognizer:self.cornerGesture toDisplayWithIdentity:identity];
    [manager addGestureRecognizer:self.modalGesture toDisplayWithIdentity:identity];
    [manager addGestureRecognizer:self.floatingExclusiveGesture
            toDisplayWithIdentity:identity];
    self.systemGestureManager = manager;
    self.displayIdentity = identity;
    return YES;
}

- (void)reloadPreferences {
    CFPreferencesSynchronize(FLYME_PREFERENCES_DOMAIN,
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);
    id enabledValue = FLMCopyPreference(@"enabled");
    id itemsValue = FLMCopyPreference(@"wheelItems");
    id radiusValue = FLMCopyPreference(@"wheelRadius");
    id iconSizeValue = FLMCopyPreference(@"wheelIconSize");
    self.enabled = [enabledValue isKindOfClass:[NSNumber class]] && [enabledValue boolValue];
    self.itemIdentifiers =
        [itemsValue isKindOfClass:[NSArray class]] ? [itemsValue copy] : @[];
    CGFloat requestedRadius =
        [radiusValue isKindOfClass:[NSNumber class]]
            ? [radiusValue doubleValue]
            : FLMDefaultWheelRadius;
    CGFloat requestedIconSize =
        [iconSizeValue isKindOfClass:[NSNumber class]]
            ? [iconSizeValue doubleValue]
            : FLMDefaultWheelIconSize;
    self.wheelRadius =
        MAX(FLMMinimumWheelRadius, MIN(FLMMaximumWheelRadius, requestedRadius));
    self.wheelIconSize =
        MAX(FLMMinimumWheelIconSize,
            MIN(FLMMaximumWheelIconSize, requestedIconSize));
    self.cornerGuardGesture.enabled = self.enabled;
    self.cornerGesture.enabled = self.enabled;
    if (!self.enabled) {
        self.modalGesture.enabled = NO;
    }
    self.hotspotWindow.hotspotsEnabled = self.enabled && !self.usesSystemGestureManager;
    self.hotspotWindow.hidden = !self.enabled || self.usesSystemGestureManager;
    if (!self.enabled) {
        [self dismissWheelLaunchingItem:nil];
        [self closeFloatingWindowKeepingApplication:YES];
    }
}

- (void)orientationDidChange:(NSNotification *)notification {
    (void)notification;
    [self dismissWheelLaunchingItem:nil];
    [self restoreKeyboardWindowFrames];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self updateWindowFrames];
        if (self.floatingKeyboardVisible) {
            [self applyLandscapeKeyboardLayout];
        }
    });
}

- (void)updateWindowFrames {
    CGRect bounds = FLMVisualScreenBounds();
    self.overlayWindow.frame = bounds;
    self.overlayWindow.rootViewController.view.frame = bounds;
    self.wheelContainer.frame = bounds;
    self.hotspotWindow.frame = bounds;
    self.hotspotWindow.rootViewController.view.frame = bounds;
    self.floatingWindow.frame = bounds;
    self.floatingWindow.rootViewController.view.frame = bounds;
    self.floatingDimView.frame = bounds;
    [self layoutFloatingWindow];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.floatingBackdropTap) {
        return !self.floatingWindow.hidden;
    }
    if (gestureRecognizer == self.floatingExclusiveGesture) {
        return !self.floatingWindow.hidden && !FLMDeviceIsLocked();
    }
    if (gestureRecognizer == self.modalGesture) {
        return self.enabled && self.wheelPinned && !FLMDeviceIsLocked();
    }
    if (gestureRecognizer == self.cornerGuardGesture) {
        return self.enabled && !self.wheelPinned &&
               self.itemIdentifiers.count > 0 && !FLMDeviceIsLocked();
    }
    if (!self.enabled || self.wheelPinned || self.itemIdentifiers.count == 0) {
        return NO;
    }
    if (FLMDeviceIsLocked()) {
        return NO;
    }
    CGRect bounds = FLMVisualScreenBounds();
    BOOL fromRight = NO;
    BOOL insideTrigger =
        FLMPointInsideCornerTrigger(self.cornerGestureStartPoint,
                                    bounds,
                                    &fromRight);
    self.presentingFromRight = fromRight;
    return insideTrigger;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer == self.floatingBackdropTap) {
        return !self.floatingWindow.hidden;
    }
    if (gestureRecognizer == self.floatingExclusiveGesture) {
        if (self.floatingWindow.hidden || FLMDeviceIsLocked()) {
            return NO;
        }
        UIView *touchView = touch.view;
        if (touchView == self.floatingContainer ||
            [touchView isDescendantOfView:self.floatingContainer] ||
            touchView == self.floatingHandle ||
            [touchView isDescendantOfView:self.floatingHandle]) {
            return NO;
        }
        CGPoint point =
            [touch locationInView:self.floatingWindow.rootViewController.view];
        CGRect handleHitFrame = CGRectInset(self.floatingHandle.frame, -22.0, -20.0);
        if (self.floatingKeyboardVisible &&
            CGRectContainsPoint(self.floatingKeyboardFrame, point)) {
            return NO;
        }
        return !CGRectContainsPoint(self.floatingContainer.frame, point) &&
               !CGRectContainsPoint(handleHitFrame, point);
    }
    if (gestureRecognizer == self.modalGesture) {
        return self.enabled && self.wheelPinned && !FLMDeviceIsLocked();
    }
    if (gestureRecognizer == self.cornerGuardGesture) {
        if (!self.enabled || self.wheelPinned ||
            self.itemIdentifiers.count == 0 || FLMDeviceIsLocked()) {
            return NO;
        }
        CGPoint rawPoint = [touch locationInView:nil];
        CGPoint point = FLMVisualPointFromRawPoint(rawPoint);
        return FLMPointInsideCornerTrigger(point,
                                           FLMVisualScreenBounds(),
                                           NULL);
    }
    if (!self.enabled || self.wheelPinned || self.itemIdentifiers.count == 0) {
        return NO;
    }
    if (FLMDeviceIsLocked()) {
        return NO;
    }
    CGRect bounds = FLMVisualScreenBounds();
    CGPoint rawPoint = [touch locationInView:nil];
    CGPoint point = FLMVisualPointFromRawPoint(rawPoint);
    BOOL fromRight = NO;
    if (!FLMPointInsideCornerTrigger(point, bounds, &fromRight)) {
        return NO;
    }
    self.presentingFromRight = fromRight;
    self.cornerGestureStartPoint = point;
    self.wheelGestureActive = NO;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer {
    BOOL guardAndWheel =
        (gestureRecognizer == self.cornerGuardGesture &&
         otherGestureRecognizer == self.cornerGesture) ||
        (gestureRecognizer == self.cornerGesture &&
         otherGestureRecognizer == self.cornerGuardGesture);
    if (guardAndWheel) {
        return YES;
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldBeRequiredToFailByGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return NO;
}

- (void)handleModalGesture:(UIGestureRecognizer *)gesture {
    if (!self.wheelPinned) {
        return;
    }
    CGPoint rawPoint = [gesture locationInView:nil];
    CGPoint point = FLMVisualPointFromRawPoint(rawPoint);
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            [self updateHighlightForPoint:point];
            break;
        case UIGestureRecognizerStateEnded: {
            FLMWheelItemView *item =
                [self itemNearPoint:point
                    maximumDistance:self.wheelIconSize * 0.5 + 2.0];
            [self dismissWheelLaunchingItem:item];
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            self.highlightedItem.highlighted = NO;
            self.highlightedItem = nil;
            break;
        default:
            break;
    }
}

- (void)handleCornerGuardGesture:(UIGestureRecognizer *)gesture {
    // Intentionally empty. Recognizing immediately reserves the user-locked
    // corner zone so home/back gestures cannot consume the same touch stream.
    (void)gesture;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRequireFailureOfGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return NO;
}

- (void)handleCornerGesture:(UIGestureRecognizer *)gesture {
    CGPoint rawPoint = [gesture locationInView:nil];
    CGPoint point = FLMVisualPointFromRawPoint(rawPoint);

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            if (!self.wheelGestureActive && [self shouldActivateWheelAtPoint:point]) {
                self.wheelGestureActive = YES;
                [self presentWheelFromRight:self.presentingFromRight];
            }
            if (self.wheelGestureActive) {
                [self updateHighlightForPoint:point];
            }
            break;
        case UIGestureRecognizerStateEnded:
            if (self.wheelGestureActive) {
                FLMWheelItemView *selectedItem = self.highlightedItem;
                if (selectedItem) {
                    [self dismissWheelLaunchingItem:selectedItem];
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
            if (self.wheelGestureActive) {
                [self dismissWheelLaunchingItem:nil];
            }
            self.wheelGestureActive = NO;
            break;
        default:
            break;
    }
}

- (BOOL)shouldActivateWheelAtPoint:(CGPoint)point {
    CGFloat horizontalMovement = point.x - self.cornerGestureStartPoint.x;
    CGFloat verticalMovement = point.y - self.cornerGestureStartPoint.y;
    CGFloat totalMovement = hypot(horizontalMovement, verticalMovement);
    CGFloat inwardMovement =
        self.presentingFromRight ? -horizontalMovement : horizontalMovement;
    CGFloat upwardMovement = -verticalMovement;
    return totalMovement >= 14.0 &&
           (inwardMovement >= 4.0 || upwardMovement >= 4.0);
}

- (NSArray<NSNumber *> *)itemCountsByRingForCount:(NSUInteger)count {
    NSMutableArray<NSNumber *> *counts = [NSMutableArray array];
    NSUInteger remaining = count;
    NSUInteger capacity = 4;
    while (remaining > 0) {
        NSUInteger ringCount = MIN(remaining, capacity);
        [counts addObject:@(ringCount)];
        remaining -= ringCount;
        capacity += 1;
    }
    return counts;
}

- (void)presentWheelFromRight:(BOOL)fromRight {
    [self.itemViews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.wheelPinned = NO;
    self.overlayWindow.userInteractionEnabled = NO;
    NSMutableArray<FLMWheelItemView *> *views = [NSMutableArray array];
    CGRect bounds = FLMVisualScreenBounds();
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    CGPoint anchor = CGPointMake(fromRight ? width - 4.0 : 4.0, height - 4.0);
    NSArray<NSNumber *> *ringCounts =
        [self itemCountsByRingForCount:self.itemIdentifiers.count];
    CGFloat fullStartAngle = -82.0 * (CGFloat)M_PI / 180.0;
    CGFloat fullEndAngle = -10.0 * (CGFloat)M_PI / 180.0;
    CGFloat fullAngleSpan = fullEndAngle - fullStartAngle;
    CGFloat safeCenterMargin = self.wheelIconSize * 0.5 + 10.0;
    CGFloat maximumRadiusByWidth =
        (width - 4.0 - safeCenterMargin) / cos(fullEndAngle);
    CGFloat maximumRadiusByHeight =
        (height - 4.0 - safeCenterMargin) / fabs(sin(fullStartAngle));
    CGFloat maximumRadius = MAX(120.0, MIN(maximumRadiusByWidth,
                                           maximumRadiusByHeight));
    CGFloat firstRadius = MIN(self.wheelRadius, maximumRadius);
    CGFloat ringSpacing = 0.0;
    if (ringCounts.count > 1) {
        CGFloat ringIntervals = (CGFloat)(ringCounts.count - 1);
        CGFloat desiredSpacing = self.wheelIconSize + 20.0;
        CGFloat minimumSpacing = self.wheelIconSize + 6.0;
        CGFloat desiredOuterRadius = firstRadius + desiredSpacing * ringIntervals;
        if (desiredOuterRadius <= maximumRadius) {
            ringSpacing = desiredSpacing;
        } else {
            firstRadius =
                MIN(firstRadius,
                    MAX(132.0, maximumRadius - minimumSpacing * ringIntervals));
            ringSpacing = (maximumRadius - firstRadius) / ringIntervals;
        }
    }

    NSUInteger itemIndex = 0;
    for (NSUInteger ring = 0; ring < ringCounts.count; ring++) {
        NSUInteger ringCount = ringCounts[ring].unsignedIntegerValue;
        CGFloat radius = firstRadius + (CGFloat)ring * ringSpacing;
        for (NSUInteger position = 0; position < ringCount; position++) {
            CGFloat fraction = ringCount == 1
                                   ? 0.5
                                   : (CGFloat)position / (CGFloat)(ringCount - 1);
            CGFloat angle = fullStartAngle + fraction * fullAngleSpan;
            CGFloat leftX = 4.0 + radius * cos(angle);
            CGFloat centerX = fromRight ? width - leftX : leftX;
            CGFloat centerY = anchor.y + radius * sin(angle);
            NSString *identifier = self.itemIdentifiers[itemIndex++];
            FLMWheelItemView *item =
                [[FLMWheelItemView alloc] initWithIdentifier:identifier
                                                       image:FLMApplicationIcon(identifier)
                                                        size:self.wheelIconSize];
            item.center = CGPointMake(centerX, centerY);
            item.alpha = 0.0;
            item.transform = CGAffineTransformMakeScale(0.42, 0.42);
            [self.wheelContainer addSubview:item];
            [views addObject:item];
        }
    }
    self.itemViews = views;

    self.overlayWindow.hidden = NO;
    self.wheelContainer.alpha = 1.0;
    [self.itemViews enumerateObjectsUsingBlock:^(
                        FLMWheelItemView *item, NSUInteger index, BOOL *stop) {
        (void)stop;
        [UIView animateWithDuration:0.44
                              delay:MIN((NSTimeInterval)index * 0.018, 0.12)
             usingSpringWithDamping:0.72
              initialSpringVelocity:0.55
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
                             item.alpha = 1.0;
                             item.transform = CGAffineTransformIdentity;
                         }
                         completion:nil];
    }];
}

- (void)updateHighlightForPoint:(CGPoint)point {
    FLMWheelItemView *nearest =
        [self itemNearPoint:point
            maximumDistance:self.wheelIconSize * 0.5 + 2.0];
    if (nearest == self.highlightedItem) {
        return;
    }
    self.highlightedItem.highlighted = NO;
    self.highlightedItem = nearest;
    self.highlightedItem.highlighted = YES;
    if (@available(iOS 10.0, *)) {
        if (nearest) {
            UISelectionFeedbackGenerator *feedback =
                [[UISelectionFeedbackGenerator alloc] init];
            [feedback selectionChanged];
        }
    }
}

- (FLMWheelItemView *)itemNearPoint:(CGPoint)point maximumDistance:(CGFloat)distance {
    FLMWheelItemView *nearest = nil;
    CGFloat nearestDistance = CGFLOAT_MAX;
    for (FLMWheelItemView *item in self.itemViews) {
        CGFloat itemDistance = hypot(point.x - item.center.x, point.y - item.center.y);
        if (itemDistance < nearestDistance) {
            nearestDistance = itemDistance;
            nearest = item;
        }
    }
    return nearestDistance <= distance ? nearest : nil;
}

- (void)pinWheel {
    if (self.overlayWindow.hidden) {
        return;
    }
    self.highlightedItem.highlighted = NO;
    self.highlightedItem = nil;
    self.wheelPinned = YES;
    self.overlayWindow.userInteractionEnabled = YES;
    if (self.usesSystemGestureManager) {
        self.modalGesture.enabled = YES;
        self.wheelTapGesture.enabled = NO;
    } else {
        self.wheelTapGesture.enabled = YES;
    }
    [self beginLockMonitoring];
    [UIView animateWithDuration:0.32
                          delay:0.0
         usingSpringWithDamping:0.76
          initialSpringVelocity:0.25
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         for (FLMWheelItemView *item in self.itemViews) {
                             item.transform = CGAffineTransformIdentity;
                             item.alpha = 1.0;
                         }
                     }
                     completion:nil];
}

- (void)handleWheelTap:(UITapGestureRecognizer *)gesture {
    if (!self.wheelPinned) {
        return;
    }
    CGPoint point = [gesture locationInView:self.wheelContainer];
    FLMWheelItemView *item =
        [self itemNearPoint:point
            maximumDistance:self.wheelIconSize * 0.5 + 2.0];
    [self dismissWheelLaunchingItem:item];
}

- (void)dismissWheelLaunchingItem:(FLMWheelItemView *)item {
    self.highlightedItem.highlighted = NO;
    self.highlightedItem = nil;
    self.wheelPinned = NO;
    self.modalGesture.enabled = NO;
    self.wheelTapGesture.enabled = YES;
    self.overlayWindow.userInteractionEnabled = NO;
    [self stopLockMonitoringIfIdle];
    if (self.overlayWindow.hidden) {
        if (item) {
            [self activateIdentifier:item.identifier];
        }
        return;
    }

    [UIView animateWithDuration:0.24
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseIn
                     animations:^{
                         self.wheelContainer.alpha = 0.0;
                         for (FLMWheelItemView *itemView in self.itemViews) {
                             itemView.transform = CGAffineTransformMakeScale(0.78, 0.78);
                             itemView.alpha = 0.0;
                         }
                     }
                     completion:^(BOOL finished) {
                         (void)finished;
                         self.overlayWindow.hidden = YES;
                         self.wheelContainer.alpha = 1.0;
                         [self.itemViews makeObjectsPerformSelector:@selector(removeFromSuperview)];
                         self.itemViews = @[];
                         if (item) {
                             [self activateIdentifier:item.identifier];
                         }
                     }];
}

- (void)handleFloatingBackdropTap:(UIGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded ||
        self.floatingWindow.hidden) {
        return;
    }
    [self closeFloatingWindowKeepingApplication:YES];
}

- (void)handleFloatingExclusiveGesture:(UIGestureRecognizer *)gesture {
    // The system-level recognizer only reserves input priority outside the card.
    // FLMOutsideTapGestureRecognizer owns the close decision using every touch's
    // starting point, movement and duration.
    (void)gesture;
}

- (void)handleFloatingHandleTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded ||
        self.floatingWindow.hidden) {
        return;
    }
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
    }
    [UIView animateWithDuration:0.10
                     animations:^{
                         self.floatingHandleBar.alpha = 1.0;
                         self.floatingHandleBar.transform =
                             CGAffineTransformMakeScale(1.10, 1.28);
                     }
                     completion:^(BOOL finished) {
                         (void)finished;
                         [UIView animateWithDuration:0.18
                                          animations:^{
                                              self.floatingHandleBar.alpha = 1.0;
                                              self.floatingHandleBar.transform =
                                                  CGAffineTransformIdentity;
                                          }];
                     }];
}

- (BOOL)updateFloatingSceneToReferenceSize:(CGSize)referenceSize
                               orientation:(NSInteger)orientation {
    id scene = self.floatingScene;
    if (!scene || referenceSize.width < 1.0 || referenceSize.height < 1.0) {
        return NO;
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
        if (!mutableSettings ||
            ![scene respondsToSelector:
                       @selector(updateSettings:withTransitionContext:)]) {
            return NO;
        }
        if ([mutableSettings respondsToSelector:@selector(setFrame:)]) {
            [mutableSettings setFrame:CGRectMake(0.0,
                                                  0.0,
                                                  referenceSize.width,
                                                  referenceSize.height)];
        }
        if (orientation >= 1 && orientation <= 4 &&
            [mutableSettings respondsToSelector:
                                 @selector(setInterfaceOrientation:)]) {
            [mutableSettings setInterfaceOrientation:orientation];
        }
        [scene updateSettings:mutableSettings withTransitionContext:nil];
        self.floatingHostReferenceSize = referenceSize;
        [self layoutFloatingHostView];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

- (void)prepareFloatingSceneForInteractiveFullscreen {
    if (self.floatingInteractiveScenePrepared) {
        return;
    }
    self.floatingInteractiveScenePrepared = YES;
    self.floatingInteractiveFullscreenTransition = YES;
    self.floatingCenteredReferenceSize = self.floatingHostReferenceSize;

    UIView *snapshot =
        [self.floatingContainer snapshotViewAfterScreenUpdates:NO];
    snapshot.frame = self.floatingContainer.bounds;
    snapshot.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.floatingContainer addSubview:snapshot];
    self.floatingInteractiveSnapshot = snapshot;

    CGSize fullscreenSize =
        self.floatingWindow.rootViewController.view.bounds.size;
    NSInteger orientation = (NSInteger)FLMActiveInterfaceOrientation();
    [self updateFloatingSceneToReferenceSize:fullscreenSize
                                 orientation:orientation];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.06 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *currentSnapshot = self.floatingInteractiveSnapshot;
        if (!currentSnapshot) {
            return;
        }
        [UIView animateWithDuration:0.10
                         animations:^{
                             currentSnapshot.alpha = 0.0;
                         }
                         completion:^(BOOL finished) {
                             (void)finished;
                             [currentSnapshot removeFromSuperview];
                             if (self.floatingInteractiveSnapshot == currentSnapshot) {
                                 self.floatingInteractiveSnapshot = nil;
                             }
                         }];
    });
}

- (void)restoreFloatingSceneAfterCancelledTransition {
    [self.floatingInteractiveSnapshot removeFromSuperview];
    self.floatingInteractiveSnapshot = nil;
    BOOL wasPrepared = self.floatingInteractiveScenePrepared;
    self.floatingInteractiveScenePrepared = NO;
    self.floatingInteractiveFullscreenTransition = NO;
    if (wasPrepared &&
        self.floatingCenteredReferenceSize.width > 0.0 &&
        self.floatingCenteredReferenceSize.height > 0.0) {
        [self updateFloatingSceneToReferenceSize:self.floatingCenteredReferenceSize
                                     orientation:1];
    }
    self.floatingCenteredReferenceSize = CGSizeZero;
}

- (void)handleFloatingHandlePress:(UILongPressGestureRecognizer *)gesture {
    if (self.floatingWindow.hidden) {
        return;
    }
    UIView *rootView = self.floatingWindow.rootViewController.view;
    CGPoint point = [gesture locationInView:rootView];
    CGRect bounds = rootView.bounds;
    BOOL landscape = CGRectGetWidth(bounds) > CGRectGetHeight(bounds);

    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.floatingHandleStartPoint = point;
        self.floatingHandleInitialContainerFrame = self.floatingContainer.frame;
        self.floatingHandleMoved = NO;
        self.floatingInteractiveScenePrepared = NO;
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *feedback =
                [[UIImpactFeedbackGenerator alloc]
                    initWithStyle:UIImpactFeedbackStyleLight];
            [feedback impactOccurred];
        }
        [UIView animateWithDuration:0.12
                         animations:^{
                             self.floatingHandleBar.alpha = 1.0;
                             self.floatingHandleBar.transform =
                                 landscape
                                     ? CGAffineTransformMakeScale(1.28, 1.06)
                                     : CGAffineTransformMakeScale(1.06, 1.28);
                         }];
        return;
    }

    CGFloat primaryMovement =
        landscape ? point.x - self.floatingHandleStartPoint.x
                  : point.y - self.floatingHandleStartPoint.y;
    CGFloat crossMovement =
        landscape ? point.y - self.floatingHandleStartPoint.y
                  : point.x - self.floatingHandleStartPoint.x;

    if (gesture.state == UIGestureRecognizerStateChanged) {
        if (primaryMovement > 0.0 &&
            fabs(primaryMovement) >= fabs(crossMovement) * 0.55) {
            if (primaryMovement >= 3.0) {
                self.floatingHandleMoved = YES;
                [self prepareFloatingSceneForInteractiveFullscreen];
            }
            CGRect start = self.floatingHandleInitialContainerFrame;
            CGFloat available =
                landscape ? MAX(1.0, CGRectGetWidth(bounds) - CGRectGetMaxX(start))
                          : MAX(1.0, CGRectGetHeight(bounds) - CGRectGetMaxY(start));
            CGFloat progress = MIN(1.0, MAX(0.0, primaryMovement / available));
            CGRect target = bounds;
            CGRect frame = CGRectMake(
                start.origin.x + (target.origin.x - start.origin.x) * progress,
                start.origin.y + (target.origin.y - start.origin.y) * progress,
                start.size.width + (target.size.width - start.size.width) * progress,
                start.size.height + (target.size.height - start.size.height) * progress);
            self.floatingContainer.frame = frame;
            self.floatingContainer.layer.cornerRadius = 18.0 * (1.0 - progress);
            self.floatingDimView.alpha = 1.0 - progress;
            self.floatingHandle.alpha =
                1.0 - MAX(0.0, (progress - 0.88) / 0.12);
            [self layoutFloatingHostView];
            [self layoutFloatingHandleForCurrentContainer];
        } else {
            CGFloat resistance = MAX(-14.0, MIN(0.0, primaryMovement * 0.18));
            self.floatingHandleBar.transform =
                landscape
                    ? CGAffineTransformMakeTranslation(resistance, 0.0)
                    : CGAffineTransformMakeTranslation(0.0, resistance);
        }
        return;
    }

    if (gesture.state == UIGestureRecognizerStateEnded &&
        self.floatingHandleMoved && primaryMovement > 0.0) {
        [self transitionFloatingWindowToFullscreen];
        return;
    }
    [self resetFloatingInteractiveLayoutAnimated:YES];
}

- (void)resetFloatingInteractiveLayoutAnimated:(BOOL)animated {
    [self restoreFloatingSceneAfterCancelledTransition];
    void (^changes)(void) = ^{
        self.floatingContainer.layer.cornerRadius = 18.0;
        self.floatingDimView.alpha = 1.0;
        self.floatingHandle.alpha = 1.0;
        self.floatingHandleBar.alpha = 1.0;
        self.floatingHandleBar.transform = CGAffineTransformIdentity;
        [self layoutFloatingWindow];
    };
    if (!animated) {
        changes();
        return;
    }
    [UIView animateWithDuration:0.34
                          delay:0.0
         usingSpringWithDamping:0.78
          initialSpringVelocity:0.25
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:changes
                     completion:nil];
}

- (void)transitionFloatingWindowToFullscreen {
    if (self.floatingWindow.hidden || self.floatingIdentifier.length == 0) {
        [self resetFloatingInteractiveLayoutAnimated:YES];
        return;
    }
    UIView *rootView = self.floatingWindow.rootViewController.view;
    CGRect targetFrame = rootView.bounds;
    [UIView animateWithDuration:0.30
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         self.floatingContainer.frame = targetFrame;
                         self.floatingContainer.layer.cornerRadius = 0.0;
                         self.floatingDimView.alpha = 0.0;
                         self.floatingHandle.alpha = 0.0;
                         [self layoutFloatingHostView];
                         [self layoutFloatingHandleForCurrentContainer];
                     }
                     completion:^(BOOL finished) {
                         (void)finished;
                         NSString *identifier = [self.floatingIdentifier copy];
                         [self.floatingInteractiveSnapshot removeFromSuperview];
                         self.floatingInteractiveSnapshot = nil;
                         UIView *snapshot =
                             [self.floatingContainer snapshotViewAfterScreenUpdates:NO];
                         if (!snapshot) {
                             snapshot = [[UIView alloc] initWithFrame:targetFrame];
                             snapshot.backgroundColor = [UIColor blackColor];
                         }
                         snapshot.frame = targetFrame;
                         [rootView addSubview:snapshot];

                         self.floatingReconnectSuppressed = YES;
                         self.floatingInteractiveScenePrepared = NO;
                         self.floatingInteractiveFullscreenTransition = NO;
                         self.floatingCenteredReferenceSize = CGSizeZero;
                         self.floatingLaunchGeneration += 1;
                         id scene = self.floatingScene;
                         id presenter = self.floatingPresenter;
                         [self.floatingHostView removeFromSuperview];
                         self.floatingHostView = nil;
                         self.floatingSceneEntity = nil;
                         self.floatingSceneHandle = nil;
                         self.floatingScene = nil;
                         self.floatingPresentationManager = nil;
                         self.floatingPresenter = nil;
                         self.floatingIdentifier = nil;
                         self.floatingExclusiveGesture.enabled = NO;
                         self.cornerGuardGesture.enabled = self.enabled;
                         self.cornerGesture.enabled = self.enabled;
                         [self restoreKeyboardWindowFrames];
                         FLMClearProtectedScene(scene);
                         @try {
                             if ([presenter respondsToSelector:@selector(deactivate)]) {
                                 [presenter deactivate];
                             }
                             if ([presenter respondsToSelector:@selector(invalidate)]) {
                                 [presenter invalidate];
                             }
                         } @catch (__unused NSException *exception) {
                         }
                         self.floatingContainer.alpha = 0.0;
                         [self activateIdentifierFullscreen:identifier];
                         [self finishFullscreenHandoffWithCover:snapshot
                                                   identifier:identifier
                                                      attempt:0];
                     }];
}

- (void)finishFullscreenHandoffWithCover:(UIView *)cover
                              identifier:(NSString *)identifier
                                 attempt:(NSUInteger)attempt {
    BOOL targetIsFrontmost =
        identifier.length > 0 &&
        [identifier isEqualToString:FLMFrontmostApplicationIdentifier()];
    BOOL minimumCoverTimeElapsed = attempt >= 8;
    if ((!targetIsFrontmost || !minimumCoverTimeElapsed) && attempt < 24) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self finishFullscreenHandoffWithCover:cover
                                       identifier:identifier
                                          attempt:attempt + 1];
        });
        return;
    }
    [UIView animateWithDuration:0.12
                          delay:targetIsFrontmost ? 0.05 : 0.0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         cover.alpha = 0.0;
                     }
                     completion:^(BOOL finished) {
                         (void)finished;
                         [cover removeFromSuperview];
                         self.floatingWindow.hidden = YES;
                         self.floatingContainer.alpha = 1.0;
                         [self resetFloatingInteractiveLayoutAnimated:NO];
                         [self stopLockMonitoringIfIdle];
                     }];
}

- (void)protectedSceneDidDisappear:(NSNotification *)notification {
    (void)notification;
    if (self.floatingWindow.hidden) {
        return;
    }
    if (self.floatingReconnectSuppressed) {
        return;
    }
    if (FLMDeviceIsLocked() || self.floatingIdentifier.length == 0) {
        [self closeFloatingWindowKeepingApplication:YES];
        return;
    }

    NSString *identifier = [self.floatingIdentifier copy];
    self.floatingLaunchGeneration += 1;
    NSUInteger generation = self.floatingLaunchGeneration;
    id presenter = self.floatingPresenter;
    [self.floatingHostView removeFromSuperview];
    self.floatingHostView = nil;
    self.floatingHostReferenceSize = CGSizeZero;
    self.floatingSceneEntity = nil;
    self.floatingSceneHandle = nil;
    self.floatingScene = nil;
    self.floatingPresentationManager = nil;
    self.floatingPresenter = nil;
    @try {
        if ([presenter respondsToSelector:@selector(deactivate)]) {
            [presenter deactivate];
        }
        if ([presenter respondsToSelector:@selector(invalidate)]) {
            [presenter invalidate];
        }
    } @catch (__unused NSException *exception) {
    }
    self.floatingStatusLabel.hidden = NO;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [self attachFloatingIdentifier:identifier
                                generation:generation
                                   attempt:0];
        });
}

- (void)layoutFloatingWindow {
    if (!self.floatingWindow) {
        return;
    }
    CGRect bounds = self.floatingWindow.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    if (width <= 0.0 || height <= 0.0) {
        return;
    }

    UIEdgeInsets safeInsets =
        self.floatingWindow.rootViewController.view.safeAreaInsets;
    CGFloat containerWidth = width * 0.77;
    CGFloat containerHeight = 520.0;
    CGFloat top = MAX(safeInsets.top, width > height ? 12.0 : 10.0);
    BOOL landscape = width > height;
    CGFloat originX = 0.0;
    if (landscape) {
        CGFloat portraitRatio = (390.0 * 0.77) / 520.0;
        CGFloat verticalMargin = 16.0;
        containerHeight = MAX(240.0, height - verticalMargin * 2.0);
        containerWidth = containerHeight * portraitRatio;
        top = floor((height - containerHeight) * 0.5);
        originX = MAX(0.0, safeInsets.left);
    } else {
        CGFloat centeredUpperTop =
            floor((height - containerHeight) * 0.5 - 44.0);
        top = MAX(safeInsets.top + 8.0, centeredUpperTop);
        CGFloat maximumHeight = MAX(180.0, height - top - 72.0);
        if (containerHeight > maximumHeight) {
            CGFloat scale = maximumHeight / containerHeight;
            containerHeight = maximumHeight;
            containerWidth *= scale;
        }
        originX = floor((width - containerWidth) * 0.5);
    }
    self.floatingContainer.frame =
        CGRectMake(originX, top, containerWidth, containerHeight);
    [self layoutFloatingHostView];
    self.floatingStatusLabel.frame = self.floatingContainer.bounds;
    [self layoutFloatingHandleForCurrentContainer];
}

- (void)layoutFloatingHandleForCurrentContainer {
    CGRect bounds = self.floatingWindow.rootViewController.view.bounds;
    BOOL landscape =
        CGRectGetWidth(bounds) > CGRectGetHeight(bounds);
    CGFloat containerWidth = CGRectGetWidth(self.floatingContainer.frame);
    CGFloat containerHeight = CGRectGetHeight(self.floatingContainer.frame);
    if (landscape) {
        CGFloat handleHeight = containerHeight * 0.30;
        self.floatingHandle.frame =
            CGRectMake(CGRectGetMaxX(self.floatingContainer.frame) + 2.0,
                       floor(CGRectGetMidY(self.floatingContainer.frame) -
                             handleHeight * 0.5),
                       44.0,
                       handleHeight);
        self.floatingHandleBar.frame =
            CGRectMake(0.0, 0.0, 5.0, handleHeight);
    } else {
        CGFloat handleWidth = containerWidth * 0.30;
        self.floatingHandle.frame =
            CGRectMake(floor(CGRectGetMidX(self.floatingContainer.frame) -
                             handleWidth * 0.5),
                       CGRectGetMaxY(self.floatingContainer.frame) + 2.0,
                       handleWidth,
                       44.0);
        self.floatingHandleBar.frame =
            CGRectMake(0.0, floor((44.0 - 5.0) * 0.5), handleWidth, 5.0);
    }
}

- (void)layoutFloatingHostView {
    UIView *host = self.floatingHostView;
    if (!host || !self.floatingContainer) {
        return;
    }
    CGSize referenceSize = self.floatingHostReferenceSize;
    if (referenceSize.width < 1.0 || referenceSize.height < 1.0) {
        referenceSize = self.floatingWindow.bounds.size;
    }
    CGSize targetSize = self.floatingContainer.bounds.size;
    if (targetSize.width < 1.0 || targetSize.height < 1.0) {
        return;
    }

    BOOL targetIsLandscape = targetSize.width > targetSize.height;
    BOOL referenceIsLandscape = referenceSize.width > referenceSize.height;
    if (targetIsLandscape != referenceIsLandscape) {
        referenceSize =
            CGSizeMake(referenceSize.height, referenceSize.width);
    }

    CGFloat widthScale = targetSize.width / referenceSize.width;
    CGFloat heightScale = targetSize.height / referenceSize.height;
    CGFloat scale = self.floatingInteractiveFullscreenTransition
                        ? MAX(widthScale, heightScale)
                        : MIN(widthScale, heightScale);
    host.transform = CGAffineTransformIdentity;
    host.bounds = CGRectMake(0.0,
                             0.0,
                             referenceSize.width,
                             referenceSize.height);
    host.center = CGPointMake(CGRectGetMidX(self.floatingContainer.bounds),
                              CGRectGetMidY(self.floatingContainer.bounds));
    host.transform = CGAffineTransformMakeScale(scale, scale);
}

- (void)keyboardFrameWillChange:(NSNotification *)notification {
    if (self.floatingWindow.hidden) {
        return;
    }
    NSValue *frameValue = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (![frameValue isKindOfClass:[NSValue class]]) {
        return;
    }
    CGRect bounds = self.floatingWindow.rootViewController.view.bounds;
    CGRect reportedFrame = frameValue.CGRectValue;
    if (!CGRectIntersectsRect(bounds, reportedFrame) ||
        CGRectGetMinY(reportedFrame) >= CGRectGetHeight(bounds)) {
        [self keyboardWillHide:notification];
        return;
    }

    BOOL landscape = CGRectGetWidth(bounds) > CGRectGetHeight(bounds);
    if (!landscape) {
        CGFloat reportedHeight = CGRectGetHeight(reportedFrame);
        if (reportedHeight >= 180.0 && reportedHeight <= 420.0) {
            self.lastPortraitKeyboardHeight = reportedHeight;
        }
        self.floatingKeyboardFrame = CGRectIntersection(bounds, reportedFrame);
        self.floatingKeyboardVisible = YES;
        self.floatingBackdropTap.additionalProtectedFrame =
            self.floatingKeyboardFrame;
        [self applyLandscapeKeyboardLayout];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.08 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self applyLandscapeKeyboardLayout];
        });
        return;
    }

    CGFloat portraitWidth = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat reportedHeight = CGRectGetHeight(reportedFrame);
    CGFloat keyboardHeight =
        reportedHeight >= 200.0 ? reportedHeight : self.lastPortraitKeyboardHeight;
    keyboardHeight =
        MIN(CGRectGetHeight(bounds), MAX(216.0, keyboardHeight));
    self.floatingKeyboardFrame =
        CGRectMake(CGRectGetWidth(bounds) - portraitWidth,
                   CGRectGetHeight(bounds) - keyboardHeight,
                   portraitWidth,
                   keyboardHeight);
    self.floatingKeyboardVisible = YES;
    self.floatingBackdropTap.additionalProtectedFrame =
        self.floatingKeyboardFrame;
    [self applyLandscapeKeyboardLayout];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self applyLandscapeKeyboardLayout];
    });
}

- (void)keyboardWillHide:(NSNotification *)notification {
    (void)notification;
    self.floatingKeyboardVisible = NO;
    self.floatingKeyboardFrame = CGRectNull;
    self.floatingBackdropTap.additionalProtectedFrame = CGRectNull;
    [self restoreKeyboardWindowFrames];
}

- (void)applyLandscapeKeyboardLayout {
    if (!self.floatingKeyboardVisible ||
        self.floatingWindow.hidden) {
        return;
    }
    BOOL landscape =
        CGRectGetWidth(self.floatingWindow.bounds) >
        CGRectGetHeight(self.floatingWindow.bounds);
    NSMutableOrderedSet<UIWindow *> *windows = [NSMutableOrderedSet orderedSet];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
            }
        }
    }
    for (UIWindow *window in windows) {
        if (window.hidden || window == self.floatingWindow ||
            window == self.overlayWindow || window == self.hotspotWindow) {
            continue;
        }
        NSString *className = NSStringFromClass(window.class);
        BOOL looksLikeKeyboard =
            [className rangeOfString:@"Keyboard"
                             options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [className rangeOfString:@"TextEffects"
                             options:NSCaseInsensitiveSearch].location != NSNotFound;
        if (!looksLikeKeyboard) {
            continue;
        }
        if (![self.keyboardOriginalFrames objectForKey:window]) {
            [self.keyboardOriginalFrames
                setObject:[NSValue valueWithCGRect:window.frame]
                   forKey:window];
            [self.keyboardOriginalLevels
                setObject:@(window.windowLevel)
                   forKey:window];
        }
        window.windowLevel = self.floatingWindow.windowLevel + 1.0;
        if (landscape &&
            !CGRectEqualToRect(window.frame, self.floatingKeyboardFrame)) {
            window.frame = self.floatingKeyboardFrame;
        }
    }
}

- (void)restoreKeyboardWindowFrames {
    for (UIWindow *window in self.keyboardOriginalFrames) {
        NSValue *frameValue = [self.keyboardOriginalFrames objectForKey:window];
        if (window && frameValue) {
            window.frame = frameValue.CGRectValue;
            NSNumber *levelValue =
                [self.keyboardOriginalLevels objectForKey:window];
            if (levelValue) {
                window.windowLevel = levelValue.doubleValue;
            }
        }
    }
    [self.keyboardOriginalFrames removeAllObjects];
    [self.keyboardOriginalLevels removeAllObjects];
}

- (CGSize)floatingSceneReferenceSize {
    CGSize screenSize = self.floatingWindow.bounds.size;
    CGSize containerSize = self.floatingContainer.bounds.size;
    if (screenSize.width < 1.0 || screenSize.height < 1.0 ||
        containerSize.width < 1.0 || containerSize.height < 1.0) {
        return CGSizeZero;
    }
    CGFloat logicalWidth =
        screenSize.width > screenSize.height ? screenSize.height : screenSize.width;
    CGFloat visualScale = containerSize.width / logicalWidth;
    if (visualScale <= 0.0) {
        return CGSizeZero;
    }
    return CGSizeMake(logicalWidth,
                      containerSize.height / visualScale);
}

- (FLMApplicationSceneHandle *)sceneHandleForIdentifier:(NSString *)identifier {
    if (identifier.length == 0) {
        return nil;
    }
    @try {
        if (self.floatingSceneEntity &&
            [identifier isEqualToString:self.floatingIdentifier] &&
            [self.floatingSceneEntity respondsToSelector:@selector(sceneHandle)]) {
            id existingCandidate = [self.floatingSceneEntity sceneHandle];
            if ([existingCandidate respondsToSelector:@selector(sceneIfExists)] ||
                [existingCandidate respondsToSelector:@selector(scene)]) {
                return (FLMApplicationSceneHandle *)existingCandidate;
            }
        }

        Class controllerClass = NSClassFromString(@"SBApplicationController");
        if (![controllerClass respondsToSelector:@selector(sharedInstance)]) {
            return nil;
        }
        FLMSBApplicationController *controller =
            (FLMSBApplicationController *)[controllerClass sharedInstance];
        if (![controller respondsToSelector:
                            @selector(applicationWithBundleIdentifier:)]) {
            return nil;
        }
        FLMSBApplication *application =
            (FLMSBApplication *)[controller
                applicationWithBundleIdentifier:identifier];
        if (!application) {
            return nil;
        }

        Class entityClass =
            NSClassFromString(@"SBDeviceApplicationSceneEntity");
        SEL initializer =
            @selector(initWithApplicationForMainDisplay:
                 generatingNewPrimarySceneIfRequired:);
        id allocatedEntity = [entityClass alloc];
        if (!allocatedEntity ||
            ![allocatedEntity respondsToSelector:initializer]) {
            return nil;
        }
        FLMDeviceApplicationSceneEntity *entity =
            [(FLMDeviceApplicationSceneEntity *)allocatedEntity
                initWithApplicationForMainDisplay:application
                generatingNewPrimarySceneIfRequired:YES];
        if (!entity ||
            ![entity respondsToSelector:@selector(sceneHandle)]) {
            return nil;
        }
        self.floatingSceneEntity = entity;
        id candidate = [entity sceneHandle];
        if (![candidate respondsToSelector:@selector(sceneIfExists)] &&
            ![candidate respondsToSelector:@selector(scene)]) {
            return nil;
        }
        return (FLMApplicationSceneHandle *)candidate;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

- (id)sceneForHandle:(FLMApplicationSceneHandle *)sceneHandle {
    if (!sceneHandle) {
        return nil;
    }
    id scene = nil;
    @try {
        if ([sceneHandle respondsToSelector:@selector(sceneIfExists)]) {
            scene = [sceneHandle sceneIfExists];
        }
        if (!scene && [sceneHandle respondsToSelector:@selector(scene)]) {
            scene = [sceneHandle scene];
        }
    } @catch (__unused NSException *exception) {
        scene = nil;
    }
    return scene;
}

- (BOOL)prepareFloatingScene:(id)scene
                      handle:(FLMApplicationSceneHandle *)sceneHandle {
    if (!scene) {
        return NO;
    }
    FLMProtectScene(scene, sceneHandle);
    @try {
        if ([scene respondsToSelector:@selector(_setContentState:)]) {
            [scene _setContentState:2];
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
        if ([mutableSettings respondsToSelector:@selector(setDeactivationReasons:)]) {
            [mutableSettings setDeactivationReasons:0];
        }
        if ([mutableSettings respondsToSelector:@selector(setForeground:)]) {
            [mutableSettings setForeground:YES];
        }
        if ([mutableSettings respondsToSelector:@selector(setBackgrounded:)]) {
            [mutableSettings setBackgrounded:NO];
        }
        CGSize referenceSize = [self floatingSceneReferenceSize];
        if (referenceSize.width > 0.0 && referenceSize.height > 0.0 &&
            [mutableSettings respondsToSelector:@selector(setFrame:)]) {
            [mutableSettings
                setFrame:CGRectMake(0.0,
                                    0.0,
                                    referenceSize.width,
                                    referenceSize.height)];
        }
        BOOL landscapeWindow =
            CGRectGetWidth(self.floatingWindow.bounds) >
            CGRectGetHeight(self.floatingWindow.bounds);
        NSInteger orientation = 1;
        if (!landscapeWindow &&
            [sceneHandle respondsToSelector:
                             @selector(currentInterfaceOrientation)]) {
            orientation = [sceneHandle currentInterfaceOrientation];
        }
        if (orientation < 1 || orientation > 4) {
            orientation = 1;
        }
        if ([mutableSettings respondsToSelector:
                             @selector(setInterfaceOrientation:)]) {
            [mutableSettings setInterfaceOrientation:orientation];
        }
        if (![scene respondsToSelector:
                       @selector(updateSettings:withTransitionContext:)]) {
            FLMClearProtectedScene(scene);
            return NO;
        }
        [scene updateSettings:mutableSettings withTransitionContext:nil];
        return YES;
    } @catch (__unused NSException *exception) {
        FLMClearProtectedScene(scene);
        return NO;
    }
}

- (void)backgroundFloatingScene:(id)scene {
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

- (UIView *)hostViewForSceneHandle:(FLMApplicationSceneHandle *)sceneHandle {
    if (!sceneHandle) {
        return nil;
    }
    id scene = [self sceneForHandle:sceneHandle];
    if (![self prepareFloatingScene:scene handle:sceneHandle]) {
        return nil;
    }
    self.floatingScene = scene;
    self.floatingHostReferenceSize = [self floatingSceneReferenceSize];

    id manager = self.floatingPresentationManager;
    id presenter = self.floatingPresenter;
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
        if (manager && manager != self.floatingPresentationManager) {
            self.floatingPresentationManager = manager;
        }
        if (!presenter) {
            if (![manager respondsToSelector:
                             @selector(createPresenterWithIdentifier:)]) {
                return nil;
            }
            presenter =
                [manager createPresenterWithIdentifier:
                             @"com.codex.flymemultitasking.centered"];
            if (presenter) {
                self.floatingPresenter = presenter;
            }
            if ([presenter respondsToSelector:@selector(activate)]) {
                [presenter activate];
            }
        }
        if ([presenter respondsToSelector:@selector(presentationView)]) {
            host = [presenter presentationView];
        }
    } @catch (__unused NSException *exception) {
        host = nil;
    }
    if (![host isKindOfClass:[UIView class]]) {
        return nil;
    }
    self.floatingPresentationManager = manager;
    self.floatingPresenter = presenter;
    host.backgroundColor = [UIColor blackColor];
    host.userInteractionEnabled = YES;
    host.clipsToBounds = YES;
    return host;
}

- (void)openFloatingIdentifier:(NSString *)identifier {
    if (identifier.length == 0 || FLMDeviceIsLocked()) {
        return;
    }
    if ([identifier isEqualToString:FLMFrontmostApplicationIdentifier()]) {
        return;
    }

    self.floatingReconnectSuppressed = NO;
    self.floatingInteractiveScenePrepared = NO;
    self.floatingInteractiveFullscreenTransition = NO;
    self.floatingCenteredReferenceSize = CGSizeZero;
    [self.floatingInteractiveSnapshot removeFromSuperview];
    self.floatingInteractiveSnapshot = nil;
    self.floatingKeyboardVisible = NO;
    self.floatingKeyboardFrame = CGRectNull;
    self.floatingBackdropTap.additionalProtectedFrame = CGRectNull;
    self.floatingLaunchGeneration += 1;
    NSUInteger generation = self.floatingLaunchGeneration;
    [self.floatingHostView removeFromSuperview];
    self.floatingHostView = nil;
    self.floatingHostReferenceSize = CGSizeZero;
    self.floatingSceneEntity = nil;
    self.floatingSceneHandle = nil;
    self.floatingScene = nil;
    self.floatingPresentationManager = nil;
    self.floatingPresenter = nil;
    self.floatingIdentifier = identifier;
    self.floatingStatusLabel.hidden = NO;
    self.floatingStatusLabel.text = @"正在打开…";
    [self layoutFloatingWindow];

    self.floatingDimView.alpha = 0.0;
    self.floatingContainer.alpha = 0.0;
    self.floatingContainer.transform = CGAffineTransformMakeScale(0.90, 0.90);
    self.floatingHandle.alpha = 0.0;
    self.previousKeyWindow = FLMCurrentKeyWindow();
    self.floatingExclusiveGesture.enabled = self.usesSystemGestureManager;
    self.cornerGuardGesture.enabled = NO;
    self.cornerGesture.enabled = NO;
    [self.floatingWindow makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self layoutFloatingWindow];
    });
    [UIView animateWithDuration:0.46
                          delay:0.0
         usingSpringWithDamping:0.78
          initialSpringVelocity:0.45
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         self.floatingDimView.alpha = 1.0;
                         self.floatingContainer.alpha = 1.0;
                         self.floatingContainer.transform = CGAffineTransformIdentity;
                         self.floatingHandle.alpha = 1.0;
                     }
                     completion:nil];

    UIApplication *application = [UIApplication sharedApplication];
    if ([application respondsToSelector:
                         @selector(launchApplicationWithIdentifier:suspended:)]) {
        [application launchApplicationWithIdentifier:identifier suspended:YES];
    }
    [self beginLockMonitoring];
    [self attachFloatingIdentifier:identifier
                        generation:generation
                           attempt:0];
}

- (void)attachFloatingIdentifier:(NSString *)identifier
                      generation:(NSUInteger)generation
                         attempt:(NSUInteger)attempt {
    if (generation != self.floatingLaunchGeneration ||
        ![identifier isEqualToString:self.floatingIdentifier] ||
        self.floatingWindow.hidden) {
        return;
    }
    FLMApplicationSceneHandle *sceneHandle =
        [self sceneHandleForIdentifier:identifier];
    if (!sceneHandle) {
        self.floatingStatusLabel.text = @"正在准备应用…";
        if (attempt < 30) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [self attachFloatingIdentifier:identifier
                                        generation:generation
                                           attempt:attempt + 1];
                });
            return;
        }
        self.floatingReconnectSuppressed = YES;
        [self closeFloatingWindowKeepingApplication:YES];
        [self activateIdentifierFullscreen:identifier];
        return;
    }

    if (![self sceneForHandle:sceneHandle]) {
        self.floatingStatusLabel.text = @"正在启动应用…";
        if (attempt < 30) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [self attachFloatingIdentifier:identifier
                                        generation:generation
                                           attempt:attempt + 1];
                });
            return;
        }
        self.floatingReconnectSuppressed = YES;
        [self closeFloatingWindowKeepingApplication:YES];
        [self activateIdentifierFullscreen:identifier];
        return;
    }

    UIView *host = [self hostViewForSceneHandle:sceneHandle];
    if (!host) {
        self.floatingStatusLabel.text = @"正在连接画面…";
        if (attempt < 30) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [self attachFloatingIdentifier:identifier
                                        generation:generation
                                           attempt:attempt + 1];
                });
            return;
        }
        self.floatingReconnectSuppressed = YES;
        [self backgroundFloatingScene:[self sceneForHandle:sceneHandle]];
        [self closeFloatingWindowKeepingApplication:YES];
        [self activateIdentifierFullscreen:identifier];
        return;
    }
    self.floatingSceneHandle = sceneHandle;
    self.floatingHostView = host;
    if (self.floatingHostReferenceSize.width < 1.0 ||
        self.floatingHostReferenceSize.height < 1.0) {
        CGSize referenceSize = host.bounds.size;
        if (referenceSize.width < 1.0 || referenceSize.height < 1.0) {
            referenceSize = [self floatingSceneReferenceSize];
        }
        self.floatingHostReferenceSize = referenceSize;
    }
    host.autoresizingMask = UIViewAutoresizingNone;
    [self.floatingContainer insertSubview:host atIndex:0];
    [self layoutFloatingHostView];
    self.floatingStatusLabel.hidden = YES;
}

- (void)closeFloatingWindowKeepingApplication:(BOOL)keepApplication {
    self.floatingLaunchGeneration += 1;
    [self.floatingInteractiveSnapshot removeFromSuperview];
    self.floatingInteractiveSnapshot = nil;
    self.floatingInteractiveScenePrepared = NO;
    self.floatingInteractiveFullscreenTransition = NO;
    self.floatingCenteredReferenceSize = CGSizeZero;
    NSUInteger generation = self.floatingLaunchGeneration;
    id scene = self.floatingScene;
    id presenter = self.floatingPresenter;
    UIWindow *previousKeyWindow = self.previousKeyWindow;
    self.floatingSceneEntity = nil;
    self.floatingSceneHandle = nil;
    self.floatingScene = nil;
    self.floatingHostReferenceSize = CGSizeZero;
    self.floatingPresentationManager = nil;
    self.floatingPresenter = nil;
    self.floatingIdentifier = nil;
    self.floatingExclusiveGesture.enabled = NO;
    self.cornerGuardGesture.enabled = self.enabled;
    self.cornerGesture.enabled = self.enabled;
    self.previousKeyWindow = nil;
    self.floatingKeyboardVisible = NO;
    self.floatingKeyboardFrame = CGRectNull;
    self.floatingBackdropTap.additionalProtectedFrame = CGRectNull;
    [self restoreKeyboardWindowFrames];
    if (previousKeyWindow && previousKeyWindow != self.floatingWindow) {
        [previousKeyWindow makeKeyWindow];
    }
    if (self.floatingWindow.hidden) {
        [self.floatingHostView removeFromSuperview];
        self.floatingHostView = nil;
        @try {
            if ([presenter respondsToSelector:@selector(deactivate)]) {
                [presenter deactivate];
            }
            if ([presenter respondsToSelector:@selector(invalidate)]) {
                [presenter invalidate];
            }
        } @catch (__unused NSException *exception) {
        }
        if (keepApplication) {
            [self backgroundFloatingScene:scene];
        } else {
            FLMClearProtectedScene(scene);
        }
        [self stopLockMonitoringIfIdle];
        return;
    }

    [UIView animateWithDuration:0.24
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseIn
                     animations:^{
                         self.floatingDimView.alpha = 0.0;
                         self.floatingContainer.alpha = 0.0;
                         self.floatingContainer.transform =
                             CGAffineTransformMakeScale(0.94, 0.94);
                         self.floatingHandle.alpha = 0.0;
                     }
                     completion:^(BOOL finished) {
                         (void)finished;
                         if (generation != self.floatingLaunchGeneration) {
                             return;
                         }
                          [self.floatingHostView removeFromSuperview];
                          self.floatingHostView = nil;
                          @try {
                              if ([presenter respondsToSelector:@selector(deactivate)]) {
                                  [presenter deactivate];
                              }
                              if ([presenter respondsToSelector:@selector(invalidate)]) {
                                  [presenter invalidate];
                              }
                          } @catch (__unused NSException *exception) {
                          }
                          if (keepApplication) {
                              [self backgroundFloatingScene:scene];
                          } else {
                              FLMClearProtectedScene(scene);
                          }
                          self.floatingWindow.hidden = YES;
                         self.floatingDimView.alpha = 1.0;
                         self.floatingContainer.alpha = 1.0;
                         self.floatingContainer.transform =
                             CGAffineTransformIdentity;
                         self.floatingHandle.alpha = 1.0;
                         [self stopLockMonitoringIfIdle];
                     }];
}

- (void)beginLockMonitoring {
    if (self.lockMonitorTimer.valid) {
        return;
    }
    self.lockMonitorTimer =
        [NSTimer timerWithTimeInterval:0.35
                               target:self
                             selector:@selector(checkLockState:)
                             userInfo:nil
                              repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.lockMonitorTimer
                              forMode:NSRunLoopCommonModes];
}

- (void)stopLockMonitoringIfIdle {
    if (self.wheelPinned || !self.floatingWindow.hidden) {
        return;
    }
    [self.lockMonitorTimer invalidate];
    self.lockMonitorTimer = nil;
}

- (void)checkLockState:(NSTimer *)timer {
    (void)timer;
    if (!FLMDeviceIsLocked()) {
        [self stopLockMonitoringIfIdle];
        return;
    }
    if (self.wheelPinned || !self.overlayWindow.hidden) {
        [self dismissWheelLaunchingItem:nil];
    }
    if (!self.floatingWindow.hidden) {
        [self closeFloatingWindowKeepingApplication:YES];
    }
}

- (void)activateIdentifierFullscreen:(NSString *)identifier {
    if (identifier.length == 0) {
        return;
    }
    NSString *bundleIdentifier = [identifier copy];
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            UIApplication *application = [UIApplication sharedApplication];
            if ([application respondsToSelector:
                             @selector(launchApplicationWithIdentifier:suspended:)] &&
                [application launchApplicationWithIdentifier:bundleIdentifier
                                                   suspended:NO]) {
                return;
            }
            id workspace =
                [NSClassFromString(@"LSApplicationWorkspace") defaultWorkspace];
            if ([workspace respondsToSelector:
                              @selector(openApplicationWithBundleID:)]) {
                [workspace openApplicationWithBundleID:bundleIdentifier];
            }
        });
}

- (void)activateIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:FLYME_LOCK_SCREEN_ITEM]) {
        UIApplication *application = [UIApplication sharedApplication];
        if ([application respondsToSelector:@selector(_simulateLockButtonPress)]) {
            [application _simulateLockButtonPress];
            return;
        }
        id manager = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
        if ([manager respondsToSelector:@selector(lockUIFromSource:withOptions:)]) {
            [manager lockUIFromSource:1 withOptions:nil];
        }
        return;
    }
    if ([identifier isEqualToString:FLMFrontmostApplicationIdentifier()]) {
        return;
    }
    [self openFloatingIdentifier:identifier];
}

@end

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    (void)application;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [[FLMWheelController sharedController] start];
                   });
}

%end

%ctor {
    if (notify_register_check(FLYME_RUNTIME_NOTIFICATION, &FlymeRuntimeToken) ==
        NOTIFY_STATUS_OK) {
        uint64_t state = (FLYME_RUNTIME_MAGIC << 32) | (uint32_t)getpid();
        notify_set_state(FlymeRuntimeToken, state);
        notify_post(FLYME_RUNTIME_NOTIFICATION);
    }
}
