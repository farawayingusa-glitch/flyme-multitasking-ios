#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <notify.h>
#import <objc/message.h>
#import <stdarg.h>
#import <stdint.h>
#import <unistd.h>

#import "FLMSceneLifecycle.h"

#define FLYME_RUNTIME_NOTIFICATION "com.codex.flymemultitasking.runtime"
#define FLYME_PREFERENCES_NOTIFICATION CFSTR("com.codex.flymemultitasking.preferences-changed")
#define FLYME_PREFERENCES_DOMAIN CFSTR("com.codex.flymemultitasking")
#define FLYME_KEYBOARD_NOTIFICATION "com.codex.flymemultitasking.keyboard-state-changed"
#define FLYME_KEYBOARD_SCENE_NOTIFICATION "com.codex.flymemultitasking.keyboard-scene-changed"
#define FLYME_KEYBOARD_FRAME_NOTIFICATION "com.codex.flymemultitasking.keyboard-frame-changed"
#define FLYME_KEYBOARD_PREPARE_NOTIFICATION "com.codex.flymemultitasking.keyboard-prepare-fullscreen-host"
#define FLYME_RUNTIME_MAGIC 0x464C594DULL
#define FLYME_LOCK_SCREEN_ITEM @"com.codex.flymemultitasking.lockscreen"

static const CGFloat FLMDefaultWheelRadius = 202.0;
static const CGFloat FLMMinimumWheelRadius = 170.0;
static const CGFloat FLMMaximumWheelRadius = 225.0;
static const CGFloat FLMDefaultWheelIconSize = 56.0;
static const CGFloat FLMMinimumWheelIconSize = 44.0;
static const CGFloat FLMMaximumWheelIconSize = 68.0;
static const CGFloat FLMDefaultDockWidth = 156.0;
static const CGFloat FLMMinimumDockWidth = 156.0;
static const CGFloat FLMMaximumDockWidth = 270.0;
static const CGFloat FLMDockSideMargin = 10.0;
static const CGFloat FLMDockTopMargin = 8.0;
static const CGFloat FLMCenteredDockActivationDistance = 110.0;
static const NSTimeInterval FLMFloatingLaunchTimeout = 6.5;
static const NSTimeInterval FLMFloatingSceneSettleDelay = 0.18;
static const NSTimeInterval FLMFloatingSceneGenerationDelay = 0.75;
static NSString *const FLMKeyboardDiagnosticLogPath =
    @"/var/mobile/Library/Logs/FlymeKeyboardDiagnostic.log";
static const unsigned long long FLMKeyboardDiagnosticLogLimit = 512ULL * 1024ULL;

typedef NS_ENUM(NSUInteger, FLMFloatingLaunchState) {
    FLMFloatingLaunchStateIdle,
    FLMFloatingLaunchStatePrewarming,
    FLMFloatingLaunchStateWaitingForScene,
    FLMFloatingLaunchStateWaitingForPresenter,
    FLMFloatingLaunchStateAttached,
    FLMFloatingLaunchStateFailing,
    FLMFloatingLaunchStateClosing,
};

static void FLMKeyboardDiagnosticLog(NSString *format, ...)
    NS_FORMAT_FUNCTION(1, 2);

