#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

#import "FLMDiagnostics.h"
#import "FLMLandscapeModule.h"

static NSString *const FLMLandscapeLockScreenItem =
    @"com.codex.flymemultitasking.lockscreen";

@interface NSObject (FLMLandscapeWheelRuntimePrivate)
+ (id)sharedInstance;
- (BOOL)isUILocked;
- (BOOL)isLockScreenVisible;
- (BOOL)isLockScreenActive;
- (BOOL)isLocked;
@end

@interface UIImage (FLMLandscapeWheelRuntimePrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)identifier
                                               format:(NSInteger)format
                                                scale:(CGFloat)scale;
@end

@interface FLMHotspotWindow : UIWindow
@property(nonatomic, assign) BOOL hotspotsEnabled;
@end

// This is the class implemented by the frozen portrait source. Landscape only
// allocates it; there is deliberately no second item-view implementation.
@interface FLMWheelItemView : UIView
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, assign) BOOL highlighted;
- (instancetype)initWithIdentifier:(NSString *)identifier
                             image:(UIImage *)image
                              size:(CGFloat)size;
@end

@interface FLMWheelController : NSObject
@property(nonatomic, strong) UIWindow *overlayWindow;
@property(nonatomic, strong) UIView *wheelContainer;
@property(nonatomic, strong) FLMHotspotWindow *hotspotWindow;
@property(nonatomic, strong) UIWindow *floatingWindow;
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
@property(nonatomic, assign) CGPoint cornerGestureStartPoint;
@property(nonatomic, strong) UIGestureRecognizer *cornerGuardGesture;
@property(nonatomic, strong) UIGestureRecognizer *cornerGesture;
@property(nonatomic, strong) UIGestureRecognizer *floatingCornerGuardGesture;
@property(nonatomic, strong) UIGestureRecognizer *floatingCornerGesture;
@property(nonatomic, strong) UIGestureRecognizer *modalGesture;
- (NSArray<NSNumber *> *)itemCountsByRingForCount:(NSUInteger)count;
- (void)updateHighlightForPoint:(CGPoint)point;
- (void)pinWheel;
- (void)dismissWheelLaunchingItem:(FLMWheelItemView *)item;
@end

static __weak FLMWheelController *FLMLandscapeActiveRoot = nil;
static FLMLandscapeTouchContext FLMLandscapeActiveTouchContext;
static BOOL FLMLandscapeTouchContextValid = NO;

