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

@interface NSObject (FLMRuntimePrivate)
+ (id)defaultWorkspace;
+ (id)sharedInstance;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleIdentifier;
- (void)lockUIFromSource:(NSInteger)source withOptions:(id)options;
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
- (id)applicationSceneHandle;
@end

@interface FLMApplicationSceneHandle : NSObject
- (NSInteger)currentInterfaceOrientation;
- (id)sceneIfExists;
- (id)scene;
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

@interface FLMWheelItemView : UIView
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, assign) BOOL highlighted;
@end

@implementation FLMWheelItemView

- (instancetype)initWithIdentifier:(NSString *)identifier image:(UIImage *)image {
    self = [super initWithFrame:CGRectMake(0.0, 0.0, 56.0, 56.0)];
    if (self) {
        _identifier = [identifier copy];
        BOOL isLockItem = [identifier isEqualToString:FLYME_LOCK_SCREEN_ITEM];
        self.backgroundColor = isLockItem ? [UIColor systemBlueColor] : [UIColor clearColor];
        self.layer.cornerRadius = 28.0;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.22;
        self.layer.shadowRadius = 8.0;
        self.layer.shadowOffset = CGSizeMake(0.0, 3.0);
        self.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:self.bounds].CGPath;

        _iconView = [[UIImageView alloc] initWithImage:image];
        _iconView.frame = isLockItem ? CGRectInset(self.bounds, 15.0, 15.0) : self.bounds;
        _iconView.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _iconView.contentMode =
            isLockItem ? UIViewContentModeScaleAspectFit : UIViewContentModeScaleAspectFill;
        _iconView.clipsToBounds = YES;
        _iconView.layer.cornerRadius = isLockItem ? 0.0 : 28.0;
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
@property(nonatomic, strong) UITapGestureRecognizer *floatingBackdropTap;
@property(nonatomic, strong) UIPanGestureRecognizer *floatingHandlePan;
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
@property(nonatomic, assign) CGPoint cornerGestureStartPoint;
@property(nonatomic, copy) NSString *floatingIdentifier;
@property(nonatomic, strong) FLMApplicationSceneHandle *floatingSceneHandle;
@property(nonatomic, strong) id floatingScene;
@property(nonatomic, strong) id floatingPresentationManager;
@property(nonatomic, strong) id floatingPresenter;
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
- (void)handleFloatingBackdropTap:(UITapGestureRecognizer *)gesture;
- (void)handleFloatingHandlePan:(UIPanGestureRecognizer *)gesture;
- (void)handleFloatingExclusiveGesture:(UIGestureRecognizer *)gesture;
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
        [self createWindows];
        [self reloadPreferences];
    });
}

- (void)createWindows {
    CGRect bounds = [UIScreen mainScreen].bounds;
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
    self.floatingExclusiveGesture.cancelsTouchesInView = YES;
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
    CGRect bounds = [UIScreen mainScreen].bounds;
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
        [[UITapGestureRecognizer alloc] initWithTarget:self
                                               action:@selector(handleFloatingBackdropTap:)];
    self.floatingBackdropTap.delegate = self;
    self.floatingBackdropTap.cancelsTouchesInView = NO;
    self.floatingBackdropTap.delaysTouchesBegan = NO;
    self.floatingBackdropTap.delaysTouchesEnded = NO;
    [self.floatingWindow.rootViewController.view
        addGestureRecognizer:self.floatingBackdropTap];

    self.floatingHandlePan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                action:@selector(handleFloatingHandlePan:)];
    self.floatingHandlePan.cancelsTouchesInView = YES;
    [self.floatingHandle addGestureRecognizer:self.floatingHandlePan];
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
    self.enabled = [enabledValue isKindOfClass:[NSNumber class]] && [enabledValue boolValue];
    self.itemIdentifiers =
        [itemsValue isKindOfClass:[NSArray class]] ? [itemsValue copy] : @[];
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
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateWindowFrames];
    });
}