static void FLMKeyboardDiagnosticLog(NSString *format, ...) {
    if (format.length == 0) {
        return;
    }
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format
                                               arguments:arguments];
    va_end(arguments);
    if (message.length == 0) {
        return;
    }
    NSLog(@"[FlymeKeyboardDiagnostic] %@", message);

    @autoreleasepool {
        NSString *line =
            [NSString stringWithFormat:@"%.3f pid=%d %@\n",
                                       [NSDate date].timeIntervalSince1970,
                                       getpid(), message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) {
            return;
        }
        @synchronized([NSFileManager class]) {
            @try {
                NSFileManager *manager = [NSFileManager defaultManager];
                NSString *directory =
                    [FLMKeyboardDiagnosticLogPath stringByDeletingLastPathComponent];
                [manager createDirectoryAtPath:directory
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:nil];
                NSDictionary *attributes =
                    [manager attributesOfItemAtPath:FLMKeyboardDiagnosticLogPath
                                              error:nil];
                unsigned long long size =
                    [attributes[NSFileSize] unsignedLongLongValue];
                if (size > FLMKeyboardDiagnosticLogLimit) {
                    [data writeToFile:FLMKeyboardDiagnosticLogPath atomically:YES];
                    return;
                }
                if (![manager fileExistsAtPath:FLMKeyboardDiagnosticLogPath]) {
                    [data writeToFile:FLMKeyboardDiagnosticLogPath atomically:YES];
                    return;
                }
                NSFileHandle *handle =
                    [NSFileHandle fileHandleForWritingAtPath:FLMKeyboardDiagnosticLogPath];
                [handle seekToEndOfFile];
                [handle writeData:data];
                [handle synchronizeFile];
                [handle closeFile];
            } @catch (NSException *exception) {
                NSLog(@"[FlymeKeyboardDiagnostic] file-write-failed %@",
                      exception.reason ?: @"<unknown>");
            }
        }
    }
}

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
    SEL statusBarSelector = NSSelectorFromString(@"statusBarOrientation");
    if ([application respondsToSelector:statusBarSelector]) {
        UIInterfaceOrientation (*orientationGetter)(id, SEL) =
            (UIInterfaceOrientation (*)(id, SEL))
                [application methodForSelector:statusBarSelector];
        UIInterfaceOrientation statusBarOrientation =
            orientationGetter
                ? orientationGetter(application, statusBarSelector)
                : UIInterfaceOrientationUnknown;
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

static BOOL FLMPrewarmApplicationIdentifier(NSString *identifier) {
    if (identifier.length == 0 ||
        [identifier isEqualToString:FLYME_LOCK_SCREEN_ITEM]) {
        return NO;
    }
    UIApplication *application = [UIApplication sharedApplication];
    if (![application respondsToSelector:
                         @selector(launchApplicationWithIdentifier:suspended:)]) {
        return NO;
    }
    return [application launchApplicationWithIdentifier:identifier
                                               suspended:YES];
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
@property(nonatomic, assign) BOOL passesTouchesOutsideFloatingContent;
@property(nonatomic, assign) CGRect keyboardPassThroughFrame;
@property(nonatomic, weak) UIView *floatingContentView;
@property(nonatomic, weak) UIView *floatingPrimaryControlView;
@property(nonatomic, weak) UIView *floatingSecondaryControlView;
@end

@implementation FLMFloatingWindow

- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // A remote scene can retain an oversized hit-test view for one layout
    // transaction after it is reattached.  Always give the centered handle
    // first refusal: it owns the only gestures that leave centered mode.
    UIView *primaryControl = self.floatingPrimaryControlView;
    if (primaryControl && !primaryControl.hidden &&
        primaryControl.userInteractionEnabled && primaryControl.alpha > 0.01) {
        CGPoint primaryPoint = [self convertPoint:point toView:primaryControl];
        UIView *primaryHit = [primaryControl hitTest:primaryPoint withEvent:event];
        if (primaryHit) {
            return primaryHit;
        }
    }
    if (!CGRectIsNull(self.keyboardPassThroughFrame) &&
        CGRectContainsPoint(self.keyboardPassThroughFrame, point)) {
        return nil;
    }
    if (self.passesTouchesOutsideFloatingContent) {
        BOOL insideContent =
            self.floatingContentView &&
            CGRectContainsPoint(CGRectInset(self.floatingContentView.frame, -2.0, -2.0),
                                point);
        BOOL insidePrimaryControl =
            self.floatingPrimaryControlView &&
            !self.floatingPrimaryControlView.hidden &&
            CGRectContainsPoint(CGRectInset(self.floatingPrimaryControlView.frame,
                                            -6.0,
                                            -6.0),
                                point);
        BOOL insideSecondaryControl =
            self.floatingSecondaryControlView &&
            !self.floatingSecondaryControlView.hidden &&
            CGRectContainsPoint(CGRectInset(self.floatingSecondaryControlView.frame,
                                            -12.0,
                                            -12.0),
                                point);
        if (!insideContent && !insidePrimaryControl && !insideSecondaryControl) {
            return nil;
        }
    }
    return [super hitTest:point withEvent:event];
}

@end

@interface FLMKeyboardOverlayWindow : FLMOverlayWindow
@property(nonatomic, assign) CGRect keyboardInteractionFrame;
@end

@implementation FLMKeyboardOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (CGRectIsNull(self.keyboardInteractionFrame) ||
        !CGRectContainsPoint(self.keyboardInteractionFrame, point)) {
        return nil;
    }
    return [super hitTest:point withEvent:event];
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
    if (self.startPoints.count + touches.count > 1) {
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
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
@property(nonatomic, strong) UIView *floatingDockShadowView;
@property(nonatomic, strong) UIView *floatingContainer;
@property(nonatomic, strong) UIView *floatingDockInteractionShield;
@property(nonatomic, strong) UIView *floatingDockReadyIndicator;
@property(nonatomic, strong) CAShapeLayer *floatingDockReadyCheckLayer;
@property(nonatomic, strong) UIView *floatingHandle;
@property(nonatomic, strong) UIView *floatingHandleBar;
@property(nonatomic, strong) UIView *floatingResizeHandle;
@property(nonatomic, strong) CAShapeLayer *floatingResizeShapeLayer;
@property(nonatomic, strong) UIView *floatingHostView;
@property(nonatomic, strong) UILabel *floatingStatusLabel;
@property(nonatomic, strong) FLMOutsideTapGestureRecognizer *floatingBackdropTap;
@property(nonatomic, strong) UILongPressGestureRecognizer *floatingHandlePress;
@property(nonatomic, strong) UITapGestureRecognizer *floatingHandleTap;
@property(nonatomic, strong) UITapGestureRecognizer *floatingDockTap;
@property(nonatomic, strong) UILongPressGestureRecognizer *floatingDockDragPress;
@property(nonatomic, strong) UILongPressGestureRecognizer *floatingResizePress;
@property(nonatomic, strong) FLMCornerGestureRecognizer *floatingExclusiveGesture;
@property(nonatomic, strong) FLMCornerGestureRecognizer *floatingDockInputGesture;
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
@property(nonatomic, assign) BOOL floatingDocked;
@property(nonatomic, assign) BOOL floatingDockedOnRight;
@property(nonatomic, assign) BOOL floatingDockTransitionActive;
@property(nonatomic, assign) CGFloat floatingDockWidth;
@property(nonatomic, assign) CGPoint floatingDockDragStartPoint;
@property(nonatomic, assign) CGPoint floatingDockDragInitialCenter;
@property(nonatomic, assign) CGPoint floatingResizeStartPoint;
@property(nonatomic, assign) CGRect floatingResizeInitialFrame;
@property(nonatomic, assign) CGPoint floatingDockInputLatestPoint;
@property(nonatomic, assign) BOOL floatingDockInputTargetsResize;
@property(nonatomic, assign) BOOL floatingDockGlobalDragActivated;
@property(nonatomic, assign) NSUInteger floatingDockInputGeneration;
@property(nonatomic, assign) BOOL floatingDockReady;
@property(nonatomic, assign) BOOL floatingResizeCenterReady;
@property(nonatomic, assign) CGPoint floatingExclusiveStartPoint;
@property(nonatomic, assign) NSTimeInterval floatingExclusiveStartTimestamp;
@property(nonatomic, assign) BOOL floatingExclusiveTapEligible;
@property(nonatomic, assign) BOOL floatingInteractiveFullscreenTransition;
@property(nonatomic, assign) BOOL floatingInteractiveScenePrepared;
@property(nonatomic, assign) CGFloat floatingFullscreenProgress;
@property(nonatomic, strong) UIView *floatingInteractiveSnapshot;
@property(nonatomic, strong) UIView *floatingInteractiveSnapshotBackground;
@property(nonatomic, strong) UIView *floatingInteractiveSnapshotContent;
@property(nonatomic, assign) BOOL floatingReconnectSuppressed;
@property(nonatomic, assign) BOOL floatingKeyboardVisible;
@property(nonatomic, assign) CGRect floatingKeyboardFrame;
@property(nonatomic, assign) CGFloat lastPortraitKeyboardHeight;
@property(nonatomic, assign) int keyboardFrameNotifyToken;
@property(nonatomic, assign) int keyboardPrepareNotifyToken;
@property(nonatomic, assign) BOOL floatingKeyboardInteractionSessionActive;
@property(nonatomic, assign) NSUInteger floatingKeyboardInteractionGeneration;
@property(nonatomic, assign) NSUInteger floatingKeyboardPrepareGeneration;
@property(nonatomic, strong) FLMKeyboardOverlayWindow *keyboardOverlayWindow;
@property(nonatomic, weak) UIView *floatingKeyboardLayerHostView;
@property(nonatomic, weak) UIView *floatingReusableKeyboardLayerHostView;
@property(nonatomic, weak) id floatingReusableKeyboardScene;
@property(nonatomic, copy) NSString *floatingReusableKeyboardSceneIdentifier;
@property(nonatomic, weak) UIView *floatingKeyboardOriginalSuperview;
@property(nonatomic, assign) NSInteger floatingKeyboardOriginalSubviewIndex;
@property(nonatomic, assign) CGRect floatingKeyboardOriginalFrame;
@property(nonatomic, assign) CGAffineTransform floatingKeyboardOriginalTransform;
@property(nonatomic, assign) UIViewAutoresizing floatingKeyboardOriginalAutoresizingMask;
@property(nonatomic, assign) BOOL floatingKeyboardOriginalTranslatesAutoresizingMask;
@property(nonatomic, assign) BOOL floatingKeyboardDetachPending;
@property(nonatomic, assign) NSUInteger floatingKeyboardDetachGeneration;
@property(nonatomic, assign) CGPoint cornerGestureStartPoint;
@property(nonatomic, copy) NSString *floatingIdentifier;
@property(nonatomic, copy) NSString *prewarmedIdentifier;
@property(nonatomic, copy) NSString *lastObservedFrontmostIdentifier;
@property(nonatomic, assign) BOOL floatingExternalActivationArmed;
@property(nonatomic, strong) FLMDeviceApplicationSceneEntity *floatingSceneEntity;
@property(nonatomic, strong) FLMApplicationSceneHandle *floatingSceneHandle;
@property(nonatomic, strong) id floatingScene;
@property(nonatomic, strong) id floatingPresentationManager;
@property(nonatomic, strong) id floatingPresenter;
@property(nonatomic, assign) CGSize floatingHostReferenceSize;
@property(nonatomic, assign) NSUInteger floatingLaunchGeneration;
@property(nonatomic, assign) FLMFloatingLaunchState floatingLaunchState;
@property(nonatomic, assign) NSTimeInterval floatingLaunchStartedAt;
@property(nonatomic, assign) NSTimeInterval floatingScenePreparedAt;
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
- (void)handleFloatingDockTap:(UITapGestureRecognizer *)gesture;
- (void)handleFloatingDockDragPress:(UILongPressGestureRecognizer *)gesture;
- (void)handleFloatingResizePress:(UILongPressGestureRecognizer *)gesture;
- (void)handleFloatingExclusiveGesture:(UIGestureRecognizer *)gesture;
- (void)handleFloatingDockInputGesture:(FLMCornerGestureRecognizer *)gesture;
- (void)activateFloatingDockDragForGeneration:(NSUInteger)generation;
- (void)keyboardFrameWillChange:(NSNotification *)notification;
- (void)keyboardDidHide:(NSNotification *)notification;
- (void)applyKeyboardFrame:(CGRect)frame visible:(BOOL)visible;
- (void)prepareFloatingKeyboardHostIfNeeded;
- (void)requestFloatingKeyboardHostPreparation;
- (void)keyboardLayerHostView:(UIView *)hostView didUpdateForScene:(id)scene;
- (void)detachFloatingKeyboardLayerHost;
- (void)scheduleFloatingKeyboardLayerHostDetach;
- (void)clearFloatingReusableKeyboardHost;
- (CGRect)floatingKeyboardInteractionFrame;
- (BOOL)pointIsInsideFloatingInteractionDomain:(CGPoint)point;
- (void)beginFloatingKeyboardInteractionSession;
- (void)endFloatingKeyboardInteractionSession;
- (void)resetFloatingInteractiveLayoutAnimated:(BOOL)animated;
- (void)setFloatingApplicationInputBlocked:(BOOL)blocked;
- (void)updateFloatingFullscreenSnapshotForProgress:(CGFloat)progress;
- (void)layoutFloatingHandleForCurrentContainer;
- (CGRect)centeredFloatingFrame;
- (CGRect)dockedFloatingFrameOnRight:(BOOL)onRight width:(CGFloat)width;
- (void)layoutFloatingDockShadow;
- (void)updateFloatingDockAccessoryPositions;
- (void)normalizeFloatingContainerTransform;
- (void)layoutFloatingResizeHandle;
- (void)layoutFloatingDockReadyIndicator;
- (void)setFloatingDockReady:(BOOL)ready animated:(BOOL)animated;
- (BOOL)floatingResizeControlContainsPoint:(CGPoint)point;
- (void)configureFloatingInteractionForDockedState;
- (void)restoreFloatingHandleInteraction;
- (void)transitionFloatingWindowToDocked;
- (void)transitionFloatingWindowToCentered;
- (void)snapDockedFloatingWindowUsingTouchPoint:(CGPoint)point;
- (void)saveFloatingDockWidth;
- (void)prepareFloatingSceneForInteractiveFullscreen;
- (void)restoreFloatingSceneAfterCancelledTransition;
- (void)transitionFloatingWindowToFullscreen;
- (void)finishFullscreenHandoffWithCover:(UIView *)cover
                              identifier:(NSString *)identifier
                                 attempt:(NSUInteger)attempt;
- (void)protectedSceneDidDisappear:(NSNotification *)notification;
- (void)openFloatingIdentifier:(NSString *)identifier;
- (void)attachFloatingIdentifier:(NSString *)identifier
                      generation:(NSUInteger)generation
                           attempt:(NSUInteger)attempt;
- (void)failFloatingLaunchForIdentifier:(NSString *)identifier
                              generation:(NSUInteger)generation;
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
static int FlymeKeyboardRouteToken = -1;
static int FlymeKeyboardSceneToken = -1;

static id FLMCopyPreference(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyValue((__bridge CFStringRef)key,
                                                      FLYME_PREFERENCES_DOMAIN,
                                                      kCFPreferencesCurrentUser,
                                                      kCFPreferencesAnyHost);
    return CFBridgingRelease(value);
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

static NSString *FLMSceneIdentifier(id scene) {
    if (!scene) {
        return nil;
    }
    @try {
        if ([scene respondsToSelector:@selector(sceneIdentifier)]) {
            id value = [scene sceneIdentifier];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return value;
            }
        }
        if ([scene respondsToSelector:@selector(identifier)]) {
            id value = [scene identifier];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return value;
            }
        }
        id settings = [scene respondsToSelector:@selector(settings)]
                          ? [scene settings]
                          : nil;
        if ([settings respondsToSelector:@selector(sceneIdentifier)]) {
            id value = [settings sceneIdentifier];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return value;
            }
        }
        if ([settings respondsToSelector:@selector(identifier)]) {
            id value = [settings identifier];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return value;
            }
        }
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static void FLMPublishKeyboardState(NSString *identifier, id scene) {
    if (FlymeKeyboardRouteToken < 0 &&
        notify_register_check(FLYME_KEYBOARD_NOTIFICATION,
                              &FlymeKeyboardRouteToken) != NOTIFY_STATUS_OK) {
        return;
    }
    if (FlymeKeyboardSceneToken < 0) {
        notify_register_check(FLYME_KEYBOARD_SCENE_NOTIFICATION,
                              &FlymeKeyboardSceneToken);
    }
    notify_set_state(FlymeKeyboardRouteToken, FLMIdentifierHash(identifier));
    if (FlymeKeyboardSceneToken >= 0) {
        notify_set_state(FlymeKeyboardSceneToken,
                         FLMIdentifierHash(FLMSceneIdentifier(scene)));
        notify_post(FLYME_KEYBOARD_SCENE_NOTIFICATION);
    }
    notify_post(FLYME_KEYBOARD_NOTIFICATION);
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

static FLMKeyboardOverlayWindow *FLMCreateKeyboardOverlayWindow(CGRect frame) {
    UIWindowScene *scene = FLMForegroundWindowScene();
    if (@available(iOS 13.0, *)) {
        if (scene) {
            FLMKeyboardOverlayWindow *window =
                [[FLMKeyboardOverlayWindow alloc] initWithWindowScene:scene];
            window.frame = frame;
            return window;
        }
    }
    return [[FLMKeyboardOverlayWindow alloc] initWithFrame:frame];
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
        FLMKeyboardDiagnosticLog(@"process-start build=0.8.12-diagnostic home=%@",
                                 NSHomeDirectory() ?: @"<unknown>");
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
               selector:@selector(keyboardDidHide:)
                   name:UIKeyboardDidHideNotification
                 object:nil];
        self.lastPortraitKeyboardHeight = 291.0;
        self.floatingKeyboardFrame = CGRectNull;
        // Dock resizing is deliberately session-local. Every new dock transition
        // starts from the fixed minimum size instead of restoring a prior resize.
        self.floatingDockWidth = FLMDefaultDockWidth;
        self.floatingDockedOnRight = YES;
        int keyboardToken = -1;
        if (notify_register_dispatch(FLYME_KEYBOARD_FRAME_NOTIFICATION,
                                     &keyboardToken,
                                     dispatch_get_main_queue(),
                                     ^(int token) {
            uint64_t state = 0;
            if (notify_get_state(token, &state) != NOTIFY_STATUS_OK) {
                return;
            }
            BOOL visible = (state & (1ULL << 63)) != 0;
            CGFloat height = (CGFloat)(state & 0x7FFFFFFFFFFFFFFFULL) / 100.0;
            CGRect bounds = FLMVisualScreenBounds();
            height = MIN(CGRectGetHeight(bounds), MAX(0.0, height));
            CGRect frame = visible
                               ? CGRectMake(0.0,
                                            CGRectGetHeight(bounds) - height,
                                            CGRectGetWidth(bounds),
                                            height)
                               : CGRectNull;
            FLMKeyboardDiagnosticLog(
                @"frame-notify visible=%d height=%.1f frame=%@",
                visible, height, NSStringFromCGRect(frame));
            [[FLMWheelController sharedController] applyKeyboardFrame:frame
                                                               visible:visible];
        }) == NOTIFY_STATUS_OK) {
            self.keyboardFrameNotifyToken = keyboardToken;
        }
        int keyboardPrepareToken = -1;
        if (notify_register_dispatch(FLYME_KEYBOARD_PREPARE_NOTIFICATION,
                                     &keyboardPrepareToken,
                                      dispatch_get_main_queue(),
                                      ^(__unused int token) {
            FLMKeyboardDiagnosticLog(@"prepare-notify received");
            [[FLMWheelController sharedController]
                requestFloatingKeyboardHostPreparation];
        }) == NOTIFY_STATUS_OK) {
            self.keyboardPrepareNotifyToken = keyboardPrepareToken;
        }
        // Clear a stale per-app keyboard route left by a prior SpringBoard
        // process before any new centered card is opened.
        FLMPublishKeyboardState(nil, nil);
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
    // The system-wide recognizer only accepts touches that began outside the
    // card/handle/keyboard domain. Once accepted it must consume that outside
    // tap so the Home Screen does not also activate an icon underneath.
    self.floatingExclusiveGesture.cancelsTouchesInView = YES;
    self.floatingExclusiveGesture.delaysTouchesBegan = NO;
    self.floatingExclusiveGesture.delaysTouchesEnded = NO;
    self.floatingExclusiveGesture.numberOfTouchesRequired = 1;
    self.floatingExclusiveGesture.minimumPressDuration = 0.0;
    self.floatingExclusiveGesture.allowableMovement = CGFLOAT_MAX;
    self.floatingExclusiveGesture.enabled = NO;

    self.floatingDockInputGesture =
        [[FLMCornerGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingDockInputGesture:)];
    self.floatingDockInputGesture.delegate = self;
    self.floatingDockInputGesture.cancelsTouchesInView = YES;
    self.floatingDockInputGesture.delaysTouchesBegan = NO;
    self.floatingDockInputGesture.delaysTouchesEnded = NO;
    self.floatingDockInputGesture.numberOfTouchesRequired = 1;
    self.floatingDockInputGesture.minimumPressDuration = 0.0;
    self.floatingDockInputGesture.allowableMovement = CGFLOAT_MAX;
    self.floatingDockInputGesture.enabled = NO;

    self.usesSystemGestureManager = [self registerGlobalCornerGesture];
    if (!self.usesSystemGestureManager) {
        [self.hotspotWindow.rootViewController.view
            addGestureRecognizer:self.cornerGuardGesture];
        [self.hotspotWindow.rootViewController.view addGestureRecognizer:self.cornerGesture];
        [self.floatingWindow.rootViewController.view
            addGestureRecognizer:self.floatingDockInputGesture];
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
    ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame = CGRectNull;

    self.floatingDimView = [[UIView alloc] initWithFrame:bounds];
    self.floatingDimView.backgroundColor =
        [UIColor colorWithWhite:0.0 alpha:0.12];
    [self.floatingWindow.rootViewController.view addSubview:self.floatingDimView];

    self.floatingDockShadowView = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingDockShadowView.backgroundColor =
        [UIColor colorWithWhite:0.0 alpha:0.01];
    self.floatingDockShadowView.userInteractionEnabled = NO;
    self.floatingDockShadowView.hidden = YES;
    self.floatingDockShadowView.alpha = 0.0;
    self.floatingDockShadowView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.floatingDockShadowView.layer.shadowOpacity = 0.18;
    self.floatingDockShadowView.layer.shadowRadius = 14.0;
    self.floatingDockShadowView.layer.shadowOffset = CGSizeMake(0.0, 3.0);
    [self.floatingWindow.rootViewController.view
        addSubview:self.floatingDockShadowView];

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

    self.floatingDockInteractionShield = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingDockInteractionShield.backgroundColor = [UIColor clearColor];
    self.floatingDockInteractionShield.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.floatingDockInteractionShield.hidden = YES;
    self.floatingDockInteractionShield.userInteractionEnabled = NO;
    [self.floatingContainer addSubview:self.floatingDockInteractionShield];

    self.floatingDockReadyIndicator =
        [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 30.0, 30.0)];
    self.floatingDockReadyIndicator.backgroundColor =
        [UIColor colorWithWhite:1.0 alpha:0.18];
    self.floatingDockReadyIndicator.layer.cornerRadius = 15.0;
    self.floatingDockReadyIndicator.layer.borderWidth = 0.8;
    self.floatingDockReadyIndicator.layer.borderColor =
        [UIColor colorWithWhite:1.0 alpha:0.20].CGColor;
    self.floatingDockReadyIndicator.userInteractionEnabled = NO;
    self.floatingDockReadyIndicator.hidden = YES;
    self.floatingDockReadyIndicator.alpha = 0.0;
    self.floatingDockReadyCheckLayer = [CAShapeLayer layer];
    self.floatingDockReadyCheckLayer.fillColor = [UIColor clearColor].CGColor;
    self.floatingDockReadyCheckLayer.strokeColor =
        [UIColor colorWithWhite:1.0 alpha:0.90].CGColor;
    self.floatingDockReadyCheckLayer.lineWidth = 2.6;
    self.floatingDockReadyCheckLayer.lineCap = kCALineCapRound;
    self.floatingDockReadyCheckLayer.lineJoin = kCALineJoinRound;
    UIBezierPath *readyCheckPath = [UIBezierPath bezierPath];
    [readyCheckPath moveToPoint:CGPointMake(7.5, 15.5)];
    [readyCheckPath addLineToPoint:CGPointMake(12.5, 20.0)];
    [readyCheckPath addLineToPoint:CGPointMake(22.5, 10.0)];
    self.floatingDockReadyCheckLayer.path = readyCheckPath.CGPath;
    self.floatingDockReadyCheckLayer.frame =
        self.floatingDockReadyIndicator.bounds;
    [self.floatingDockReadyIndicator.layer
        addSublayer:self.floatingDockReadyCheckLayer];
    [self.floatingWindow.rootViewController.view
        addSubview:self.floatingDockReadyIndicator];

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

    self.floatingResizeHandle = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingResizeHandle.backgroundColor = [UIColor clearColor];
    self.floatingResizeHandle.hidden = YES;
    self.floatingResizeHandle.alpha = 0.0;
    self.floatingResizeShapeLayer = [CAShapeLayer layer];
    self.floatingResizeShapeLayer.fillColor = [UIColor clearColor].CGColor;
    self.floatingResizeShapeLayer.strokeColor =
        [UIColor colorWithWhite:1.0 alpha:1.0].CGColor;
    self.floatingResizeShapeLayer.opacity = 0.72;
    self.floatingResizeShapeLayer.lineWidth = 3.2;
    self.floatingResizeShapeLayer.lineCap = kCALineCapRound;
    self.floatingResizeShapeLayer.lineJoin = kCALineJoinRound;
    [self.floatingResizeHandle.layer addSublayer:self.floatingResizeShapeLayer];
    [self.floatingWindow.rootViewController.view
        addSubview:self.floatingResizeHandle];

    self.floatingDockDragPress =
        [[UILongPressGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingDockDragPress:)];
    self.floatingDockDragPress.minimumPressDuration = 0.10;
    self.floatingDockDragPress.allowableMovement = CGFLOAT_MAX;
    self.floatingDockDragPress.cancelsTouchesInView = YES;
    self.floatingDockDragPress.enabled = NO;
    [self.floatingDockInteractionShield
        addGestureRecognizer:self.floatingDockDragPress];

    self.floatingDockTap =
        [[UITapGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingDockTap:)];
    self.floatingDockTap.cancelsTouchesInView = YES;
    self.floatingDockTap.enabled = NO;
    [self.floatingDockTap
        requireGestureRecognizerToFail:self.floatingDockDragPress];
    [self.floatingDockInteractionShield addGestureRecognizer:self.floatingDockTap];

    self.floatingResizePress =
        [[UILongPressGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingResizePress:)];
    self.floatingResizePress.minimumPressDuration = 0.12;
    self.floatingResizePress.allowableMovement = CGFLOAT_MAX;
    self.floatingResizePress.cancelsTouchesInView = YES;
    [self.floatingResizeHandle addGestureRecognizer:self.floatingResizePress];
    self.floatingResizeHandle.userInteractionEnabled = YES;

    FLMFloatingWindow *floatingWindow =
        (FLMFloatingWindow *)self.floatingWindow;
    floatingWindow.floatingContentView = self.floatingContainer;
    floatingWindow.floatingPrimaryControlView = self.floatingHandle;
    floatingWindow.floatingSecondaryControlView = self.floatingResizeHandle;
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
    [manager addGestureRecognizer:self.floatingDockInputGesture
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self updateWindowFrames];
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
    if (self.keyboardOverlayWindow) {
        self.keyboardOverlayWindow.frame = bounds;
        self.keyboardOverlayWindow.rootViewController.view.frame = bounds;
        if (self.floatingKeyboardLayerHostView) {
            self.floatingKeyboardLayerHostView.frame =
                self.keyboardOverlayWindow.rootViewController.view.bounds;
        }
    }
    [self layoutFloatingWindow];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.floatingDockInputGesture) {
        return self.floatingDocked && !self.floatingWindow.hidden &&
               !FLMDeviceIsLocked();
    }
    if (gestureRecognizer == self.floatingDockTap ||
        gestureRecognizer == self.floatingDockDragPress ||
        gestureRecognizer == self.floatingResizePress) {
        return self.floatingDocked && !self.floatingWindow.hidden;
    }
    if (gestureRecognizer == self.floatingBackdropTap) {
        return !self.floatingWindow.hidden && !self.floatingDocked;
    }
    if (gestureRecognizer == self.floatingExclusiveGesture) {
        return !self.floatingWindow.hidden && !self.floatingDocked &&
               !FLMDeviceIsLocked();
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
    if (gestureRecognizer == self.floatingDockInputGesture) {
        if (!self.floatingDocked || self.floatingWindow.hidden ||
            FLMDeviceIsLocked()) {
            return NO;
        }
        CGPoint rawPoint = [touch locationInView:nil];
        CGPoint point = FLMVisualPointFromRawPoint(rawPoint);
        return [self floatingResizeControlContainsPoint:point] ||
               CGRectContainsPoint(self.floatingContainer.frame, point);
    }
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
        CGPoint rawPoint = [touch locationInView:nil];
        CGPoint point = FLMVisualPointFromRawPoint(rawPoint);
        return ![self pointIsInsideFloatingInteractionDomain:point];
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
    NSString *selectedIdentifier = [item.identifier copy];
    BOOL selectedIsCurrentFloating =
        !self.floatingWindow.hidden && self.floatingIdentifier.length > 0 &&
        [selectedIdentifier isEqualToString:self.floatingIdentifier];
    BOOL selectedIsFrontmost =
        selectedIdentifier.length > 0 &&
        [selectedIdentifier isEqualToString:FLMFrontmostApplicationIdentifier()];
    if (selectedIdentifier.length > 0 && !selectedIsCurrentFloating &&
        !selectedIsFrontmost &&
        ![selectedIdentifier isEqualToString:FLYME_LOCK_SCREEN_ITEM] &&
        FLMPrewarmApplicationIdentifier(selectedIdentifier)) {
        // Start the suspended scene while the wheel is completing its existing
        // dismissal animation. This gives scene creation a 240 ms head start.
        self.prewarmedIdentifier = selectedIdentifier;
    } else {
        self.prewarmedIdentifier = nil;
    }
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
    if (self.floatingWindow.hidden || self.floatingDocked) {
        self.floatingExclusiveTapEligible = NO;
        return;
    }

    CGPoint rawPoint = [gesture locationInView:nil];
    CGPoint point = FLMVisualPointFromRawPoint(rawPoint);
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            self.floatingExclusiveStartPoint = point;
            self.floatingExclusiveStartTimestamp = CACurrentMediaTime();
            self.floatingExclusiveTapEligible =
                ![self pointIsInsideFloatingInteractionDomain:point];
            break;
        case UIGestureRecognizerStateChanged:
            if (self.floatingExclusiveTapEligible &&
                hypot(point.x - self.floatingExclusiveStartPoint.x,
                      point.y - self.floatingExclusiveStartPoint.y) > 12.0) {
                self.floatingExclusiveTapEligible = NO;
            }
            break;
        case UIGestureRecognizerStateEnded: {
            BOOL shouldClose =
                self.floatingExclusiveTapEligible &&
                CACurrentMediaTime() - self.floatingExclusiveStartTimestamp <= 0.35 &&
                hypot(point.x - self.floatingExclusiveStartPoint.x,
                      point.y - self.floatingExclusiveStartPoint.y) <= 12.0;
            self.floatingExclusiveTapEligible = NO;
            if (shouldClose && !self.floatingWindow.hidden && !self.floatingDocked) {
                [self closeFloatingWindowKeepingApplication:YES];
            }
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            self.floatingExclusiveTapEligible = NO;
            break;
        default:
            break;
    }
}

- (void)activateFloatingDockDragForGeneration:(NSUInteger)generation {
    if (generation != self.floatingDockInputGeneration ||
        !self.floatingDocked || self.floatingWindow.hidden ||
        self.floatingDockInputTargetsResize ||
        (self.floatingDockInputGesture.state != UIGestureRecognizerStateBegan &&
         self.floatingDockInputGesture.state != UIGestureRecognizerStateChanged)) {
        return;
    }
    self.floatingDockGlobalDragActivated = YES;
    UIView *rootView = self.floatingWindow.rootViewController.view;
    [rootView bringSubviewToFront:self.floatingContainer];
    [rootView bringSubviewToFront:self.floatingResizeHandle];
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback =
            [[UIImpactFeedbackGenerator alloc]
                initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
    }
}

- (void)handleFloatingDockInputGesture:(FLMCornerGestureRecognizer *)gesture {
    if (!self.floatingDocked || self.floatingWindow.hidden) {
        return;
    }
    CGPoint rawPoint = [gesture locationInView:nil];
    CGPoint point = FLMVisualPointFromRawPoint(rawPoint);
    self.floatingDockInputLatestPoint = point;
    UIView *rootView = self.floatingWindow.rootViewController.view;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.floatingDockInputGeneration += 1;
        NSUInteger generation = self.floatingDockInputGeneration;
        self.floatingDockInputTargetsResize =
            [self floatingResizeControlContainsPoint:point];
        self.floatingDockGlobalDragActivated = NO;
        if (self.floatingDockInputTargetsResize) {
            self.floatingResizeStartPoint = point;
            self.floatingResizeInitialFrame = self.floatingContainer.frame;
            self.floatingResizeCenterReady = NO;
            if (@available(iOS 10.0, *)) {
                UIImpactFeedbackGenerator *feedback =
                    [[UIImpactFeedbackGenerator alloc]
                        initWithStyle:UIImpactFeedbackStyleMedium];
                [feedback impactOccurred];
            }
            [UIView animateWithDuration:0.14
                             animations:^{
                                 self.floatingResizeHandle.transform =
                                     CGAffineTransformMakeScale(1.16, 1.16);
                                 self.floatingResizeShapeLayer.opacity = 1.0;
                             }];
            return;
        }

        self.floatingDockDragStartPoint = point;
        self.floatingDockDragInitialCenter = self.floatingContainer.center;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.10 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self activateFloatingDockDragForGeneration:generation];
        });
        return;
    }

    if (gesture.state == UIGestureRecognizerStateChanged) {
        if (self.floatingDockInputTargetsResize) {
            CGFloat horizontalOutward =
                self.floatingDockedOnRight
                    ? self.floatingResizeStartPoint.x - point.x
                    : point.x - self.floatingResizeStartPoint.x;
            CGFloat verticalOutward = point.y - self.floatingResizeStartPoint.y;
            CGFloat delta = (horizontalOutward + verticalOutward) * 0.5;
            CGFloat requestedWidth =
                CGRectGetWidth(self.floatingResizeInitialFrame) + delta;
            CGFloat width = requestedWidth;
            if (requestedWidth > FLMMaximumDockWidth) {
                width =
                    FLMMaximumDockWidth +
                    MIN(16.0,
                        (requestedWidth - FLMMaximumDockWidth) * 0.60);
            }
            width = MAX(FLMMinimumDockWidth, width);
            if (!self.floatingResizeCenterReady && requestedWidth >= 286.0) {
                self.floatingResizeCenterReady = YES;
                if (@available(iOS 10.0, *)) {
                    UIImpactFeedbackGenerator *feedback =
                        [[UIImpactFeedbackGenerator alloc]
                            initWithStyle:UIImpactFeedbackStyleMedium];
                    [feedback impactOccurred];
                }
            } else if (self.floatingResizeCenterReady &&
                       requestedWidth <= 278.0) {
                self.floatingResizeCenterReady = NO;
            }
            CGRect centeredFrame = [self centeredFloatingFrame];
            CGFloat aspectRatio =
                CGRectGetWidth(centeredFrame) /
                MAX(1.0, CGRectGetHeight(centeredFrame));
            CGFloat height = width / MAX(0.1, aspectRatio);
            CGFloat top = CGRectGetMinY(self.floatingResizeInitialFrame);
            CGFloat anchorX =
                self.floatingDockedOnRight
                    ? CGRectGetMaxX(self.floatingResizeInitialFrame)
                    : CGRectGetMinX(self.floatingResizeInitialFrame);
            CGRect visualFrame =
                CGRectMake(self.floatingDockedOnRight ? anchorX - width
                                                      : anchorX,
                           top,
                           width,
                           height);
            CGFloat scale =
                width / MAX(1.0, CGRectGetWidth(self.floatingResizeInitialFrame));
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [UIView performWithoutAnimation:^{
                self.floatingContainer.center =
                    CGPointMake(CGRectGetMidX(visualFrame),
                                CGRectGetMidY(visualFrame));
                self.floatingContainer.transform =
                    CGAffineTransformMakeScale(scale, scale);
                self.floatingDockWidth = width;
                [self updateFloatingDockAccessoryPositions];
            }];
            [CATransaction commit];
            return;
        }

        CGFloat movement =
            hypot(point.x - self.floatingDockDragStartPoint.x,
                  point.y - self.floatingDockDragStartPoint.y);
        if (!self.floatingDockGlobalDragActivated && movement >= 5.0) {
            [self activateFloatingDockDragForGeneration:
                      self.floatingDockInputGeneration];
        }
        if (self.floatingDockGlobalDragActivated) {
            CGPoint delta =
                CGPointMake(point.x - self.floatingDockDragStartPoint.x,
                            point.y - self.floatingDockDragStartPoint.y);
            CGRect bounds = rootView.bounds;
            UIEdgeInsets safeInsets = rootView.safeAreaInsets;
            CGFloat halfWidth =
                CGRectGetWidth(self.floatingContainer.bounds) * 0.5;
            CGFloat halfHeight =
                CGRectGetHeight(self.floatingContainer.bounds) * 0.5;
            CGPoint center =
                CGPointMake(self.floatingDockDragInitialCenter.x + delta.x,
                            self.floatingDockDragInitialCenter.y + delta.y);
            center.x = MAX(halfWidth,
                           MIN(CGRectGetWidth(bounds) - halfWidth, center.x));
            center.y =
                MAX(safeInsets.top + halfHeight,
                    MIN(CGRectGetHeight(bounds) - safeInsets.bottom - halfHeight,
                        center.y));
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [UIView performWithoutAnimation:^{
                self.floatingContainer.center = center;
                [self updateFloatingDockAccessoryPositions];
            }];
            [CATransaction commit];
        }
        return;
    }

    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        self.floatingDockInputGeneration += 1;
        if (self.floatingDockInputTargetsResize) {
            [self normalizeFloatingContainerTransform];
            BOOL restoreCentered =
                gesture.state == UIGestureRecognizerStateEnded &&
                self.floatingResizeCenterReady;
            self.floatingResizeCenterReady = NO;
            if (restoreCentered) {
                self.floatingDockInputTargetsResize = NO;
                self.floatingResizeHandle.transform =
                    CGAffineTransformIdentity;
                self.floatingResizeShapeLayer.opacity = 0.72;
                [self transitionFloatingWindowToCentered];
                return;
            }
            self.floatingDockWidth =
                MAX(FLMMinimumDockWidth,
                    MIN(FLMMaximumDockWidth, self.floatingDockWidth));
            [self saveFloatingDockWidth];
            CGRect target =
                [self dockedFloatingFrameOnRight:self.floatingDockedOnRight
                                           width:self.floatingDockWidth];
            [UIView animateWithDuration:0.18
                                  delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState |
                                        UIViewAnimationOptionCurveEaseOut |
                                        UIViewAnimationOptionAllowUserInteraction
                             animations:^{
                                 self.floatingContainer.frame = target;
                                 self.floatingResizeHandle.transform =
                                     CGAffineTransformIdentity;
                                 self.floatingResizeShapeLayer.opacity = 0.72;
                                 [self layoutFloatingHostView];
                                 [self layoutFloatingDockShadow];
                                 [self layoutFloatingResizeHandle];
                             }
                             completion:nil];
            self.floatingDockInputTargetsResize = NO;
            return;
        }

        if (self.floatingDockGlobalDragActivated) {
            self.floatingDockGlobalDragActivated = NO;
            [self snapDockedFloatingWindowUsingTouchPoint:point];
            return;
        }
        CGFloat movement =
            hypot(point.x - self.floatingDockDragStartPoint.x,
                  point.y - self.floatingDockDragStartPoint.y);
        if (gesture.state == UIGestureRecognizerStateEnded && movement < 5.0) {
            if (@available(iOS 10.0, *)) {
                UIImpactFeedbackGenerator *feedback =
                    [[UIImpactFeedbackGenerator alloc]
                        initWithStyle:UIImpactFeedbackStyleLight];
                [feedback impactOccurred];
            }
            [self transitionFloatingWindowToCentered];
        }
    }
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

