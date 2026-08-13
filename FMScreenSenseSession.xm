#import "FMScreenSenseSession.h"

#import <QuartzCore/QuartzCore.h>

#import "FLMDiagnostics.h"
#import "FMScreenSenseTranslation.h"
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

static BOOL FMScreenSenseDeviceIsLocked(void) {
    id manager = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
    if (!manager) {
        return NO;
    }
    for (NSString *name in @[
             @"isUILocked", @"isLockScreenVisible", @"isLockScreenActive", @"isLocked"
         ]) {
        SEL selector = NSSelectorFromString(name);
        if (![manager respondsToSelector:selector]) {
            continue;
        }
        @try {
            BOOL (*getter)(id, SEL) =
                (BOOL (*)(id, SEL))[manager methodForSelector:selector];
            if (getter && getter(manager, selector)) {
                return YES;
            }
        } @catch (__unused NSException *exception) {
        }
    }
    return NO;
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

- (BOOL)canBecomeFirstResponder {
    // VisionKit presents Copy/Translate through UIKit's text-action responder
    // chain. The custom SpringBoard controller must be eligible to host that
    // chain; otherwise iOS 16 still draws the Live Text selection handles but
    // drops the action menu after the selection becomes active.
    return YES;
}

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
@property(nonatomic, strong) UIButton *translateButton;
@property(nonatomic, strong) UITextView *translationView;
@property(nonatomic, strong) UIWindow *previousKeyWindow;
@property(nonatomic, strong) FMScreenSenseVisionBridge *visionBridge;
@property(nonatomic, strong) NSTimer *lifecycleTimer;
@property(nonatomic, assign) BOOL translationRequestInFlight;
@property(nonatomic, assign) BOOL lastKnownSelectionActive;
- (void)startLifecycleMonitoring;
- (void)stopLifecycleMonitoring;
- (void)handleSystemLifecycleNotification:(NSNotification *)notification;
- (void)checkLifecycleTimer:(NSTimer *)timer;
- (void)dismissOnMainThread;
- (void)abortVisionWithErrorCode:(NSInteger)code message:(NSString *)message;
- (void)handleCloseButton:(UIButton *)sender;
- (void)handleTranslateButton:(UIButton *)sender;
- (void)resolveTranslationTextWithCompletion:(void (^)(NSString *_Nullable text,
                                                       BOOL selected,
                                                       NSError *_Nullable error))completion;
- (void)finishSelectionCopyWithPasteboard:(UIPasteboard *)pasteboard
                         beforeChangeCount:(NSInteger)beforeChangeCount
                              originalItems:(NSArray *)originalItems
                                    attempt:(NSUInteger)attempt
                                completion:(void (^)(NSString *_Nullable text,
                                                      BOOL selected,
                                                      NSError *_Nullable error))completion;
- (void)showTranslationError:(NSError *)error;
- (void)showTranslationResult:(NSString *)result;
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
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self
                   selector:@selector(handleSystemLifecycleNotification:)
                       name:UIApplicationProtectedDataWillBecomeUnavailableNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(handleSystemLifecycleNotification:)
                       name:UIApplicationDidEnterBackgroundNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(handleSystemLifecycleNotification:)
                       name:UIApplicationDidBecomeActiveNotification
                     object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_lifecycleTimer invalidate];
}

