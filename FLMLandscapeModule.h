#ifndef FLM_LANDSCAPE_MODULE_H
#define FLM_LANDSCAPE_MODULE_H

#import <UIKit/UIKit.h>

// Constructor-safe POSIX marker owned by the horizontal module.  It is kept
// out of the frozen portrait diagnostics header so this module can be added
// without changing the portrait implementation.
void FLMWriteLandscapeBootstrapMarker(const char * _Nullable reason);

// The horizontal module owns this coordinate space.  The portrait module is
// intentionally not imported here and has no horizontal entry point.
BOOL FLMLandscapeModuleIsLandscape(void);
CGRect FLMLandscapeModuleVisualBounds(void);
UIInterfaceOrientation FLMLandscapeModuleVisualOrientation(void);
UIEdgeInsets FLMLandscapeModuleVisualSafeAreaInsets(void);

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

void FLMLandscapeModuleStart(void);
// The independent wheel keeps a second, in-window recognizer pair on the
// landscape card.  This mirrors the original portrait controller's floating
// window fallback and is deliberately exposed as a view, not as the private
// module object itself.
UIView * _Nullable FLMLandscapeModuleWheelGestureView(void);
void FLMLandscapeModuleUpdateFrames(void);
void FLMLandscapeModuleOrientationDidChange(void);
void FLMLandscapeModuleOpenIdentifier(NSString * _Nonnull identifier);
void FLMLandscapeModuleClose(BOOL keepApplication);
BOOL FLMLandscapeModuleHasVisibleCard(void);

// The portrait controller owns the single system-gesture-manager registration.
// The horizontal module only borrows those recognizers through this adapter;
// it never installs a second global gesture family.
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

// The portrait controller has already registered these two recognizers with
// _UISystemGestureManager.  While a landscape card is visible, the additive
// adapter lends them to the landscape card so backdrop, handle and dock
// touches keep ownership even when another application Scene is frontmost.
BOOL FLMLandscapeCardOwnsSharedGesture(
    id _Nullable wheelController,
    UIGestureRecognizer * _Nullable gestureRecognizer);
BOOL FLMLandscapeCardShouldReceiveSharedTouch(
    id _Nullable wheelController,
    UIGestureRecognizer * _Nullable gestureRecognizer,
    UITouch * _Nullable touch);
BOOL FLMLandscapeCardShouldBeginSharedGesture(
    id _Nullable wheelController,
    UIGestureRecognizer * _Nullable gestureRecognizer);
void FLMLandscapeCardHandleSharedGesture(
    id _Nullable wheelController,
    UIGestureRecognizer * _Nullable gestureRecognizer);

#endif