- (void)handleFloatingDockTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded ||
        !self.floatingDocked || self.floatingWindow.hidden) {
        return;
    }
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
    }
    [self transitionFloatingWindowToCentered];
}

- (void)handleFloatingDockDragPress:(UILongPressGestureRecognizer *)gesture {
    if (!self.floatingDocked || self.floatingWindow.hidden) {
        return;
    }
    UIView *rootView = self.floatingWindow.rootViewController.view;
    CGPoint point = [gesture locationInView:rootView];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.floatingDockDragStartPoint = point;
        self.floatingDockDragInitialCenter = self.floatingContainer.center;
        [rootView bringSubviewToFront:self.floatingContainer];
        [rootView bringSubviewToFront:self.floatingResizeHandle];
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *feedback =
                [[UIImpactFeedbackGenerator alloc]
                    initWithStyle:UIImpactFeedbackStyleMedium];
            [feedback impactOccurred];
        }
        return;
    }

    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint delta =
            CGPointMake(point.x - self.floatingDockDragStartPoint.x,
                        point.y - self.floatingDockDragStartPoint.y);
        CGRect bounds = rootView.bounds;
        UIEdgeInsets safeInsets = rootView.safeAreaInsets;
        CGFloat halfWidth = CGRectGetWidth(self.floatingContainer.bounds) * 0.5;
        CGFloat halfHeight = CGRectGetHeight(self.floatingContainer.bounds) * 0.5;
        CGPoint center =
            CGPointMake(self.floatingDockDragInitialCenter.x + delta.x,
                        self.floatingDockDragInitialCenter.y + delta.y);
        center.x = MAX(halfWidth,
                       MIN(CGRectGetWidth(bounds) - halfWidth, center.x));
        center.y = MAX(safeInsets.top + halfHeight,
                       MIN(CGRectGetHeight(bounds) - safeInsets.bottom - halfHeight,
                           center.y));
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [UIView performWithoutAnimation:^{
            self.floatingContainer.center = center;
            [self updateFloatingDockAccessoryPositions];
        }];
        [CATransaction commit];
        return;
    }

    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        [self snapDockedFloatingWindowUsingTouchPoint:point];
    }
}

- (void)handleFloatingResizePress:(UILongPressGestureRecognizer *)gesture {
    if (!self.floatingDocked || self.floatingWindow.hidden) {
        return;
    }
    UIView *rootView = self.floatingWindow.rootViewController.view;
    CGPoint point = [gesture locationInView:rootView];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.floatingResizeStartPoint = point;
        self.floatingResizeInitialFrame = self.floatingContainer.frame;
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *feedback =
                [[UIImpactFeedbackGenerator alloc]
                    initWithStyle:UIImpactFeedbackStyleMedium];
            [feedback impactOccurred];
        }
        [UIView animateWithDuration:0.14
                         animations:^{
                             self.floatingResizeHandle.transform =
                                 CGAffineTransformMakeScale(1.16, 1.16);
                             self.floatingResizeShapeLayer.opacity = 1.0;
                         }];
        return;
    }

    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGFloat horizontalOutward =
            self.floatingDockedOnRight
                ? self.floatingResizeStartPoint.x - point.x
                : point.x - self.floatingResizeStartPoint.x;
        CGFloat verticalOutward = point.y - self.floatingResizeStartPoint.y;
        CGFloat delta = (horizontalOutward + verticalOutward) * 0.5;
        CGFloat width =
            MAX(FLMMinimumDockWidth,
                MIN(FLMMaximumDockWidth,
                    CGRectGetWidth(self.floatingResizeInitialFrame) + delta));
        CGRect centeredFrame = [self centeredFloatingFrame];
        CGFloat aspectRatio =
            CGRectGetWidth(centeredFrame) / MAX(1.0, CGRectGetHeight(centeredFrame));
        CGFloat height = width / MAX(0.1, aspectRatio);
        CGFloat top = CGRectGetMinY(self.floatingResizeInitialFrame);
        CGFloat anchorX =
            self.floatingDockedOnRight
                ? CGRectGetMaxX(self.floatingResizeInitialFrame)
                : CGRectGetMinX(self.floatingResizeInitialFrame);
        CGRect visualFrame =
            CGRectMake(self.floatingDockedOnRight ? anchorX - width : anchorX,
                       top,
                       width,
                       height);
        CGFloat scale =
            width / MAX(1.0, CGRectGetWidth(self.floatingResizeInitialFrame));
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [UIView performWithoutAnimation:^{
            self.floatingContainer.center =
                CGPointMake(CGRectGetMidX(visualFrame), CGRectGetMidY(visualFrame));
            self.floatingContainer.transform =
                CGAffineTransformMakeScale(scale, scale);
            self.floatingDockWidth = width;
            [self updateFloatingDockAccessoryPositions];
        }];
        [CATransaction commit];
        return;
    }

    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        [self normalizeFloatingContainerTransform];
        [self saveFloatingDockWidth];
        [UIView animateWithDuration:0.28
                              delay:0.0
             usingSpringWithDamping:0.72
              initialSpringVelocity:0.35
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
                             self.floatingResizeHandle.transform =
                                 CGAffineTransformIdentity;
                             self.floatingResizeShapeLayer.opacity = 0.72;
                         }
                         completion:nil];
    }
}

- (void)setFloatingApplicationInputBlocked:(BOOL)blocked {
    if (self.floatingDocked) {
        return;
    }
    self.floatingHostView.userInteractionEnabled = !blocked;
    self.floatingDockInteractionShield.frame = self.floatingContainer.bounds;
    self.floatingDockInteractionShield.hidden = !blocked;
    self.floatingDockInteractionShield.userInteractionEnabled = blocked;
    if (blocked) {
        [self.floatingContainer
            bringSubviewToFront:self.floatingDockInteractionShield];
    }
}

