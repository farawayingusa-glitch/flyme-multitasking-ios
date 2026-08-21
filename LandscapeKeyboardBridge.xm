#import <UIKit/UIKit.h>
#import <math.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/stat.h>

#import "FLMDiagnostics.h"
#import "FLMLandscapeKeyboardBridge.h"
#import "FLMLandscapeModule.h"

#define FLYME_KEYBOARD_NOTIFICATION \
    "com.codex.flymemultitasking.keyboard-state-changed"
#define FLYME_KEYBOARD_SCENE_NOTIFICATION \
    "com.codex.flymemultitasking.keyboard-scene-changed"
#define FLYME_KEYBOARD_SESSION_NOTIFICATION \
    "com.codex.flymemultitasking.keyboard-session-changed"
#define FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION \
    "com.codex.flymemultitasking.keyboard-avoidance-changed"
#define FLYME_KEYBOARD_CARD_GEOMETRY_NOTIFICATION \
    "com.codex.flymemultitasking.keyboard-card-geometry-changed"
#define FLYME_KEYBOARD_SHARED_STATE_NOTIFICATION \
    "com.codex.flymemultitasking.keyboard-shared-state-changed"

static NSString *const FLMLandscapeKeyboardSharedStatePath =
    @"/var/mobile/Library/Preferences/FlymeMultitasking-KeyboardState.plist";
static NSString *const FLMLandscapeKeyboardSharedStateRootlessPath =
    @"/var/jb/var/mobile/Library/Preferences/FlymeMultitasking-KeyboardState.plist";
static const CGFloat FLMLandscapeKeyboardPortraitWidth = 390.0;
static const CGFloat FLMLandscapeKeyboardPortraitHeight = 844.0;

static uint64_t FLMLandscapeKeyboardIdentifierHash(NSString *identifier) {
    const char *bytes = identifier.UTF8String;
    if (!bytes || bytes[0] == '\0') {
        return 0;
    }
    uint64_t value = 1469598103934665603ULL;
    for (const unsigned char *cursor = (const unsigned char *)bytes;
         *cursor;
         cursor++) {
        value ^= (uint64_t)*cursor;
        value *= 1099511628211ULL;
    }
    return value ?: 1;
}

static NSString *FLMLandscapeKeyboardSceneIdentifier(id scene) {
    if (!scene) {
        return nil;
    }
    for (NSString *selectorName in @[@"sceneIdentifier", @"identifier"]) {
        SEL selector = NSSelectorFromString(selectorName);
        @try {
            if ([scene respondsToSelector:selector]) {
                id value = ((id (*)(id, SEL))objc_msgSend)(scene, selector);
                if ([value isKindOfClass:[NSString class]] &&
                    [value length] > 0) {
                    return value;
                }
            }
        } @catch (__unused NSException *exception) {
        }
    }
    @try {
        id settings = [scene valueForKey:@"settings"];
        for (NSString *key in @[@"sceneIdentifier", @"identifier"]) {
            id value = [settings valueForKey:key];
            if ([value isKindOfClass:[NSString class]] &&
                [value length] > 0) {
                return value;
            }
        }
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

@interface FLMLandscapeKeyboardRootViewController : UIViewController
@end

@implementation FLMLandscapeKeyboardRootViewController

- (BOOL)shouldAutorotate {
    return NO;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end

@interface FLMLandscapeKeyboardForwardingWindow : UIWindow
@property(nonatomic, assign) CGRect keyboardInteractionFrame;
@end

@implementation FLMLandscapeKeyboardForwardingWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (CGRectIsNull(self.keyboardInteractionFrame) ||
        !CGRectContainsPoint(self.keyboardInteractionFrame, point)) {
        return nil;
    }
    return [super hitTest:point withEvent:event];
}

@end

@interface FLMLandscapeKeyboardCoordinator : NSObject
@property(nonatomic, copy) NSString *targetIdentifier;
@property(nonatomic, strong) id targetScene;
@property(nonatomic, assign) uint64_t sessionGeneration;
@property(nonatomic, weak) UIWindow *cardWindow;
@property(nonatomic, strong) FLMLandscapeKeyboardForwardingWindow *forwardingWindow;
@property(nonatomic, strong) UIView *keyboardHostView;
@property(nonatomic, weak) UIView *keyboardOriginalSuperview;
@property(nonatomic, assign) NSUInteger keyboardOriginalSubviewIndex;
@property(nonatomic, assign) CGRect keyboardOriginalFrame;
@property(nonatomic, assign) CGAffineTransform keyboardOriginalTransform;
@property(nonatomic, assign) UIViewAutoresizing keyboardOriginalAutoresizingMask;
@property(nonatomic, assign) BOOL keyboardOriginalTranslatesAutoresizingMask;
@property(nonatomic, strong) id keyboardScene;
@property(nonatomic, strong) id keyboardPreferredHostIdentity;
@property(nonatomic, assign) uint64_t keyboardHostSessionGeneration;
@property(nonatomic, assign) BOOL keyboardVisible;
@property(nonatomic, assign) CGRect keyboardFrame;
@property(nonatomic, assign) BOOL keyboardFramePending;
@property(nonatomic, assign) CGRect pendingKeyboardFrame;
@property(nonatomic, assign) uint64_t pendingKeyboardSessionGeneration;
@property(nonatomic, assign) CGRect cardFrame;
@property(nonatomic, assign) CGFloat cardScale;
@property(nonatomic, assign) BOOL cardInteractive;
@property(nonatomic, strong) UIView *deferredHostView;
@property(nonatomic, strong) id deferredUpdatedScene;
@property(nonatomic, assign) NSUInteger deferredAttempt;
@property(nonatomic, strong) dispatch_queue_t sharedStateQueue;
@property(nonatomic, assign) int routeToken;
@property(nonatomic, assign) int sceneToken;
@property(nonatomic, assign) int sessionToken;
@property(nonatomic, assign) int avoidanceToken;
@property(nonatomic, assign) int cardGeometryToken;
+ (instancetype)sharedCoordinator;
- (void)start;
- (void)beginWithIdentifier:(NSString *)identifier
                      scene:(id)scene
                    session:(uint64_t)session
                 cardWindow:(UIWindow *)cardWindow;
- (void)updateCardFrame:(CGRect)cardFrame
                  scale:(CGFloat)scale
            interactive:(BOOL)interactive;
- (void)endSession:(uint64_t)session;
- (BOOL)routeIsActive;
- (void)keyboardHostView:(UIView *)hostView didUpdateForScene:(id)scene;
@end

@implementation FLMLandscapeKeyboardCoordinator

+ (instancetype)sharedCoordinator {
    static FLMLandscapeKeyboardCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [[self alloc] init];
        coordinator.routeToken = -1;
        coordinator.sceneToken = -1;
        coordinator.sessionToken = -1;
        coordinator.avoidanceToken = -1;
        coordinator.cardGeometryToken = -1;
        coordinator.keyboardFrame = CGRectNull;
        coordinator.pendingKeyboardFrame = CGRectNull;
        coordinator.cardFrame = CGRectNull;
        coordinator.sharedStateQueue = dispatch_queue_create(
            "com.codex.flymemultitasking.landscape-keyboard-state",
            DISPATCH_QUEUE_SERIAL);
    });
    return coordinator;
}

