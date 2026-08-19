#ifndef FLM_LANDSCAPE_MODULE_H
#define FLM_LANDSCAPE_MODULE_H

#import <UIKit/UIKit.h>

// Constructor-safe POSIX marker owned by the horizontal module.  It is kept
// out of the frozen portrait diagnostics header so this module can be added
// without changing the portrait implementation.
void FLMWriteLandscapeBootstrapMarker(const char *reason);

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

#endif
