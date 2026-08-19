#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

#import "FLMDiagnostics.h"
#import "FLMLandscapeModule.h"

static NSString *const FLMLandscapePreferencesDomain =
    @"com.codex.flymelandscape";
static NSString *const FLMLandscapeLegacyPreferencesDomain =
    @"com.codex.flymemultitasking";
static NSString *const FLMLandscapeLegacyWheelItem =
    @"com.codex.flymemultitasking.screensense";
static const CGFloat FLMLandscapeDefaultWheelRadius = 202.0;
static const CGFloat FLMLandscapeMinimumWheelRadius = 170.0;
static const CGFloat FLMLandscapeMaximumWheelRadius = 225.0;
static const CGFloat FLMLandscapeDefaultWheelIconSize = 56.0;
static const CGFloat FLMLandscapeMinimumWheelIconSize = 44.0;
static const CGFloat FLMLandscapeMaximumWheelIconSize = 68.0;

@interface FLMLandscapeDisplayConfiguration : NSObject
- (id)identity;
@end

@interface UIScreen (FLMLandscapeWheelPrivate)
- (FLMLandscapeDisplayConfiguration *)displayConfiguration;
@end

@interface FLMLandscapeSystemGestureManager : NSObject
+ (instancetype)sharedInstance;
- (void)addGestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       toDisplayWithIdentity:(id)displayIdentity;
@end

@interface UIApplication (FLMLandscapeWheelPrivate)
- (BOOL)launchApplicationWithIdentifier:(NSString *)identifier
                              suspended:(BOOL)suspended;
- (void)_simulateLockButtonPress;
@end

@interface UIImage (FLMLandscapeWheelPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier
                                               format:(NSInteger)format
                                                scale:(CGFloat)scale;
@end

@interface NSObject (FLMLandscapeWheelWorkspacePrivate)
+ (id)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleIdentifier;
- (NSString *)bundleIdentifier;
- (NSString *)displayIdentifier;
@end

static BOOL FLMLandscapeWheelDeviceIsLocked(void) {
    id manager = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
    if (!manager) {
        return NO;
    }
    for (NSString *selectorName in
         @[@"isUILocked", @"isLockScreenVisible", @"isLockScreenActive",
           @"isLocked"]) {
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

static id FLMLandscapeWheelPreference(NSString *key) {
    for (NSString *domain in @[FLMLandscapePreferencesDomain,
                               FLMLandscapeLegacyPreferencesDomain]) {
        CFPreferencesSynchronize((__bridge CFStringRef)domain,
                                  kCFPreferencesCurrentUser,
                                  kCFPreferencesAnyHost);
        id value = CFBridgingRelease(CFPreferencesCopyAppValue(
            (__bridge CFStringRef)key,
            (__bridge CFStringRef)domain));
        if (value != nil) {
            return value;
        }
    }
    return nil;
}

static CGFloat FLMLandscapeWheelClamped(CGFloat value,
                                        CGFloat minimum,
                                        CGFloat maximum,
                                        CGFloat fallback) {
    if (!isfinite(value)) {
        return fallback;
    }
    return MAX(minimum, MIN(maximum, value));
}

static UIImage *FLMLandscapeWheelIcon(NSString *identifier) {
    if ([UIImage respondsToSelector:
                    @selector(_applicationIconImageForBundleIdentifier:
                                                  format:scale:)]) {
        UIImage *image =
            [UIImage _applicationIconImageForBundleIdentifier:identifier
                                                       format:0
                                                        scale:3.0];
        if (image) {
            return image;
        }
    }
    return nil;
}

@interface FLMLandscapeWheelItemView : UIView
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, assign, getter=isHighlighted) BOOL highlighted;
- (instancetype)initWithIdentifier:(NSString *)identifier
                              image:(UIImage *)image
                               size:(CGFloat)size;
@end

@implementation FLMLandscapeWheelItemView

- (instancetype)initWithIdentifier:(NSString *)identifier
                              image:(UIImage *)image
                               size:(CGFloat)size {
    self = [super initWithFrame:CGRectMake(0.0, 0.0, size, size)];
    if (!self) {
        return nil;
    }
    _identifier = [identifier copy];
    self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.94];
    self.layer.cornerRadius = size * 0.5;
    self.layer.masksToBounds = YES;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    self.userInteractionEnabled = NO;

    _iconView = [[UIImageView alloc] initWithFrame:CGRectMake(6.0,
                                                               6.0,
                                                               size - 12.0,
                                                               size - 12.0)];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.layer.cornerRadius = (size - 12.0) * 0.24;
    _iconView.layer.masksToBounds = YES;
    _iconView.image = image;
    [self addSubview:_iconView];
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    _highlighted = highlighted;
    self.layer.borderWidth = highlighted ? 3.0 : 1.0;
    self.layer.borderColor =
        (highlighted ? [UIColor whiteColor]
                     : [UIColor colorWithWhite:1.0 alpha:0.18]).CGColor;
    self.transform = highlighted
                         ? CGAffineTransformMakeScale(1.12, 1.12)
                         : CGAffineTransformIdentity;
}

@end

@interface FLMLandscapeCornerGestureRecognizer : UILongPressGestureRecognizer
@end

@implementation FLMLandscapeCornerGestureRecognizer

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

@interface FLMLandscapeWheelViewController : UIViewController
@end

@implementation FLMLandscapeWheelViewController

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end

@interface FLMLandscapeWheelWindow : UIWindow
@end

@implementation FLMLandscapeWheelWindow

- (BOOL)canBecomeKeyWindow {
    return NO;
}

@end

@interface FLMLandscapeWheelHotspotWindow : FLMLandscapeWheelWindow
@property(nonatomic, assign) BOOL hotspotsEnabled;
@end

@implementation FLMLandscapeWheelHotspotWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.hotspotsEnabled ||
        !FLMLandscapeModuleIsLandscape() ||
        !FLMLandscapeModulePointInsideCornerTrigger(point, self.bounds, NULL)) {
        return nil;
    }
    return [super hitTest:point withEvent:event];
}

