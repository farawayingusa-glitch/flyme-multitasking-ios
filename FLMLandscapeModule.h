#ifndef FLM_LANDSCAPE_MODULE_H
#define FLM_LANDSCAPE_MODULE_H

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Constructor-safe POSIX marker. It remains isolated from the frozen
// diagnostics foundation and is safe before UIKit has finished launching.
void FLMWriteLandscapeBootstrapMarker(const char * _Nullable reason);

// Landscape is an adapter around the frozen FLMWheelController. These helpers
// describe only the rotated display and never own a second window/Scene state
// machine.
BOOL FLMLandscapeModuleIsLandscape(void);
CGRect FLMLandscapeModuleVisualBounds(void);
UIInterfaceOrientation FLMLandscapeModuleVisualOrientation(void);
UIEdgeInsets FLMLandscapeModuleVisualSafeAreaInsets(void);
CGRect FLMLandscapeModuleCardFrame(void);
CGSize FLMLandscapeModulePortraitCanvasSize(void);

CGPoint FLMLandscapeEnvironmentConvertPoint(CGPoint rawPoint);
CGPoint FLMLandscapeModuleVisualPointFromRawPoint(CGPoint rawPoint);

typedef struct {
    BOOL valid;
    UIInterfaceOrientation orientation;
    CGRect visualBounds;
    CGRect fixedBounds;
} FLMLandscapeTouchContext;

FLMLandscapeTouchContext FLMLandscapeModuleCaptureTouchContext(void);
CGPoint FLMLandscapeModuleVisualPointFromRawPointInContext(
    FLMLandscapeTouchContext context,
    CGPoint rawPoint);
BOOL FLMLandscapeModulePointInsideCornerTrigger(CGPoint point,
                                                CGRect bounds,
                                                BOOL * _Nullable fromRight);

// Root-controller bridge. No object created by the landscape module owns app
// launch, Scene resolution, Presenter creation, or close/restore state.
void FLMLandscapeModuleStart(void);
void FLMLandscapeModuleSynchronizeRootController(id _Nullable rootController);
BOOL FLMLandscapeModulePrepareSharedScene(id rootController,
                                          id scene,
                                          id _Nullable sceneHandle);
void FLMLandscapeModuleBackgroundSharedScene(id rootController, id scene);
BOOL FLMLandscapeModuleOwnsSharedScene(id _Nullable scene);

// The landscape wheel operates directly on the frozen root controller and its
// FLMWheelItemView objects. It borrows the already registered gesture family;
// it does not create a second controller, window, item class, or preference
// store.
BOOL FLMLandscapeWheelOwnsSharedGesture(
    id _Nullable wheelController,
    UIGestureRecognizer * _Nullable gestureRecognizer);
BOOL FLMLandscapeWheelShouldReceiveSharedTouch(
    id _Nullable wheelController,
    UIGestureRecognizer * _Nullable gestureRecognizer,
    UITouch * _Nullable touch);
BOOL FLMLandscapeWheelShouldBeginSharedGesture(
    id _Nullable wheelController,
    UIGestureRecognizer * _Nullable gestureRecognizer);
BOOL FLMLandscapeWheelShouldSuppressPortraitGesture(
    id _Nullable wheelController,
    UIGestureRecognizer * _Nullable gestureRecognizer);
void FLMLandscapeWheelHandleSharedGesture(
    id _Nullable wheelController,
    UIGestureRecognizer * _Nullable gestureRecognizer);
void FLMLandscapeWheelPresentRootController(id wheelController,
                                            BOOL fromRight);

NS_ASSUME_NONNULL_END

#endif