- (void)start {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self
                   selector:@selector(keyboardFrameWillChange:)
                       name:UIKeyboardWillChangeFrameNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(keyboardDidHide:)
                       name:UIKeyboardDidHideNotification
                     object:nil];
    });
}

- (BOOL)routeIsActive {
    return self.sessionGeneration != 0 && self.targetIdentifier.length > 0 &&
           self.targetScene != nil && self.cardWindow != nil &&
           !self.cardWindow.hidden;
}

- (void)prepareForwardingWindowIfNeeded {
    UIWindowScene *windowScene = self.cardWindow.windowScene;
    if (!windowScene) {
        return;
    }
    CGRect bounds = FLMLandscapeModuleVisualBounds();
    FLMLandscapeKeyboardForwardingWindow *window = self.forwardingWindow;
    if (window && window.windowScene != windowScene) {
        [self restoreKeyboardHost];
        window.hidden = YES;
        window.rootViewController = nil;
        self.forwardingWindow = nil;
        window = nil;
    }
    if (!window) {
        window = [[FLMLandscapeKeyboardForwardingWindow alloc]
            initWithWindowScene:windowScene];
        window.backgroundColor = [UIColor clearColor];
        window.opaque = NO;
        window.userInteractionEnabled = YES;
        window.keyboardInteractionFrame = CGRectNull;
        FLMLandscapeKeyboardRootViewController *rootController =
            [[FLMLandscapeKeyboardRootViewController alloc] init];
        rootController.view.backgroundColor = [UIColor clearColor];
        rootController.view.userInteractionEnabled = YES;
        window.rootViewController = rootController;
        SEL autorotationSelector =
            NSSelectorFromString(@"setAutorotates:forceUpdateInterfaceOrientation:");
        if ([window respondsToSelector:autorotationSelector]) {
            ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(
                window, autorotationSelector, NO, NO);
        }
        window.hidden = YES;
        self.forwardingWindow = window;
    }
    window.frame = bounds;
    window.bounds = CGRectMake(0.0, 0.0,
                               CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    window.rootViewController.view.transform = CGAffineTransformIdentity;
    window.rootViewController.view.bounds = window.bounds;
    window.rootViewController.view.center = CGPointMake(
        CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds));
    window.windowLevel = self.cardWindow.windowLevel + 1.0;
}

- (NSDictionary *)sharedStateSnapshot {
    BOOL active = [self routeIsActive];
    CGFloat avoidanceHeight = 0.0;
    if (active && self.keyboardVisible && self.cardInteractive &&
        self.cardScale > 0.01 && !CGRectIsNull(self.cardFrame) &&
        !CGRectIsNull(self.keyboardFrame)) {
        CGRect overlap = CGRectIntersection(self.cardFrame, self.keyboardFrame);
        if (!CGRectIsNull(overlap) && !CGRectIsEmpty(overlap)) {
            avoidanceHeight = CGRectGetHeight(overlap) / self.cardScale;
        }
        avoidanceHeight = MIN(FLMLandscapeKeyboardPortraitHeight * 0.72,
                              MAX(0.0, avoidanceHeight));
    }
    return @{
        @"version": @2,
        @"active": @(active),
        @"bundleID": active ? self.targetIdentifier : @"",
        @"sceneHash": @(active ? FLMLandscapeKeyboardIdentifierHash(
                                      FLMLandscapeKeyboardSceneIdentifier(
                                          self.targetScene))
                                  : 0),
        @"sessionGeneration": @(active ? self.sessionGeneration : 0),
        @"avoidanceVisible": @(active && self.keyboardVisible &&
                                avoidanceHeight > 0.0),
        @"avoidanceHeight": @(avoidanceHeight),
        @"cardActive": @(active && self.cardInteractive &&
                          !CGRectIsNull(self.cardFrame) && self.cardScale > 0.01),
        @"cardBottom": @(active ? CGRectGetMaxY(self.cardFrame) : 0.0),
        @"cardScale": @(active ? MAX(0.0, self.cardScale) : 0.0),
        @"cardWidth": @(active ? MAX(0.0, CGRectGetWidth(self.cardFrame)) : 0.0),
        @"cardHeight": @(active ? MAX(0.0, CGRectGetHeight(self.cardFrame)) : 0.0),
        @"contentViewportWidth": @(active ? FLMLandscapeKeyboardPortraitWidth : 0.0),
        @"contentViewportHeight": @(active ? FLMLandscapeKeyboardPortraitHeight : 0.0),
        @"updatedAt": @([[NSDate date] timeIntervalSince1970]),
    };
}