@end

@interface FLMLandscapeWheelController : NSObject
<UIGestureRecognizerDelegate>
@property(nonatomic, strong) FLMLandscapeWheelWindow *overlayWindow;
@property(nonatomic, strong) FLMLandscapeWheelHotspotWindow *hotspotWindow;
@property(nonatomic, strong) UIView *wheelContainer;
@property(nonatomic, strong) FLMLandscapeCornerGestureRecognizer *guardGesture;
@property(nonatomic, strong) FLMLandscapeCornerGestureRecognizer *openerGesture;
@property(nonatomic, strong) FLMLandscapeCornerGestureRecognizer *modalGesture;
@property(nonatomic, strong) UITapGestureRecognizer *overlayTap;
@property(nonatomic, strong) NSArray<FLMLandscapeWheelItemView *> *itemViews;
@property(nonatomic, copy) NSArray<NSString *> *itemIdentifiers;
@property(nonatomic, weak) FLMLandscapeWheelItemView *highlightedItem;
@property(nonatomic, assign) CGFloat wheelRadius;
@property(nonatomic, assign) CGFloat wheelIconSize;
@property(nonatomic, assign) BOOL enabled;
@property(nonatomic, assign) BOOL wheelPinned;
@property(nonatomic, assign) BOOL wheelGestureActive;
@property(nonatomic, assign) BOOL presentingFromRight;
@property(nonatomic, assign) CGPoint startPoint;
@property(nonatomic, assign) FLMLandscapeTouchContext touchContext;
@property(nonatomic, assign) BOOL touchContextValid;
@property(nonatomic, assign) BOOL usesSystemGestureManager;
@property(nonatomic, assign) BOOL started;
+ (instancetype)sharedController;
- (void)start;
- (void)reloadPreferences;
- (void)updateFrames;
- (void)handleGuardGesture:(UIGestureRecognizer *)gesture;
- (void)handleOpenerGesture:(UIGestureRecognizer *)gesture;
- (void)handleModalGesture:(UIGestureRecognizer *)gesture;
- (void)handleOverlayTap:(UITapGestureRecognizer *)gesture;
- (void)createWindowsIfNeeded;
- (void)registerGlobalGestures;
- (BOOL)shouldActivateForPoint:(CGPoint)point;
- (void)presentWheelFromRight:(BOOL)fromRight;
- (void)updateHighlightForPoint:(CGPoint)point;
- (void)pinWheel;
- (void)dismissWheelLaunchingItem:(FLMLandscapeWheelItemView *)item;
- (FLMLandscapeWheelItemView *)itemNearPoint:(CGPoint)point;
@end

@implementation FLMLandscapeWheelController

