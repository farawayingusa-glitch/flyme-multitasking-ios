#import "FMScreenSenseSession.h"

#import <QuartzCore/QuartzCore.h>
#import <Vision/Vision.h>

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

@interface FMScreenSenseTranslationOverlayView : UIView
- (void)showLoading;
- (void)showErrorMessage:(NSString *)message;
- (void)showTranslatedLines:(NSArray<NSString *> *)lines
                     frames:(NSArray<NSValue *> *)frames;
@end

@implementation FMScreenSenseTranslationOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        // This view is visual-only. Touches must continue to reach the
        // ImageAnalysisInteraction underneath it.
        self.userInteractionEnabled = NO;
        self.accessibilityIdentifier =
            @"com.codex.flymemultitasking.screensense.translation-overlay";
    }
    return self;
}

- (void)clearContent {
    for (UIView *subview in [self.subviews copy]) {
        [subview removeFromSuperview];
    }
}

- (UILabel *)statusLabelWithText:(NSString *)text {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.textColor = [UIColor whiteColor];
    label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    label.layer.cornerRadius = 9.0;
    label.layer.masksToBounds = YES;
    label.numberOfLines = 1;
    [self addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [label.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor
                                                          constant:24.0],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor
                                                           constant:-24.0],
        [label.heightAnchor constraintEqualToConstant:38.0],
    ]];
    return label;
}

- (void)showLoading {
    [self clearContent];
    [self statusLabelWithText:@"翻译中…"];
}

- (void)showErrorMessage:(NSString *)message {
    [self clearContent];
    [self statusLabelWithText:message.length > 0 ? message : @"翻译失败"];
}

- (void)showTranslatedLines:(NSArray<NSString *> *)lines
                     frames:(NSArray<NSValue *> *)frames {
    [self clearContent];

    NSUInteger count = MIN(lines.count, frames.count);
    for (NSUInteger index = 0; index < count; index++) {
        NSString *lineText = lines[index];
        if (lineText.length == 0) {
            continue;
        }

        CGRect frame = [frames[index] CGRectValue];
        frame = CGRectInset(frame, -3.0, -2.0);
        frame = CGRectIntersection(frame, self.bounds);
        if (CGRectIsEmpty(frame) || CGRectIsNull(frame)) {
            continue;
        }

        UILabel *label = [[UILabel alloc] initWithFrame:frame];
        label.text = lineText;
        label.textColor = [UIColor whiteColor];
        // Cover the original OCR line and place the translation at the same
        // coordinates. Keeping one label per source line avoids the large,
        // reflowed text panel used by the previous implementation.
        label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.82];
        label.font = [UIFont systemFontOfSize:
                                MAX(10.0, MIN(22.0, frame.size.height * 0.72))
                                weight:UIFontWeightMedium];
        label.textAlignment = NSTextAlignmentLeft;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.48;
        label.numberOfLines = 1;
        label.lineBreakMode = NSLineBreakByClipping;
        label.layer.cornerRadius = 3.0;
        label.layer.masksToBounds = YES;
        label.accessibilityLabel = lineText;
        [self addSubview:label];
    }

    if (self.subviews.count == 0) {
        [self showErrorMessage:@"没有可显示的翻译"];
    }
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
@property(nonatomic, strong) UIView *actionBar;
@property(nonatomic, strong) UIButton *translateButton;
@property(nonatomic, strong) FMScreenSenseTranslationOverlayView *translationOverlay;
@property(nonatomic, strong) NSURLSessionDataTask *translationTask;
@property(nonatomic, assign) NSUInteger translationRequestID;
@property(nonatomic, strong) UIWindow *previousKeyWindow;
@property(nonatomic, strong) FMScreenSenseVisionBridge *visionBridge;
- (void)dismissOnMainThread;
- (void)abortVisionWithErrorCode:(NSInteger)code message:(NSString *)message;
- (void)handleCloseButton:(UIButton *)sender;
- (void)installActionBarInViewController:(UIViewController *)viewController;
- (void)refreshActionButtonTitles;
- (void)handleTranslateButton:(UIButton *)sender;
- (void)cancelTranslation;
- (void)beginInPlaceTranslationForText:(NSString *)text
                           hasSelection:(BOOL)hasSelection;
- (void)performOCRForImage:(UIImage *)image
                  inBounds:(CGRect)bounds
                 completion:(void (^)(NSArray<NSString *> *lines,
                                      NSArray<NSValue *> *frames,
                                      NSError *error))completion;
- (void)requestTranslationForText:(NSString *)text
                        completion:(void (^)(NSString *translatedText,
                                             NSError *error))completion;
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

