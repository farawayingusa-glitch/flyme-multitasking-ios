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

@interface FMScreenSenseSession () <UITextViewDelegate, UIEditMenuInteractionDelegate>
@property(nonatomic, assign) FMScreenSenseState state;
@property(nonatomic, assign) NSUInteger generation;
@property(nonatomic, assign) CFTimeInterval analysisStartedAt;
@property(nonatomic, strong) FMScreenSenseWindow *window;
@property(nonatomic, strong) FMScreenSenseViewController *viewController;
@property(nonatomic, strong) UIImageView *imageView;
@property(nonatomic, strong) UIButton *closeButton;
@property(nonatomic, strong) UIView *actionBar;
@property(nonatomic, strong) UIButton *screenSenseCopyButton;
@property(nonatomic, strong) UIButton *translateButton;
@property(nonatomic, strong) UIView *textActionPanel;
@property(nonatomic, strong) UITextView *textActionView;
@property(nonatomic, strong) UIButton *textActionCloseButton;
@property(nonatomic, strong) UIEditMenuInteraction *editMenuInteraction;
@property(nonatomic, strong) UIWindow *previousKeyWindow;
@property(nonatomic, strong) FMScreenSenseVisionBridge *visionBridge;
- (void)dismissOnMainThread;
- (void)abortVisionWithErrorCode:(NSInteger)code message:(NSString *)message;
- (void)installActionBarInViewController:(UIViewController *)viewController;
- (void)refreshActionButtonTitles;
- (BOOL)hasReadableTextSelection;
- (NSString *)currentActionText;
- (void)handleCopyButton:(UIButton *)sender;
- (void)handleTranslateButton:(UIButton *)sender;
- (void)presentTranslatePanelForText:(NSString *)text;
- (void)dismissTextActionPanel;
- (void)textViewDidChangeSelection:(UITextView *)textView;
- (BOOL)performDirectTranslateOnTextView:(UITextView *)textView;
- (void)showEditMenuForTextView:(UITextView *)textView;
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
    window.windowLevel = UIWindowLevelAlert + 120.0;
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
                    action:@selector(dismiss)
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

    [self installActionBarInViewController:viewController];

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
        [weakSelf refreshActionButtonTitles];
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Selection] source=delegate active=%d selectedTextLength=%ld fullTextLength=%ld",
            active ? 1 : 0, (long)selectedLength, (long)fullLength);
    }];
    [self.visionBridge setVisionStateHandler:^(BOOL highlighted,
                                               NSUInteger activeInteractionTypes) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][VisionState] highlightSelectedItemsDidChange=%d activeInteractionTypes=%lu",
            highlighted ? 1 : 0, (unsigned long)activeInteractionTypes);
    }];
    [self.visionBridge setVisionGestureHandler:^(CGPoint point,
                                                 NSUInteger interactionTypes,
                                                 BOOL hasText,
                                                 BOOL analysisHasText) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][VisionGesture] shouldBegin point={%.1f,%.1f} typesRaw=%lu hasText=%d analysisHasText=%d",
            point.x, point.y, (unsigned long)interactionTypes,
            hasText ? 1 : 0, analysisHasText ? 1 : 0);
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
            @"[ScreenSense][Selection] active=%d selectedTextLength=%ld fullTextLength=%ld",
            bridge.hasActiveTextSelection ? 1 : 0,
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