- (void)updateWindowFrames {
    CGRect bounds = [UIScreen mainScreen].bounds;
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
    CGRect bounds = [UIScreen mainScreen].bounds;
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
        CGPoint point =
            [touch locationInView:self.floatingWindow.rootViewController.view];
        return !self.floatingWindow.hidden &&
               !CGRectContainsPoint(self.floatingContainer.frame, point) &&
               !CGRectContainsPoint(CGRectInset(self.floatingHandle.frame, -18.0, -18.0),
                                     point);
    }
    if (gestureRecognizer == self.floatingExclusiveGesture) {
        if (self.floatingWindow.hidden || FLMDeviceIsLocked()) {
            return NO;
        }
        CGPoint point =
            [touch locationInView:self.floatingWindow.rootViewController.view];
        CGRect handleHitFrame = CGRectInset(self.floatingHandle.frame, -22.0, -20.0);
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
        CGPoint point = [touch locationInView:nil];
        return FLMPointInsideCornerTrigger(point,
                                           [UIScreen mainScreen].bounds,
                                           NULL);
    }
    if (!self.enabled || self.wheelPinned || self.itemIdentifiers.count == 0) {
        return NO;
    }
    if (FLMDeviceIsLocked()) {
        return NO;
    }
    CGRect bounds = [UIScreen mainScreen].bounds;
    CGPoint point = [touch locationInView:nil];
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
    CGPoint point = [gesture locationInView:nil];
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            [self updateHighlightForPoint:point];
            break;
        case UIGestureRecognizerStateEnded: {
            FLMWheelItemView *item =
                [self itemNearPoint:point maximumDistance:30.0];
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
    CGPoint point = [gesture locationInView:nil];

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
    CGRect bounds = [UIScreen mainScreen].bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    CGPoint anchor = CGPointMake(fromRight ? width - 4.0 : 4.0, height - 4.0);
    NSArray<NSNumber *> *ringCounts =
        [self itemCountsByRingForCount:self.itemIdentifiers.count];
    CGFloat fullStartAngle = -82.0 * (CGFloat)M_PI / 180.0;
    CGFloat fullEndAngle = -10.0 * (CGFloat)M_PI / 180.0;
    CGFloat fullAngleSpan = fullEndAngle - fullStartAngle;
    CGFloat safeCenterMargin = 38.0;
    CGFloat maximumRadiusByWidth =
        (width - 4.0 - safeCenterMargin) / cos(fullEndAngle);
    CGFloat maximumRadiusByHeight =
        (height - 4.0 - safeCenterMargin) / fabs(sin(fullStartAngle));
    CGFloat maximumRadius = MAX(120.0, MIN(maximumRadiusByWidth,
                                           maximumRadiusByHeight));
    CGFloat firstRadius = MIN(202.0, maximumRadius);
    CGFloat ringSpacing = 0.0;
    if (ringCounts.count > 1) {
        CGFloat ringIntervals = (CGFloat)(ringCounts.count - 1);
        CGFloat desiredSpacing = 76.0;
        CGFloat desiredOuterRadius = firstRadius + desiredSpacing * ringIntervals;
        if (desiredOuterRadius <= maximumRadius) {
            ringSpacing = desiredSpacing;
        } else {
            firstRadius =
                MIN(firstRadius, MAX(132.0, maximumRadius - 62.0 * ringIntervals));
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
                                                       image:FLMApplicationIcon(identifier)];
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
    FLMWheelItemView *nearest = [self itemNearPoint:point maximumDistance:30.0];
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
    FLMWheelItemView *item = [self itemNearPoint:point maximumDistance:30.0];
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

- (void)handleFloatingBackdropTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded ||
        self.floatingWindow.hidden) {
        return;
    }
    [self closeFloatingWindowKeepingApplication:YES];
}

- (void)handleFloatingExclusiveGesture:(UIGestureRecognizer *)gesture {
    if (self.floatingWindow.hidden) {
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded) {
        [self closeFloatingWindowKeepingApplication:YES];
    }
}

- (void)handleFloatingHandlePan:(UIPanGestureRecognizer *)gesture {
    if (self.floatingWindow.hidden) {
        return;
    }
    CGPoint translation =
        [gesture translationInView:self.floatingWindow.rootViewController.view];
    CGFloat visualOffset = MAX(-8.0, MIN(14.0, translation.y * 0.18));
    if (gesture.state == UIGestureRecognizerStateBegan ||
        gesture.state == UIGestureRecognizerStateChanged) {
        self.floatingHandleBar.transform =
            CGAffineTransformMakeTranslation(0.0, visualOffset);
        return;
    }
    [UIView animateWithDuration:0.30
                          delay:0.0
         usingSpringWithDamping:0.72
          initialSpringVelocity:0.35
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         self.floatingHandleBar.transform =
                             CGAffineTransformIdentity;
                     }
                     completion:nil];
    if (gesture.state == UIGestureRecognizerStateEnded &&
        translation.y >= 46.0 &&
        fabs(translation.y) > fabs(translation.x) * 1.15) {
        NSString *identifier = [self.floatingIdentifier copy];
        [self closeFloatingWindowKeepingApplication:YES];
        [self activateIdentifierFullscreen:identifier];
    }
}

