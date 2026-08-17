#ifndef FLM_LANDSCAPE_MODULE_H
#define FLM_LANDSCAPE_MODULE_H

#import <UIKit/UIKit.h>

// The landscape path deliberately owns its own coordinate space and window.
// These functions are the narrow direction gate used by the wheel entry point;
// no portrait presentation state is exposed here.
BOOL FLMLandscapeModuleIsLandscape(void);
CGRect FLMLandscapeModuleVisualBounds(void);
CGPoint FLMLandscapeModuleVisualPointFromRawPoint(CGPoint rawPoint);
BOOL FLMLandscapeModulePointInsideCornerTrigger(CGPoint point,
                                                CGRect bounds,
                                                BOOL * _Nullable fromRight);

void FLMLandscapeModuleStart(void);
void FLMLandscapeModuleUpdateFrames(void);
void FLMLandscapeModuleOrientationDidChange(void);
void FLMLandscapeModuleOpenIdentifier(NSString *identifier);
void FLMLandscapeModuleClose(BOOL keepApplication);
BOOL FLMLandscapeModuleHasVisibleCard(void);

#endif