- (void)installActionBarInViewController:(UIViewController *)viewController {
    UIView *actionBar = [[UIView alloc] initWithFrame:CGRectZero];
    actionBar.translatesAutoresizingMaskIntoConstraints = NO;
    actionBar.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
    actionBar.layer.cornerRadius = 14.0;
    actionBar.layer.masksToBounds = YES;
    actionBar.accessibilityIdentifier =
        @"com.codex.flymemultitasking.screensense.actions";

    UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButton *translateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    NSArray<UIButton *> *buttons = @[copyButton, translateButton];
    for (UIButton *button in buttons) {
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.titleLabel.font =
            [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        [button setTitleColor:[UIColor whiteColor]
                      forState:UIControlStateNormal];
        [button setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.55]
                      forState:UIControlStateHighlighted];
        button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
        button.layer.cornerRadius = 10.0;
        button.layer.masksToBounds = YES;
    }
    copyButton.accessibilityLabel = @"复制识屏文字";
    copyButton.accessibilityIdentifier =
        @"com.codex.flymemultitasking.screensense.copy";
    translateButton.accessibilityLabel = @"翻译识屏文字";
    translateButton.accessibilityIdentifier =
        @"com.codex.flymemultitasking.screensense.translate";
    [copyButton addTarget:self
                   action:@selector(handleCopyButton:)
         forControlEvents:UIControlEventTouchUpInside];
    [translateButton addTarget:self
                        action:@selector(handleTranslateButton:)
              forControlEvents:UIControlEventTouchUpInside];

    [actionBar addSubview:copyButton];
    [actionBar addSubview:translateButton];
    [viewController.view addSubview:actionBar];
    [NSLayoutConstraint activateConstraints:@[
        [actionBar.leadingAnchor
            constraintEqualToAnchor:viewController.view.safeAreaLayoutGuide.leadingAnchor
                           constant:12.0],
        [actionBar.trailingAnchor
            constraintEqualToAnchor:viewController.view.safeAreaLayoutGuide.trailingAnchor
                           constant:-12.0],
        [actionBar.bottomAnchor
            constraintEqualToAnchor:viewController.view.safeAreaLayoutGuide.bottomAnchor
                           constant:-8.0],
        [actionBar.heightAnchor constraintEqualToConstant:48.0],
        [copyButton.leadingAnchor constraintEqualToAnchor:actionBar.leadingAnchor
                                                  constant:6.0],
        [copyButton.topAnchor constraintEqualToAnchor:actionBar.topAnchor
                                              constant:6.0],
        [copyButton.bottomAnchor constraintEqualToAnchor:actionBar.bottomAnchor
                                                 constant:-6.0],
        [translateButton.leadingAnchor constraintEqualToAnchor:copyButton.trailingAnchor
                                                       constant:6.0],
        [translateButton.trailingAnchor constraintEqualToAnchor:actionBar.trailingAnchor
                                                        constant:-6.0],
        [translateButton.topAnchor constraintEqualToAnchor:actionBar.topAnchor
                                                   constant:6.0],
        [translateButton.bottomAnchor constraintEqualToAnchor:actionBar.bottomAnchor
                                                      constant:-6.0],
        [translateButton.widthAnchor constraintEqualToAnchor:copyButton.widthAnchor],
    ]];

    self.actionBar = actionBar;
    self.screenSenseCopyButton = copyButton;
    self.translateButton = translateButton;
    [self refreshActionButtonTitles];
}

- (BOOL)hasReadableTextSelection {
    UITextView *textActionView = self.textActionView;
    if (textActionView.superview && textActionView.selectedRange.length > 0 &&
        NSMaxRange(textActionView.selectedRange) <= textActionView.text.length) {
        return YES;
    }

    return self.visionBridge.currentSelectedText.length > 0;
}

- (NSString *)currentActionText {
    UITextView *textActionView = self.textActionView;
    if (textActionView.superview && textActionView.selectedRange.length > 0 &&
        NSMaxRange(textActionView.selectedRange) <= textActionView.text.length) {
        return [textActionView.text substringWithRange:textActionView.selectedRange];
    }

    NSString *selectedText = self.visionBridge.currentSelectedText;
    if (selectedText.length > 0) {
        return selectedText;
    }

    return self.visionBridge.currentFullText ?: @"";
}

- (void)refreshActionButtonTitles {
    if (!self.screenSenseCopyButton || !self.translateButton) {
        return;
    }

    BOOL hasSelection = [self hasReadableTextSelection];
    [self.screenSenseCopyButton setTitle:hasSelection ? @"复制所选" : @"复制全部"
                              forState:UIControlStateNormal];
    [self.translateButton setTitle:hasSelection ? @"翻译所选" : @"翻译全部"
                          forState:UIControlStateNormal];
}

- (void)handleCopyButton:(UIButton *)sender {
    NSString *text = [self currentActionText];
    if (text.length == 0) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Action][ERROR] copy ignored reason=empty-text");
        return;
    }

    BOOL hasSelection = [self hasReadableTextSelection];
    [UIPasteboard generalPasteboard].string = text;
    FLMEnqueueDiagnosticLine(
        @"[ScreenSense][Action] copy mode=%@ textLength=%ld",
        hasSelection ? @"selection" : @"full", (long)text.length);

    [sender setTitle:@"已复制" forState:UIControlStateNormal];
    NSUInteger sessionGeneration = self.generation;
    __weak FMScreenSenseSession *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FMScreenSenseSession *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.generation != sessionGeneration ||
            strongSelf.state == FMScreenSenseStateInactive) {
            return;
        }
        [strongSelf refreshActionButtonTitles];
    });
}