- (void)writeSharedStateAndPublishTokens {
    NSDictionary *snapshot = [self sharedStateSnapshot];
    BOOL active = [snapshot[@"active"] boolValue];
    uint64_t session = [snapshot[@"sessionGeneration"] unsignedLongLongValue];
    uint64_t routeHash = active
        ? FLMLandscapeKeyboardIdentifierHash(snapshot[@"bundleID"])
        : 0;
    uint64_t sceneHash = [snapshot[@"sceneHash"] unsignedLongLongValue];
    CGFloat avoidanceHeight = [snapshot[@"avoidanceHeight"] doubleValue];
    BOOL avoidanceVisible = [snapshot[@"avoidanceVisible"] boolValue];
    BOOL cardActive = [snapshot[@"cardActive"] boolValue];
    CGFloat cardBottom = [snapshot[@"cardBottom"] doubleValue];
    CGFloat cardScale = [snapshot[@"cardScale"] doubleValue];

    if (self.routeToken < 0) {
        notify_register_check(FLYME_KEYBOARD_NOTIFICATION, &_routeToken);
    }
    if (self.sceneToken < 0) {
        notify_register_check(FLYME_KEYBOARD_SCENE_NOTIFICATION, &_sceneToken);
    }
    if (self.sessionToken < 0) {
        notify_register_check(FLYME_KEYBOARD_SESSION_NOTIFICATION, &_sessionToken);
    }
    if (self.avoidanceToken < 0) {
        notify_register_check(FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION,
                              &_avoidanceToken);
    }
    if (self.cardGeometryToken < 0) {
        notify_register_check(FLYME_KEYBOARD_CARD_GEOMETRY_NOTIFICATION,
                              &_cardGeometryToken);
    }
    if (self.routeToken >= 0) {
        notify_set_state(self.routeToken, routeHash);
    }
    if (self.sceneToken >= 0) {
        notify_set_state(self.sceneToken, sceneHash);
    }
    if (self.sessionToken >= 0) {
        notify_set_state(self.sessionToken, session);
    }
    uint64_t encodedHeight =
        MIN(0xFFFFFFULL, (uint64_t)llround(avoidanceHeight * 100.0));
    uint64_t avoidanceState =
        (avoidanceVisible ? (1ULL << 63) : 0) |
        ((session & 0x7FFFFFFFFFULL) << 24) | encodedHeight;
    if (self.avoidanceToken >= 0) {
        notify_set_state(self.avoidanceToken, avoidanceState);
    }
    uint64_t encodedBottom =
        MIN(0xFFFFFFULL, (uint64_t)llround(cardBottom * 100.0));
    uint64_t encodedScale =
        MIN(0xFFFFFFULL, (uint64_t)llround(cardScale * 1000000.0));
    uint64_t cardState = (cardActive ? (1ULL << 63) : 0) |
                         ((session & 0x7FFFULL) << 48) |
                         (encodedBottom << 24) | encodedScale;
    if (self.cardGeometryToken >= 0) {
        notify_set_state(self.cardGeometryToken, cardState);
    }

    dispatch_async(self.sharedStateQueue, ^{
        @autoreleasepool {
            NSError *error = nil;
            NSData *data = [NSPropertyListSerialization
                dataWithPropertyList:snapshot
                              format:NSPropertyListBinaryFormat_v1_0
                             options:0
                               error:&error];
            BOOL wrote = data && !error &&
                [data writeToFile:FLMLandscapeKeyboardSharedStatePath
                          options:NSDataWritingAtomic
                            error:&error];
            NSString *path = wrote ? FLMLandscapeKeyboardSharedStatePath : nil;
            if (wrote) {
                chmod(path.fileSystemRepresentation, 0644);
            } else {
                error = nil;
                wrote = data &&
                    [data writeToFile:
                              FLMLandscapeKeyboardSharedStateRootlessPath
                              options:NSDataWritingAtomic
                                error:&error];
                path = wrote ? FLMLandscapeKeyboardSharedStateRootlessPath : nil;
                if (wrote) {
                    chmod(path.fileSystemRepresentation, 0644);
                }
            }
            if (wrote) {
                notify_post(FLYME_KEYBOARD_SHARED_STATE_NOTIFICATION);
            }
            FLMEnqueueDiagnosticLine(
                @"sb landscape-keyboard shared-state active=%d session=%llu path=%@ success=%d error=%@",
                active, (unsigned long long)session, path ?: @"<none>", wrote,
                error.localizedDescription ?: @"<none>");
        }
    });

    if (self.sessionToken >= 0) {
        notify_post(FLYME_KEYBOARD_SESSION_NOTIFICATION);
    }
    if (self.sceneToken >= 0) {
        notify_post(FLYME_KEYBOARD_SCENE_NOTIFICATION);
    }
    if (self.routeToken >= 0) {
        notify_post(FLYME_KEYBOARD_NOTIFICATION);
    }
    if (self.avoidanceToken >= 0) {
        notify_post(FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION);
    }
    if (self.cardGeometryToken >= 0) {
        notify_post(FLYME_KEYBOARD_CARD_GEOMETRY_NOTIFICATION);
    }
}

