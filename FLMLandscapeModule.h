#ifndef FLM_LANDSCAPE_MODULE_H
#define FLM_LANDSCAPE_MODULE_H

#import <UIKit/UIKit.h>

// The horizontal package owns this coordinate space.  The portrait package
// is intentionally not imported here and has no horizontal entry point.
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
void FLMLandscapeModuleUpdateFrames(void);
void FLMLandscapeModuleOrientationDidChange(void);
void FLMLandscapeModuleOpenIdentifier(NSString * _Nonnull identifier);
void FLMLandscapeModuleClose(BOOL keepApplication);
BOOL FLMLandscapeModuleHasVisibleCard(void);

#endif
