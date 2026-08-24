#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Narrow bridge between the frozen portrait controller and the independent
// landscape implementation.  Portrait behavior stays in Tweak.xm; only these
// shared lifecycle and keyboard primitives cross the boundary.
id _Nullable FLMCopyPreference(NSString *key);
BOOL FLMDeviceIsLocked(void);
NSString * _Nullable FLMFrontmostApplicationIdentifier(void);
BOOL FLMPrewarmApplicationIdentifier(NSString *identifier);
NSString * _Nullable FLMSceneIdentifier(id _Nullable scene);
UIWindow * _Nullable FLMCurrentKeyWindow(void);
UIImage *FLMApplicationIcon(NSString *bundleIdentifier);

void FLMPublishKeyboardState(NSString * _Nullable identifier,
                             id _Nullable scene,
                             uint64_t sessionGeneration);
void FLMPublishKeyboardAvoidance(uint64_t sessionGeneration,
                                 CGFloat keyboardHeight,
                                 BOOL visible);
void FLMPublishKeyboardCardGeometry(uint64_t sessionGeneration,
                                    CGFloat cardBottom,
                                    CGFloat visualScale,
                                    CGFloat cardWidth,
                                    CGFloat cardHeight,
                                    BOOL active);

void FLMQuiescePortraitControllerForLandscape(void);

void FLMLandscapeStart(void);
NSUInteger FLMLandscapeKeyboardSessionGeneration(void);
void FLMLandscapeKeyboardHostDidUpdate(UIView *hostView,
                                       id _Nullable scene,
                                       NSUInteger sessionGeneration);

NS_ASSUME_NONNULL_END