+ (instancetype)sharedController {
    static FLMLandscapeWheelController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [[self alloc] init];
    });
    return controller;
}

- (void)start {
    if (self.started) {
        return;
    }
    self.started = YES;
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(orientationDidChange:)
               name:UIDeviceOrientationDidChangeNotification
             object:nil];
    [self createWindowsIfNeeded];
    [self reloadPreferences];
    [self registerGlobalGestures];
    [self updateFrames];
    FLMLandscapeModuleStart();
    FLMEnqueueDiagnosticLine(
        @"sb landscape-plugin-start globalGestures=%d items=%lu",
        self.usesSystemGestureManager,
        (unsigned long)self.itemIdentifiers.count);
}

- (void)createWindowsIfNeeded {
    if (self.overlayWindow) {
        return;
    }
    CGRect bounds = FLMLandscapeModuleVisualBounds();
    FLMLandscapeWheelViewController *controller =
        [[FLMLandscapeWheelViewController alloc] init];
    FLMLandscapeWheelWindow *window =
        [[FLMLandscapeWheelWindow alloc] initWithFrame:bounds];
    window.windowLevel = UIWindowLevelAlert + 96.0;
    window.backgroundColor = UIColor.clearColor;
    window.rootViewController = controller;
    window.hidden = YES;
    UIView *root = controller.view;
    root.backgroundColor = UIColor.clearColor;
    UIView *container = [[UIView alloc] initWithFrame:root.bounds];
    container.backgroundColor = UIColor.clearColor;
    container.userInteractionEnabled = YES;
    [root addSubview:container];
    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self
                                                action:@selector(handleOverlayTap:)];
    tap.enabled = NO;
    tap.cancelsTouchesInView = YES;
    [root addGestureRecognizer:tap];

    FLMLandscapeWheelHotspotWindow *hotspot =
        [[FLMLandscapeWheelHotspotWindow alloc] initWithFrame:bounds];
    hotspot.windowLevel = UIWindowLevelAlert + 120.0;
    hotspot.backgroundColor = UIColor.clearColor;
    hotspot.rootViewController =
        [[FLMLandscapeWheelViewController alloc] init];
    hotspot.hidden = YES;

    FLMLandscapeCornerGestureRecognizer *guard =
        [[FLMLandscapeCornerGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleGuardGesture:)];
    guard.delegate = self;
    guard.minimumPressDuration = 0.0;
    guard.allowableMovement = CGFLOAT_MAX;
    guard.cancelsTouchesInView = YES;
    guard.delaysTouchesBegan = NO;
    guard.delaysTouchesEnded = NO;

    FLMLandscapeCornerGestureRecognizer *opener =
        [[FLMLandscapeCornerGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleOpenerGesture:)];
    opener.delegate = self;
    opener.minimumPressDuration = 0.12;
    opener.allowableMovement = CGFLOAT_MAX;
    opener.cancelsTouchesInView = YES;
    opener.delaysTouchesBegan = NO;
    opener.delaysTouchesEnded = NO;

    FLMLandscapeCornerGestureRecognizer *modal =
        [[FLMLandscapeCornerGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleModalGesture:)];
    modal.delegate = self;
    modal.minimumPressDuration = 0.0;
    modal.allowableMovement = CGFLOAT_MAX;
    modal.cancelsTouchesInView = YES;
    modal.enabled = NO;

    [root addGestureRecognizer:modal];
    [hotspot.rootViewController.view addGestureRecognizer:guard];
    [hotspot.rootViewController.view addGestureRecognizer:opener];
    self.overlayWindow = window;
    self.hotspotWindow = hotspot;
    self.wheelContainer = container;
    self.guardGesture = guard;
    self.openerGesture = opener;
    self.modalGesture = modal;
    self.overlayTap = tap;
    self.itemViews = @[];
}

- (void)registerGlobalGestures {
    Class managerClass = NSClassFromString(@"_UISystemGestureManager");
    FLMLandscapeSystemGestureManager *manager =
        (FLMLandscapeSystemGestureManager *)[managerClass sharedInstance];
    FLMLandscapeDisplayConfiguration *configuration =
        [[UIScreen mainScreen] displayConfiguration];
    id identity = [configuration identity];
    SEL selector = @selector(addGestureRecognizer:toDisplayWithIdentity:);
    if (manager && identity && [manager respondsToSelector:selector]) {
        [manager addGestureRecognizer:self.guardGesture
                toDisplayWithIdentity:identity];
        [manager addGestureRecognizer:self.openerGesture
                toDisplayWithIdentity:identity];
        [manager addGestureRecognizer:self.modalGesture
                toDisplayWithIdentity:identity];
        self.usesSystemGestureManager = YES;
    } else {
        self.usesSystemGestureManager = NO;
        self.hotspotWindow.hidden = NO;
        self.hotspotWindow.hotspotsEnabled = YES;
    }
}

