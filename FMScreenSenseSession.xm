#import "FMScreenSenseSession.h"

#import <QuartzCore/QuartzCore.h>

#import "FLMDiagnostics.h"
#import "FlymeMultitasking-Swift.h"

typedef NS_ENUM(NSInteger, FMScreenSenseState) {
    FMScreenSenseStateInactive = 0,
    FMScreenSenseStateDismissingWheel,
    FMScreenSenseStateCapturing,
    FMScreenSenseStateAnalyzing,
    FMScreenSenseStateActive,
    FMScreenSenseStateDismissing,
};

static NSString *FMScreenSenseStateName(FMScreenSenseState state) {
    switch (state) {
        case FMScreenSenseStateDismissingWheel:
            return @"dismissingWheel";
        case FMScreenSenseStateCapturing:
            return @"capturing";
        case FMScreenSenseStateAnalyzing:
            return @"analyzing";
        case FMScreenSenseStateActive:
            return @"active";
        case FMScreenSenseStateDismissing:
            return @"dismissing";
        case FMScreenSenseStateInactive:
        default:
            return @"inactive";
    }
}

static UIWindowScene *FMScreenSenseForegroundWindowScene(void) {
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

static UIWindow *FMScreenSenseCurrentKeyWindow(UIWindowScene *scene) {
    if (!scene) {
        return nil;
    }
    for (UIWindow *window in scene.windows) {
        if (window.isKeyWindow) {
            return window;
        }
    }
    return nil;
}

@interface FMScreenSenseWindow : UIWindow
@end

@implementation FMScreenSenseWindow

- (BOOL)canBecomeKeyWindow {
    return YES;
}

@end

@interface FMScreenSenseViewController : UIViewController
@end

@implementation FMScreenSenseViewController

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

@interface FMScreenSenseSession ()
@property(nonatomic, assign) FMScreenSenseState state;
@property(nonatomic, assign) NSUInteger generation;
@property(nonatomic, assign) CFTimeInterval analysisStartedAt;
@property(nonatomic, strong) FMScreenSenseWindow *window;
@property(nonatomic, strong) FMScreenSenseViewController *viewController;
@property(nonatomic, strong) UIImageView *imageView;
@property(nonatomic, strong) UIButton *closeButton;
@property(nonatomic, strong) UIWindow *previousKeyWindow;
@property(nonatomic, strong) FMScreenSenseVisionBridge *visionBridge;
- (void)dismissOnMainThread;
- (void)abortVisionWithErrorCode:(NSInteger)code message:(NSString *)message;
- (void)handleCloseButton:(UIButton *)sender;
@end

@implementation FMScreenSenseSession

+ (instancetype)sharedSession {
    static FMScreenSenseSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        session = [[self alloc] init];
    });
    return session;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = FMScreenSenseStateInactive;
        _generation = 0;
    }
    return self;
}

- (BOOL)beginCaptureSession {
    if (![NSThread isMainThread]) {
        __block BOOL accepted = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            accepted = [self beginCaptureSession];
        });
        return accepted;
    }

    if (self.state != FMScreenSenseStateInactive) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense] duplicate trigger ignored state=%@",
            FMScreenSenseStateName(self.state));
        return NO;
    }

    self.generation += 1;
    self.state = FMScreenSenseStateDismissingWheel;
    return YES;
}

- (void)markCaptureStarted {
    if (![NSThread isMainThread]) {
        __weak FMScreenSenseSession *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf markCaptureStarted];
        });
        return;
    }

    if (self.state == FMScreenSenseStateDismissingWheel) {
        self.state = FMScreenSenseStateCapturing;
    }
}

- (void)abortCaptureWithReason:(NSString *)reason {
    if (![NSThread isMainThread]) {
        __weak FMScreenSenseSession *weakSelf = self;
        NSString *reasonCopy = [reason copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf abortCaptureWithReason:reasonCopy];
        });
        return;
    }

    if (self.state == FMScreenSenseStateInactive) {
        return;
    }

    FLMEnqueueDiagnosticLine(
        @"[ScreenSense][Capture][ERROR] capture aborted reason=%@",
        reason.length > 0 ? reason : @"unknown");
    [self dismissOnMainThread];
}

