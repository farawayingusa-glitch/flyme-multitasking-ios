#ifndef FLM_LANDSCAPE_MODULE_H
#define FLM_LANDSCAPE_MODULE_H

#import <UIKit/UIKit.h>
#include <stdint.h>

// The landscape path deliberately owns its own coordinate space and window.
// These functions are the narrow direction gate used by the wheel entry point;
// no portrait presentation state is exposed here.
BOOL FLMLandscapeModuleIsLandscape(void);
CGRect FLMLandscapeModuleVisualBounds(void);
UIInterfaceOrientation FLMLandscapeModuleVisualOrientation(void);
UIEdgeInsets FLMLandscapeModuleVisualSafeAreaInsets(void);
CGPoint FLMLandscapeModuleVisualPointFromRawPoint(CGPoint rawPoint);

// A system gesture can begin while UIKit is still publishing the portrait
// fixed-coordinate frame and finish after the window has already switched to
// its landscape visual frame.  The wheel keeps one of these snapshots for the
// entire touch stream so entry, rendering, highlighting and selection all use
// the same transform.
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
uint64_t FLMLandscapeModuleKeyboardSessionGeneration(void);

// SpringBoard owns the landscape card, while the keyboard adapter is built as
// a separate tweak.  These bridge calls publish the exact landscape Scene and
// let SpringBoard move the native keyboard host to a full-display window.
void FLMLandscapeKeyboardRouteOpen(NSString * _Nonnull identifier,
                                   id _Nonnull scene,
                                   uint64_t sessionGeneration);
void FLMLandscapeKeyboardRouteClose(uint64_t sessionGeneration);

#endif