- (void)handleTranslateButton:(UIButton *)sender {
    (void)sender;
    NSString *text = [self currentActionText];
    if (text.length == 0) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Action][ERROR] translate ignored reason=empty-text");
        return;
    }

    BOOL hasSelection = [self hasReadableTextSelection];
    FLMEnqueueDiagnosticLine(
        @"[ScreenSense][Action] translate requested mode=%@ textLength=%ld",
        hasSelection ? @"selection" : @"full", (long)text.length);
    [self presentTranslatePanelForText:text];
}

- (void)presentTranslatePanelForText:(NSString *)text {
    [self dismissTextActionPanel];

    if (!self.viewController || text.length == 0) {
        return;
    }

    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.96];
    panel.layer.cornerRadius = 14.0;
    panel.layer.masksToBounds = YES;
    panel.accessibilityIdentifier =
        @"com.codex.flymemultitasking.screensense.translate-panel";

    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [closeButton setTitle:@"返回识屏" forState:UIControlStateNormal];
    [closeButton setTitleColor:[UIColor whiteColor]
                       forState:UIControlStateNormal];
    closeButton.titleLabel.font =
        [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    [closeButton addTarget:self
                    action:@selector(dismissTextActionPanel)
          forControlEvents:UIControlEventTouchUpInside];
    closeButton.accessibilityLabel = @"返回识屏画面";

    UITextView *textView = [[UITextView alloc] initWithFrame:CGRectZero];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.backgroundColor = [UIColor clearColor];
    textView.textColor = [UIColor whiteColor];
    textView.tintColor = [UIColor systemBlueColor];
    textView.font = [UIFont systemFontOfSize:17.0];
    textView.editable = NO;
    textView.selectable = YES;
    textView.scrollEnabled = YES;
    textView.delegate = self;
    textView.text = text;
    textView.accessibilityLabel = @"识别出的文字，可选择后翻译或复制";
    textView.accessibilityIdentifier =
        @"com.codex.flymemultitasking.screensense.recognized-text";

    [panel addSubview:closeButton];
    [panel addSubview:textView];
    [self.viewController.view addSubview:panel];

    NSLayoutConstraint *bottomConstraint =
        [panel.bottomAnchor constraintEqualToAnchor:self.actionBar.topAnchor
                                           constant:-8.0];
    [NSLayoutConstraint activateConstraints:@[
        [panel.leadingAnchor
            constraintEqualToAnchor:self.viewController.view.safeAreaLayoutGuide.leadingAnchor
                           constant:12.0],
        [panel.trailingAnchor
            constraintEqualToAnchor:self.viewController.view.safeAreaLayoutGuide.trailingAnchor
                           constant:-12.0],
        [panel.topAnchor
            constraintEqualToAnchor:self.viewController.view.safeAreaLayoutGuide.topAnchor
                           constant:52.0],
        bottomConstraint,
        [closeButton.topAnchor constraintEqualToAnchor:panel.topAnchor constant:6.0],
        [closeButton.trailingAnchor
            constraintEqualToAnchor:panel.trailingAnchor
                           constant:-8.0],
        [closeButton.heightAnchor constraintEqualToConstant:32.0],
        [closeButton.widthAnchor constraintGreaterThanOrEqualToConstant:76.0],
        [textView.topAnchor constraintEqualToAnchor:closeButton.bottomAnchor
                                            constant:2.0],
        [textView.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor
                                               constant:8.0],
        [textView.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor
                                                constant:-8.0],
        [textView.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor
                                               constant:-8.0],
    ]];

    self.textActionPanel = panel;
    self.textActionView = textView;
    self.textActionCloseButton = closeButton;
    UIEditMenuInteraction *editMenuInteraction =
        [[UIEditMenuInteraction alloc] initWithDelegate:self];
    [textView addInteraction:editMenuInteraction];
    self.editMenuInteraction = editMenuInteraction;

    [self.viewController.view layoutIfNeeded];
    [textView becomeFirstResponder];
    textView.selectedRange = NSMakeRange(0, textView.text.length);
    [self refreshActionButtonTitles];

    if (![self performDirectTranslateOnTextView:textView]) {
        [self showEditMenuForTextView:textView];
    }
}