- (void)updateFloatingFullscreenSnapshotForProgress:(CGFloat)progress {
    UIView *wrapper = self.floatingInteractiveSnapshot;
    UIView *background = self.floatingInteractiveSnapshotBackground;
    UIView *content = self.floatingInteractiveSnapshotContent;
    if (!wrapper || !content) {
        return;
    }
    progress = MIN(1.0, MAX(0.0, progress));
    CGRect start = self.floatingHandleInitialContainerFrame;
    CGRect bounds = self.floatingWindow.rootViewController.view.bounds;
    if (CGRectGetWidth(start) < 1.0 || CGRectGetHeight(start) < 1.0) {
        return;
    }
    self.floatingFullscreenProgress = progress;

    // Width growth and vertical reveal deliberately overlap. The application
    // snapshot remains uniformly scaled while the enclosing mask opens toward
    // the physical display, avoiding a visible width-stage/height-stage seam.
    const CGFloat widthCompletion = 0.82;
    CGFloat widthProgress = MIN(1.0, progress / widthCompletion);
    widthProgress = widthProgress * widthProgress *
                    (3.0 - 2.0 * widthProgress);
    const CGFloat verticalRevealStart = 0.22;
    CGFloat verticalProgress =
        progress <= verticalRevealStart
            ? 0.0
            : (progress - verticalRevealStart) /
                  (1.0 - verticalRevealStart);
    verticalProgress = MIN(1.0, MAX(0.0, verticalProgress));
    verticalProgress = verticalProgress * verticalProgress *
                       (3.0 - 2.0 * verticalProgress);
    CGFloat targetScale = CGRectGetWidth(bounds) / CGRectGetWidth(start);
    CGFloat uniformScale = 1.0 + (targetScale - 1.0) * widthProgress;
    CGSize uniformSize = CGSizeMake(CGRectGetWidth(start) * uniformScale,
                                    CGRectGetHeight(start) * uniformScale);
    CGPoint startCenter = CGPointMake(CGRectGetMidX(start), CGRectGetMidY(start));
    CGPoint screenCenter = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    CGPoint center = CGPointMake(
        startCenter.x + (screenCenter.x - startCenter.x) * widthProgress,
        startCenter.y + (screenCenter.y - startCenter.y) * widthProgress);
    CGRect uniformFrame = CGRectMake(center.x - uniformSize.width * 0.5,
                                     center.y - uniformSize.height * 0.5,
                                     uniformSize.width,
                                     uniformSize.height);
    CGRect frame = CGRectMake(
        CGRectGetMinX(uniformFrame),
        CGRectGetMinY(uniformFrame) +
            (CGRectGetMinY(bounds) - CGRectGetMinY(uniformFrame)) *
                verticalProgress,
        CGRectGetWidth(uniformFrame),
        CGRectGetHeight(uniformFrame) +
            (CGRectGetHeight(bounds) - CGRectGetHeight(uniformFrame)) *
                verticalProgress);
    wrapper.transform = CGAffineTransformIdentity;
    wrapper.frame = frame;
    wrapper.layer.cornerRadius = 18.0 * (1.0 - progress);

    CGFloat fitScale = CGRectGetWidth(frame) / CGRectGetWidth(start);
    CGFloat fillScale = MAX(fitScale,
                            CGRectGetHeight(frame) / CGRectGetHeight(start));
    CGPoint localCenter =
        CGPointMake(CGRectGetMidX(wrapper.bounds), CGRectGetMidY(wrapper.bounds));
    content.center = localCenter;
    content.transform = CGAffineTransformMakeScale(fitScale, fitScale);
    if (background) {
        background.center = localCenter;
        background.transform =
            CGAffineTransformMakeScale(fillScale, fillScale);
    }
    // The proportional foreground never disappears. An opaque aspect-fill copy
    // exists only behind newly revealed vertical pixels; since that region has
    // zero area at the reveal boundary, enabling it cannot flash or expose the
    // wrapper's former black corners.
    content.alpha = 1.0;
    background.alpha = verticalProgress > 0.0001 ? 1.0 : 0.0;

    // The real container remains hidden but tracks exactly the same bounded
    // geometry, which keeps the handle and final handoff spatially continuous.
    self.floatingContainer.transform = CGAffineTransformIdentity;
    self.floatingContainer.frame = frame;
}

- (void)prepareFloatingSceneForInteractiveFullscreen {
    if (self.floatingInteractiveScenePrepared) {
        return;
    }
    self.floatingInteractiveScenePrepared = YES;
    self.floatingInteractiveFullscreenTransition = YES;
    self.floatingFullscreenProgress = 0.0;

    UIView *content =
        [self.floatingContainer snapshotViewAfterScreenUpdates:NO];
    if (!content) {
        content = [[UIView alloc] initWithFrame:self.floatingContainer.bounds];
        content.backgroundColor = [UIColor blackColor];
    }
    UIView *background =
        [self.floatingContainer snapshotViewAfterScreenUpdates:NO];
    CGRect start = self.floatingHandleInitialContainerFrame;
    UIView *wrapper = [[UIView alloc] initWithFrame:start];
    wrapper.backgroundColor = [UIColor clearColor];
    wrapper.autoresizingMask = UIViewAutoresizingNone;
    wrapper.userInteractionEnabled = NO;
    wrapper.clipsToBounds = YES;
    wrapper.layer.cornerRadius = 18.0;
    CGRect sourceBounds = CGRectMake(0.0,
                                     0.0,
                                     CGRectGetWidth(start),
                                     CGRectGetHeight(start));
    if (background) {
        background.bounds = sourceBounds;
        background.center = CGPointMake(CGRectGetMidX(wrapper.bounds),
                                        CGRectGetMidY(wrapper.bounds));
        background.autoresizingMask = UIViewAutoresizingNone;
        background.userInteractionEnabled = NO;
        background.alpha = 0.0;
        [wrapper addSubview:background];
    }
    content.bounds = sourceBounds;
    content.center = CGPointMake(CGRectGetMidX(wrapper.bounds),
                                 CGRectGetMidY(wrapper.bounds));
    content.autoresizingMask = UIViewAutoresizingNone;
    content.userInteractionEnabled = NO;
    [wrapper addSubview:content];
    [self.floatingWindow.rootViewController.view addSubview:wrapper];
    [self.floatingWindow.rootViewController.view
        bringSubviewToFront:self.floatingHandle];
    self.floatingInteractiveSnapshot = wrapper;
    self.floatingInteractiveSnapshotBackground = background;
    self.floatingInteractiveSnapshotContent = content;
    self.floatingContainer.alpha = 0.0;
    [self updateFloatingFullscreenSnapshotForProgress:0.0];
}

- (void)restoreFloatingSceneAfterCancelledTransition {
    if (!self.floatingInteractiveScenePrepared &&
        !self.floatingInteractiveSnapshot) {
        return;
    }
    [self.floatingInteractiveSnapshot removeFromSuperview];
    self.floatingInteractiveSnapshot = nil;
    self.floatingInteractiveSnapshotBackground = nil;
    self.floatingInteractiveSnapshotContent = nil;
    self.floatingInteractiveScenePrepared = NO;
    self.floatingInteractiveFullscreenTransition = NO;
    self.floatingFullscreenProgress = 0.0;
    self.floatingContainer.alpha = 1.0;
    self.floatingContainer.transform = CGAffineTransformIdentity;
    if (!CGRectIsEmpty(self.floatingHandleInitialContainerFrame)) {
        self.floatingContainer.frame = self.floatingHandleInitialContainerFrame;
    }
    [self layoutFloatingHostView];
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
        // A centered card always starts a new dock gesture at the fixed
        // minimum size. Resizing a prior dock is intentionally not remembered.
        self.floatingDockWidth = FLMMinimumDockWidth;
        self.floatingHandleStartPoint = point;
        self.floatingHandleInitialContainerFrame = self.floatingContainer.frame;
        self.floatingHandleMoved = NO;
        self.floatingDockTransitionActive = NO;
        self.floatingInteractiveScenePrepared = NO;
        [self setFloatingApplicationInputBlocked:NO];
        [self setFloatingDockReady:NO animated:NO];
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
        if (landscape) {
            BOOL directionIsPrimary =
                fabs(primaryMovement) >= fabs(crossMovement) * 0.55;
            if (directionIsPrimary && primaryMovement >= 3.0) {
                self.floatingHandleMoved = YES;
                self.floatingDockTransitionActive = NO;
                if (!self.floatingInteractiveScenePrepared) {
                    [self prepareFloatingSceneForInteractiveFullscreen];
                }
                CGFloat available =
                    MAX(1.0,
                        CGRectGetWidth(bounds) -
                            CGRectGetMaxX(self.floatingHandleInitialContainerFrame));
                CGFloat progress =
                    MIN(1.0, MAX(0.0, primaryMovement / available));
                [self updateFloatingFullscreenSnapshotForProgress:progress];
                self.floatingDimView.alpha = 1.0 - progress;
                self.floatingHandle.alpha =
                    1.0 - MAX(0.0, (progress - 0.88) / 0.12);
                [self layoutFloatingHandleForCurrentContainer];
            } else {
                CGFloat resistance =
                    MAX(-14.0, MIN(0.0, primaryMovement * 0.18));
                self.floatingHandleBar.transform =
                    CGAffineTransformMakeTranslation(resistance, 0.0);
            }
            return;
        }

        if (primaryMovement <= -3.0) {
            if (self.floatingInteractiveScenePrepared) {
                [self restoreFloatingSceneAfterCancelledTransition];
            }
            [self setFloatingApplicationInputBlocked:YES];
            self.floatingHandleMoved = YES;
            self.floatingDockTransitionActive = YES;
            CGRect start = self.floatingHandleInitialContainerFrame;
            CGRect dockTarget =
                [self dockedFloatingFrameOnRight:YES width:self.floatingDockWidth];
            CGFloat available = FLMCenteredDockActivationDistance;
            CGFloat progress =
                MIN(1.0, MAX(0.0, -primaryMovement / available));
            CGFloat width =
                CGRectGetWidth(start) +
                (CGRectGetWidth(dockTarget) - CGRectGetWidth(start)) * progress;
            CGFloat scale = width / MAX(1.0, CGRectGetWidth(start));
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [UIView performWithoutAnimation:^{
                self.floatingContainer.center =
                    CGPointMake(CGRectGetMidX(start), CGRectGetMidY(start));
                self.floatingContainer.transform =
                    CGAffineTransformMakeScale(scale, scale);
                self.floatingDockShadowView.center = self.floatingContainer.center;
                self.floatingDockShadowView.transform =
                    self.floatingContainer.transform;
            }];
            [CATransaction commit];
            CGFloat visualCornerRadius =
                18.0 + (16.0 - 18.0) * progress;
            self.floatingContainer.layer.cornerRadius =
                visualCornerRadius / MAX(0.01, scale);
            self.floatingDimView.alpha = 1.0 - progress;
            self.floatingDockShadowView.hidden = NO;
            self.floatingDockShadowView.alpha = progress;
            self.floatingHandle.alpha = 1.0;
            [self layoutFloatingHandleForCurrentContainer];
            [self layoutFloatingDockReadyIndicator];
            if (!self.floatingDockReady && progress >= 1.0) {
                if (@available(iOS 10.0, *)) {
                    UIImpactFeedbackGenerator *feedback =
                        [[UIImpactFeedbackGenerator alloc]
                            initWithStyle:UIImpactFeedbackStyleMedium];
                    [feedback impactOccurred];
                }
                [self setFloatingDockReady:YES animated:YES];
            } else if (self.floatingDockReady && progress <= 0.90) {
                [self setFloatingDockReady:NO animated:YES];
            }
        } else if (primaryMovement >= 3.0) {
            [self setFloatingDockReady:NO animated:YES];
            [self setFloatingApplicationInputBlocked:NO];
            self.floatingHandleMoved = YES;
            self.floatingDockTransitionActive = NO;
            self.floatingDockShadowView.alpha = 0.0;
            self.floatingDockShadowView.hidden = YES;
            if (!self.floatingInteractiveScenePrepared) {
                [self prepareFloatingSceneForInteractiveFullscreen];
            }
            CGFloat available =
                MAX(1.0,
                    CGRectGetHeight(bounds) -
                        CGRectGetMaxY(self.floatingHandleInitialContainerFrame));
            CGFloat progress = MIN(1.0, MAX(0.0, primaryMovement / available));
            [self updateFloatingFullscreenSnapshotForProgress:progress];
            self.floatingDimView.alpha = 1.0 - progress;
            self.floatingHandle.alpha =
                1.0 - MAX(0.0, (progress - 0.88) / 0.12);
            [self layoutFloatingHandleForCurrentContainer];
        } else {
            [self setFloatingDockReady:NO animated:YES];
            [self setFloatingApplicationInputBlocked:NO];
            if (self.floatingInteractiveScenePrepared) {
                [self restoreFloatingSceneAfterCancelledTransition];
            }
            self.floatingDockTransitionActive = NO;
            self.floatingContainer.transform = CGAffineTransformIdentity;
            self.floatingContainer.frame =
                self.floatingHandleInitialContainerFrame;
            self.floatingDockShadowView.transform = CGAffineTransformIdentity;
            self.floatingContainer.layer.cornerRadius = 18.0;
            self.floatingDimView.alpha = 1.0;
            self.floatingDockShadowView.alpha = 0.0;
            self.floatingDockShadowView.hidden = YES;
            self.floatingHandle.alpha = 1.0;
            [self layoutFloatingHostView];
            [self layoutFloatingHandleForCurrentContainer];
        }
        return;
    }

    if (!landscape && gesture.state == UIGestureRecognizerStateEnded &&
        self.floatingDockReady && primaryMovement < 0.0) {
        [self setFloatingDockReady:NO animated:YES];
        [self transitionFloatingWindowToDocked];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded &&
        self.floatingHandleMoved && !self.floatingDockTransitionActive &&
        primaryMovement > 0.0 &&
        (landscape ||
         point.y >= CGRectGetHeight(bounds) - 80.0)) {
        [self setFloatingDockReady:NO animated:NO];
        [self transitionFloatingWindowToFullscreen];
        return;
    }
    [self setFloatingDockReady:NO animated:YES];
    [self resetFloatingInteractiveLayoutAnimated:YES];
}

- (void)resetFloatingInteractiveLayoutAnimated:(BOOL)animated {
    [self setFloatingDockReady:NO animated:animated];
    [self restoreFloatingSceneAfterCancelledTransition];
    [self setFloatingApplicationInputBlocked:NO];
    [self normalizeFloatingContainerTransform];
    void (^changes)(void) = ^{
        self.floatingContainer.alpha = 1.0;
        self.floatingContainer.layer.cornerRadius = 18.0;
        self.floatingDimView.alpha = 1.0;
        self.floatingHandle.alpha = 1.0;
        self.floatingHandleBar.alpha = 1.0;
        self.floatingHandleBar.transform = CGAffineTransformIdentity;
        self.floatingDockShadowView.alpha = 0.0;
        [self layoutFloatingWindow];
    };
    if (!animated) {
        changes();
        self.floatingDockTransitionActive = NO;
        if (!self.floatingDocked) {
            self.floatingDockShadowView.hidden = YES;
        }
        return;
    }
    [UIView animateWithDuration:0.34
                          delay:0.0
         usingSpringWithDamping:0.78
          initialSpringVelocity:0.25
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:changes
                     completion:^(BOOL finished) {
                         (void)finished;
                         self.floatingDockTransitionActive = NO;
                         if (!self.floatingDocked) {
                             self.floatingDockShadowView.hidden = YES;
                         }
                     }];
}

- (void)transitionFloatingWindowToFullscreen {
    [self setFloatingDockReady:NO animated:NO];
    if (self.floatingWindow.hidden || self.floatingIdentifier.length == 0) {
        [self resetFloatingInteractiveLayoutAnimated:YES];
        return;
    }
    UIView *rootView = self.floatingWindow.rootViewController.view;
    [self.floatingHostView endEditing:YES];
    [self detachFloatingKeyboardLayerHost];
    [self clearFloatingReusableKeyboardHost];
    FLMPublishKeyboardState(nil, nil);
    CGRect targetFrame = rootView.bounds;
    if (!self.floatingInteractiveScenePrepared) {
        self.floatingHandleInitialContainerFrame = self.floatingContainer.frame;
        [self prepareFloatingSceneForInteractiveFullscreen];
    }
    NSString *identifier = [self.floatingIdentifier copy];
    self.floatingReconnectSuppressed = YES;
    // Start the already-running scene promotion while the final part of the
    // same card morph is still on screen. The old implementation waited until
    // that animation ended, producing a visible motion/pause/activation split.
    [self activateIdentifierFullscreen:identifier];
    CGFloat remainingProgress =
        MAX(0.0, 1.0 - self.floatingFullscreenProgress);
    NSTimeInterval finishDuration = 0.18 + 0.28 * remainingProgress;
    [UIView animateWithDuration:finishDuration
                           delay:0.0
                         options:UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionAllowUserInteraction
                      animations:^{
                         [self updateFloatingFullscreenSnapshotForProgress:1.0];
                         self.floatingContainer.layer.cornerRadius = 0.0;
                         self.floatingDimView.alpha = 0.0;
                         self.floatingHandle.alpha = 0.0;
                         [self layoutFloatingHandleForCurrentContainer];
                     }
                      completion:^(BOOL finished) {
                          (void)finished;
                          UIView *snapshot = self.floatingInteractiveSnapshot;
                         self.floatingInteractiveSnapshot = nil;
                         self.floatingInteractiveSnapshotBackground = nil;
                         self.floatingInteractiveSnapshotContent = nil;
                         if (!snapshot) {
                             snapshot = [[UIView alloc] initWithFrame:targetFrame];
                             snapshot.backgroundColor = [UIColor blackColor];
                             [rootView addSubview:snapshot];
                         } else {
                             snapshot.layer.cornerRadius = 0.0;
                             [rootView addSubview:snapshot];
                         }

                          self.floatingInteractiveScenePrepared = NO;
                          self.floatingInteractiveFullscreenTransition = NO;
                          self.floatingFullscreenProgress = 1.0;
                         self.floatingLaunchGeneration += 1;
                         self.floatingExclusiveGesture.enabled = NO;
                         self.cornerGuardGesture.enabled = self.enabled;
                         self.cornerGesture.enabled = self.enabled;
                         self.floatingContainer.alpha = 0.0;
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
    BOOL displayCommitted = targetIsFrontmost && attempt >= 1;
    if (!displayCommitted && attempt < 24) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self finishFullscreenHandoffWithCover:cover
                                       identifier:identifier
                                          attempt:attempt + 1];
        });
        return;
    }

    id scene = self.floatingScene;
    id presenter = self.floatingPresenter;
    [self.floatingHostView removeFromSuperview];
    self.floatingHostView = nil;
    self.floatingHostReferenceSize = CGSizeZero;
    self.floatingSceneEntity = nil;
    self.floatingSceneHandle = nil;
    self.floatingScene = nil;
    self.floatingPresentationManager = nil;
    self.floatingPresenter = nil;
    self.floatingIdentifier = nil;
    self.floatingFullscreenProgress = 0.0;
    [self detachFloatingKeyboardLayerHost];
    [self clearFloatingReusableKeyboardHost];
    [self applyKeyboardFrame:CGRectNull visible:NO];
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

    // The geometry animation already ended at the exact physical-screen
    // bounds. Once SpringBoard confirms the real Scene is frontmost, exchange
    // the identical full-screen cover without a second visible animation.
    [UIView performWithoutAnimation:^{
        self.floatingWindow.hidden = YES;
        [cover removeFromSuperview];
        self.floatingContainer.alpha = 1.0;
        [self resetFloatingInteractiveLayoutAnimated:NO];
        [self stopLockMonitoringIfIdle];
    }];
}

