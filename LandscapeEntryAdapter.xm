#import <UIKit/UIKit.h>

#import "FLMLandscapeModule.h"

// This file is intentionally an additive bridge.  FLMWheelController remains
// the only owner of _UISystemGestureManager registration; in landscape, these
// hooks redirect that already-registered gesture family to the horizontal
// module and suppress the portrait-only gesture consumers.

%hook FLMWheelController

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

%end