- (void)presentCapturedImage:(UIImage *)image {
    if (![NSThread isMainThread]) {
        __weak FMScreenSenseSession *weakSelf = self;
        UIImage *imageCopy = image;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf presentCapturedImage:imageCopy];
        });
        return;
    }

    if (!image || self.state != FMScreenSenseStateCapturing) {
        [self abortCaptureWithReason:image ? @"invalid-session-state"
                                      : @"nil-image"];
        return;
    }

    NSUInteger sessionGeneration = self.generation;
    UIWindowScene *scene = FMScreenSenseForegroundWindowScene();
    if (!scene) {
        [self abortCaptureWithReason:@"no-foreground-window-scene"];
        return;
    }

    FLMEnqueueDiagnosticLine(@"[ScreenSense] overlay present begin");
    self.previousKeyWindow = FMScreenSenseCurrentKeyWindow(scene);

    FMScreenSenseWindow *window =
        [[FMScreenSenseWindow alloc] initWithWindowScene:scene];
    window.frame = scene.coordinateSpace.bounds;
    // Keep the frozen screen above the current host window, but leave room
    // for UIKit/VisionKit's own text-effects and translation presentation
    // windows. The previous Alert+120 level could visually cover the native
    // Copy/Translate UI while selection itself still appeared to work.
    CGFloat hostWindowLevel = self.previousKeyWindow
                                  ? self.previousKeyWindow.windowLevel
                                  : UIWindowLevelNormal;
    window.windowLevel = MAX(UIWindowLevelAlert + 1.0, hostWindowLevel + 1.0);
    window.backgroundColor = [UIColor blackColor];
    window.opaque = YES;
    window.userInteractionEnabled = YES;

    FMScreenSenseViewController *viewController =
        [[FMScreenSenseViewController alloc] init];
    viewController.view.frame = window.bounds;
    viewController.view.backgroundColor = [UIColor blackColor];
    window.rootViewController = viewController;

    UIImageView *imageView = [[UIImageView alloc] initWithFrame:window.bounds];
    imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleHeight;
    imageView.backgroundColor = [UIColor blackColor];
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    imageView.clipsToBounds = YES;
    imageView.userInteractionEnabled = YES;
    imageView.image = image;
    imageView.accessibilityIdentifier = @"com.codex.flymemultitasking.screensense.frozen-image";
    [viewController.view addSubview:imageView];

    // Keep dismissal out of the image view's gesture arena. A sibling button
    // gives the VisionKit interaction the complete touch stream it needs for
    // text selection while still providing a deterministic exit path.
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeButton setTitle:@"关闭" forState:UIControlStateNormal];
    [closeButton setTitleColor:[UIColor whiteColor]
                      forState:UIControlStateNormal];
    closeButton.titleLabel.font =
        [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    closeButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.62];
    closeButton.layer.cornerRadius = 18.0;
    closeButton.layer.masksToBounds = YES;
    closeButton.accessibilityLabel = @"关闭识屏";
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [closeButton addTarget:self
                    action:@selector(handleCloseButton:)
          forControlEvents:UIControlEventTouchUpInside];
    [viewController.view addSubview:closeButton];
    [NSLayoutConstraint activateConstraints:@[
        [closeButton.topAnchor
            constraintEqualToAnchor:viewController.view.safeAreaLayoutGuide.topAnchor
                           constant:8.0],
        [closeButton.trailingAnchor
            constraintEqualToAnchor:viewController.view.safeAreaLayoutGuide.trailingAnchor
                           constant:-12.0],
        [closeButton.widthAnchor constraintGreaterThanOrEqualToConstant:56.0],
        [closeButton.heightAnchor constraintEqualToConstant:36.0],
    ]];

    self.window = window;
    self.viewController = viewController;
    self.imageView = imageView;
    self.closeButton = closeButton;

    window.hidden = NO;
    [window makeKeyAndVisible];
    [window layoutIfNeeded];
    FLMEnqueueDiagnosticLine(@"[ScreenSense] overlay present success");

    self.state = FMScreenSenseStateAnalyzing;
    self.analysisStartedAt = CACurrentMediaTime();
    self.visionBridge = [[FMScreenSenseVisionBridge alloc] init];
    [self.visionBridge setPresentingViewController:self.viewController];
    FLMEnqueueDiagnosticLine(@"[ScreenSense][Vision] bridge created");
    FLMEnqueueDiagnosticLine(
        @"[ScreenSense][Translation] provider=system-live-text network=disabled");

    BOOL supported = [FMScreenSenseVisionBridge isSupported];
    FLMEnqueueDiagnosticLine(@"[ScreenSense][Vision] ImageAnalyzer supported=%d",
                             supported ? 1 : 0);
    if (!supported) {
        [self abortVisionWithErrorCode:1
                               message:@"ImageAnalyzer is not supported"];
        return;
    }

    FLMEnqueueDiagnosticLine(@"[ScreenSense][Vision] analysis begin");
    __weak FMScreenSenseSession *weakSelf = self;
    [self.visionBridge setSelectionHandler:^(BOOL active,
                                             NSInteger selectedLength,
                                             NSInteger fullLength) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Selection] source=delegate active=%d selectedRangeCount=%ld selectedTextLength=%ld fullTextLength=%ld",
            active ? 1 : 0, (long)weakSelf.visionBridge.selectedRangeCount,
            (long)selectedLength, (long)fullLength);
    }];
    [self.visionBridge setVisionStateHandler:^(BOOL highlighted,
                                               NSUInteger activeInteractionTypes) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][VisionState] highlightSelectedItemsDidChange=%d activeInteractionTypes=%lu",
             highlighted ? 1 : 0, (unsigned long)activeInteractionTypes);
    }];
    [self.visionBridge attachLiveTextTo:imageView
                                  image:image
                             completion:^(BOOL success, NSError *error) {
        FMScreenSenseSession *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.generation != sessionGeneration ||
            strongSelf.state != FMScreenSenseStateAnalyzing) {
            return;
        }

        CFTimeInterval elapsed =
            (CACurrentMediaTime() - strongSelf.analysisStartedAt) * 1000.0;
        if (!success) {
            NSString *message = error.localizedDescription.length > 0
                                    ? error.localizedDescription
                                    : @"unknown VisionKit error";
            FLMEnqueueDiagnosticLine(
                @"[ScreenSense][Vision][ERROR] analysis failed error=%@ elapsed=%.2f",
                message, elapsed);
            [strongSelf dismissOnMainThread];
            return;
        }

        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Vision] analysis success elapsed=%.2f", elapsed);
        FLMEnqueueDiagnosticLine(@"[ScreenSense][Vision] interaction created");
        FLMEnqueueDiagnosticLine(@"[ScreenSense][Vision] interaction attached");
        FMScreenSenseVisionBridge *bridge = strongSelf.visionBridge;
        FMScreenSenseWindow *overlayWindow = strongSelf.window;
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Selection] active=%d selectedRangeCount=%ld selectedTextLength=%ld fullTextLength=%ld",
            bridge.hasActiveTextSelection ? 1 : 0,
            (long)bridge.selectedRangeCount,
            (long)bridge.currentSelectedText.length,
            (long)bridge.currentFullText.length);
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Vision] preferredInteractionTypes=%lu supplementaryHidden=%d selectableItemsHighlighted=%d",
            (unsigned long)bridge.preferredInteractionTypesRawValue,
            bridge.supplementaryInterfaceHidden ? 1 : 0,
            bridge.selectableItemsHighlighted ? 1 : 0);
        CGRect imageViewBounds = bridge.interactionImageViewBounds;
        CGSize imageSize = bridge.interactionImageSize;
        CGRect contentsRect = bridge.interactionContentsRect;
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][VisionGeometry] interactionViewIsImageView=%d imageViewBounds={%.1f,%.1f,%.1f,%.1f} contentMode=%ld imageSize={%.1f,%.1f} contentsRect={%.3f,%.3f,%.3f,%.3f}",
            bridge.interactionViewMatchesImageView ? 1 : 0,
            imageViewBounds.origin.x, imageViewBounds.origin.y,
            imageViewBounds.size.width, imageViewBounds.size.height,
            (long)bridge.interactionImageViewContentModeRawValue,
            imageSize.width, imageSize.height,
            contentsRect.origin.x, contentsRect.origin.y,
            contentsRect.size.width, contentsRect.size.height);
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Overlay] windowClass=%@ isHidden=%d isKeyWindow=%d windowLevel=%.1f windowScene=%@ rootViewController=%@ imageView.window=%@",
            NSStringFromClass([overlayWindow class]), overlayWindow.isHidden ? 1 : 0,
            overlayWindow.isKeyWindow ? 1 : 0, overlayWindow.windowLevel,
            overlayWindow.windowScene ? @"yes" : @"no",
            NSStringFromClass([overlayWindow.rootViewController class]),
            strongSelf.imageView.window
                ? NSStringFromClass([strongSelf.imageView.window class])
                : @"<nil>");
        strongSelf.state = FMScreenSenseStateActive;
        FLMEnqueueDiagnosticLine(@"[ScreenSense] state=active");
    }];
}