- (void)protectedSceneDidDisappear:(NSNotification *)notification {
    (void)notification;
    [self clearFloatingReusableKeyboardHost];
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
    if (self.floatingDocked &&
        [identifier isEqualToString:FLMFrontmostApplicationIdentifier()]) {
        // The user opened the docked application through SpringBoard. Its
        // primary scene now belongs to the fullscreen transition; reconnecting
        // that same scene into the dock produces a black, permanently stale
        // presenter. Detach our presenter without backgrounding the app.
        self.floatingReconnectSuppressed = YES;
        [self closeFloatingWindowKeepingApplication:NO];
        return;
    }
    self.floatingLaunchGeneration += 1;
    NSUInteger generation = self.floatingLaunchGeneration;
    self.floatingLaunchState = FLMFloatingLaunchStatePrewarming;
    self.floatingLaunchStartedAt = CACurrentMediaTime();
    self.floatingScenePreparedAt = 0.0;
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

- (CGRect)centeredFloatingFrame {
    CGRect bounds = self.floatingWindow.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    if (width <= 0.0 || height <= 0.0) {
        return CGRectZero;
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
    return CGRectMake(originX, top, containerWidth, containerHeight);
}

- (CGRect)dockedFloatingFrameOnRight:(BOOL)onRight width:(CGFloat)width {
    UIView *rootView = self.floatingWindow.rootViewController.view;
    CGRect bounds = rootView.bounds;
    UIEdgeInsets safeInsets = rootView.safeAreaInsets;
    CGRect centeredFrame = [self centeredFloatingFrame];
    CGFloat aspectRatio =
        CGRectGetWidth(centeredFrame) / MAX(1.0, CGRectGetHeight(centeredFrame));
    CGFloat clampedWidth =
        MAX(FLMMinimumDockWidth, MIN(FLMMaximumDockWidth, width));
    CGFloat height = clampedWidth / MAX(0.1, aspectRatio);
    CGFloat top = safeInsets.top + FLMDockTopMargin;
    CGFloat originX =
        onRight
            ? CGRectGetWidth(bounds) - safeInsets.right -
                  FLMDockSideMargin - clampedWidth
            : safeInsets.left + FLMDockSideMargin;
    return CGRectMake(originX, top, clampedWidth, height);
}

- (void)layoutFloatingDockShadow {
    if (!self.floatingDocked && !self.floatingDockTransitionActive) {
        self.floatingDockShadowView.hidden = YES;
        return;
    }
    self.floatingDockShadowView.hidden = NO;
    self.floatingDockShadowView.bounds = self.floatingContainer.bounds;
    self.floatingDockShadowView.center = self.floatingContainer.center;
    self.floatingDockShadowView.transform = self.floatingContainer.transform;
    self.floatingDockShadowView.layer.cornerRadius =
        self.floatingContainer.layer.cornerRadius;
    UIBezierPath *shadowPath =
        [UIBezierPath
            bezierPathWithRoundedRect:self.floatingDockShadowView.bounds
                         cornerRadius:self.floatingDockShadowView.layer.cornerRadius];
    self.floatingDockShadowView.layer.shadowPath = shadowPath.CGPath;
    [self.floatingWindow.rootViewController.view
        insertSubview:self.floatingDockShadowView
         belowSubview:self.floatingContainer];
}

- (void)updateFloatingDockAccessoryPositions {
    if (!self.floatingDocked) {
        return;
    }
    self.floatingDockShadowView.center = self.floatingContainer.center;
    self.floatingDockShadowView.transform = self.floatingContainer.transform;

    CGRect frame = self.floatingContainer.frame;
    const CGFloat hitSize = 46.0;
    self.floatingResizeHandle.frame =
        self.floatingDockedOnRight
            ? CGRectMake(CGRectGetMinX(frame) - 32.0,
                         CGRectGetMaxY(frame) - 14.0,
                         hitSize,
                         hitSize)
            : CGRectMake(CGRectGetMaxX(frame) - 14.0,
                         CGRectGetMaxY(frame) - 14.0,
                         hitSize,
                         hitSize);
}

- (void)normalizeFloatingContainerTransform {
    if (CGAffineTransformIsIdentity(self.floatingContainer.transform)) {
        return;
    }
    CGRect visualFrame = self.floatingContainer.frame;
    [UIView performWithoutAnimation:^{
        self.floatingContainer.transform = CGAffineTransformIdentity;
        self.floatingContainer.frame = visualFrame;
        self.floatingDockShadowView.transform = CGAffineTransformIdentity;
        self.floatingDockShadowView.frame = visualFrame;
        self.floatingDockInteractionShield.frame = self.floatingContainer.bounds;
        [self layoutFloatingHostView];
    }];
}

- (void)layoutFloatingDockReadyIndicator {
    CGSize size = self.floatingDockReadyIndicator.bounds.size;
    self.floatingDockReadyIndicator.center =
        CGPointMake(CGRectGetMidX(self.floatingContainer.frame),
                    CGRectGetMinY(self.floatingContainer.frame) -
                        size.height * 0.5 - 10.0);
}

- (void)setFloatingDockReady:(BOOL)ready animated:(BOOL)animated {
    if (self.floatingDockReady == ready) {
        if (ready) {
            [self layoutFloatingDockReadyIndicator];
        } else if (!animated) {
            [self.floatingDockReadyIndicator.layer removeAllAnimations];
            self.floatingDockReadyIndicator.hidden = YES;
            self.floatingDockReadyIndicator.alpha = 0.0;
            self.floatingDockReadyIndicator.transform =
                CGAffineTransformIdentity;
        }
        return;
    }
    self.floatingDockReady = ready;
    if (ready) {
        [self layoutFloatingDockReadyIndicator];
        self.floatingDockReadyIndicator.hidden = NO;
        self.floatingDockReadyIndicator.alpha = 0.0;
        self.floatingDockReadyIndicator.transform =
            CGAffineTransformMakeScale(0.72, 0.72);
        void (^showChanges)(void) = ^{
            self.floatingDockReadyIndicator.alpha = 1.0;
            self.floatingDockReadyIndicator.transform =
                CGAffineTransformIdentity;
        };
        if (!animated) {
            showChanges();
            return;
        }
        [UIView animateWithDuration:0.28
                              delay:0.0
             usingSpringWithDamping:0.64
              initialSpringVelocity:0.42
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:showChanges
                         completion:nil];
        return;
    }

    void (^hideChanges)(void) = ^{
        self.floatingDockReadyIndicator.alpha = 0.0;
        self.floatingDockReadyIndicator.transform =
            CGAffineTransformMakeScale(0.78, 0.78);
    };
    void (^hideCompletion)(BOOL) = ^(BOOL finished) {
        (void)finished;
        if (!self.floatingDockReady) {
            self.floatingDockReadyIndicator.hidden = YES;
            self.floatingDockReadyIndicator.transform =
                CGAffineTransformIdentity;
        }
    };
    if (!animated) {
        hideChanges();
        hideCompletion(YES);
        return;
    }
    [UIView animateWithDuration:0.16
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionCurveEaseOut
                     animations:hideChanges
                     completion:hideCompletion];
}

- (void)layoutFloatingResizeHandle {
    if (!self.floatingDocked) {
        self.floatingResizeHandle.hidden = YES;
        return;
    }
    CGRect frame = self.floatingContainer.frame;
    const CGFloat hitSize = 46.0;
    UIBezierPath *path = [UIBezierPath bezierPath];
    if (self.floatingDockedOnRight) {
        self.floatingResizeHandle.frame =
            CGRectMake(CGRectGetMinX(frame) - 32.0,
                       CGRectGetMaxY(frame) - 14.0,
                       hitSize,
                       hitSize);
        [path moveToPoint:CGPointMake(24.0, 2.0)];
        [path addLineToPoint:CGPointMake(24.0, 12.0)];
        [path addQuadCurveToPoint:CGPointMake(34.0, 22.0)
                    controlPoint:CGPointMake(24.0, 22.0)];
        [path addLineToPoint:CGPointMake(44.0, 22.0)];
    } else {
        self.floatingResizeHandle.frame =
            CGRectMake(CGRectGetMaxX(frame) - 14.0,
                       CGRectGetMaxY(frame) - 14.0,
                       hitSize,
                       hitSize);
        [path moveToPoint:CGPointMake(22.0, 2.0)];
        [path addLineToPoint:CGPointMake(22.0, 12.0)];
        [path addQuadCurveToPoint:CGPointMake(12.0, 22.0)
                    controlPoint:CGPointMake(22.0, 22.0)];
        [path addLineToPoint:CGPointMake(2.0, 22.0)];
    }
    self.floatingResizeShapeLayer.frame = self.floatingResizeHandle.bounds;
    self.floatingResizeShapeLayer.path = path.CGPath;
    self.floatingResizeHandle.hidden = NO;
}

- (BOOL)floatingResizeControlContainsPoint:(CGPoint)point {
    if (!self.floatingDocked || self.floatingResizeHandle.hidden ||
        !self.floatingResizeShapeLayer.path) {
        return NO;
    }
    CGRect broadFrame = CGRectInset(self.floatingResizeHandle.frame, -10.0, -10.0);
    if (!CGRectContainsPoint(broadFrame, point)) {
        return NO;
    }
    CGPoint localPoint =
        CGPointMake(point.x - CGRectGetMinX(self.floatingResizeHandle.frame),
                    point.y - CGRectGetMinY(self.floatingResizeHandle.frame));
    CGPathRef touchPath =
        CGPathCreateCopyByStrokingPath(self.floatingResizeShapeLayer.path,
                                      NULL,
                                      20.0,
                                      kCGLineCapRound,
                                      kCGLineJoinRound,
                                      1.0);
    if (!touchPath) {
        return NO;
    }
    BOOL contains = CGPathContainsPoint(touchPath, NULL, localPoint, NO);
    CGPathRelease(touchPath);
    return contains;
}

- (void)configureFloatingInteractionForDockedState {
    FLMFloatingWindow *floatingWindow =
        (FLMFloatingWindow *)self.floatingWindow;
    floatingWindow.passesTouchesOutsideFloatingContent = self.floatingDocked;
    self.floatingBackdropTap.enabled = !self.floatingDocked;
    self.floatingDockTap.enabled = NO;
    self.floatingDockDragPress.enabled = NO;
    self.floatingResizePress.enabled = NO;
    self.floatingDockInputGesture.enabled = self.floatingDocked;
    self.floatingHostView.userInteractionEnabled = !self.floatingDocked;
    self.floatingDockInteractionShield.frame = self.floatingContainer.bounds;
    self.floatingDockInteractionShield.hidden = !self.floatingDocked;
    self.floatingDockInteractionShield.userInteractionEnabled =
        self.floatingDocked;
    if (self.floatingDocked) {
        [self.floatingContainer
            bringSubviewToFront:self.floatingDockInteractionShield];
    }
    self.floatingHandle.userInteractionEnabled = !self.floatingDocked;
    self.floatingHandle.hidden = self.floatingDocked;
    self.floatingResizeHandle.hidden = !self.floatingDocked;
    self.floatingExclusiveGesture.enabled =
        !self.floatingDocked && self.usesSystemGestureManager &&
        !self.floatingWindow.hidden;
    if (self.floatingDocked) {
        self.floatingDimView.alpha = 0.0;
        self.floatingHandle.alpha = 0.0;
        self.floatingResizeHandle.alpha = 1.0;
        self.floatingDockShadowView.alpha = 1.0;
        [self layoutFloatingDockShadow];
        if (self.previousKeyWindow &&
            self.previousKeyWindow != self.floatingWindow) {
            [self.previousKeyWindow makeKeyWindow];
        }
        [self layoutFloatingResizeHandle];
    } else {
        self.floatingResizeHandle.alpha = 0.0;
        self.floatingHandle.alpha = 1.0;
        self.floatingDockShadowView.alpha = 0.0;
        self.floatingDockShadowView.hidden = YES;
        [self.floatingWindow makeKeyWindow];
    }
}

- (void)restoreFloatingHandleInteraction {
    // configureFloatingInteractionForDockedState deliberately disables the
    // handle for a docked card.  The old close/open path only unhid it, so a
    // subsequently centered card could display a white bar whose recognizers
    // never received touches.  Keep this reset independent of Scene startup.
    self.floatingHandle.hidden = NO;
    self.floatingHandle.alpha = 1.0;
    self.floatingHandle.userInteractionEnabled = YES;
    self.floatingHandlePress.enabled = YES;
    self.floatingHandleTap.enabled = YES;
}

- (void)transitionFloatingWindowToDocked {
    [self setFloatingDockReady:NO animated:YES];
    if (self.floatingWindow.hidden || self.floatingDocked) {
        return;
    }
    [self setFloatingApplicationInputBlocked:YES];
    [self.floatingHostView endEditing:YES];
    FLMPublishKeyboardState(nil, nil);
    [self applyKeyboardFrame:CGRectNull visible:NO];
    [self clearFloatingReusableKeyboardHost];
    self.floatingDockTransitionActive = YES;
    self.floatingDockedOnRight = YES;
    self.floatingDockWidth = FLMMinimumDockWidth;
    CGRect target =
        [self dockedFloatingFrameOnRight:YES width:self.floatingDockWidth];
    CGFloat targetScale =
        CGRectGetWidth(target) /
        MAX(1.0, CGRectGetWidth(self.floatingContainer.bounds));
    self.floatingDockShadowView.hidden = NO;
    [UIView animateWithDuration:0.40
                          delay:0.0
         usingSpringWithDamping:0.84
          initialSpringVelocity:0.34
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         // Continue from the exact transform produced by the
                         // finger. Do not restore the centered frame or relayout
                         // the remote host before the card reaches its dock.
                         self.floatingContainer.center =
                             CGPointMake(CGRectGetMidX(target),
                                         CGRectGetMidY(target));
                         self.floatingContainer.transform =
                             CGAffineTransformMakeScale(targetScale,
                                                        targetScale);
                         self.floatingContainer.layer.cornerRadius =
                             16.0 / MAX(0.01, targetScale);
                         self.floatingDimView.alpha = 0.0;
                         self.floatingDockShadowView.alpha = 1.0;
                         [self layoutFloatingDockShadow];
                         self.floatingHandle.alpha = 0.0;
                         [self layoutFloatingHandleForCurrentContainer];
                     }
                     completion:^(BOOL finished) {
                         (void)finished;
                         UIView *settleCover =
                             [self.floatingContainer
                                 snapshotViewAfterScreenUpdates:NO];
                         if (settleCover) {
                             settleCover.frame = target;
                             settleCover.userInteractionEnabled = NO;
                             settleCover.layer.cornerRadius = 16.0;
                             settleCover.clipsToBounds = YES;
                             [self.floatingWindow.rootViewController.view
                                 addSubview:settleCover];
                         }
                         [UIView performWithoutAnimation:^{
                             self.floatingContainer.transform =
                                 CGAffineTransformIdentity;
                             self.floatingContainer.frame = target;
                             self.floatingContainer.layer.cornerRadius = 16.0;
                             self.floatingDockShadowView.transform =
                                 CGAffineTransformIdentity;
                             self.floatingDockShadowView.frame = target;
                             self.floatingDockShadowView.layer.cornerRadius = 16.0;
                             [self layoutFloatingHostView];
                         }];
                         self.floatingDockTransitionActive = NO;
                         self.floatingDocked = YES;
                         self.lastObservedFrontmostIdentifier =
                             FLMFrontmostApplicationIdentifier();
                         self.floatingExternalActivationArmed =
                             ![self.lastObservedFrontmostIdentifier
                                 isEqualToString:self.floatingIdentifier];
                         self.floatingHandleBar.alpha = 1.0;
                         self.floatingHandleBar.transform =
                             CGAffineTransformIdentity;
                         [self configureFloatingInteractionForDockedState];
                         if (settleCover) {
                             [UIView animateWithDuration:0.08
                                              animations:^{
                                                  settleCover.alpha = 0.0;
                                              }
                                              completion:^(__unused BOOL done) {
                                                  [settleCover removeFromSuperview];
                                              }];
                         }
                     }];
}

- (void)transitionFloatingWindowToCentered {
    [self setFloatingDockReady:NO animated:YES];
    if (self.floatingWindow.hidden || !self.floatingDocked) {
        return;
    }
    FLMFloatingWindow *floatingWindow =
        (FLMFloatingWindow *)self.floatingWindow;
    floatingWindow.passesTouchesOutsideFloatingContent = NO;
    self.floatingDockTap.enabled = NO;
    self.floatingDockDragPress.enabled = NO;
    self.floatingResizePress.enabled = NO;
    self.floatingDockInputGesture.enabled = NO;
    self.floatingDockInputGeneration += 1;
    self.floatingResizeHandle.alpha = 0.0;
    self.floatingResizeHandle.hidden = YES;
    self.floatingDockShadowView.hidden = NO;
    self.floatingDocked = NO;
    [self setFloatingApplicationInputBlocked:YES];
    [self restoreFloatingHandleInteraction];
    self.floatingExternalActivationArmed = NO;
    self.lastObservedFrontmostIdentifier = nil;
    FLMPublishKeyboardState(self.floatingIdentifier, self.floatingScene);
    [self.floatingWindow makeKeyWindow];
    CGRect target = [self centeredFloatingFrame];
    self.floatingHandle.hidden = NO;
    [UIView animateWithDuration:0.42
                          delay:0.0
         usingSpringWithDamping:0.82
          initialSpringVelocity:0.30
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         self.floatingContainer.transform =
                             CGAffineTransformIdentity;
                         self.floatingContainer.layer.borderWidth = 0.0;
                         self.floatingContainer.frame = target;
                         self.floatingContainer.layer.cornerRadius = 18.0;
                         self.floatingDimView.alpha = 1.0;
                         self.floatingDockShadowView.alpha = 0.0;
                         self.floatingDockShadowView.frame = target;
                         self.floatingHandle.alpha = 1.0;
                         [self layoutFloatingHostView];
                         [self layoutFloatingHandleForCurrentContainer];
                     }
                     completion:^(BOOL finished) {
                         (void)finished;
                         [self configureFloatingInteractionForDockedState];
                     }];
}

