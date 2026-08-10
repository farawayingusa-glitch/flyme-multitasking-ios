#ifndef FLM_SCREEN_SENSE_SESSION_H
#define FLM_SCREEN_SENSE_SESSION_H

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns one ScreenSense capture, frozen overlay, VisionKit session, and
/// teardown lifecycle. The VisionKit implementation stays behind the Swift
/// bridge; this interface intentionally exposes only UIImage/UIKit types.
@interface FMScreenSenseSession : NSObject

+ (instancetype)sharedSession;

/// Claims a new ScreenSense action. Returns NO while a previous session is
/// dismissing, capturing, analyzing, or active.
- (BOOL)beginCaptureSession;

/// Moves the claimed session from wheel dismissal into the synchronous
/// RenderServer capture phase.
- (void)markCaptureStarted;

/// Cancels a claimed session before a valid image is available.
- (void)abortCaptureWithReason:(NSString *)reason;

/// Presents the captured frame immediately and then starts VisionKit.
- (void)presentCapturedImage:(UIImage *)image;

/// Closes the frozen ScreenSense overlay. A tap in a blank, non-Live-Text
/// region is the normal user-facing exit path.
- (void)dismiss;

@end

NS_ASSUME_NONNULL_END

#endif
