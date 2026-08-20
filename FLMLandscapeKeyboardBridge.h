#ifndef FLM_LANDSCAPE_KEYBOARD_BRIDGE_H
#define FLM_LANDSCAPE_KEYBOARD_BRIDGE_H

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// SpringBoard-side adapter for the existing native FlymeKeyboard route.  It
// never draws a keyboard: it pairs and hosts iOS' real remote Keyboard Scene
// above the landscape card while the application Scene remains portrait.
void FLMLandscapeKeyboardBridgeStart(void);
void FLMLandscapeKeyboardBridgeBegin(NSString *identifier,
                                     id applicationScene,
                                     uint64_t sessionGeneration,
                                     UIWindow *cardWindow);
void FLMLandscapeKeyboardBridgeUpdateCard(CGRect cardFrame,
                                          CGFloat visualScale,
                                          BOOL interactive);
void FLMLandscapeKeyboardBridgeEnd(uint64_t sessionGeneration);
BOOL FLMLandscapeKeyboardBridgeContainsVisualPoint(CGPoint point);

NS_ASSUME_NONNULL_END

#endif