- (void)snapDockedFloatingWindowUsingTouchPoint:(CGPoint)point {
    if (!self.floatingDocked) {
        return;
    }
    CGRect bounds = self.floatingWindow.rootViewController.view.bounds;
    self.floatingDockedOnRight = point.x >= CGRectGetMidX(bounds);
    CGRect target =
        [self dockedFloatingFrameOnRight:self.floatingDockedOnRight
                                   width:self.floatingDockWidth];
    [UIView animateWithDuration:0.28
                          delay:0.0
         usingSpringWithDamping:0.88
          initialSpringVelocity:0.28
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         self.floatingContainer.center =
                             CGPointMake(CGRectGetMidX(target),
                                         CGRectGetMidY(target));
                         self.floatingResizeHandle.alpha = 1.0;
                         [self updateFloatingDockAccessoryPositions];
                     }
                     completion:^(BOOL finished) {
                         (void)finished;
                         [UIView performWithoutAnimation:^{
                             self.floatingContainer.transform =
                                 CGAffineTransformIdentity;
                             self.floatingContainer.layer.borderWidth = 0.0;
                             [self layoutFloatingDockShadow];
                             [self layoutFloatingResizeHandle];
                         }];
                     }];
}

- (void)saveFloatingDockWidth {
    CGFloat width =
        MAX(FLMMinimumDockWidth, MIN(FLMMaximumDockWidth, self.floatingDockWidth));
    self.floatingDockWidth = width;
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

    self.floatingContainer.frame =
        self.floatingDocked
            ? [self dockedFloatingFrameOnRight:self.floatingDockedOnRight
                                         width:self.floatingDockWidth]
            : [self centeredFloatingFrame];
    [self layoutFloatingHostView];
    self.floatingStatusLabel.frame = self.floatingContainer.bounds;
    self.floatingDockInteractionShield.frame = self.floatingContainer.bounds;
    [self layoutFloatingHandleForCurrentContainer];
    [self layoutFloatingDockShadow];
    [self layoutFloatingResizeHandle];
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
        CGFloat visibleHandleWidth = containerWidth * 0.30;
        // Keep the invisible hit target outside the application card.  The
        // visible bar remains centered, with exactly 20 pt of horizontal
        // reach on each side and a little more vertical forgiveness.
        CGFloat handleWidth = visibleHandleWidth + 40.0;
        CGFloat handleHeight = 58.0;
        self.floatingHandle.frame =
            CGRectMake(floor(CGRectGetMidX(self.floatingContainer.frame) -
                             handleWidth * 0.5),
                       CGRectGetMaxY(self.floatingContainer.frame),
                       handleWidth,
                       handleHeight);
        self.floatingHandleBar.frame =
            CGRectMake(20.0,
                       floor((handleHeight - 5.0) * 0.5),
                       visibleHandleWidth,
                       5.0);
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

- (void)applyKeyboardFrame:(CGRect)frame visible:(BOOL)visible {
    FLMKeyboardDiagnosticLog(
        @"apply-frame input-visible=%d frame=%@ windowHidden=%d docked=%d "
         "launch=%lu launchGen=%lu interactionGen=%lu activeHost=%p reusableHost=%p",
        visible, NSStringFromCGRect(frame), self.floatingWindow.hidden,
        self.floatingDocked, (unsigned long)self.floatingLaunchState,
        (unsigned long)self.floatingLaunchGeneration,
        (unsigned long)self.floatingKeyboardInteractionGeneration,
        (__bridge void *)self.floatingKeyboardLayerHostView,
        (__bridge void *)self.floatingReusableKeyboardLayerHostView);
    if (self.floatingWindow.hidden || self.floatingDocked) {
        visible = NO;
    }
    CGRect bounds = self.floatingWindow.rootViewController.view.bounds;
    if (visible) {
        [self beginFloatingKeyboardInteractionSession];
        CGFloat height = CGRectGetHeight(frame);
        if (height < 180.0) {
            height = self.lastPortraitKeyboardHeight;
        } else {
            self.lastPortraitKeyboardHeight = height;
        }
        height = MIN(CGRectGetHeight(bounds), MAX(216.0, height));
        frame = CGRectMake(0.0,
                           CGRectGetHeight(bounds) - height,
                           CGRectGetWidth(bounds),
                           height);
        self.floatingKeyboardVisible = YES;
        self.floatingKeyboardFrame = frame;
        self.floatingBackdropTap.additionalProtectedFrame = frame;
        ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame = frame;
        self.keyboardOverlayWindow.keyboardInteractionFrame = frame;
        if (self.floatingKeyboardLayerHostView) {
            self.keyboardOverlayWindow.hidden = NO;
        }
        NSUInteger generation = self.floatingKeyboardInteractionGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(1.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (generation == self.floatingKeyboardInteractionGeneration &&
                self.floatingKeyboardInteractionSessionActive &&
                self.floatingKeyboardVisible &&
                !self.floatingKeyboardLayerHostView &&
                !self.floatingWindow.hidden && !self.floatingDocked) {
                // Never turn a keyboard pairing miss into an unrelated Scene
                // transition.  The route remains protected while UIKit either
                // publishes a fresh host or keeps its in-card fallback alive.
                NSLog(@"[FlymeKeyboardOverlay] pairing timeout; keeping centered %@",
                      self.floatingIdentifier ?: @"<unknown>");
                FLMKeyboardDiagnosticLog(
                    @"pair-timeout app=%@ scene=%@ launchGen=%lu prepareGen=%lu",
                    self.floatingIdentifier ?: @"<unknown>",
                    FLMSceneIdentifier(self.floatingScene) ?: @"<none>",
                    (unsigned long)self.floatingLaunchGeneration,
                    (unsigned long)self.floatingKeyboardPrepareGeneration);
            }
        });
        return;
    }
    self.floatingKeyboardVisible = NO;
    self.floatingKeyboardFrame = CGRectNull;
    self.floatingBackdropTap.additionalProtectedFrame = CGRectNull;
    ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame = CGRectNull;
    self.keyboardOverlayWindow.keyboardInteractionFrame = CGRectNull;
    [self detachFloatingKeyboardLayerHost];
    self.floatingKeyboardPrepareGeneration += 1;
    [self endFloatingKeyboardInteractionSession];
}

- (void)prepareFloatingKeyboardHostIfNeeded {
    if (self.floatingWindow.hidden || self.floatingDocked ||
        self.floatingIdentifier.length == 0 || !self.floatingScene) {
        FLMKeyboardDiagnosticLog(
            @"prepare-rejected hidden=%d docked=%d app=%@ scene=%@ launch=%lu",
            self.floatingWindow.hidden, self.floatingDocked,
            self.floatingIdentifier ?: @"<none>",
            FLMSceneIdentifier(self.floatingScene) ?: @"<none>",
            (unsigned long)self.floatingLaunchState);
        return;
    }
    FLMKeyboardDiagnosticLog(
        @"prepare-accepted app=%@ scene=%@ activeHost=%p reusableHost=%p",
        self.floatingIdentifier, FLMSceneIdentifier(self.floatingScene) ?: @"<none>",
        (__bridge void *)self.floatingKeyboardLayerHostView,
        (__bridge void *)self.floatingReusableKeyboardLayerHostView);
    [self beginFloatingKeyboardInteractionSession];
    if (!self.keyboardOverlayWindow) {
        CGRect bounds = FLMVisualScreenBounds();
        FLMKeyboardOverlayWindow *window =
            FLMCreateKeyboardOverlayWindow(bounds);
        window.windowLevel = UIWindowLevelAlert + 94.0;
        window.backgroundColor = [UIColor clearColor];
        window.rootViewController = [[FLMOverlayViewController alloc] init];
        window.rootViewController.view.backgroundColor = [UIColor clearColor];
        window.keyboardInteractionFrame = [self floatingKeyboardInteractionFrame];
        window.hidden = YES;
        self.keyboardOverlayWindow = window;
    }
}

- (void)requestFloatingKeyboardHostPreparation {
    if (self.floatingWindow.hidden || self.floatingDocked ||
        self.floatingLaunchState == FLMFloatingLaunchStateClosing ||
        self.floatingIdentifier.length == 0 || !self.floatingScene) {
        FLMKeyboardDiagnosticLog(
            @"request-rejected hidden=%d docked=%d app=%@ scene=%@ launch=%lu",
            self.floatingWindow.hidden, self.floatingDocked,
            self.floatingIdentifier ?: @"<none>",
            FLMSceneIdentifier(self.floatingScene) ?: @"<none>",
            (unsigned long)self.floatingLaunchState);
        return;
    }
    [self beginFloatingKeyboardInteractionSession];
    [self prepareFloatingKeyboardHostIfNeeded];
    self.floatingKeyboardPrepareGeneration += 1;
    NSUInteger generation = self.floatingKeyboardPrepareGeneration;
    FLMKeyboardDiagnosticLog(
        @"request-accepted app=%@ scene=%@ launchGen=%lu prepareGen=%lu "
         "activeHost=%p reusableHost=%p leaseScene=%@",
        self.floatingIdentifier, FLMSceneIdentifier(self.floatingScene) ?: @"<none>",
        (unsigned long)self.floatingLaunchGeneration, (unsigned long)generation,
        (__bridge void *)self.floatingKeyboardLayerHostView,
        (__bridge void *)self.floatingReusableKeyboardLayerHostView,
        self.floatingReusableKeyboardSceneIdentifier ?: @"<none>");

    // A reused iOS 16 keyboard host does not necessarily receive another
    // client-settings diff. Revalidate the last matched host at a few bounded
    // points around responder activation instead of adding a lifecycle hook.
    void (^reattachReusableHost)(void) = ^{
        if (generation != self.floatingKeyboardPrepareGeneration ||
            self.floatingWindow.hidden || self.floatingDocked) {
            return;
        }
        UIView *candidate = self.floatingKeyboardLayerHostView ?:
                            self.floatingReusableKeyboardLayerHostView;
        id candidateScene = self.floatingReusableKeyboardScene;
        if (!candidate) {
            FLMKeyboardDiagnosticLog(
                @"reattach-no-candidate prepareGen=%lu scene=%@ leaseScene=%@",
                (unsigned long)generation,
                FLMSceneIdentifier(self.floatingScene) ?: @"<none>",
                self.floatingReusableKeyboardSceneIdentifier ?: @"<none>");
            return;
        }
        NSString *floatingSceneIdentifier = FLMSceneIdentifier(self.floatingScene);
        NSString *leasedSceneIdentifier =
            self.floatingReusableKeyboardSceneIdentifier;
        if (floatingSceneIdentifier.length > 0 &&
            leasedSceneIdentifier.length > 0 &&
            ![floatingSceneIdentifier isEqualToString:leasedSceneIdentifier]) {
            if (candidate == self.floatingKeyboardLayerHostView) {
                [self detachFloatingKeyboardLayerHost];
            }
            [self clearFloatingReusableKeyboardHost];
            FLMKeyboardDiagnosticLog(
                @"reattach-scene-rejected host=%p current=%@ lease=%@ prepareGen=%lu",
                (__bridge void *)candidate, floatingSceneIdentifier,
                leasedSceneIdentifier, (unsigned long)generation);
            return;
        }
        FLMKeyboardDiagnosticLog(
            @"reattach-dispatch host=%p scene=%@ current=%@ prepareGen=%lu",
            (__bridge void *)candidate,
            FLMSceneIdentifier(candidateScene) ?: @"<none>",
            floatingSceneIdentifier ?: @"<none>", (unsigned long)generation);
        [self keyboardLayerHostView:candidate didUpdateForScene:candidateScene];
    };
    reattachReusableHost();
    for (NSNumber *delayValue in @[@0.08, @0.20, @0.45, @0.85]) {
        NSTimeInterval delay = delayValue.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), reattachReusableHost);
    }
}