- (BOOL)beginCaptureSession {
    if (![NSThread isMainThread]) {
        __block BOOL accepted = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            accepted = [self beginCaptureSession];
        });
        return accepted;
    }

    if (FMScreenSenseDeviceIsLocked()) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][ERROR] trigger ignored device-locked");
        return NO;
    }

    if (self.state != FMScreenSenseStateInactive) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense] duplicate trigger ignored state=%@",
            FMScreenSenseStateName(self.state));
        return NO;
    }

    self.generation += 1;
    self.state = FMScreenSenseStateDismissingWheel;
    [self startLifecycleMonitoring];
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

    if (FMScreenSenseDeviceIsLocked()) {
        [self abortCaptureWithReason:@"device-locked-before-overlay"];
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
    // Keep the frozen screen just above the current host window. Live Text's
    // text-effects and translation windows are higher than the normal window
    // level on iOS 16; using Alert+1 here leaves the selection visible but
    // covers the native Copy/Translate menu.
    CGFloat hostWindowLevel = self.previousKeyWindow
                                  ? self.previousKeyWindow.windowLevel
                                  : UIWindowLevelNormal;
    window.windowLevel = MAX(UIWindowLevelNormal + 0.5, hostWindowLevel + 0.5);
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

    UIButton *translateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [translateButton setTitle:@"识别中…" forState:UIControlStateNormal];
    [translateButton setTitleColor:[UIColor whiteColor]
                          forState:UIControlStateNormal];
    [translateButton setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.55]
                          forState:UIControlStateDisabled];
    translateButton.titleLabel.font =
        [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    translateButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.62];
    translateButton.layer.cornerRadius = 18.0;
    translateButton.layer.masksToBounds = YES;
    translateButton.accessibilityLabel = @"翻译识别到的文字";
    translateButton.translatesAutoresizingMaskIntoConstraints = NO;
    translateButton.enabled = NO;
    [translateButton addTarget:self
                        action:@selector(handleTranslateButton:)
              forControlEvents:UIControlEventTouchUpInside];
    [viewController.view addSubview:translateButton];

    UITextView *translationView = [[UITextView alloc] initWithFrame:CGRectZero];
    translationView.translatesAutoresizingMaskIntoConstraints = NO;
    translationView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
    translationView.textColor = [UIColor whiteColor];
    translationView.font = [UIFont systemFontOfSize:17.0];
    translationView.layer.cornerRadius = 14.0;
    translationView.layer.masksToBounds = YES;
    translationView.editable = NO;
    translationView.selectable = YES;
    translationView.scrollEnabled = YES;
    translationView.hidden = YES;
    translationView.textContainerInset = UIEdgeInsetsMake(14.0, 12.0, 14.0, 12.0);
    translationView.accessibilityLabel = @"翻译结果";
    [viewController.view addSubview:translationView];
    [NSLayoutConstraint activateConstraints:@[
        [translateButton.centerXAnchor
            constraintEqualToAnchor:viewController.view.centerXAnchor],
        [translateButton.bottomAnchor
            constraintEqualToAnchor:viewController.view.safeAreaLayoutGuide.bottomAnchor
                           constant:-12.0],
        [translateButton.widthAnchor constraintGreaterThanOrEqualToConstant:96.0],
        [translateButton.heightAnchor constraintEqualToConstant:36.0],
        [translationView.leadingAnchor
            constraintEqualToAnchor:viewController.view.leadingAnchor
                           constant:16.0],
        [translationView.trailingAnchor
            constraintEqualToAnchor:viewController.view.trailingAnchor
                           constant:-16.0],
        [translationView.bottomAnchor
            constraintEqualToAnchor:translateButton.topAnchor
                           constant:-12.0],
        [translationView.heightAnchor constraintEqualToConstant:164.0],
    ]];

    self.window = window;
    self.viewController = viewController;
    self.imageView = imageView;
    self.closeButton = closeButton;
    self.translateButton = translateButton;
    self.translationView = translationView;
    self.translationRequestInFlight = NO;
    self.lastKnownSelectionActive = NO;

    window.hidden = NO;
    [window makeKeyAndVisible];
    BOOL becameFirstResponder = [viewController becomeFirstResponder];
    FLMEnqueueDiagnosticLine(
        @"[ScreenSense][Vision] action-responder controller=%d windowLevel=%.1f",
        becameFirstResponder ? 1 : 0, window.windowLevel);
    [window layoutIfNeeded];
    FLMEnqueueDiagnosticLine(@"[ScreenSense] overlay present success");

    self.state = FMScreenSenseStateAnalyzing;
    self.analysisStartedAt = CACurrentMediaTime();
    self.visionBridge = [[FMScreenSenseVisionBridge alloc] init];
    [self.visionBridge setPresentingViewController:self.viewController];
    FLMEnqueueDiagnosticLine(@"[ScreenSense][Vision] bridge created");
    FLMEnqueueDiagnosticLine(
        @"[ScreenSense][Translation] route=web target=%@",
        [[FMScreenSenseTranslation sharedService] targetLanguage]);

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
        weakSelf.lastKnownSelectionActive = active;
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
        strongSelf.translateButton.enabled = YES;
        [strongSelf.translateButton setTitle:@"翻译" forState:UIControlStateNormal];
        FLMEnqueueDiagnosticLine(@"[ScreenSense] state=active");
    }];
}