static BOOL FLMLandscapeWheelDeviceIsLocked(void) {
    Class managerClass = NSClassFromString(@"SBLockScreenManager");
    id manager = [managerClass respondsToSelector:@selector(sharedInstance)]
                     ? [managerClass sharedInstance]
                     : nil;
    if (!manager) {
        return NO;
    }
    NSArray<NSString *> *selectors =
        @[@"isUILocked", @"isLockScreenVisible", @"isLockScreenActive",
          @"isLocked"];
    for (NSString *name in selectors) {
        SEL selector = NSSelectorFromString(name);
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

static UIImage *FLMLandscapeRootWheelIcon(NSString *identifier) {
    if ([identifier isEqualToString:FLMLandscapeLockScreenItem]) {
        UIImage *image = [UIImage systemImageNamed:@"lock.fill"];
        return [image imageWithTintColor:[UIColor whiteColor]
                           renderingMode:UIImageRenderingModeAlwaysOriginal];
    }
    if ([UIImage respondsToSelector:
                     @selector(_applicationIconImageForBundleIdentifier:
                                                format:
                                                 scale:)]) {
        UIImage *image =
            [UIImage _applicationIconImageForBundleIdentifier:identifier
                                                       format:2
                                                        scale:[UIScreen mainScreen].scale];
        if (image) {
            return image;
        }
    }
    return [UIImage systemImageNamed:@"app.fill"];
}

static BOOL FLMLandscapeRootCanSummon(FLMWheelController *root) {
    return root && FLMLandscapeModuleIsLandscape() && root.enabled &&
           !root.wheelPinned && root.itemIdentifiers.count > 0 &&
           !FLMLandscapeWheelDeviceIsLocked();
}

static BOOL FLMLandscapeGestureIsGuard(FLMWheelController *root,
                                       UIGestureRecognizer *gesture) {
    return gesture &&
           (gesture == root.cornerGuardGesture ||
            gesture == root.floatingCornerGuardGesture);
}

static BOOL FLMLandscapeGestureIsOpener(FLMWheelController *root,
                                        UIGestureRecognizer *gesture) {
    return gesture &&
           (gesture == root.cornerGesture ||
            gesture == root.floatingCornerGesture);
}

static CGPoint FLMLandscapeWheelPoint(CGPoint rawPoint) {
    if (FLMLandscapeTouchContextValid) {
        return FLMLandscapeModuleVisualPointFromRawPointInContext(
            FLMLandscapeActiveTouchContext, rawPoint);
    }
    return FLMLandscapeEnvironmentConvertPoint(rawPoint);
}

static void FLMLandscapeCaptureRootTouch(FLMWheelController *root,
                                         UITouch *touch) {
    FLMLandscapeActiveRoot = root;
    FLMLandscapeActiveTouchContext =
        FLMLandscapeModuleCaptureTouchContext();
    FLMLandscapeTouchContextValid =
        FLMLandscapeActiveTouchContext.valid;
    CGPoint rawPoint = [touch locationInView:nil];
    CGPoint point = FLMLandscapeWheelPoint(rawPoint);
    BOOL fromRight = NO;
    FLMLandscapeModulePointInsideCornerTrigger(
        point, FLMLandscapeActiveTouchContext.visualBounds, &fromRight);
    root.cornerGestureStartPoint = point;
    root.presentingFromRight = fromRight;
    root.wheelGestureActive = NO;
    FLMEnqueueDiagnosticLine(
        @"sb landscape-root-wheel-touch raw={%.1f,%.1f} point={%.1f,%.1f} fromRight=%d root=%p",
        rawPoint.x, rawPoint.y, point.x, point.y, fromRight,
        (__bridge void *)root);
}

BOOL FLMLandscapeWheelOwnsSharedGesture(
    id wheelController,
    UIGestureRecognizer *gestureRecognizer) {
    if (![wheelController isKindOfClass:
                             NSClassFromString(@"FLMWheelController")]) {
        return NO;
    }
    FLMWheelController *root = (FLMWheelController *)wheelController;
    return FLMLandscapeGestureIsGuard(root, gestureRecognizer) ||
           FLMLandscapeGestureIsOpener(root, gestureRecognizer) ||
           gestureRecognizer == root.modalGesture;
}

BOOL FLMLandscapeWheelShouldReceiveSharedTouch(
    id wheelController,
    UIGestureRecognizer *gestureRecognizer,
    UITouch *touch) {
    if (!FLMLandscapeWheelOwnsSharedGesture(wheelController,
                                            gestureRecognizer) ||
        !touch) {
        return NO;
    }
    FLMWheelController *root = (FLMWheelController *)wheelController;
    if (gestureRecognizer == root.modalGesture) {
        return root.enabled && root.wheelPinned &&
               !FLMLandscapeWheelDeviceIsLocked();
    }
    if (!FLMLandscapeRootCanSummon(root)) {
        return NO;
    }
    FLMLandscapeTouchContext context =
        FLMLandscapeModuleCaptureTouchContext();
    CGPoint rawPoint = [touch locationInView:nil];
    CGPoint point =
        FLMLandscapeModuleVisualPointFromRawPointInContext(context, rawPoint);
    BOOL accepted = context.valid &&
                    FLMLandscapeModulePointInsideCornerTrigger(
                        point, context.visualBounds, NULL);
    if (accepted && FLMLandscapeGestureIsOpener(root, gestureRecognizer)) {
        FLMLandscapeCaptureRootTouch(root, touch);
    }
    if (accepted) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-root-wheel-priority recognizer=%@ point={%.1f,%.1f}",
            FLMLandscapeGestureIsGuard(root, gestureRecognizer)
                ? @"guard"
                : @"opener",
            point.x, point.y);
    }
    return accepted;
}