- (void)reloadPreferences {
    id enabled = FLMLandscapeWheelPreference(@"enabled");
    self.enabled = ![enabled isKindOfClass:[NSNumber class]] ||
                   [(NSNumber *)enabled boolValue];
    id items = FLMLandscapeWheelPreference(@"wheelItems");
    NSMutableArray<NSString *> *filtered = [NSMutableArray array];
    if ([items isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)items) {
            if (![value isKindOfClass:[NSString class]] ||
                ![(NSString *)value length] ||
                [(NSString *)value isEqualToString:FLMLandscapeLegacyWheelItem]) {
                continue;
            }
            [filtered addObject:value];
        }
    }
    self.itemIdentifiers = [filtered copy] ?: @[];
    id radius = FLMLandscapeWheelPreference(@"wheelRadius");
    id iconSize = FLMLandscapeWheelPreference(@"wheelIconSize");
    CGFloat requestedRadius = [radius isKindOfClass:[NSNumber class]]
                                  ? [(NSNumber *)radius doubleValue]
                                  : FLMLandscapeDefaultWheelRadius;
    CGFloat requestedIconSize = [iconSize isKindOfClass:[NSNumber class]]
                                    ? [(NSNumber *)iconSize doubleValue]
                                    : FLMLandscapeDefaultWheelIconSize;
    self.wheelRadius =
        FLMLandscapeWheelClamped(requestedRadius,
                                 FLMLandscapeMinimumWheelRadius,
                                 FLMLandscapeMaximumWheelRadius,
                                 FLMLandscapeDefaultWheelRadius);
    self.wheelIconSize =
        FLMLandscapeWheelClamped(requestedIconSize,
                                 FLMLandscapeMinimumWheelIconSize,
                                 FLMLandscapeMaximumWheelIconSize,
                                 FLMLandscapeDefaultWheelIconSize);
    BOOL active = self.enabled && self.itemIdentifiers.count > 0;
    self.guardGesture.enabled = active && !self.wheelPinned;
    self.openerGesture.enabled = active && !self.wheelPinned;
    self.modalGesture.enabled = active && self.wheelPinned;
    self.hotspotWindow.hotspotsEnabled =
        active && !self.usesSystemGestureManager && !self.wheelPinned;
    if (!active && self.wheelPinned) {
        [self dismissWheelLaunchingItem:nil];
    }
}

- (void)updateFrames {
    CGRect bounds = FLMLandscapeModuleVisualBounds();
    self.overlayWindow.frame = bounds;
    self.overlayWindow.rootViewController.view.frame =
        CGRectMake(0.0, 0.0, bounds.size.width, bounds.size.height);
    self.wheelContainer.frame =
        CGRectMake(0.0, 0.0, bounds.size.width, bounds.size.height);
    self.hotspotWindow.frame = bounds;
    self.hotspotWindow.rootViewController.view.frame =
        CGRectMake(0.0, 0.0, bounds.size.width, bounds.size.height);
    if (!FLMLandscapeModuleIsLandscape()) {
        self.overlayWindow.hidden = YES;
        self.hotspotWindow.hotspotsEnabled = NO;
        self.guardGesture.enabled = NO;
        self.openerGesture.enabled = NO;
        self.modalGesture.enabled = NO;
        self.wheelPinned = NO;
    }
}