- (void)dismissTextActionPanel {
    UITextView *textView = self.textActionView;
    if (textView) {
        [textView resignFirstResponder];
    }
    [self.textActionPanel removeFromSuperview];
    self.editMenuInteraction = nil;
    self.textActionCloseButton = nil;
    self.textActionView = nil;
    self.textActionPanel = nil;
    [self refreshActionButtonTitles];
}

- (void)textViewDidChangeSelection:(UITextView *)textView {
    if (textView == self.textActionView) {
        [self refreshActionButtonTitles];
    }
}

- (BOOL)performDirectTranslateOnTextView:(UITextView *)textView {
    SEL translateSelector = NSSelectorFromString(@"translate:");
    if (![textView canPerformAction:translateSelector withSender:nil]) {
        return NO;
    }

    IMP implementation = [textView methodForSelector:translateSelector];
    if (!implementation) {
        return NO;
    }

    typedef void (*FMScreenSenseTextAction)(id, SEL, id);
    FMScreenSenseTextAction invoke =
        (FMScreenSenseTextAction)implementation;
    invoke(textView, translateSelector, nil);
    FLMEnqueueDiagnosticLine(
        @"[ScreenSense][Action] translate dispatched system-action=1");
    return YES;
}

- (void)showEditMenuForTextView:(UITextView *)textView {
    if (!textView.window || !self.editMenuInteraction) {
        return;
    }

    CGPoint sourcePoint = CGPointMake(CGRectGetMidX(textView.bounds),
                                      CGRectGetMidY(textView.bounds));
    UIEditMenuConfiguration *configuration =
        [UIEditMenuConfiguration configurationWithIdentifier:nil
                                                 sourcePoint:sourcePoint];
    [self.editMenuInteraction presentEditMenuWithConfiguration:configuration];
    FLMEnqueueDiagnosticLine(
        @"[ScreenSense][Action] translate presented native-edit-menu=1");
}

- (UIMenu *)editMenuInteraction:(UIEditMenuInteraction *)interaction
          menuForConfiguration:(UIEditMenuConfiguration *)configuration
              suggestedActions:(NSArray<UIMenuElement *> *)suggestedActions {
    (void)interaction;
    (void)configuration;
    return [UIMenu menuWithChildren:suggestedActions];
}

- (void)dismiss {
    if (![NSThread isMainThread]) {
        __weak FMScreenSenseSession *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf dismiss];
        });
        return;
    }

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
    [self dismissTextActionPanel];

    FMScreenSenseVisionBridge *bridge = self.visionBridge;
    if (bridge) {
        [bridge teardown];
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Selection] active=%d selectedTextLength=%ld fullTextLength=%ld",
            bridge.hasActiveTextSelection ? 1 : 0,
            (long)bridge.currentSelectedText.length,
            (long)bridge.currentFullText.length);
    }
    self.visionBridge = nil;

    self.imageView.userInteractionEnabled = NO;
    self.imageView.image = nil;
    self.window.userInteractionEnabled = NO;
    self.window.hidden = YES;
    self.closeButton.userInteractionEnabled = NO;
    self.actionBar.userInteractionEnabled = NO;
    self.screenSenseCopyButton.userInteractionEnabled = NO;
    self.translateButton.userInteractionEnabled = NO;

    UIWindow *previousKeyWindow = self.previousKeyWindow;
    self.previousKeyWindow = nil;
    if (previousKeyWindow && previousKeyWindow.windowScene.activationState !=
                                 UISceneActivationStateUnattached) {
        [previousKeyWindow makeKeyAndVisible];
    }

    self.closeButton = nil;
    self.actionBar = nil;
    self.screenSenseCopyButton = nil;
    self.translateButton = nil;
    self.imageView = nil;
    self.viewController = nil;
    self.window = nil;
    self.analysisStartedAt = 0.0;
    self.state = FMScreenSenseStateInactive;
    FLMEnqueueDiagnosticLine(@"[ScreenSense] cleanup completed");
}

@end