- (void)keyboardLayerHostView:(UIView *)hostView didUpdateForScene:(id)scene {
    FLMKeyboardDiagnosticLog(
        @"host-update-enter host=%p updatedScene=%@ currentScene=%@ launch=%lu "
         "launchGen=%lu hidden=%d docked=%d",
        (__bridge void *)hostView, FLMSceneIdentifier(scene) ?: @"<none>",
        FLMSceneIdentifier(self.floatingScene) ?: @"<none>",
        (unsigned long)self.floatingLaunchState,
        (unsigned long)self.floatingLaunchGeneration, self.floatingWindow.hidden,
        self.floatingDocked);
    if (self.floatingLaunchState == FLMFloatingLaunchStateClosing) {
        self.keyboardOverlayWindow.hidden = YES;
        FLMKeyboardDiagnosticLog(@"host-update-rejected reason=closing host=%p",
                                 (__bridge void *)hostView);
        return;
    }
    if (!hostView || self.floatingWindow.hidden || self.floatingDocked ||
        !self.floatingScene || self.floatingIdentifier.length == 0) {
        if (hostView == self.floatingKeyboardLayerHostView) {
            [self detachFloatingKeyboardLayerHost];
        }
        FLMKeyboardDiagnosticLog(
            @"host-update-rejected reason=inactive host=%p hidden=%d docked=%d app=%@ "
             "scene=%@",
            (__bridge void *)hostView, self.floatingWindow.hidden,
            self.floatingDocked, self.floatingIdentifier ?: @"<none>",
            FLMSceneIdentifier(self.floatingScene) ?: @"<none>");
        return;
    }

    id owningScene = nil;
    @try {
        owningScene = [hostView valueForKey:@"_owningScene"];
    } @catch (__unused NSException *exception) {
    }
    NSString *floatingSceneIdentifier = FLMSceneIdentifier(self.floatingScene);
    NSString *owningSceneIdentifier = FLMSceneIdentifier(owningScene);
    NSString *updatedSceneIdentifier = FLMSceneIdentifier(scene);
    BOOL matches = owningScene == self.floatingScene || scene == self.floatingScene;
    if (!matches && floatingSceneIdentifier.length > 0) {
        matches = [floatingSceneIdentifier isEqualToString:owningSceneIdentifier] ||
                  [floatingSceneIdentifier isEqualToString:updatedSceneIdentifier];
    }
    if (!matches) {
        FLMKeyboardDiagnosticLog(
            @"host-update-rejected reason=scene-mismatch host=%p current=%@ owner=%@ "
             "updated=%@ activeHost=%d reusableHost=%d",
            (__bridge void *)hostView, floatingSceneIdentifier ?: @"<none>",
            owningSceneIdentifier ?: @"<none>",
            updatedSceneIdentifier ?: @"<none>",
            hostView == self.floatingKeyboardLayerHostView,
            hostView == self.floatingReusableKeyboardLayerHostView);
        if (hostView == self.floatingKeyboardLayerHostView) {
            [self detachFloatingKeyboardLayerHost];
        }
        if (hostView == self.floatingReusableKeyboardLayerHostView) {
            [self clearFloatingReusableKeyboardHost];
        }
        return;
    }

    self.floatingReusableKeyboardLayerHostView = hostView;
    self.floatingReusableKeyboardScene = scene ?: owningScene;
    self.floatingReusableKeyboardSceneIdentifier =
        owningSceneIdentifier ?: updatedSceneIdentifier;
    self.floatingKeyboardDetachPending = NO;
    self.floatingKeyboardDetachGeneration += 1;
    FLMKeyboardDiagnosticLog(
        @"host-lease-accepted host=%p current=%@ owner=%@ updated=%@ detachGen=%lu",
        (__bridge void *)hostView, floatingSceneIdentifier ?: @"<none>",
        owningSceneIdentifier ?: @"<none>",
        updatedSceneIdentifier ?: @"<none>",
        (unsigned long)self.floatingKeyboardDetachGeneration);

    [self prepareFloatingKeyboardHostIfNeeded];
    UIView *overlayRoot = self.keyboardOverlayWindow.rootViewController.view;
    if (!overlayRoot) {
        return;
    }
    if (hostView != self.floatingKeyboardLayerHostView) {
        [self detachFloatingKeyboardLayerHost];
        UIView *originalSuperview = hostView.superview;
        self.floatingKeyboardOriginalSuperview = originalSuperview;
        self.floatingKeyboardOriginalSubviewIndex =
            originalSuperview ? [originalSuperview.subviews indexOfObject:hostView]
                              : NSNotFound;
        self.floatingKeyboardOriginalFrame = hostView.frame;
        self.floatingKeyboardOriginalTransform = hostView.transform;
        self.floatingKeyboardOriginalAutoresizingMask = hostView.autoresizingMask;
        self.floatingKeyboardOriginalTranslatesAutoresizingMask =
            hostView.translatesAutoresizingMaskIntoConstraints;
        self.floatingKeyboardLayerHostView = hostView;
    }

    if (hostView.superview != overlayRoot) {
        [hostView removeFromSuperview];
        hostView.translatesAutoresizingMaskIntoConstraints = YES;
        hostView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                    UIViewAutoresizingFlexibleHeight;
        hostView.transform = CGAffineTransformIdentity;
        hostView.frame = overlayRoot.bounds;
        [overlayRoot addSubview:hostView];
    } else {
        hostView.transform = CGAffineTransformIdentity;
        hostView.frame = overlayRoot.bounds;
    }
    [hostView setNeedsLayout];
    [hostView layoutIfNeeded];
    self.keyboardOverlayWindow.keyboardInteractionFrame =
        [self floatingKeyboardInteractionFrame];
    self.keyboardOverlayWindow.hidden = NO;
    id keyboardScene = nil;
    @try {
        keyboardScene = [hostView valueForKey:@"_keyboardScene"];
    } @catch (__unused NSException *exception) {
    }
    NSLog(@"[FlymeKeyboardOverlay] paired owner=%@ keyboard=%@",
          owningSceneIdentifier ?: updatedSceneIdentifier ?: @"<unknown>",
          FLMSceneIdentifier(keyboardScene) ?: @"<unknown>");
    FLMKeyboardDiagnosticLog(
        @"host-paired host=%p overlay=%p owner=%@ keyboard=%@ frame=%@",
        (__bridge void *)hostView, (__bridge void *)self.keyboardOverlayWindow,
        owningSceneIdentifier ?: updatedSceneIdentifier ?: @"<unknown>",
        FLMSceneIdentifier(keyboardScene) ?: @"<unknown>",
        NSStringFromCGRect(hostView.frame));
}

- (void)detachFloatingKeyboardLayerHost {
    self.floatingKeyboardDetachPending = NO;
    self.floatingKeyboardDetachGeneration += 1;
    UIView *hostView = self.floatingKeyboardLayerHostView;
    if (!hostView) {
        self.keyboardOverlayWindow.hidden = YES;
        FLMKeyboardDiagnosticLog(
            @"detach-no-active-host detachGen=%lu reusableHost=%p leaseScene=%@",
            (unsigned long)self.floatingKeyboardDetachGeneration,
            (__bridge void *)self.floatingReusableKeyboardLayerHostView,
            self.floatingReusableKeyboardSceneIdentifier ?: @"<none>");
        return;
    }
    FLMKeyboardDiagnosticLog(
        @"detach-begin host=%p originalSuperview=%p detachGen=%lu",
        (__bridge void *)hostView,
        (__bridge void *)self.floatingKeyboardOriginalSuperview,
        (unsigned long)self.floatingKeyboardDetachGeneration);
    UIView *originalSuperview = self.floatingKeyboardOriginalSuperview;
    @try {
        [hostView removeFromSuperview];
        hostView.transform = self.floatingKeyboardOriginalTransform;
        hostView.frame = self.floatingKeyboardOriginalFrame;
        hostView.autoresizingMask = self.floatingKeyboardOriginalAutoresizingMask;
        hostView.translatesAutoresizingMaskIntoConstraints =
            self.floatingKeyboardOriginalTranslatesAutoresizingMask;
        if (originalSuperview) {
            NSInteger index = self.floatingKeyboardOriginalSubviewIndex;
            if (index >= 0 && index <= (NSInteger)originalSuperview.subviews.count) {
                [originalSuperview insertSubview:hostView atIndex:(NSUInteger)index];
            } else {
                [originalSuperview addSubview:hostView];
            }
        }
    } @catch (NSException *exception) {
        // UIKit may tear down the original keyboard hierarchy while the app
        // Scene is being backgrounded.  Dropping the weak lease is safer than
        // letting that private hierarchy exception take SpringBoard down.
        NSLog(@"[FlymeKeyboardOverlay] safe detach skipped restore: %@",
              exception.reason ?: @"<unknown>");
        FLMKeyboardDiagnosticLog(@"detach-restore-exception host=%p reason=%@",
                                 (__bridge void *)hostView,
                                 exception.reason ?: @"<unknown>");
        [self clearFloatingReusableKeyboardHost];
    }
    self.floatingKeyboardLayerHostView = nil;
    self.floatingKeyboardOriginalSuperview = nil;
    self.floatingKeyboardOriginalSubviewIndex = NSNotFound;
    self.keyboardOverlayWindow.hidden = YES;
    NSLog(@"[FlymeKeyboardOverlay] detached");
    FLMKeyboardDiagnosticLog(@"detach-complete host=%p reusableHost=%p leaseScene=%@",
                             (__bridge void *)hostView,
                             (__bridge void *)self.floatingReusableKeyboardLayerHostView,
                             self.floatingReusableKeyboardSceneIdentifier ?: @"<none>");
}

- (void)scheduleFloatingKeyboardLayerHostDetach {
    // Cancel delayed preparation blocks from the input session that is closing
    // without discarding the Scene-bound weak host lease itself.
    self.floatingKeyboardPrepareGeneration += 1;
    if (!self.floatingKeyboardLayerHostView) {
        self.keyboardOverlayWindow.hidden = YES;
        FLMKeyboardDiagnosticLog(
            @"detach-schedule-skipped reason=no-active-host reusableHost=%p leaseScene=%@",
            (__bridge void *)self.floatingReusableKeyboardLayerHostView,
            self.floatingReusableKeyboardSceneIdentifier ?: @"<none>");
        return;
    }
    self.floatingKeyboardDetachPending = YES;
    self.floatingKeyboardDetachGeneration += 1;
    NSUInteger generation = self.floatingKeyboardDetachGeneration;
    self.keyboardOverlayWindow.hidden = YES;
    FLMKeyboardDiagnosticLog(
        @"detach-scheduled host=%p detachGen=%lu prepareGen=%lu scene=%@",
        (__bridge void *)self.floatingKeyboardLayerHostView,
        (unsigned long)generation,
        (unsigned long)self.floatingKeyboardPrepareGeneration,
        FLMSceneIdentifier(self.floatingScene) ?: @"<none>");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.55 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.floatingKeyboardDetachPending ||
            generation != self.floatingKeyboardDetachGeneration) {
            FLMKeyboardDiagnosticLog(
                @"detach-cancelled scheduled=%lu current=%lu pending=%d",
                (unsigned long)generation,
                (unsigned long)self.floatingKeyboardDetachGeneration,
                self.floatingKeyboardDetachPending);
            return;
        }
        FLMKeyboardDiagnosticLog(@"detach-timer-fired detachGen=%lu",
                                 (unsigned long)generation);
        [self detachFloatingKeyboardLayerHost];
    });
}

- (void)clearFloatingReusableKeyboardHost {
    FLMKeyboardDiagnosticLog(
        @"lease-clear activeHost=%p reusableHost=%p leaseScene=%@ prepareGen=%lu",
        (__bridge void *)self.floatingKeyboardLayerHostView,
        (__bridge void *)self.floatingReusableKeyboardLayerHostView,
        self.floatingReusableKeyboardSceneIdentifier ?: @"<none>",
        (unsigned long)self.floatingKeyboardPrepareGeneration);
    self.floatingKeyboardPrepareGeneration += 1;
    self.floatingReusableKeyboardLayerHostView = nil;
    self.floatingReusableKeyboardScene = nil;
    self.floatingReusableKeyboardSceneIdentifier = nil;
}

- (CGRect)floatingKeyboardInteractionFrame {
    if (!self.floatingKeyboardInteractionSessionActive) {
        return CGRectNull;
    }
    if (self.floatingKeyboardVisible &&
        !CGRectIsNull(self.floatingKeyboardFrame) &&
        CGRectGetWidth(self.floatingKeyboardFrame) > 1.0 &&
        CGRectGetHeight(self.floatingKeyboardFrame) > 1.0) {
        return self.floatingKeyboardFrame;
    }
    CGRect bounds = self.floatingWindow.rootViewController.view.bounds;
    CGFloat height = MIN(CGRectGetHeight(bounds),
                         MAX(216.0, self.lastPortraitKeyboardHeight));
    return CGRectMake(0.0,
                      CGRectGetHeight(bounds) - height,
                      CGRectGetWidth(bounds),
                      height);
}

- (BOOL)pointIsInsideFloatingInteractionDomain:(CGPoint)point {
    CGRect contentFrame = CGRectInset(self.floatingContainer.frame, -2.0, -2.0);
    CGRect handleFrame = CGRectInset(self.floatingHandle.frame, -22.0, -20.0);
    if (CGRectContainsPoint(contentFrame, point) ||
        (!self.floatingHandle.hidden && CGRectContainsPoint(handleFrame, point))) {
        return YES;
    }
    CGRect keyboardFrame = [self floatingKeyboardInteractionFrame];
    return !CGRectIsNull(keyboardFrame) &&
           CGRectContainsPoint(keyboardFrame, point);
}

- (void)beginFloatingKeyboardInteractionSession {
    if (self.floatingWindow.hidden || self.floatingDocked) {
        return;
    }
    if (self.floatingKeyboardInteractionSessionActive) {
        self.floatingBackdropTap.additionalProtectedFrame =
            [self floatingKeyboardInteractionFrame];
        return;
    }
    self.floatingKeyboardInteractionSessionActive = YES;
    self.floatingKeyboardInteractionGeneration += 1;
    NSUInteger generation = self.floatingKeyboardInteractionGeneration;
    CGRect protectedFrame = [self floatingKeyboardInteractionFrame];
    self.floatingBackdropTap.additionalProtectedFrame = protectedFrame;

    // A responder can fail to present a keyboard. Do not leave the lower screen
    // permanently protected if no keyboard frame arrives for this session.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation == self.floatingKeyboardInteractionGeneration &&
            self.floatingKeyboardInteractionSessionActive &&
            !self.floatingKeyboardVisible) {
            [self applyKeyboardFrame:CGRectNull visible:NO];
        }
    });
}

- (void)endFloatingKeyboardInteractionSession {
    self.floatingKeyboardInteractionGeneration += 1;
    self.floatingKeyboardInteractionSessionActive = NO;
}

- (void)keyboardFrameWillChange:(NSNotification *)notification {
    NSValue *frameValue = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (![frameValue isKindOfClass:[NSValue class]]) {
        return;
    }
    CGRect frame = frameValue.CGRectValue;
    CGRect bounds = FLMVisualScreenBounds();
    BOOL visible = CGRectIntersectsRect(bounds, frame) &&
                   CGRectGetMinY(frame) < CGRectGetHeight(bounds);
    if (visible) {
        [self applyKeyboardFrame:frame visible:YES];
    }
}