- (void)handleTranslateButton:(UIButton *)sender {
    (void)sender;
    if (self.translationRequestInFlight ||
        self.state != FMScreenSenseStateActive || !self.visionBridge) {
        return;
    }

    self.translationRequestInFlight = YES;
    self.translateButton.enabled = NO;
    [self.translateButton setTitle:@"处理中…" forState:UIControlStateNormal];
    NSUInteger sessionGeneration = self.generation;
    __weak FMScreenSenseSession *weakSelf = self;
    [self resolveTranslationTextWithCompletion:^(NSString *text,
                                                  BOOL selected,
                                                  NSError *error) {
        FMScreenSenseSession *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.generation != sessionGeneration ||
            strongSelf.state != FMScreenSenseStateActive) {
            return;
        }

        if (error || text.length == 0) {
            [strongSelf showTranslationError:error ?: [NSError errorWithDomain:
                @"com.codex.flymemultitasking.translation"
                                                          code:5
                                                      userInfo:@{
                NSLocalizedDescriptionKey : @"没有识别到可翻译的文字"
            }]];
            strongSelf.translationRequestInFlight = NO;
            strongSelf.translateButton.enabled = YES;
            [strongSelf.translateButton setTitle:@"翻译" forState:UIControlStateNormal];
            return;
        }

        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Translation] start route=web source=%@ textLength=%lu",
            selected ? @"selected" : @"all", (unsigned long)text.length);

        NSURL *url = [[FMScreenSenseTranslation sharedService]
            webURLForText:text];
        if (!url) {
            [strongSelf showTranslationError:[NSError errorWithDomain:
                @"com.codex.flymemultitasking.translation"
                                                          code:6
                                                      userInfo:@{
                NSLocalizedDescriptionKey : @"无法生成 Google 翻译链接"
            }]];
            strongSelf.translationRequestInFlight = NO;
            strongSelf.translateButton.enabled = YES;
            [strongSelf.translateButton setTitle:@"翻译" forState:UIControlStateNormal];
            return;
        }

        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Translation] route=web action=jump target=%@",
            [[FMScreenSenseTranslation sharedService] targetLanguage]);
        strongSelf.translationRequestInFlight = NO;
        [strongSelf dismissOnMainThread];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                      (int64_t)(0.18 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIApplication *application = [UIApplication sharedApplication];
            if (![application respondsToSelector:
                              @selector(openURL:options:completionHandler:)]) {
                FLMEnqueueDiagnosticLine(
                    @"[ScreenSense][Translation][ERROR] web openURL unavailable");
                return;
            }
            [application openURL:url
                         options:@{}
               completionHandler:^(BOOL success) {
                FLMEnqueueDiagnosticLine(
                    @"[ScreenSense][Translation] route=web opened=%d",
                    success ? 1 : 0);
            }];
        });
    }];
}

- (void)resolveTranslationTextWithCompletion:(void (^)(NSString *_Nullable text,
                                                       BOOL selected,
                                                       NSError *_Nullable error))completion {
    FMScreenSenseVisionBridge *bridge = self.visionBridge;
    if (!bridge) {
        completion(nil, NO, [NSError errorWithDomain:
            @"com.codex.flymemultitasking.translation"
                                                  code:8
                                              userInfo:@{
            NSLocalizedDescriptionKey : @"识屏会话已结束"
        }]);
        return;
    }

    // Keep the last delegate state as a guard against the button touch
    // briefly taking focus away from the Live Text interaction itself.
    BOOL hasSelection = bridge.hasActiveTextSelection || self.lastKnownSelectionActive;
    NSString *publicSelectedText = bridge.currentSelectedText;
    if (publicSelectedText.length > 0) {
        completion([self normalizedTranslationText:publicSelectedText], YES, nil);
        return;
    }

    if (!hasSelection) {
        NSString *fullText = [self normalizedTranslationText:bridge.currentFullText];
        if (fullText.length == 0) {
            completion(nil, NO, [NSError errorWithDomain:
                @"com.codex.flymemultitasking.translation"
                                                      code:9
                                                  userInfo:@{
                NSLocalizedDescriptionKey : @"没有识别到文字"
            }]);
            return;
        }
        completion(fullText, NO, nil);
        return;
    }

    // iOS 16 exposes the active selection to Live Text but not its string.
    // Ask the native responder to copy exactly that selection, read it once,
    // and restore the user's previous pasteboard contents immediately.
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    NSArray *originalItems = [pasteboard.items copy] ?: @[];
    NSInteger beforeChangeCount = pasteboard.changeCount;
    BOOL copyDispatched = [bridge copyActiveTextSelection];
    FLMEnqueueDiagnosticLine(
        @"[ScreenSense][Selection] translation-copy dispatched=%d beforeChangeCount=%ld",
        copyDispatched ? 1 : 0, (long)beforeChangeCount);
    [self finishSelectionCopyWithPasteboard:pasteboard
                           beforeChangeCount:beforeChangeCount
                                originalItems:originalItems
                                      attempt:0
                                  completion:completion];
}