- (void)orientationDidChange:(NSNotification *)notification {
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!FLMLandscapeModuleIsLandscape()) {
            [self dismissWheelLaunchingItem:nil];
            FLMLandscapeModuleClose(YES);
            [self updateFrames];
            return;
        }
        [self updateFrames];
        FLMLandscapeModuleOrientationDidChange();
    });
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    if (!self.enabled || FLMLandscapeWheelDeviceIsLocked() ||
        !FLMLandscapeModuleIsLandscape()) {
        return NO;
    }
    CGPoint rawPoint = [touch locationInView:nil];
    FLMLandscapeTouchContext context =
        FLMLandscapeModuleCaptureTouchContext();
    CGPoint point =
        FLMLandscapeModuleVisualPointFromRawPointInContext(context, rawPoint);
    if (gestureRecognizer == self.modalGesture) {
        return self.wheelPinned;
    }
    BOOL fromRight = NO;
    BOOL inside = FLMLandscapeModulePointInsideCornerTrigger(
        point, context.visualBounds, &fromRight);
    if (gestureRecognizer == self.guardGesture) {
        return !self.wheelPinned && inside;
    }
    if (gestureRecognizer == self.openerGesture) {
        if (self.wheelPinned || !inside || self.itemIdentifiers.count == 0) {
            return NO;
        }
        self.startPoint = point;
        self.presentingFromRight = fromRight;
        self.touchContext = context;
        self.touchContextValid = context.valid;
        FLMEnqueueDiagnosticLine(
            @"sb landscape-wheel-touch accepted raw={%.1f,%.1f} point={%.1f,%.1f} fromRight=%d visual=%@ fixed=%@",
            rawPoint.x, rawPoint.y, point.x, point.y, fromRight,
            NSStringFromCGRect(context.visualBounds),
            NSStringFromCGRect(context.fixedBounds));
        return YES;
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer {
    BOOL isWheelGesture = gestureRecognizer == self.guardGesture ||
                          gestureRecognizer == self.openerGesture ||
                          gestureRecognizer == self.modalGesture;
    BOOL isOtherWheelGesture = otherGestureRecognizer == self.guardGesture ||
                               otherGestureRecognizer == self.openerGesture ||
                               otherGestureRecognizer == self.modalGesture;
    return isWheelGesture && isOtherWheelGesture;
}

- (BOOL)shouldActivateForPoint:(CGPoint)point {
    CGFloat horizontalMovement = point.x - self.startPoint.x;
    CGFloat verticalMovement = point.y - self.startPoint.y;
    CGFloat totalMovement = hypot(horizontalMovement, verticalMovement);
    CGFloat inwardMovement = self.presentingFromRight
                                 ? -horizontalMovement
                                 : horizontalMovement;
    return totalMovement >= 14.0 &&
           (inwardMovement >= 4.0 || -verticalMovement >= 4.0);
}

- (NSArray<NSNumber *> *)ringCountsForCount:(NSUInteger)count {
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

- (CGPoint)wheelPointForRawPoint:(CGPoint)rawPoint {
    if (self.touchContextValid) {
        return FLMLandscapeModuleVisualPointFromRawPointInContext(
            self.touchContext, rawPoint);
    }
    return FLMLandscapeEnvironmentConvertPoint(rawPoint);
}

- (void)presentWheelFromRight:(BOOL)fromRight {
    if (!FLMLandscapeModuleIsLandscape() || self.itemIdentifiers.count == 0) {
        return;
    }
    CGRect bounds = self.touchContextValid
                        ? self.touchContext.visualBounds
                        : FLMLandscapeModuleVisualBounds();
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    BOOL resolvedFromRight = self.startPoint.x > width * 0.5;
    if (resolvedFromRight != fromRight) {
        fromRight = resolvedFromRight;
        self.presentingFromRight = fromRight;
    }

    [self.itemViews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.itemViews = @[];
    self.wheelPinned = NO;
    self.guardGesture.enabled = NO;
    self.openerGesture.enabled = YES;
    self.modalGesture.enabled = NO;
    self.hotspotWindow.hotspotsEnabled = NO;

    CGPoint anchor = CGPointMake(fromRight ? width - 4.0 : 4.0,
                                 height - 4.0);
    NSArray<NSNumber *> *rings =
        [self ringCountsForCount:self.itemIdentifiers.count];
    CGFloat startAngle = -82.0 * (CGFloat)M_PI / 180.0;
    CGFloat endAngle = -10.0 * (CGFloat)M_PI / 180.0;
    CGFloat angleSpan = endAngle - startAngle;
    CGFloat safeCenterMargin = self.wheelIconSize * 0.5 + 10.0;
    CGFloat maxRadiusByWidth =
        (width - 4.0 - safeCenterMargin) / cos(endAngle);
    CGFloat maxRadiusByHeight =
        (height - 4.0 - safeCenterMargin) / fabs(sin(startAngle));
    CGFloat maximumRadius = MAX(120.0,
                                MIN(maxRadiusByWidth, maxRadiusByHeight));
    CGFloat requestedRadius = MIN(self.wheelRadius, MAX(132.0, height * 0.42));
    CGFloat firstRadius = MIN(requestedRadius, maximumRadius);
    CGFloat ringSpacing = 0.0;
    if (rings.count > 1) {
        CGFloat intervals = (CGFloat)rings.count - 1.0;
        CGFloat desiredSpacing = self.wheelIconSize + 20.0;
        CGFloat minimumSpacing = self.wheelIconSize + 6.0;
        if (firstRadius + desiredSpacing * intervals <= maximumRadius) {
            ringSpacing = desiredSpacing;
        } else {
            firstRadius =
                MIN(firstRadius,
                    MAX(132.0, maximumRadius - minimumSpacing * intervals));
            ringSpacing = MAX(0.0, (maximumRadius - firstRadius) / intervals);
        }
    }

    // Preserve the already validated landscape fan geometry: calculate the
    // complete icon envelope first, then move the whole fan away from the
    // notch by the minimum safe-area correction.
    UIEdgeInsets safeArea = FLMLandscapeModuleVisualSafeAreaInsets();
    CGFloat safeMinX = MAX(0.0, MIN(width, safeArea.left));
    CGFloat safeMaxX = MIN(width, MAX(safeMinX, width - MAX(0.0, safeArea.right)));
    CGFloat minItemX = CGFLOAT_MAX;
    CGFloat maxItemX = -CGFLOAT_MAX;
    for (NSUInteger ring = 0; ring < rings.count; ring++) {
        NSUInteger ringCount = rings[ring].unsignedIntegerValue;
        CGFloat radius = firstRadius + ring * ringSpacing;
        for (NSUInteger position = 0; position < ringCount; position++) {
            CGFloat fraction = ringCount == 1
                                    ? 0.5
                                    : (CGFloat)position / (CGFloat)(ringCount - 1);
            CGFloat angle = startAngle + fraction * angleSpan;
            CGFloat edgeX = 4.0 + radius * cos(angle);
            CGFloat centerX = fromRight ? width - edgeX : edgeX;
            minItemX = MIN(minItemX, centerX - self.wheelIconSize * 0.5);
            maxItemX = MAX(maxItemX, centerX + self.wheelIconSize * 0.5);
        }
    }
    CGFloat horizontalShift = 0.0;
    if (minItemX != CGFLOAT_MAX && maxItemX != -CGFLOAT_MAX) {
        if (fromRight) {
            horizontalShift = -MIN(MAX(0.0, maxItemX - safeMaxX),
                                    MAX(0.0, minItemX - safeMinX));
        } else {
            horizontalShift = MIN(MAX(0.0, safeMinX - minItemX),
                                  MAX(0.0, safeMaxX - maxItemX));
        }
    }
    anchor.x += horizontalShift;

    NSMutableArray<FLMLandscapeWheelItemView *> *views =
        [NSMutableArray arrayWithCapacity:self.itemIdentifiers.count];
    NSUInteger itemIndex = 0;
    for (NSUInteger ring = 0; ring < rings.count; ring++) {
        NSUInteger ringCount = rings[ring].unsignedIntegerValue;
        CGFloat radius = firstRadius + ring * ringSpacing;
        for (NSUInteger position = 0; position < ringCount &&
                                     itemIndex < self.itemIdentifiers.count;
             position++) {
            CGFloat fraction = ringCount == 1
                                    ? 0.5
                                    : (CGFloat)position / (CGFloat)(ringCount - 1);
            CGFloat angle = startAngle + fraction * angleSpan;
            CGFloat edgeX = 4.0 + radius * cos(angle);
            CGFloat centerX = (fromRight ? width - edgeX : edgeX) +
                              horizontalShift;
            CGFloat centerY = anchor.y + radius * sin(angle);
            NSString *identifier = self.itemIdentifiers[itemIndex++];
            FLMLandscapeWheelItemView *item =
                [[FLMLandscapeWheelItemView alloc]
                    initWithIdentifier:identifier
                                 image:FLMLandscapeWheelIcon(identifier)
                                  size:self.wheelIconSize];
            item.center = CGPointMake(centerX, centerY);
            item.alpha = 0.0;
            item.transform = CGAffineTransformMakeScale(0.42, 0.42);
            [self.wheelContainer addSubview:item];
            [views addObject:item];
        }
    }
    self.itemViews = views;
    self.overlayWindow.frame = bounds;
    self.overlayWindow.rootViewController.view.frame =
        CGRectMake(0.0, 0.0, width, height);
    self.wheelContainer.frame = CGRectMake(0.0, 0.0, width, height);
    self.overlayWindow.hidden = NO;
    self.overlayWindow.userInteractionEnabled = NO;
    self.wheelContainer.alpha = 1.0;
    FLMEnqueueDiagnosticLine(
        @"sb landscape-wheel-geometry side=%@ bounds=%@ safeArea={%.1f,%.1f,%.1f,%.1f} shiftX=%.1f itemX={%.1f,%.1f} anchor={%.1f,%.1f} radius=%.1f icon=%.1f",
        fromRight ? @"right" : @"left", NSStringFromCGRect(bounds),
        safeArea.left, safeArea.top, safeArea.right, safeArea.bottom,
        horizontalShift, minItemX, maxItemX, anchor.x, anchor.y,
        firstRadius, self.wheelIconSize);
    [self.itemViews enumerateObjectsUsingBlock:
        ^(FLMLandscapeWheelItemView *item, NSUInteger index, BOOL *stop) {
            (void)stop;
            [UIView animateWithDuration:0.40
                                  delay:MIN(index * 0.018, 0.12)
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

- (FLMLandscapeWheelItemView *)itemNearPoint:(CGPoint)point {
    FLMLandscapeWheelItemView *nearest = nil;
    CGFloat nearestDistance = CGFLOAT_MAX;
    CGFloat hitDistance = self.wheelIconSize * 0.5 + 2.0;
    for (FLMLandscapeWheelItemView *item in self.itemViews) {
        CGFloat distance = hypot(point.x - item.center.x,
                                 point.y - item.center.y);
        if (distance < nearestDistance) {
            nearestDistance = distance;
            nearest = item;
        }
    }
    return nearestDistance <= hitDistance ? nearest : nil;
}

- (void)updateHighlightForPoint:(CGPoint)point {
    FLMLandscapeWheelItemView *item = [self itemNearPoint:point];
    if (item == self.highlightedItem) {
        return;
    }
    self.highlightedItem.highlighted = NO;
    self.highlightedItem = item;
    self.highlightedItem.highlighted = YES;
    if (@available(iOS 10.0, *)) {
        if (!item) {
            return;
        }
        UISelectionFeedbackGenerator *feedback =
            [[UISelectionFeedbackGenerator alloc] init];
        [feedback selectionChanged];
    }
}

- (void)pinWheel {
    if (self.overlayWindow.hidden || self.wheelPinned) {
        return;
    }
    self.highlightedItem.highlighted = NO;
    self.highlightedItem = nil;
    self.wheelPinned = YES;
    self.guardGesture.enabled = NO;
    self.openerGesture.enabled = NO;
    self.modalGesture.enabled = YES;
    self.overlayTap.enabled = !self.usesSystemGestureManager;
    self.overlayWindow.userInteractionEnabled = !self.usesSystemGestureManager;
    [UIView animateWithDuration:0.24
                     animations:^{
                         for (FLMLandscapeWheelItemView *item in self.itemViews) {
                             item.alpha = 1.0;
                             item.transform = CGAffineTransformIdentity;
                         }
                     }];
    FLMEnqueueDiagnosticLine(@"sb landscape-wheel-pinned");
}

- (void)dismissWheelLaunchingItem:(FLMLandscapeWheelItemView *)item {
    NSString *identifier = [item.identifier copy];
    self.highlightedItem.highlighted = NO;
    self.highlightedItem = nil;
    self.wheelPinned = NO;
    self.wheelGestureActive = NO;
    self.guardGesture.enabled = self.enabled && self.itemIdentifiers.count > 0;
    self.openerGesture.enabled = self.enabled && self.itemIdentifiers.count > 0;
    self.modalGesture.enabled = NO;
    self.overlayTap.enabled = NO;
    self.overlayWindow.userInteractionEnabled = NO;
    self.hotspotWindow.hotspotsEnabled =
        self.enabled && self.itemIdentifiers.count > 0 &&
        !self.usesSystemGestureManager;
    if (self.overlayWindow.hidden) {
        if (identifier.length) {
            FLMLandscapeModuleOpenIdentifier(identifier);
        }
        return;
    }
    [UIView animateWithDuration:0.18
                     animations:^{
                         self.wheelContainer.alpha = 0.0;
                         for (FLMLandscapeWheelItemView *view in self.itemViews) {
                             view.alpha = 0.0;
                             view.transform = CGAffineTransformMakeScale(0.78, 0.78);
                         }
                     }
                     completion:^(BOOL finished) {
                         (void)finished;
                         self.overlayWindow.hidden = YES;
                         self.wheelContainer.alpha = 1.0;
                         [self.itemViews makeObjectsPerformSelector:
                                      @selector(removeFromSuperview)];
                         self.itemViews = @[];
                         if (identifier.length) {
                             FLMLandscapeModuleOpenIdentifier(identifier);
                         }
                     }];
}

- (void)handleGuardGesture:(UIGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        CGPoint point = [self wheelPointForRawPoint:[gesture locationInView:nil]];
        FLMEnqueueDiagnosticLine(
            @"sb landscape-wheel-priority-guard began point={%.1f,%.1f}",
            point.x, point.y);
    }
}

- (void)handleOpenerGesture:(UIGestureRecognizer *)gesture {
    if (!FLMLandscapeModuleIsLandscape() || self.wheelPinned) {
        return;
    }
    CGPoint point = [self wheelPointForRawPoint:[gesture locationInView:nil]];
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            if (!self.wheelGestureActive &&
                [self shouldActivateForPoint:point]) {
                self.wheelGestureActive = YES;
                [self presentWheelFromRight:self.presentingFromRight];
                FLMEnqueueDiagnosticLine(
                    @"sb landscape-wheel-gesture began point={%.1f,%.1f} start={%.1f,%.1f} fromRight=%d",
                    point.x, point.y, self.startPoint.x, self.startPoint.y,
                    self.presentingFromRight);
            }
            if (self.wheelGestureActive) {
                [self updateHighlightForPoint:point];
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
            if (self.wheelGestureActive) {
                [self dismissWheelLaunchingItem:nil];
            }
            self.wheelGestureActive = NO;
            break;
        default:
            break;
    }
}

- (void)handleModalGesture:(UIGestureRecognizer *)gesture {
    if (!self.wheelPinned) {
        return;
    }
    CGPoint point = FLMLandscapeEnvironmentConvertPoint(
        [gesture locationInView:nil]);
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            [self updateHighlightForPoint:point];
            break;
        case UIGestureRecognizerStateEnded:
            [self dismissWheelLaunchingItem:self.highlightedItem];
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            self.highlightedItem.highlighted = NO;
            self.highlightedItem = nil;
            break;
        default:
            break;
    }
}

- (void)handleOverlayTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded || !self.wheelPinned) {
        return;
    }
    CGPoint point = [gesture locationInView:self.wheelContainer];
    [self dismissWheelLaunchingItem:[self itemNearPoint:point]];
}

- (void)activateIdentifier:(NSString *)identifier {
    if (!identifier.length || FLMLandscapeWheelDeviceIsLocked()) {
        return;
    }
    if ([identifier isEqualToString:@"com.codex.flymemultitasking.lockscreen"]) {
        UIApplication *application = [UIApplication sharedApplication];
        if ([application respondsToSelector:@selector(_simulateLockButtonPress)]) {
            [application _simulateLockButtonPress];
        }
        return;
    }
    UIApplication *application = [UIApplication sharedApplication];
    BOOL launched = NO;
    if ([application respondsToSelector:
                    @selector(launchApplicationWithIdentifier:suspended:)]) {
        launched = [application launchApplicationWithIdentifier:identifier
                                                      suspended:NO];
    }
    id workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = [workspaceClass respondsToSelector:@selector(defaultWorkspace)]
                       ? [workspaceClass defaultWorkspace]
                       : nil;
    if (!launched && [workspace respondsToSelector:
                                  @selector(openApplicationWithBundleID:)]) {
        [workspace openApplicationWithBundleID:identifier];
    }
    FLMEnqueueDiagnosticLine(@"sb landscape-wheel-launch app=%@", identifier);
}

@end

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    (void)application;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[FLMLandscapeWheelController sharedController] start];
    });
}

%end

%ctor {
    // The module is a SpringBoard-only package. No UIKit application or
    // keyboard dylib is installed by this target.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[FLMLandscapeWheelController sharedController] start];
    });
}