- (void)keyboardDidHide:(NSNotification *)notification {
    (void)notification;
    [self applyKeyboardFrame:CGRectNull visible:NO];
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
            if (([existingCandidate respondsToSelector:@selector(sceneIfExists)] ||
                 [existingCandidate respondsToSelector:@selector(scene)]) &&
                [self sceneForHandle:existingCandidate]) {
                return (FLMApplicationSceneHandle *)existingCandidate;
            }
            // Do not keep polling a handle whose primary scene was replaced
            // during cold launch.  This was the main source of the permanent
            // "Launching application" card on iOS 16.
            self.floatingSceneEntity = nil;
            self.floatingSceneHandle = nil;
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
        // First let the normal suspended launch create its own primary scene.
        // Forcing one synchronously races UIKit's scene connection and often
        // yields a valid handle with a black, never-ready surface.  Only ask
        // SpringBoard to generate a scene after a bounded grace period.
        BOOL generatePrimaryScene =
            self.floatingLaunchStartedAt > 0.0 &&
            CACurrentMediaTime() - self.floatingLaunchStartedAt >=
                FLMFloatingSceneGenerationDelay;
        FLMDeviceApplicationSceneEntity *entity =
            [(FLMDeviceApplicationSceneEntity *)allocatedEntity
                initWithApplicationForMainDisplay:application
                generatingNewPrimarySceneIfRequired:generatePrimaryScene];
        if (!entity ||
            ![entity respondsToSelector:@selector(sceneHandle)]) {
            return nil;
        }
        id candidate = [entity sceneHandle];
        if (![candidate respondsToSelector:@selector(sceneIfExists)] &&
            ![candidate respondsToSelector:@selector(scene)]) {
            return nil;
        }
        if (generatePrimaryScene || [self sceneForHandle:candidate]) {
            self.floatingSceneEntity = entity;
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
        CGRect screenBounds = FLMVisualScreenBounds();
        if ([mutableSettings respondsToSelector:@selector(setFrame:)] &&
            !CGRectIsEmpty(screenBounds)) {
            [mutableSettings setFrame:CGRectMake(0.0,
                                                  0.0,
                                                  CGRectGetWidth(screenBounds),
                                                  CGRectGetHeight(screenBounds))];
        }
        NSInteger orientation = (NSInteger)FLMActiveInterfaceOrientation();
        if (orientation >= 1 && orientation <= 4 &&
            [mutableSettings respondsToSelector:
                                 @selector(setInterfaceOrientation:)]) {
            [mutableSettings setInterfaceOrientation:orientation];
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
    BOOL sceneChanged = scene && scene != self.floatingScene;
    if (sceneChanged) {
        FLMKeyboardDiagnosticLog(
            @"floating-scene-changed app=%@ old=%@ new=%@ launchGen=%lu",
            self.floatingIdentifier ?: @"<none>",
            FLMSceneIdentifier(self.floatingScene) ?: @"<none>",
            FLMSceneIdentifier(scene) ?: @"<none>",
            (unsigned long)self.floatingLaunchGeneration);
    }
    if (![self prepareFloatingScene:scene handle:sceneHandle]) {
        return nil;
    }
    self.floatingScene = scene;
    FLMPublishKeyboardState(self.floatingIdentifier, scene);
    FLMKeyboardDiagnosticLog(
        @"floating-scene-published app=%@ scene=%@ changed=%d launchGen=%lu",
        self.floatingIdentifier ?: @"<none>",
        FLMSceneIdentifier(scene) ?: @"<none>", sceneChanged,
        (unsigned long)self.floatingLaunchGeneration);
    self.floatingHostReferenceSize = [self floatingSceneReferenceSize];

    // Let the foreground/frame settings reach the application process before
    // creating the remote presenter. Creating both in the same transaction is
    // fast on a warm app but intermittently leaves a permanently black surface
    // during cold launch.
    if (sceneChanged) {
        self.floatingScenePreparedAt = CACurrentMediaTime();
        self.floatingLaunchState = FLMFloatingLaunchStateWaitingForPresenter;
        return nil;
    }
    if (self.floatingScenePreparedAt > 0.0 &&
        CACurrentMediaTime() - self.floatingScenePreparedAt <
            FLMFloatingSceneSettleDelay) {
        return nil;
    }

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
    self.floatingLaunchState = FLMFloatingLaunchStateAttached;
    FLMKeyboardDiagnosticLog(
        @"floating-host-attached app=%@ scene=%@ host=%p launchGen=%lu",
        self.floatingIdentifier ?: @"<none>",
        FLMSceneIdentifier(scene) ?: @"<none>", (__bridge void *)host,
        (unsigned long)self.floatingLaunchGeneration);
    return host;
}

- (void)openFloatingIdentifier:(NSString *)identifier {
    if (identifier.length == 0 || FLMDeviceIsLocked()) {
        self.prewarmedIdentifier = nil;
        return;
    }
    if (!self.floatingWindow.hidden && self.floatingIdentifier.length > 0 &&
        [identifier isEqualToString:self.floatingIdentifier]) {
        self.prewarmedIdentifier = nil;
        return;
    }
    if (!self.floatingWindow.hidden && self.floatingIdentifier.length > 0) {
        NSString *pendingIdentifier = [identifier copy];
        BOOL pendingWasPrewarmed =
            [self.prewarmedIdentifier isEqualToString:pendingIdentifier];
        [self closeFloatingWindowKeepingApplication:YES];
        self.prewarmedIdentifier =
            pendingWasPrewarmed ? pendingIdentifier : nil;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.26 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                [self openFloatingIdentifier:pendingIdentifier];
            });
        return;
    }
    if ([identifier isEqualToString:FLMFrontmostApplicationIdentifier()]) {
        self.prewarmedIdentifier = nil;
        return;
    }

    BOOL alreadyPrewarmed =
        [self.prewarmedIdentifier isEqualToString:identifier];
    self.prewarmedIdentifier = nil;

    self.floatingDockWidth = FLMMinimumDockWidth;
    self.floatingReconnectSuppressed = NO;
    self.floatingDocked = NO;
    self.floatingDockedOnRight = YES;
    self.floatingExternalActivationArmed = NO;
    self.lastObservedFrontmostIdentifier = nil;
    self.floatingDockTransitionActive = NO;
    self.floatingResizeCenterReady = NO;
    [self setFloatingDockReady:NO animated:NO];
    ((FLMFloatingWindow *)self.floatingWindow)
        .passesTouchesOutsideFloatingContent = NO;
    self.floatingDockTap.enabled = NO;
    self.floatingDockDragPress.enabled = NO;
    self.floatingResizePress.enabled = NO;
    self.floatingDockInputGesture.enabled = NO;
    self.floatingDockInputGeneration += 1;
    self.floatingResizeHandle.hidden = YES;
    self.floatingResizeHandle.alpha = 0.0;
    self.floatingDockShadowView.hidden = YES;
    self.floatingDockShadowView.alpha = 0.0;
    self.floatingDockShadowView.transform = CGAffineTransformIdentity;
    self.floatingDockInteractionShield.hidden = YES;
    self.floatingDockInteractionShield.userInteractionEnabled = NO;
    [self restoreFloatingHandleInteraction];
    self.floatingContainer.layer.borderWidth = 0.0;
    self.floatingInteractiveScenePrepared = NO;
    self.floatingInteractiveFullscreenTransition = NO;
    [self.floatingInteractiveSnapshot removeFromSuperview];
    self.floatingInteractiveSnapshot = nil;
    self.floatingInteractiveSnapshotBackground = nil;
    self.floatingInteractiveSnapshotContent = nil;
    self.floatingFullscreenProgress = 0.0;
    self.floatingKeyboardInteractionGeneration += 1;
    self.floatingKeyboardInteractionSessionActive = NO;
    self.floatingKeyboardVisible = NO;
    self.floatingKeyboardFrame = CGRectNull;
    self.floatingExclusiveTapEligible = NO;
    self.floatingBackdropTap.additionalProtectedFrame = CGRectNull;
    ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame = CGRectNull;
    self.floatingLaunchGeneration += 1;
    NSUInteger generation = self.floatingLaunchGeneration;
    self.floatingLaunchState = FLMFloatingLaunchStatePrewarming;
    self.floatingLaunchStartedAt = CACurrentMediaTime();
    self.floatingScenePreparedAt = 0.0;
    [self.floatingHostView removeFromSuperview];
    self.floatingHostView = nil;
    self.floatingHostReferenceSize = CGSizeZero;
    self.floatingSceneEntity = nil;
    self.floatingSceneHandle = nil;
    self.floatingScene = nil;
    self.floatingPresentationManager = nil;
    self.floatingPresenter = nil;
    self.floatingIdentifier = identifier;
    FLMKeyboardDiagnosticLog(
        @"floating-open app=%@ launchGen=%lu previousActiveHost=%p reusableHost=%p "
         "leaseScene=%@",
        identifier, (unsigned long)generation,
        (__bridge void *)self.floatingKeyboardLayerHostView,
        (__bridge void *)self.floatingReusableKeyboardLayerHostView,
        self.floatingReusableKeyboardSceneIdentifier ?: @"<none>");
    FLMPublishKeyboardState(identifier, nil);
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
    [UIView animateWithDuration:0.40
                          delay:0.0
         usingSpringWithDamping:0.84
          initialSpringVelocity:0.30
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         self.floatingDimView.alpha = 1.0;
                         self.floatingContainer.alpha = 1.0;
                         self.floatingContainer.transform = CGAffineTransformIdentity;
                         self.floatingHandle.alpha = 1.0;
                     }
                     completion:nil];

    if (!alreadyPrewarmed) {
        FLMPrewarmApplicationIdentifier(identifier);
    }
    [self beginLockMonitoring];
    // Let UIKit publish its normal primary scene before querying an entity.
    // Creating both transactions in the same run-loop turn is racy on iOS 16.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self attachFloatingIdentifier:identifier
                            generation:generation
                               attempt:0];
    });
}

- (void)attachFloatingIdentifier:(NSString *)identifier
                      generation:(NSUInteger)generation
                         attempt:(NSUInteger)attempt {
    if (generation != self.floatingLaunchGeneration ||
        ![identifier isEqualToString:self.floatingIdentifier] ||
        self.floatingWindow.hidden) {
        return;
    }
    if (self.floatingLaunchStartedAt <= 0.0) {
        self.floatingLaunchStartedAt = CACurrentMediaTime();
    }
    if (CACurrentMediaTime() - self.floatingLaunchStartedAt >
        FLMFloatingLaunchTimeout) {
        [self failFloatingLaunchForIdentifier:identifier generation:generation];
        return;
    }
    FLMApplicationSceneHandle *sceneHandle =
        [self sceneHandleForIdentifier:identifier];
    if (!sceneHandle) {
        self.floatingLaunchState = FLMFloatingLaunchStateWaitingForScene;
        self.floatingStatusLabel.text = @"正在准备应用…";
        if (attempt < 60) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [self attachFloatingIdentifier:identifier
                                        generation:generation
                                           attempt:attempt + 1];
                });
            return;
        }
        [self failFloatingLaunchForIdentifier:identifier generation:generation];
        return;
    }

    if (![self sceneForHandle:sceneHandle]) {
        self.floatingLaunchState = FLMFloatingLaunchStateWaitingForScene;
        self.floatingStatusLabel.text = @"正在启动应用…";
        if (attempt > 0 && attempt % 5 == 0) {
            // A generated primary-scene entity can retain a handle whose scene
            // was replaced during application launch. Resolve a fresh entity
            // instead of polling the dead handle for the full timeout.
            self.floatingSceneEntity = nil;
            self.floatingSceneHandle = nil;
        }
        if (attempt == 8) {
            FLMPrewarmApplicationIdentifier(identifier);
        }
        if (attempt < 60) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [self attachFloatingIdentifier:identifier
                                        generation:generation
                                           attempt:attempt + 1];
                });
            return;
        }
        [self failFloatingLaunchForIdentifier:identifier generation:generation];
        return;
    }

    UIView *host = [self hostViewForSceneHandle:sceneHandle];
    if (!host) {
        self.floatingLaunchState = FLMFloatingLaunchStateWaitingForPresenter;
        self.floatingStatusLabel.text = @"正在连接画面…";
        if (attempt > 0 && attempt % 6 == 0) {
            id stalePresenter = self.floatingPresenter;
            @try {
                if ([stalePresenter respondsToSelector:@selector(deactivate)]) {
                    [stalePresenter deactivate];
                }
                if ([stalePresenter respondsToSelector:@selector(invalidate)]) {
                    [stalePresenter invalidate];
                }
            } @catch (__unused NSException *exception) {
            }
            self.floatingPresentationManager = nil;
            self.floatingPresenter = nil;
        }
        if (attempt < 60) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [self attachFloatingIdentifier:identifier
                                        generation:generation
                                           attempt:attempt + 1];
                });
            return;
        }
        [self failFloatingLaunchForIdentifier:identifier generation:generation];
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

- (void)failFloatingLaunchForIdentifier:(NSString *)identifier
                              generation:(NSUInteger)generation {
    if (generation != self.floatingLaunchGeneration ||
        self.floatingWindow.hidden) {
        return;
    }
    // Invalidate delayed retries before releasing the protection lease.  A
    // retry from a prior launch must never attach a replaced primary scene.
    self.floatingLaunchState = FLMFloatingLaunchStateFailing;
    self.floatingReconnectSuppressed = YES;
    [self closeFloatingWindowKeepingApplication:YES];
    [self activateIdentifierFullscreen:identifier];
}

- (void)closeFloatingWindowKeepingApplication:(BOOL)keepApplication {
    FLMKeyboardDiagnosticLog(
        @"floating-close-begin app=%@ scene=%@ launchGen=%lu keep=%d activeHost=%p "
         "reusableHost=%p leaseScene=%@ keyboardVisible=%d",
        self.floatingIdentifier ?: @"<none>",
        FLMSceneIdentifier(self.floatingScene) ?: @"<none>",
        (unsigned long)self.floatingLaunchGeneration, keepApplication,
        (__bridge void *)self.floatingKeyboardLayerHostView,
        (__bridge void *)self.floatingReusableKeyboardLayerHostView,
        self.floatingReusableKeyboardSceneIdentifier ?: @"<none>",
        self.floatingKeyboardVisible);
    [self.floatingHostView endEditing:YES];
    FLMPublishKeyboardState(nil, nil);
    self.floatingLaunchGeneration += 1;
    self.floatingLaunchState = FLMFloatingLaunchStateClosing;
    self.floatingLaunchStartedAt = 0.0;
    self.floatingScenePreparedAt = 0.0;
    [self.floatingInteractiveSnapshot removeFromSuperview];
    self.floatingInteractiveSnapshot = nil;
    self.floatingInteractiveSnapshotBackground = nil;
    self.floatingInteractiveSnapshotContent = nil;
    self.floatingFullscreenProgress = 0.0;
    [self scheduleFloatingKeyboardLayerHostDetach];
    self.floatingKeyboardInteractionGeneration += 1;
    self.floatingKeyboardInteractionSessionActive = NO;
    self.floatingInteractiveScenePrepared = NO;
    self.floatingInteractiveFullscreenTransition = NO;
    self.floatingDocked = NO;
    self.floatingDockTransitionActive = NO;
    self.floatingExternalActivationArmed = NO;
    self.lastObservedFrontmostIdentifier = nil;
    self.floatingResizeCenterReady = NO;
    [self setFloatingDockReady:NO animated:NO];
    ((FLMFloatingWindow *)self.floatingWindow)
        .passesTouchesOutsideFloatingContent = NO;
    self.floatingBackdropTap.enabled = YES;
    self.floatingDockTap.enabled = NO;
    self.floatingDockDragPress.enabled = NO;
    self.floatingResizePress.enabled = NO;
    self.floatingDockInputGesture.enabled = NO;
    self.floatingDockInputGeneration += 1;
    self.floatingResizeHandle.hidden = YES;
    self.floatingResizeHandle.alpha = 0.0;
    self.floatingDockShadowView.hidden = YES;
    self.floatingDockShadowView.alpha = 0.0;
    self.floatingDockShadowView.transform = CGAffineTransformIdentity;
    self.floatingDockInteractionShield.hidden = YES;
    self.floatingDockInteractionShield.userInteractionEnabled = NO;
    self.floatingHandle.hidden = NO;
    self.floatingContainer.layer.borderWidth = 0.0;
    self.floatingContainer.transform = CGAffineTransformIdentity;
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
    self.floatingExclusiveTapEligible = NO;
    self.cornerGuardGesture.enabled = self.enabled;
    self.cornerGesture.enabled = self.enabled;
    self.previousKeyWindow = nil;
    self.floatingKeyboardVisible = NO;
    self.floatingKeyboardFrame = CGRectNull;
    self.floatingBackdropTap.additionalProtectedFrame = CGRectNull;
    ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame = CGRectNull;
    if (previousKeyWindow && previousKeyWindow != self.floatingWindow) {
        [previousKeyWindow makeKeyWindow];
    }
    if (self.floatingWindow.hidden) {
        [self.floatingHostView removeFromSuperview];
        self.floatingHostView = nil;
        if (keepApplication) {
            [self backgroundFloatingScene:scene];
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
        self.floatingLaunchState = FLMFloatingLaunchStateIdle;
        [self stopLockMonitoringIfIdle];
        return;
    }

    [UIView animateWithDuration:0.24
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         self.floatingDimView.alpha = 0.0;
                         self.floatingContainer.alpha = 0.0;
                         self.floatingHandle.alpha = 0.0;
                         self.floatingDockShadowView.alpha = 0.0;
                         self.floatingResizeHandle.alpha = 0.0;
                     }
                     completion:^(BOOL finished) {
                         (void)finished;
                         if (generation != self.floatingLaunchGeneration) {
                             return;
                         }
                           [self.floatingHostView removeFromSuperview];
                           self.floatingHostView = nil;
                           if (keepApplication) {
                               [self backgroundFloatingScene:scene];
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
                           self.floatingWindow.hidden = YES;
                         self.floatingLaunchState = FLMFloatingLaunchStateIdle;
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
    if (self.floatingDocked && !self.floatingWindow.hidden &&
        self.floatingIdentifier.length > 0) {
        NSString *frontmostIdentifier = FLMFrontmostApplicationIdentifier();
        BOOL targetIsFrontmost =
            [frontmostIdentifier isEqualToString:self.floatingIdentifier];
        BOOL targetWasFrontmost =
            [self.lastObservedFrontmostIdentifier
                isEqualToString:self.floatingIdentifier];
        if (!targetIsFrontmost) {
            self.floatingExternalActivationArmed = YES;
        }
        self.lastObservedFrontmostIdentifier = frontmostIdentifier;
        if (self.floatingExternalActivationArmed && targetIsFrontmost &&
            !targetWasFrontmost) {
            // The docked app was opened by SpringBoard. Release only our
            // presenter; backgrounding here would black out the fullscreen app.
            self.floatingReconnectSuppressed = YES;
            [self closeFloatingWindowKeepingApplication:NO];
            return;
        }
    }
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
    if (!self.floatingWindow.hidden && self.floatingIdentifier.length > 0 &&
        [identifier isEqualToString:self.floatingIdentifier]) {
        self.prewarmedIdentifier = nil;
        return;
    }
    if ([identifier isEqualToString:FLMFrontmostApplicationIdentifier()]) {
        self.prewarmedIdentifier = nil;
        return;
    }
    [self openFloatingIdentifier:identifier];
}

@end

%hook _UIKeyboardLayerHostView

- (void)scene:(id)scene
    didUpdateClientSettingsWithDiff:(id)diff
                  oldClientSettings:(id)oldClientSettings
                  transitionContext:(id)transitionContext {
    // Let UIKit finish pairing first, then move only the paired keyboard host
    // into a physical-screen overlay. The application Scene remains at the
    // stable card size and is never expanded or rescaled for keyboard layout.
    FLMWheelController *controller = [FLMWheelController sharedController];
    uintptr_t hostAddress = (uintptr_t)(__bridge void *)self;
    NSString *queuedSceneIdentifier =
        [FLMSceneIdentifier(scene) copy] ?: @"<none>";
    __weak UIView *weakHostView = (UIView *)self;
    __weak id weakUpdatedScene = scene;
    FLMKeyboardDiagnosticLog(
        @"hook-callback-enter host=0x%llx updatedScene=%@",
        (unsigned long long)hostAddress, queuedSceneIdentifier);
    [controller prepareFloatingKeyboardHostIfNeeded];
    %orig;
    FLMKeyboardDiagnosticLog(
        @"hook-callback-queued host=0x%llx updatedScene=%@",
        (unsigned long long)hostAddress, queuedSceneIdentifier);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *hostView = weakHostView;
        id updatedScene = weakUpdatedScene;
        if (!hostView) {
            FLMKeyboardDiagnosticLog(
                @"hook-callback-expired host=0x%llx updatedScene=%@",
                (unsigned long long)hostAddress, queuedSceneIdentifier);
            return;
        }
        FLMKeyboardDiagnosticLog(
            @"hook-callback-execute host=%p queuedHost=0x%llx updatedScene=%@",
            (__bridge void *)hostView, (unsigned long long)hostAddress,
            FLMSceneIdentifier(updatedScene) ?: queuedSceneIdentifier);
        [controller keyboardLayerHostView:hostView
                        didUpdateForScene:updatedScene];
    });
}

%end

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