- (NSString *)normalizedTranslationText:(NSString *)text {
    if (![text isKindOfClass:[NSString class]]) {
        return @"";
    }
    NSString *normalized = [text stringByReplacingOccurrencesOfString:@"\u00a0"
                                                             withString:@" "];
    normalized = [normalized stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return normalized;
}

- (void)finishSelectionCopyWithPasteboard:(UIPasteboard *)pasteboard
                         beforeChangeCount:(NSInteger)beforeChangeCount
                              originalItems:(NSArray *)originalItems
                                    attempt:(NSUInteger)attempt
                                completion:(void (^)(NSString *_Nullable text,
                                                      BOOL selected,
                                                      NSError *_Nullable error))completion {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(0.10 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
        NSString *candidate = [self normalizedTranslationText:pasteboard.string];
        BOOL changed = pasteboard.changeCount != beforeChangeCount;
        if (changed && candidate.length > 0) {
            pasteboard.items = originalItems;
            FLMEnqueueDiagnosticLine(
                @"[ScreenSense][Selection] translation-copy success length=%lu",
                (unsigned long)candidate.length);
            completion(candidate, YES, nil);
            return;
        }

        if (attempt < 2) {
            [self finishSelectionCopyWithPasteboard:pasteboard
                                   beforeChangeCount:beforeChangeCount
                                        originalItems:originalItems
                                              attempt:attempt + 1
                                          completion:completion];
            return;
        }

        pasteboard.items = originalItems;
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Selection][ERROR] translation-copy unavailable changed=%d",
            changed ? 1 : 0);
        completion(nil, YES, [NSError errorWithDomain:
            @"com.codex.flymemultitasking.translation"
                                                  code:10
                                              userInfo:@{
            NSLocalizedDescriptionKey : @"无法读取当前选中的文字，请重新选择后再点翻译"
        }]);
    });
}

- (void)showTranslationResult:(NSString *)result {
    self.translationView.textColor = [UIColor whiteColor];
    self.translationView.text = result;
    self.translationView.hidden = NO;
    [self.translationView flashScrollIndicators];
}

- (void)showTranslationError:(NSError *)error {
    NSString *message = error.localizedDescription.length > 0
        ? error.localizedDescription
        : @"翻译失败，请检查翻译设置";
    self.translationView.textColor = [UIColor systemRedColor];
    self.translationView.text = [NSString stringWithFormat:@"翻译失败\n%@", message];
    self.translationView.hidden = NO;
    FLMEnqueueDiagnosticLine(
        @"[ScreenSense][Translation][ERROR] userMessageLength=%lu",
        (unsigned long)message.length);
}

- (void)startLifecycleMonitoring {
    if (self.lifecycleTimer.valid) {
        return;
    }
    self.lifecycleTimer =
        [NSTimer timerWithTimeInterval:0.25
                                target:self
                              selector:@selector(checkLifecycleTimer:)
                              userInfo:nil
                               repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.lifecycleTimer
                               forMode:NSRunLoopCommonModes];
}

- (void)stopLifecycleMonitoring {
    [self.lifecycleTimer invalidate];
    self.lifecycleTimer = nil;
}

- (void)handleSystemLifecycleNotification:(NSNotification *)notification {
    if (self.state == FMScreenSenseStateInactive) {
        return;
    }

    NSString *name = notification.name;
    if ([name isEqualToString:UIApplicationProtectedDataWillBecomeUnavailableNotification] ||
        [name isEqualToString:UIApplicationDidEnterBackgroundNotification]) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense] lifecycle notification=%@ action=dismiss",
            name);
        [self dismiss];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self checkLifecycleTimer:nil];
    });
}

- (void)checkLifecycleTimer:(NSTimer *)timer {
    (void)timer;
    if (self.state == FMScreenSenseStateInactive) {
        [self stopLifecycleMonitoring];
        return;
    }

    if (FMScreenSenseDeviceIsLocked()) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense] lifecycle watchdog locked action=dismiss state=%@",
            FMScreenSenseStateName(self.state));
        [self dismissOnMainThread];
        return;
    }

    if (self.state != FMScreenSenseStateAnalyzing &&
        self.state != FMScreenSenseStateActive) {
        return;
    }

    UIWindow *window = self.window;
    UIWindowScene *windowScene = window ? window.windowScene : nil;
    if (!window || window.hidden || !windowScene ||
        windowScene.activationState == UISceneActivationStateUnattached) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense] lifecycle watchdog invalid-window action=dismiss state=%@",
            FMScreenSenseStateName(self.state));
        [self dismissOnMainThread];
    }
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
    [self stopLifecycleMonitoring];
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
    self.translateButton = nil;
    self.translationView = nil;
    self.imageView = nil;
    self.viewController = nil;
    self.window = nil;
    self.analysisStartedAt = 0.0;
    self.translationRequestInFlight = NO;
    self.lastKnownSelectionActive = NO;
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
