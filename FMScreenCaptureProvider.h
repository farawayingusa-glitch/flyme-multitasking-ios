#ifndef FLM_SCREEN_CAPTURE_PROVIDER_H
#define FLM_SCREEN_CAPTURE_PROVIDER_H

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Captures one composited frame from the main display in SpringBoard.
///
/// The provider owns all RenderServer/IOSurface details so the wheel/session
/// controller only receives an independent UIImage or nil.
@interface FMScreenCaptureProvider : NSObject

+ (nullable UIImage *)captureCurrentDisplay;

@end

NS_ASSUME_NONNULL_END

#endif