BOOL FLMLandscapeWheelShouldBeginSharedGesture(
    id wheelController,
    UIGestureRecognizer *gestureRecognizer) {
    if (!FLMLandscapeWheelOwnsSharedGesture(wheelController,
                                            gestureRecognizer)) {
        return NO;
    }
    FLMWheelController *root = (FLMWheelController *)wheelController;
    if (gestureRecognizer == root.modalGesture) {
        return root.enabled && root.wheelPinned &&
               !FLMLandscapeWheelDeviceIsLocked();
    }
    if (!FLMLandscapeRootCanSummon(root)) {
        return NO;
    }
    if (FLMLandscapeGestureIsGuard(root, gestureRecognizer)) {
        return YES;
    }
    if (!FLMLandscapeTouchContextValid || FLMLandscapeActiveRoot != root) {
        FLMLandscapeActiveTouchContext =
            FLMLandscapeModuleCaptureTouchContext();
        FLMLandscapeTouchContextValid =
            FLMLandscapeActiveTouchContext.valid;
        CGPoint point = FLMLandscapeWheelPoint(
            [gestureRecognizer locationInView:nil]);
        BOOL fromRight = NO;
        if (!FLMLandscapeModulePointInsideCornerTrigger(
                point, FLMLandscapeActiveTouchContext.visualBounds,
                &fromRight)) {
            return NO;
        }
        root.cornerGestureStartPoint = point;
        root.presentingFromRight = fromRight;
        root.wheelGestureActive = NO;
        FLMLandscapeActiveRoot = root;
    }
    return FLMLandscapeModulePointInsideCornerTrigger(
        root.cornerGestureStartPoint,
        FLMLandscapeActiveTouchContext.visualBounds,
        NULL);
}

BOOL FLMLandscapeWheelShouldSuppressPortraitGesture(
    id wheelController,
    UIGestureRecognizer *gestureRecognizer) {
    (void)wheelController;
    (void)gestureRecognizer;
    // Card, handle, dock, backdrop and keyboard gestures remain owned by the
    // frozen controller. Only the wheel family above needs coordinate
    // adaptation in landscape.
    return NO;
}