static CGRect FMScreenSenseAspectFitRect(CGSize imageSize, CGRect bounds) {
    if (imageSize.width <= 0.0 || imageSize.height <= 0.0 ||
        bounds.size.width <= 0.0 || bounds.size.height <= 0.0) {
        return bounds;
    }

    CGFloat scale = MIN(bounds.size.width / imageSize.width,
                        bounds.size.height / imageSize.height);
    CGSize fittedSize = CGSizeMake(imageSize.width * scale,
                                   imageSize.height * scale);
    return CGRectMake(CGRectGetMidX(bounds) - fittedSize.width * 0.5,
                      CGRectGetMidY(bounds) - fittedSize.height * 0.5,
                      fittedSize.width,
                      fittedSize.height);
}

- (void)installActionBarInViewController:(UIViewController *)viewController {
    UIView *actionBar = [[UIView alloc] initWithFrame:CGRectZero];
    actionBar.translatesAutoresizingMaskIntoConstraints = NO;
    actionBar.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
    actionBar.layer.cornerRadius = 14.0;
    actionBar.layer.masksToBounds = YES;
    actionBar.accessibilityIdentifier =
        @"com.codex.flymemultitasking.screensense.actions";

    UIButton *translateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    translateButton.translatesAutoresizingMaskIntoConstraints = NO;
    translateButton.titleLabel.font =
        [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    [translateButton setTitleColor:[UIColor whiteColor]
                          forState:UIControlStateNormal];
    [translateButton setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.55]
                          forState:UIControlStateHighlighted];
    translateButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    translateButton.layer.cornerRadius = 10.0;
    translateButton.layer.masksToBounds = YES;
    translateButton.accessibilityLabel = @"翻译识屏文字";
    translateButton.accessibilityIdentifier =
        @"com.codex.flymemultitasking.screensense.translate";
    [translateButton addTarget:self
                        action:@selector(handleTranslateButton:)
              forControlEvents:UIControlEventTouchUpInside];

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
        [translateButton.leadingAnchor constraintEqualToAnchor:actionBar.leadingAnchor
                                                       constant:6.0],
        [translateButton.trailingAnchor constraintEqualToAnchor:actionBar.trailingAnchor
                                                        constant:-6.0],
        [translateButton.topAnchor constraintEqualToAnchor:actionBar.topAnchor
                                                   constant:6.0],
        [translateButton.bottomAnchor constraintEqualToAnchor:actionBar.bottomAnchor
                                                      constant:-6.0],
    ]];

    self.actionBar = actionBar;
    self.translateButton = translateButton;
    [self refreshActionButtonTitles];
}

- (void)refreshActionButtonTitles {
    if (!self.translateButton) {
        return;
    }

    // The action always has the same name. It translates the active selection
    // when iOS exposes one, otherwise it translates the complete OCR result.
    [self.translateButton setTitle:@"翻译" forState:UIControlStateNormal];
}

- (void)handleTranslateButton:(UIButton *)sender {
    (void)sender;
    NSString *selectedText = self.visionBridge.currentSelectedText;
    BOOL hasSelection = selectedText.length > 0;
    NSString *text = hasSelection ? selectedText : self.visionBridge.currentFullText;
    if (text.length == 0) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Action][ERROR] translate ignored reason=empty-text");
        return;
    }

    FLMEnqueueDiagnosticLine(
        @"[ScreenSense][Action] translate in-place begin mode=%@ textLength=%ld nativeSelection=%d",
        hasSelection ? @"selection" : @"full", (long)text.length,
        self.visionBridge.hasActiveTextSelection ? 1 : 0);
    [self beginInPlaceTranslationForText:text hasSelection:hasSelection];
}

- (void)cancelTranslation {
    self.translationRequestID += 1;
    [self.translationTask cancel];
    self.translationTask = nil;
    [self.translationOverlay removeFromSuperview];
    self.translationOverlay = nil;
    self.translateButton.userInteractionEnabled = YES;
}

