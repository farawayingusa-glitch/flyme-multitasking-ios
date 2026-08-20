#import <UIKit/UIKit.h>

#import "FLMDiagnostics.h"
#import "FLMLandscapeModule.h"

@interface FLMWheelController : NSObject
@property(nonatomic, strong) UIWindow *floatingWindow;
@property(nonatomic, strong) id floatingScene;
- (void)closeFloatingWindowKeepingApplication:(BOOL)keepApplication;
@end

// Only this scoped call needs the portrait client reference. Everywhere else
// the frozen controller sees the real full-display landscape Scene size.
static NSUInteger FLMLandscapeHostLayoutDepth = 0;

%hook FLMOverlayViewController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if (FLMLandscapeModuleIsLandscape()) {
        return UIInterfaceOrientationMaskLandscape;
    }
    return %orig;
}

%end

%hook FLMWheelController

- (void)start {
    %orig;
    FLMLandscapeModuleStart();
    FLMLandscapeModuleSynchronizeRootController(self);
}

- (void)updateWindowFrames {
    if (FLMLandscapeModuleIsLandscape()) {
        FLMLandscapeModuleSynchronizeRootController(self);
        return;
    }
    %orig;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (FLMLandscapeModuleIsLandscape() &&
        FLMLandscapeWheelOwnsSharedGesture(self, gestureRecognizer)) {
        return FLMLandscapeWheelShouldBeginSharedGesture(
            self, gestureRecognizer);
    }
    if (FLMLandscapeModuleIsLandscape() &&
        FLMLandscapeWheelShouldSuppressPortraitGesture(self,
                                                       gestureRecognizer)) {
        return NO;
    }
    return %orig;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    if (FLMLandscapeModuleIsLandscape() &&
        FLMLandscapeWheelOwnsSharedGesture(self, gestureRecognizer)) {
        return FLMLandscapeWheelShouldReceiveSharedTouch(
            self, gestureRecognizer, touch);
    }
    if (FLMLandscapeModuleIsLandscape() &&
        FLMLandscapeWheelShouldSuppressPortraitGesture(self,
                                                       gestureRecognizer)) {
        return NO;
    }
    return %orig;
}

- (void)handleCornerGuardGesture:(UIGestureRecognizer *)gesture {
    if (FLMLandscapeModuleIsLandscape() &&
        FLMLandscapeWheelOwnsSharedGesture(self, gesture)) {
        FLMLandscapeWheelHandleSharedGesture(self, gesture);
        return;
    }
    %orig;
}

- (void)handleCornerGesture:(UIGestureRecognizer *)gesture {
    if (FLMLandscapeModuleIsLandscape() &&
        FLMLandscapeWheelOwnsSharedGesture(self, gesture)) {
        FLMLandscapeWheelHandleSharedGesture(self, gesture);
        return;
    }
    %orig;
}

- (void)handleModalGesture:(UIGestureRecognizer *)gesture {
    if (FLMLandscapeModuleIsLandscape() &&
        FLMLandscapeWheelOwnsSharedGesture(self, gesture)) {
        FLMLandscapeWheelHandleSharedGesture(self, gesture);
        return;
    }
    %orig;
}

- (void)presentWheelFromRight:(BOOL)fromRight {
    if (FLMLandscapeModuleIsLandscape()) {
        FLMLandscapeWheelPresentRootController(self, fromRight);
        return;
    }
    %orig;
}

- (void)openFloatingIdentifier:(NSString *)identifier {
    if (FLMLandscapeModuleIsLandscape()) {
        FLMLandscapeModuleSynchronizeRootController(self);
        FLMEnqueueDiagnosticLine(
            @"sb landscape-bridge-open app=%@ engine=FLMWheelController",
            identifier ?: @"<none>");
    }
    %orig;
}

- (BOOL)prepareFloatingScene:(id)scene handle:(id)sceneHandle {
    if (FLMLandscapeModuleIsLandscape()) {
        return FLMLandscapeModulePrepareSharedScene(self,
                                                    scene,
                                                    sceneHandle);
    }
    return %orig;
}

- (void)backgroundFloatingScene:(id)scene {
    if (FLMLandscapeModuleOwnsSharedScene(scene)) {
        FLMLandscapeModuleBackgroundSharedScene(self, scene);
        return;
    }
    %orig;
}

- (CGSize)floatingSystemSceneReferenceSize {
    if (FLMLandscapeModuleIsLandscape()) {
        if (FLMLandscapeHostLayoutDepth > 0) {
            return FLMLandscapeModulePortraitCanvasSize();
        }
        return FLMLandscapeModuleVisualBounds().size;
    }
    return %orig;
}

- (CGSize)floatingContentViewportReferenceSize {
    if (FLMLandscapeModuleIsLandscape() ||
        FLMLandscapeModuleOwnsSharedScene(self.floatingScene)) {
        return FLMLandscapeModulePortraitCanvasSize();
    }
    return %orig;
}

- (void)layoutFloatingHostView {
    if (!FLMLandscapeModuleIsLandscape()) {
        %orig;
        return;
    }
    FLMLandscapeHostLayoutDepth += 1;
    @try {
        %orig;
    } @finally {
        FLMLandscapeHostLayoutDepth -= 1;
    }
}

- (CGFloat)effectiveCenteredCardWidth {
    if (FLMLandscapeModuleIsLandscape()) {
        return CGRectGetWidth(FLMLandscapeModuleCardFrame());
    }
    return %orig;
}

- (CGFloat)effectiveCenteredCardHeight {
    if (FLMLandscapeModuleIsLandscape()) {
        return CGRectGetHeight(FLMLandscapeModuleCardFrame());
    }
    return %orig;
}

- (CGRect)centeredFloatingFrame {
    if (FLMLandscapeModuleIsLandscape()) {
        return FLMLandscapeModuleCardFrame();
    }
    return %orig;
}

- (void)failFloatingLaunchForIdentifier:(NSString *)identifier
                               generation:(NSUInteger)generation {
    if (FLMLandscapeModuleIsLandscape() ||
        FLMLandscapeModuleOwnsSharedScene(self.floatingScene)) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-bridge-fail app=%@ generation=%lu action=close-card-no-fullscreen",
            identifier ?: @"<none>", (unsigned long)generation);
        [self closeFloatingWindowKeepingApplication:YES];
        return;
    }
    %orig;
}

%end