- (void)beginWithIdentifier:(NSString *)identifier
                      scene:(id)scene
                    session:(uint64_t)session
                 cardWindow:(UIWindow *)cardWindow {
    if (identifier.length == 0 || !scene || session == 0 || !cardWindow) {
        return;
    }
    if (self.sessionGeneration != 0 &&
        self.sessionGeneration != session) {
        [self endSession:self.sessionGeneration];
    }
    self.targetIdentifier = [identifier copy];
    self.targetScene = scene;
    self.sessionGeneration = session;
    self.cardWindow = cardWindow;
    self.keyboardVisible = NO;
    self.keyboardFrame = CGRectNull;
    self.keyboardFramePending = NO;
    self.pendingKeyboardFrame = CGRectNull;
    self.pendingKeyboardSessionGeneration = 0;
    self.cardInteractive = YES;
    if (!cardWindow.isKeyWindow) {
        [cardWindow makeKeyWindow];
    }
    [self prepareForwardingWindowIfNeeded];
    [self writeSharedStateAndPublishTokens];
    FLMEnqueueDiagnosticLine(
        @"sb landscape-keyboard route-begin app=%@ scene=%@ session=%llu outer=%@ cardKey=%d cardLevel=%.1f policy=external-host-only",
        identifier,
        FLMLandscapeKeyboardSceneIdentifier(scene) ?: @"<none>",
        (unsigned long long)session,
        NSStringFromCGRect(FLMLandscapeModuleVisualBounds()),
        cardWindow.isKeyWindow, cardWindow.windowLevel);
}

- (void)updateCardFrame:(CGRect)cardFrame
                  scale:(CGFloat)scale
            interactive:(BOOL)interactive {
    self.cardFrame = cardFrame;
    self.cardScale = scale;
    self.cardInteractive = interactive;
    [self writeSharedStateAndPublishTokens];
}

- (BOOL)applyKeyboardScenePairing:(id)keyboardScene
             preferredHostIdentity:(id)preferredHostIdentity {
    if (!keyboardScene || !preferredHostIdentity ||
        ![self routeIsActive]) {
        return NO;
    }
    SEL updateSelector = NSSelectorFromString(@"updateClientSettingsWithBlock:");
    if (![keyboardScene respondsToSelector:updateSelector]) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-keyboard scene-pair apply=unsupported session=%llu keyboardScene=%@ class=%@ policy=continue-native-host",
            (unsigned long long)self.sessionGeneration,
            FLMLandscapeKeyboardSceneIdentifier(keyboardScene) ?: @"<none>",
            NSStringFromClass([keyboardScene class]));
        return NO;
    }
    __block BOOL applied = NO;
    __block NSString *failure = nil;
    void (^settingsBlock)(id) = ^(id mutableSettings) {
        @try {
            id currentIdentity = nil;
            @try {
                currentIdentity =
                    [mutableSettings valueForKey:@"preferredSceneHostIdentity"];
            } @catch (__unused NSException *exception) {
            }
            if (currentIdentity && currentIdentity != preferredHostIdentity &&
                ![currentIdentity isEqual:preferredHostIdentity]) {
                failure = @"identity-changed";
                return;
            }
            SEL setter =
                NSSelectorFromString(@"setPreferredSceneHostIdentity:");
            if ([mutableSettings respondsToSelector:setter]) {
                ((void (*)(id, SEL, id))objc_msgSend)(
                    mutableSettings, setter, preferredHostIdentity);
            } else {
                [mutableSettings setValue:preferredHostIdentity
                                   forKey:@"preferredSceneHostIdentity"];
            }
            applied = YES;
        } @catch (NSException *exception) {
            failure = exception.name ?: @"exception";
        }
    };
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(keyboardScene,
                                             updateSelector,
                                             settingsBlock);
    } @catch (NSException *exception) {
        failure = exception.name ?: @"exception";
    }
    if (applied) {
        self.keyboardScene = keyboardScene;
        self.keyboardPreferredHostIdentity = preferredHostIdentity;
        self.keyboardHostSessionGeneration = self.sessionGeneration;
    }
    FLMEnqueueDiagnosticLine(
        @"sb landscape-keyboard scene-pair apply=%d session=%llu keyboardScene=%@ preferred=%p failure=%@",
        applied, (unsigned long long)self.sessionGeneration,
        FLMLandscapeKeyboardSceneIdentifier(keyboardScene) ?: @"<none>",
        (__bridge void *)preferredHostIdentity, failure ?: @"<none>");
    return applied;
}