- (void)beginInPlaceTranslationForText:(NSString *)text
                           hasSelection:(BOOL)hasSelection {
    if (!self.viewController || !self.imageView || text.length == 0) {
        return;
    }

    [self cancelTranslation];
    NSUInteger requestID = self.translationRequestID;
    UIImage *image = self.imageView.image;
    CGRect overlayBounds = self.imageView.bounds;
    if (!image || CGRectIsEmpty(overlayBounds)) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Action][ERROR] translate ignored reason=image-unavailable");
        return;
    }

    FMScreenSenseTranslationOverlayView *overlay =
        [[FMScreenSenseTranslationOverlayView alloc] initWithFrame:overlayBounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
    [self.viewController.view insertSubview:overlay aboveSubview:self.imageView];
    self.translationOverlay = overlay;
    [overlay showLoading];
    self.translateButton.userInteractionEnabled = NO;

    __weak FMScreenSenseSession *weakSelf = self;
    [self performOCRForImage:image
                    inBounds:overlayBounds
                  completion:^(NSArray<NSString *> *lines,
                               NSArray<NSValue *> *frames,
                               NSError *ocrError) {
        FMScreenSenseSession *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.state == FMScreenSenseStateInactive ||
            strongSelf.translationRequestID != requestID) {
            return;
        }

        NSString *ocrText = [lines componentsJoinedByString:@"\n"];
        NSString *queryText = ocrText.length > 0 ? ocrText : text;
        if (ocrError) {
            FLMEnqueueDiagnosticLine(
                @"[ScreenSense][Action][OCR] layout fallback code=%ld",
                (long)ocrError.code);
        }
        if (queryText.length == 0) {
            [overlay showErrorMessage:@"没有识别到文字"];
            strongSelf.translateButton.userInteractionEnabled = YES;
            return;
        }

        [strongSelf requestTranslationForText:queryText
                                    completion:^(NSString *translatedText,
                                                 NSError *translationError) {
            FMScreenSenseSession *latestSelf = weakSelf;
            if (!latestSelf || latestSelf.state == FMScreenSenseStateInactive ||
                latestSelf.translationRequestID != requestID) {
                return;
            }

            latestSelf.translateButton.userInteractionEnabled = YES;
            if (translationError || translatedText.length == 0) {
                FLMEnqueueDiagnosticLine(
                    @"[ScreenSense][Action][ERROR] translate request failed domain=%@ code=%ld",
                    translationError.domain ?: @"unknown",
                    (long)translationError.code);
                [overlay showErrorMessage:@"翻译失败，请检查网络"];
                return;
            }

            NSArray<NSString *> *translatedLines =
                [translatedText componentsSeparatedByString:@"\n"];
            NSArray<NSString *> *displayLines = translatedLines;
            NSArray<NSValue *> *displayFrames = frames;
            if (frames.count == 0) {
                displayLines = @[translatedText];
                displayFrames = @[[NSValue valueWithCGRect:
                    CGRectInset(overlay.bounds, 20.0, 80.0)]];
            } else if (hasSelection || translatedLines.count != frames.count) {
                // iOS 16 keeps the exact grab-handle range inside VisionKit,
                // so there is no public rectangle to read back. Use one
                // bounded in-place label for that result rather than showing
                // a reflowed second window or mismatching every OCR line.
                CGRect unionFrame = CGRectNull;
                for (NSValue *value in frames) {
                    unionFrame = CGRectIsNull(unionFrame)
                                     ? value.CGRectValue
                                     : CGRectUnion(unionFrame, value.CGRectValue);
                }
                displayLines = @[translatedText];
                displayFrames = @[[NSValue valueWithCGRect:unionFrame]];
            }

            [overlay showTranslatedLines:displayLines frames:displayFrames];
            FLMEnqueueDiagnosticLine(
                @"[ScreenSense][Action] translate in-place success sourceLines=%ld resultLength=%ld",
                (long)displayFrames.count, (long)translatedText.length);
        }];
    }];
}

- (void)performOCRForImage:(UIImage *)image
                inBounds:(CGRect)bounds
              completion:(void (^)(NSArray<NSString *> *lines,
                                   NSArray<NSValue *> *frames,
                                   NSError *error))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        request.usesLanguageCorrection = YES;
        // Let Vision choose the language model instead of hard-coding a list
        // that may not be installed on every iOS 16 device. VisionKit still
        // supplies the authoritative transcript; this request is only used to
        // obtain line rectangles.
        request.automaticallyDetectsLanguage = YES;

        NSError *ocrError = nil;
        CGImageRef imageRef = image.CGImage;
        if (imageRef) {
            VNImageRequestHandler *handler =
                [[VNImageRequestHandler alloc] initWithCGImage:imageRef
                                                        options:@{}];
            [handler performRequests:@[request] error:&ocrError];
        } else {
            ocrError = [NSError errorWithDomain:@"com.codex.flymemultitasking.screensense.ocr"
                                           code:1
                                       userInfo:@{
                                           NSLocalizedDescriptionKey:
                                               @"Captured image has no CGImage"
                                       }];
        }

        NSArray<VNRecognizedTextObservation *> *observations =
            [request.results sortedArrayUsingComparator:
                ^NSComparisonResult(VNRecognizedTextObservation *left,
                                    VNRecognizedTextObservation *right) {
                    CGRect leftBox = left.boundingBox;
                    CGRect rightBox = right.boundingBox;
                    if (fabs(leftBox.origin.y - rightBox.origin.y) > 0.018) {
                        return leftBox.origin.y > rightBox.origin.y
                                   ? NSOrderedAscending
                                   : NSOrderedDescending;
                    }
                    return leftBox.origin.x < rightBox.origin.x
                               ? NSOrderedAscending
                               : NSOrderedDescending;
                }];

        CGRect imageRect = FMScreenSenseAspectFitRect(image.size, bounds);
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        NSMutableArray<NSValue *> *frames = [NSMutableArray array];
        for (VNRecognizedTextObservation *observation in observations) {
            VNRecognizedText *candidate =
                [[observation topCandidates:1] firstObject];
            if (candidate.string.length == 0) {
                continue;
            }

            CGRect box = observation.boundingBox;
            CGRect frame = CGRectMake(
                imageRect.origin.x + box.origin.x * imageRect.size.width,
                imageRect.origin.y + (1.0 - box.origin.y - box.size.height) *
                    imageRect.size.height,
                box.size.width * imageRect.size.width,
                box.size.height * imageRect.size.height);
            if (CGRectIsEmpty(frame)) {
                continue;
            }
            [lines addObject:candidate.string];
            [frames addObject:[NSValue valueWithCGRect:frame]];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(lines, frames, ocrError);
        });
    });
}

