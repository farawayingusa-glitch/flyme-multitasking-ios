#import <UIKit/UIKit.h>
#import <math.h>
#import <notify.h>
#import <stdint.h>
#import <unistd.h>

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
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat triggerWidth = MIN(220.0, MAX(170.0, width * 0.32));
    CGFloat triggerHeight = MIN(280.0, MAX(220.0, height * 0.42));
    BOOL insideBottom = point.y >= height - triggerHeight;
    BOOL insideLeft = point.x <= triggerWidth;
    BOOL insideRight = point.x >= width - triggerWidth;
    if (!insideBottom || (!insideLeft && !insideRight)) {
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
@property(nonatomic, strong) FLMCornerGestureRecognizer *cornerGesture;
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
+ (instancetype)sharedController;
- (void)start;
- (void)reloadPreferences;
- (void)createWindows;
- (BOOL)registerGlobalCornerGesture;
- (void)updateWindowFrames;
- (void)orientationDidChange:(NSNotification *)notification;
- (void)handleCornerGesture:(UIGestureRecognizer *)gesture;
- (NSArray<NSNumber *> *)itemCountsByRingForCount:(NSUInteger)count;
- (void)presentWheelFromRight:(BOOL)fromRight;
- (void)updateHighlightForPoint:(CGPoint)point;
- (void)pinWheel;
- (void)handleWheelTap:(UITapGestureRecognizer *)gesture;
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
    [self.overlayWindow.rootViewController.view addGestureRecognizer:self.wheelTapGesture];

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
    self.cornerGesture.minimumPressDuration = 0.0;
    self.cornerGesture.allowableMovement = CGFLOAT_MAX;
    self.usesSystemGestureManager = [self registerGlobalCornerGesture];
    if (!self.usesSystemGestureManager) {
        [self.hotspotWindow.rootViewController.view addGestureRecognizer:self.cornerGesture];
    }
    [self updateWindowFrames];
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

    [manager addGestureRecognizer:self.cornerGesture toDisplayWithIdentity:identity];
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
    self.cornerGesture.enabled = self.enabled;
    self.hotspotWindow.hotspotsEnabled = self.enabled && !self.usesSystemGestureManager;
    self.hotspotWindow.hidden = !self.enabled || self.usesSystemGestureManager;
    if (!self.enabled) {
        [self dismissWheelLaunchingItem:nil];
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
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (!self.enabled || self.itemIdentifiers.count == 0) {
        return NO;
    }
    CGRect bounds = [UIScreen mainScreen].bounds;
    CGPoint point = [gestureRecognizer locationInView:nil];
    self.presentingFromRight = point.x >= CGRectGetMidX(bounds);
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    (void)gestureRecognizer;
    if (!self.enabled || self.itemIdentifiers.count == 0) {
        return NO;
    }
    CGRect bounds = [UIScreen mainScreen].bounds;
    CGPoint point = [touch locationInView:nil];
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    CGFloat triggerWidth = MIN(220.0, MAX(170.0, width * 0.32));
    CGFloat triggerHeight = MIN(280.0, MAX(220.0, height * 0.42));
    BOOL insideBottom = point.y >= height - triggerHeight;
    BOOL insideLeft = point.x <= triggerWidth;
    BOOL insideRight = point.x >= width - triggerWidth;
    self.presentingFromRight = insideRight && !insideLeft;
    return insideBottom && (insideLeft || insideRight);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return YES;
}

- (void)handleCornerGesture:(UIGestureRecognizer *)gesture {
    CGPoint point = [gesture locationInView:nil];

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            [self presentWheelFromRight:self.presentingFromRight];
            [self updateHighlightForPoint:point];
            break;
        case UIGestureRecognizerStateChanged:
            [self updateHighlightForPoint:point];
            break;
        case UIGestureRecognizerStateEnded:
            [self pinWheel];
            break;
        case UIGestureRecognizerStateCancelled:
            [self pinWheel];
            break;
        case UIGestureRecognizerStateFailed:
            [self dismissWheelLaunchingItem:nil];
            break;
        default:
            break;
    }
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
    CGFloat fullEndAngle = -25.0 * (CGFloat)M_PI / 180.0;
    CGFloat fullAngleSpan = fullEndAngle - fullStartAngle;
    CGFloat angleMidpoint = (fullStartAngle + fullEndAngle) * 0.5;
    CGFloat safeCenterMargin = 38.0;
    CGFloat maximumRadiusByWidth =
        (width - 4.0 - safeCenterMargin) / cos(fullEndAngle);
    CGFloat maximumRadiusByHeight =
        (height - 4.0 - safeCenterMargin) / fabs(sin(fullStartAngle));
    CGFloat maximumRadius = MAX(120.0, MIN(maximumRadiusByWidth,
                                           maximumRadiusByHeight));
    CGFloat firstRadius = MIN(190.0, maximumRadius);
    CGFloat ringSpacing = 0.0;
    if (ringCounts.count > 1) {
        CGFloat ringIntervals = (CGFloat)(ringCounts.count - 1);
        firstRadius = MIN(190.0, MAX(150.0, maximumRadius - 74.0 * ringIntervals));
        firstRadius = MIN(firstRadius, maximumRadius);
        ringSpacing = (maximumRadius - firstRadius) / ringIntervals;
    }

    NSUInteger itemIndex = 0;
    for (NSUInteger ring = 0; ring < ringCounts.count; ring++) {
        NSUInteger ringCount = ringCounts[ring].unsignedIntegerValue;
        CGFloat radius = firstRadius + (CGFloat)ring * ringSpacing;
        CGFloat occupiedAngleSpan =
            ringCount > 1
                ? MIN(fullAngleSpan, ((CGFloat)(ringCount - 1) * 68.0) / radius)
                : 0.0;
        CGFloat occupiedStartAngle = angleMidpoint - occupiedAngleSpan * 0.5;
        for (NSUInteger position = 0; position < ringCount; position++) {
            CGFloat fraction = ringCount == 1
                                   ? 0.5
                                   : (CGFloat)position / (CGFloat)(ringCount - 1);
            CGFloat angle = occupiedStartAngle + fraction * occupiedAngleSpan;
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
    FLMWheelItemView *nearest = [self itemNearPoint:point maximumDistance:72.0];
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
    FLMWheelItemView *item = [self itemNearPoint:point maximumDistance:38.0];
    [self dismissWheelLaunchingItem:item];
}

- (void)dismissWheelLaunchingItem:(FLMWheelItemView *)item {
    self.highlightedItem.highlighted = NO;
    self.highlightedItem = nil;
    self.wheelPinned = NO;
    self.overlayWindow.userInteractionEnabled = NO;
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

    id workspace = [NSClassFromString(@"LSApplicationWorkspace") defaultWorkspace];
    if ([workspace respondsToSelector:@selector(openApplicationWithBundleID:)] &&
        [workspace openApplicationWithBundleID:identifier]) {
        return;
    }
    UIApplication *application = [UIApplication sharedApplication];
    if ([application respondsToSelector:
                         @selector(launchApplicationWithIdentifier:suspended:)]) {
        [application launchApplicationWithIdentifier:identifier suspended:NO];
    }
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