- (void)clearKeyboardScenePairing {
    id keyboardScene = self.keyboardScene;
    id ownedIdentity = self.keyboardPreferredHostIdentity;
    uint64_t session = self.keyboardHostSessionGeneration;
    __block BOOL cleared = NO;
    SEL updateSelector = NSSelectorFromString(@"updateClientSettingsWithBlock:");
    if (keyboardScene && ownedIdentity &&
        [keyboardScene respondsToSelector:updateSelector]) {
        void (^settingsBlock)(id) = ^(id mutableSettings) {
            @try {
                id currentIdentity = nil;
                @try {
                    currentIdentity = [mutableSettings
                        valueForKey:@"preferredSceneHostIdentity"];
                } @catch (__unused NSException *exception) {
                }
                if (currentIdentity && currentIdentity != ownedIdentity &&
                    ![currentIdentity isEqual:ownedIdentity]) {
                    return;
                }
                SEL setter =
                    NSSelectorFromString(@"setPreferredSceneHostIdentity:");
                if ([mutableSettings respondsToSelector:setter]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(mutableSettings,
                                                         setter,
                                                         nil);
                } else {
                    [mutableSettings setValue:nil
                                       forKey:@"preferredSceneHostIdentity"];
                }
                cleared = YES;
            } @catch (__unused NSException *exception) {
            }
        };
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(keyboardScene,
                                                 updateSelector,
                                                 settingsBlock);
        } @catch (__unused NSException *exception) {
        }
    }
    FLMEnqueueDiagnosticLine(
        @"sb landscape-keyboard scene-pair clear=%d session=%llu keyboardScene=%@",
        cleared, (unsigned long long)session,
        FLMLandscapeKeyboardSceneIdentifier(keyboardScene) ?: @"<none>");
    self.keyboardScene = nil;
    self.keyboardPreferredHostIdentity = nil;
    self.keyboardHostSessionGeneration = 0;
}

- (void)restoreKeyboardHost {
    UIView *hostView = self.keyboardHostView;
    if (!hostView) {
        return;
    }
    [hostView removeFromSuperview];
    hostView.translatesAutoresizingMaskIntoConstraints =
        self.keyboardOriginalTranslatesAutoresizingMask;
    hostView.autoresizingMask = self.keyboardOriginalAutoresizingMask;
    hostView.transform = self.keyboardOriginalTransform;
    hostView.frame = self.keyboardOriginalFrame;
    UIView *superview = self.keyboardOriginalSuperview;
    if (superview) {
        NSUInteger index = self.keyboardOriginalSubviewIndex;
        if (index != NSNotFound && index <= superview.subviews.count) {
            [superview insertSubview:hostView atIndex:index];
        } else {
            [superview addSubview:hostView];
        }
    }
    self.keyboardHostView = nil;
    self.keyboardOriginalSuperview = nil;
    self.keyboardOriginalSubviewIndex = NSNotFound;
    FLMEnqueueDiagnosticLine(
        @"sb landscape-keyboard host-restore host=%p session=%llu",
        (__bridge void *)hostView,
        (unsigned long long)self.sessionGeneration);
}

- (BOOL)keyboardHostMatchesTarget:(UIView *)hostView
                      updatedScene:(id)updatedScene
                       owningScene:(id *)owningSceneOut
                      keyboardScene:(id *)keyboardSceneOut
             preferredHostIdentity:(id *)preferredHostIdentityOut
                            paired:(BOOL *)pairedOut {
    id owningScene = nil;
    id keyboardScene = nil;
    id preferredHostIdentity = nil;
    BOOL paired = NO;
    @try {
        owningScene = [hostView valueForKey:@"_owningScene"];
    } @catch (__unused NSException *exception) {
    }
    @try {
        keyboardScene = [hostView valueForKey:@"_keyboardScene"];
    } @catch (__unused NSException *exception) {
    }
    @try {
        preferredHostIdentity =
            [hostView valueForKey:@"_keyboardPreferredHostIdentity"];
    } @catch (__unused NSException *exception) {
    }
    @try {
        id pairedValue = [hostView valueForKey:@"_isPaired"];
        paired = [pairedValue respondsToSelector:@selector(boolValue)] &&
                 [pairedValue boolValue];
    } @catch (__unused NSException *exception) {
    }
    if (owningSceneOut) {
        *owningSceneOut = owningScene;
    }
    if (keyboardSceneOut) {
        *keyboardSceneOut = keyboardScene;
    }
    if (preferredHostIdentityOut) {
        *preferredHostIdentityOut = preferredHostIdentity;
    }
    if (pairedOut) {
        *pairedOut = paired;
    }
    NSString *targetIdentifier =
        FLMLandscapeKeyboardSceneIdentifier(self.targetScene);
    NSString *ownerIdentifier =
        FLMLandscapeKeyboardSceneIdentifier(owningScene);
    NSString *updatedIdentifier =
        FLMLandscapeKeyboardSceneIdentifier(updatedScene);
    return owningScene == self.targetScene || updatedScene == self.targetScene ||
           (targetIdentifier.length > 0 &&
            ([targetIdentifier isEqualToString:ownerIdentifier] ||
             [targetIdentifier isEqualToString:updatedIdentifier]));
}

- (void)scheduleDeferredHostRetry:(UIView *)hostView
                      updatedScene:(id)updatedScene {
    if (self.deferredHostView != hostView) {
        self.deferredAttempt = 0;
    }
    self.deferredHostView = hostView;
    self.deferredUpdatedScene = updatedScene;
    NSUInteger attempt = ++self.deferredAttempt;
    uint64_t session = self.sessionGeneration;
    if (attempt > 20) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-keyboard host-deferred timeout host=%p session=%llu",
            (__bridge void *)hostView, (unsigned long long)session);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (session != self.sessionGeneration ||
            self.deferredHostView != hostView) {
            return;
        }
        [self keyboardHostView:hostView didUpdateForScene:updatedScene];
    });
}

- (BOOL)hasActiveKeyboardHost {
    return self.keyboardHostView != nil &&
           self.keyboardHostSessionGeneration == self.sessionGeneration;
}