void FLMLandscapeWheelPresentRootController(id wheelController,
                                            BOOL fromRight) {
    if (![wheelController isKindOfClass:
                             NSClassFromString(@"FLMWheelController")]) {
        return;
    }
    FLMWheelController *root = (FLMWheelController *)wheelController;
    if (!FLMLandscapeModuleIsLandscape() ||
        root.itemIdentifiers.count == 0) {
        return;
    }
    FLMWriteLandscapeBootstrapMarker("root-wheel-open");
    FLMLandscapeModuleSynchronizeRootController(root);
    CGRect bounds = FLMLandscapeTouchContextValid
                        ? FLMLandscapeActiveTouchContext.visualBounds
                        : FLMLandscapeModuleVisualBounds();
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    BOOL resolvedFromRight = root.cornerGestureStartPoint.x > width * 0.5;
    if (resolvedFromRight != fromRight) {
        fromRight = resolvedFromRight;
        root.presentingFromRight = fromRight;
    }

    [root.itemViews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    root.itemViews = @[];
    root.wheelPinned = NO;
    root.hotspotWindow.hotspotsEnabled = NO;
    root.overlayWindow.userInteractionEnabled = NO;
    root.overlayWindow.windowLevel = root.floatingWindow.windowLevel + 2.0;

    CGPoint anchor = CGPointMake(fromRight ? width - 4.0 : 4.0,
                                 height - 4.0);
    NSArray<NSNumber *> *rings =
        [root itemCountsByRingForCount:root.itemIdentifiers.count];
    CGFloat startAngle = -82.0 * (CGFloat)M_PI / 180.0;
    CGFloat endAngle = -10.0 * (CGFloat)M_PI / 180.0;
    CGFloat angleSpan = endAngle - startAngle;
    CGFloat safeCenterMargin = root.wheelIconSize * 0.5 + 10.0;
    CGFloat maxRadiusByWidth =
        (width - 4.0 - safeCenterMargin) / cos(endAngle);
    CGFloat maxRadiusByHeight =
        (height - 4.0 - safeCenterMargin) / fabs(sin(startAngle));
    CGFloat maximumRadius =
        MAX(120.0, MIN(maxRadiusByWidth, maxRadiusByHeight));
    CGFloat requestedRadius =
        MIN(root.wheelRadius, MAX(132.0, height * 0.42));
    CGFloat firstRadius = MIN(requestedRadius, maximumRadius);
    CGFloat ringSpacing = 0.0;
    if (rings.count > 1) {
        CGFloat intervals = (CGFloat)rings.count - 1.0;
        CGFloat desiredSpacing = root.wheelIconSize + 20.0;
        CGFloat minimumSpacing = root.wheelIconSize + 6.0;
        if (firstRadius + desiredSpacing * intervals <= maximumRadius) {
            ringSpacing = desiredSpacing;
        } else {
            firstRadius =
                MIN(firstRadius,
                    MAX(132.0,
                        maximumRadius - minimumSpacing * intervals));
            ringSpacing =
                MAX(0.0, (maximumRadius - firstRadius) / intervals);
        }
    }

    UIEdgeInsets safeArea = FLMLandscapeModuleVisualSafeAreaInsets();
    CGFloat safeMinX = MAX(0.0, MIN(width, safeArea.left));
    CGFloat safeMaxX =
        MIN(width, MAX(safeMinX, width - MAX(0.0, safeArea.right)));
    CGFloat minItemX = CGFLOAT_MAX;
    CGFloat maxItemX = -CGFLOAT_MAX;
    for (NSUInteger ring = 0; ring < rings.count; ring++) {
        NSUInteger ringCount = rings[ring].unsignedIntegerValue;
        CGFloat radius = firstRadius + ring * ringSpacing;
        for (NSUInteger position = 0; position < ringCount; position++) {
            CGFloat fraction = ringCount == 1
                                   ? 0.5
                                   : (CGFloat)position /
                                         (CGFloat)(ringCount - 1);
            CGFloat angle = startAngle + fraction * angleSpan;
            CGFloat edgeX = 4.0 + radius * cos(angle);
            CGFloat centerX = fromRight ? width - edgeX : edgeX;
            minItemX = MIN(minItemX,
                           centerX - root.wheelIconSize * 0.5);
            maxItemX = MAX(maxItemX,
                           centerX + root.wheelIconSize * 0.5);
        }
    }
    CGFloat horizontalShift = 0.0;
    if (minItemX != CGFLOAT_MAX && maxItemX != -CGFLOAT_MAX) {
        if (fromRight) {
            horizontalShift =
                -MIN(MAX(0.0, maxItemX - safeMaxX),
                     MAX(0.0, minItemX - safeMinX));
        } else {
            horizontalShift =
                MIN(MAX(0.0, safeMinX - minItemX),
                    MAX(0.0, safeMaxX - maxItemX));
        }
    }
    anchor.x += horizontalShift;

    NSMutableArray<FLMWheelItemView *> *views =
        [NSMutableArray arrayWithCapacity:root.itemIdentifiers.count];
    NSUInteger itemIndex = 0;
    for (NSUInteger ring = 0; ring < rings.count; ring++) {
        NSUInteger ringCount = rings[ring].unsignedIntegerValue;
        CGFloat radius = firstRadius + ring * ringSpacing;
        for (NSUInteger position = 0;
             position < ringCount && itemIndex < root.itemIdentifiers.count;
             position++) {
            CGFloat fraction = ringCount == 1
                                   ? 0.5
                                   : (CGFloat)position /
                                         (CGFloat)(ringCount - 1);
            CGFloat angle = startAngle + fraction * angleSpan;
            CGFloat edgeX = 4.0 + radius * cos(angle);
            CGFloat centerX = (fromRight ? width - edgeX : edgeX) +
                              horizontalShift;
            CGFloat centerY = anchor.y + radius * sin(angle);
            NSString *identifier = root.itemIdentifiers[itemIndex++];
            FLMWheelItemView *item =
                [[NSClassFromString(@"FLMWheelItemView") alloc]
                    initWithIdentifier:identifier
                                 image:FLMLandscapeRootWheelIcon(identifier)
                                  size:root.wheelIconSize];
            if (!item) {
                continue;
            }
            item.center = CGPointMake(centerX, centerY);
            item.alpha = 0.0;
            item.transform = CGAffineTransformMakeScale(0.42, 0.42);
            [root.wheelContainer addSubview:item];
            [views addObject:item];
        }
    }
    root.itemViews = views;
    root.overlayWindow.frame = bounds;
    root.overlayWindow.rootViewController.view.frame =
        CGRectMake(0.0, 0.0, width, height);
    root.wheelContainer.frame = CGRectMake(0.0, 0.0, width, height);
    root.overlayWindow.hidden = NO;
    root.wheelContainer.alpha = 1.0;
    FLMEnqueueDiagnosticLine(
        @"sb landscape-root-wheel-open root=%p items=%lu side=%@ bounds=%@ safeArea={%.1f,%.1f,%.1f,%.1f} shiftX=%.1f radius=%.1f icon=%.1f itemClass=FLMWheelItemView",
        (__bridge void *)root, (unsigned long)views.count,
        fromRight ? @"right" : @"left", NSStringFromCGRect(bounds),
        safeArea.left, safeArea.top, safeArea.right, safeArea.bottom,
        horizontalShift, firstRadius, root.wheelIconSize);
    [root.itemViews enumerateObjectsUsingBlock:
        ^(FLMWheelItemView *item, NSUInteger index, BOOL *stop) {
            (void)stop;
            [UIView animateWithDuration:0.44
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

void FLMLandscapeWheelHandleSharedGesture(
    id wheelController,
    UIGestureRecognizer *gestureRecognizer) {
    if (!FLMLandscapeWheelOwnsSharedGesture(wheelController,
                                            gestureRecognizer)) {
        return;
    }
    FLMWheelController *root = (FLMWheelController *)wheelController;
    if (gestureRecognizer == root.modalGesture) {
        if (!root.wheelPinned) {
            return;
        }
        CGPoint point = FLMLandscapeWheelPoint(
            [gestureRecognizer locationInView:nil]);
        switch (gestureRecognizer.state) {
            case UIGestureRecognizerStateBegan:
            case UIGestureRecognizerStateChanged:
                [root updateHighlightForPoint:point];
                break;
            case UIGestureRecognizerStateEnded:
                [root dismissWheelLaunchingItem:root.highlightedItem];
                FLMLandscapeTouchContextValid = NO;
                break;
            case UIGestureRecognizerStateCancelled:
            case UIGestureRecognizerStateFailed:
                root.highlightedItem.highlighted = NO;
                root.highlightedItem = nil;
                FLMLandscapeTouchContextValid = NO;
                break;
            default:
                break;
        }
        return;
    }
    if (FLMLandscapeGestureIsGuard(root, gestureRecognizer)) {
        if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
            CGPoint point = FLMLandscapeWheelPoint(
                [gestureRecognizer locationInView:nil]);
            FLMEnqueueDiagnosticLine(
                @"sb landscape-root-wheel-guard point={%.1f,%.1f}",
                point.x, point.y);
        }
        return;
    }

    CGPoint point = FLMLandscapeWheelPoint(
        [gestureRecognizer locationInView:nil]);
    CGFloat horizontalMovement = point.x - root.cornerGestureStartPoint.x;
    CGFloat verticalMovement = point.y - root.cornerGestureStartPoint.y;
    CGFloat totalMovement = hypot(horizontalMovement, verticalMovement);
    CGFloat inwardMovement = root.presentingFromRight
                                 ? -horizontalMovement
                                 : horizontalMovement;
    CGFloat upwardMovement = -verticalMovement;
    BOOL shouldActivate = totalMovement >= 14.0 &&
                          (inwardMovement >= 4.0 || upwardMovement >= 4.0);
    switch (gestureRecognizer.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            if (!root.wheelGestureActive && shouldActivate) {
                root.wheelGestureActive = YES;
                FLMLandscapeWheelPresentRootController(
                    root, root.presentingFromRight);
            }
            if (root.wheelGestureActive) {
                [root updateHighlightForPoint:point];
            }
            break;
        case UIGestureRecognizerStateEnded:
            if (root.wheelGestureActive) {
                FLMWheelItemView *selectedItem = root.highlightedItem;
                if (selectedItem) {
                    [root dismissWheelLaunchingItem:selectedItem];
                } else {
                    [root pinWheel];
                }
            }
            FLMEnqueueDiagnosticLine(
                @"sb landscape-root-wheel-ended active=%d point={%.1f,%.1f}",
                root.wheelGestureActive, point.x, point.y);
            root.wheelGestureActive = NO;
            FLMLandscapeTouchContextValid = root.wheelPinned;
            break;
        case UIGestureRecognizerStateCancelled:
            if (root.wheelGestureActive) {
                [root pinWheel];
            }
            root.wheelGestureActive = NO;
            FLMLandscapeTouchContextValid = root.wheelPinned;
            break;
        case UIGestureRecognizerStateFailed:
            if (root.wheelGestureActive) {
                [root dismissWheelLaunchingItem:nil];
            }
            root.wheelGestureActive = NO;
            FLMLandscapeTouchContextValid = NO;
            break;
        default:
            break;
    }
}

%ctor {
    FLMWriteLandscapeBootstrapMarker("adapter-constructor");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FLMLandscapeModuleStart();
    });
}