- (void)protectedSceneDidDisappear:(NSNotification *)notification {
    (void)notification;
    if (!self.floatingWindow.hidden) {
        [self closeFloatingWindowKeepingApplication:YES];
    }
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
    CGFloat top = MAX(safeInsets.top, width > height ? 12.0 : 10.0);
    CGFloat containerWidth = width * 0.77;
    CGFloat containerHeight = containerWidth * (height / width);
    CGFloat maximumHeight = MAX(180.0, height - top - 72.0);
    if (containerHeight > maximumHeight) {
        CGFloat scale = maximumHeight / containerHeight;
        containerHeight = maximumHeight;
        containerWidth *= scale;
    }
    CGFloat originX = floor((width - containerWidth) * 0.5);
    self.floatingContainer.frame =
        CGRectMake(originX, top, containerWidth, containerHeight);
    self.floatingHostView.frame = self.floatingContainer.bounds;
    self.floatingStatusLabel.frame = self.floatingContainer.bounds;

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

- (FLMApplicationSceneHandle *)sceneHandleForIdentifier:(NSString *)identifier {
    if (identifier.length == 0) {
        return nil;
    }
    @try {
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
        if (![application respondsToSelector:
                             @selector(applicationSceneHandle)]) {
            return nil;
        }
        id candidate = [application applicationSceneHandle];
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
    id manager = nil;
    id presenter = nil;
    UIView *host = nil;
    @try {
        if ([scene respondsToSelector:@selector(uiPresentationManager)]) {
            manager = [scene uiPresentationManager];
        }
        if (!manager &&
            [scene respondsToSelector:@selector(presentationManager)]) {
            manager = [scene presentationManager];
        }
        if (![manager respondsToSelector:
                         @selector(createPresenterWithIdentifier:)]) {
            return nil;
        }
        presenter =
            [manager createPresenterWithIdentifier:
                         @"com.codex.flymemultitasking.centered"];
        if ([presenter respondsToSelector:@selector(activate)]) {
            [presenter activate];
        }
        if ([presenter respondsToSelector:@selector(presentationView)]) {
            host = [presenter presentationView];
        }
    } @catch (__unused NSException *exception) {
        host = nil;
    }
    if (![host isKindOfClass:[UIView class]]) {
        @try {
            if ([presenter respondsToSelector:@selector(deactivate)]) {
                [presenter deactivate];
            }
            if ([presenter respondsToSelector:@selector(invalidate)]) {
                [presenter invalidate];
            }
        } @catch (__unused NSException *exception) {
        }
        return nil;
    }
    self.floatingScene = scene;
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

    self.floatingLaunchGeneration += 1;
    NSUInteger generation = self.floatingLaunchGeneration;
    [self.floatingHostView removeFromSuperview];
    self.floatingHostView = nil;
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
        [self backgroundFloatingScene:[self sceneForHandle:sceneHandle]];
        [self closeFloatingWindowKeepingApplication:YES];
        [self activateIdentifierFullscreen:identifier];
        return;
    }
    self.floatingSceneHandle = sceneHandle;
    self.floatingHostView = host;
    host.frame = self.floatingContainer.bounds;
    host.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.floatingContainer insertSubview:host atIndex:0];
    self.floatingStatusLabel.hidden = YES;
}

- (void)closeFloatingWindowKeepingApplication:(BOOL)keepApplication {
    self.floatingLaunchGeneration += 1;
    NSUInteger generation = self.floatingLaunchGeneration;
    id scene = self.floatingScene;
    id presenter = self.floatingPresenter;
    UIWindow *previousKeyWindow = self.previousKeyWindow;
    self.floatingSceneHandle = nil;
    self.floatingScene = nil;
    self.floatingPresentationManager = nil;
    self.floatingPresenter = nil;
    self.floatingIdentifier = nil;
    self.floatingExclusiveGesture.enabled = NO;
    self.cornerGuardGesture.enabled = self.enabled;
    self.cornerGesture.enabled = self.enabled;
    self.previousKeyWindow = nil;
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