- (BOOL)replayPendingKeyboardFrameIfReady {
    if (!self.keyboardFramePending || !self.keyboardVisible ||
        self.pendingKeyboardSessionGeneration != self.sessionGeneration ||
        CGRectIsNull(self.pendingKeyboardFrame) ||
        ![self hasActiveKeyboardHost] || ![self routeIsActive]) {
        return NO;
    }
    [self prepareForwardingWindowIfNeeded];
    if (!self.forwardingWindow) {
        return NO;
    }
    self.keyboardFrame = self.pendingKeyboardFrame;
    self.forwardingWindow.keyboardInteractionFrame = self.keyboardFrame;
    self.forwardingWindow.windowLevel = self.cardWindow.windowLevel + 1.0;
    [self.forwardingWindow makeKeyAndVisible];
    self.keyboardFramePending = NO;
    self.pendingKeyboardFrame = CGRectNull;
    self.pendingKeyboardSessionGeneration = 0;
    [self writeSharedStateAndPublishTokens];
    FLMEnqueueDiagnosticLine(
        @"sb landscape-keyboard frame-deferred replay=1 frame=%@ host=%p session=%llu forwardingKey=%d",
        NSStringFromCGRect(self.keyboardFrame),
        (__bridge void *)self.keyboardHostView,
        (unsigned long long)self.sessionGeneration,
        self.forwardingWindow.isKeyWindow);
    return YES;
}

- (void)keyboardHostView:(UIView *)hostView didUpdateForScene:(id)updatedScene {
    if (!hostView || ![self routeIsActive]) {
        return;
    }
    id owningScene = nil;
    id keyboardScene = nil;
    id preferredHostIdentity = nil;
    BOOL paired = NO;
    BOOL matches = [self keyboardHostMatchesTarget:hostView
                                      updatedScene:updatedScene
                                       owningScene:&owningScene
                                      keyboardScene:&keyboardScene
                             preferredHostIdentity:&preferredHostIdentity
                                            paired:&paired];
    FLMEnqueueDiagnosticLine(
        @"sb landscape-keyboard host-update host=%p session=%llu target=%@ owner=%@ updated=%@ keyboardScene=%@ paired=%d preferred=%p matches=%d",
        (__bridge void *)hostView,
        (unsigned long long)self.sessionGeneration,
        FLMLandscapeKeyboardSceneIdentifier(self.targetScene) ?: @"<none>",
        FLMLandscapeKeyboardSceneIdentifier(owningScene) ?: @"<none>",
        FLMLandscapeKeyboardSceneIdentifier(updatedScene) ?: @"<none>",
        FLMLandscapeKeyboardSceneIdentifier(keyboardScene) ?: @"<none>",
        paired, (__bridge void *)preferredHostIdentity, matches);
    if (!matches) {
        return;
    }
    if (self.keyboardHostView && self.keyboardHostView != hostView &&
        self.keyboardHostSessionGeneration == self.sessionGeneration) {
        // UIKit can report an alternate keyboard host while the native host
        // is being paired.  Keep the first valid host for this route instead
        // of replacing it with a transient remote/alternate surface.
        FLMEnqueueDiagnosticLine(
            @"sb landscape-keyboard host-update ignored=alternate-current active=%p incoming=%p session=%llu",
            (__bridge void *)self.keyboardHostView,
            (__bridge void *)hostView,
            (unsigned long long)self.sessionGeneration);
        return;
    }
    if (!paired || !keyboardScene || !preferredHostIdentity) {
        if ([self hasActiveKeyboardHost] && self.keyboardHostView == hostView) {
            // The host's pairing flag can briefly drop while UIKit publishes
            // the next client-settings update.  It is still the active host;
            // do not tear it down or wait for a new host during this window.
            self.deferredHostView = nil;
            self.deferredUpdatedScene = nil;
            self.deferredAttempt = 0;
            FLMEnqueueDiagnosticLine(
                @"sb landscape-keyboard host-update ignored=unpaired-current host=%p session=%llu pending=%d",
                (__bridge void *)hostView,
                (unsigned long long)self.sessionGeneration,
                self.keyboardFramePending);
            [self replayPendingKeyboardFrameIfReady];
            return;
        }
        [self scheduleDeferredHostRetry:hostView updatedScene:updatedScene];
        return;
    }
    self.deferredHostView = nil;
    self.deferredUpdatedScene = nil;
    self.deferredAttempt = 0;
    // The host is already paired by UIKit.  Match the proven portrait route:
    // propagating preferredSceneHostIdentity is auxiliary bookkeeping, not a
    // prerequisite for moving the native host to the full-display forwarding
    // window.  Treating it as a hard gate left the keyboard inside the card on
    // builds where the remote keyboard Scene does not expose the update API.
    BOOL pairingPropagated =
        [self applyKeyboardScenePairing:keyboardScene
                  preferredHostIdentity:preferredHostIdentity];
    [self prepareForwardingWindowIfNeeded];
    UIView *forwardingRoot = self.forwardingWindow.rootViewController.view;
    if (!forwardingRoot) {
        return;
    }
    if (self.keyboardHostView != hostView) {
        self.keyboardOriginalSuperview = hostView.superview;
        self.keyboardOriginalSubviewIndex = hostView.superview
            ? [hostView.superview.subviews indexOfObject:hostView]
            : NSNotFound;
        self.keyboardOriginalFrame = hostView.frame;
        self.keyboardOriginalTransform = hostView.transform;
        self.keyboardOriginalAutoresizingMask = hostView.autoresizingMask;
        self.keyboardOriginalTranslatesAutoresizingMask =
            hostView.translatesAutoresizingMaskIntoConstraints;
        self.keyboardHostView = hostView;
        self.keyboardHostSessionGeneration = self.sessionGeneration;
    }
    if (hostView.superview != forwardingRoot) {
        [hostView removeFromSuperview];
        hostView.translatesAutoresizingMaskIntoConstraints = YES;
        hostView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                    UIViewAutoresizingFlexibleHeight;
        hostView.transform = CGAffineTransformIdentity;
        hostView.frame = forwardingRoot.bounds;
        [forwardingRoot addSubview:hostView];
    } else {
        hostView.translatesAutoresizingMaskIntoConstraints = YES;
        hostView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                    UIViewAutoresizingFlexibleHeight;
        hostView.transform = CGAffineTransformIdentity;
        hostView.frame = forwardingRoot.bounds;
    }
    [hostView setNeedsLayout];
    [hostView layoutIfNeeded];
    BOOL replayedPendingFrame = [self replayPendingKeyboardFrameIfReady];
    if (!replayedPendingFrame && self.keyboardVisible) {
        self.forwardingWindow.keyboardInteractionFrame = self.keyboardFrame;
        self.forwardingWindow.windowLevel = self.cardWindow.windowLevel + 1.0;
        [self.forwardingWindow makeKeyAndVisible];
    } else if (!self.keyboardVisible) {
        self.forwardingWindow.hidden = YES;
    }
    FLMEnqueueDiagnosticLine(
        @"sb landscape-keyboard host-attached host=%p frame=%@ session=%llu visible=%d pendingReplay=%d forwardingKey=%d level=%.1f pairingPropagated=%d route=external-full-display cardHost=0",
        (__bridge void *)hostView, NSStringFromCGRect(hostView.frame),
        (unsigned long long)self.sessionGeneration, self.keyboardVisible,
        replayedPendingFrame,
        self.forwardingWindow.isKeyWindow, self.forwardingWindow.windowLevel,
        pairingPropagated);
}