- (void)handleCloseButton:(UIButton *)sender {
    sender.userInteractionEnabled = NO;
    FLMEnqueueDiagnosticLine(@"[ScreenSense] close button request");

    // Finish the current button event before removing the key window. Doing
    // the teardown synchronously from UIControl's touch-up callback can let
    // the same touch continue into the host app's window on iOS 16.
    __weak FMScreenSenseSession *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf dismiss];
    });
}

- (void)dismiss {
    if (![NSThread isMainThread]) {
        __weak FMScreenSenseSession *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf dismiss];
        });
        return;
    }

    FLMEnqueueDiagnosticLine(
        @"[ScreenSense] dismiss request state=%@",
        FMScreenSenseStateName(self.state));
    [self dismissOnMainThread];
}

- (void)abortVisionWithErrorCode:(NSInteger)code message:(NSString *)message {
    FLMEnqueueDiagnosticLine(
        @"[ScreenSense][Vision][ERROR] unavailable code=%ld message=%@",
        (long)code, message ?: @"unknown");
    [self dismissOnMainThread];
}

- (void)dismissOnMainThread {
    NSAssert([NSThread isMainThread], @"ScreenSense cleanup must run on main thread");
    if (self.state == FMScreenSenseStateInactive) {
        return;
    }

    self.state = FMScreenSenseStateDismissing;
    FLMEnqueueDiagnosticLine(@"[ScreenSense] dismiss begin");
    self.generation += 1;

    FMScreenSenseVisionBridge *bridge = self.visionBridge;
    if (bridge) {
        [bridge teardown];
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Selection] active=%d selectedRangeCount=%ld selectedTextLength=%ld fullTextLength=%ld",
            bridge.hasActiveTextSelection ? 1 : 0,
            (long)bridge.selectedRangeCount,
            (long)bridge.currentSelectedText.length,
            (long)bridge.currentFullText.length);
    }
    self.visionBridge = nil;

    FMScreenSenseWindow *overlayWindow = self.window;
    UIImageView *imageView = self.imageView;
    imageView.userInteractionEnabled = NO;
    imageView.image = nil;
    overlayWindow.userInteractionEnabled = NO;
    self.closeButton.userInteractionEnabled = NO;

    UIWindow *previousKeyWindow = self.previousKeyWindow;
    self.previousKeyWindow = nil;
    [overlayWindow resignKeyWindow];
    overlayWindow.hidden = YES;

    self.closeButton = nil;
    self.imageView = nil;
    self.viewController = nil;
    self.window = nil;
    self.analysisStartedAt = 0.0;
    self.state = FMScreenSenseStateInactive;
    FLMEnqueueDiagnosticLine(@"[ScreenSense] cleanup completed");

    // Restore the host window after the close button's touch has fully
    // unwound. Restoring it synchronously from the overlay callback can cause
    // iOS 16 to deliver the same touch into the host app, which looks like an
    // app close/crash to the user.
    __weak FMScreenSenseSession *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        FMScreenSenseSession *strongSelf = weakSelf;
        if (previousKeyWindow &&
            previousKeyWindow.windowScene.activationState !=
                UISceneActivationStateUnattached &&
            previousKeyWindow != overlayWindow) {
            if (previousKeyWindow.isHidden) {
                previousKeyWindow.hidden = NO;
            }
            [previousKeyWindow makeKeyWindow];
            FLMEnqueueDiagnosticLine(
                @"[ScreenSense] host window restored class=%@ key=%d hidden=%d",
                NSStringFromClass([previousKeyWindow class]),
                previousKeyWindow.isKeyWindow ? 1 : 0,
                previousKeyWindow.isHidden ? 1 : 0);
        } else {
            FLMEnqueueDiagnosticLine(
                @"[ScreenSense] host window restore skipped previous=%@",
                previousKeyWindow ? @"unavailable" : @"nil");
        }

        // Detach the hidden overlay's controller only after the event turn.
        // This keeps all UIKit callbacks inside the overlay alive until the
        // close touch has completed.
        overlayWindow.rootViewController = nil;
        (void)strongSelf;
    });
}

@end
