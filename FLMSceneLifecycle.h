#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const FLMProtectedSceneDidDisappearNotification;

void FLMProtectScene(id scene, id _Nullable sceneHandle);
void FLMClearProtectedScene(id _Nullable scene);
BOOL FLMObjectMatchesProtectedScene(id _Nullable object);

NS_ASSUME_NONNULL_END