- (void)keyboardFrameWillChange:(NSNotification *)notification {
    if (![self routeIsActive]) {
        return;
    }
    NSValue *frameValue = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (![frameValue isKindOfClass:[NSValue class]]) {
        return;
    }
    CGRect rawFrame = frameValue.CGRectValue;
    CGRect bounds = FLMLandscapeModuleVisualBounds();
    BOOL visible = CGRectIntersectsRect(bounds, rawFrame) &&
                   CGRectGetMinY(rawFrame) < CGRectGetHeight(bounds);
    if (!visible) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-keyboard frame-hide-pending raw=%@ session=%llu",
            NSStringFromCGRect(rawFrame),
            (unsigned long long)self.sessionGeneration);
        return;
    }
    self.keyboardVisible = YES;
    self.keyboardFrame = CGRectIntersection(bounds, rawFrame);
    [self prepareForwardingWindowIfNeeded];
    self.forwardingWindow.keyboardInteractionFrame = self.keyboardFrame;
    if ([self hasActiveKeyboardHost]) {
        self.keyboardFramePending = NO;
        self.pendingKeyboardFrame = CGRectNull;
        self.pendingKeyboardSessionGeneration = 0;
        self.forwardingWindow.windowLevel = self.cardWindow.windowLevel + 1.0;
        [self.forwardingWindow makeKeyAndVisible];
    } else {
        self.keyboardFramePending = YES;
        self.pendingKeyboardFrame = self.keyboardFrame;
        self.pendingKeyboardSessionGeneration = self.sessionGeneration;
        FLMEnqueueDiagnosticLine(
            @"sb landscape-keyboard frame-visible waiting-host pending=1 session=%llu forwardingLevel=%.1f",
            (unsigned long long)self.sessionGeneration,
            self.forwardingWindow.windowLevel);
    }
    [self writeSharedStateAndPublishTokens];
    FLMEnqueueDiagnosticLine(
        @"sb landscape-keyboard frame-visible raw=%@ normalized=%@ outer=%@ card=%@ scale=%.6f host=%p pending=%d forwardingKey=%d",
        NSStringFromCGRect(rawFrame), NSStringFromCGRect(self.keyboardFrame),
        NSStringFromCGRect(bounds), NSStringFromCGRect(self.cardFrame),
        self.cardScale, (__bridge void *)self.keyboardHostView,
        self.keyboardFramePending,
        self.forwardingWindow.isKeyWindow);
}

- (void)keyboardDidHide:(NSNotification *)notification {
    (void)notification;
    if (self.sessionGeneration == 0) {
        return;
    }
    self.keyboardVisible = NO;
    self.keyboardFrame = CGRectNull;
    self.keyboardFramePending = NO;
    self.pendingKeyboardFrame = CGRectNull;
    self.pendingKeyboardSessionGeneration = 0;
    self.forwardingWindow.keyboardInteractionFrame = CGRectNull;
    BOOL wasKey = self.forwardingWindow.isKeyWindow;
    self.forwardingWindow.hidden = YES;
    if (wasKey && self.cardWindow && !self.cardWindow.hidden) {
        [self.cardWindow makeKeyWindow];
    }
    [self writeSharedStateAndPublishTokens];
    FLMEnqueueDiagnosticLine(
        @"sb landscape-keyboard frame-hidden session=%llu restoredCardKey=%d",
        (unsigned long long)self.sessionGeneration,
        self.cardWindow.isKeyWindow);
}