- (void)requestTranslationForText:(NSString *)text
                        completion:(void (^)(NSString *translatedText,
                                             NSError *error))completion {
    NSURLComponents *components = [NSURLComponents
        componentsWithString:@"https://translate.googleapis.com/translate_a/single"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"client" value:@"gtx"],
        [NSURLQueryItem queryItemWithName:@"sl" value:@"auto"],
        [NSURLQueryItem queryItemWithName:@"tl" value:@"zh-CN"],
        [NSURLQueryItem queryItemWithName:@"dt" value:@"t"],
        [NSURLQueryItem queryItemWithName:@"q" value:text],
    ];
    NSURL *url = components.URL;
    if (!url) {
        completion(nil, [NSError errorWithDomain:@"com.codex.flymemultitasking.screensense.translate"
                                              code:1
                                          userInfo:@{
                                              NSLocalizedDescriptionKey:
                                                  @"Unable to construct translation URL"
                                          }]);
        return;
    }

    NSURLSessionConfiguration *configuration =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 20.0;
    configuration.timeoutIntervalForResource = 30.0;
    NSURLSession *session =
        [NSURLSession sessionWithConfiguration:configuration];
    NSURLSessionDataTask *task =
        [session dataTaskWithURL:url
               completionHandler:^(NSData *data, NSURLResponse *response,
                                   NSError *networkError) {
        NSError *resultError = networkError;
        NSString *translatedText = nil;
        if (!resultError &&
            [response isKindOfClass:[NSHTTPURLResponse class]] &&
            ((NSHTTPURLResponse *)response).statusCode >= 400) {
            resultError = [NSError errorWithDomain:@"com.codex.flymemultitasking.screensense.translate"
                                               code:((NSHTTPURLResponse *)response).statusCode
                                           userInfo:@{
                                               NSLocalizedDescriptionKey:
                                                   @"Translation service returned an HTTP error"
                                           }];
        }

        if (!resultError && data.length > 0) {
            NSError *parseError = nil;
            id root = [NSJSONSerialization JSONObjectWithData:data
                                                        options:0
                                                          error:&parseError];
            NSArray *segments = [root isKindOfClass:[NSArray class]] &&
                                        [root count] > 0
                                    ? root[0]
                                    : nil;
            if ([segments isKindOfClass:[NSArray class]]) {
                NSMutableString *result = [NSMutableString string];
                for (id segment in segments) {
                    if (![segment isKindOfClass:[NSArray class]] ||
                        [segment count] == 0) {
                        continue;
                    }
                    id piece = segment[0];
                    if ([piece isKindOfClass:[NSString class]]) {
                        [result appendString:piece];
                    }
                }
                translatedText = result.copy;
            }
            if (translatedText.length == 0) {
                resultError = parseError ?: [NSError errorWithDomain:@"com.codex.flymemultitasking.screensense.translate"
                                                                   code:2
                                                               userInfo:@{
                                                                   NSLocalizedDescriptionKey:
                                                                       @"Translation response was empty"
                                                               }];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(translatedText, resultError);
        });
        [session finishTasksAndInvalidate];
    }];
    self.translationTask = task;
    [task resume];
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
    [self cancelTranslation];

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
    self.actionBar.userInteractionEnabled = NO;
    self.translateButton.userInteractionEnabled = NO;

    UIWindow *previousKeyWindow = self.previousKeyWindow;
    self.previousKeyWindow = nil;
    [overlayWindow resignKeyWindow];
    overlayWindow.hidden = YES;

    self.closeButton = nil;
    self.actionBar = nil;
    self.translateButton = nil;
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