- (void)endSession:(uint64_t)session {
    if (session == 0 || session != self.sessionGeneration) {
        return;
    }
    FLMEnqueueDiagnosticLine(
        @"sb landscape-keyboard route-end begin app=%@ scene=%@ session=%llu host=%p visible=%d",
        self.targetIdentifier ?: @"<none>",
        FLMLandscapeKeyboardSceneIdentifier(self.targetScene) ?: @"<none>",
        (unsigned long long)session,
        (__bridge void *)self.keyboardHostView, self.keyboardVisible);
    self.deferredHostView = nil;
    self.deferredUpdatedScene = nil;
    self.deferredAttempt = 0;
    [self clearKeyboardScenePairing];
    [self restoreKeyboardHost];
    self.forwardingWindow.keyboardInteractionFrame = CGRectNull;
    self.forwardingWindow.hidden = YES;
    self.keyboardVisible = NO;
    self.keyboardFrame = CGRectNull;
    self.keyboardFramePending = NO;
    self.pendingKeyboardFrame = CGRectNull;
    self.pendingKeyboardSessionGeneration = 0;
    self.cardInteractive = NO;
    self.targetIdentifier = nil;
    self.targetScene = nil;
    self.cardWindow = nil;
    self.sessionGeneration = 0;
    self.cardFrame = CGRectNull;
    self.cardScale = 0.0;
    [self writeSharedStateAndPublishTokens];
    FLMEnqueueDiagnosticLine(
        @"sb landscape-keyboard route-end complete session=%llu",
        (unsigned long long)session);
}

@end

typedef void (*FLMLandscapeKeyboardHostUpdateIMP)(id,
                                                   SEL,
                                                   id,
                                                   id,
                                                   id,
                                                   id);
static FLMLandscapeKeyboardHostUpdateIMP
    FLMLandscapeOriginalKeyboardHostUpdate = NULL;
static BOOL FLMLandscapeKeyboardHostHookInstalled = NO;

static void FLMLandscapeKeyboardHostUpdateHook(id object,
                                                SEL selector,
                                                id scene,
                                                id diff,
                                                id oldClientSettings,
                                                id transitionContext) {
    if (FLMLandscapeOriginalKeyboardHostUpdate) {
        FLMLandscapeOriginalKeyboardHostUpdate(object,
                                               selector,
                                               scene,
                                               diff,
                                               oldClientSettings,
                                               transitionContext);
    }
    __weak UIView *weakHostView = [object isKindOfClass:[UIView class]]
        ? (UIView *)object
        : nil;
    __weak id weakScene = scene;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *hostView = weakHostView;
        id updatedScene = weakScene;
        if (hostView) {
            [[FLMLandscapeKeyboardCoordinator sharedCoordinator]
                keyboardHostView:hostView
                didUpdateForScene:updatedScene];
        }
    });
}

static void FLMLandscapeInstallKeyboardHostHook(NSUInteger attempt) {
    if (FLMLandscapeKeyboardHostHookInstalled) {
        return;
    }
    Class hostClass = objc_getClass("_UIKeyboardLayerHostView");
    SEL selector = NSSelectorFromString(
        @"scene:didUpdateClientSettingsWithDiff:oldClientSettings:transitionContext:");
    Method method = hostClass ? class_getInstanceMethod(hostClass, selector) : NULL;
    if (!method) {
        if (attempt < 12) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                FLMLandscapeInstallKeyboardHostHook(attempt + 1);
            });
        }
        return;
    }
    IMP current = method_getImplementation(method);
    FLMLandscapeOriginalKeyboardHostUpdate =
        (FLMLandscapeKeyboardHostUpdateIMP)current;
    method_setImplementation(method,
                             (IMP)FLMLandscapeKeyboardHostUpdateHook);
    FLMLandscapeKeyboardHostHookInstalled = YES;
    FLMEnqueueDiagnosticLine(
        @"sb landscape-keyboard host-hook installed class=%@ attempt=%lu original=%p",
        NSStringFromClass(hostClass), (unsigned long)attempt, current);
}

void FLMLandscapeKeyboardBridgeStart(void) {
    [[FLMLandscapeKeyboardCoordinator sharedCoordinator] start];
    FLMLandscapeInstallKeyboardHostHook(0);
}

void FLMLandscapeKeyboardBridgeBegin(NSString *identifier,
                                     id applicationScene,
                                     uint64_t sessionGeneration,
                                     UIWindow *cardWindow) {
    [[FLMLandscapeKeyboardCoordinator sharedCoordinator]
        beginWithIdentifier:identifier
                      scene:applicationScene
                    session:sessionGeneration
                 cardWindow:cardWindow];
}

void FLMLandscapeKeyboardBridgeUpdateCard(CGRect cardFrame,
                                          CGFloat visualScale,
                                          BOOL interactive) {
    [[FLMLandscapeKeyboardCoordinator sharedCoordinator]
        updateCardFrame:cardFrame
                  scale:visualScale
            interactive:interactive];
}

void FLMLandscapeKeyboardBridgeEnd(uint64_t sessionGeneration) {
    [[FLMLandscapeKeyboardCoordinator sharedCoordinator]
        endSession:sessionGeneration];
}

BOOL FLMLandscapeKeyboardBridgeContainsVisualPoint(CGPoint point) {
    FLMLandscapeKeyboardCoordinator *coordinator =
        [FLMLandscapeKeyboardCoordinator sharedCoordinator];
    if (![coordinator routeIsActive] || !coordinator.keyboardVisible ||
        CGRectIsNull(coordinator.keyboardFrame) ||
        CGRectIsEmpty(coordinator.keyboardFrame)) {
        return NO;
    }
    return CGRectContainsPoint(coordinator.keyboardFrame, point);
}
