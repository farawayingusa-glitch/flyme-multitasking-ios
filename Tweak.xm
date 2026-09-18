#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <notify.h>
#import <objc/message.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <stdarg.h>
#import <stdint.h>
#import <stdio.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <sys/resource.h>
#import <unistd.h>

#import "FLMDiagnostics.h"
#import "FLMSceneLifecycle.h"

#define FLYME_RUNTIME_NOTIFICATION "com.codex.flymemultitasking.runtime"
#define FLYME_PREFERENCES_NOTIFICATION CFSTR("com.codex.flymemultitasking.preferences-changed")
#define FLYME_PREFERENCES_DOMAIN CFSTR("com.codex.flymemultitasking")
#define FLYME_KEYBOARD_NOTIFICATION "com.codex.flymemultitasking.keyboard-state-changed"
#define FLYME_KEYBOARD_SCENE_NOTIFICATION "com.codex.flymemultitasking.keyboard-scene-changed"
#define FLYME_KEYBOARD_SESSION_NOTIFICATION "com.codex.flymemultitasking.keyboard-session-changed"
#define FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION "com.codex.flymemultitasking.keyboard-avoidance-changed"
#define FLYME_KEYBOARD_CARD_GEOMETRY_NOTIFICATION "com.codex.flymemultitasking.keyboard-card-geometry-changed"
#define FLYME_KEYBOARD_SHARED_STATE_NOTIFICATION "com.codex.flymemultitasking.keyboard-shared-state-changed"
#define FLYME_KEYBOARD_APP_CTOR_NOTIFICATION "com.codex.flymemultitasking.keyboard-app-ctor-v53"
#define FLYME_KEYBOARD_APP_READY_NOTIFICATION "com.codex.flymemultitasking.keyboard-app-ready-v53"
#define FLYME_KEYBOARD_DISMISS_REQUEST_NOTIFICATION "com.codex.flymemultitasking.keyboard-dismiss-request-reset-v1"
#define FLYME_KEYBOARD_APP_CTOR_MAGIC 0xF153ULL
#define FLYME_KEYBOARD_APP_READY_MAGIC 0xF253ULL
#define FLYME_KEYBOARD_APP_ADAPTER_BUILD 53ULL
#define FLYME_RUNTIME_MAGIC 0x464C594DULL
#define FLYME_LOCK_SCREEN_ITEM @"com.codex.flymemultitasking.lockscreen"
// Bump this together with the package version in control / Info.plist so the
// diagnostic log can tell one build from another.
#define FLMLogBuildString @"Landscape Canvas Unification 0.9.71 (scene-space windows, rotated canvas, wheel solver, keyboard space)"

// Kept only to discard the identifier left by older installs. It is not a
// supported wheel item and must never be rendered or activated.
static NSString *const FLMRemovedLegacyWheelItemIdentifier =
    @"com.codex.flymemultitasking.screensense";

typedef NS_ENUM(NSInteger, FLMLandscapeRawCoordinateMode) {
    FLMLandscapeRawCoordinateModeUnknown = 0,
    FLMLandscapeRawCoordinateModeCurrent,
    FLMLandscapeRawCoordinateModeFixedLandscapeLeft,
    FLMLandscapeRawCoordinateModeFixedLandscapeRight,
};

static NSString *FLMLandscapeRawCoordinateModeName(
    FLMLandscapeRawCoordinateMode mode) {
    switch (mode) {
        case FLMLandscapeRawCoordinateModeCurrent:
            return @"current";
        case FLMLandscapeRawCoordinateModeFixedLandscapeLeft:
            return @"fixed-left";
        case FLMLandscapeRawCoordinateModeFixedLandscapeRight:
            return @"fixed-right";
        case FLMLandscapeRawCoordinateModeUnknown:
        default:
            return @"unknown";
    }
}

static const char *FLMDiagnosticPrimaryPath =
    "/var/jb/var/mobile/Library/Preferences/FlymeMultitasking-Diagnostic.log";
static const char *FLMDiagnosticFallbackPath =
    "/var/mobile/Library/Preferences/FlymeMultitasking-Diagnostic.log";
static dispatch_queue_t FLMDiagnosticWriterQueue;
static BOOL FLMDiagnosticWriterReady = NO;
static dispatch_semaphore_t FLMDiagnosticPendingSlots;
static os_unfair_lock FLMDiagnosticDropLock = OS_UNFAIR_LOCK_INIT;
static NSUInteger FLMDiagnosticDroppedLines = 0;
// Accessed only on the serial diagnostic writer queue.
static NSMutableData *FLMDiagnosticBuffer;
static BOOL FLMDiagnosticFlushScheduled = NO;
static int FLMDiagnosticLegacyReceiverToken = -1;
static int FLMDiagnosticSpringBoardReceiverToken = -1;
static int FLMDiagnosticApplicationReceiverToken = -1;
static int FLMDiagnosticKeyboardReceiverToken = -1;
static int FLMDiagnosticUIKitOtherReceiverToken = -1;
static const off_t FLMDiagnosticMaximumSize = 1024 * 1024;
static const CGFloat FLMKeyboardAccessoryProtectionHeight = 56.0;

static const char *FLMDiagnosticRoleName(uint8_t role) {
    switch (role) {
        case FLMDiagnosticRoleSpringBoard: return "springboard";
        case FLMDiagnosticRoleApplication: return "application";
        case FLMDiagnosticRoleKeyboardExtension: return "keyboard-extension";
        case FLMDiagnosticRoleUIKitOther: return "uikit-other";
        default: return "unknown";
    }
}

static const char *FLMDiagnosticEventName(uint8_t event) {
    switch (event) {
        case FLMDiagnosticEventProcessReady: return "process-ready";
        case FLMDiagnosticEventRouteReload: return "route-reload";
        case FLMDiagnosticEventResponderBecome: return "responder-become";
        case FLMDiagnosticEventResponderResign: return "responder-resign";
        case FLMDiagnosticEventFramePublish: return "frame-publish";
        case FLMDiagnosticEventFrameObserved: return "frame-observed";
        case FLMDiagnosticEventFrameCorrected: return "frame-corrected";
        case FLMDiagnosticEventCardGeometry: return "card-geometry";
        case FLMDiagnosticEventAvoidanceReload: return "avoidance-reload";
        case FLMDiagnosticEventIntersection: return "intersection";
        case FLMDiagnosticEventDismissRequest: return "dismiss-request";
        case FLMDiagnosticEventWillHide: return "will-hide";
        case FLMDiagnosticEventDidHide: return "did-hide";
        case FLMDiagnosticEventSceneMatch: return "scene-match";
        case FLMDiagnosticEventLayoutRefresh: return "layout-refresh";
        case FLMDiagnosticEventRouteReady: return "route-ready";
        case FLMDiagnosticEventDismissAck: return "dismiss-ack";
        case FLMDiagnosticEventAdapterLoaded: return "adapter-loaded";
        case FLMDiagnosticEventAdapterCtor: return "adapter-ctor";
        case FLMDiagnosticEventAdapterReady: return "adapter-ready";
        case FLMDiagnosticEventInputSuppressed: return "input-suppressed";
        default: return "unknown-event";
    }
}

static void FLMRotateDiagnosticFileIfNeeded(const char *path) {
    if (!path) {
        return;
    }
    struct stat information;
    if (stat(path, &information) != 0 ||
        information.st_size < FLMDiagnosticMaximumSize) {
        return;
    }
    char previousPath[PATH_MAX];
    int length = snprintf(previousPath, sizeof(previousPath), "%s.previous", path);
    if (length <= 0 || (size_t)length >= sizeof(previousPath)) {
        return;
    }
    unlink(previousPath);
    rename(path, previousPath);
}

static int FLMOpenDiagnosticFile(void) {
    FLMRotateDiagnosticFileIfNeeded(FLMDiagnosticPrimaryPath);
    int descriptor = open(FLMDiagnosticPrimaryPath,
                          O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                          0644);
    if (descriptor >= 0) {
        return descriptor;
    }
    FLMRotateDiagnosticFileIfNeeded(FLMDiagnosticFallbackPath);
    return open(FLMDiagnosticFallbackPath,
                O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                0644);
}

static void FLMFlushDiagnosticBufferNow(void) {
    if (FLMDiagnosticBuffer.length == 0) return;
    // Finish the already-captured tail even if capture was just switched off.
    // New lines remain gated in FLMAppendDiagnosticLineNow.
    int descriptor = FLMOpenDiagnosticFile();
    if (descriptor >= 0) {
        const uint8_t *bytes = (const uint8_t *)FLMDiagnosticBuffer.bytes;
        size_t remaining = FLMDiagnosticBuffer.length;
        while (remaining > 0) {
            ssize_t written = write(descriptor, bytes, remaining);
            if (written > 0) {
                bytes += written;
                remaining -= (size_t)written;
            } else if (written < 0 && errno == EINTR) {
                continue;
            } else {
                break;
            }
        }
        close(descriptor);
    }
    [FLMDiagnosticBuffer setLength:0];
}

static void FLMAppendDiagnosticLineNow(NSString *message) {
    if (!FLMDiagnosticCaptureEnabled() || message.length == 0) return;
    struct timeval now;
    gettimeofday(&now, NULL);
    NSString *line = [NSString stringWithFormat:@"%lld.%03d pid=%d %@\n",
        (long long)now.tv_sec, (int)(now.tv_usec / 1000), getpid(), message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!FLMDiagnosticBuffer) FLMDiagnosticBuffer = [NSMutableData data];
    if (FLMDiagnosticBuffer.length + data.length > 64 * 1024)
        FLMFlushDiagnosticBufferNow();
    if (data.length <= 64 * 1024) [FLMDiagnosticBuffer appendData:data];
    os_unfair_lock_lock(&FLMDiagnosticDropLock);
    NSUInteger dropped = FLMDiagnosticDroppedLines;
    FLMDiagnosticDroppedLines = 0;
    os_unfair_lock_unlock(&FLMDiagnosticDropLock);
    if (dropped) {
        NSString *summary = [NSString stringWithFormat:
            @"%lld.%03d pid=%d diagnostic-dropped lines=%lu reason=queue-limit\n",
            (long long)now.tv_sec, (int)(now.tv_usec / 1000), getpid(),
            (unsigned long)dropped];
        [FLMDiagnosticBuffer appendData:[summary dataUsingEncoding:NSUTF8StringEncoding]];
    }
    if (!FLMDiagnosticFlushScheduled) {
        FLMDiagnosticFlushScheduled = YES;
        // One finite flush per burst; no periodic timer when logging is idle.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                       FLMDiagnosticWriterQueue, ^{
            FLMDiagnosticFlushScheduled = NO;
            FLMFlushDiagnosticBufferNow();
        });
    }
}

void FLMEnqueueDiagnosticLine(NSString *format, ...) {
    if (!FLMDiagnosticCaptureEnabled() || !FLMDiagnosticWriterReady || !FLMDiagnosticWriterQueue ||
        format.length == 0) {
        return;
    }
    if (dispatch_semaphore_wait(FLMDiagnosticPendingSlots, DISPATCH_TIME_NOW) != 0) {
        os_unfair_lock_lock(&FLMDiagnosticDropLock);
        FLMDiagnosticDroppedLines += 1;
        os_unfair_lock_unlock(&FLMDiagnosticDropLock);
        return;
    }
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format
                                               arguments:arguments];
    va_end(arguments);
    dispatch_async(FLMDiagnosticWriterQueue, ^{
        @autoreleasepool {
            FLMAppendDiagnosticLineNow(message);
        }
        dispatch_semaphore_signal(FLMDiagnosticPendingSlots);
    });
}

static void FLMRecordRemoteDiagnosticEvent(int token) {
    if (!FLMDiagnosticCaptureEnabled()) return;
    uint64_t state = 0;
    if (token < 0 || notify_get_state(token, &state) != NOTIFY_STATUS_OK) {
        return;
    }
    uint8_t event = (uint8_t)(state >> 56);
    uint8_t role = (uint8_t)((state >> 48) & 0xFFULL);
    uint16_t session = (uint16_t)((state >> 32) & 0xFFFFULL);
    uint16_t first = (uint16_t)((state >> 16) & 0xFFFFULL);
    uint16_t second = (uint16_t)(state & 0xFFFFULL);
    FLMAppendDiagnosticLineNow(
        [NSString stringWithFormat:
            @"remote role=%s event=%s session=%u a=%u b=%u raw=0x%016llx",
            FLMDiagnosticRoleName(role), FLMDiagnosticEventName(event),
            session, first, second, (unsigned long long)state]);
}

static void FLMRegisterDiagnosticReceiver(const char *notificationName,
                                          int *receiverToken) {
    notify_register_dispatch(notificationName,
                             receiverToken,
                             FLMDiagnosticWriterQueue,
                             ^(int deliveredToken) {
        FLMRecordRemoteDiagnosticEvent(deliveredToken);
    });
}

static void FLMStartDiagnosticWriter(void) {
    CFPreferencesSynchronize(FLYME_PREFERENCES_DOMAIN,
                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPropertyListRef capture = CFPreferencesCopyValue(
        CFSTR("diagnosticCaptureEnabled"), FLYME_PREFERENCES_DOMAIN,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    id captureValue = CFBridgingRelease(capture);
    FLMSetDiagnosticCaptureState([captureValue isKindOfClass:[NSNumber class]] &&
                                 [captureValue boolValue]);
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FLMDiagnosticWriterQueue =
            dispatch_queue_create("com.codex.flymemultitasking.diagnostic-writer",
                                  DISPATCH_QUEUE_SERIAL);
        FLMRegisterDiagnosticReceiver(FLYME_DIAGNOSTIC_EVENT_NOTIFICATION,
                                      &FLMDiagnosticLegacyReceiverToken);
        FLMRegisterDiagnosticReceiver(FLYME_DIAGNOSTIC_SPRINGBOARD_NOTIFICATION,
                                      &FLMDiagnosticSpringBoardReceiverToken);
        FLMRegisterDiagnosticReceiver(FLYME_DIAGNOSTIC_APPLICATION_NOTIFICATION,
                                      &FLMDiagnosticApplicationReceiverToken);
        FLMRegisterDiagnosticReceiver(FLYME_DIAGNOSTIC_KEYBOARD_NOTIFICATION,
                                      &FLMDiagnosticKeyboardReceiverToken);
        FLMRegisterDiagnosticReceiver(FLYME_DIAGNOSTIC_UIKIT_OTHER_NOTIFICATION,
                                      &FLMDiagnosticUIKitOtherReceiverToken);
        FLMDiagnosticPendingSlots = dispatch_semaphore_create(512);
        FLMDiagnosticWriterReady = YES;
        dispatch_async(FLMDiagnosticWriterQueue, ^{
            @autoreleasepool {
                FLMAppendDiagnosticLineNow(
                    [NSString stringWithFormat:@"logger-ready build=%@ schema=19",
                                               FLMLogBuildString]);
            }
        });
    });
}

static const CGFloat FLMDefaultWheelRadius = 202.0;
static const CGFloat FLMMinimumWheelRadius = 170.0;
static const CGFloat FLMMaximumWheelRadius = 225.0;
static const CGFloat FLMDefaultWheelIconSize = 56.0;
static const CGFloat FLMMinimumWheelIconSize = 44.0;
static const CGFloat FLMMaximumWheelIconSize = 68.0;
static const CGFloat FLMDefaultCornerTriggerSize = 58.0;
static const CGFloat FLMMinimumCornerTriggerSize = 36.0;
static const CGFloat FLMMaximumCornerTriggerSize = 96.0;
static CGFloat FLMCornerTriggerSize = FLMDefaultCornerTriggerSize;
static const CGFloat FLMDefaultDockWidth = 156.0;
static const CGFloat FLMMinimumDockWidth = 156.0;
static const CGFloat FLMMaximumDockWidth = 270.0;
static const CGFloat FLMDockSideMargin = 10.0;
static const CGFloat FLMDockTopMargin = 8.0;
// The centered card is a physical presentation surface for a full-screen
// application. The app Scene and keyboard always remain 390x844. The card
// width selects one uniform presentation scale; top/bottom crop values then
// select which part of that full-screen surface remains visible.
static const CGFloat FLMCenteredCardWidth = 315.0;
static const CGFloat FLMCenteredCardTopCrop = 37.0;
static const CGFloat FLMCenteredCardBottomCrop = 19.0;
static const CGFloat FLMMinimumCenteredCardWidth = 240.0;
static const CGFloat FLMMaximumCenteredCardWidth = 360.0;
static const CGFloat FLMMinimumCenteredCardCrop = 0.0;
static const CGFloat FLMMaximumCenteredCardCrop = 260.0;
// The Scene remains display-sized at 390x844. The physical card height is
// computed as width * 844 / 390 - topCrop - bottomCrop.
static const CGFloat FLMVirtualViewportWidth = 390.0;
static const CGFloat FLMVirtualViewportHeight = 844.0;
// Landscape is an independent system/presentation contract. The system Scene
// remains true landscape for KeyboardServices while the target application
// content is rendered into a portrait logical strip and only that strip is
// presented as the visible card.
static const CGFloat FLMLandscapeCardSideMargin = 8.0;
static const CGFloat FLMLandscapeCardVerticalMargin = 8.0;
static const CGFloat FLMLandscapeHandleVisibleLength =
    FLMCenteredCardWidth * 0.30; // 94.5 pt, same as centered portrait bar.
static const CGFloat FLMLandscapeHandleDockActivationDistance = 92.0;
static const CGFloat FLMLandscapeHandleFullscreenActivationDistance = 150.0;
static const CGFloat FLMCenteredDockActivationDistance = 110.0;
static const CGFloat FLMDefaultCenteredDockSwipeThreshold = 20.0;
static const CGFloat FLMMinimumCenteredDockSwipeThreshold = 8.0;
static const CGFloat FLMMaximumCenteredDockSwipeThreshold = 120.0;
static const CGFloat FLMDefaultDockedShrinkAmount = 0.0;
static const CGFloat FLMMinimumDockedShrinkAmount = 0.0;
static const CGFloat FLMMaximumDockedShrinkAmount = 60.0;
static const CGFloat FLMMinimumDockPresentationWidth = 96.0;
static const CGFloat FLMDockAnimationSpeed = 0.85;
static const NSTimeInterval FLMFloatingLaunchTimeout = 6.5;
static const NSTimeInterval FLMFloatingSceneSettleDelay = 0.10;
static const NSTimeInterval FLMFloatingScenePollInterval = 0.05;
static const NSTimeInterval FLMFloatingSceneResolveGraceDelay = 0.03;

// Scene/presenter polling starts at the original 50 ms cadence and then backs
// off geometrically, so a slow launch no longer runs a 20 Hz main-queue
// heartbeat for the whole timeout window. The retry budget is unchanged; only
// the spacing grows (50 ms -> capped 400 ms).
static NSTimeInterval FLMFloatingSceneRetryDelay(NSUInteger attempt) {
    NSTimeInterval delay =
        FLMFloatingScenePollInterval * pow(1.35, (double)attempt);
    return MIN(0.40, MAX(FLMFloatingScenePollInterval, delay));
}
static const NSTimeInterval FLMFloatingLaunchCoverSettleDelay = 0.02;
static const NSTimeInterval FLMFloatingLaunchCoverFadeDuration = 0.05;
static const NSTimeInterval FLMFloatingFullscreenActivationDelay = 0.02;
static const NSTimeInterval FLMFloatingFullscreenHandoffPollInterval = 0.03;
static const CGFloat FLMFloatingFullscreenActivationThreshold = 0.85;
static const NSTimeInterval FLMFloatingSceneGenerationDelay = 0.75;
static const NSTimeInterval FLMFloatingPresenterRecoveryTimeout = 1.0;
static const NSTimeInterval FLMFloatingCloseFallbackDelay = 0.45;
// A dock tap can be held by UIKit for a short interval after the dock
// recognizer has ended. Keep the remote host non-interactive for that tail so
// a dock-to-centered transition cannot replay the same touch into app content.
static const NSTimeInterval FLMFloatingDockContentTailProtectionDuration = 0.14;
// A dock touch must choose one owner at its beginning.  The previous
// implementation inferred the owner again on every Changed callback, so an
// ordinary card drag could turn into a hide gesture (or a resize) halfway
// through the same touch.
typedef NS_ENUM(NSUInteger, FLMFloatingDockInputMode) {
    FLMFloatingDockInputModeNone = 0,
    FLMFloatingDockInputModeCardDrag,
    FLMFloatingDockInputModeResize,
    FLMFloatingDockInputModeHiddenReveal,
};

static NSString *FLMFloatingDockInputModeName(FLMFloatingDockInputMode mode) {
    switch (mode) {
        case FLMFloatingDockInputModeCardDrag:
            return @"card-drag";
        case FLMFloatingDockInputModeResize:
            return @"resize";
        case FLMFloatingDockInputModeHiddenReveal:
            return @"hidden-reveal";
        default:
            return @"none";
    }
}

static const CGFloat FLMFloatingDockHideIntentDistance = 18.0;
static const CGFloat FLMFloatingDockHideIntentHorizontalRatio = 1.35;
typedef NS_ENUM(NSUInteger, FLMFloatingLaunchState) {
    FLMFloatingLaunchStateIdle,
    FLMFloatingLaunchStatePrewarming,
    FLMFloatingLaunchStateWaitingForScene,
    FLMFloatingLaunchStateWaitingForPresenter,
    FLMFloatingLaunchStateAttached,
    FLMFloatingLaunchStateFailing,
    FLMFloatingLaunchStateClosing,
};

@interface NSObject (FLMRuntimePrivate)
+ (id)defaultWorkspace;
+ (id)sharedInstance;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleIdentifier;
- (void)lockUIFromSource:(NSInteger)source withOptions:(id)options;
- (id)frontmostApplication;
- (id)_accessibilityFrontMostApplication;
- (NSString *)bundleIdentifier;
- (NSString *)displayIdentifier;
@end

@interface FLMDisplayConfiguration : NSObject
- (id)identity;
@end

@interface UIScreen (FLMRuntimePrivate)
- (FLMDisplayConfiguration *)displayConfiguration;
@end

@interface FLMSystemGestureManager : NSObject
+ (instancetype)sharedInstance;
- (void)addGestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       toDisplayWithIdentity:(id)displayIdentity;
@end

@interface UIApplication (FLMRuntimePrivate)
- (BOOL)launchApplicationWithIdentifier:(NSString *)identifier suspended:(BOOL)suspended;
- (void)_simulateLockButtonPress;
@end

@interface UIImage (FLMRuntimePrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier
                                               format:(NSInteger)format
                                                scale:(CGFloat)scale;
@end

@interface FLMSBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (id)applicationWithBundleIdentifier:(NSString *)bundleIdentifier;
@end

@interface FLMSBApplication : NSObject
@end

@interface FLMApplicationSceneHandle : NSObject
- (id)sceneIfExists;
- (id)scene;
@end

@interface FLMDeviceApplicationSceneEntity : NSObject
- (instancetype)initWithApplicationForMainDisplay:(id)application
             generatingNewPrimarySceneIfRequired:(BOOL)required;
- (FLMApplicationSceneHandle *)sceneHandle;
@end

@interface NSObject (FLMSceneHostingPrivate)
- (id)settings;
- (id)mutableSettings;
- (NSString *)identifier;
- (NSString *)sceneIdentifier;
- (id)uiPresentationManager;
- (id)presentationManager;
- (id)createPresenterWithIdentifier:(NSString *)identifier;
- (UIView *)presentationView;
- (void)activate;
- (void)deactivate;
- (void)invalidate;
- (void)setForeground:(BOOL)foreground;
- (void)setBackgrounded:(BOOL)backgrounded;
- (void)setDeactivationReasons:(unsigned long long)reasons;
- (void)setFrame:(CGRect)frame;
- (void)setInterfaceOrientation:(NSInteger)orientation;
- (void)updateSettings:(id)settings withTransitionContext:(id)context;
- (void)updateClientSettingsWithBlock:(void (^)(id mutableSettings))block;
- (void)_setContentState:(NSInteger)state;
@end

static BOOL FLMDeviceIsLocked(void) {
    id manager = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
    if (!manager) {
        return NO;
    }
    NSArray<NSString *> *selectorNames =
        @[@"isUILocked", @"isLockScreenVisible", @"isLockScreenActive", @"isLocked"];
    for (NSString *selectorName in selectorNames) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![manager respondsToSelector:selector]) {
            continue;
        }
        BOOL (*getter)(id, SEL) =
            (BOOL (*)(id, SEL))[manager methodForSelector:selector];
        if (getter && getter(manager, selector)) {
            return YES;
        }
    }
    return NO;
}

static CGRect FLMVisualScreenBounds(void) {
    UIScreen *screen = [UIScreen mainScreen];
    CGRect bounds = screen.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);

    // On several iOS 16 SpringBoard builds the status-bar/interface
    // orientation can remain Portrait while an application owns the physical
    // display in landscape. Prefer already-landscape screen bounds, otherwise
    // use the real device orientation to recover the physical logical size
    // from nativeBounds. This is presentation geometry only; it does not
    // mutate the target application's Scene orientation.
    UIDeviceOrientation deviceOrientation = [UIDevice currentDevice].orientation;
    BOOL deviceLandscape =
        deviceOrientation == UIDeviceOrientationLandscapeLeft ||
        deviceOrientation == UIDeviceOrientationLandscapeRight;
    if (width <= height + 1.0 && deviceLandscape) {
        CGRect nativeBounds = screen.nativeBounds;
        CGFloat scale = screen.nativeScale;
        if (scale <= 0.0) scale = screen.scale;
        if (scale <= 0.0) scale = 1.0;
        CGFloat nativeWidth = CGRectGetWidth(nativeBounds) / scale;
        CGFloat nativeHeight = CGRectGetHeight(nativeBounds) / scale;
        CGFloat longSide = MAX(nativeWidth, nativeHeight);
        CGFloat shortSide = MIN(nativeWidth, nativeHeight);
        if (longSide > 1.0 && shortSide > 1.0) {
            return CGRectMake(0.0, 0.0, longSide, shortSide);
        }
    }
    return CGRectMake(0.0, 0.0, width, height);
}

static CGRect FLMSpringBoardWindowBounds(void) {
    // UIWindow geometry belongs to SpringBoard's own scene coordinate space.
    // On the affected iOS 16 path that space intentionally remains portrait
    // (for example 390x844) even while the physical display presentation is
    // landscape (844x390). Never size a SpringBoard UIWindow with the physical
    // landscape bounds; only the child presentation canvas is rotated.
    CGRect bounds = [UIScreen mainScreen].bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    if (width < 1.0 || height < 1.0) {
        return FLMVisualScreenBounds();
    }
    return CGRectMake(0.0, 0.0, width, height);
}

static BOOL FLMBoundsAreLandscape(CGRect bounds) {
    return CGRectGetWidth(bounds) > CGRectGetHeight(bounds) + 1.0;
}

static BOOL FLMDisplayIsLandscape(void) {
    return FLMBoundsAreLandscape(FLMVisualScreenBounds());
}

static UIInterfaceOrientation FLMReportedSceneOrientation(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateForegroundActive ||
            windowScene.activationState == UISceneActivationStateForegroundInactive) {
            return windowScene.interfaceOrientation;
        }
    }
    return UIInterfaceOrientationUnknown;
}

static UIInterfaceOrientation FLMLandscapeOrientationForSafeInsets(
    UIEdgeInsets safeInsets) {
    // A notched iPhone exposes the physical top edge via the larger horizontal
    // safe-area even when SpringBoard momentarily reports portrait.
    if (safeInsets.left > safeInsets.right + 2.0) {
        return UIInterfaceOrientationLandscapeLeft;
    }
    if (safeInsets.right > safeInsets.left + 2.0) {
        return UIInterfaceOrientationLandscapeRight;
    }
    UIDeviceOrientation deviceOrientation = [UIDevice currentDevice].orientation;
    if (deviceOrientation == UIDeviceOrientationLandscapeLeft) {
        return UIInterfaceOrientationLandscapeRight;
    }
    if (deviceOrientation == UIDeviceOrientationLandscapeRight) {
        return UIInterfaceOrientationLandscapeLeft;
    }
    UIInterfaceOrientation reported = FLMReportedSceneOrientation();
    if (UIInterfaceOrientationIsLandscape(reported)) {
        return reported;
    }
    return UIInterfaceOrientationLandscapeLeft;
}

static UIEdgeInsets FLMPhysicalLandscapeSafeInsets(
    UIEdgeInsets springBoardInsets,
    UIInterfaceOrientation orientation) {
    // SpringBoard can keep reporting its portrait safe area while another
    // application's Scene owns the display in landscape. Preserve genuine
    // landscape left/right insets when present; otherwise rotate the portrait
    // sensor/home-indicator values into physical landscape coordinates.
    if (springBoardInsets.left > 1.0 || springBoardInsets.right > 1.0) {
        return springBoardInsets;
    }
    CGFloat sensorInset = MAX(0.0, springBoardInsets.top);
    CGFloat bottomInset = springBoardInsets.bottom > 1.0
                              ? MIN(21.0, springBoardInsets.bottom)
                              : 0.0;
    if (orientation == UIInterfaceOrientationLandscapeRight) {
        return UIEdgeInsetsMake(0.0, 0.0, bottomInset, sensorInset);
    }
    return UIEdgeInsetsMake(0.0, sensorInset, bottomInset, 0.0);
}

static CGPoint FLMVisualPointFromRootPoint(CGPoint rootPoint,
                                           CGRect rootBounds,
                                           CGRect visualBounds,
                                           UIInterfaceOrientation orientation) {
    if (!FLMBoundsAreLandscape(visualBounds) ||
        CGRectGetWidth(rootBounds) > CGRectGetHeight(rootBounds) + 1.0) {
        return rootPoint;
    }
    CGFloat visualWidth = CGRectGetWidth(visualBounds);
    CGFloat visualHeight = CGRectGetHeight(visualBounds);
    if (orientation == UIInterfaceOrientationLandscapeLeft) {
        return CGPointMake(visualWidth - rootPoint.y, rootPoint.x);
    }
    return CGPointMake(rootPoint.y, visualHeight - rootPoint.x);
}

static id<UICoordinateSpace> FLMCanvasScreenSpace(UIView *canvas) {
    UIScreen *screen = canvas.window.screen ?: [UIScreen mainScreen];
    return screen ? screen.coordinateSpace : nil;
}

static BOOL FLMCanvasOriginLandedOnFarCorner(UIView *canvas,
                                             CGRect visualBounds) {
    // A rotated canvas can be mounted with either sign and both put an 844x390
    // bounding box on the display, so only an asymmetric point tells them
    // apart. When the sign matches what the system already applies between the
    // window scene and the display, the canvas' own origin lands on the visual
    // origin; when it does not, it lands on the opposite corner.
    id<UICoordinateSpace> screenSpace = FLMCanvasScreenSpace(canvas);
    if (!screenSpace) {
        return NO;
    }
    CGPoint measured = [canvas convertPoint:CGPointZero
                         toCoordinateSpace:screenSpace];
    CGPoint expected = visualBounds.origin;
    CGPoint opposite = CGPointMake(CGRectGetMaxX(visualBounds),
                                   CGRectGetMaxY(visualBounds));
    CGFloat expectedDistance = hypot(measured.x - expected.x,
                                     measured.y - expected.y);
    CGFloat oppositeDistance = hypot(measured.x - opposite.x,
                                     measured.y - opposite.y);
    return oppositeDistance + 1.0 < expectedDistance;
}

static void FLMLogCanvasVerification(UIView *canvas,
                                     CGRect visualBounds,
                                     int sign,
                                     BOOL rotated,
                                     BOOL corrected) {
    id<UICoordinateSpace> screenSpace = FLMCanvasScreenSpace(canvas);
    CGRect canvasInScreen =
        screenSpace ? [canvas convertRect:canvas.bounds
                        toCoordinateSpace:screenSpace]
                    : CGRectNull;
    static CGRect lastCanvasInScreen = {{0.0, 0.0}, {0.0, 0.0}};
    static int lastSign = 0;
    static BOOL lastCorrected = NO;
    static BOOL hasLogged = NO;
    if (hasLogged && lastSign == sign && lastCorrected == corrected &&
        CGRectEqualToRect(lastCanvasInScreen, canvasInScreen)) {
        return;
    }
    hasLogged = YES;
    lastSign = sign;
    lastCorrected = corrected;
    lastCanvasInScreen = canvasInScreen;
    UIScreen *screen = canvas.window.screen ?: [UIScreen mainScreen];
    FLMEnqueueDiagnosticLine(
        @"sb canvas-verify canvas=%@ visual=%@ screen=%@ sign=%d rotated=%d corrected=%d",
        NSStringFromCGRect(canvasInScreen), NSStringFromCGRect(visualBounds),
        NSStringFromCGRect(screen ? screen.bounds : CGRectNull), sign,
        rotated ? 1 : 0, corrected ? 1 : 0);
}

static void FLMConfigureVisualCanvas(UIView *canvas,
                                     UIView *rootView,
                                     CGRect visualBounds,
                                     UIInterfaceOrientation orientation) {
    if (!canvas || !rootView) {
        return;
    }
    CGRect rootBounds = rootView.bounds;
    canvas.autoresizingMask = UIViewAutoresizingNone;
    canvas.transform = CGAffineTransformIdentity;
    if (FLMBoundsAreLandscape(visualBounds) &&
        CGRectGetWidth(rootBounds) <= CGRectGetHeight(rootBounds) + 1.0) {
        canvas.bounds = CGRectMake(0.0, 0.0,
                                   CGRectGetWidth(visualBounds),
                                   CGRectGetHeight(visualBounds));
        canvas.center = CGPointMake(CGRectGetMidX(rootBounds),
                                    CGRectGetMidY(rootBounds));
        int sign = orientation == UIInterfaceOrientationLandscapeLeft ? -1 : 1;
        canvas.transform =
            CGAffineTransformMakeRotation((CGFloat)sign * (CGFloat)M_PI_2);
        BOOL corrected = NO;
        // The system already rotates between the window scene and the display,
        // so the direction that pairs with it depends on the live orientation
        // pair. Measure instead of assuming one of the two landscape cases.
        if (FLMCanvasOriginLandedOnFarCorner(canvas, visualBounds)) {
            sign = -sign;
            canvas.transform =
                CGAffineTransformMakeRotation((CGFloat)sign * (CGFloat)M_PI_2);
            corrected = YES;
        }
        FLMLogCanvasVerification(canvas, visualBounds, sign, YES, corrected);
        return;
    }
    canvas.transform = CGAffineTransformIdentity;
    canvas.frame = rootBounds;
}

static CGPoint FLMVisualPointFromRawPoint(CGPoint rawPoint) {
    CGRect visualBounds = FLMVisualScreenBounds();
    if (!FLMBoundsAreLandscape(visualBounds) ||
        CGRectContainsPoint(visualBounds, rawPoint)) {
        return rawPoint;
    }

    // Some SpringBoard keyboard/gesture transactions temporarily report a
    // portrait-space point even though the physical display is landscape.
    // Convert only points that cannot belong to the visible landscape bounds,
    // then use the physical orientation to choose the matching rotation.
    CGRect portraitBounds = CGRectMake(0.0,
                                       0.0,
                                       CGRectGetHeight(visualBounds),
                                       CGRectGetWidth(visualBounds));
    if (!CGRectContainsPoint(portraitBounds, rawPoint)) {
        return rawPoint;
    }

    CGFloat portraitWidth = CGRectGetWidth(portraitBounds);
    CGFloat portraitHeight = CGRectGetHeight(portraitBounds);
    CGPoint candidateLeft =
        CGPointMake(rawPoint.y, portraitWidth - rawPoint.x);
    CGPoint candidateRight =
        CGPointMake(portraitHeight - rawPoint.y, rawPoint.x);
    BOOL leftInside = CGRectContainsPoint(visualBounds, candidateLeft);
    BOOL rightInside = CGRectContainsPoint(visualBounds, candidateRight);
    UIInterfaceOrientation orientation =
        FLMLandscapeOrientationForSafeInsets(UIEdgeInsetsZero);
    if (orientation == UIInterfaceOrientationLandscapeLeft && leftInside) {
        return candidateLeft;
    }
    if (orientation == UIInterfaceOrientationLandscapeRight && rightInside) {
        return candidateRight;
    }
    if (leftInside && !rightInside) {
        return candidateLeft;
    }
    if (rightInside && !leftInside) {
        return candidateRight;
    }
    return rawPoint;
}

static CGPoint FLMLandscapeVisualPointFromRawPoint(
    CGPoint rawPoint,
    CGRect visualBounds,
    FLMLandscapeRawCoordinateMode mode) {
    if (!FLMBoundsAreLandscape(visualBounds)) {
        return rawPoint;
    }
    CGFloat shortSide = MIN(CGRectGetWidth(visualBounds),
                            CGRectGetHeight(visualBounds));
    CGFloat longSide = MAX(CGRectGetWidth(visualBounds),
                           CGRectGetHeight(visualBounds));
    switch (mode) {
        case FLMLandscapeRawCoordinateModeFixedLandscapeLeft:
            return CGPointMake(rawPoint.y, shortSide - rawPoint.x);
        case FLMLandscapeRawCoordinateModeFixedLandscapeRight:
            return CGPointMake(longSide - rawPoint.y, rawPoint.x);
        case FLMLandscapeRawCoordinateModeCurrent:
        case FLMLandscapeRawCoordinateModeUnknown:
        default:
            return rawPoint;
    }
}

static CGFloat FLMLandscapeNotchAvoidanceInset(UIEdgeInsets insets) {
    CGFloat horizontal = MAX(insets.left, insets.right);
    CGFloat vertical = MAX(insets.top, insets.bottom);
    CGFloat measured = horizontal >= 24.0 ? horizontal : vertical;
    if (horizontal < 24.0 && vertical < 30.0) {
        // SpringBoard can retain portrait/zero safe-area values after a Scene
        // handoff. Keep a conservative side inset so the arc cannot slide under
        // a notch even when the physical orientation notification is stale.
        measured = 47.0;
    }
    return MIN(76.0, MAX(12.0, measured + 4.0));
}

static NSString *FLMIdentifierForApplication(id application) {
    if ([application respondsToSelector:@selector(bundleIdentifier)]) {
        NSString *identifier = [application bundleIdentifier];
        if (identifier.length > 0) {
            return identifier;
        }
    }
    if ([application respondsToSelector:@selector(displayIdentifier)]) {
        NSString *identifier = [application displayIdentifier];
        if (identifier.length > 0) {
            return identifier;
        }
    }
    return nil;
}

static NSString *FLMFrontmostApplicationIdentifier(void) {
    id workspaceClass = NSClassFromString(@"SBMainWorkspace");
    id workspace =
        [workspaceClass respondsToSelector:@selector(sharedInstance)]
            ? [workspaceClass sharedInstance]
            : nil;
    if ([workspace respondsToSelector:@selector(frontmostApplication)]) {
        NSString *identifier =
            FLMIdentifierForApplication([workspace frontmostApplication]);
        if (identifier.length > 0) {
            return identifier;
        }
    }
    UIApplication *springBoard = [UIApplication sharedApplication];
    if ([springBoard respondsToSelector:
                         @selector(_accessibilityFrontMostApplication)]) {
        return FLMIdentifierForApplication(
            [springBoard _accessibilityFrontMostApplication]);
    }
    return nil;
}

static BOOL FLMPrewarmApplicationIdentifier(NSString *identifier) {
    if (identifier.length == 0 ||
        [identifier isEqualToString:FLYME_LOCK_SCREEN_ITEM]) {
        return NO;
    }
    UIApplication *application = [UIApplication sharedApplication];
    if (![application respondsToSelector:
                         @selector(launchApplicationWithIdentifier:suspended:)]) {
        return NO;
    }
    return [application launchApplicationWithIdentifier:identifier
                                               suspended:YES];
}

static CGFloat FLMClampedCornerTriggerSize(CGFloat value) {
    if (!isfinite(value)) {
        return FLMDefaultCornerTriggerSize;
    }
    return MAX(FLMMinimumCornerTriggerSize,
               MIN(FLMMaximumCornerTriggerSize, value));
}

static BOOL FLMPointInsideCornerTrigger(CGPoint point,
                                        CGRect bounds,
                                        BOOL *fromRight) {
    // Keep the original 58x65 quarter-ellipse at the default. The setting
    // scales both axes together while preserving that exact aspect ratio.
    CGFloat horizontalRadius =
        FLMClampedCornerTriggerSize(FLMCornerTriggerSize);
    CGFloat verticalRadius = horizontalRadius * (65.0 / 58.0);
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    CGFloat bottomDistance = height - point.y;
    if (point.x < 0.0 || point.x > width ||
        bottomDistance < 0.0 || bottomDistance > verticalRadius) {
        return NO;
    }

    CGFloat verticalComponent = bottomDistance / verticalRadius;
    CGFloat leftComponent = point.x / horizontalRadius;
    CGFloat rightComponent = (width - point.x) / horizontalRadius;
    BOOL insideLeft =
        leftComponent * leftComponent +
            verticalComponent * verticalComponent <=
        1.0;
    BOOL insideRight =
        rightComponent * rightComponent +
            verticalComponent * verticalComponent <=
        1.0;
    if (fromRight) {
        *fromRight = insideRight && !insideLeft;
    }
    return insideLeft || insideRight;
}

@interface FLMOverlayViewController : UIViewController
@end

@implementation FLMOverlayViewController

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

@end

@interface FLMOverlayWindow : UIWindow
@end

@implementation FLMOverlayWindow

- (BOOL)canBecomeKeyWindow {
    return NO;
}

@end

// A system-manager recognizer can observe a touch without becoming the owner
// of the remote Scene's touch stream.  This transparent, display-level window
// is the ownership boundary for docked/hidden card touches.  It only
// hit-tests the card or hidden handle; all other points still pass through.
@interface FLMDockTouchGateWindow : FLMOverlayWindow
@property(nonatomic, assign) BOOL dockTouchGateEnabled;
@property(nonatomic, assign) BOOL wheelPriorityActive;
@property(nonatomic, assign) CGRect visualBounds;
@property(nonatomic, assign) UIInterfaceOrientation visualOrientation;
@property(nonatomic, assign) CGRect dockCardFrame;
@property(nonatomic, assign) CGRect dockHandleFrame;
@property(nonatomic, assign) CGRect dockResizeFrame;
@end

@implementation FLMDockTouchGateWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.dockTouchGateEnabled || FLMDeviceIsLocked()) {
        return nil;
    }
    CGRect visualBounds = CGRectIsEmpty(self.visualBounds)
                              ? FLMVisualScreenBounds()
                              : self.visualBounds;
    UIView *rootView = self.rootViewController.view;
    CGPoint visualPoint = FLMVisualPointFromRootPoint(
        point, rootView.bounds, visualBounds, self.visualOrientation);
    if (self.wheelPriorityActive &&
        FLMPointInsideCornerTrigger(visualPoint, visualBounds, NULL)) {
        UITouch *touch = [event.allTouches anyObject];
        if (touch && touch.phase == UITouchPhaseBegan) {
            FLMDiagnosticLog(
                @"sb dock-input-gate owner=wheel point={%.1f,%.1f} touch=%p",
                visualPoint.x, visualPoint.y, (__bridge void *)touch);
        }
        return nil;
    }
    BOOL insideCard = !CGRectIsNull(self.dockCardFrame) &&
                      !CGRectIsEmpty(self.dockCardFrame) &&
                      CGRectContainsPoint(CGRectInset(self.dockCardFrame, -3.0, -3.0),
                                          visualPoint);
    BOOL insideHandle = !CGRectIsNull(self.dockHandleFrame) &&
                        !CGRectIsEmpty(self.dockHandleFrame) &&
                        CGRectContainsPoint(CGRectInset(self.dockHandleFrame,
                                                        -18.0,
                                                        -18.0),
                                            visualPoint);
    BOOL insideResize = !CGRectIsNull(self.dockResizeFrame) &&
                        !CGRectIsEmpty(self.dockResizeFrame) &&
                        CGRectContainsPoint(CGRectInset(self.dockResizeFrame,
                                                        -10.0,
                                                        -10.0),
                                            visualPoint);
    if (!insideCard && !insideHandle && !insideResize) {
        return nil;
    }
    UITouch *touch = [event.allTouches anyObject];
    if (touch && touch.phase == UITouchPhaseBegan) {
        FLMDiagnosticLog(
            @"sb dock-input-gate owner=dock card=%d handle=%d resize=%d point={%.1f,%.1f} touch=%p",
            insideCard, insideHandle, insideResize, visualPoint.x, visualPoint.y,
            (__bridge void *)touch);
    }
    return rootView;
}

@end

// The remote keyboard host must live in a full-display window that belongs to
// SpringBoard's active UIWindowScene. The remote host needs a key event window
// for third-party keyboard-extension buttons to complete their UIKit actions.
// Empty root space still returns nil so card and backdrop touches fall through.
@interface FLMKeyboardForwardingWindow : UIWindow
@property(nonatomic, assign) CGRect keyboardInteractionFrame;
@end

@implementation FLMKeyboardForwardingWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // `keyboardInteractionFrame` is measured in the physical display space the
    // keyboard canvas renders in, while `point` arrives in this window's scene
    // space. Bridge them through the screen coordinate space instead of
    // comparing two different spaces.
    CGRect visualBounds = FLMVisualScreenBounds();
    CGPoint visualPoint = point;
    if (FLMBoundsAreLandscape(visualBounds)) {
        UIScreen *screen = self.screen ?: [UIScreen mainScreen];
        id<UICoordinateSpace> screenSpace =
            screen ? screen.coordinateSpace : nil;
        if (screenSpace) {
            visualPoint =
                [self convertPoint:point toCoordinateSpace:screenSpace];
        }
    }
    if (CGRectIsNull(self.keyboardInteractionFrame) ||
        !CGRectContainsPoint(self.keyboardInteractionFrame, visualPoint)) {
        return nil;
    }
    UIView *hitView = [super hitTest:point withEvent:event];
    UIView *rootView = self.rootViewController.view;
    if (hitView == self || hitView == rootView) {
        return nil;
    }
    return hitView;
}

@end

@interface FLMFloatingWindow : FLMOverlayWindow
@property(nonatomic, assign) CGRect visualBounds;
@property(nonatomic, assign) UIInterfaceOrientation visualOrientation;
@property(nonatomic, assign) BOOL passesTouchesOutsideFloatingContent;
@property(nonatomic, assign) BOOL suppressesCornerRoutingDuringDockGesture;
@property(nonatomic, assign) CGRect keyboardPassThroughFrame;
@property(nonatomic, weak) UIView *floatingContentView;
@property(nonatomic, weak) UIView *floatingPrimaryControlView;
@property(nonatomic, weak) UIView *floatingSecondaryControlView;
@end

static void FLMLogFloatingHitTest(FLMFloatingWindow *window,
                                  CGPoint point,
                                  UIEvent *event,
                                  UIView *hitView,
                                  NSString *route) {
    UITouch *touch = [event.allTouches anyObject];
    FLMDiagnosticLog(
        @"sb touch-hit touch=%p timestamp=%.6f phase=%ld route=%@ point={%.1f,%.1f} hit=%@ hitPtr=%p key=%d keyboardPass=%@ card=%@ handle=%@",
        (__bridge void *)touch, touch ? touch.timestamp : 0.0,
        (long)(touch ? touch.phase : UITouchPhaseCancelled),
        route ?: @"<none>", point.x, point.y,
        hitView ? NSStringFromClass([hitView class]) : @"<nil>",
        (__bridge void *)hitView, window.isKeyWindow,
        NSStringFromCGRect(window.keyboardPassThroughFrame),
        NSStringFromCGRect(window.floatingContentView.frame),
        NSStringFromCGRect(window.floatingPrimaryControlView.frame));
}

@implementation FLMFloatingWindow

- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect visualBounds = CGRectIsEmpty(self.visualBounds)
                              ? FLMVisualScreenBounds()
                              : self.visualBounds;
    UIView *rootView = self.rootViewController.view;
    CGPoint visualPoint = FLMVisualPointFromRootPoint(
        point, rootView.bounds, visualBounds, self.visualOrientation);

    // A remote scene can retain an oversized hit-test view for one layout
    // transaction after it is reattached. Always give the centered handle
    // first refusal: it owns the only gestures that leave centered mode.
    UIView *primaryControl = self.floatingPrimaryControlView;
    if (primaryControl && !primaryControl.hidden &&
        primaryControl.userInteractionEnabled && primaryControl.alpha > 0.01) {
        CGPoint primaryPoint = [self convertPoint:point toView:primaryControl];
        UIView *primaryHit = [primaryControl hitTest:primaryPoint withEvent:event];
        if (primaryHit) {
            FLMLogFloatingHitTest(self, point, event, primaryHit, @"handle");
            return primaryHit;
        }
    }
    if (self.suppressesCornerRoutingDuringDockGesture) {
        UIView *hitView = [super hitTest:point withEvent:event];
        return hitView ?: rootView;
    }
    if (!CGRectIsNull(self.keyboardPassThroughFrame) &&
        CGRectContainsPoint(self.keyboardPassThroughFrame, visualPoint)) {
        FLMLogFloatingHitTest(self, point, event, nil, @"keyboard-pass");
        return nil;
    }
    if (self.passesTouchesOutsideFloatingContent) {
        BOOL insideContent = NO;
        if (self.floatingContentView) {
            CGPoint local = [self convertPoint:point toView:self.floatingContentView];
            insideContent =
                CGRectContainsPoint(CGRectInset(self.floatingContentView.bounds,
                                                -2.0, -2.0),
                                    local);
        }
        BOOL insidePrimaryControl = NO;
        if (self.floatingPrimaryControlView &&
            !self.floatingPrimaryControlView.hidden) {
            CGPoint local =
                [self convertPoint:point toView:self.floatingPrimaryControlView];
            insidePrimaryControl =
                CGRectContainsPoint(CGRectInset(
                                        self.floatingPrimaryControlView.bounds,
                                        -6.0, -6.0),
                                    local);
        }
        BOOL insideSecondaryControl = NO;
        if (self.floatingSecondaryControlView &&
            !self.floatingSecondaryControlView.hidden) {
            CGPoint local =
                [self convertPoint:point toView:self.floatingSecondaryControlView];
            insideSecondaryControl =
                CGRectContainsPoint(CGRectInset(
                                        self.floatingSecondaryControlView.bounds,
                                        -12.0, -12.0),
                                    local);
        }
        if (!insideContent && !insidePrimaryControl && !insideSecondaryControl) {
            if (FLMPointInsideCornerTrigger(visualPoint, visualBounds, NULL)) {
                FLMLogFloatingHitTest(self, point, event, nil, @"wheel-corner");
                UIView *hitView = [super hitTest:point withEvent:event];
                return hitView ?: rootView;
            }
            FLMLogFloatingHitTest(self, point, event, nil, @"docked-pass");
            return nil;
        }
    }
    UIView *hitView = [super hitTest:point withEvent:event];
    BOOL insideCard = NO;
    if (self.floatingContentView) {
        CGPoint local = [self convertPoint:point toView:self.floatingContentView];
        insideCard = CGRectContainsPoint(self.floatingContentView.bounds, local);
    }
    FLMLogFloatingHitTest(self, point, event, hitView,
                          insideCard ? @"card" : @"backdrop");
    return hitView;
}

@end

@interface FLMHotspotWindow : UIWindow
@property(nonatomic, assign) BOOL hotspotsEnabled;
@property(nonatomic, assign) CGRect visualBounds;
@property(nonatomic, assign) UIInterfaceOrientation visualOrientation;
@end

@implementation FLMHotspotWindow

- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.hotspotsEnabled) {
        return nil;
    }
    CGRect visualBounds = CGRectIsEmpty(self.visualBounds)
                              ? FLMVisualScreenBounds()
                              : self.visualBounds;
    UIView *rootView = self.rootViewController.view;
    CGPoint visualPoint = FLMVisualPointFromRootPoint(
        point, rootView.bounds, visualBounds, self.visualOrientation);
    if (!FLMPointInsideCornerTrigger(visualPoint, visualBounds, NULL)) {
        return nil;
    }
    return [super hitTest:point withEvent:event];
}

@end

@class FLMWheelController;

static BOOL FLMHomeDockZoneHitTest(CGRect bounds, CGPoint point);

// Full-screen transparent window that owns the bottom-center home-indicator
// zone while a plain application is frontmost. Its recognizer runs UIKit's
// normal in-window arbitration, so once the long-press begins, the system
// gesture manager gate fails the real home gesture and the app switcher never
// opens. Every gate (card visible, wheel pinned, locked, home screen) is
// re-evaluated per touch in the hit-test, so the window never swallows input
// it should not own.
@interface FLMHomeDockWindow : UIWindow
@end

@implementation FLMHomeDockWindow

- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // The window itself is on SpringBoard's portrait scene bounds, so the
    // home-indicator zone has to be tested in the physical display space the
    // user actually sees. Convert through the screen coordinate space the same
    // way the presentation canvases are placed, instead of assuming the window
    // and the display share an origin.
    CGRect visualBounds = FLMVisualScreenBounds();
    CGPoint visualPoint = point;
    if (FLMBoundsAreLandscape(visualBounds)) {
        UIScreen *screen = self.screen ?: [UIScreen mainScreen];
        id<UICoordinateSpace> screenSpace =
            screen ? screen.coordinateSpace : nil;
        if (screenSpace) {
            visualPoint =
                [self convertPoint:point toCoordinateSpace:screenSpace];
        }
    }
    if (!FLMHomeDockZoneHitTest(visualBounds, visualPoint)) {
        return nil;
    }
    return [super hitTest:point withEvent:event];
}

@end

@interface FLMCornerGestureRecognizer : UILongPressGestureRecognizer
@property(nonatomic, assign) NSTimeInterval flmFirstTouchTimestamp;
@property(nonatomic, assign) CGPoint flmFirstTouchPoint;
@property(nonatomic, assign) BOOL flmHasFirstTouchPoint;
@property(nonatomic, assign) CGPoint flmFirstRawPoint;
@property(nonatomic, assign) BOOL flmHasFirstRawPoint;
@property(nonatomic, assign)
    FLMLandscapeRawCoordinateMode flmLandscapeRawCoordinateMode;
@property(nonatomic, assign) BOOL flmOutsideCloseAuthorized;
@property(nonatomic, assign) CGPoint flmAuthorizedStartPoint;
@end

@implementation FLMCornerGestureRecognizer

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *firstTouch = [touches anyObject];
    if (firstTouch && !self.flmHasFirstRawPoint) {
        self.flmFirstRawPoint = [firstTouch locationInView:nil];
        self.flmHasFirstRawPoint = YES;
    }
    if (firstTouch && self.flmFirstTouchTimestamp <= 0.0) {
        self.flmFirstTouchTimestamp = firstTouch.timestamp;
        // _UISystemGestureManager does not consistently ask the delegate's
        // shouldReceiveTouch: in landscape. Capture the raw display-space
        // ingress here so shouldBegin never depends on that optional callback.
        CGPoint firstPoint =
            FLMVisualPointFromRawPoint([firstTouch locationInView:nil]);
        UIWindow *touchWindow = firstTouch.view.window;
        if ([touchWindow isKindOfClass:[FLMHotspotWindow class]]) {
            FLMHotspotWindow *window = (FLMHotspotWindow *)touchWindow;
            UIView *root = window.rootViewController.view;
            firstPoint = FLMVisualPointFromRootPoint(
                [firstTouch locationInView:root], root.bounds,
                CGRectIsEmpty(window.visualBounds)
                    ? FLMVisualScreenBounds()
                    : window.visualBounds,
                window.visualOrientation);
        } else if ([touchWindow isKindOfClass:[FLMFloatingWindow class]]) {
            FLMFloatingWindow *window = (FLMFloatingWindow *)touchWindow;
            UIView *root = window.rootViewController.view;
            firstPoint = FLMVisualPointFromRootPoint(
                [firstTouch locationInView:root], root.bounds,
                CGRectIsEmpty(window.visualBounds)
                    ? FLMVisualScreenBounds()
                    : window.visualBounds,
                window.visualOrientation);
        } else if ([touchWindow isKindOfClass:[FLMDockTouchGateWindow class]]) {
            FLMDockTouchGateWindow *window =
                (FLMDockTouchGateWindow *)touchWindow;
            UIView *root = window.rootViewController.view;
            firstPoint = FLMVisualPointFromRootPoint(
                [firstTouch locationInView:root], root.bounds,
                CGRectIsEmpty(window.visualBounds)
                    ? FLMVisualScreenBounds()
                    : window.visualBounds,
                window.visualOrientation);
        }
        self.flmFirstTouchPoint = firstPoint;
        self.flmHasFirstTouchPoint = YES;
    }
    [super touchesBegan:touches withEvent:event];
}

- (void)reset {
    [super reset];
    self.flmFirstTouchTimestamp = 0.0;
    self.flmFirstTouchPoint = CGPointZero;
    self.flmHasFirstTouchPoint = NO;
    self.flmFirstRawPoint = CGPointZero;
    self.flmHasFirstRawPoint = NO;
    self.flmLandscapeRawCoordinateMode =
        FLMLandscapeRawCoordinateModeUnknown;
    self.flmOutsideCloseAuthorized = NO;
    self.flmAuthorizedStartPoint = CGPointZero;
}

- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)preventingGestureRecognizer {
    (void)preventingGestureRecognizer;
    return NO;
}

- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)preventedGestureRecognizer {
    (void)preventedGestureRecognizer;
    return YES;
}

- (BOOL)shouldBeRequiredToFailByGestureRecognizer:
    (UIGestureRecognizer *)otherGestureRecognizer {
    (void)otherGestureRecognizer;
    return NO;
}

- (BOOL)shouldRequireFailureOfGestureRecognizer:
    (UIGestureRecognizer *)otherGestureRecognizer {
    (void)otherGestureRecognizer;
    return NO;
}

@end

// Intercepts the home-indicator up-swipe in the bottom-center zone. The system
// home gesture needs motion, so a stationary press always beats it: after
// flmPressDuration with less than flmMovementTolerance of travel the recognizer
// begins (and prevents the home gesture from opening the app switcher), then a
// subsequent upward drag past flmSwipeThreshold docks the frontmost app. A
// regular quick or slow swipe moves more than the tolerance before the press
// elapses and fails itself, leaving the system home gesture untouched.
@interface FLMDockGestureRecognizer : UIGestureRecognizer
@property(nonatomic, assign) NSTimeInterval flmPressDuration;
@property(nonatomic, assign) CGFloat flmMovementTolerance;
@property(nonatomic, assign) CGFloat flmSwipeThreshold;
@property(nonatomic, assign, readonly) BOOL flmLongPressConfirmed;
@property(nonatomic, assign, readonly) BOOL flmTriggered;
@end

@interface FLMDockGestureRecognizer () {
    NSTimeInterval _flmFirstTouchTimestamp;
    CGPoint _flmPressStartPoint;
    NSUInteger _flmPressToken;
}
@end

@implementation FLMDockGestureRecognizer

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    self = [super initWithTarget:target action:action];
    if (self) {
        _flmPressDuration = 0.25;
        _flmMovementTolerance = 8.0;
        _flmSwipeThreshold = 40.0;
    }
    return self;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    if (self.state != UIGestureRecognizerStatePossible) {
        return;
    }
    UITouch *firstTouch = [touches anyObject];
    if (!firstTouch) {
        return;
    }
    _flmFirstTouchTimestamp = firstTouch.timestamp;
    _flmPressStartPoint = [firstTouch locationInView:nil];
    _flmLongPressConfirmed = NO;
    _flmTriggered = NO;
    _flmPressToken += 1;
    NSUInteger token = _flmPressToken;
    __weak FLMDockGestureRecognizer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(self.flmPressDuration *
                                           NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FLMDockGestureRecognizer *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_flmPressToken != token ||
            strongSelf.state != UIGestureRecognizerStatePossible) {
            return;
        }
        strongSelf->_flmLongPressConfirmed = YES;
        strongSelf.state = UIGestureRecognizerStateBegan;
    });
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    UITouch *firstTouch = [touches anyObject];
    if (!firstTouch) {
        return;
    }
    CGPoint location = [firstTouch locationInView:nil];
    if (self.state == UIGestureRecognizerStatePossible) {
        CGFloat movement =
            hypot(location.x - _flmPressStartPoint.x,
                  location.y - _flmPressStartPoint.y);
        if (movement >= self.flmMovementTolerance) {
            _flmPressToken += 1;
            self.state = UIGestureRecognizerStateFailed;
        }
        return;
    }
    if (self.state == UIGestureRecognizerStateBegan ||
        self.state == UIGestureRecognizerStateChanged) {
        CGFloat upward = _flmPressStartPoint.y - location.y;
        if (_flmTriggered && upward >= self.flmSwipeThreshold) {
            self.state = UIGestureRecognizerStateChanged;
        } else if (!_flmTriggered && upward >= self.flmSwipeThreshold) {
            _flmTriggered = YES;
            self.state = UIGestureRecognizerStateChanged;
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    if (self.state == UIGestureRecognizerStatePossible) {
        _flmPressToken += 1;
        self.state = UIGestureRecognizerStateFailed;
    } else if (self.state == UIGestureRecognizerStateBegan ||
               self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateEnded;
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    if (self.state == UIGestureRecognizerStatePossible) {
        _flmPressToken += 1;
        self.state = UIGestureRecognizerStateFailed;
    }
}

- (void)reset {
    [super reset];
    _flmPressToken += 1;
    _flmFirstTouchTimestamp = 0.0;
    _flmPressStartPoint = CGPointZero;
    _flmLongPressConfirmed = NO;
    _flmTriggered = NO;
}

- (BOOL)canBePreventedByGestureRecognizer:
    (UIGestureRecognizer *)preventingGestureRecognizer {
    (void)preventingGestureRecognizer;
    return NO;
}

- (BOOL)canPreventGestureRecognizer:
    (UIGestureRecognizer *)preventedGestureRecognizer {
    (void)preventedGestureRecognizer;
    return YES;
}

- (BOOL)shouldBeRequiredToFailByGestureRecognizer:
    (UIGestureRecognizer *)otherGestureRecognizer {
    (void)otherGestureRecognizer;
    return NO;
}

- (BOOL)shouldRequireFailureOfGestureRecognizer:
    (UIGestureRecognizer *)otherGestureRecognizer {
    (void)otherGestureRecognizer;
    return NO;
}

@end

@interface FLMOutsideTapGestureRecognizer : UIGestureRecognizer
@property(nonatomic, weak) UIView *protectedView;
@property(nonatomic, weak) UIView *secondaryProtectedView;
@property(nonatomic, assign) CGRect additionalProtectedFrame;
@property(nonatomic, strong) NSMutableDictionary<NSValue *, NSValue *> *startPoints;
@property(nonatomic, assign) NSTimeInterval firstTouchTimestamp;
@property(nonatomic, assign) BOOL outsideCloseAuthorized;
@property(nonatomic, assign) NSUInteger touchSequence;
@end

@implementation FLMOutsideTapGestureRecognizer

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    self = [super initWithTarget:target action:action];
    if (self) {
        _startPoints = [NSMutableDictionary dictionary];
        _additionalProtectedFrame = CGRectNull;
        self.cancelsTouchesInView = NO;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
    }
    return self;
}

- (NSValue *)keyForTouch:(UITouch *)touch {
    return [NSValue valueWithNonretainedObject:touch];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    static NSUInteger nextTouchSequence = 0;
    self.touchSequence = ++nextTouchSequence;
    self.outsideCloseAuthorized = NO;
    if (self.startPoints.count + touches.count > 1) {
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    if (self.firstTouchTimestamp <= 0.0) {
        UITouch *firstTouch = [touches anyObject];
        self.firstTouchTimestamp = firstTouch.timestamp;
    }
    for (UITouch *touch in touches) {
        CGPoint point = [touch locationInView:self.view];
        BOOL inCard = NO;
        if (self.protectedView) {
            CGPoint protectedPoint = [touch locationInView:self.protectedView];
            inCard = CGRectContainsPoint(self.protectedView.bounds,
                                         protectedPoint);
        }
        BOOL inHandle = NO;
        if (self.secondaryProtectedView) {
            CGPoint handlePoint =
                [touch locationInView:self.secondaryProtectedView];
            inHandle = CGRectContainsPoint(
                self.secondaryProtectedView.bounds, handlePoint);
        }
        BOOL inKeyboard = !CGRectIsNull(self.additionalProtectedFrame) &&
                          CGRectContainsPoint(self.additionalProtectedFrame,
                                              point);
        FLMDiagnosticLog(
            @"sb touch-backdrop-began sequence=%lu touch=%p timestamp=%.6f point={%.1f,%.1f} inCard=%d inHandle=%d inKeyboard=%d keyboardFrame=%@",
            (unsigned long)self.touchSequence, (__bridge void *)touch,
            touch.timestamp, point.x, point.y, inCard, inHandle, inKeyboard,
            NSStringFromCGRect(self.additionalProtectedFrame));
        if (inCard) {
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
        if (inHandle) {
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
        if (inKeyboard) {
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
        self.startPoints[[self keyForTouch:touch]] = [NSValue valueWithCGPoint:point];
    }
    self.outsideCloseAuthorized = self.startPoints.count == 1;
    FLMDiagnosticLog(
        @"sb touch-backdrop-authorized sequence=%lu authorized=%d",
        (unsigned long)self.touchSequence, self.outsideCloseAuthorized);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for (UITouch *touch in touches) {
        NSValue *startValue = self.startPoints[[self keyForTouch:touch]];
        if (!startValue) {
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
        CGPoint start = startValue.CGPointValue;
        CGPoint current = [touch locationInView:self.view];
        if (hypot(current.x - start.x, current.y - start.y) > 12.0) {
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    NSTimeInterval lastTimestamp = self.firstTouchTimestamp;
    for (UITouch *touch in touches) {
        lastTimestamp = MAX(lastTimestamp, touch.timestamp);
        [self.startPoints removeObjectForKey:[self keyForTouch:touch]];
    }
    if (self.startPoints.count != 0) {
        return;
    }
    self.state =
        lastTimestamp - self.firstTouchTimestamp <= 0.35
            ? UIGestureRecognizerStateRecognized
            : UIGestureRecognizerStateFailed;
    FLMDiagnosticLog(
        @"sb touch-backdrop-ended sequence=%lu authorized=%d duration=%.4f state=%ld",
        (unsigned long)self.touchSequence, self.outsideCloseAuthorized,
        lastTimestamp - self.firstTouchTimestamp, (long)self.state);
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    self.state = UIGestureRecognizerStateCancelled;
}

- (void)reset {
    [super reset];
    [self.startPoints removeAllObjects];
    self.firstTouchTimestamp = 0.0;
    self.outsideCloseAuthorized = NO;
    self.touchSequence = 0;
}

- (BOOL)canBePreventedByGestureRecognizer:
    (UIGestureRecognizer *)preventingGestureRecognizer {
    (void)preventingGestureRecognizer;
    return NO;
}

@end

static void FLMBeginWheelRefreshLease(NSTimeInterval duration) {
    Class controllerClass = NSClassFromString(@"FLMWheelController");
    SEL sharedSelector = NSSelectorFromString(@"sharedController");
    if (!controllerClass || ![controllerClass respondsToSelector:sharedSelector]) {
        return;
    }
    id controller =
        ((id (*)(id, SEL))objc_msgSend)(controllerClass, sharedSelector);
    SEL leaseSelector =
        NSSelectorFromString(@"beginFloatingHighRefreshLeaseForDuration:");
    if (!controller || ![controller respondsToSelector:leaseSelector]) {
        return;
    }
    ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(
        controller, leaseSelector, duration);
}

@interface FLMWheelItemView : UIView
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, assign) BOOL highlighted;
@end

@implementation FLMWheelItemView

- (instancetype)initWithIdentifier:(NSString *)identifier
                             image:(UIImage *)image
                              size:(CGFloat)size {
    self = [super initWithFrame:CGRectMake(0.0, 0.0, size, size)];
    if (self) {
        _identifier = [identifier copy];
        BOOL isLockItem = [identifier isEqualToString:FLYME_LOCK_SCREEN_ITEM];
        BOOL isBuiltInAction = isLockItem;
        self.backgroundColor = isLockItem ? [UIColor systemBlueColor]
                                          : [UIColor clearColor];
        self.layer.cornerRadius = size * 0.5;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.22;
        self.layer.shadowRadius = 8.0;
        self.layer.shadowOffset = CGSizeMake(0.0, 3.0);
        self.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:self.bounds].CGPath;

        _iconView = [[UIImageView alloc] initWithImage:image];
        CGFloat lockInset = size * (15.0 / FLMDefaultWheelIconSize);
        _iconView.frame =
            isBuiltInAction ? CGRectInset(self.bounds, lockInset, lockInset)
                            : self.bounds;
        _iconView.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _iconView.contentMode =
            isBuiltInAction ? UIViewContentModeScaleAspectFit
                            : UIViewContentModeScaleAspectFill;
        _iconView.clipsToBounds = YES;
        _iconView.layer.cornerRadius = isBuiltInAction ? 0.0 : size * 0.5;
        [self addSubview:_iconView];
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    if (_highlighted == highlighted) {
        return;
    }
    _highlighted = highlighted;
    FLMBeginWheelRefreshLease(0.28);
    CGFloat scale = highlighted ? 1.24 : 1.0;
    self.layer.shadowOpacity = highlighted ? 0.32 : 0.18;
    [UIView animateWithDuration:0.28
                          delay:0.0
         usingSpringWithDamping:0.64
          initialSpringVelocity:0.45
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         self.transform = CGAffineTransformMakeScale(scale, scale);
                     }
                     completion:nil];
}

@end

@interface FLMWheelController : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, strong) FLMOverlayWindow *overlayWindow;
@property(nonatomic, strong) UIView *wheelContainer;
@property(nonatomic, strong) FLMHotspotWindow *hotspotWindow;
@property(nonatomic, strong) FLMHomeDockWindow *homeDockWindow;
@property(nonatomic, strong) FLMOverlayWindow *floatingWindow;
@property(nonatomic, strong) FLMDockTouchGateWindow *floatingDockTouchGateWindow;
@property(nonatomic, strong) UIView *floatingPresentationView;
@property(nonatomic, strong) UIView *floatingDimView;
@property(nonatomic, strong) UIView *floatingDockShadowView;
@property(nonatomic, strong) UIView *floatingContainer;
@property(nonatomic, strong) UIView *floatingDockInteractionShield;
@property(nonatomic, strong) UIView *floatingHandle;
@property(nonatomic, strong) UIView *floatingHandleBar;
// Transparent hit target for dock resizing.  The old L-shaped layer was only
// a visual affordance; the resize gesture itself remains active without it.
@property(nonatomic, strong) UIView *floatingResizeHandle;
@property(nonatomic, strong) UIView *floatingHostView;
@property(nonatomic, strong) UILabel *floatingStatusLabel;
@property(nonatomic, strong) UIView *floatingLaunchCoverView;
@property(nonatomic, strong) UIImageView *floatingLaunchIconView;
@property(nonatomic, strong) FLMOutsideTapGestureRecognizer *floatingBackdropTap;
@property(nonatomic, strong) UILongPressGestureRecognizer *floatingHandlePress;
@property(nonatomic, strong) UITapGestureRecognizer *floatingHandleTap;
@property(nonatomic, strong) UITapGestureRecognizer *floatingDockTap;
@property(nonatomic, strong) UILongPressGestureRecognizer *floatingDockDragPress;
@property(nonatomic, strong) FLMCornerGestureRecognizer *floatingExclusiveGesture;
@property(nonatomic, strong) FLMCornerGestureRecognizer *floatingDockInputGesture;
@property(nonatomic, weak) UIWindow *previousKeyWindow;
@property(nonatomic, strong) FLMCornerGestureRecognizer *cornerGuardGesture;
@property(nonatomic, strong) FLMCornerGestureRecognizer *cornerGesture;
// Dedicated in-window landscape ingress. The private system gesture manager
// may report successful registration while skipping touch-delegate delivery
// after rotation; these recognizers remain attached to a SpringBoard window
// and are enabled only for the physical landscape trigger path.
@property(nonatomic, strong) FLMCornerGestureRecognizer *landscapeCornerGuardGesture;
@property(nonatomic, strong) FLMCornerGestureRecognizer *landscapeCornerGesture;
@property(nonatomic, strong) FLMCornerGestureRecognizer *landscapeGlobalCornerGuardGesture;
@property(nonatomic, strong) FLMCornerGestureRecognizer *landscapeGlobalCornerGesture;
@property(nonatomic, assign) BOOL landscapeIngressActive;
@property(nonatomic, assign) CGRect landscapeIngressBounds;
@property(nonatomic, assign)
    FLMLandscapeRawCoordinateMode landscapeIngressRawMode;
@property(nonatomic, assign) BOOL landscapeDirectWheelTaps;
@property(nonatomic, strong) FLMCornerGestureRecognizer *floatingCornerGuardGesture;
@property(nonatomic, strong) FLMCornerGestureRecognizer *floatingCornerGesture;
@property(nonatomic, strong) FLMCornerGestureRecognizer *modalGesture;
@property(nonatomic, strong) UITapGestureRecognizer *wheelTapGesture;
@property(nonatomic, strong) id systemGestureManager;
@property(nonatomic, strong) id displayIdentity;
@property(nonatomic, strong) NSArray<FLMWheelItemView *> *itemViews;
// Item centres as measured in the physical display space. The landscape route
// stores them here so the container-local `center` can be re-derived whenever
// the wheel window or its root view changes layout, instead of assuming the
// container's own coordinate space already equals the display space.
@property(nonatomic, strong) NSArray<NSValue *> *landscapeWheelVisualCenters;
@property(nonatomic, copy) NSArray<NSString *> *itemIdentifiers;
@property(nonatomic, weak) FLMWheelItemView *highlightedItem;
@property(nonatomic, assign) BOOL enabled;
@property(nonatomic, assign) BOOL presentingFromRight;
@property(nonatomic, assign) BOOL usesSystemGestureManager;
@property(nonatomic, assign) BOOL wheelPinned;
@property(nonatomic, assign) BOOL wheelGestureActive;
@property(nonatomic, assign) CGFloat wheelRadius;
@property(nonatomic, assign) CGFloat wheelIconSize;
@property(nonatomic, assign) CGFloat centeredCardWidth;
@property(nonatomic, assign) CGFloat centeredCardTopCrop;
@property(nonatomic, assign) CGFloat centeredCardBottomCrop;
@property(nonatomic, assign) CGFloat centeredDockSwipeThreshold;
@property(nonatomic, assign) CGFloat dockedShrinkAmount;
@property(nonatomic, assign) BOOL floatingLandscapeSession;
@property(nonatomic, assign) UIInterfaceOrientation floatingLandscapeInterfaceOrientation;
@property(nonatomic, assign) CGSize floatingLandscapeSystemSize;
@property(nonatomic, assign) UIEdgeInsets floatingLandscapeSafeInsets;
@property(nonatomic, assign) CGPoint floatingHandleStartPoint;
@property(nonatomic, assign) CGRect floatingHandleInitialContainerFrame;
@property(nonatomic, assign) BOOL floatingHandleMoved;
@property(nonatomic, assign) BOOL floatingDocked;
@property(nonatomic, assign) BOOL floatingDockedOnRight;
@property(nonatomic, assign) BOOL floatingDockHidden;
@property(nonatomic, assign) BOOL floatingDockHideGestureActive;
@property(nonatomic, assign) BOOL floatingDockHideReady;
@property(nonatomic, assign) CGPoint floatingDockHideStartPoint;
@property(nonatomic, assign) CGRect floatingDockHideInitialFrame;
@property(nonatomic, assign) CGRect floatingDockHideInitialHandleFrame;
@property(nonatomic, assign) CGPoint floatingHiddenBarDragStartPoint;
@property(nonatomic, assign) CGRect floatingHiddenBarDragInitialFrame;
@property(nonatomic, assign) BOOL floatingDockTransitionActive;
@property(nonatomic, assign) BOOL floatingDockControlArmed;
@property(nonatomic, assign) BOOL floatingDockEntrySettleActive;
@property(nonatomic, assign) CGRect floatingDockEntryTargetFrame;
@property(nonatomic, assign) CGRect floatingDockTouchCaptureFrame;
@property(nonatomic, assign) NSUInteger floatingDockEntrySettleGeneration;
@property(nonatomic, assign) BOOL floatingDockEntryControlTouchPending;
@property(nonatomic, assign) CGFloat floatingDockWidth;
@property(nonatomic, assign) CGFloat floatingDockVerticalCenter;
@property(nonatomic, assign) CGPoint floatingDockDragStartPoint;
@property(nonatomic, assign) CGPoint floatingDockDragInitialCenter;
@property(nonatomic, assign) CGPoint floatingResizeStartPoint;
@property(nonatomic, assign) CGRect floatingResizeInitialFrame;
@property(nonatomic, assign) CGPoint floatingDockInputLatestPoint;
@property(nonatomic, assign) CGPoint floatingDockInputFramePoint;
@property(nonatomic, assign) BOOL floatingDockInputTargetsResize;
@property(nonatomic, assign) BOOL floatingDockGlobalDragActivated;
@property(nonatomic, assign) FLMFloatingDockInputMode floatingDockInputMode;
@property(nonatomic, assign) BOOL floatingDockInputSessionActive;
@property(nonatomic, assign) BOOL floatingDockInputBlockedUntilNextTouch;
@property(nonatomic, assign) NSTimeInterval floatingDockInputBlockCutoffTimestamp;
@property(nonatomic, assign) BOOL floatingDockInputFramePending;
@property(nonatomic, assign) NSUInteger floatingDockInputFrameGeneration;
@property(nonatomic, strong) CADisplayLink *floatingDockInputDisplayLink;
@property(nonatomic, strong) CADisplayLink *floatingHighRefreshDisplayLink;
@property(nonatomic, assign) CFTimeInterval floatingHighRefreshDeadline;
@property(nonatomic, assign) NSUInteger floatingDockInputGeneration;
@property(nonatomic, assign) BOOL floatingDockReady;
@property(nonatomic, assign) BOOL floatingDockFeedbackSent;
@property(nonatomic, assign) BOOL floatingResizeCenterReady;
@property(nonatomic, assign) BOOL floatingDockContentTailProtected;
@property(nonatomic, assign) NSUInteger floatingDockContentProtectionGeneration;
@property(nonatomic, assign) CGPoint floatingExclusiveStartPoint;
@property(nonatomic, assign) NSTimeInterval floatingExclusiveStartTimestamp;
@property(nonatomic, assign) NSTimeInterval floatingOpenCloseGuardUntil;
@property(nonatomic, assign) BOOL floatingCloseInputArmed;
@property(nonatomic, assign) NSTimeInterval floatingCloseArmAt;
@property(nonatomic, assign) NSUInteger floatingCloseArmGeneration;
@property(nonatomic, assign) BOOL floatingExclusiveTapEligible;
@property(nonatomic, assign) BOOL floatingInteractiveFullscreenTransition;
@property(nonatomic, assign) BOOL floatingInteractiveScenePrepared;
@property(nonatomic, assign) BOOL floatingSceneUsesCardGeometry;
@property(nonatomic, assign) BOOL floatingSceneCardGeometryPending;
@property(nonatomic, assign) BOOL floatingSceneCardGeometryCommitted;
@property(nonatomic, assign) NSUInteger floatingSceneGeometryCommitGeneration;
@property(nonatomic, assign) CGFloat floatingFullscreenProgress;
@property(nonatomic, strong) UIView *floatingInteractiveSnapshot;
@property(nonatomic, strong) UIView *floatingInteractiveSnapshotBackground;
@property(nonatomic, strong) UIView *floatingInteractiveSnapshotContent;
@property(nonatomic, assign) BOOL floatingReconnectSuppressed;
@property(nonatomic, assign) BOOL floatingKeyboardVisible;
@property(nonatomic, assign) CGRect floatingKeyboardFrame;
@property(nonatomic, assign) CGFloat lastPortraitKeyboardHeight;
@property(nonatomic, assign) CGFloat floatingKeyboardMaximumVisibleHeight;
@property(nonatomic, assign) BOOL floatingKeyboardInteractionSessionActive;
@property(nonatomic, assign) NSUInteger floatingKeyboardInteractionGeneration;
@property(nonatomic, assign) NSUInteger floatingKeyboardSessionCounter;
@property(nonatomic, assign) NSUInteger floatingKeyboardSessionGeneration;
@property(nonatomic, strong) FLMKeyboardForwardingWindow *keyboardForwardingWindow;
@property(nonatomic, weak) UIView *floatingKeyboardLayerHostView;
@property(nonatomic, weak) UIView *floatingKeyboardRejectedHostView;
@property(nonatomic, strong) UIView *floatingKeyboardOriginalSuperview;
@property(nonatomic, assign) NSInteger floatingKeyboardOriginalSubviewIndex;
@property(nonatomic, assign) CGRect floatingKeyboardOriginalFrame;
@property(nonatomic, assign) CGAffineTransform floatingKeyboardOriginalTransform;
@property(nonatomic, assign) UIViewAutoresizing floatingKeyboardOriginalAutoresizingMask;
@property(nonatomic, assign) BOOL floatingKeyboardOriginalTranslatesAutoresizingMask;
@property(nonatomic, assign) NSUInteger floatingKeyboardHostSessionGeneration;
@property(nonatomic, strong) id floatingKeyboardScene;
@property(nonatomic, strong) id floatingKeyboardPreferredHostIdentity;
@property(nonatomic, assign) NSUInteger floatingKeyboardPairingSessionGeneration;
@property(nonatomic, assign) BOOL floatingKeyboardFramePending;
@property(nonatomic, assign) CGRect floatingKeyboardPendingFrame;
@property(nonatomic, assign) NSUInteger floatingKeyboardPendingSessionGeneration;
@property(nonatomic, weak) UIView *floatingKeyboardDeferredHostView;
@property(nonatomic, strong) id floatingKeyboardDeferredScene;
@property(nonatomic, assign) NSUInteger floatingKeyboardDeferredSessionGeneration;
@property(nonatomic, assign) CGPoint cornerGestureStartPoint;
@property(nonatomic, copy) NSString *floatingIdentifier;
@property(nonatomic, copy) NSString *prewarmedIdentifier;
@property(nonatomic, copy) NSString *lastObservedFrontmostIdentifier;
@property(nonatomic, assign) BOOL floatingExternalActivationArmed;
@property(nonatomic, assign) BOOL floatingFullscreenActivationArmed;
@property(nonatomic, strong) FLMDeviceApplicationSceneEntity *floatingSceneEntity;
@property(nonatomic, strong) FLMApplicationSceneHandle *floatingSceneHandle;
@property(nonatomic, strong) id floatingScene;
@property(nonatomic, strong) id floatingPresentationManager;
@property(nonatomic, strong) id floatingPresenter;
@property(nonatomic, strong) id floatingPresenterScene;
@property(nonatomic, assign) CGSize floatingHostReferenceSize;
@property(nonatomic, assign) NSUInteger floatingLaunchGeneration;
@property(nonatomic, assign) FLMFloatingLaunchState floatingLaunchState;
@property(nonatomic, assign) NSTimeInterval floatingLaunchStartedAt;
@property(nonatomic, assign) NSUInteger floatingRevealRetryCount;
@property(nonatomic, assign) NSTimeInterval floatingScenePreparedAt;
@property(nonatomic, assign) NSTimeInterval floatingPresenterUnavailableAt;
@property(nonatomic, assign) NSUInteger floatingPresenterRetryAttempt;
@property(nonatomic, assign) BOOL floatingCloseInProgress;
@property(nonatomic, assign) NSUInteger floatingCloseTokenCounter;
@property(nonatomic, assign) NSUInteger floatingActiveCloseToken;
@property(nonatomic, assign) BOOL floatingCloseCleanupDone;
@property(nonatomic, assign) BOOL floatingCloseKeepApplication;
@property(nonatomic, copy) NSString *floatingQueuedIdentifier;
@property(nonatomic, copy) NSString *floatingQueuedFullscreenIdentifier;
@property(nonatomic, strong) id floatingClosingScene;
@property(nonatomic, strong) id floatingClosingPresenter;
@property(nonatomic, strong) UIView *floatingClosingHostView;
@property(nonatomic, strong) NSTimer *lockMonitorTimer;
@property(nonatomic, strong) FLMDockGestureRecognizer *homeDockGesture;
@property(nonatomic, assign) BOOL homeDockGestureActive;
@property(nonatomic, assign) BOOL homeDockTriggerHandled;
@property(nonatomic, assign) BOOL floatingOpenTargetDocked;
+ (instancetype)sharedController;
- (void)start;
- (void)reloadPreferences;
- (void)createWindows;
- (void)createFloatingWindow;
- (BOOL)registerGlobalCornerGesture;
- (void)updateWindowFrames;
- (void)displayGeometryDidChange:(NSNotification *)notification;
- (void)handleCornerGuardGesture:(UIGestureRecognizer *)gesture;
- (void)handleCornerGesture:(UIGestureRecognizer *)gesture;
- (BOOL)resolveLandscapeCornerGesture:(UIGestureRecognizer *)gesture
                                touch:(UITouch *)touch
                         resolvedPoint:(CGPoint *)resolvedPoint
                      resolvedFromRight:(BOOL *)resolvedFromRight;
- (void)presentLandscapeWheelFromRight:(BOOL)fromRight;
- (void)handleLandscapeWheelItemTap:(UITapGestureRecognizer *)gesture;
- (void)armFloatingCloseInputForGeneration:(NSUInteger)generation;
- (void)handleModalGesture:(UIGestureRecognizer *)gesture;
- (void)handleHomeDockGesture:(FLMDockGestureRecognizer *)gesture;
- (void)activateDockedFrontmostApplication;
- (BOOL)shouldActivateWheelAtPoint:(CGPoint)point;
- (void)presentWheelFromRight:(BOOL)fromRight;
- (void)updateHighlightForPoint:(CGPoint)point;
- (void)pinWheel;
- (void)handleWheelTap:(UITapGestureRecognizer *)gesture;
- (void)handleFloatingBackdropTap:(UIGestureRecognizer *)gesture;
- (void)handleFloatingHandlePress:(UILongPressGestureRecognizer *)gesture;
- (void)handleFloatingHiddenBarDrag:(UILongPressGestureRecognizer *)gesture;
- (void)handleFloatingHandleTap:(UITapGestureRecognizer *)gesture;
- (void)handleFloatingDockTap:(UITapGestureRecognizer *)gesture;
- (void)handleFloatingDockDragPress:(UILongPressGestureRecognizer *)gesture;
- (void)handleFloatingExclusiveGesture:(UIGestureRecognizer *)gesture;
- (void)handleFloatingDockInputGesture:(FLMCornerGestureRecognizer *)gesture;
- (void)refreshWheelPriorityWindow;
- (void)activateFloatingDockDragForGeneration:(NSUInteger)generation;
- (void)queueFloatingDockInputUpdateForPoint:(CGPoint)point;
- (void)configureFloatingDisplayLinkForMaximumRefresh:(CADisplayLink *)displayLink;
- (void)ensureFloatingDockInputDisplayLink;
- (void)beginFloatingHighRefreshLeaseForDuration:(NSTimeInterval)duration;
- (void)tickFloatingHighRefreshDisplayLink:(CADisplayLink *)displayLink;
- (void)flushFloatingDockInputFrame:(CADisplayLink *)displayLink;
- (void)flushFloatingDockInputFrameImmediately;
- (void)cancelFloatingDockInputUpdates;
- (void)applyFloatingDockInputPoint:(CGPoint)point;
- (void)setFloatingDockRoutingSuppressed:(BOOL)suppressed;
- (CGRect)floatingContainerPresentationFrame;
- (CGFloat)floatingDockHiddenFractionForFrame:(CGRect)frame;
- (void)finishFloatingDockEntryImmediatelyForControl;
- (void)updateFloatingDockTouchGate;
- (void)keyboardFrameWillChange:(NSNotification *)notification;
- (void)keyboardDidHide:(NSNotification *)notification;
- (void)applyKeyboardFrame:(CGRect)frame visible:(BOOL)visible;
- (void)finalizeKeyboardDismissalProtection;
- (void)prepareKeyboardForwardingWindowIfNeeded;
- (void)keyboardLayerHostView:(UIView *)hostView
            didUpdateForScene:(id)scene
            sessionGeneration:(NSUInteger)sessionGeneration;
- (BOOL)floatingKeyboardPresentationReady;
- (BOOL)floatingApplicationHostReadyForKeyboardRoute;
- (void)flushDeferredFloatingKeyboardHostIfReady;
- (void)flushPendingFloatingKeyboardFrameIfReady;
- (void)restoreFloatingKeyboardLayerHost;
- (void)discardFloatingKeyboardLayerHost;
- (void)deactivateKeyboardForwardingWindow;
- (void)endFloatingKeyboardSession;
- (BOOL)propagateFloatingKeyboardScenePairing:(id)keyboardScene
                         preferredHostIdentity:(id)preferredHostIdentity
                             sessionGeneration:(NSUInteger)sessionGeneration;
- (void)clearFloatingKeyboardScenePairingForSession:(NSUInteger)sessionGeneration;
- (CGRect)floatingKeyboardInteractionFrame;
- (BOOL)pointIsInsideFloatingInteractionDomain:(CGPoint)point;
- (CGFloat)floatingKeyboardAvoidanceHeightForFrame:(CGRect)frame;
- (void)beginFloatingKeyboardInteractionSession;
- (void)endFloatingKeyboardInteractionSession;
- (void)resetFloatingInteractiveLayoutAnimated:(BOOL)animated;
- (void)setFloatingApplicationInputBlocked:(BOOL)blocked;
- (void)protectFloatingContentAfterDockTouch;
- (void)updateFloatingFullscreenSnapshotForProgress:(CGFloat)progress;
- (void)layoutFloatingHandleForCurrentContainer;
- (CGFloat)effectiveCenteredCardWidth;
- (CGFloat)effectiveCenteredCardHeight;
- (CGFloat)effectiveCenteredCardScaleX;
- (CGFloat)effectiveCenteredCardScaleY;
- (CGFloat)effectiveCenteredDockSwipeThreshold;
- (CGFloat)effectiveDockedPresentationWidth;
- (BOOL)isLandscapeFloatingSession;
- (UIView *)floatingLayoutView;
- (UIEdgeInsets)floatingLayoutSafeInsets;
- (CGPoint)visualPointForGesture:(UIGestureRecognizer *)gesture;
- (CGPoint)visualPointForTouch:(UITouch *)touch;
- (void)captureFloatingOrientationContract;
- (void)clearFloatingOrientationContract;
- (CGRect)landscapeFloatingFrame;
- (CGRect)centeredFloatingFrame;
- (CGRect)dockedFloatingFrameOnRight:(BOOL)onRight width:(CGFloat)width;
- (CGRect)dockedFloatingFrameOnRight:(BOOL)onRight
                               width:(CGFloat)width
             preservingVerticalCenter:(CGFloat)verticalCenter;
- (CGRect)dockedHiddenFloatingFrameOnRight:(BOOL)onRight width:(CGFloat)width;
- (CGRect)dockedHiddenFloatingFrameOnRight:(BOOL)onRight
                                      width:(CGFloat)width
                    preservingVerticalCenter:(CGFloat)verticalCenter;
- (void)layoutFloatingDockShadow;
- (void)updateFloatingDockAccessoryPositions;
- (void)layoutFloatingResizeHandle;
- (BOOL)floatingResizeControlContainsPoint:(CGPoint)point;
- (void)saveFloatingDockWidth;
- (void)normalizeFloatingContainerTransform;
- (void)configureFloatingInteractionForDockedState;
- (void)restoreFloatingHandleInteraction;
- (void)transitionFloatingWindowToDocked;
- (void)transitionFloatingWindowToCentered;
- (void)transitionFloatingWindowToHiddenAnimated:(BOOL)animated;
- (void)finishFloatingDockHiddenGesture:(BOOL)shouldHide
                                atPoint:(CGPoint)point;
- (void)updateFloatingDockHiddenRevealForPoint:(CGPoint)point;
- (void)snapDockedFloatingWindowUsingTouchPoint:(CGPoint)point;
- (void)prepareFloatingSceneForInteractiveFullscreen;
- (void)restoreFloatingSceneAfterCancelledTransition;
- (void)transitionFloatingWindowToFullscreen;
- (void)finishFullscreenHandoffWithCover:(UIView *)cover
                              identifier:(NSString *)identifier
                              generation:(NSUInteger)generation
                                 attempt:(NSUInteger)attempt;
- (void)protectedSceneDidDisappear:(NSNotification *)notification;
- (void)openFloatingIdentifier:(NSString *)identifier;
- (void)attachFloatingIdentifier:(NSString *)identifier
                       generation:(NSUInteger)generation
                          attempt:(NSUInteger)attempt;
- (void)commitFloatingCardSceneGeometryForIdentifier:(NSString *)identifier
                                           generation:(NSUInteger)generation
                                              attempt:(NSUInteger)attempt;
- (void)finishFloatingCardSceneGeometryCommitForIdentifier:(NSString *)identifier
                                                  generation:(NSUInteger)generation
                                                     attempt:(NSUInteger)attempt;
- (void)failFloatingLaunchForIdentifier:(NSString *)identifier
                               generation:(NSUInteger)generation;
- (void)invalidateFloatingPresenterForRecoveryReason:(NSString *)reason;
- (void)finishFloatingCloseWithToken:(NSUInteger)token;
- (FLMApplicationSceneHandle *)sceneHandleForIdentifier:(NSString *)identifier;
- (id)sceneForHandle:(FLMApplicationSceneHandle *)sceneHandle;
- (BOOL)prepareFloatingScene:(id)scene
                      handle:(FLMApplicationSceneHandle *)sceneHandle;
- (void)backgroundFloatingScene:(id)scene;
- (UIView *)hostViewForSceneHandle:(FLMApplicationSceneHandle *)sceneHandle;
- (void)layoutFloatingWindow;
- (void)configureFloatingLaunchCoverForIdentifier:(NSString *)identifier;
- (void)revealFloatingContentForGeneration:(NSUInteger)generation;
- (void)layoutFloatingHostView;
- (CGSize)floatingSystemSceneReferenceSize;
- (CGSize)floatingContentViewportReferenceSize;
- (CGSize)floatingSceneReferenceSize;
- (BOOL)applyFloatingSceneLogicalFrameForCurrentPresentation:(NSString *)policy;
- (BOOL)floatingSceneLogicalFrameMatchesSystemReference;
- (void)closeFloatingWindowKeepingApplication:(BOOL)keepApplication;
- (void)activateIdentifierFullscreen:(NSString *)identifier;
- (void)beginLockMonitoring;
- (void)stopLockMonitoringIfIdle;
- (void)checkLockState:(NSTimer *)timer;
- (FLMWheelItemView *)itemNearPoint:(CGPoint)point maximumDistance:(CGFloat)distance;
- (void)dismissWheelLaunchingItem:(FLMWheelItemView *)item;
- (void)activateIdentifier:(NSString *)identifier;
@end

static int FlymeRuntimeToken = -1;
static int FlymeKeyboardRouteToken = -1;
static int FlymeKeyboardSceneToken = -1;
static int FlymeKeyboardSessionToken = -1;
static int FlymeKeyboardAvoidanceToken = -1;
static int FlymeKeyboardCardGeometryToken = -1;
static int FlymeKeyboardAppCtorToken = -1;
static int FlymeKeyboardAppReadyToken = -1;
static int FlymeKeyboardDismissRequestToken = -1;
static int FlymeDockInputBlockToken = -1;
static uint64_t FLMLastDockInputBlockState = UINT64_MAX;
static NSString *const FLMKeyboardSharedStatePath =
    @"/var/mobile/Library/Preferences/FlymeMultitasking-KeyboardState.plist";
static NSString *const FLMKeyboardSharedStateRootlessPath =
    @"/var/jb/var/mobile/Library/Preferences/FlymeMultitasking-KeyboardState.plist";
static dispatch_queue_t FLMKeyboardSharedStateWriterQueue;
static NSString *FLMKeyboardSharedIdentifier;
static uint64_t FLMKeyboardSharedSceneHash = 0;
static uint64_t FLMKeyboardSharedSessionGeneration = 0;
static BOOL FLMKeyboardSharedAvoidanceVisible = NO;
static CGFloat FLMKeyboardSharedAvoidanceHeight = 0.0;
static BOOL FLMKeyboardSharedCardActive = NO;
static CGFloat FLMKeyboardSharedCardBottom = 0.0;
static CGFloat FLMKeyboardSharedCardScale = 0.0;
static CGFloat FLMKeyboardSharedCardWidth = 0.0;
static CGFloat FLMKeyboardSharedCardHeight = 0.0;
static CGFloat FLMKeyboardSharedContentViewportWidth = 0.0;
static CGFloat FLMKeyboardSharedContentViewportHeight = 0.0;
static BOOL FLMKeyboardSharedLandscapeScene = NO;
static BOOL FLMKeyboardSharedContentStrip = NO;
static NSInteger FLMKeyboardSharedInterfaceOrientation = UIInterfaceOrientationPortrait;
static CGFloat FLMKeyboardSharedSystemWidth = 0.0;
static CGFloat FLMKeyboardSharedSystemHeight = 0.0;

static id FLMCopyPreference(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyValue((__bridge CFStringRef)key,
                                                      FLYME_PREFERENCES_DOMAIN,
                                                      kCFPreferencesCurrentUser,
                                                      kCFPreferencesAnyHost);
    return CFBridgingRelease(value);
}

static NSString *FLMSceneIdentifier(id scene) {
    if (!scene) {
        return nil;
    }
    @try {
        if ([scene respondsToSelector:@selector(sceneIdentifier)]) {
            id value = [scene sceneIdentifier];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return value;
            }
        }
        if ([scene respondsToSelector:@selector(identifier)]) {
            id value = [scene identifier];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return value;
            }
        }
        id settings = [scene respondsToSelector:@selector(settings)]
                          ? [scene settings]
                          : nil;
        if ([settings respondsToSelector:@selector(sceneIdentifier)]) {
            id value = [settings sceneIdentifier];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return value;
            }
        }
        if ([settings respondsToSelector:@selector(identifier)]) {
            id value = [settings identifier];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return value;
            }
        }
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static uint64_t FLMIdentifierHash(NSString *identifier) {
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

static void FLMPublishDockInputBlockState(NSString *identifier,
                                          BOOL blocked,
                                          NSString *reason) {
    uint64_t identifierHash = FLMIdentifierHash(identifier);
    // Close transfers the identifier out of the live controller before its
    // host/presenter teardown finishes. A late animation completion may still
    // reassert blocking during that interval; without a target it must preserve
    // the existing active state, not reinterpret "blocked" as a global clear.
    if (blocked && identifierHash == 0) {
        return;
    }
    uint64_t state = FLMDockInputBlockState(identifierHash, blocked);
    if (FlymeDockInputBlockToken < 0 &&
        notify_register_check(FLYME_DOCK_INPUT_BLOCK_NOTIFICATION,
                              &FlymeDockInputBlockToken) != NOTIFY_STATUS_OK) {
        FlymeDockInputBlockToken = -1;
        FLMDiagnosticLog(
            @"sb dock-input-block register-failed blocked=%d app=%@ reason=%@",
            blocked, identifier ?: @"<none>", reason ?: @"<none>");
        return;
    }
    if (state == FLMLastDockInputBlockState) {
        return;
    }
    int setStatus = notify_set_state(FlymeDockInputBlockToken, state);
    int postStatus = notify_post(FLYME_DOCK_INPUT_BLOCK_NOTIFICATION);
    if (setStatus == NOTIFY_STATUS_OK && postStatus == NOTIFY_STATUS_OK) {
        FLMLastDockInputBlockState = state;
    } else {
        FLMLastDockInputBlockState = UINT64_MAX;
    }
    FLMDiagnosticLog(
        @"sb dock-input-block publish blocked=%d app=%@ hash=0x%016llx state=0x%016llx reason=%@ set=%d post=%d",
        state != 0, identifier ?: @"<none>",
        (unsigned long long)identifierHash, (unsigned long long)state,
        reason ?: @"<none>", setStatus, postStatus);
}

typedef struct {
    int registerStatus;
    int readStatus;
    uint64_t rawState;
    uint16_t magic;
    uint16_t build;
    pid_t pid;
    BOOL processAlive;
    BOOL valid;
} FLMKeyboardLifecycleEvidence;

static FLMKeyboardLifecycleEvidence FLMReadKeyboardLifecycleEvidence(
    const char *notificationName,
    int *token,
    uint16_t expectedMagic) {
    FLMKeyboardLifecycleEvidence evidence = {
        .registerStatus = NOTIFY_STATUS_OK,
        .readStatus = -1,
        .rawState = 0, .magic = 0, .build = 0, .pid = 0,
        .processAlive = NO, .valid = NO,
    };
    if (*token < 0) {
        evidence.registerStatus =
            notify_register_check(notificationName, token);
        if (evidence.registerStatus != NOTIFY_STATUS_OK) {
            *token = -1;
            return evidence;
        }
    }
    evidence.readStatus = notify_get_state(*token, &evidence.rawState);
    if (evidence.readStatus != NOTIFY_STATUS_OK) {
        return evidence;
    }
    evidence.magic = (uint16_t)((evidence.rawState >> 48) & 0xFFFFULL);
    evidence.build = (uint16_t)((evidence.rawState >> 32) & 0xFFFFULL);
    evidence.pid = (pid_t)(evidence.rawState & 0xFFFFFFFFULL);
    errno = 0;
    evidence.processAlive =
        evidence.pid > 1 &&
        (kill(evidence.pid, 0) == 0 || errno == EPERM);
    evidence.valid = evidence.magic == expectedMagic &&
                     evidence.build == FLYME_KEYBOARD_APP_ADAPTER_BUILD &&
                     evidence.processAlive;
    return evidence;
}

static BOOL FLMLogKeyboardAdapterHandshake(NSString *context,
                                           NSString *identifier,
                                           pid_t *readyPID) {
    if (readyPID) {
        *readyPID = 0;
    }
    // Readiness is diagnostic evidence only; it no longer gates publishing.
    if (!FLMDiagnosticCaptureEnabled()) return NO;
    FLMKeyboardLifecycleEvidence ctor = FLMReadKeyboardLifecycleEvidence(
        FLYME_KEYBOARD_APP_CTOR_NOTIFICATION,
        &FlymeKeyboardAppCtorToken,
        FLYME_KEYBOARD_APP_CTOR_MAGIC);
    FLMKeyboardLifecycleEvidence ready = FLMReadKeyboardLifecycleEvidence(
        FLYME_KEYBOARD_APP_READY_NOTIFICATION,
        &FlymeKeyboardAppReadyToken,
        FLYME_KEYBOARD_APP_READY_MAGIC);
    // The wheel can target any ordinary application. The identifier is the
    // exact value published by SpringBoard; the lifecycle tokens prove that
    // this same target process loaded and completed the adapter.
    BOOL targetMatches = identifier.length > 0;
    BOOL accepted = targetMatches && ctor.valid && ready.valid &&
                    ctor.pid == ready.pid;
    if (accepted && readyPID) {
        *readyPID = ready.pid;
    }
    FLMDiagnosticLog(
        @"sb adapter-handshake context=%@ app=%@ filter=target-bundle target-gated accepted=%d ctor={reg:%d read:%d raw:0x%016llx magic:0x%04x build:%u pid:%d alive:%d valid:%d} ready={reg:%d read:%d raw:0x%016llx magic:0x%04x build:%u pid:%d alive:%d valid:%d}",
        context ?: @"<none>", identifier ?: @"<none>", accepted,
        ctor.registerStatus, ctor.readStatus,
        (unsigned long long)ctor.rawState, ctor.magic, ctor.build, ctor.pid,
        ctor.processAlive, ctor.valid,
        ready.registerStatus, ready.readStatus,
        (unsigned long long)ready.rawState, ready.magic, ready.build, ready.pid,
        ready.processAlive, ready.valid);
    return accepted;
}

static BOOL FLMKeyboardAppAdapterReadyForIdentifier(NSString *identifier,
                                                     pid_t *readyPID) {
    return FLMLogKeyboardAdapterHandshake(@"avoidance", identifier, readyPID);
}

// Latest-value mailbox: at most one pending snapshot and one in-flight write.
// All state fields are still collected together on the SpringBoard main thread.
static os_unfair_lock FLMKeyboardWriteLock = OS_UNFAIR_LOCK_INIT;
static NSDictionary *FLMKeyboardPendingSnapshot;
static NSDictionary *FLMKeyboardLastRequestedSnapshot;
static BOOL FLMKeyboardWriteScheduled = NO;

static void FLMKeyboardSharedWriteFailed(NSDictionary *snapshot) {
    os_unfair_lock_lock(&FLMKeyboardWriteLock);
    if (FLMKeyboardLastRequestedSnapshot == snapshot)
        FLMKeyboardLastRequestedSnapshot = nil; // allow the next event to retry
    os_unfair_lock_unlock(&FLMKeyboardWriteLock);
}

static void FLMScheduleKeyboardSharedStateWrite(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FLMKeyboardSharedStateWriterQueue = dispatch_queue_create(
            "com.codex.flymemultitasking.keyboard-shared-state",
            DISPATCH_QUEUE_SERIAL);
    });
    BOOL active = FLMKeyboardSharedIdentifier.length > 0 &&
                  FLMKeyboardSharedSessionGeneration != 0;
    NSDictionary *snapshot = @{
        @"version": @3,
        @"active": @(active),
        @"bundleID": FLMKeyboardSharedIdentifier ?: @"",
        @"sceneHash": @(FLMKeyboardSharedSceneHash),
        @"sessionGeneration": @(FLMKeyboardSharedSessionGeneration),
        @"avoidanceVisible": @(FLMKeyboardSharedAvoidanceVisible),
        @"avoidanceHeight": @(FLMKeyboardSharedAvoidanceHeight),
        @"cardActive": @(FLMKeyboardSharedCardActive),
        @"cardBottom": @(FLMKeyboardSharedCardBottom),
        @"cardScale": @(FLMKeyboardSharedCardScale),
        @"cardWidth": @(FLMKeyboardSharedCardWidth),
        @"cardHeight": @(FLMKeyboardSharedCardHeight),
        @"contentViewportWidth": @(FLMKeyboardSharedContentViewportWidth),
        @"contentViewportHeight": @(FLMKeyboardSharedContentViewportHeight),
        @"landscapeScene": @(FLMKeyboardSharedLandscapeScene),
        @"contentStrip": @(FLMKeyboardSharedContentStrip),
        @"interfaceOrientation": @(FLMKeyboardSharedInterfaceOrientation),
        @"systemWidth": @(FLMKeyboardSharedSystemWidth),
        @"systemHeight": @(FLMKeyboardSharedSystemHeight),
    };
    os_unfair_lock_lock(&FLMKeyboardWriteLock);
    if ([snapshot isEqualToDictionary:FLMKeyboardLastRequestedSnapshot]) {
        os_unfair_lock_unlock(&FLMKeyboardWriteLock);
        return;
    }
    FLMKeyboardLastRequestedSnapshot = snapshot;
    FLMKeyboardPendingSnapshot = snapshot;
    if (FLMKeyboardWriteScheduled) {
        os_unfair_lock_unlock(&FLMKeyboardWriteLock);
        return;
    }
    FLMKeyboardWriteScheduled = YES;
    os_unfair_lock_unlock(&FLMKeyboardWriteLock);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.016 * NSEC_PER_SEC)),
                   FLMKeyboardSharedStateWriterQueue, ^{
        @autoreleasepool {
            os_unfair_lock_lock(&FLMKeyboardWriteLock);
            NSDictionary *snapshot = FLMKeyboardPendingSnapshot;
            FLMKeyboardPendingSnapshot = nil;
            FLMKeyboardWriteScheduled = NO;
            os_unfair_lock_unlock(&FLMKeyboardWriteLock);
            static NSDictionary *lastPersistedSnapshot;
            if ([snapshot isEqualToDictionary:lastPersistedSnapshot]) return;
            NSMutableDictionary *persistedSnapshot = [snapshot mutableCopy];
            persistedSnapshot[@"updatedAt"] = @([[NSDate date] timeIntervalSince1970]);
            NSError *serializationError = nil;
            NSData *data = [NSPropertyListSerialization
                dataWithPropertyList:persistedSnapshot
                              format:NSPropertyListBinaryFormat_v1_0
                             options:0
                               error:&serializationError];
            if (!data || serializationError) {
                FLMKeyboardSharedWriteFailed(snapshot);
                return;
            }
            NSError *writeError = nil;
            BOOL wrote = [data writeToFile:FLMKeyboardSharedStatePath
                                   options:NSDataWritingAtomic
                                     error:&writeError];
            NSString *writtenPath = nil;
            if (wrote) {
                chmod(FLMKeyboardSharedStatePath.fileSystemRepresentation, 0644);
                writtenPath = FLMKeyboardSharedStatePath;
            } else {
                writeError = nil;
                wrote = [data writeToFile:FLMKeyboardSharedStateRootlessPath
                                  options:NSDataWritingAtomic
                                    error:&writeError];
                if (wrote) {
                    chmod(
                        FLMKeyboardSharedStateRootlessPath.fileSystemRepresentation,
                        0644);
                    writtenPath = FLMKeyboardSharedStateRootlessPath;
                }
            }
            if (wrote) {
                lastPersistedSnapshot = snapshot;
                // The notification is only a refresh signal. All routing and
                // geometry values are read from the atomically replaced file.
                notify_post(FLYME_KEYBOARD_SHARED_STATE_NOTIFICATION);
            } else {
                FLMKeyboardSharedWriteFailed(snapshot);
            }
            FLMDiagnosticLog(
                @"sb shared-state write success=%d path=%@ error=%@",
                wrote, writtenPath ?: @"<none>",
                writeError.localizedDescription ?: @"<none>");
        }
    });
    FLMDiagnosticLog(
        @"sb shared-state publish active=%d app=%@ session=%llu avoidance=%d/%.2f card=%d/%.2f/%.5f landscape=%d orientation=%ld system={%.1f,%.1f}",
        active, FLMKeyboardSharedIdentifier ?: @"<none>",
        (unsigned long long)FLMKeyboardSharedSessionGeneration,
        FLMKeyboardSharedAvoidanceVisible, FLMKeyboardSharedAvoidanceHeight,
        FLMKeyboardSharedCardActive, FLMKeyboardSharedCardBottom,
        FLMKeyboardSharedCardScale, FLMKeyboardSharedLandscapeScene,
        (long)FLMKeyboardSharedInterfaceOrientation,
        FLMKeyboardSharedSystemWidth, FLMKeyboardSharedSystemHeight);
}

typedef struct {
    uint64_t value;
    BOOL valid;
} FLMNotifyPublication;

// Cache only a successful set AND post. Failures remain retryable on the next
// real event. Startup always publishes even when the first desired value is 0.
static void FLMPublishChangedNotifyState(int token, const char *name,
                                         uint64_t state, FLMNotifyPublication *last) {
    if (token < 0 || (last->valid && last->value == state)) return;
    last->valid = NO; // a partial failure must not leave an old cache valid
    if (notify_set_state(token, state) != NOTIFY_STATUS_OK) return;
    if (notify_post(name) != NOTIFY_STATUS_OK) return;
    last->value = state;
    last->valid = YES;
}

static void FLMPublishKeyboardState(NSString *identifier,
                                    id scene,
                                    uint64_t sessionGeneration) {
    uint64_t routeHash = FLMIdentifierHash(identifier);
    uint64_t sceneHash = FLMIdentifierHash(FLMSceneIdentifier(scene));
    FLMKeyboardSharedIdentifier = [identifier copy];
    FLMKeyboardSharedSceneHash = sceneHash;
    FLMKeyboardSharedSessionGeneration = sessionGeneration;
    if (identifier.length == 0 || sessionGeneration == 0) {
        FLMKeyboardSharedAvoidanceVisible = NO;
        FLMKeyboardSharedAvoidanceHeight = 0.0;
        FLMKeyboardSharedCardActive = NO;
        FLMKeyboardSharedCardBottom = 0.0;
        FLMKeyboardSharedCardScale = 0.0;
        FLMKeyboardSharedCardWidth = 0.0;
        FLMKeyboardSharedCardHeight = 0.0;
        FLMKeyboardSharedContentViewportWidth = 0.0;
        FLMKeyboardSharedContentViewportHeight = 0.0;
    }
    FLMScheduleKeyboardSharedStateWrite();
    if (FlymeKeyboardRouteToken < 0 &&
        notify_register_check(FLYME_KEYBOARD_NOTIFICATION,
                              &FlymeKeyboardRouteToken) != NOTIFY_STATUS_OK) {
        FlymeKeyboardRouteToken = -1;
    }
    if (FlymeKeyboardSceneToken < 0) {
        notify_register_check(FLYME_KEYBOARD_SCENE_NOTIFICATION,
                              &FlymeKeyboardSceneToken);
    }
    if (FlymeKeyboardSessionToken < 0) {
        notify_register_check(FLYME_KEYBOARD_SESSION_NOTIFICATION,
                              &FlymeKeyboardSessionToken);
    }
    static uint64_t lastRoute = 0, lastScene = 0, lastSession = 0;
    static BOOL published = NO;
    if (published && routeHash == lastRoute && sceneHash == lastScene &&
        sessionGeneration == lastSession) return;
    published = NO;
    // Set the entire legacy tuple before posting any of its change signals.
    BOOL routeOK = FlymeKeyboardRouteToken >= 0 &&
        notify_set_state(FlymeKeyboardRouteToken, routeHash) == NOTIFY_STATUS_OK;
    BOOL sceneOK = FlymeKeyboardSceneToken >= 0 &&
        notify_set_state(FlymeKeyboardSceneToken, sceneHash) == NOTIFY_STATUS_OK;
    BOOL sessionOK = FlymeKeyboardSessionToken >= 0 &&
        notify_set_state(FlymeKeyboardSessionToken, sessionGeneration) == NOTIFY_STATUS_OK;
    BOOL posted = YES;
    if (sessionOK) posted &= notify_post(FLYME_KEYBOARD_SESSION_NOTIFICATION) == NOTIFY_STATUS_OK;
    if (sceneOK) posted &= notify_post(FLYME_KEYBOARD_SCENE_NOTIFICATION) == NOTIFY_STATUS_OK;
    if (routeOK) posted &= notify_post(FLYME_KEYBOARD_NOTIFICATION) == NOTIFY_STATUS_OK;
    if (routeOK && sceneOK && sessionOK && posted) {
        published = YES;
        lastRoute = routeHash;
        lastScene = sceneHash;
        lastSession = sessionGeneration;
    }
    FLMDiagnosticLog(
        @"sb route-publish app=%@ scene=%@ session=%llu routeHash=0x%llx sceneHash=0x%llx",
        identifier ?: @"<none>", FLMSceneIdentifier(scene) ?: @"<none>",
        (unsigned long long)sessionGeneration,
        (unsigned long long)routeHash,
        (unsigned long long)sceneHash);
    if (identifier.length > 0 && sessionGeneration != 0) {
        FLMLogKeyboardAdapterHandshake(@"route-publish", identifier, NULL);
    }
}

static void FLMPublishKeyboardDismissRequest(NSString *identifier,
                                             uint64_t sessionGeneration) {
    if (identifier.length == 0 || sessionGeneration == 0) {
        return;
    }
    if (FlymeKeyboardDismissRequestToken < 0 &&
        notify_register_check(FLYME_KEYBOARD_DISMISS_REQUEST_NOTIFICATION,
                              &FlymeKeyboardDismissRequestToken) !=
            NOTIFY_STATUS_OK) {
        FlymeKeyboardDismissRequestToken = -1;
        FLMDiagnosticLog(
            @"sb dismiss-request publish-failed app=%@ session=%llu",
            identifier, (unsigned long long)sessionGeneration);
        return;
    }

    // A close request must not depend on the asynchronously written shared
    // plist. Pack the target bundle hash and the current keyboard session into
    // one Darwin notify state so the application can still validate the
    // request if route-clear is delivered first on another channel.
    uint64_t requestState =
        ((sessionGeneration & 0xFFFFFFFFULL) << 32) |
        (FLMIdentifierHash(identifier) & 0xFFFFFFFFULL);
    int setStatus =
        notify_set_state(FlymeKeyboardDismissRequestToken, requestState);
    int postStatus =
        notify_post(FLYME_KEYBOARD_DISMISS_REQUEST_NOTIFICATION);
    FLMDiagnosticLog(
        @"sb dismiss-request app=%@ session=%llu state=0x%016llx set=%d post=%d",
        identifier, (unsigned long long)sessionGeneration,
        (unsigned long long)requestState, setStatus, postStatus);
}

static void FLMPublishKeyboardAvoidance(uint64_t sessionGeneration,
                                        CGFloat keyboardHeight,
                                        BOOL visible) {
    if (sessionGeneration == 0) {
        return;
    }
    pid_t adapterPID = 0;
    BOOL adapterReady = FLMKeyboardAppAdapterReadyForIdentifier(
        FLMKeyboardSharedIdentifier, &adapterPID);
    // Readiness is evidence, never a publishing gate. In 0.8.39 the first
    // keyboard frame could beat the target-app ctor by one run-loop turn, causing
    // a zero avoidance value that was never republished after ready arrived.
    // The atomically stored state is safe without a consumer; a late adapter
    // simply reads the latest real value during its initial route reload.
    BOOL effectiveVisible = visible;
    CGFloat height = effectiveVisible ? MAX(0.0, keyboardHeight) : 0.0;
    FLMKeyboardSharedAvoidanceVisible = effectiveVisible;
    FLMKeyboardSharedAvoidanceHeight = height;
    FLMScheduleKeyboardSharedStateWrite();
    if (FlymeKeyboardAvoidanceToken < 0 &&
        notify_register_check(FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION,
                              &FlymeKeyboardAvoidanceToken) != NOTIFY_STATUS_OK) {
        FlymeKeyboardAvoidanceToken = -1;
    }
    uint64_t encodedHeight =
        MIN(0xFFFFFFULL, (uint64_t)llround(height * 100.0));
    uint64_t encodedGeneration =
        (sessionGeneration & 0x7FFFFFFFFFULL) << 24;
    uint64_t state = (effectiveVisible ? (1ULL << 63) : 0) |
                     encodedGeneration | encodedHeight;
    static FLMNotifyPublication lastAvoidance;
    FLMPublishChangedNotifyState(FlymeKeyboardAvoidanceToken,
        FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION, state, &lastAvoidance);
    FLMDiagnosticLog(
        @"sb avoidance-publish session=%llu requested=%d visible=%d height=%.2f adapterReady=%d adapterPID=%d state=0x%llx",
        (unsigned long long)sessionGeneration, visible, effectiveVisible,
        height, adapterReady, adapterPID, (unsigned long long)state);
}

static void FLMPublishKeyboardCardGeometry(uint64_t sessionGeneration,
                                           CGFloat cardBottom,
                                           CGFloat visualScale,
                                           CGFloat cardWidth,
                                           CGFloat cardHeight,
                                           BOOL active) {
    BOOL hasCardDimensions = cardWidth > 1.0 && cardHeight > 1.0;
    FLMKeyboardSharedCardActive = active && sessionGeneration != 0 &&
                                  cardBottom > 1.0 && visualScale > 0.05 &&
                                  hasCardDimensions;
    FLMKeyboardSharedCardBottom =
        FLMKeyboardSharedCardActive ? cardBottom : 0.0;
    FLMKeyboardSharedCardScale =
        FLMKeyboardSharedCardActive ? visualScale : 0.0;
    FLMKeyboardSharedCardWidth = FLMKeyboardSharedCardActive
                                     ? MAX(0.0, cardWidth)
                                     : 0.0;
    FLMKeyboardSharedCardHeight = FLMKeyboardSharedCardActive
                                      ? MAX(0.0, cardHeight)
                                      : 0.0;
    FLMKeyboardSharedContentViewportWidth = FLMKeyboardSharedCardActive
                                                ? FLMVirtualViewportWidth
                                                : 0.0;
    FLMKeyboardSharedContentViewportHeight =
        FLMKeyboardSharedCardActive && visualScale > 0.05
            ? FLMKeyboardSharedCardHeight / visualScale
            : 0.0;
    FLMScheduleKeyboardSharedStateWrite();
    if (FlymeKeyboardCardGeometryToken < 0 &&
        notify_register_check(FLYME_KEYBOARD_CARD_GEOMETRY_NOTIFICATION,
                              &FlymeKeyboardCardGeometryToken) !=
            NOTIFY_STATUS_OK) {
        FlymeKeyboardCardGeometryToken = -1;
    }
    uint64_t state = 0;
    if (FLMKeyboardSharedCardActive) {
        uint64_t generation = (sessionGeneration & 0x7FFFULL) << 48;
        uint64_t encodedBottom =
            MIN(0xFFFFFFULL, (uint64_t)llround(cardBottom * 100.0)) << 24;
        uint64_t encodedScale =
            MIN(0xFFFFFFULL, (uint64_t)llround(visualScale * 1000000.0));
        state = (1ULL << 63) | generation | encodedBottom | encodedScale;
    }
    static FLMNotifyPublication lastGeometry;
    FLMPublishChangedNotifyState(FlymeKeyboardCardGeometryToken,
        FLYME_KEYBOARD_CARD_GEOMETRY_NOTIFICATION, state, &lastGeometry);
    FLMDiagnosticLog(
        @"sb geometry-publish session=%llu active=%d bottom=%.2f scale=%.5f card={%.2f,%.2f} viewport={%.2f,%.2f} state=0x%llx",
        (unsigned long long)sessionGeneration, active, cardBottom, visualScale,
        FLMKeyboardSharedCardWidth, FLMKeyboardSharedCardHeight,
        FLMKeyboardSharedContentViewportWidth,
        FLMKeyboardSharedContentViewportHeight,
        (unsigned long long)state);
}

static UIWindowScene *FLMForegroundWindowScene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                return (UIWindowScene *)scene;
            }
        }
    }
    return nil;
}

static UIWindow *FLMCurrentKeyWindow(void) {
    UIWindowScene *scene = FLMForegroundWindowScene();
    if (@available(iOS 13.0, *)) {
        for (UIWindow *window in scene.windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    return nil;
}

static UIWindow *FLMCreateWindow(CGRect frame) {
    UIWindowScene *scene = FLMForegroundWindowScene();
    if (@available(iOS 13.0, *)) {
        if (scene) {
            FLMOverlayWindow *window = [[FLMOverlayWindow alloc] initWithWindowScene:scene];
            window.frame = frame;
            return window;
        }
    }
    return [[FLMOverlayWindow alloc] initWithFrame:frame];
}

static FLMFloatingWindow *FLMCreateFloatingWindow(CGRect frame) {
    UIWindowScene *scene = FLMForegroundWindowScene();
    if (@available(iOS 13.0, *)) {
        if (scene) {
            FLMFloatingWindow *window =
                [[FLMFloatingWindow alloc] initWithWindowScene:scene];
            window.frame = frame;
            return window;
        }
    }
    return [[FLMFloatingWindow alloc] initWithFrame:frame];
}

static FLMDockTouchGateWindow *FLMCreateDockTouchGateWindow(CGRect frame) {
    UIWindowScene *scene = FLMForegroundWindowScene();
    if (@available(iOS 13.0, *)) {
        if (scene) {
            FLMDockTouchGateWindow *window =
                [[FLMDockTouchGateWindow alloc] initWithWindowScene:scene];
            window.frame = frame;
            return window;
        }
    }
    return [[FLMDockTouchGateWindow alloc] initWithFrame:frame];
}

static FLMHotspotWindow *FLMCreateHotspotWindow(CGRect frame) {
    UIWindowScene *scene = FLMForegroundWindowScene();
    if (@available(iOS 13.0, *)) {
        if (scene) {
            FLMHotspotWindow *window =
                [[FLMHotspotWindow alloc] initWithWindowScene:scene];
            window.frame = frame;
            return window;
        }
    }
    return [[FLMHotspotWindow alloc] initWithFrame:frame];
}

static FLMHomeDockWindow *FLMCreateHomeDockWindow(CGRect frame) {
    UIWindowScene *scene = FLMForegroundWindowScene();
    if (@available(iOS 13.0, *)) {
        if (scene) {
            FLMHomeDockWindow *window =
                [[FLMHomeDockWindow alloc] initWithWindowScene:scene];
            window.frame = frame;
            return window;
        }
    }
    return [[FLMHomeDockWindow alloc] initWithFrame:frame];
}

static UIImage *FLMLockImage(void) {
    UIImage *image = [UIImage systemImageNamed:@"lock.fill"];
    return [image imageWithTintColor:[UIColor whiteColor]
                       renderingMode:UIImageRenderingModeAlwaysOriginal];
}

static UIImage *FLMApplicationIcon(NSString *bundleIdentifier) {
    if ([bundleIdentifier isEqualToString:FLYME_LOCK_SCREEN_ITEM]) {
        return FLMLockImage();
    }
    if ([UIImage respondsToSelector:
                     @selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        UIImage *image = [UIImage _applicationIconImageForBundleIdentifier:bundleIdentifier
                                                                    format:2
                                                                     scale:[UIScreen mainScreen].scale];
        if (image) {
            return image;
        }
    }
    return [UIImage systemImageNamed:@"app.fill"];
}

static void FLMPreferencesChanged(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[FLMWheelController sharedController] reloadPreferences];
    });
}

@implementation FLMWheelController

+ (instancetype)sharedController {
    static FLMWheelController *controller = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [[self alloc] init];
    });
    return controller;
}

- (void)start {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        FLMPreferencesChanged,
                                        FLYME_PREFERENCES_NOTIFICATION,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(protectedSceneDidDisappear:)
                   name:FLMProtectedSceneDidDisappearNotification
                 object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(keyboardFrameWillChange:)
                   name:UIKeyboardWillChangeFrameNotification
                 object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(keyboardDidHide:)
                   name:UIKeyboardDidHideNotification
                 object:nil];

        // SpringBoard can keep reporting a portrait interface orientation while
        // the physical phone is already landscape. Generate device-orientation
        // updates explicitly and refresh only our overlay geometry/entry route;
        // the stable portrait application Scene contract is not touched here.
        [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(displayGeometryDidChange:)
                   name:UIDeviceOrientationDidChangeNotification
                 object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(displayGeometryDidChange:)
                   name:@"UIApplicationDidChangeStatusBarOrientationNotification"
                 object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(displayGeometryDidChange:)
                   name:@"UIApplicationDidChangeStatusBarFrameNotification"
                 object:nil];
        self.lastPortraitKeyboardHeight = 291.0;
        self.floatingKeyboardFrame = CGRectNull;
        // Dock presentation width is session-local. Every new dock transition
        // starts from the configured minimum size instead of restoring stale geometry.
        self.floatingDockWidth = FLMDefaultDockWidth;
        self.floatingDockedOnRight = [self isLandscapeFloatingSession] ? NO : YES;
        // Clear a route left by a previous SpringBoard generation before any
        // application-side UIKit adapter is allowed to change geometry.
        FLMPublishKeyboardState(nil, nil, 0);
        [self createWindows];
        [self reloadPreferences];
        [self displayGeometryDidChange:nil];
    });
}

- (void)createWindows {
    CGRect bounds = FLMSpringBoardWindowBounds();
    self.overlayWindow = (FLMOverlayWindow *)FLMCreateWindow(bounds);
    self.overlayWindow.windowLevel = UIWindowLevelAlert + 91.0;
    self.overlayWindow.backgroundColor = [UIColor clearColor];
    self.overlayWindow.userInteractionEnabled = NO;
    self.overlayWindow.rootViewController = [[FLMOverlayViewController alloc] init];
    self.overlayWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.overlayWindow.hidden = YES;

    self.wheelContainer = [[UIView alloc] initWithFrame:bounds];
    self.wheelContainer.userInteractionEnabled = YES;
    [self.overlayWindow.rootViewController.view addSubview:self.wheelContainer];

    self.wheelTapGesture =
        [[UITapGestureRecognizer alloc] initWithTarget:self
                                               action:@selector(handleWheelTap:)];
    self.wheelTapGesture.cancelsTouchesInView = YES;
    self.wheelTapGesture.delaysTouchesEnded = NO;
    [self.overlayWindow.rootViewController.view addGestureRecognizer:self.wheelTapGesture];

    [self createFloatingWindow];

    self.floatingDockTouchGateWindow = FLMCreateDockTouchGateWindow(bounds);
    // Stay below the wheel hotspot window, but above application and remote
    // presenter surfaces.  The gate's hit-test returns nil outside the dock
    // card and corner trigger, so it does not become a full-screen blocker.
    self.floatingDockTouchGateWindow.windowLevel = UIWindowLevelAlert + 119.0;
    self.floatingDockTouchGateWindow.backgroundColor = [UIColor clearColor];
    self.floatingDockTouchGateWindow.userInteractionEnabled = NO;
    self.floatingDockTouchGateWindow.rootViewController =
        [[FLMOverlayViewController alloc] init];
    self.floatingDockTouchGateWindow.rootViewController.view.backgroundColor =
        [UIColor clearColor];
    self.floatingDockTouchGateWindow.hidden = YES;

    self.hotspotWindow = FLMCreateHotspotWindow(bounds);
    // This transparent window is the wheel's arbitration boundary. It only
    // hit-tests the four corner ellipses, but it stays above the floating card
    // and keyboard forwarding windows so those routes cannot win first.
    self.hotspotWindow.windowLevel = UIWindowLevelAlert + 120.0;
    self.hotspotWindow.backgroundColor = [UIColor clearColor];
    UIViewController *hotspotController = [[UIViewController alloc] init];
    hotspotController.view.backgroundColor = [UIColor clearColor];
    self.hotspotWindow.rootViewController = hotspotController;

    // Bottom-center home-dock zone. The recognizer must live on this window's
    // view (UIKit in-window arbitration, not the system gesture manager) so a
    // recognized long-press gates the real home gesture off instead of losing
    // the arbitration race against it. The hit-test re-validates every touch.
    self.homeDockWindow = FLMCreateHomeDockWindow(bounds);
    self.homeDockWindow.windowLevel = UIWindowLevelAlert + 90.0;
    self.homeDockWindow.backgroundColor = [UIColor clearColor];
    UIViewController *homeDockController = [[UIViewController alloc] init];
    homeDockController.view.backgroundColor = [UIColor clearColor];
    self.homeDockWindow.rootViewController = homeDockController;

    self.cornerGesture =
        [[FLMCornerGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(handleCornerGesture:)];
    self.cornerGesture.delegate = self;
    self.cornerGesture.cancelsTouchesInView = YES;
    self.cornerGesture.numberOfTouchesRequired = 1;
    self.cornerGesture.minimumPressDuration = 0.12;
    self.cornerGesture.allowableMovement = CGFLOAT_MAX;

    self.cornerGuardGesture =
        [[FLMCornerGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleCornerGuardGesture:)];
    self.cornerGuardGesture.delegate = self;
    self.cornerGuardGesture.cancelsTouchesInView = YES;
    self.cornerGuardGesture.delaysTouchesBegan = NO;
    self.cornerGuardGesture.delaysTouchesEnded = NO;
    self.cornerGuardGesture.numberOfTouchesRequired = 1;
    self.cornerGuardGesture.minimumPressDuration = 0.0;
    self.cornerGuardGesture.allowableMovement = CGFLOAT_MAX;

    // Landscape gets an always-available UIKit/window ingress in addition to
    // the private system-manager pair. Old 0.9.45-era devices demonstrated
    // that _UISystemGestureManager may accept registration yet skip the
    // delegate/touch route after a portrait->landscape transition. Keeping a
    // second pair on the hotspot window makes the entry independent of that
    // private callback quirk while leaving portrait behavior unchanged.
    self.landscapeCornerGesture =
        [[FLMCornerGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(handleCornerGesture:)];
    self.landscapeCornerGesture.delegate = self;
    self.landscapeCornerGesture.cancelsTouchesInView = YES;
    self.landscapeCornerGesture.numberOfTouchesRequired = 1;
    self.landscapeCornerGesture.minimumPressDuration = 0.12;
    self.landscapeCornerGesture.allowableMovement = CGFLOAT_MAX;

    self.landscapeCornerGuardGesture =
        [[FLMCornerGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(handleCornerGuardGesture:)];
    self.landscapeCornerGuardGesture.delegate = self;
    self.landscapeCornerGuardGesture.cancelsTouchesInView = YES;
    self.landscapeCornerGuardGesture.delaysTouchesBegan = NO;
    self.landscapeCornerGuardGesture.delaysTouchesEnded = NO;
    self.landscapeCornerGuardGesture.numberOfTouchesRequired = 1;
    self.landscapeCornerGuardGesture.minimumPressDuration = 0.0;
    self.landscapeCornerGuardGesture.allowableMovement = CGFLOAT_MAX;

    // Separate global instances are required because _UISystemGestureManager
    // takes ownership of a recognizer's view. The local pair remains attached
    // to the physical hotspot window; this pair stays alive through stale
    // portrait reports from SpringBoard's own Scene.
    self.landscapeGlobalCornerGesture =
        [[FLMCornerGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(handleCornerGesture:)];
    self.landscapeGlobalCornerGesture.delegate = self;
    self.landscapeGlobalCornerGesture.cancelsTouchesInView = YES;
    self.landscapeGlobalCornerGesture.numberOfTouchesRequired = 1;
    self.landscapeGlobalCornerGesture.minimumPressDuration = 0.12;
    self.landscapeGlobalCornerGesture.allowableMovement = CGFLOAT_MAX;

    self.landscapeGlobalCornerGuardGesture =
        [[FLMCornerGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleCornerGuardGesture:)];
    self.landscapeGlobalCornerGuardGesture.delegate = self;
    self.landscapeGlobalCornerGuardGesture.cancelsTouchesInView = YES;
    self.landscapeGlobalCornerGuardGesture.delaysTouchesBegan = NO;
    self.landscapeGlobalCornerGuardGesture.delaysTouchesEnded = NO;
    self.landscapeGlobalCornerGuardGesture.numberOfTouchesRequired = 1;
    self.landscapeGlobalCornerGuardGesture.minimumPressDuration = 0.0;
    self.landscapeGlobalCornerGuardGesture.allowableMovement = CGFLOAT_MAX;

    // A second wheel pair attached to the floating window itself. The system
    // gesture manager pair can be arbitrated away by the card gestures when a
    // card is up, and shouldReceiveTouch: is not reliably consulted for
    // system-manager gestures. In-window recognizers always run UIKit's
    // standard delegate arbitration, so the wheel keeps its corner in every
    // card mode: centered (the window owns the whole screen), docked and
    // hidden (the window hit-tests the corner trigger before pass-through).
    self.floatingCornerGuardGesture =
        [[FLMCornerGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleCornerGuardGesture:)];
    self.floatingCornerGuardGesture.delegate = self;
    self.floatingCornerGuardGesture.cancelsTouchesInView = YES;
    self.floatingCornerGuardGesture.delaysTouchesBegan = NO;
    self.floatingCornerGuardGesture.delaysTouchesEnded = NO;
    self.floatingCornerGuardGesture.numberOfTouchesRequired = 1;
    self.floatingCornerGuardGesture.minimumPressDuration = 0.0;
    self.floatingCornerGuardGesture.allowableMovement = CGFLOAT_MAX;
    [self.floatingWindow.rootViewController.view
        addGestureRecognizer:self.floatingCornerGuardGesture];

    self.floatingCornerGesture =
        [[FLMCornerGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleCornerGesture:)];
    self.floatingCornerGesture.delegate = self;
    self.floatingCornerGesture.cancelsTouchesInView = YES;
    self.floatingCornerGesture.numberOfTouchesRequired = 1;
    self.floatingCornerGesture.minimumPressDuration = 0.12;
    self.floatingCornerGesture.allowableMovement = CGFLOAT_MAX;
    [self.floatingWindow.rootViewController.view
        addGestureRecognizer:self.floatingCornerGesture];

    self.modalGesture =
        [[FLMCornerGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(handleModalGesture:)];
    self.modalGesture.delegate = self;
    self.modalGesture.cancelsTouchesInView = YES;
    self.modalGesture.numberOfTouchesRequired = 1;
    self.modalGesture.minimumPressDuration = 0.0;
    self.modalGesture.allowableMovement = CGFLOAT_MAX;
    self.modalGesture.enabled = NO;

    self.floatingExclusiveGesture =
        [[FLMCornerGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingExclusiveGesture:)];
    self.floatingExclusiveGesture.delegate = self;
    // The system-wide recognizer only accepts touches that began outside the
    // card/handle/keyboard domain. Once accepted it must consume that outside
    // tap so the Home Screen does not also activate an icon underneath.
    self.floatingExclusiveGesture.cancelsTouchesInView = YES;
    self.floatingExclusiveGesture.delaysTouchesBegan = NO;
    self.floatingExclusiveGesture.delaysTouchesEnded = NO;
    self.floatingExclusiveGesture.numberOfTouchesRequired = 1;
    self.floatingExclusiveGesture.minimumPressDuration = 0.0;
    self.floatingExclusiveGesture.allowableMovement = CGFLOAT_MAX;
    self.floatingExclusiveGesture.enabled = NO;

    self.floatingDockInputGesture =
        [[FLMCornerGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingDockInputGesture:)];
    self.floatingDockInputGesture.delegate = self;
    self.floatingDockInputGesture.cancelsTouchesInView = YES;
    // This recognizer is enabled only while the card/handle owns the touch
    // domain. Delay the underlying application's touch-began until the
    // immediate dock recognizer has arbitrated the stream; otherwise a
    // button or scroll view below can consume the first sample before the
    // system-registered gesture cancels it.
    self.floatingDockInputGesture.delaysTouchesBegan = YES;
    self.floatingDockInputGesture.delaysTouchesEnded = NO;
    self.floatingDockInputGesture.numberOfTouchesRequired = 1;
    self.floatingDockInputGesture.minimumPressDuration = 0.0;
    self.floatingDockInputGesture.allowableMovement = CGFLOAT_MAX;
    self.floatingDockInputGesture.enabled = NO;

    // Docks the frontmost app from the bottom-center home-indicator zone. The
    // system home gesture wins any swipe that starts moving quickly; only a
    // stationary press (long-press) beats it, then the upward drag past the
    // swipe threshold grabs the frontmost app into the upper-right dock. The
    // recognizer lives on the dedicated zone window: once it begins, UIKit's
    // gate makes the system home gesture fail, which the system gesture
    // manager pair (0.8.68) could not do.
    self.homeDockGesture =
        [[FLMDockGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleHomeDockGesture:)];
    self.homeDockGesture.delegate = self;
    self.homeDockGesture.cancelsTouchesInView = YES;
    self.homeDockGesture.delaysTouchesBegan = NO;
    self.homeDockGesture.delaysTouchesEnded = NO;
    [self.homeDockWindow.rootViewController.view
        addGestureRecognizer:self.homeDockGesture];

    self.usesSystemGestureManager = [self registerGlobalCornerGesture];
    // Landscape always owns a separate UIKit/window route. It must not depend
    // on the private manager delivering callbacks after a Scene handoff.
    [self.hotspotWindow.rootViewController.view
        addGestureRecognizer:self.landscapeCornerGuardGesture];
    [self.hotspotWindow.rootViewController.view
        addGestureRecognizer:self.landscapeCornerGesture];
    if (!self.usesSystemGestureManager) {
        // The private manager is unavailable, so the original wheel pair owns
        // the transparent hotspot window for both orientations.
        [self.hotspotWindow.rootViewController.view
            addGestureRecognizer:self.cornerGuardGesture];
        [self.hotspotWindow.rootViewController.view
            addGestureRecognizer:self.cornerGesture];
        [self.floatingDockTouchGateWindow.rootViewController.view
            addGestureRecognizer:self.floatingDockInputGesture];
    }
    [self updateWindowFrames];
}

- (void)createFloatingWindow {
    CGRect bounds = FLMSpringBoardWindowBounds();
    self.floatingWindow = FLMCreateFloatingWindow(bounds);
    self.floatingWindow.windowLevel = UIWindowLevelAlert + 92.0;
    self.floatingWindow.backgroundColor = [UIColor clearColor];
    self.floatingWindow.rootViewController = [[FLMOverlayViewController alloc] init];
    self.floatingWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.floatingWindow.hidden = YES;
    ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame = CGRectNull;

    self.floatingPresentationView = [[UIView alloc] initWithFrame:bounds];
    self.floatingPresentationView.backgroundColor = [UIColor clearColor];
    self.floatingPresentationView.userInteractionEnabled = YES;
    [self.floatingWindow.rootViewController.view
        addSubview:self.floatingPresentationView];

    self.floatingDimView = [[UIView alloc] initWithFrame:bounds];
    self.floatingDimView.backgroundColor =
        [UIColor colorWithWhite:0.0 alpha:0.12];
    [self.floatingPresentationView addSubview:self.floatingDimView];

    self.floatingDockShadowView = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingDockShadowView.backgroundColor =
        [UIColor colorWithWhite:0.0 alpha:0.01];
    self.floatingDockShadowView.userInteractionEnabled = NO;
    self.floatingDockShadowView.hidden = YES;
    self.floatingDockShadowView.alpha = 0.0;
    self.floatingDockShadowView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.floatingDockShadowView.layer.shadowOpacity = 0.18;
    self.floatingDockShadowView.layer.shadowRadius = 14.0;
    self.floatingDockShadowView.layer.shadowOffset = CGSizeMake(0.0, 3.0);
    [self.floatingPresentationView addSubview:self.floatingDockShadowView];

    self.floatingContainer = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingContainer.backgroundColor = [UIColor blackColor];
    self.floatingContainer.layer.cornerRadius = 22.0;
    self.floatingContainer.layer.masksToBounds = YES;
    [self.floatingPresentationView addSubview:self.floatingContainer];

    self.floatingStatusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.floatingStatusLabel.text = @"正在打开…";
    self.floatingStatusLabel.textAlignment = NSTextAlignmentCenter;
    self.floatingStatusLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    self.floatingStatusLabel.font = [UIFont systemFontOfSize:15.0
                                                     weight:UIFontWeightMedium];
    self.floatingStatusLabel.hidden = YES;
    [self.floatingContainer addSubview:self.floatingStatusLabel];

    self.floatingLaunchCoverView = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingLaunchCoverView.backgroundColor =
        [UIColor secondarySystemBackgroundColor];
    self.floatingLaunchCoverView.hidden = YES;
    self.floatingLaunchCoverView.userInteractionEnabled = NO;
    [self.floatingContainer addSubview:self.floatingLaunchCoverView];

    self.floatingLaunchIconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.floatingLaunchIconView.contentMode = UIViewContentModeScaleAspectFit;
    self.floatingLaunchIconView.layer.cornerRadius = 16.0;
    self.floatingLaunchIconView.layer.masksToBounds = YES;
    [self.floatingLaunchCoverView addSubview:self.floatingLaunchIconView];

    self.floatingDockInteractionShield = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingDockInteractionShield.backgroundColor = [UIColor clearColor];
    self.floatingDockInteractionShield.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.floatingDockInteractionShield.hidden = YES;
    self.floatingDockInteractionShield.userInteractionEnabled = NO;
    [self.floatingContainer addSubview:self.floatingDockInteractionShield];

    self.floatingHandle = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingHandle.backgroundColor = [UIColor clearColor];
    self.floatingHandleBar = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingHandleBar.backgroundColor =
        [UIColor colorWithWhite:1.0 alpha:0.72];
    self.floatingHandleBar.layer.cornerRadius = 2.5;
    self.floatingHandleBar.userInteractionEnabled = NO;
    [self.floatingHandle addSubview:self.floatingHandleBar];
    [self.floatingPresentationView addSubview:self.floatingHandle];

    // Keep the resize interaction as a transparent hit target.  The previous
    // L-shaped CAShapeLayer was only a visual affordance and is intentionally
    // not recreated.
    self.floatingResizeHandle = [[UIView alloc] initWithFrame:CGRectZero];
    self.floatingResizeHandle.backgroundColor = [UIColor clearColor];
    self.floatingResizeHandle.hidden = YES;
    self.floatingResizeHandle.userInteractionEnabled = YES;
    [self.floatingPresentationView addSubview:self.floatingResizeHandle];

    self.floatingBackdropTap =
        [[FLMOutsideTapGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingBackdropTap:)];
    self.floatingBackdropTap.protectedView = self.floatingContainer;
    self.floatingBackdropTap.secondaryProtectedView = self.floatingHandle;
    self.floatingBackdropTap.delegate = self;
    [self.floatingPresentationView
        addGestureRecognizer:self.floatingBackdropTap];

    self.floatingHandlePress =
        [[UILongPressGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingHandlePress:)];
    self.floatingHandlePress.minimumPressDuration = 0.12;
    self.floatingHandlePress.allowableMovement = CGFLOAT_MAX;
    self.floatingHandlePress.cancelsTouchesInView = YES;
    [self.floatingHandle addGestureRecognizer:self.floatingHandlePress];

    self.floatingHandleTap =
        [[UITapGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingHandleTap:)];
    self.floatingHandleTap.cancelsTouchesInView = YES;
    [self.floatingHandleTap
        requireGestureRecognizerToFail:self.floatingHandlePress];
    [self.floatingHandle addGestureRecognizer:self.floatingHandleTap];
    self.floatingHandle.userInteractionEnabled = YES;

    self.floatingDockDragPress =
        [[UILongPressGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingDockDragPress:)];
    self.floatingDockDragPress.minimumPressDuration = 0.10;
    self.floatingDockDragPress.allowableMovement = CGFLOAT_MAX;
    self.floatingDockDragPress.cancelsTouchesInView = YES;
    self.floatingDockDragPress.enabled = NO;
    [self.floatingDockInteractionShield
        addGestureRecognizer:self.floatingDockDragPress];

    self.floatingDockTap =
        [[UITapGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleFloatingDockTap:)];
    self.floatingDockTap.cancelsTouchesInView = YES;
    self.floatingDockTap.enabled = NO;
    [self.floatingDockTap
        requireGestureRecognizerToFail:self.floatingDockDragPress];
    [self.floatingDockInteractionShield addGestureRecognizer:self.floatingDockTap];

    FLMFloatingWindow *floatingWindow =
        (FLMFloatingWindow *)self.floatingWindow;
    floatingWindow.floatingContentView = self.floatingContainer;
    floatingWindow.floatingPrimaryControlView = self.floatingHandle;
    floatingWindow.floatingSecondaryControlView = self.floatingResizeHandle;
    [self layoutFloatingWindow];
}

- (BOOL)registerGlobalCornerGesture {
    Class managerClass = NSClassFromString(@"_UISystemGestureManager");
    FLMSystemGestureManager *manager =
        (FLMSystemGestureManager *)[managerClass sharedInstance];
    FLMDisplayConfiguration *displayConfiguration =
        [[UIScreen mainScreen] displayConfiguration];
    id identity = [displayConfiguration identity];
    SEL registrationSelector =
        @selector(addGestureRecognizer:toDisplayWithIdentity:);
    if (!manager || !identity || ![manager respondsToSelector:registrationSelector]) {
        return NO;
    }

    // Keep the wheel pair in the private system gesture manager so it remains
    // global while another application's Scene is frontmost. The floating
    // window owns a second pair for centered/docked card-local arbitration.
    [manager addGestureRecognizer:self.cornerGuardGesture
            toDisplayWithIdentity:identity];
    [manager addGestureRecognizer:self.cornerGesture toDisplayWithIdentity:identity];
    [manager addGestureRecognizer:self.landscapeGlobalCornerGuardGesture
            toDisplayWithIdentity:identity];
    [manager addGestureRecognizer:self.landscapeGlobalCornerGesture
            toDisplayWithIdentity:identity];
    [manager addGestureRecognizer:self.modalGesture toDisplayWithIdentity:identity];
    [manager addGestureRecognizer:self.floatingExclusiveGesture
            toDisplayWithIdentity:identity];
    [manager addGestureRecognizer:self.floatingDockInputGesture
            toDisplayWithIdentity:identity];
    self.systemGestureManager = manager;
    self.displayIdentity = identity;
    return YES;
}

- (void)reloadPreferences {
    CFPreferencesSynchronize(FLYME_PREFERENCES_DOMAIN,
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);
    id enabledValue = FLMCopyPreference(@"enabled");
    id itemsValue = FLMCopyPreference(@"wheelItems");
    id radiusValue = FLMCopyPreference(@"wheelRadius");
    id iconSizeValue = FLMCopyPreference(@"wheelIconSize");
    // Use a new key so values left by the retired experimental implementation
    // cannot change the restored 58x65 default after this upgrade.
    id cornerTriggerSizeValue = FLMCopyPreference(@"cornerTriggerSizeV2");
    id centeredCardWidthValue = FLMCopyPreference(@"centeredCardWidth");
    id centeredCardTopCropValue = FLMCopyPreference(@"centeredCardTopCrop");
    id centeredCardBottomCropValue = FLMCopyPreference(@"centeredCardBottomCrop");
    id centeredDockSwipeThresholdValue =
        FLMCopyPreference(@"centeredDockSwipeThreshold");
    id dockedShrinkAmountValue = FLMCopyPreference(@"dockedShrinkAmount");
    self.enabled = [enabledValue isKindOfClass:[NSNumber class]] && [enabledValue boolValue];
    NSArray *configuredItems =
        [itemsValue isKindOfClass:[NSArray class]] ? itemsValue : @[];
    NSMutableArray<NSString *> *runtimeItems =
        [NSMutableArray arrayWithCapacity:configuredItems.count];
    for (id candidate in configuredItems) {
        if (![candidate isKindOfClass:[NSString class]] ||
            [(NSString *)candidate length] == 0 ||
            [(NSString *)candidate isEqualToString:
                FLMRemovedLegacyWheelItemIdentifier]) {
            continue;
        }
        [runtimeItems addObject:(NSString *)candidate];
    }
    self.itemIdentifiers = [runtimeItems copy];
    CGFloat requestedRadius =
        [radiusValue isKindOfClass:[NSNumber class]]
            ? [radiusValue doubleValue]
            : FLMDefaultWheelRadius;
    CGFloat requestedIconSize =
        [iconSizeValue isKindOfClass:[NSNumber class]]
            ? [iconSizeValue doubleValue]
            : FLMDefaultWheelIconSize;
    self.wheelRadius =
        MAX(FLMMinimumWheelRadius, MIN(FLMMaximumWheelRadius, requestedRadius));
    self.wheelIconSize =
        MAX(FLMMinimumWheelIconSize,
            MIN(FLMMaximumWheelIconSize, requestedIconSize));
    CGFloat requestedCornerTriggerSize =
        [cornerTriggerSizeValue isKindOfClass:[NSNumber class]]
            ? [cornerTriggerSizeValue doubleValue]
            : FLMDefaultCornerTriggerSize;
    FLMCornerTriggerSize =
        FLMClampedCornerTriggerSize(requestedCornerTriggerSize);
    CGFloat requestedCenteredCardWidth =
        [centeredCardWidthValue isKindOfClass:[NSNumber class]]
            ? [centeredCardWidthValue doubleValue]
            : FLMCenteredCardWidth;
    self.centeredCardWidth =
        MAX(FLMMinimumCenteredCardWidth,
            MIN(FLMMaximumCenteredCardWidth, requestedCenteredCardWidth));
    CGFloat requestedTopCrop =
        [centeredCardTopCropValue isKindOfClass:[NSNumber class]]
            ? [centeredCardTopCropValue doubleValue]
            : FLMCenteredCardTopCrop;
    CGFloat requestedBottomCrop =
        [centeredCardBottomCropValue isKindOfClass:[NSNumber class]]
            ? [centeredCardBottomCropValue doubleValue]
            : FLMCenteredCardBottomCrop;
    self.centeredCardTopCrop =
        MAX(FLMMinimumCenteredCardCrop,
            MIN(FLMMaximumCenteredCardCrop, requestedTopCrop));
    self.centeredCardBottomCrop =
        MAX(FLMMinimumCenteredCardCrop,
            MIN(FLMMaximumCenteredCardCrop, requestedBottomCrop));
    CGFloat requestedSwipeThreshold =
        [centeredDockSwipeThresholdValue isKindOfClass:[NSNumber class]]
            ? [centeredDockSwipeThresholdValue doubleValue]
            : FLMDefaultCenteredDockSwipeThreshold;
    self.centeredDockSwipeThreshold =
        MAX(FLMMinimumCenteredDockSwipeThreshold,
            MIN(FLMMaximumCenteredDockSwipeThreshold, requestedSwipeThreshold));
    CGFloat requestedDockShrink =
        [dockedShrinkAmountValue isKindOfClass:[NSNumber class]]
            ? [dockedShrinkAmountValue doubleValue]
            : FLMDefaultDockedShrinkAmount;
    self.dockedShrinkAmount =
        MAX(FLMMinimumDockedShrinkAmount,
            MIN(FLMMaximumDockedShrinkAmount, requestedDockShrink));
    self.cornerGuardGesture.enabled = self.enabled;
    self.cornerGesture.enabled = self.enabled;
    self.landscapeCornerGuardGesture.enabled = self.enabled;
    self.landscapeCornerGesture.enabled = self.enabled;
    self.landscapeGlobalCornerGuardGesture.enabled = self.enabled;
    self.landscapeGlobalCornerGesture.enabled = self.enabled;
    self.floatingCornerGuardGesture.enabled = self.enabled;
    self.floatingCornerGesture.enabled = self.enabled;
    if (!self.enabled) {
        self.modalGesture.enabled = NO;
    }
    [self refreshWheelPriorityWindow];
    if (!self.enabled) {
        [self dismissWheelLaunchingItem:nil];
        [self closeFloatingWindowKeepingApplication:YES];
    } else if (self.floatingWindow && !self.floatingWindow.hidden &&
               !self.floatingInteractiveFullscreenTransition) {
        // Settings changes are presentation-only. Re-layout the existing
        // card if it is visible, while leaving the application's full-screen
        // Scene, responder route, and keyboard coordinate system untouched.
        [self layoutFloatingWindow];
    }
}

- (void)refreshWheelPriorityWindow {
    BOOL canReceive = self.enabled &&
                      !self.wheelPinned &&
                      self.itemIdentifiers.count > 0;
    BOOL landscape = FLMDisplayIsLandscape();
    self.hotspotWindow.windowLevel = UIWindowLevelAlert + 120.0;
    // Portrait recognizers remain exactly as 0.9.63 left them. The landscape
    // delegate gate, not an orientation-triggered enabled flip, decides which
    // physical route owns a touch.
    self.cornerGuardGesture.enabled = self.enabled;
    self.cornerGesture.enabled = self.enabled;
    self.landscapeCornerGuardGesture.enabled = self.enabled;
    self.landscapeCornerGesture.enabled = self.enabled;
    self.landscapeGlobalCornerGuardGesture.enabled = self.enabled;
    self.landscapeGlobalCornerGesture.enabled = self.enabled;

    if (landscape) {
        self.hotspotWindow.hotspotsEnabled = canReceive;
        self.hotspotWindow.hidden = !self.enabled;
        return;
    }

    self.hotspotWindow.hotspotsEnabled =
        canReceive && !self.usesSystemGestureManager;
    self.hotspotWindow.hidden =
        !self.enabled || self.usesSystemGestureManager;
}

- (void)updateWindowFrames {
    CGRect visualBounds = FLMVisualScreenBounds();
    CGRect windowBounds = FLMSpringBoardWindowBounds();
    BOOL landscape = FLMBoundsAreLandscape(visualBounds);
    CGRect wheelWindowBounds = windowBounds;
    UIView *overlayRoot = self.overlayWindow.rootViewController.view;
    [overlayRoot layoutIfNeeded];
    UIInterfaceOrientation orientation =
        landscape
            ? FLMLandscapeOrientationForSafeInsets(overlayRoot.safeAreaInsets)
            : UIInterfaceOrientationPortrait;

    self.overlayWindow.frame = wheelWindowBounds;
    // The root view must stay on SpringBoard's own scene bounds. That is what
    // lets FLMConfigureVisualCanvas recognise the portrait-root/landscape-visual
    // pair and rotate only the child canvas; the system already supplies the
    // rotation between the scene and the display.
    overlayRoot.frame = self.overlayWindow.bounds;
    FLMConfigureVisualCanvas(self.wheelContainer, overlayRoot, visualBounds,
                             orientation);

    self.hotspotWindow.frame = wheelWindowBounds;
    self.hotspotWindow.rootViewController.view.frame =
        self.hotspotWindow.bounds;
    self.hotspotWindow.visualBounds = visualBounds;
    self.hotspotWindow.visualOrientation = orientation;

    self.homeDockWindow.frame = wheelWindowBounds;

    // The floating stack shares the wheel window's scene bounds, and its
    // presentation canvas is rotated the same way. The card still keeps its
    // portrait-proportion content because `landscapeFloatingFrame` derives it
    // from the portrait card settings.
    self.floatingWindow.frame = wheelWindowBounds;
    FLMFloatingWindow *floatingWindow =
        (FLMFloatingWindow *)self.floatingWindow;
    floatingWindow.visualBounds = visualBounds;
    floatingWindow.visualOrientation = orientation;
    self.floatingWindow.rootViewController.view.frame = self.floatingWindow.bounds;
    FLMConfigureVisualCanvas(self.floatingPresentationView,
                             self.floatingWindow.rootViewController.view,
                             visualBounds, orientation);
    self.floatingDimView.frame = self.floatingPresentationView.bounds;

    self.floatingDockTouchGateWindow.frame = wheelWindowBounds;
    self.floatingDockTouchGateWindow.visualBounds = visualBounds;
    self.floatingDockTouchGateWindow.visualOrientation = orientation;

    [self layoutFloatingWindow];
    [self updateFloatingDockTouchGate];
}

- (void)displayGeometryDidChange:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect visualBounds = FLMVisualScreenBounds();
        CGRect windowBounds = FLMSpringBoardWindowBounds();
        BOOL landscape = FLMBoundsAreLandscape(visualBounds);
        CGRect wheelWindowBounds = windowBounds;
        UIView *overlayRoot = self.overlayWindow.rootViewController.view;
        [overlayRoot layoutIfNeeded];
        UIInterfaceOrientation orientation =
            landscape
                ? FLMLandscapeOrientationForSafeInsets(
                      overlayRoot.safeAreaInsets)
                : UIInterfaceOrientationPortrait;

        // SpringBoard's UIWindow/root coordinate space can remain portrait
        // (390x844) while a foreground application owns the display in
        // landscape (844x390). Keep the windows and their root views on that
        // scene space; only the presentation canvases are rotated into a stable
        // physical-display coordinate space.
        self.overlayWindow.frame = wheelWindowBounds;
        overlayRoot.frame = self.overlayWindow.bounds;
        FLMConfigureVisualCanvas(self.wheelContainer, overlayRoot,
                                 visualBounds, orientation);

        self.hotspotWindow.frame = wheelWindowBounds;
        self.hotspotWindow.rootViewController.view.frame =
            self.hotspotWindow.bounds;
        self.hotspotWindow.visualBounds = visualBounds;
        self.hotspotWindow.visualOrientation = orientation;
        self.homeDockWindow.frame = wheelWindowBounds;

        if (self.floatingWindow.hidden) {
            self.floatingWindow.frame = wheelWindowBounds;
            FLMFloatingWindow *floatingWindow =
                (FLMFloatingWindow *)self.floatingWindow;
            floatingWindow.visualBounds = visualBounds;
            floatingWindow.visualOrientation = orientation;
            self.floatingWindow.rootViewController.view.frame =
                self.floatingWindow.bounds;
            FLMConfigureVisualCanvas(
                self.floatingPresentationView,
                self.floatingWindow.rootViewController.view,
                visualBounds, orientation);
            self.floatingDimView.frame = self.floatingPresentationView.bounds;

            self.floatingDockTouchGateWindow.frame = wheelWindowBounds;
            self.floatingDockTouchGateWindow.visualBounds = visualBounds;
            self.floatingDockTouchGateWindow.visualOrientation = orientation;
        }
        [self refreshWheelPriorityWindow];

        FLMEnqueueDiagnosticLine(
            @"sb display-geometry-refresh notification=%@ visual=%@ window=%@ wheelWindow=%@ overlayRoot=%@ deviceOrientation=%ld statusOrientation=%ld presentationOrientation=%ld landscape=%d systemManager=%d hotspotHidden=%d hotspotEnabled=%d",
            notification.name ?: @"<manual>",
            NSStringFromCGRect(visualBounds),
            NSStringFromCGRect(windowBounds),
            NSStringFromCGRect(wheelWindowBounds),
            NSStringFromCGRect(overlayRoot.bounds),
            (long)[UIDevice currentDevice].orientation,
            (long)FLMReportedSceneOrientation(),
            (long)orientation,
            FLMBoundsAreLandscape(visualBounds),
            self.usesSystemGestureManager,
            self.hotspotWindow.hidden,
            self.hotspotWindow.hotspotsEnabled);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.18 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!self.floatingWindow.hidden) {
                return;
            }
            CGRect settledBounds = FLMVisualScreenBounds();
            CGRect settledWindowBounds = FLMSpringBoardWindowBounds();
            BOOL settledLandscape = FLMBoundsAreLandscape(settledBounds);
            CGRect settledWheelWindowBounds = settledWindowBounds;
            UIView *settledRoot =
                self.overlayWindow.rootViewController.view;
            [settledRoot layoutIfNeeded];
            UIInterfaceOrientation settledOrientation =
                settledLandscape
                    ? FLMLandscapeOrientationForSafeInsets(
                          settledRoot.safeAreaInsets)
                    : UIInterfaceOrientationPortrait;

            self.overlayWindow.frame = settledWheelWindowBounds;
            settledRoot.frame = self.overlayWindow.bounds;
            FLMConfigureVisualCanvas(self.wheelContainer, settledRoot,
                                     settledBounds, settledOrientation);

            self.hotspotWindow.frame = settledWheelWindowBounds;
            self.hotspotWindow.rootViewController.view.frame =
                self.hotspotWindow.bounds;
            self.hotspotWindow.visualBounds = settledBounds;
            self.hotspotWindow.visualOrientation = settledOrientation;
            self.homeDockWindow.frame = settledWheelWindowBounds;

            self.floatingWindow.frame = settledWheelWindowBounds;
            FLMFloatingWindow *floatingWindow =
                (FLMFloatingWindow *)self.floatingWindow;
            floatingWindow.visualBounds = settledBounds;
            floatingWindow.visualOrientation = settledOrientation;
            self.floatingWindow.rootViewController.view.frame =
                self.floatingWindow.bounds;
            FLMConfigureVisualCanvas(
                self.floatingPresentationView,
                self.floatingWindow.rootViewController.view,
                settledBounds, settledOrientation);
            self.floatingDimView.frame = self.floatingPresentationView.bounds;

            self.floatingDockTouchGateWindow.frame = settledWheelWindowBounds;
            self.floatingDockTouchGateWindow.visualBounds = settledBounds;
            self.floatingDockTouchGateWindow.visualOrientation =
                settledOrientation;

            [self refreshWheelPriorityWindow];
            FLMEnqueueDiagnosticLine(
                @"sb display-geometry-settled visual=%@ window=%@ wheelWindow=%@ overlayRoot=%@ presentationOrientation=%ld landscape=%d hotspotHidden=%d hotspotEnabled=%d",
                NSStringFromCGRect(settledBounds),
                NSStringFromCGRect(settledWindowBounds),
                NSStringFromCGRect(settledWheelWindowBounds),
                NSStringFromCGRect(settledRoot.bounds),
                (long)settledOrientation,
                FLMBoundsAreLandscape(settledBounds),
                self.hotspotWindow.hidden,
                self.hotspotWindow.hotspotsEnabled);
        });
    });
}

- (BOOL)resolveLandscapeCornerGesture:(UIGestureRecognizer *)gesture
                                touch:(UITouch *)touch
                        resolvedPoint:(CGPoint *)resolvedPoint
                     resolvedFromRight:(BOOL *)resolvedFromRight {
    if (!gesture || !self.enabled || self.wheelPinned ||
        self.itemIdentifiers.count == 0 || FLMDeviceIsLocked()) {
        return NO;
    }
    CGRect bounds = self.landscapeIngressActive
                        ? self.landscapeIngressBounds
                        : FLMVisualScreenBounds();
    if (!FLMBoundsAreLandscape(bounds)) {
        return NO;
    }

    FLMCornerGestureRecognizer *cornerRecognizer =
        [gesture isKindOfClass:[FLMCornerGestureRecognizer class]]
            ? (FLMCornerGestureRecognizer *)gesture
            : nil;
    CGPoint rawPoint = CGPointZero;
    if (touch) {
        rawPoint = [touch locationInView:nil];
    } else if (cornerRecognizer && cornerRecognizer.flmHasFirstRawPoint) {
        rawPoint = cornerRecognizer.flmFirstRawPoint;
    } else {
        rawPoint = [gesture locationInView:nil];
    }

    FLMLandscapeRawCoordinateMode lockedMode =
        cornerRecognizer &&
                cornerRecognizer.flmLandscapeRawCoordinateMode !=
                    FLMLandscapeRawCoordinateModeUnknown
            ? cornerRecognizer.flmLandscapeRawCoordinateMode
            : FLMLandscapeRawCoordinateModeUnknown;
    if (lockedMode == FLMLandscapeRawCoordinateModeUnknown &&
        self.landscapeIngressActive &&
        self.landscapeIngressRawMode != FLMLandscapeRawCoordinateModeUnknown) {
        lockedMode = self.landscapeIngressRawMode;
    }
    FLMLandscapeRawCoordinateMode modes[] = {
        FLMLandscapeRawCoordinateModeCurrent,
        FLMLandscapeRawCoordinateModeFixedLandscapeLeft,
        FLMLandscapeRawCoordinateModeFixedLandscapeRight,
    };
    NSUInteger modeCount = sizeof(modes) / sizeof(modes[0]);
    FLMLandscapeRawCoordinateMode resolvedMode =
        FLMLandscapeRawCoordinateModeUnknown;
    CGPoint resolved = CGPointZero;
    BOOL resolvedRight = NO;
    for (NSUInteger index = 0; index < modeCount; index++) {
        FLMLandscapeRawCoordinateMode mode =
            lockedMode != FLMLandscapeRawCoordinateModeUnknown
                ? lockedMode
                : modes[index];
        CGPoint candidate =
            FLMLandscapeVisualPointFromRawPoint(rawPoint, bounds, mode);
        BOOL fromRight = NO;
        if (!FLMPointInsideCornerTrigger(candidate, bounds, &fromRight)) {
            if (lockedMode != FLMLandscapeRawCoordinateModeUnknown) {
                break;
            }
            continue;
        }
        resolvedMode = mode;
        resolved = candidate;
        resolvedRight = fromRight;
        break;
    }
    if (resolvedMode == FLMLandscapeRawCoordinateModeUnknown) {
        FLMEnqueueDiagnosticLine(
            @"sb landscape-ingress rejected raw={%.1f,%.1f} bounds=%@ locked=%@ device=%ld",
            rawPoint.x, rawPoint.y, NSStringFromCGRect(bounds),
            FLMLandscapeRawCoordinateModeName(lockedMode),
            (long)[UIDevice currentDevice].orientation);
        return NO;
    }

    if (cornerRecognizer) {
        cornerRecognizer.flmLandscapeRawCoordinateMode = resolvedMode;
        cornerRecognizer.flmFirstTouchPoint = resolved;
        cornerRecognizer.flmHasFirstTouchPoint = YES;
    }
    self.landscapeIngressRawMode = resolvedMode;
    self.landscapeIngressBounds = bounds;
    if (gesture == self.landscapeCornerGesture ||
        gesture == self.landscapeCornerGuardGesture ||
        gesture == self.landscapeGlobalCornerGesture ||
        gesture == self.landscapeGlobalCornerGuardGesture) {
        self.landscapeIngressActive = YES;
    }
    if (resolvedPoint) {
        *resolvedPoint = resolved;
    }
    if (resolvedFromRight) {
        *resolvedFromRight = resolvedRight;
    }
    [self updateWindowFrames];
    FLMEnqueueDiagnosticLine(
        @"sb landscape-ingress accepted route=%@ raw={%.1f,%.1f} visual={%.1f,%.1f} mode=%@ fromRight=%d bounds=%@ device=%ld",
        (gesture == self.landscapeCornerGesture ||
         gesture == self.landscapeGlobalCornerGesture)
            ? (gesture == self.landscapeGlobalCornerGesture ? @"global-opener"
                                                            : @"opener")
            : ((gesture == self.landscapeCornerGuardGesture ||
                gesture == self.landscapeGlobalCornerGuardGesture)
                   ? (gesture == self.landscapeGlobalCornerGuardGesture
                          ? @"global-guard"
                          : @"guard")
                   : @"other"),
        rawPoint.x, rawPoint.y, resolved.x, resolved.y,
        FLMLandscapeRawCoordinateModeName(resolvedMode), resolvedRight,
        NSStringFromCGRect(bounds), (long)[UIDevice currentDevice].orientation);
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.homeDockGesture) {
        return !FLMDisplayIsLandscape() && self.enabled && !self.wheelPinned &&
               self.floatingWindow.hidden && !self.floatingCloseInProgress &&
               !FLMDeviceIsLocked();
    }
    if (gestureRecognizer == self.floatingDockInputGesture) {
        BOOL entrySettleCanReceive =
            self.floatingDockControlArmed &&
            self.floatingDockEntrySettleActive;
        BOOL entryControlTouch =
            entrySettleCanReceive ||
            self.floatingDockEntryControlTouchPending;
        BOOL canBegin =
            (self.floatingDocked || self.floatingDockHidden ||
             entryControlTouch) &&
                        !self.floatingWindow.hidden &&
                        (!self.floatingDockTransitionActive ||
                         entryControlTouch) &&
                        !FLMDeviceIsLocked();
        if (canBegin) {
            CGPoint point =
                [self visualPointForGesture:gestureRecognizer];
            if (self.floatingDockHidden) {
                canBegin =
                    CGRectContainsPoint(self.floatingHandle.frame, point) ||
                    CGRectContainsPoint(CGRectInset(self.floatingHandle.frame,
                                                    -18.0,
                                                    -18.0),
                                        point);
            } else if (entryControlTouch) {
                canBegin = CGRectContainsPoint(
                    CGRectInset([self floatingContainerPresentationFrame],
                                -6.0,
                                -6.0),
                    point);
            } else {
                canBegin =
                    [self floatingResizeControlContainsPoint:point] ||
                    CGRectContainsPoint(self.floatingContainer.frame, point);
            }
        }
        if (!canBegin && !self.floatingDockTransitionActive) {
            [self setFloatingDockRoutingSuppressed:NO];
        }
        return canBegin;
    }
    if (gestureRecognizer == self.floatingDockTap ||
        gestureRecognizer == self.floatingDockDragPress) {
        BOOL canBegin = self.floatingDocked && !self.floatingWindow.hidden &&
                        !self.floatingDockTransitionActive;
        if (!canBegin) {
            [self setFloatingDockRoutingSuppressed:NO];
        }
        return canBegin;
    }
    if (gestureRecognizer == self.floatingBackdropTap) {
        return self.floatingCloseInputArmed &&
               !self.floatingWindow.hidden && !self.floatingDocked;
    }
    if (gestureRecognizer == self.floatingExclusiveGesture) {
        if (!self.floatingCloseInputArmed) {
            return NO;
        }
        if (self.enabled && !self.wheelPinned &&
            self.itemIdentifiers.count > 0 &&
            FLMPointInsideCornerTrigger(
                [self visualPointForGesture:gestureRecognizer],
                FLMVisualScreenBounds(),
                NULL)) {
            FLMDiagnosticLog(
                @"sb should-begin recognizer=exclusive gate=wheel-corner point={%.1f,%.1f}",
                [self visualPointForGesture:gestureRecognizer].x,
                [self visualPointForGesture:gestureRecognizer].y);
            return NO;
        }
        return !self.floatingWindow.hidden && !self.floatingDocked &&
               !FLMDeviceIsLocked();
    }
    if (gestureRecognizer == self.modalGesture) {
        return self.enabled && self.wheelPinned && !FLMDeviceIsLocked();
    }

    BOOL landscapeIngress =
        FLMDisplayIsLandscape() || self.landscapeIngressActive;
    BOOL portraitWheelRecognizer =
        gestureRecognizer == self.cornerGuardGesture ||
        gestureRecognizer == self.cornerGesture ||
        gestureRecognizer == self.floatingCornerGuardGesture ||
        gestureRecognizer == self.floatingCornerGesture;
    BOOL landscapeWheelRecognizer =
        gestureRecognizer == self.landscapeCornerGuardGesture ||
        gestureRecognizer == self.landscapeCornerGesture ||
        gestureRecognizer == self.landscapeGlobalCornerGuardGesture ||
        gestureRecognizer == self.landscapeGlobalCornerGesture;
    if (portraitWheelRecognizer && landscapeIngress) {
        return NO;
    }
    if (landscapeWheelRecognizer && !landscapeIngress) {
        return NO;
    }
    if (gestureRecognizer == self.cornerGuardGesture ||
        gestureRecognizer == self.landscapeCornerGuardGesture ||
        gestureRecognizer == self.landscapeGlobalCornerGuardGesture ||
        gestureRecognizer == self.floatingCornerGuardGesture) {
        if (gestureRecognizer == self.landscapeCornerGuardGesture ||
            gestureRecognizer == self.landscapeGlobalCornerGuardGesture) {
            CGPoint point = CGPointZero;
            BOOL fromRight = NO;
            return [self resolveLandscapeCornerGesture:gestureRecognizer
                                                 touch:nil
                                         resolvedPoint:&point
                                      resolvedFromRight:&fromRight];
        }
        return self.enabled && !self.wheelPinned &&
               self.itemIdentifiers.count > 0 && !FLMDeviceIsLocked();
    }
    if (gestureRecognizer != self.cornerGesture &&
        gestureRecognizer != self.landscapeCornerGesture &&
        gestureRecognizer != self.landscapeGlobalCornerGesture &&
        gestureRecognizer != self.floatingCornerGesture) {
        return NO;
    }
    if (!self.enabled || self.wheelPinned || self.itemIdentifiers.count == 0) {
        return NO;
    }
    if (FLMDeviceIsLocked()) {
        return NO;
    }

    if (gestureRecognizer == self.landscapeCornerGesture ||
        gestureRecognizer == self.landscapeGlobalCornerGesture) {
        CGPoint point = CGPointZero;
        BOOL fromRight = NO;
        if (![self resolveLandscapeCornerGesture:gestureRecognizer
                                           touch:nil
                                   resolvedPoint:&point
                                resolvedFromRight:&fromRight]) {
            return NO;
        }
        self.cornerGestureStartPoint = point;
        self.presentingFromRight = fromRight;
        self.wheelGestureActive = NO;
        return YES;
    }

    FLMCornerGestureRecognizer *cornerRecognizer =
        (FLMCornerGestureRecognizer *)gestureRecognizer;
    CGPoint startPoint = cornerRecognizer.flmHasFirstTouchPoint
                             ? cornerRecognizer.flmFirstTouchPoint
                             : self.cornerGestureStartPoint;
    if (!cornerRecognizer.flmHasFirstTouchPoint) {
        // Last-resort fallback for private-manager builds that enter shouldBegin
        // without delegate delivery. The recognizer's current point is still a
        // better physical-space candidate than a stale point from a prior touch.
        CGPoint currentPoint =
            [self visualPointForGesture:gestureRecognizer];
        if (!CGPointEqualToPoint(currentPoint, CGPointZero)) {
            startPoint = currentPoint;
        }
    }
    CGRect bounds = FLMVisualScreenBounds();
    BOOL fromRight = NO;
    BOOL insideTrigger =
        FLMPointInsideCornerTrigger(startPoint, bounds, &fromRight);
    if (insideTrigger) {
        self.cornerGestureStartPoint = startPoint;
        self.presentingFromRight = fromRight;
    }
    FLMEnqueueDiagnosticLine(
        @"sb wheel-should-begin recognizer=%@ accepted=%d start={%.1f,%.1f} bounds=%@ captured=%d fromRight=%d landscape=%d",
        gestureRecognizer == self.landscapeCornerGesture ? @"landscape-window" :
        (gestureRecognizer == self.floatingCornerGesture ? @"floating" : @"system"),
        insideTrigger, startPoint.x, startPoint.y, NSStringFromCGRect(bounds),
        cornerRecognizer.flmHasFirstTouchPoint, fromRight,
        FLMBoundsAreLandscape(bounds));
    return insideTrigger;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer == self.homeDockGesture) {
        if (FLMDisplayIsLandscape() || !self.enabled || self.wheelPinned || !self.floatingWindow.hidden ||
            self.floatingCloseInProgress || FLMDeviceIsLocked()) {
            return NO;
        }
        CGPoint point = [self visualPointForTouch:touch];
        CGRect screenBounds = FLMVisualScreenBounds();
        CGFloat zoneLeft = CGRectGetWidth(screenBounds) * 0.30;
        CGFloat zoneRight = CGRectGetWidth(screenBounds) * 0.70;
        if (point.x < zoneLeft || point.x > zoneRight ||
            point.y < CGRectGetHeight(screenBounds) - 100.0) {
            return NO;
        }
        NSString *frontmost = FLMFrontmostApplicationIdentifier();
        if (frontmost.length == 0 ||
            [frontmost isEqualToString:@"com.apple.springboard"] ||
            [frontmost isEqualToString:FLYME_LOCK_SCREEN_ITEM]) {
            return NO;
        }
        return YES;
    }
    if (gestureRecognizer == self.floatingDockInputGesture) {
        BOOL entrySettleCanReceive =
            self.floatingDockControlArmed &&
            self.floatingDockEntrySettleActive;
        self.floatingDockEntryControlTouchPending = NO;
        if ((!self.floatingDocked && !self.floatingDockHidden &&
             !entrySettleCanReceive) ||
            self.floatingWindow.hidden ||
            (self.floatingDockTransitionActive &&
             !entrySettleCanReceive) ||
            FLMDeviceIsLocked()) {
            return NO;
        }
        CGPoint point = [self visualPointForTouch:touch];
        BOOL staleStream =
            self.floatingDockInputBlockedUntilNextTouch &&
            self.floatingDockInputBlockCutoffTimestamp > 0.0 &&
            touch.timestamp > 0.0 &&
            touch.timestamp <= self.floatingDockInputBlockCutoffTimestamp + 0.001;
        BOOL accepted = NO;
        if (self.floatingDockHidden) {
            accepted = CGRectContainsPoint(self.floatingHandle.frame, point) ||
                       CGRectContainsPoint(CGRectInset(self.floatingHandle.frame,
                                                       -18.0,
                                                       -18.0),
                                           point);
        } else if (entrySettleCanReceive) {
            accepted = CGRectContainsPoint(
                CGRectInset([self floatingContainerPresentationFrame],
                            -6.0,
                            -6.0),
                point);
        } else {
            accepted = [self floatingResizeControlContainsPoint:point] ||
                       CGRectContainsPoint(self.floatingContainer.frame, point);
        }
        accepted = accepted && !staleStream;
        if (accepted && entrySettleCanReceive) {
            self.floatingDockEntryControlTouchPending = YES;
        }
        FLMDiagnosticLog(
            @"sb dock-input-delegate accepted=%d docked=%d hidden=%d transition=%d entry=%d armed=%d blocked=%d stale=%d timestamp=%.6f point={%.1f,%.1f} view=%@ card=%@",
            accepted,
            self.floatingDocked,
            self.floatingDockHidden,
            self.floatingDockTransitionActive,
            self.floatingDockEntrySettleActive,
            self.floatingDockControlArmed,
            self.floatingDockInputBlockedUntilNextTouch,
            staleStream,
            touch.timestamp,
            point.x,
            point.y,
            touch.view ? NSStringFromClass([touch.view class]) : @"<nil>",
            NSStringFromCGRect(self.floatingContainer.frame));
        if (accepted) {
            // A touch newer than the transition cutoff is a genuinely new
            // stream. Clear the tail guard before the gesture begins so the
            // first deliberate post-transition drag/tap is not discarded.
            self.floatingDockInputBlockedUntilNextTouch = NO;
            self.floatingDockInputBlockCutoffTimestamp = 0.0;
            // Lock the floating card's touch route before the recognizer has
            // reached Began.  Waiting for the action callback leaves a small
            // arbitration window where a drag through a lower corner can be
            // handed to the wheel for one compositor frame.
            [self setFloatingDockRoutingSuppressed:YES];
            if ((self.floatingDocked || entrySettleCanReceive) &&
                !self.floatingDockHidden) {
                // Reassert the shield at touch-begin.  The dock can finish its
                // settle animation between two recognizer callbacks; without
                // this refresh a newly accepted drag can briefly target the
                // remote Scene underneath the card.
                [self setFloatingApplicationInputBlocked:YES];
            }
        }
        return accepted;
    }
    if (gestureRecognizer == self.floatingBackdropTap) {
        BOOL accepted =
            self.floatingCloseInputArmed && !self.floatingWindow.hidden;
        CGPoint point = [self visualPointForTouch:touch];
        FLMDiagnosticLog(
            @"sb touch-delegate recognizer=backdrop touch=%p timestamp=%.6f accepted=%d armed=%d armAt=%.6f point={%.1f,%.1f} view=%@",
            (__bridge void *)touch, touch.timestamp, accepted,
            self.floatingCloseInputArmed, self.floatingCloseArmAt,
            point.x, point.y,
            touch.view ? NSStringFromClass([touch.view class]) : @"<nil>");
        return accepted;
    }
    if (gestureRecognizer == self.floatingExclusiveGesture) {
        FLMCornerGestureRecognizer *exclusiveGesture =
            (FLMCornerGestureRecognizer *)gestureRecognizer;
        exclusiveGesture.flmOutsideCloseAuthorized = NO;
        if (!self.floatingCloseInputArmed ||
            self.floatingWindow.hidden || FLMDeviceIsLocked()) {
            FLMDiagnosticLog(
                @"sb touch-delegate recognizer=exclusive touch=%p timestamp=%.6f accepted=0 gate=%@ armed=%d armAt=%.6f",
                (__bridge void *)touch, touch.timestamp,
                !self.floatingCloseInputArmed
                    ? @"close-guard"
                    : (self.floatingWindow.hidden ? @"window-hidden"
                                                  : @"device-locked"),
                self.floatingCloseInputArmed, self.floatingCloseArmAt);
            return NO;
        }
        UIView *touchView = touch.view;
        if (touchView == self.floatingContainer ||
            [touchView isDescendantOfView:self.floatingContainer] ||
            touchView == self.floatingHandle ||
            [touchView isDescendantOfView:self.floatingHandle]) {
            FLMDiagnosticLog(
                @"sb touch-delegate recognizer=exclusive touch=%p timestamp=%.6f accepted=0 gate=protected-view view=%@ viewPtr=%p",
                (__bridge void *)touch, touch.timestamp,
                touchView ? NSStringFromClass([touchView class]) : @"<nil>",
                (__bridge void *)touchView);
            return NO;
        }
        CGPoint point = [self visualPointForTouch:touch];
        // The wheel owns the corner trigger while it can summon: the exclusive
        // close gesture must never arbitrate away the corner swipe that opens
        // the wheel over a centered card.
        if (self.enabled && !self.wheelPinned &&
            self.itemIdentifiers.count > 0 &&
            FLMPointInsideCornerTrigger(point,
                                        FLMVisualScreenBounds(),
                                        NULL)) {
            FLMDiagnosticLog(
                @"sb touch-delegate recognizer=exclusive touch=%p timestamp=%.6f accepted=0 gate=wheel-corner point={%.1f,%.1f}",
                (__bridge void *)touch, touch.timestamp, point.x, point.y);
            return NO;
        }
        BOOL outside = ![self pointIsInsideFloatingInteractionDomain:point];
        exclusiveGesture.flmOutsideCloseAuthorized = outside;
        exclusiveGesture.flmAuthorizedStartPoint = point;
        FLMDiagnosticLog(
            @"sb touch-delegate recognizer=exclusive touch=%p timestamp=%.6f accepted=%d point={%.1f,%.1f} view=%@ keyboardVisible=%d interaction=%d keyboardFrame=%@ card=%@",
            (__bridge void *)touch, touch.timestamp, outside, point.x, point.y,
            touchView ? NSStringFromClass([touchView class]) : @"<nil>",
            self.floatingKeyboardVisible,
            self.floatingKeyboardInteractionSessionActive,
            NSStringFromCGRect([self floatingKeyboardInteractionFrame]),
            NSStringFromCGRect(self.floatingContainer.frame));
        return outside;
    }
    if (gestureRecognizer == self.floatingDockDragPress) {
        if (!self.floatingDocked || self.floatingWindow.hidden ||
            self.floatingDockTransitionActive || FLMDeviceIsLocked()) {
            return NO;
        }
        [self setFloatingDockRoutingSuppressed:YES];
        return YES;
    }
    if (gestureRecognizer == self.modalGesture) {
        return self.enabled && self.wheelPinned && !FLMDeviceIsLocked();
    }

    BOOL landscapeIngress =
        FLMDisplayIsLandscape() || self.landscapeIngressActive;
    BOOL portraitWheelRecognizer =
        gestureRecognizer == self.cornerGuardGesture ||
        gestureRecognizer == self.cornerGesture ||
        gestureRecognizer == self.floatingCornerGuardGesture ||
        gestureRecognizer == self.floatingCornerGesture;
    BOOL landscapeWheelRecognizer =
        gestureRecognizer == self.landscapeCornerGuardGesture ||
        gestureRecognizer == self.landscapeCornerGesture ||
        gestureRecognizer == self.landscapeGlobalCornerGuardGesture ||
        gestureRecognizer == self.landscapeGlobalCornerGesture;
    if (portraitWheelRecognizer && landscapeIngress) {
        return NO;
    }
    if (landscapeWheelRecognizer && !landscapeIngress) {
        return NO;
    }
    if (gestureRecognizer == self.cornerGuardGesture ||
        gestureRecognizer == self.landscapeCornerGuardGesture ||
        gestureRecognizer == self.landscapeGlobalCornerGuardGesture ||
        gestureRecognizer == self.floatingCornerGuardGesture) {
        if (!self.enabled || self.wheelPinned ||
            self.itemIdentifiers.count == 0 || FLMDeviceIsLocked()) {
            return NO;
        }
        if (gestureRecognizer == self.landscapeCornerGuardGesture ||
            gestureRecognizer == self.landscapeGlobalCornerGuardGesture) {
            CGPoint resolved = CGPointZero;
            BOOL fromRight = NO;
            return [self resolveLandscapeCornerGesture:gestureRecognizer
                                                 touch:touch
                                         resolvedPoint:&resolved
                                      resolvedFromRight:&fromRight];
        }
        CGPoint point = [self visualPointForTouch:touch];
        BOOL accepted = FLMPointInsideCornerTrigger(point,
                                                    FLMVisualScreenBounds(),
                                                    NULL);
        if (accepted) {
            NSString *route =
                gestureRecognizer == self.cornerGuardGesture ? @"guard" :
                (gestureRecognizer == self.landscapeCornerGuardGesture
                    ? @"landscape-window-guard" : @"floating-guard");
            FLMDiagnosticLog(
                @"sb wheel-priority-touch accepted recognizer=%@ point={%.1f,%.1f}",
                route, point.x, point.y);
        }
        return accepted;
    }
    if (gestureRecognizer != self.cornerGesture &&
        gestureRecognizer != self.landscapeCornerGesture &&
        gestureRecognizer != self.landscapeGlobalCornerGesture &&
        gestureRecognizer != self.floatingCornerGesture) {
        return NO;
    }
    if (!self.enabled || self.wheelPinned || self.itemIdentifiers.count == 0) {
        return NO;
    }
    if (FLMDeviceIsLocked()) {
        return NO;
    }
    if (gestureRecognizer == self.landscapeCornerGesture ||
        gestureRecognizer == self.landscapeGlobalCornerGesture) {
        CGPoint resolved = CGPointZero;
        BOOL fromRight = NO;
        if (![self resolveLandscapeCornerGesture:gestureRecognizer
                                           touch:touch
                                   resolvedPoint:&resolved
                                resolvedFromRight:&fromRight]) {
            return NO;
        }
        self.presentingFromRight = fromRight;
        self.cornerGestureStartPoint = resolved;
        self.wheelGestureActive = NO;
        return YES;
    }
    CGRect bounds = FLMVisualScreenBounds();
    CGPoint point = [self visualPointForTouch:touch];
    BOOL fromRight = NO;
    if (!FLMPointInsideCornerTrigger(point, bounds, &fromRight)) {
        return NO;
    }
    self.presentingFromRight = fromRight;
    self.cornerGestureStartPoint = point;
    FLMCornerGestureRecognizer *cornerRecognizer =
        (FLMCornerGestureRecognizer *)gestureRecognizer;
    cornerRecognizer.flmFirstTouchPoint = point;
    cornerRecognizer.flmHasFirstTouchPoint = YES;
    self.wheelGestureActive = NO;
    NSString *route =
        gestureRecognizer == self.cornerGesture ? @"opener" :
        (gestureRecognizer == self.landscapeCornerGesture
            ? @"landscape-window-opener" : @"floating-opener");
    FLMDiagnosticLog(
        @"sb wheel-priority-touch accepted recognizer=%@ point={%.1f,%.1f} fromRight=%d bounds=%@",
        route, point.x, point.y, fromRight, NSStringFromCGRect(bounds));
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer {
    // The wheel family spans the dedicated hotspot window and the floating
    // window fallback pair. Every member must be able to recognize beside any
    // other member, otherwise the first recognizer to begin prevents the rest
    // and the wheel silently stops summoning in card modes.
    FLMCornerGestureRecognizer *wheelFamily[] = {
        self.cornerGuardGesture,
        self.cornerGesture,
        self.landscapeCornerGuardGesture,
        self.landscapeCornerGesture,
        self.landscapeGlobalCornerGuardGesture,
        self.landscapeGlobalCornerGesture,
        self.floatingCornerGuardGesture,
        self.floatingCornerGesture,
    };
    BOOL firstInFamily = NO;
    BOOL secondInFamily = NO;
    for (NSUInteger i = 0; i < sizeof(wheelFamily) / sizeof(wheelFamily[0]); i++) {
        if (gestureRecognizer == wheelFamily[i]) {
            firstInFamily = YES;
        }
        if (otherGestureRecognizer == wheelFamily[i]) {
            secondInFamily = YES;
        }
    }
    if (firstInFamily && secondInFamily) {
        return YES;
    }
    // The in-window guard must not disable the backdrop close on a quick
    // corner tap; let the backdrop tap run alongside any wheel-family member.
    BOOL backdropInvolved =
        gestureRecognizer == self.floatingBackdropTap ||
        otherGestureRecognizer == self.floatingBackdropTap;
    if (backdropInvolved && (firstInFamily || secondInFamily)) {
        return YES;
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldBeRequiredToFailByGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return NO;
}

- (void)handleModalGesture:(UIGestureRecognizer *)gesture {
    if (!self.wheelPinned) {
        return;
    }
    CGPoint point = [self visualPointForGesture:gesture];
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            [self updateHighlightForPoint:point];
            break;
        case UIGestureRecognizerStateEnded: {
            FLMWheelItemView *item =
                [self itemNearPoint:point
                    maximumDistance:self.wheelIconSize * 0.5 + 2.0];
            [self dismissWheelLaunchingItem:item];
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            self.highlightedItem.highlighted = NO;
            self.highlightedItem = nil;
            break;
        default:
            break;
    }
}

- (void)handleCornerGuardGesture:(UIGestureRecognizer *)gesture {
    BOOL landscapeIngress =
        FLMDisplayIsLandscape() || self.landscapeIngressActive;
    BOOL portraitRecognizer =
        gesture == self.cornerGuardGesture ||
        gesture == self.floatingCornerGuardGesture;
    BOOL landscapeRecognizer =
        gesture == self.landscapeCornerGuardGesture ||
        gesture == self.landscapeGlobalCornerGuardGesture;
    if ((portraitRecognizer && landscapeIngress) ||
        (landscapeRecognizer && !landscapeIngress)) {
        return;
    }
    // Recognizing immediately reserves the corner zone so home/back/card
    // gestures cannot consume the same touch stream. Keep a breadcrumb for
    // the priority boundary because this guard runs before the wheel opener.
    if (gesture.state == UIGestureRecognizerStateBegan) {
        CGPoint point = [self visualPointForGesture:gesture];
        FLMDiagnosticLog(
            @"sb wheel-priority-guard began point={%.1f,%.1f}",
            point.x, point.y);
    }
}

- (void)handleHomeDockGesture:(FLMDockGestureRecognizer *)gesture {
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            self.homeDockGestureActive = YES;
            self.homeDockTriggerHandled = NO;
            FLMDiagnosticLog(
                @"sb home-dock long-press confirmed app=%@",
                FLMFrontmostApplicationIdentifier() ?: @"<none>");
            break;
        case UIGestureRecognizerStateChanged:
            if (gesture.flmTriggered && !self.homeDockTriggerHandled) {
                self.homeDockTriggerHandled = YES;
                [self activateDockedFrontmostApplication];
            }
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            self.homeDockGestureActive = NO;
            self.homeDockTriggerHandled = NO;
            break;
        default:
            break;
    }
}

- (void)activateDockedFrontmostApplication {
    if (!self.enabled || FLMDeviceIsLocked() ||
        !self.floatingWindow.hidden || self.floatingCloseInProgress) {
        return;
    }
    NSString *frontmost = FLMFrontmostApplicationIdentifier();
    if (frontmost.length == 0 ||
        [frontmost isEqualToString:@"com.apple.springboard"] ||
        [frontmost isEqualToString:FLYME_LOCK_SCREEN_ITEM]) {
        return;
    }
    self.floatingOpenTargetDocked = YES;
    [self openFloatingIdentifier:frontmost];
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback =
            [[UIImpactFeedbackGenerator alloc]
                initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
    }
    FLMDiagnosticLog(@"sb home-dock activate app=%@", frontmost);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRequireFailureOfGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return NO;
}

- (void)handleCornerGesture:(UIGestureRecognizer *)gesture {
    BOOL landscapeIngress =
        FLMDisplayIsLandscape() || self.landscapeIngressActive;
    BOOL portraitRecognizer =
        gesture == self.cornerGesture ||
        gesture == self.floatingCornerGesture;
    BOOL landscapeRecognizer =
        gesture == self.landscapeCornerGesture ||
        gesture == self.landscapeGlobalCornerGesture;
    if ((portraitRecognizer && landscapeIngress) ||
        (landscapeRecognizer && !landscapeIngress)) {
        return;
    }
    CGPoint point = [self visualPointForGesture:gesture];
    FLMCornerGestureRecognizer *cornerRecognizer =
        [gesture isKindOfClass:[FLMCornerGestureRecognizer class]]
            ? (FLMCornerGestureRecognizer *)gesture
            : nil;
    if (cornerRecognizer.flmHasFirstTouchPoint) {
        BOOL fromRight = NO;
        CGRect cornerBounds =
            (self.landscapeIngressActive &&
             FLMBoundsAreLandscape(self.landscapeIngressBounds))
                ? self.landscapeIngressBounds
                : FLMVisualScreenBounds();
        if (FLMPointInsideCornerTrigger(cornerRecognizer.flmFirstTouchPoint,
                                       cornerBounds,
                                       &fromRight)) {
            self.cornerGestureStartPoint = cornerRecognizer.flmFirstTouchPoint;
            self.presentingFromRight = fromRight;
        }
    }

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            if (!self.wheelGestureActive && [self shouldActivateWheelAtPoint:point]) {
                self.wheelGestureActive = YES;
                FLMDiagnosticLog(
                    @"sb wheel-gesture began point={%.1f,%.1f} start={%.1f,%.1f} priority=1",
                    point.x, point.y,
                    self.cornerGestureStartPoint.x,
                    self.cornerGestureStartPoint.y);
                [self presentWheelFromRight:self.presentingFromRight];
            }
            if (self.wheelGestureActive) {
                [self updateHighlightForPoint:point];
            }
            break;
        case UIGestureRecognizerStateEnded:
            if (self.wheelGestureActive) {
                FLMWheelItemView *selectedItem = self.highlightedItem;
                if (selectedItem) {
                    [self dismissWheelLaunchingItem:selectedItem];
                } else {
                    [self pinWheel];
                }
            }
            FLMDiagnosticLog(
                @"sb wheel-gesture ended active=%d point={%.1f,%.1f}",
                self.wheelGestureActive, point.x, point.y);
            self.wheelGestureActive = NO;
            break;
        case UIGestureRecognizerStateCancelled:
            if (self.wheelGestureActive) {
                [self pinWheel];
            }
            FLMDiagnosticLog(
                @"sb wheel-gesture cancelled active=%d point={%.1f,%.1f}",
                self.wheelGestureActive, point.x, point.y);
            self.wheelGestureActive = NO;
            break;
        case UIGestureRecognizerStateFailed:
            if (self.wheelGestureActive) {
                [self dismissWheelLaunchingItem:nil];
            }
            self.wheelGestureActive = NO;
            break;
        default:
            break;
    }
}

- (BOOL)shouldActivateWheelAtPoint:(CGPoint)point {
    CGFloat horizontalMovement = point.x - self.cornerGestureStartPoint.x;
    CGFloat verticalMovement = point.y - self.cornerGestureStartPoint.y;
    CGFloat totalMovement = hypot(horizontalMovement, verticalMovement);
    CGFloat inwardMovement =
        self.presentingFromRight ? -horizontalMovement : horizontalMovement;
    CGFloat upwardMovement = -verticalMovement;
    return totalMovement >= 14.0 &&
           (inwardMovement >= 4.0 || upwardMovement >= 4.0);
}

// The wheel is solved in the visual display space. `anchor` is the bottom
// corner the arc grows out of, `inward` points away from that screen edge, and
// every ring carries its own radius plus the angle window it may occupy.
#define FLMWheelMaximumRings 6

typedef struct {
    CGFloat radius;
    CGFloat startAngle;
    CGFloat endAngle;
    NSUInteger count;
} FLMWheelRingPlan;

typedef struct {
    FLMWheelRingPlan rings[FLMWheelMaximumRings];
    NSUInteger ringCount;
    CGPoint anchor;
    CGFloat inward;
    CGPoint degenerateCenter;
    BOOL degenerate;
} FLMWheelPlan;

static CGFloat FLMWheelClampUnit(CGFloat value) {
    return MIN(1.0, MAX(0.0, value));
}

// Largest angle window a ring of `radius` can use inside a corner box of
// `horizontalRoom` x `verticalRoom`, with the arc spanning (−90°, 0°).
static CGFloat FLMWheelSpanMaximum(CGFloat radius,
                                   CGFloat horizontalRoom,
                                   CGFloat verticalRoom) {
    if (radius <= 0.0 || horizontalRoom <= 0.0 || verticalRoom <= 0.0) {
        return 0.0;
    }
    CGFloat thetaVertical =
        radius <= verticalRoom
            ? (CGFloat)M_PI_2
            : asin(FLMWheelClampUnit(verticalRoom / radius));
    CGFloat thetaHorizontal =
        radius <= horizontalRoom
            ? 0.0
            : acos(FLMWheelClampUnit(horizontalRoom / radius));
    return MAX(0.0, thetaVertical - thetaHorizontal);
}

// Angular step that keeps two centres on the ring at least `minimumChord`
// apart.
static CGFloat FLMWheelAnglePitch(CGFloat radius, CGFloat minimumChord) {
    if (radius <= 0.0 || minimumChord <= 0.0) {
        return 0.0;
    }
    CGFloat ratio = minimumChord / (2.0 * radius);
    if (ratio >= 1.0) {
        return (CGFloat)M_PI;
    }
    return 2.0 * asin(ratio);
}

static CGFloat FLMWheelSpanNeeded(CGFloat radius,
                                  CGFloat minimumChord,
                                  NSUInteger count) {
    if (count < 2) {
        return 0.0;
    }
    return (CGFloat)(count - 1) * FLMWheelAnglePitch(radius, minimumChord);
}

// Radius at which one ring can hold `count` items, or 0 when no single ring
// can. The preferred radius wins when it already fits so the user setting is
// respected; otherwise scan for the widest radius that still keeps the gap.
// `span needed` and `span available` both shrink with R at different rates, so
// the difference is not monotone and a bisection would miss solutions.
static CGFloat FLMWheelResolveRadius(NSUInteger count,
                                     CGFloat preferredRadius,
                                     CGFloat iconSize,
                                     CGFloat horizontalRoom,
                                     CGFloat verticalRoom) {
    if (count == 0) {
        return 0.0;
    }
    CGFloat minimumChord = iconSize + 6.0;
    CGFloat diagonal = sqrt(horizontalRoom * horizontalRoom +
                            verticalRoom * verticalRoom);
    CGFloat maximum = MAX(1.0, diagonal);
    CGFloat minimum = MAX(0.5, minimumChord * 0.5);
    if (maximum < minimum) {
        return 0.0;
    }
    CGFloat preferred = MIN(preferredRadius, maximum);
    if (preferred >= minimum &&
        FLMWheelSpanNeeded(preferred, minimumChord, count) <=
            FLMWheelSpanMaximum(preferred, horizontalRoom, verticalRoom)) {
        return preferred;
    }
    const NSUInteger samples = 64;
    CGFloat best = 0.0;
    for (NSUInteger index = 0; index <= samples; index++) {
        CGFloat radius = minimum + (maximum - minimum) *
                                       (CGFloat)index / (CGFloat)samples;
        if (FLMWheelSpanNeeded(radius, minimumChord, count) <=
            FLMWheelSpanMaximum(radius, horizontalRoom, verticalRoom)) {
            best = radius;
        }
    }
    return best;
}

// Angle window one ring actually uses for `count` items. 72° is the design
// cap carried over from the historical 82°..10° arc, but it never shrinks
// below what the minimum gap needs.
static CGFloat FLMWheelRingSpan(CGFloat radius,
                                CGFloat iconSize,
                                NSUInteger count,
                                CGFloat horizontalRoom,
                                CGFloat verticalRoom) {
    CGFloat available =
        FLMWheelSpanMaximum(radius, horizontalRoom, verticalRoom);
    CGFloat needed =
        FLMWheelSpanNeeded(radius, iconSize + 6.0, count);
    CGFloat preferred = 72.0 * (CGFloat)M_PI / 180.0;
    return MIN(available, MAX(preferred, needed));
}

static CGFloat FLMWheelHorizontalAngle(CGFloat radius,
                                       CGFloat horizontalRoom) {
    if (radius <= horizontalRoom) {
        return 0.0;
    }
    return acos(FLMWheelClampUnit(horizontalRoom / radius));
}

static FLMWheelPlan FLMWheelResolvePlan(NSUInteger count,
                                        CGFloat preferredRadius,
                                        CGFloat iconSize,
                                        BOOL fromRight,
                                        CGFloat safeLeft,
                                        CGFloat safeTop,
                                        CGFloat safeRight,
                                        CGFloat safeBottom) {
    FLMWheelPlan plan;
    memset(&plan, 0, sizeof(plan));
    plan.anchor = CGPointMake(fromRight ? safeRight : safeLeft, safeBottom);
    plan.inward = fromRight ? -1.0 : 1.0;
    plan.degenerateCenter =
        CGPointMake((safeLeft + safeRight) * 0.5, (safeTop + safeBottom) * 0.5);
    if (count == 0) {
        return plan;
    }
    CGFloat horizontalRoom = safeRight - safeLeft;
    CGFloat verticalRoom = safeBottom - safeTop;
    if (horizontalRoom <= 1.0 || verticalRoom <= 1.0) {
        plan.degenerate = YES;
        plan.ringCount = 1;
        plan.rings[0].count = count;
        return plan;
    }
    CGFloat radius = FLMWheelResolveRadius(count, preferredRadius, iconSize,
                                           horizontalRoom, verticalRoom);
    if (radius > 0.0) {
        plan.ringCount = 1;
        plan.rings[0].radius = radius;
        plan.rings[0].endAngle = -FLMWheelHorizontalAngle(radius, horizontalRoom);
        plan.rings[0].startAngle =
            plan.rings[0].endAngle -
            FLMWheelRingSpan(radius, iconSize, count, horizontalRoom,
                             verticalRoom);
        plan.rings[0].count = count;
        return plan;
    }
    // No single ring can hold every item. Fill rings outward, each one sized
    // from its own geometry rather than a fixed per-ring allowance.
    CGFloat ringSpacing = iconSize + 20.0;
    CGFloat diagonal = sqrt(horizontalRoom * horizontalRoom +
                            verticalRoom * verticalRoom);
    CGFloat ringRadius = MIN(preferredRadius, MAX(1.0, diagonal));
    if (ringRadius < (iconSize + 6.0) * 0.5) {
        ringRadius = (iconSize + 6.0) * 0.5;
    }
    NSUInteger remaining = count;
    while (remaining > 0 && plan.ringCount < FLMWheelMaximumRings) {
        CGFloat available =
            FLMWheelSpanMaximum(ringRadius, horizontalRoom, verticalRoom);
        CGFloat preferredSpan = 72.0 * (CGFloat)M_PI / 180.0;
        CGFloat capacitySpan = MIN(available, preferredSpan);
        CGFloat pitch = FLMWheelAnglePitch(ringRadius, iconSize + 6.0);
        NSUInteger capacity =
            capacitySpan > 0.0 && pitch > 0.0
                ? (NSUInteger)floor(capacitySpan / pitch) + 1
                : 1;
        NSUInteger ringCount = MIN(remaining, MAX((NSUInteger)1, capacity));
        FLMWheelRingPlan *slot = &plan.rings[plan.ringCount];
        slot->radius = ringRadius;
        slot->endAngle = -FLMWheelHorizontalAngle(ringRadius, horizontalRoom);
        slot->startAngle =
            slot->endAngle -
            FLMWheelRingSpan(ringRadius, iconSize, ringCount, horizontalRoom,
                             verticalRoom);
        slot->count = ringCount;
        plan.ringCount += 1;
        remaining -= ringCount;
        ringRadius += ringSpacing;
    }
    if (remaining > 0) {
        // Ring budget exhausted. Keep the overflow visible on the last ring
        // instead of dropping applications.
        plan.rings[plan.ringCount - 1].count += remaining;
    }
    return plan;
}

static CGPoint FLMWheelRingPoint(FLMWheelPlan plan,
                                 FLMWheelRingPlan ring,
                                 NSUInteger position) {
    if (plan.degenerate) {
        return plan.degenerateCenter;
    }
    CGFloat fraction = ring.count <= 1
                           ? 0.5
                           : (CGFloat)position / (CGFloat)(ring.count - 1);
    CGFloat angle =
        ring.startAngle + fraction * (ring.endAngle - ring.startAngle);
    return CGPointMake(plan.anchor.x + plan.inward * ring.radius * cos(angle),
                       plan.anchor.y + ring.radius * sin(angle));
}

- (void)presentWheelFromRight:(BOOL)fromRight {
    if (FLMDisplayIsLandscape() || self.landscapeIngressActive) {
        [self presentLandscapeWheelFromRight:fromRight];
        return;
    }
    self.landscapeDirectWheelTaps = NO;
    [self.itemViews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.wheelPinned = NO;
    // The opening touch belongs to this wheel stream. Do not let the
    // priority window start a second stream while the wheel is animating in.
    self.hotspotWindow.hotspotsEnabled = NO;
    // The wheel must render and receive touches above any visible card. The
    // keyboard forwarding window sits at floating+1, so present at +2.
    self.overlayWindow.userInteractionEnabled = NO;
    self.overlayWindow.windowLevel = self.floatingWindow.windowLevel + 2.0;
    NSMutableArray<FLMWheelItemView *> *views = [NSMutableArray array];
    CGRect bounds = FLMVisualScreenBounds();
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    UIView *overlayRoot = self.overlayWindow.rootViewController.view;
    [overlayRoot layoutIfNeeded];
    UIEdgeInsets rawSafeInsets = overlayRoot.safeAreaInsets;
    UIInterfaceOrientation presentationOrientation =
        FLMBoundsAreLandscape(bounds)
            ? FLMLandscapeOrientationForSafeInsets(rawSafeInsets)
            : UIInterfaceOrientationPortrait;
    FLMConfigureVisualCanvas(self.wheelContainer, overlayRoot, bounds,
                             presentationOrientation);
    UIEdgeInsets safeInsets =
        FLMBoundsAreLandscape(bounds)
            ? FLMPhysicalLandscapeSafeInsets(rawSafeInsets,
                                             presentationOrientation)
            : rawSafeInsets;
    CGFloat safeLeft = MAX(4.0, safeInsets.left + 4.0);
    CGFloat safeRight = MIN(width - 4.0, width - safeInsets.right - 4.0);
    CGFloat safeTop = MAX(4.0, safeInsets.top + 4.0);
    CGFloat safeBottom = MIN(height - 4.0, height - safeInsets.bottom - 4.0);
    CGPoint anchor = CGPointMake(fromRight ? safeRight : safeLeft, safeBottom);
    // Portrait shares the solver with the landscape route, so the arc stays
    // inside the real safe area and the per-ring counts come from geometry
    // instead of a fixed 4, 5, 6 allowance.
    FLMWheelPlan plan = FLMWheelResolvePlan(
        self.itemIdentifiers.count, self.wheelRadius, self.wheelIconSize,
        fromRight, safeLeft, safeTop, safeRight, safeBottom);
    if (FLMBoundsAreLandscape(bounds)) {
        FLMEnqueueDiagnosticLine(
            @"sb wheel-landscape-layout side=%@ bounds=%@ rawSafe={%.1f,%.1f,%.1f,%.1f} physicalSafe={%.1f,%.1f,%.1f,%.1f} orientation=%ld anchor={%.1f,%.1f} rings=%lu radius=%.1f",
            fromRight ? @"right" : @"left", NSStringFromCGRect(bounds),
            rawSafeInsets.top, rawSafeInsets.left, rawSafeInsets.bottom,
            rawSafeInsets.right, safeInsets.top, safeInsets.left,
            safeInsets.bottom, safeInsets.right,
            (long)presentationOrientation, anchor.x, anchor.y,
            (unsigned long)plan.ringCount, plan.rings[0].radius);
    }

    NSUInteger itemIndex = 0;
    for (NSUInteger ring = 0; ring < plan.ringCount; ring++) {
        FLMWheelRingPlan ringPlan = plan.rings[ring];
        for (NSUInteger position = 0; position < ringPlan.count; position++) {
            CGPoint visualCenter = FLMWheelRingPoint(plan, ringPlan, position);
            NSString *identifier = self.itemIdentifiers[itemIndex++];
            FLMWheelItemView *item =
                [[FLMWheelItemView alloc] initWithIdentifier:identifier
                                                       image:FLMApplicationIcon(identifier)
                                                        size:self.wheelIconSize];
            item.center = visualCenter;
            item.alpha = 0.0;
            item.transform = CGAffineTransformMakeScale(0.42, 0.42);
            [self.wheelContainer addSubview:item];
            [views addObject:item];
        }
    }
    self.itemViews = views;

    self.overlayWindow.hidden = NO;
    self.wheelContainer.alpha = 1.0;
    [self beginFloatingHighRefreshLeaseForDuration:0.56];
    [self.itemViews enumerateObjectsUsingBlock:^(
                        FLMWheelItemView *item, NSUInteger index, BOOL *stop) {
        (void)stop;
        [UIView animateWithDuration:0.44
                              delay:MIN((NSTimeInterval)index * 0.018, 0.12)
             usingSpringWithDamping:0.72
              initialSpringVelocity:0.55
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
                             item.alpha = 1.0;
                             item.transform = CGAffineTransformIdentity;
                         }
                         completion:nil];
    }];
}

// The landscape wheel geometry is solved in the physical display space
// (844x390), and the wheel container IS that space: it is an 844x390 canvas
// rotated into SpringBoard's portrait scene bounds, so one canvas-local point
// maps onto exactly one physical display point. Converting through
// UIScreen.coordinateSpace would apply the system rotation a second time.
- (CGPoint)landscapeWheelLocalPointFromVisualPoint:(CGPoint)visualPoint {
    return visualPoint;
}

- (void)synchronizeLandscapeWheelItemCenters {
    NSArray<FLMWheelItemView *> *items = self.itemViews;
    NSArray<NSValue *> *visualCenters = self.landscapeWheelVisualCenters;
    if (items.count == 0 || items.count != visualCenters.count) {
        return;
    }
    [items enumerateObjectsUsingBlock:^(FLMWheelItemView *item,
                                        NSUInteger index, BOOL *stop) {
        (void)stop;
        item.center =
            [self landscapeWheelLocalPointFromVisualPoint:
                      visualCenters[index].CGPointValue];
    }];
}

- (void)presentLandscapeWheelFromRight:(BOOL)fromRight {
    self.landscapeDirectWheelTaps = YES;
    [self.itemViews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.wheelPinned = NO;
    self.hotspotWindow.hotspotsEnabled = NO;
    self.overlayWindow.userInteractionEnabled = NO;
    self.overlayWindow.windowLevel = self.floatingWindow.windowLevel + 2.0;
    self.wheelTapGesture.enabled = NO;
    self.modalGesture.enabled = NO;

    CGRect bounds = self.landscapeIngressActive
                        ? self.landscapeIngressBounds
                        : FLMVisualScreenBounds();
    if (!FLMBoundsAreLandscape(bounds)) {
        self.landscapeDirectWheelTaps = NO;
        return;
    }
    self.landscapeIngressActive = YES;
    self.landscapeIngressBounds = bounds;
    UIEdgeInsets rawSafeInsets = self.overlayWindow.safeAreaInsets;
    CGFloat notchInset = FLMLandscapeNotchAvoidanceInset(rawSafeInsets);
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    CGFloat iconHalf = self.wheelIconSize * 0.5;
    CGFloat centerMargin = iconHalf + 8.0;
    CGFloat safeLeft = notchInset + centerMargin;
    CGFloat safeRight = width - notchInset - centerMargin;
    CGFloat safeTop = centerMargin;
    CGFloat safeBottom = height - centerMargin;
    if (safeRight <= safeLeft || safeBottom <= safeTop) {
        safeLeft = centerMargin;
        safeRight = width - centerMargin;
        safeTop = centerMargin;
        safeBottom = height - centerMargin;
    }
    CGPoint anchor = CGPointMake(fromRight ? safeRight : safeLeft, safeBottom);
    FLMWheelPlan plan = FLMWheelResolvePlan(
        self.itemIdentifiers.count, self.wheelRadius, self.wheelIconSize,
        fromRight, safeLeft, safeTop, safeRight, safeBottom);

    NSMutableArray<FLMWheelItemView *> *views = [NSMutableArray array];
    NSMutableArray<NSValue *> *visualCenters = [NSMutableArray array];
    NSUInteger itemIndex = 0;
    for (NSUInteger ring = 0; ring < plan.ringCount; ring++) {
        FLMWheelRingPlan ringPlan = plan.rings[ring];
        for (NSUInteger position = 0; position < ringPlan.count; position++) {
            CGPoint visualCenter = FLMWheelRingPoint(plan, ringPlan, position);
            NSString *identifier = self.itemIdentifiers[itemIndex++];
            FLMWheelItemView *item =
                [[FLMWheelItemView alloc] initWithIdentifier:identifier
                                                       image:FLMApplicationIcon(identifier)
                                                        size:self.wheelIconSize];
            UITapGestureRecognizer *itemTap =
                [[UITapGestureRecognizer alloc]
                    initWithTarget:self
                            action:@selector(handleLandscapeWheelItemTap:)];
            itemTap.cancelsTouchesInView = YES;
            itemTap.delaysTouchesBegan = NO;
            itemTap.delaysTouchesEnded = NO;
            [item addGestureRecognizer:itemTap];
            [visualCenters addObject:[NSValue valueWithCGPoint:visualCenter]];
            item.center = [self landscapeWheelLocalPointFromVisualPoint:visualCenter];
            item.alpha = 0.0;
            item.transform = CGAffineTransformMakeScale(0.42, 0.42);
            [self.wheelContainer addSubview:item];
            [views addObject:item];
        }
    }
    self.itemViews = views;
    self.landscapeWheelVisualCenters = visualCenters;
    self.overlayWindow.hidden = NO;
    self.wheelContainer.alpha = 1.0;
    // Showing the window can trigger one more layout pass that moves the
    // container, so re-derive every item centre from its stored physical point
    // and keep rendering and hit-testing in the same space.
    [self.wheelContainer setNeedsLayout];
    [self.wheelContainer layoutIfNeeded];
    [self synchronizeLandscapeWheelItemCenters];
    [self beginFloatingHighRefreshLeaseForDuration:0.56];
    [views enumerateObjectsUsingBlock:^(
               FLMWheelItemView *item, NSUInteger index, BOOL *stop) {
        (void)stop;
        [UIView animateWithDuration:0.44
                              delay:MIN((NSTimeInterval)index * 0.018, 0.12)
             usingSpringWithDamping:0.72
              initialSpringVelocity:0.55
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
                             item.alpha = 1.0;
                             item.transform = CGAffineTransformIdentity;
                         }
                         completion:nil];
    }];
    FLMEnqueueDiagnosticLine(
        @"sb landscape-wheel-present side=%@ bounds=%@ notchInset=%.1f safe={%.1f,%.1f,%.1f,%.1f} anchor={%.1f,%.1f} rings=%lu radius=%.1f span=%.1f count=%lu mode=%@ rawInsets={%.1f,%.1f,%.1f,%.1f} overlay=%@ root=%@",
        fromRight ? @"right" : @"left", NSStringFromCGRect(bounds),
        notchInset, safeTop, safeLeft, safeBottom, safeRight,
        anchor.x, anchor.y, (unsigned long)plan.ringCount,
        plan.rings[0].radius,
        (plan.rings[0].endAngle - plan.rings[0].startAngle) * 180.0 /
            (CGFloat)M_PI,
        (unsigned long)plan.rings[0].count,
        FLMLandscapeRawCoordinateModeName(self.landscapeIngressRawMode),
        rawSafeInsets.top, rawSafeInsets.left, rawSafeInsets.bottom,
        rawSafeInsets.right, NSStringFromCGRect(self.overlayWindow.frame),
        NSStringFromCGRect(self.wheelContainer.frame));
    if (plan.ringCount > 1) {
        NSMutableString *ringSummary = [NSMutableString string];
        for (NSUInteger ring = 0; ring < plan.ringCount; ring++) {
            [ringSummary
                appendFormat:@"%@r%lu=%.1f/%.1f/%lu",
                             ring == 0 ? @"" : @";", (unsigned long)ring,
                             plan.rings[ring].radius,
                             (plan.rings[ring].endAngle -
                              plan.rings[ring].startAngle) *
                                 180.0 / (CGFloat)M_PI,
                             (unsigned long)plan.rings[ring].count];
        }
        FLMEnqueueDiagnosticLine(@"sb landscape-wheel-rings side=%@ %@",
                                 fromRight ? @"right" : @"left", ringSummary);
    }

    // The wheel's bounds are not proof that it renders in the right place. Log
    // the scene orientation, both transforms and the container's rect in the
    // real screen coordinate space, plus one item's window-space rect, so a
    // rotation between the container space and the display space is visible.
    UIWindowScene *wheelScene = self.overlayWindow.windowScene;
    UIScreen *diagnosticScreen = self.overlayWindow.screen ?: [UIScreen mainScreen];
    id<UICoordinateSpace> diagnosticScreenSpace =
        diagnosticScreen ? diagnosticScreen.coordinateSpace : nil;
    CGRect containerInScreen =
        diagnosticScreenSpace
            ? [self.wheelContainer
                  convertRect:self.wheelContainer.bounds
            toCoordinateSpace:diagnosticScreenSpace]
            : CGRectNull;
    FLMWheelItemView *probeItem = views.firstObject;
    FLMEnqueueDiagnosticLine(
        @"sb landscape-wheel-space sceneOrientation=%ld sceneBounds=%@ windowTransform=%@ rootTransform=%@ screenBounds=%@ screenSpaceBounds=%@ containerInScreen=%@ itemCount=%lu probeCenter={%.1f,%.1f} probeInWindow=%@ probeInScreen=%@",
        (long)(wheelScene ? wheelScene.interfaceOrientation
                           : UIInterfaceOrientationUnknown),
        NSStringFromCGRect(wheelScene ? wheelScene.coordinateSpace.bounds
                                      : CGRectNull),
        NSStringFromCGAffineTransform(self.overlayWindow.transform),
        NSStringFromCGAffineTransform(self.wheelContainer.transform),
        NSStringFromCGRect(diagnosticScreen ? diagnosticScreen.bounds : CGRectNull),
        NSStringFromCGRect(diagnosticScreenSpace ? diagnosticScreenSpace.bounds
                                                 : CGRectNull),
        NSStringFromCGRect(containerInScreen), (unsigned long)views.count,
        probeItem ? probeItem.center.x : 0.0,
        probeItem ? probeItem.center.y : 0.0,
        probeItem ? NSStringFromCGRect(
                        [probeItem convertRect:probeItem.bounds
                                        toView:self.overlayWindow])
                  : @"<none>",
        probeItem && diagnosticScreenSpace
            ? NSStringFromCGRect([probeItem convertRect:probeItem.bounds
                                      toCoordinateSpace:diagnosticScreenSpace])
            : @"<none>");
}

- (void)updateHighlightForPoint:(CGPoint)point {
    FLMWheelItemView *nearest =
        [self itemNearPoint:point
            maximumDistance:self.wheelIconSize * 0.5 + 2.0];
    if (nearest == self.highlightedItem) {
        return;
    }
    self.highlightedItem.highlighted = NO;
    self.highlightedItem = nearest;
    self.highlightedItem.highlighted = YES;
    if (@available(iOS 10.0, *)) {
        if (nearest) {
            UISelectionFeedbackGenerator *feedback =
                [[UISelectionFeedbackGenerator alloc] init];
            [feedback selectionChanged];
        }
    }
}

- (FLMWheelItemView *)itemNearPoint:(CGPoint)point maximumDistance:(CGFloat)distance {
    FLMWheelItemView *nearest = nil;
    CGFloat nearestDistance = CGFLOAT_MAX;
    for (FLMWheelItemView *item in self.itemViews) {
        CGFloat itemDistance = hypot(point.x - item.center.x, point.y - item.center.y);
        if (itemDistance < nearestDistance) {
            nearestDistance = itemDistance;
            nearest = item;
        }
    }
    return nearestDistance <= distance ? nearest : nil;
}

- (void)pinWheel {
    if (self.overlayWindow.hidden || self.wheelPinned) {
        return;
    }
    self.highlightedItem.highlighted = NO;
    self.highlightedItem = nil;
    self.wheelPinned = YES;
    self.hotspotWindow.hotspotsEnabled = NO;
    self.overlayWindow.userInteractionEnabled = YES;
    BOOL useWindowSelection = FLMDisplayIsLandscape() ||
                              self.landscapeIngressActive ||
                              !self.usesSystemGestureManager;
    self.modalGesture.enabled =
        self.usesSystemGestureManager && !useWindowSelection;
    self.wheelTapGesture.enabled = useWindowSelection;
    FLMEnqueueDiagnosticLine(
        @"sb wheel-pinned selectionRoute=%@ visual=%@ window=%@ direct=%d",
        self.landscapeDirectWheelTaps ? @"landscape-items" :
        (useWindowSelection ? @"window" : @"system"),
        NSStringFromCGRect(FLMVisualScreenBounds()),
        NSStringFromCGRect(FLMSpringBoardWindowBounds()),
        self.landscapeDirectWheelTaps);
    [self beginLockMonitoring];
    [self beginFloatingHighRefreshLeaseForDuration:0.44];
    [UIView animateWithDuration:0.32
                          delay:0.0
         usingSpringWithDamping:0.76
          initialSpringVelocity:0.25
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         for (FLMWheelItemView *item in self.itemViews) {
                             item.transform = CGAffineTransformIdentity;
                             item.alpha = 1.0;
                         }
                     }
                     completion:nil];
}

- (void)handleWheelTap:(UITapGestureRecognizer *)gesture {
    if (!self.wheelPinned) {
        return;
    }
    CGPoint point = [gesture locationInView:self.wheelContainer];
    FLMWheelItemView *item =
        [self itemNearPoint:point
            maximumDistance:self.wheelIconSize * 0.5 + 8.0];
    if (self.landscapeDirectWheelTaps && item) {
        // The item's own recognizer carries the exact identifier.
        return;
    }
    FLMEnqueueDiagnosticLine(
        @"sb wheel-window-select point={%.1f,%.1f} selected=%@",
        point.x, point.y, item.identifier ?: @"<none>");
    [self dismissWheelLaunchingItem:item];
}

- (void)handleLandscapeWheelItemTap:(UITapGestureRecognizer *)gesture {
    if (!self.wheelPinned ||
        gesture.state != UIGestureRecognizerStateEnded ||
        ![gesture.view isKindOfClass:[FLMWheelItemView class]]) {
        return;
    }
    FLMWheelItemView *item = (FLMWheelItemView *)gesture.view;
    [self synchronizeLandscapeWheelItemCenters];
    CGPoint point = [gesture locationInView:self.wheelContainer];
    CGPoint windowPoint = [gesture locationInView:self.overlayWindow];
    FLMEnqueueDiagnosticLine(
        @"sb landscape-wheel-item-select point={%.1f,%.1f} windowPoint={%.1f,%.1f} selected=%@ center={%.1f,%.1f} itemInWindow=%@",
        point.x, point.y, windowPoint.x, windowPoint.y,
        item.identifier ?: @"<none>", item.center.x, item.center.y,
        NSStringFromCGRect([item convertRect:item.bounds
                                      toView:self.overlayWindow]));
    [self dismissWheelLaunchingItem:item];
}

- (void)dismissWheelLaunchingItem:(FLMWheelItemView *)item {
    NSString *selectedIdentifier = [item.identifier copy];
    FLMEnqueueDiagnosticLine(
        @"sb wheel-dismiss selected=%@ pinned=%d landscape=%d",
        selectedIdentifier ?: @"<none>", self.wheelPinned,
        FLMDisplayIsLandscape());
    BOOL selectedIsCurrentFloating =
        !self.floatingWindow.hidden && self.floatingIdentifier.length > 0 &&
        [selectedIdentifier isEqualToString:self.floatingIdentifier];
    BOOL selectedIsFrontmost =
        selectedIdentifier.length > 0 &&
        [selectedIdentifier isEqualToString:FLMFrontmostApplicationIdentifier()];
    if (selectedIdentifier.length > 0 && !selectedIsCurrentFloating &&
        !selectedIsFrontmost &&
        ![selectedIdentifier isEqualToString:FLYME_LOCK_SCREEN_ITEM] &&
        FLMPrewarmApplicationIdentifier(selectedIdentifier)) {
        // Start the suspended scene while the wheel is completing its existing
        // dismissal animation. This gives scene creation a 240 ms head start.
        self.prewarmedIdentifier = selectedIdentifier;
    } else {
        self.prewarmedIdentifier = nil;
    }
    self.highlightedItem.highlighted = NO;
    self.highlightedItem = nil;
    self.wheelPinned = NO;
    self.modalGesture.enabled = NO;
    self.wheelTapGesture.enabled = !self.landscapeDirectWheelTaps;
    self.landscapeDirectWheelTaps = NO;
    self.overlayWindow.userInteractionEnabled = NO;
    // Restore the overlay below the floating window now that the wheel no
    // longer needs to sit above a visible card.
    self.overlayWindow.windowLevel = UIWindowLevelAlert + 91.0;
    [self refreshWheelPriorityWindow];
    [self stopLockMonitoringIfIdle];
    if (self.overlayWindow.hidden) {
        [self.itemViews makeObjectsPerformSelector:@selector(removeFromSuperview)];
        self.itemViews = @[];
        if (item) {
            [self activateIdentifier:item.identifier];
        }
        if (self.floatingWindow.hidden) {
            self.landscapeIngressActive = NO;
            self.landscapeIngressRawMode =
                FLMLandscapeRawCoordinateModeUnknown;
        }
        return;
    }

    [self beginFloatingHighRefreshLeaseForDuration:0.24];
    [UIView animateWithDuration:0.24
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseIn
                     animations:^{
                         self.wheelContainer.alpha = 0.0;
                         for (FLMWheelItemView *itemView in self.itemViews) {
                             itemView.transform = CGAffineTransformMakeScale(0.78, 0.78);
                             itemView.alpha = 0.0;
                         }
                     }
                     completion:^(BOOL finished) {
                         (void)finished;
                         self.overlayWindow.hidden = YES;
                         self.wheelContainer.alpha = 1.0;
                         [self.itemViews makeObjectsPerformSelector:@selector(removeFromSuperview)];
                         self.itemViews = @[];
                         if (item) {
                             [self activateIdentifier:item.identifier];
                         }
                         if (self.floatingWindow.hidden) {
                             self.landscapeIngressActive = NO;
                             self.landscapeIngressRawMode =
                                 FLMLandscapeRawCoordinateModeUnknown;
                         }
                     }];
}

- (void)handleFloatingBackdropTap:(UIGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded ||
        self.floatingWindow.hidden) {
        return;
    }
    FLMOutsideTapGestureRecognizer *outsideGesture =
        (FLMOutsideTapGestureRecognizer *)gesture;
    CGPoint point = [self visualPointForGesture:gesture];
    FLMDiagnosticLog(
        @"sb backdrop-ended authorized=%d point={%.1f,%.1f} keyboardVisible=%d interaction=%d keyboardFrame=%@ card=%@",
        outsideGesture.outsideCloseAuthorized, point.x, point.y,
        self.floatingKeyboardVisible,
        self.floatingKeyboardInteractionSessionActive,
        NSStringFromCGRect([self floatingKeyboardInteractionFrame]),
        NSStringFromCGRect(self.floatingContainer.frame));
    if (self.floatingCloseInputArmed &&
        outsideGesture.outsideCloseAuthorized &&
        CACurrentMediaTime() >= self.floatingOpenCloseGuardUntil) {
        FLMDiagnosticLog(@"sb close-reason=backdrop-tap");
        [self closeFloatingWindowKeepingApplication:YES];
    }
}

- (void)handleFloatingExclusiveGesture:(UIGestureRecognizer *)gesture {
    if (self.floatingWindow.hidden || self.floatingDocked) {
        self.floatingExclusiveTapEligible = NO;
        return;
    }

    CGPoint point = [self visualPointForGesture:gesture];
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            self.floatingExclusiveStartPoint =
                ((FLMCornerGestureRecognizer *)gesture)
                    .flmAuthorizedStartPoint;
            self.floatingExclusiveStartTimestamp = CACurrentMediaTime();
            self.floatingExclusiveTapEligible =
                ((FLMCornerGestureRecognizer *)gesture)
                    .flmOutsideCloseAuthorized &&
                ((FLMCornerGestureRecognizer *)gesture)
                        .flmFirstTouchTimestamp > 0.0;
            FLMDiagnosticLog(
                @"sb exclusive-began authorized=%d eligible=%d delegatePoint={%.1f,%.1f} callbackPoint={%.1f,%.1f} keyboardVisible=%d interaction=%d currentDomain=%d",
                ((FLMCornerGestureRecognizer *)gesture).flmOutsideCloseAuthorized,
                self.floatingExclusiveTapEligible,
                self.floatingExclusiveStartPoint.x,
                self.floatingExclusiveStartPoint.y, point.x, point.y,
                self.floatingKeyboardVisible,
                self.floatingKeyboardInteractionSessionActive,
                [self pointIsInsideFloatingInteractionDomain:point]);
            break;
        case UIGestureRecognizerStateChanged:
            if (self.floatingExclusiveTapEligible &&
                hypot(point.x - self.floatingExclusiveStartPoint.x,
                      point.y - self.floatingExclusiveStartPoint.y) > 12.0) {
                self.floatingExclusiveTapEligible = NO;
            }
            break;
        case UIGestureRecognizerStateEnded: {
            BOOL shouldClose =
                self.floatingCloseInputArmed &&
                self.floatingExclusiveTapEligible &&
                CACurrentMediaTime() >= self.floatingOpenCloseGuardUntil &&
                CACurrentMediaTime() - self.floatingExclusiveStartTimestamp <= 0.35 &&
                hypot(point.x - self.floatingExclusiveStartPoint.x,
                      point.y - self.floatingExclusiveStartPoint.y) <= 12.0;
            self.floatingExclusiveTapEligible = NO;
            if (shouldClose && !self.floatingWindow.hidden && !self.floatingDocked &&
                ((FLMCornerGestureRecognizer *)gesture)
                    .flmOutsideCloseAuthorized) {
                FLMDiagnosticLog(
                    @"sb close-reason=exclusive-tap point={%.1f,%.1f}",
                    point.x, point.y);
                [self closeFloatingWindowKeepingApplication:YES];
            }
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            self.floatingExclusiveTapEligible = NO;
            break;
        default:
            break;
    }
}

- (void)activateFloatingDockDragForGeneration:(NSUInteger)generation {
    if (generation != self.floatingDockInputGeneration ||
        !self.floatingDocked || self.floatingDockHidden ||
        self.floatingWindow.hidden ||
        !self.floatingDockInputSessionActive ||
        self.floatingDockInputMode != FLMFloatingDockInputModeCardDrag ||
        self.floatingDockInputTargetsResize ||
        (self.floatingDockInputGesture.state != UIGestureRecognizerStateBegan &&
         self.floatingDockInputGesture.state != UIGestureRecognizerStateChanged &&
         self.floatingDockInputGesture.state != UIGestureRecognizerStateEnded)) {
        return;
    }
    self.floatingDockGlobalDragActivated = YES;
    FLMDiagnosticLog(
        @"sb dock-input-activated generation=%lu start={%.1f,%.1f} center={%.1f,%.1f}",
        (unsigned long)generation,
        self.floatingDockDragStartPoint.x,
        self.floatingDockDragStartPoint.y,
        self.floatingDockDragInitialCenter.x,
        self.floatingDockDragInitialCenter.y);
    UIView *rootView = [self floatingLayoutView];
    [rootView bringSubviewToFront:self.floatingContainer];
    [rootView bringSubviewToFront:self.floatingResizeHandle];
    // A card drag may be reclassified as an outward hide gesture. Keep the
    // handle above the remote app surface from the start so its first reveal
    // frame cannot be occluded by the card and then suddenly appear later.
    [rootView bringSubviewToFront:self.floatingHandle];
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback =
            [[UIImpactFeedbackGenerator alloc]
                initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
    }
}

- (void)setFloatingDockRoutingSuppressed:(BOOL)suppressed {
    FLMFloatingWindow *floatingWindow =
        (FLMFloatingWindow *)self.floatingWindow;
    floatingWindow.suppressesCornerRoutingDuringDockGesture = suppressed;
}

- (CGRect)floatingContainerPresentationFrame {
    CGRect frame = self.floatingContainer.frame;
    CALayer *presentationLayer =
        (CALayer *)self.floatingContainer.layer.presentationLayer;
    if (!presentationLayer) {
        return frame;
    }
    CGRect candidate = presentationLayer.frame;
    BOOL finite = isfinite(CGRectGetMinX(candidate)) &&
                  isfinite(CGRectGetMinY(candidate)) &&
                  isfinite(CGRectGetWidth(candidate)) &&
                  isfinite(CGRectGetHeight(candidate));
    if (finite && !CGRectIsNull(candidate) && !CGRectIsEmpty(candidate) &&
        CGRectGetWidth(candidate) > 1.0 && CGRectGetHeight(candidate) > 1.0) {
        frame = candidate;
    }
    return frame;
}

- (CGFloat)floatingDockHiddenFractionForFrame:(CGRect)frame {
    CGRect bounds = [self floatingLayoutView].bounds;
    CGFloat width = MAX(1.0, CGRectGetWidth(frame));
    CGFloat hiddenAmount =
        self.floatingDockedOnRight
            ? MAX(0.0, CGRectGetMaxX(frame) - CGRectGetMaxX(bounds))
            : MAX(0.0, CGRectGetMinX(bounds) - CGRectGetMinX(frame));
    return MIN(1.0, MAX(0.0, hiddenAmount / width));
}

- (void)finishFloatingDockEntryImmediatelyForControl {
    if (!self.floatingDockEntrySettleActive ||
        self.floatingWindow.hidden || self.floatingIdentifier.length == 0) {
        return;
    }

    // A new touch arrived while the entry spring was still running. Finish
    // that spring in this main-thread turn, then let the same touch enter the
    // normal dock classifier. This prevents the remote Scene from seeing the
    // touch and keeps tap/drag/outward-hide semantics available immediately.
    self.floatingDockEntrySettleGeneration += 1;
    self.floatingDockEntrySettleActive = NO;
    [self.floatingContainer.layer removeAllAnimations];
    [self.floatingDimView.layer removeAllAnimations];
    [self.floatingHandle.layer removeAllAnimations];
    [self.floatingHandleBar.layer removeAllAnimations];

    CGRect target = self.floatingDockEntryTargetFrame;
    if (CGRectIsNull(target) || CGRectIsEmpty(target)) {
        target = [self dockedFloatingFrameOnRight:self.floatingDockedOnRight
                                             width:self.floatingDockWidth];
    }
    [UIView performWithoutAnimation:^{
        self.floatingContainer.transform = CGAffineTransformIdentity;
        self.floatingContainer.frame = target;
        self.floatingContainer.layer.cornerRadius =
            22.0 * self.floatingDockWidth / FLMCenteredCardWidth;
        self.floatingDockShadowView.transform = CGAffineTransformIdentity;
        self.floatingDockShadowView.frame = target;
        self.floatingDockShadowView.layer.cornerRadius =
            22.0 * self.floatingDockWidth / FLMCenteredCardWidth;
        self.floatingDocked = YES;
        self.floatingDockHidden = NO;
        self.floatingDimView.alpha = 0.0;
        self.floatingHandleBar.alpha = 1.0;
        self.floatingHandleBar.transform = CGAffineTransformIdentity;
        [self layoutFloatingHostView];
    }];
    self.floatingDockTransitionActive = NO;
    self.floatingDockControlArmed = NO;
    self.floatingDockEntryTargetFrame = CGRectNull;
    self.floatingDockTouchCaptureFrame = CGRectNull;
    self.lastObservedFrontmostIdentifier =
        FLMFrontmostApplicationIdentifier();
    self.floatingExternalActivationArmed =
        ![self.lastObservedFrontmostIdentifier
            isEqualToString:self.floatingIdentifier];
    [self configureFloatingInteractionForDockedState];
    if (self.floatingKeyboardSessionGeneration != 0) {
        [self endFloatingKeyboardSession];
    }
    FLMDiagnosticLog(
        @"sb dock-entry-control-handoff generation=%lu frame=%@",
        (unsigned long)self.floatingDockEntrySettleGeneration,
        NSStringFromCGRect(target));
}

- (void)updateFloatingDockTouchGate {
    FLMDockTouchGateWindow *gate = self.floatingDockTouchGateWindow;
    if (!gate || !self.floatingWindow) {
        return;
    }
    CGRect visualBounds = [self floatingLayoutView].bounds;
    gate.visualBounds = visualBounds;
    gate.visualOrientation =
        [self isLandscapeFloatingSession]
            ? self.floatingLandscapeInterfaceOrientation
            : UIInterfaceOrientationPortrait;
    gate.wheelPriorityActive = self.enabled && !self.wheelPinned &&
                               self.itemIdentifiers.count > 0 &&
                               !FLMDeviceIsLocked();

    BOOL active = !self.floatingWindow.hidden &&
                  (self.floatingDocked || self.floatingDockHidden ||
                   self.floatingDockTransitionActive ||
                   self.floatingDockControlArmed);
    gate.dockTouchGateEnabled = active;
    if (!active) {
        gate.dockCardFrame = CGRectNull;
        gate.dockHandleFrame = CGRectNull;
        gate.dockResizeFrame = CGRectNull;
        gate.userInteractionEnabled = NO;
        gate.hidden = YES;
        return;
    }

    CGRect cardFrame = self.floatingContainer.frame;
    if (self.floatingDockTransitionActive &&
        !CGRectIsNull(self.floatingDockTouchCaptureFrame) &&
        !CGRectIsEmpty(self.floatingDockTouchCaptureFrame)) {
        // The gate is intentionally static during the compositor spring. A
        // union of the source and target frames owns the whole swept path
        // without rebuilding a window's hit-test geometry at 120 Hz.
        cardFrame = self.floatingDockTouchCaptureFrame;
    }
    gate.dockCardFrame = self.floatingDockHidden ? CGRectNull : cardFrame;
    gate.dockHandleFrame = !self.floatingHandle.hidden
                               ? self.floatingHandle.frame
                               : CGRectNull;
    gate.dockResizeFrame = (!self.floatingDockHidden &&
                            !self.floatingResizeHandle.hidden)
                               ? self.floatingResizeHandle.frame
                               : CGRectNull;
    gate.userInteractionEnabled = YES;
    gate.hidden = NO;
}

- (void)configureFloatingDisplayLinkForMaximumRefresh:(CADisplayLink *)displayLink {
    if (!displayLink) {
        return;
    }
    NSInteger maximumFramesPerSecond = [UIScreen mainScreen].maximumFramesPerSecond;
    if (maximumFramesPerSecond <= 0) {
        maximumFramesPerSecond = 60;
    }
    // Active gestures and animations are never voluntarily reduced to 60 Hz.
    // Idle power is controlled by invalidating these display links, not by
    // lowering the refresh target while the user can see motion.
    if ([displayLink respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        displayLink.preferredFramesPerSecond = maximumFramesPerSecond;
    }
    if (@available(iOS 15.0, *)) {
        float maximumRate = (float)maximumFramesPerSecond;
        displayLink.preferredFrameRateRange =
            CAFrameRateRangeMake(maximumRate, maximumRate, maximumRate);
    }
}

- (void)ensureFloatingDockInputDisplayLink {
    if (self.floatingDockInputDisplayLink) {
        self.floatingDockInputDisplayLink.paused = NO;
        return;
    }
    CADisplayLink *displayLink =
        [CADisplayLink displayLinkWithTarget:self
                                    selector:@selector(flushFloatingDockInputFrame:)];
    [self configureFloatingDisplayLinkForMaximumRefresh:displayLink];
    self.floatingDockInputDisplayLink = displayLink;
    [displayLink addToRunLoop:[NSRunLoop mainRunLoop]
                       forMode:NSRunLoopCommonModes];
    FLMDiagnosticLog(
        @"sb dock-displaylink-start screenMaxFPS=%ld prewarmed=1 runLoop=common",
        (long)MAX(60, [UIScreen mainScreen].maximumFramesPerSecond));
}

- (void)beginFloatingHighRefreshLeaseForDuration:(NSTimeInterval)duration {
    duration = isfinite(duration) ? MIN(2.0, MAX(0.08, duration)) : 0.08;
    self.floatingHighRefreshDeadline = MAX(self.floatingHighRefreshDeadline,
                                          CACurrentMediaTime() + duration + 0.12);
    if (!self.floatingHighRefreshDisplayLink) {
        CADisplayLink *displayLink =
            [CADisplayLink displayLinkWithTarget:self
                                        selector:@selector(tickFloatingHighRefreshDisplayLink:)];
        [self configureFloatingDisplayLinkForMaximumRefresh:displayLink];
        self.floatingHighRefreshDisplayLink = displayLink;
        [displayLink addToRunLoop:[NSRunLoop mainRunLoop]
                           forMode:NSRunLoopCommonModes];
    }
}

- (void)tickFloatingHighRefreshDisplayLink:(CADisplayLink *)displayLink {
    BOOL idle = self.floatingWindow.hidden && self.overlayWindow.hidden;
    if (idle || CACurrentMediaTime() >= self.floatingHighRefreshDeadline) {
        [displayLink invalidate];
        if (displayLink == self.floatingHighRefreshDisplayLink) {
            self.floatingHighRefreshDisplayLink = nil;
            self.floatingHighRefreshDeadline = 0;
        }
    }
}

- (void)queueFloatingDockInputUpdateForPoint:(CGPoint)point {
    if (self.floatingWindow.hidden ||
        ((!self.floatingDocked && !self.floatingDockHidden) &&
         !self.floatingDockTransitionActive)) {
        return;
    }
    self.floatingDockInputFramePoint = point;
    self.floatingDockInputFrameGeneration = self.floatingDockInputGeneration;
    self.floatingDockInputFramePending = YES;
    [self ensureFloatingDockInputDisplayLink];
}

- (void)flushFloatingDockInputFrame:(CADisplayLink *)displayLink {
    (void)displayLink;
    // Keep one uninterrupted max-refresh cadence for the complete gesture.
    // Pausing after every vsync and waiting for the next touch sample creates
    // visible cadence gaps on ProMotion devices. The link is invalidated by
    // the gesture terminal path instead.
    if (!self.floatingDockInputSessionActive || self.floatingWindow.hidden) {
        [self cancelFloatingDockInputUpdates];
        return;
    }
    if (!self.floatingDockInputFramePending) {
        return;
    }
    self.floatingDockInputFramePending = NO;
    if (self.floatingDockInputFrameGeneration !=
            self.floatingDockInputGeneration ||
        self.floatingWindow.hidden) {
        return;
    }
    [self applyFloatingDockInputPoint:self.floatingDockInputFramePoint];
}

- (void)flushFloatingDockInputFrameImmediately {
    [self flushFloatingDockInputFrame:nil];
}

- (void)cancelFloatingDockInputUpdates {
    self.floatingDockInputFramePending = NO;
    [self.floatingDockInputDisplayLink invalidate];
    self.floatingDockInputDisplayLink = nil;
}

- (void)applyFloatingDockInputPoint:(CGPoint)point {
    if (self.floatingWindow.hidden) {
        return;
    }
    if (self.floatingDockInputMode == FLMFloatingDockInputModeHiddenReveal ||
        self.floatingDockHideGestureActive) {
        [self updateFloatingDockHiddenRevealForPoint:point];
        return;
    }

    UIView *rootView = [self floatingLayoutView];
    if (self.floatingDockInputMode == FLMFloatingDockInputModeResize ||
        self.floatingDockInputTargetsResize) {
        CGFloat horizontalOutward =
            self.floatingDockedOnRight
                ? self.floatingResizeStartPoint.x - point.x
                : point.x - self.floatingResizeStartPoint.x;
        CGFloat verticalOutward = point.y - self.floatingResizeStartPoint.y;
        CGFloat delta = (horizontalOutward + verticalOutward) * 0.5;
        CGFloat requestedWidth =
            CGRectGetWidth(self.floatingResizeInitialFrame) + delta;
        CGFloat width = requestedWidth;
        if (requestedWidth > FLMMaximumDockWidth) {
            width = FLMMaximumDockWidth +
                    MIN(16.0,
                        (requestedWidth - FLMMaximumDockWidth) * 0.60);
        }
        width = MAX(FLMMinimumDockPresentationWidth, width);
        if (!self.floatingResizeCenterReady && requestedWidth >= 286.0) {
            self.floatingResizeCenterReady = YES;
            if (@available(iOS 10.0, *)) {
                UIImpactFeedbackGenerator *feedback =
                    [[UIImpactFeedbackGenerator alloc]
                        initWithStyle:UIImpactFeedbackStyleMedium];
                [feedback impactOccurred];
            }
        } else if (self.floatingResizeCenterReady && requestedWidth <= 278.0) {
            self.floatingResizeCenterReady = NO;
        }
        CGRect centeredFrame = [self centeredFloatingFrame];
        CGFloat aspectRatio =
            CGRectGetWidth(centeredFrame) /
            MAX(1.0, CGRectGetHeight(centeredFrame));
        CGFloat height = width / MAX(0.1, aspectRatio);
        CGFloat top = CGRectGetMinY(self.floatingResizeInitialFrame);
        CGFloat anchorX =
            self.floatingDockedOnRight
                ? CGRectGetMaxX(self.floatingResizeInitialFrame)
                : CGRectGetMinX(self.floatingResizeInitialFrame);
        CGRect visualFrame =
            CGRectMake(self.floatingDockedOnRight ? anchorX - width : anchorX,
                       top, width, height);
        CGFloat scale =
            width / MAX(1.0, CGRectGetWidth(self.floatingResizeInitialFrame));
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [UIView performWithoutAnimation:^{
            self.floatingContainer.center =
                CGPointMake(CGRectGetMidX(visualFrame),
                            CGRectGetMidY(visualFrame));
            self.floatingContainer.transform =
                CGAffineTransformMakeScale(scale, scale);
            self.floatingDockWidth = width;
            self.floatingDockVerticalCenter = CGRectGetMidY(visualFrame);
            [self updateFloatingDockAccessoryPositions];
        }];
        [CATransaction commit];
        return;
    }
    if (self.floatingDockInputMode != FLMFloatingDockInputModeCardDrag) {
        return;
    }
    CGFloat movement =
        hypot(point.x - self.floatingDockDragStartPoint.x,
              point.y - self.floatingDockDragStartPoint.y);
    if (!self.floatingDockGlobalDragActivated && movement >= 5.0) {
        [self activateFloatingDockDragForGeneration:
                  self.floatingDockInputGeneration];
    }
    if (!self.floatingDockGlobalDragActivated) {
        return;
    }
    CGPoint delta =
        CGPointMake(point.x - self.floatingDockDragStartPoint.x,
                    point.y - self.floatingDockDragStartPoint.y);
    CGRect bounds = rootView.bounds;
    UIEdgeInsets safeInsets = [self floatingLayoutSafeInsets];
    CGFloat halfWidth = CGRectGetWidth(self.floatingContainer.bounds) * 0.5;
    CGFloat halfHeight = CGRectGetHeight(self.floatingContainer.bounds) * 0.5;
    CGPoint center =
        CGPointMake(self.floatingDockDragInitialCenter.x + delta.x,
                    self.floatingDockDragInitialCenter.y + delta.y);
    CGFloat minimumCenterX = safeInsets.left + halfWidth;
    CGFloat maximumCenterX =
        CGRectGetWidth(bounds) - safeInsets.right - halfWidth;
    if (maximumCenterX < minimumCenterX) {
        maximumCenterX = minimumCenterX;
    }
    center.x = MAX(minimumCenterX,
                   MIN(maximumCenterX, center.x));
    center.y = MAX(safeInsets.top + halfHeight,
                   MIN(CGRectGetHeight(bounds) - safeInsets.bottom - halfHeight,
                       center.y));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [UIView performWithoutAnimation:^{
        self.floatingContainer.center = center;
        self.floatingDockVerticalCenter = center.y;
        [self updateFloatingDockAccessoryPositions];
    }];
    [CATransaction commit];
}

- (void)transitionFloatingWindowToHiddenAnimated:(BOOL)animated {
    if (!self.floatingDocked || self.floatingDockHidden ||
        self.floatingWindow.hidden) {
        return;
    }
    [self endFloatingKeyboardSession];
    self.floatingDockHidden = YES;
    self.floatingDockHideReady = NO;
    self.floatingDockTransitionActive = YES;
    [self setFloatingDockRoutingSuppressed:YES];
    CGFloat verticalCenter = CGRectGetMidY(self.floatingContainer.frame);
    self.floatingDockVerticalCenter = verticalCenter;
    CGRect target =
        [self dockedHiddenFloatingFrameOnRight:self.floatingDockedOnRight
                                          width:self.floatingDockWidth
                        preservingVerticalCenter:verticalCenter];
    void (^changes)(void) = ^{
        self.floatingContainer.transform = CGAffineTransformIdentity;
        self.floatingContainer.frame = target;
        self.floatingContainer.layer.cornerRadius =
            22.0 * self.floatingDockWidth / FLMCenteredCardWidth;
        self.floatingDockShadowView.alpha = 0.0;
        self.floatingDimView.alpha = 0.0;
        self.floatingResizeHandle.hidden = YES;
        self.floatingHandle.alpha = 1.0;
        self.floatingHandleBar.alpha = 1.0;
        [self layoutFloatingHandleForCurrentContainer];
    };
    void (^completion)(BOOL) = ^(__unused BOOL finished) {
        self.floatingDockTransitionActive = NO;
        [self configureFloatingInteractionForDockedState];
        [self setFloatingDockRoutingSuppressed:NO];
    };
    if (!animated) {
        changes();
        completion(YES);
    } else {
        [self beginFloatingHighRefreshLeaseForDuration:0.30];
        [UIView animateWithDuration:0.30
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseOut |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:changes
                         completion:completion];
    }
}

- (void)finishFloatingDockHiddenGesture:(BOOL)shouldHide
                                atPoint:(CGPoint)point {
    (void)point;
    if (!self.floatingDocked || self.floatingWindow.hidden) {
        [self setFloatingDockRoutingSuppressed:NO];
        return;
    }
    self.floatingDockHideGestureActive = NO;
    self.floatingDockHideReady = NO;
    self.floatingDockInputGeneration += 1;
    [self setFloatingDockRoutingSuppressed:YES];
    [self setFloatingApplicationInputBlocked:YES];
    CGFloat verticalCenter = CGRectGetMidY(self.floatingContainer.frame);
    self.floatingDockVerticalCenter = verticalCenter;
    if (shouldHide) {
        self.floatingDockHidden = YES;
        self.floatingDockTransitionActive = YES;
        CGRect target =
            [self dockedHiddenFloatingFrameOnRight:self.floatingDockedOnRight
                                              width:self.floatingDockWidth
                            preservingVerticalCenter:verticalCenter];
        // Single-stage edge-hide: the grab bar and the card travel together,
        // so the bar glides up from the card's corner to its edge landing
        // spot while the card slides off-screen, instead of popping in.
        UIView *rootView = [self floatingLayoutView];
        CGRect bounds = rootView.bounds;
        CGFloat handleWidth = 44.0;
        CGFloat handleHeight = 72.0;
        CGRect handleLanding =
            CGRectMake(self.floatingDockedOnRight
                           ? CGRectGetWidth(bounds) - handleWidth
                           : 0.0,
                       CGRectGetMinY(self.floatingContainer.frame) + 24.0,
                       handleWidth,
                       handleHeight);
        // Start the glide from wherever the drag left the bar.  The old code
        // snapped the bar back to the L-grip's frame at the card corner,
        // which was already off-screen at release, so the bar visibly flew
        // in from nowhere instead of continuing its travel to the edge.
        CGRect handleStart = self.floatingHandle.frame;
        if (CGRectIsEmpty(handleStart)) {
            handleStart = handleLanding;
        }
        self.floatingHandle.hidden = NO;
        self.floatingHandle.userInteractionEnabled = NO;
        self.floatingHandle.frame = handleStart;
        // Switch the grab bar to its hidden vertical form before the glide
        // animation starts, so the bar travels as a vertical line instead of
        // flying out as a horizontal strip and then snapping vertical at the
        // end.
        self.floatingHandleBar.frame =
            CGRectMake(self.floatingDockedOnRight ? 36.0 : 3.0,
                       floor((CGRectGetHeight(handleStart) - 44.0) * 0.5),
                       5.0,
                       44.0);
        [self.floatingPresentationView
            bringSubviewToFront:self.floatingHandle];
        [self beginFloatingHighRefreshLeaseForDuration:0.34];
        [UIView animateWithDuration:0.34
                              delay:0.0
             usingSpringWithDamping:0.92
              initialSpringVelocity:0.20
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
                             self.floatingContainer.transform =
                                 CGAffineTransformIdentity;
                             self.floatingContainer.frame = target;
        self.floatingContainer.layer.cornerRadius =
            22.0 * self.floatingDockWidth /
                FLMCenteredCardWidth;
        self.floatingHandle.frame = handleLanding;
                             self.floatingHandle.alpha = 1.0;
                             self.floatingHandleBar.alpha = 1.0;
                             self.floatingDimView.alpha = 0.0;
                         }
                          completion:^(__unused BOOL finished) {
                              self.floatingDockTransitionActive = NO;
                              [self configureFloatingInteractionForDockedState];
                              [self setFloatingDockRoutingSuppressed:NO];
                          }];
        return;
    }

    // Revealing the hidden dock is a state handoff, not a presentation that
    // needs a settle animation.  Keeping a transition window here lets the
    // system recognizers arbitrate one more touch against the old hidden
    // route, which is the source of the occasional card-content activation.
    self.floatingDockHidden = NO;
    self.floatingDockTransitionActive = YES;
    CGRect target =
        [self dockedFloatingFrameOnRight:self.floatingDockedOnRight
                                   width:self.floatingDockWidth
                 preservingVerticalCenter:verticalCenter];
    [self setFloatingApplicationInputBlocked:YES];
    // No UIView animation and no completion callback: apply the complete
    // docked geometry and interaction state in this one main-thread turn.
    // UIKit cannot deliver another touch between these statements, and the
    // next touch sees the final docked route immediately.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [UIView performWithoutAnimation:^{
        self.floatingContainer.transform = CGAffineTransformIdentity;
        self.floatingContainer.frame = target;
        self.floatingContainer.layer.cornerRadius =
            22.0 * self.floatingDockWidth / FLMCenteredCardWidth;
        self.floatingDockShadowView.alpha = 0.0;
        self.floatingDimView.alpha = 0.0;
        self.floatingResizeHandle.hidden = YES;
        self.floatingHandle.alpha = 0.0;
        self.floatingHandleBar.alpha = 1.0;
        [self layoutFloatingHandleForCurrentContainer];
    }];
    [CATransaction commit];
    self.floatingDockTransitionActive = NO;
    // The reveal gesture has ended; do not carry the old transition cutoff
    // into the first deliberate touch on the newly docked card.
    self.floatingDockInputBlockedUntilNextTouch = NO;
    self.floatingDockInputBlockCutoffTimestamp = 0.0;
    [self configureFloatingInteractionForDockedState];
    [self setFloatingDockRoutingSuppressed:NO];
}

- (void)updateFloatingDockHiddenRevealForPoint:(CGPoint)point {
    if (!self.floatingDocked || !self.floatingDockHideGestureActive ||
        self.floatingWindow.hidden) {
        return;
    }
    BOOL revealing = self.floatingDockHidden;
    CGFloat travel = revealing
                         ? (self.floatingDockedOnRight
                                ? self.floatingDockHideStartPoint.x - point.x
                                : point.x - self.floatingDockHideStartPoint.x)
                         : (self.floatingDockedOnRight
                                ? point.x - self.floatingDockHideStartPoint.x
                                : self.floatingDockHideStartPoint.x - point.x);
    travel = MAX(0.0, travel);
    CGFloat distance = MAX(40.0, FLMCenteredDockActivationDistance);
    CGFloat progress = MIN(1.0, travel / distance);
    CGRect start = self.floatingDockHideInitialFrame;
    CGFloat verticalCenter = CGRectGetMidY(start);
    self.floatingDockVerticalCenter = verticalCenter;
    CGRect target = revealing
                        ? [self dockedFloatingFrameOnRight:self.floatingDockedOnRight
                                                       width:self.floatingDockWidth
                                    preservingVerticalCenter:verticalCenter]
                        : [self dockedHiddenFloatingFrameOnRight:self.floatingDockedOnRight
                                                            width:self.floatingDockWidth
                                          preservingVerticalCenter:verticalCenter];
    CGRect visual = CGRectMake(CGRectGetMinX(start) +
                                   (CGRectGetMinX(target) - CGRectGetMinX(start)) * progress,
                               CGRectGetMinY(start) +
                                   (CGRectGetMinY(target) - CGRectGetMinY(start)) * progress,
                               CGRectGetWidth(start) +
                                   (CGRectGetWidth(target) - CGRectGetWidth(start)) * progress,
                               CGRectGetHeight(start) +
                                   (CGRectGetHeight(target) - CGRectGetHeight(start)) * progress);
    // The hidden grab bar tracks the drag from the card edge to its landing
    // position while the card disappears.
    CGRect bounds = [self floatingLayoutView].bounds;
    CGFloat handleWidth = 44.0;
    CGFloat handleHeight = 72.0;
    CGRect hiddenFrame =
        [self dockedHiddenFloatingFrameOnRight:self.floatingDockedOnRight
                                          width:self.floatingDockWidth
                        preservingVerticalCenter:verticalCenter];
    CGRect handleLanding =
        CGRectMake(self.floatingDockedOnRight
                       ? CGRectGetWidth(bounds) - handleWidth
                       : 0.0,
                   CGRectGetMinY(hiddenFrame) + 24.0,
                   handleWidth,
                   handleHeight);
    CGRect handleOrigin = self.floatingDockHideInitialHandleFrame;
    if (CGRectIsEmpty(handleOrigin)) {
        handleOrigin = handleLanding;
    }
    CGFloat hiddenFraction =
        [self floatingDockHiddenFractionForFrame:visual];
    [UIView performWithoutAnimation:^{
        self.floatingContainer.transform = CGAffineTransformIdentity;
        self.floatingContainer.frame = visual;
        self.floatingDockShadowView.alpha = 0.0;
        self.floatingHandle.hidden = NO;
        self.floatingHandle.alpha = 1.0;
        // Opacity is derived from the card's actual off-screen fraction, not
        // from gesture distance. This remains continuous when card-drag hands
        // off to hidden-reveal and mirrors perfectly on the left edge.
        self.floatingHandleBar.alpha = hiddenFraction;
        // Keep the bar in its vertical hidden form while the handle tracks
        // the drag; only the handle container moves, never the bar shape.
        self.floatingHandleBar.frame =
            CGRectMake(self.floatingDockedOnRight ? 36.0 : 3.0,
                       floor((handleHeight - 44.0) * 0.5),
                       5.0,
                       44.0);
        CGFloat handleX =
            revealing
                ? CGRectGetMinX(handleLanding) +
                      (CGRectGetMinX(handleOrigin) -
                       CGRectGetMinX(handleLanding)) *
                          progress
                : CGRectGetMinX(handleOrigin) +
                      (CGRectGetMinX(handleLanding) -
                       CGRectGetMinX(handleOrigin)) *
                          progress;
        CGFloat handleY =
            revealing
                ? CGRectGetMinY(handleLanding) +
                      (CGRectGetMinY(handleOrigin) -
                       CGRectGetMinY(handleLanding)) *
                          progress
                : CGRectGetMinY(handleOrigin) +
                      (CGRectGetMinY(handleLanding) -
                       CGRectGetMinY(handleOrigin)) *
                          progress;
        self.floatingHandle.frame =
            CGRectMake(handleX, handleY, handleWidth, handleHeight);
    }];
    // The current recognizer already owns this touch stream. Rebuilding a
    // sibling window's hit-test geometry on every 120 Hz sample cannot affect
    // the in-flight gesture and only adds main-thread work; the terminal
    // settle path refreshes the gate once with final geometry.
}

- (void)handleFloatingDockInputGesture:(FLMCornerGestureRecognizer *)gesture {
    CGPoint point = [self visualPointForGesture:gesture];
    self.floatingDockInputLatestPoint = point;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        BOOL entryControlTouch =
            self.floatingDockEntryControlTouchPending ||
            (self.floatingDockControlArmed &&
             self.floatingDockEntrySettleActive);
        if (self.floatingDockEntrySettleActive) {
            [self finishFloatingDockEntryImmediatelyForControl];
        }
        self.floatingDockEntryControlTouchPending = NO;
        [self cancelFloatingDockInputUpdates];
        self.floatingDockInputGeneration += 1;
        self.floatingDockInputMode = FLMFloatingDockInputModeNone;
        self.floatingDockInputSessionActive = NO;
        self.floatingDockInputTargetsResize = NO;
        self.floatingDockHideGestureActive = NO;
        self.floatingDockHideReady = NO;
        self.floatingDockHideStartPoint = point;
        self.floatingDockHideInitialFrame = self.floatingContainer.frame;
        self.floatingDockHideInitialHandleFrame = self.floatingHandle.frame;
        self.floatingDockGlobalDragActivated = NO;
        BOOL pointIsOwned = entryControlTouch ||
                            (self.floatingDockHidden
                                ? (CGRectContainsPoint(self.floatingHandle.frame, point) ||
                                   CGRectContainsPoint(CGRectInset(self.floatingHandle.frame,
                                                                  -18.0,
                                                                  -18.0),
                                                        point))
                                : ([self floatingResizeControlContainsPoint:point] ||
                                   CGRectContainsPoint(self.floatingContainer.frame, point)));
        BOOL staleStream =
            self.floatingDockInputBlockedUntilNextTouch &&
            self.floatingDockInputBlockCutoffTimestamp > 0.0 &&
            gesture.flmFirstTouchTimestamp > 0.0 &&
            gesture.flmFirstTouchTimestamp <=
                self.floatingDockInputBlockCutoffTimestamp + 0.001;
        BOOL canBegin = (self.floatingDocked || self.floatingDockHidden) &&
                        !self.floatingWindow.hidden &&
                        !self.floatingDockTransitionActive &&
                        !FLMDeviceIsLocked() && pointIsOwned && !staleStream;
        if (!canBegin) {
            // System-registered recognizers can continue to report the tail
            // of a touch that started before the card became docked.  Mark
            // that stream as foreign so its later Changed/Ended callbacks
            // cannot be mistaken for a fresh dock tap or drag.
            self.floatingDockInputBlockedUntilNextTouch = YES;
            if (self.floatingDockInputBlockCutoffTimestamp <= 0.0) {
                self.floatingDockInputBlockCutoffTimestamp =
                    gesture.flmFirstTouchTimestamp > 0.0
                        ? gesture.flmFirstTouchTimestamp
                        : CACurrentMediaTime();
            }
            if (!self.floatingDockTransitionActive) {
                [self setFloatingDockRoutingSuppressed:NO];
            }
            FLMDiagnosticLog(
                @"sb dock-input-ignored state=began docked=%d hidden=%d transition=%d owned=%d stale=%d blocked=%d point={%.1f,%.1f}",
                self.floatingDocked,
                self.floatingDockHidden,
                self.floatingDockTransitionActive,
                pointIsOwned,
                staleStream,
                self.floatingDockInputBlockedUntilNextTouch,
                point.x,
                point.y);
            return;
        }
        self.floatingDockInputBlockedUntilNextTouch = NO;
        self.floatingDockInputBlockCutoffTimestamp = 0.0;
        [self setFloatingDockRoutingSuppressed:YES];
        if (self.floatingDocked && !self.floatingDockHidden) {
            [self setFloatingApplicationInputBlocked:YES];
        }
        self.floatingDockInputSessionActive = YES;
        self.floatingDockInputMode =
            self.floatingDockHidden
                ? FLMFloatingDockInputModeHiddenReveal
                : (!entryControlTouch &&
                           [self floatingResizeControlContainsPoint:point]
                       ? FLMFloatingDockInputModeResize
                       : FLMFloatingDockInputModeCardDrag);
        self.floatingDockInputTargetsResize =
            self.floatingDockInputMode == FLMFloatingDockInputModeResize;
        // Start the display link at touch-begin, before the first Changed
        // callback. Previously the first several points were applied before a
        // 120 Hz client existed, which made the beginning of every drag feel
        // distinctly more sluggish than the rest of the gesture.
        [self ensureFloatingDockInputDisplayLink];
        FLMDiagnosticLog(
            @"sb dock-input-began mode=%@ generation=%lu point={%.1f,%.1f} frame=%@ hidden=%d side=%@",
            FLMFloatingDockInputModeName(self.floatingDockInputMode),
            (unsigned long)self.floatingDockInputGeneration,
            point.x,
            point.y,
            NSStringFromCGRect(self.floatingContainer.frame),
            self.floatingDockHidden,
            self.floatingDockedOnRight ? @"right" : @"left");
        if (self.floatingDockInputMode == FLMFloatingDockInputModeHiddenReveal) {
            self.floatingDockHideGestureActive = YES;
            self.floatingDockHideStartPoint = point;
            self.floatingDockHideInitialFrame = self.floatingContainer.frame;
            self.floatingDockHideInitialHandleFrame = self.floatingHandle.frame;
            return;
        }
        if (self.floatingDockInputMode == FLMFloatingDockInputModeResize) {
            self.floatingResizeStartPoint = point;
            self.floatingResizeInitialFrame = self.floatingContainer.frame;
            self.floatingResizeCenterReady = NO;
            if (@available(iOS 10.0, *)) {
                UIImpactFeedbackGenerator *feedback =
                    [[UIImpactFeedbackGenerator alloc]
                        initWithStyle:UIImpactFeedbackStyleMedium];
                [feedback impactOccurred];
            }
            return;
        }
        self.floatingDockDragStartPoint = point;
        self.floatingDockDragInitialCenter = self.floatingContainer.center;
        return;
    }

    if (self.floatingDockInputBlockedUntilNextTouch ||
        !self.floatingDockInputSessionActive ||
        self.floatingDockInputMode == FLMFloatingDockInputModeNone) {
        if (gesture.state == UIGestureRecognizerStateEnded ||
            gesture.state == UIGestureRecognizerStateCancelled ||
            gesture.state == UIGestureRecognizerStateFailed) {
            self.floatingDockInputBlockedUntilNextTouch = NO;
            self.floatingDockInputBlockCutoffTimestamp = 0.0;
            self.floatingDockInputSessionActive = NO;
            self.floatingDockInputMode = FLMFloatingDockInputModeNone;
            self.floatingDockInputTargetsResize = NO;
            self.floatingDockInputGeneration += 1;
            [self cancelFloatingDockInputUpdates];
            if (!self.floatingDockTransitionActive) {
                [self setFloatingDockRoutingSuppressed:NO];
            }
        }
        return;
    }

    if ((!self.floatingDocked && !self.floatingDockHidden) ||
        self.floatingWindow.hidden) {
        // The dock can disappear while a touch is in flight.  Do not let the
        // remainder of that touch enter the centered-card tap path.
        self.floatingDockInputBlockedUntilNextTouch = YES;
        if (self.floatingDockInputBlockCutoffTimestamp <= 0.0) {
            self.floatingDockInputBlockCutoffTimestamp =
                gesture.flmFirstTouchTimestamp > 0.0
                    ? gesture.flmFirstTouchTimestamp
                    : CACurrentMediaTime();
        }
        if (gesture.state == UIGestureRecognizerStateEnded ||
            gesture.state == UIGestureRecognizerStateCancelled ||
            gesture.state == UIGestureRecognizerStateFailed) {
            self.floatingDockInputSessionActive = NO;
            self.floatingDockInputMode = FLMFloatingDockInputModeNone;
            self.floatingDockInputTargetsResize = NO;
            self.floatingDockInputBlockCutoffTimestamp = 0.0;
            self.floatingDockInputGeneration += 1;
            [self cancelFloatingDockInputUpdates];
            if (!self.floatingDockTransitionActive) {
                [self setFloatingDockRoutingSuppressed:NO];
            }
        }
        return;
    }

    BOOL terminal = gesture.state == UIGestureRecognizerStateEnded ||
                    gesture.state == UIGestureRecognizerStateCancelled ||
                    gesture.state == UIGestureRecognizerStateFailed;
    if (!terminal) {
        if (self.floatingDockInputMode == FLMFloatingDockInputModeCardDrag) {
            CGFloat horizontalDelta =
                point.x - self.floatingDockHideStartPoint.x;
            CGFloat verticalDelta =
                point.y - self.floatingDockHideStartPoint.y;
            CGFloat outwardTravel = self.floatingDockedOnRight
                                         ? horizontalDelta
                                         : -horizontalDelta;
            BOOL clearHorizontalIntent =
                outwardTravel >= FLMFloatingDockHideIntentDistance &&
                fabs(horizontalDelta) >=
                    fabs(verticalDelta) *
                        FLMFloatingDockHideIntentHorizontalRatio;
            if (clearHorizontalIntent) {
                // Decide hide intent from the touch direction, even if the
                // ordinary card drag has already activated after a few points.
                // The old global-drag gate made a slower left-edge swipe miss
                // hidden mode permanently. Rebase the visual start here so a
                // late mode switch remains continuous instead of jumping back
                // to the touch-down frame.
                self.floatingDockHideStartPoint = point;
                self.floatingDockHideInitialFrame = self.floatingContainer.frame;

                // Rebase the *visible* hidden handle to the card edge at the
                // exact handoff frame. The old path reused floatingHandle.frame,
                // which is the wide horizontal dock hit target below the card
                // on the first hide. Turning that stale frame into a 44x72
                // vertical handle made the white bar visibly fly in from the
                // wrong origin. After one hide/reveal the frame happened to be
                // normalized, explaining why later attempts looked better.
                UIView *rootView = [self floatingLayoutView];
                CGRect rootBounds = rootView.bounds;
                CGRect cardFrame = self.floatingContainer.frame;
                CGFloat handoffWidth = 44.0;
                CGFloat handoffHeight = 72.0;
                CGFloat maximumHandleX =
                    MAX(0.0, CGRectGetWidth(rootBounds) - handoffWidth);
                CGFloat handoffX = self.floatingDockedOnRight
                    ? CGRectGetMaxX(cardFrame) - handoffWidth
                    : CGRectGetMinX(cardFrame);
                handoffX = MAX(0.0, MIN(maximumHandleX, handoffX));
                CGFloat handoffY = MAX(8.0, CGRectGetMinY(cardFrame) + 24.0);
                CGRect handoffFrame =
                    CGRectMake(handoffX, handoffY, handoffWidth, handoffHeight);
                self.floatingDockHideInitialHandleFrame = handoffFrame;
                [UIView performWithoutAnimation:^{
                    self.floatingHandle.hidden = NO;
                    self.floatingHandle.userInteractionEnabled = NO;
                    self.floatingHandle.frame = handoffFrame;
                    self.floatingHandleBar.frame =
                        CGRectMake(self.floatingDockedOnRight ? 36.0 : 3.0,
                                   floor((handoffHeight - 44.0) * 0.5),
                                   5.0,
                                   44.0);
                    self.floatingHandleBar.alpha =
                        [self floatingDockHiddenFractionForFrame:cardFrame];
                    [rootView bringSubviewToFront:self.floatingHandle];
                }];

                self.floatingDockInputMode =
                    FLMFloatingDockInputModeHiddenReveal;
                self.floatingDockHideGestureActive = YES;
                self.floatingDockHideReady = NO;
                self.floatingDockGlobalDragActivated = NO;
                FLMDiagnosticLog(
                    @"sb dock-input-mode-change from=card-drag to=hidden-reveal travel=%.1f point={%.1f,%.1f}",
                    outwardTravel,
                    point.x,
                    point.y);
            }
        }
        [self queueFloatingDockInputUpdateForPoint:point];
        if (self.floatingDockInputMode == FLMFloatingDockInputModeHiddenReveal) {
            CGFloat outwardTravel = self.floatingDockedOnRight
                                         ? point.x - self.floatingDockHideStartPoint.x
                                         : self.floatingDockHideStartPoint.x - point.x;
            self.floatingDockHideReady =
                outwardTravel >= [self effectiveCenteredDockSwipeThreshold];
        }
        return;
    }

    // Always submit the terminal point before deciding where to settle.  The
    // old code only flushed an earlier display-link sample, so a quick release
    // could snap from a stale position or fail to activate the drag at all.
    [self queueFloatingDockInputUpdateForPoint:point];
    [self flushFloatingDockInputFrameImmediately];
    [self cancelFloatingDockInputUpdates];

    FLMFloatingDockInputMode inputMode = self.floatingDockInputMode;
    BOOL wasGlobalDragActivated = self.floatingDockGlobalDragActivated;
    CGFloat movement =
        hypot(point.x - self.floatingDockDragStartPoint.x,
              point.y - self.floatingDockDragStartPoint.y);
    BOOL revealing = self.floatingDockHidden;
    CGFloat outwardTravel = revealing
                                ? (self.floatingDockedOnRight
                                       ? self.floatingDockHideStartPoint.x - point.x
                                       : point.x - self.floatingDockHideStartPoint.x)
                                : (self.floatingDockedOnRight
                                       ? point.x - self.floatingDockHideStartPoint.x
                                       : self.floatingDockHideStartPoint.x - point.x);
    FLMDiagnosticLog(
        @"sb dock-input-ended state=%ld mode=%@ movement=%.1f outward=%.1f global=%d frame=%@",
        (long)gesture.state,
        FLMFloatingDockInputModeName(inputMode),
        movement,
        outwardTravel,
        wasGlobalDragActivated,
        NSStringFromCGRect(self.floatingContainer.frame));

    self.floatingDockInputSessionActive = NO;
    self.floatingDockInputMode = FLMFloatingDockInputModeNone;
    self.floatingDockInputGeneration += 1;

    if (inputMode == FLMFloatingDockInputModeHiddenReveal) {
        self.floatingDockInputTargetsResize = NO;
        // A tap on the hidden handle remains inert.  Only an inward swipe
        // that crosses the configured threshold reveals the card.
        if (revealing && outwardTravel < 5.0) {
            self.floatingDockHideGestureActive = NO;
            self.floatingDockHideReady = NO;
            [self setFloatingDockRoutingSuppressed:NO];
            return;
        }
        BOOL commit = gesture.state == UIGestureRecognizerStateEnded &&
                      outwardTravel >= [self effectiveCenteredDockSwipeThreshold];
        [self finishFloatingDockHiddenGesture:revealing ? !commit : commit
                                       atPoint:point];
        return;
    }

    if (inputMode == FLMFloatingDockInputModeResize) {
        if (!self.floatingDocked || self.floatingDockHidden) {
            self.floatingDockInputTargetsResize = NO;
            self.floatingResizeCenterReady = NO;
            [self setFloatingDockRoutingSuppressed:NO];
            return;
        }
        [self normalizeFloatingContainerTransform];
        BOOL restoreCentered =
            gesture.state == UIGestureRecognizerStateEnded &&
            self.floatingResizeCenterReady;
        self.floatingResizeCenterReady = NO;
        self.floatingDockInputTargetsResize = NO;
        if (restoreCentered) {
            [self transitionFloatingWindowToCentered];
            return;
        }
        [self saveFloatingDockWidth];
        CGFloat currentVerticalCenter =
            CGRectGetMidY(self.floatingContainer.frame);
        self.floatingDockVerticalCenter = currentVerticalCenter;
        CGRect target =
            [self dockedFloatingFrameOnRight:self.floatingDockedOnRight
                                       width:self.floatingDockWidth
                   preservingVerticalCenter:currentVerticalCenter];
        self.floatingDockTransitionActive = YES;
        [self setFloatingDockRoutingSuppressed:YES];
        [self beginFloatingHighRefreshLeaseForDuration:0.18];
        [UIView animateWithDuration:0.18
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseOut |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
                             self.floatingContainer.frame = target;
                             [self layoutFloatingHostView];
                             [self layoutFloatingDockShadow];
                             [self layoutFloatingResizeHandle];
                         }
                         completion:^(__unused BOOL finished) {
                             self.floatingDockTransitionActive = NO;
                             [self configureFloatingInteractionForDockedState];
                             [self setFloatingDockRoutingSuppressed:NO];
                         }];
        return;
    }

    self.floatingDockGlobalDragActivated = NO;
    self.floatingDockInputTargetsResize = NO;
    if (wasGlobalDragActivated || movement >= 5.0) {
        // A moved card always settles horizontally, even if the last display
        // link arrived before the recognizer's Ended callback.
        [self snapDockedFloatingWindowUsingTouchPoint:point];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded && movement < 5.0) {
        if ([self isLandscapeFloatingSession]) {
            [self setFloatingDockRoutingSuppressed:NO];
            return;
        }
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *feedback =
                [[UIImpactFeedbackGenerator alloc]
                    initWithStyle:UIImpactFeedbackStyleLight];
            [feedback impactOccurred];
        }
        [self transitionFloatingWindowToCentered];
    } else {
        [self setFloatingDockRoutingSuppressed:NO];
    }
}

- (void)handleFloatingHiddenBarDrag:(UILongPressGestureRecognizer *)gesture {
    UIView *rootView = [self floatingLayoutView];
    CGRect bounds = rootView.bounds;
    CGPoint point = [gesture locationInView:rootView];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.floatingHiddenBarDragStartPoint = point;
        self.floatingHiddenBarDragInitialFrame = self.floatingHandle.frame;
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGFloat deltaY = point.y - self.floatingHiddenBarDragStartPoint.y;
        CGRect frame = self.floatingHiddenBarDragInitialFrame;
        UIEdgeInsets safeInsets = [self floatingLayoutSafeInsets];
        CGFloat topLimit = MAX(8.0, safeInsets.top);
        CGFloat bottomLimit =
            CGRectGetHeight(bounds) - CGRectGetHeight(frame) -
            safeInsets.bottom;
        frame.origin.y =
            MAX(topLimit, MIN(bottomLimit, CGRectGetMinY(frame) + deltaY));
        [UIView performWithoutAnimation:^{
            self.floatingHandle.frame = frame;
        }];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        // The hidden bar is free to travel vertically while dragged, but it
        // always springs back to its landing spot beside the hidden card
        // (upper-right for the right dock, upper-left for the left dock).
        CGRect landing =
            CGRectMake(self.floatingDockedOnRight
                           ? CGRectGetWidth(bounds) -
                                 CGRectGetWidth(self.floatingHandle.frame)
                           : 0.0,
                       MAX(8.0,
                           CGRectGetMinY(self.floatingContainer.frame) + 24.0),
                       CGRectGetWidth(self.floatingHandle.frame),
                       CGRectGetHeight(self.floatingHandle.frame));
        [self beginFloatingHighRefreshLeaseForDuration:0.32];
        [UIView animateWithDuration:0.32
                              delay:0.0
             usingSpringWithDamping:0.78
              initialSpringVelocity:0.20
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
                             self.floatingHandle.frame = landing;
                         }
                         completion:nil];
    }
}

- (void)handleFloatingHandleTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded ||
        self.floatingWindow.hidden) {
        return;
    }
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
    }
    [self beginFloatingHighRefreshLeaseForDuration:0.30];
    [UIView animateWithDuration:0.10
                     animations:^{
                         self.floatingHandleBar.alpha = 1.0;
                         self.floatingHandleBar.transform =
                             CGAffineTransformMakeScale(1.10, 1.28);
                     }
                     completion:^(BOOL finished) {
                         (void)finished;
                         [UIView animateWithDuration:0.18
                                          animations:^{
                                              self.floatingHandleBar.alpha = 1.0;
                                              self.floatingHandleBar.transform =
                                                  CGAffineTransformIdentity;
                                          }];
                     }];
}

- (void)handleFloatingDockTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded ||
        !self.floatingDocked || self.floatingWindow.hidden) {
        return;
    }
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
    }
    [self transitionFloatingWindowToCentered];
}

- (void)handleFloatingDockDragPress:(UILongPressGestureRecognizer *)gesture {
    if (!self.floatingDocked || self.floatingWindow.hidden) {
        return;
    }
    UIView *rootView = [self floatingLayoutView];
    CGPoint point = [gesture locationInView:rootView];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self setFloatingDockRoutingSuppressed:YES];
        self.floatingDockDragStartPoint = point;
        self.floatingDockDragInitialCenter = self.floatingContainer.center;
        [rootView bringSubviewToFront:self.floatingContainer];
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *feedback =
                [[UIImpactFeedbackGenerator alloc]
                    initWithStyle:UIImpactFeedbackStyleMedium];
            [feedback impactOccurred];
        }
        return;
    }

    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint delta =
            CGPointMake(point.x - self.floatingDockDragStartPoint.x,
                        point.y - self.floatingDockDragStartPoint.y);
        CGRect bounds = rootView.bounds;
        UIEdgeInsets safeInsets = [self floatingLayoutSafeInsets];
        CGFloat halfWidth = CGRectGetWidth(self.floatingContainer.bounds) * 0.5;
        CGFloat halfHeight = CGRectGetHeight(self.floatingContainer.bounds) * 0.5;
        CGPoint center =
            CGPointMake(self.floatingDockDragInitialCenter.x + delta.x,
                        self.floatingDockDragInitialCenter.y + delta.y);
        CGFloat minimumCenterX = safeInsets.left + halfWidth;
        CGFloat maximumCenterX =
            CGRectGetWidth(bounds) - safeInsets.right - halfWidth;
        if (maximumCenterX < minimumCenterX) {
            maximumCenterX = minimumCenterX;
        }
        center.x = MAX(minimumCenterX,
                       MIN(maximumCenterX, center.x));
        center.y = MAX(safeInsets.top + halfHeight,
                       MIN(CGRectGetHeight(bounds) - safeInsets.bottom - halfHeight,
                           center.y));
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [UIView performWithoutAnimation:^{
            self.floatingContainer.center = center;
            self.floatingDockVerticalCenter = center.y;
            [self updateFloatingDockTouchGate];
        }];
        [CATransaction commit];
        return;
    }

    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        [self snapDockedFloatingWindowUsingTouchPoint:point];
    }
}

- (void)setFloatingApplicationInputBlocked:(BOOL)blocked {
    if (self.floatingCloseInProgress) {
        // Close owns the final state transition. A stale animation callback
        // must neither reopen the local host nor alter the process-level state
        // captured when close began.
        self.floatingHostView.userInteractionEnabled = NO;
        return;
    }
    if (!blocked &&
        (self.floatingDocked || self.floatingDockHidden ||
         self.floatingDockControlArmed ||
         self.floatingDockContentTailProtected)) {
        blocked = YES;
    }
    FLMPublishDockInputBlockState(self.floatingIdentifier,
                                  blocked,
                                  @"application-input");
    self.floatingHostView.userInteractionEnabled = !blocked;
    self.floatingDockInteractionShield.frame = self.floatingContainer.bounds;
    self.floatingDockInteractionShield.hidden = !blocked;
    self.floatingDockInteractionShield.userInteractionEnabled = blocked;
    if (blocked) {
        [self.floatingContainer
            bringSubviewToFront:self.floatingDockInteractionShield];
    }
    [self updateFloatingDockTouchGate];
}

- (void)protectFloatingContentAfterDockTouch {
    self.floatingDockContentTailProtected = YES;
    NSUInteger generation = ++self.floatingDockContentProtectionGeneration;
    [self setFloatingApplicationInputBlocked:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(FLMFloatingDockContentTailProtectionDuration *
                                            NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != self.floatingDockContentProtectionGeneration) {
            return;
        }
        self.floatingDockContentTailProtected = NO;
        if (!self.floatingWindow.hidden &&
            !self.floatingDocked &&
            !self.floatingDockHidden &&
            !self.floatingDockTransitionActive) {
            [self configureFloatingInteractionForDockedState];
        }
    });
}

- (void)updateFloatingFullscreenSnapshotForProgress:(CGFloat)progress {
    UIView *wrapper = self.floatingInteractiveSnapshot;
    UIView *background = self.floatingInteractiveSnapshotBackground;
    UIView *content = self.floatingInteractiveSnapshotContent;
    if (!wrapper || !content) {
        return;
    }
    progress = MIN(1.0, MAX(0.0, progress));
    CGRect start = self.floatingHandleInitialContainerFrame;
    CGRect bounds = [self floatingLayoutView].bounds;
    if (CGRectGetWidth(start) < 1.0 || CGRectGetHeight(start) < 1.0) {
        return;
    }
    self.floatingFullscreenProgress = progress;

    // The card and the display now share one aspect ratio, so fullscreen is a
    // single proportional recovery: every edge moves continuously from the
    // card frame to the display frame.  The previous width-stage/height-stage
    // reveal made the finger-driven gesture look like two separate animations.
    CGFloat geometryProgress = progress;
    CGFloat minX = CGRectGetMinX(start) +
                   (CGRectGetMinX(bounds) - CGRectGetMinX(start)) *
                       geometryProgress;
    CGFloat minY = CGRectGetMinY(start) +
                   (CGRectGetMinY(bounds) - CGRectGetMinY(start)) *
                       geometryProgress;
    CGFloat width = CGRectGetWidth(start) +
                    (CGRectGetWidth(bounds) - CGRectGetWidth(start)) *
                        geometryProgress;
    CGFloat height = CGRectGetHeight(start) +
                     (CGRectGetHeight(bounds) - CGRectGetHeight(start)) *
                         geometryProgress;
    CGRect frame = CGRectMake(minX, minY, width, height);
    wrapper.transform = CGAffineTransformIdentity;
    wrapper.frame = frame;
    CGFloat cornerRadius =
        22.0 * (CGRectGetWidth(start) / FLMCenteredCardWidth) *
        (1.0 - progress);
    wrapper.layer.cornerRadius = cornerRadius;

    CGFloat uniformScale = CGRectGetWidth(frame) /
                           MAX(1.0, CGRectGetWidth(start));
    CGPoint localCenter =
        CGPointMake(CGRectGetMidX(wrapper.bounds), CGRectGetMidY(wrapper.bounds));
    content.center = localCenter;
    content.transform = CGAffineTransformMakeScale(uniformScale, uniformScale);
    if (background) {
        background.center = localCenter;
        background.transform =
            CGAffineTransformMakeScale(uniformScale, uniformScale);
    }
    // The proportional foreground remains visible for the complete gesture.
    // The optional duplicate is kept only as a snapshot fallback and follows
    // the same transform; it must never aspect-fill or create a second stage.
    content.alpha = 1.0;
    background.alpha = 0.0;

    // Keep every visible element on this same progress curve.  Previously the
    // card path, dim layer, white bar and final fullscreen animation each had a
    // separate callback.  That made release at an arbitrary point look like a
    // second animation was starting after the bar had already finished.
    self.floatingContainer.transform = CGAffineTransformIdentity;
    self.floatingContainer.frame = frame;
    self.floatingContainer.layer.cornerRadius = cornerRadius;
    self.floatingDimView.alpha = 1.0 - progress;
    CGFloat handleFade =
        MIN(1.0, MAX(0.0, (progress - 0.84) / 0.16));
    self.floatingHandle.alpha = 1.0 - handleFade;
    self.floatingHandleBar.alpha = 1.0;
    self.floatingHandleBar.transform = CGAffineTransformIdentity;
    [self layoutFloatingHandleForCurrentContainer];
}

- (void)prepareFloatingSceneForInteractiveFullscreen {
    if (self.floatingInteractiveScenePrepared) {
        return;
    }
    self.floatingInteractiveScenePrepared = YES;
    self.floatingInteractiveFullscreenTransition = YES;
    self.floatingFullscreenProgress = 0.0;
    self.floatingHandleBar.alpha = 1.0;
    self.floatingHandleBar.transform = CGAffineTransformIdentity;

    UIView *content =
        [self.floatingContainer snapshotViewAfterScreenUpdates:NO];
    if (!content) {
        content = [[UIView alloc] initWithFrame:self.floatingContainer.bounds];
        content.backgroundColor = [UIColor blackColor];
    }
    // This layer stayed at alpha=0 for the entire transition. Avoid making
    // and retaining a second, never-visible remote snapshot.
    UIView *background = nil;
    CGRect start = self.floatingHandleInitialContainerFrame;
    UIView *wrapper = [[UIView alloc] initWithFrame:start];
    wrapper.backgroundColor = [UIColor clearColor];
    wrapper.autoresizingMask = UIViewAutoresizingNone;
    wrapper.userInteractionEnabled = NO;
    wrapper.clipsToBounds = YES;
    wrapper.layer.cornerRadius =
        22.0 * CGRectGetWidth(start) / FLMCenteredCardWidth;
    CGRect sourceBounds = CGRectMake(0.0,
                                     0.0,
                                     CGRectGetWidth(start),
                                     CGRectGetHeight(start));
    if (background) {
        background.bounds = sourceBounds;
        background.center = CGPointMake(CGRectGetMidX(wrapper.bounds),
                                        CGRectGetMidY(wrapper.bounds));
        background.autoresizingMask = UIViewAutoresizingNone;
        background.userInteractionEnabled = NO;
        background.alpha = 0.0;
        [wrapper addSubview:background];
    }
    content.bounds = sourceBounds;
    content.center = CGPointMake(CGRectGetMidX(wrapper.bounds),
                                 CGRectGetMidY(wrapper.bounds));
    content.autoresizingMask = UIViewAutoresizingNone;
    content.userInteractionEnabled = NO;
    [wrapper addSubview:content];
    [self.floatingPresentationView addSubview:wrapper];
    [self.floatingPresentationView
        bringSubviewToFront:self.floatingHandle];
    self.floatingInteractiveSnapshot = wrapper;
    self.floatingInteractiveSnapshotBackground = background;
    self.floatingInteractiveSnapshotContent = content;
    self.floatingContainer.alpha = 0.0;
    [self updateFloatingFullscreenSnapshotForProgress:0.0];
}

- (void)restoreFloatingSceneAfterCancelledTransition {
    if (!self.floatingInteractiveScenePrepared &&
        !self.floatingInteractiveSnapshot) {
        return;
    }
    [self.floatingInteractiveSnapshot removeFromSuperview];
    self.floatingInteractiveSnapshot = nil;
    self.floatingInteractiveSnapshotBackground = nil;
    self.floatingInteractiveSnapshotContent = nil;
    self.floatingInteractiveScenePrepared = NO;
    self.floatingInteractiveFullscreenTransition = NO;
    self.floatingFullscreenActivationArmed = NO;
    self.floatingFullscreenProgress = 0.0;
    self.floatingReconnectSuppressed = NO;
    self.floatingContainer.alpha = 1.0;
    self.floatingContainer.transform = CGAffineTransformIdentity;
    if (!CGRectIsEmpty(self.floatingHandleInitialContainerFrame)) {
        self.floatingContainer.frame = self.floatingHandleInitialContainerFrame;
    }
    [self layoutFloatingHostView];
}

- (void)handleFloatingHandlePress:(UILongPressGestureRecognizer *)gesture {
    if (self.floatingWindow.hidden) {
        return;
    }
    if (self.floatingDocked && self.floatingDockHidden) {
        [self handleFloatingHiddenBarDrag:gesture];
        return;
    }
    UIView *rootView = [self floatingLayoutView];
    CGPoint point = [gesture locationInView:rootView];
    CGRect bounds = rootView.bounds;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        // A centered card always starts a new dock gesture at the fixed
        // minimum size. Resizing a prior dock is intentionally not remembered.
        self.floatingDockWidth = [self effectiveDockedPresentationWidth];
        self.floatingHandleStartPoint = point;
        self.floatingHandleInitialContainerFrame = self.floatingContainer.frame;
        self.floatingHandleMoved = NO;
        self.floatingDockTransitionActive = NO;
        self.floatingDockControlArmed = NO;
        self.floatingDockEntrySettleActive = NO;
        self.floatingDockEntrySettleGeneration += 1;
        self.floatingDockEntryTargetFrame = CGRectNull;
        self.floatingDockTouchCaptureFrame = CGRectNull;
        self.floatingDockEntryControlTouchPending = NO;
        self.floatingDockFeedbackSent = NO;
        self.floatingInteractiveScenePrepared = NO;
        self.floatingHandleBar.alpha = 1.0;
        self.floatingHandleBar.transform = CGAffineTransformIdentity;
        [self setFloatingApplicationInputBlocked:NO];
        self.floatingDockReady = NO;
        return;
    }

    if ([self isLandscapeFloatingSession]) {
        CGFloat horizontalMovement = point.x - self.floatingHandleStartPoint.x;
        if (gesture.state == UIGestureRecognizerStateChanged) {
            if (horizontalMovement <= -3.0) {
                if (self.floatingInteractiveScenePrepared) {
                    [self restoreFloatingSceneAfterCancelledTransition];
                }
                [self setFloatingApplicationInputBlocked:YES];
                self.floatingHandleMoved = YES;
                self.floatingDockTransitionActive = YES;
                CGRect start = self.floatingHandleInitialContainerFrame;
                CGRect dockTarget = [self dockedFloatingFrameOnRight:NO
                                                               width:self.floatingDockWidth];
                CGFloat triggerProgress = MIN(1.0, MAX(0.0,
                    -horizontalMovement / [self effectiveCenteredDockSwipeThreshold]));
                CGFloat visualProgress = MIN(1.0, MAX(0.0,
                    -horizontalMovement / FLMLandscapeHandleDockActivationDistance));
                CGFloat targetScale = CGRectGetWidth(dockTarget) / MAX(1.0, CGRectGetWidth(start));
                CGFloat scale = 1.0 + (targetScale - 1.0) * visualProgress;
                CGPoint startCenter = CGPointMake(CGRectGetMidX(start), CGRectGetMidY(start));
                CGPoint targetCenter = CGPointMake(CGRectGetMidX(dockTarget), CGRectGetMidY(dockTarget));
                self.floatingContainer.center = CGPointMake(
                    startCenter.x + (targetCenter.x - startCenter.x) * visualProgress,
                    startCenter.y + (targetCenter.y - startCenter.y) * visualProgress);
                self.floatingContainer.transform = CGAffineTransformMakeScale(scale, scale);
                self.floatingDimView.alpha = 1.0 - visualProgress;
                self.floatingHandle.alpha = 1.0;
                self.floatingHandleBar.alpha = 1.0 - triggerProgress;
                [self layoutFloatingHandleForCurrentContainer];
                if (!self.floatingDockReady && triggerProgress >= 1.0) {
                    self.floatingDockReady = YES;
                    self.floatingDockControlArmed = YES;
                    self.floatingDockInputGesture.enabled = YES;
                    self.floatingDockEntryTargetFrame = dockTarget;
                    self.floatingDockTouchCaptureFrame = CGRectUnion(
                        [self floatingContainerPresentationFrame], dockTarget);
                    [self setFloatingApplicationInputBlocked:YES];
                    [self setFloatingDockRoutingSuppressed:YES];
                    [self updateFloatingDockTouchGate];
                    if (@available(iOS 10.0, *)) {
                        UIImpactFeedbackGenerator *feedback =
                            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                        [feedback impactOccurred];
                    }
                    FLMEnqueueDiagnosticLine(
                        @"sb landscape-handle dock-armed progress=%.3f source=%@ target=%@",
                        triggerProgress, NSStringFromCGRect(start), NSStringFromCGRect(dockTarget));
                } else if (self.floatingDockReady && triggerProgress < 0.90) {
                    self.floatingDockReady = NO;
                }
            } else if (horizontalMovement >= 3.0) {
                self.floatingDockReady = NO;
                [self setFloatingApplicationInputBlocked:NO];
                self.floatingHandleMoved = YES;
                self.floatingDockTransitionActive = NO;
                if (!self.floatingInteractiveScenePrepared) {
                    [self prepareFloatingSceneForInteractiveFullscreen];
                }
                CGFloat progress = MIN(1.0, MAX(0.0,
                    horizontalMovement / FLMLandscapeHandleFullscreenActivationDistance));
                [self updateFloatingFullscreenSnapshotForProgress:progress];
                self.floatingHandleBar.alpha = 1.0;
                if (progress >= FLMFloatingFullscreenActivationThreshold &&
                    !self.floatingFullscreenActivationArmed &&
                    self.floatingIdentifier.length > 0) {
                    self.floatingFullscreenActivationArmed = YES;
                    self.floatingReconnectSuppressed = YES;
                    [self activateIdentifierFullscreen:self.floatingIdentifier];
                    FLMEnqueueDiagnosticLine(@"sb landscape-handle fullscreen-armed progress=%.3f", progress);
                }
            } else {
                self.floatingDockReady = NO;
                [self setFloatingApplicationInputBlocked:NO];
                if (self.floatingInteractiveScenePrepared) {
                    [self restoreFloatingSceneAfterCancelledTransition];
                }
                self.floatingDockTransitionActive = NO;
                self.floatingContainer.transform = CGAffineTransformIdentity;
                self.floatingContainer.frame = self.floatingHandleInitialContainerFrame;
                self.floatingHandleBar.alpha = 1.0;
                [self layoutFloatingHostView];
                [self layoutFloatingHandleForCurrentContainer];
            }
            return;
        }
        if (gesture.state == UIGestureRecognizerStateEnded &&
            self.floatingDockReady && horizontalMovement < 0.0) {
            self.floatingDockReady = NO;
            [self transitionFloatingWindowToDocked];
            return;
        }
        if (gesture.state == UIGestureRecognizerStateEnded &&
            horizontalMovement > 0.0 && self.floatingFullscreenActivationArmed) {
            self.floatingDockReady = NO;
            [self transitionFloatingWindowToFullscreen];
            return;
        }
        self.floatingDockReady = NO;
        [self resetFloatingInteractiveLayoutAnimated:YES];
        return;
    }

    CGFloat primaryMovement =
        point.y - self.floatingHandleStartPoint.y;

    if (gesture.state == UIGestureRecognizerStateChanged) {
        if (primaryMovement <= -3.0) {
            if (self.floatingInteractiveScenePrepared) {
                [self restoreFloatingSceneAfterCancelledTransition];
            }
            [self setFloatingApplicationInputBlocked:YES];
            self.floatingHandleMoved = YES;
            self.floatingDockTransitionActive = YES;
            CGRect start = self.floatingHandleInitialContainerFrame;
            CGRect dockTarget =
                [self dockedFloatingFrameOnRight:YES width:self.floatingDockWidth];
            CGFloat triggerProgress =
                MIN(1.0, MAX(0.0,
                             -primaryMovement /
                                 [self effectiveCenteredDockSwipeThreshold]));
            CGFloat visualProgress =
                MIN(1.0, MAX(0.0,
                             -primaryMovement /
                                 FLMCenteredDockActivationDistance));
            CGFloat width =
                CGRectGetWidth(start) +
                (CGRectGetWidth(dockTarget) - CGRectGetWidth(start)) * visualProgress;
            CGFloat scale = width / MAX(1.0, CGRectGetWidth(start));
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [UIView performWithoutAnimation:^{
                self.floatingContainer.center =
                    CGPointMake(CGRectGetMidX(start), CGRectGetMidY(start));
                self.floatingContainer.transform =
                    CGAffineTransformMakeScale(scale, scale);
                self.floatingDockShadowView.center = self.floatingContainer.center;
                self.floatingDockShadowView.transform =
                    self.floatingContainer.transform;
            }];
            [CATransaction commit];
            // Card corners scale proportionally with the card: the visual
            // radius stays 22pt at the centered size and shrinks to the
            // docked ratio (22 * dockWidth / 315) as the card shrinks.
            self.floatingContainer.layer.cornerRadius = 22.0;
            self.floatingDimView.alpha = 1.0 - visualProgress;
            self.floatingDockShadowView.hidden = YES;
            self.floatingDockShadowView.alpha = 0.0;
            self.floatingHandle.alpha = 1.0;
            self.floatingHandleBar.alpha = 1.0 - triggerProgress;
            [self layoutFloatingHandleForCurrentContainer];
            if (!self.floatingDockReady && triggerProgress >= 1.0) {
                if (@available(iOS 10.0, *)) {
                    UIImpactFeedbackGenerator *feedback =
                        [[UIImpactFeedbackGenerator alloc]
                            initWithStyle:UIImpactFeedbackStyleMedium];
                    if (!self.floatingDockFeedbackSent) {
                        [feedback impactOccurred];
                        self.floatingDockFeedbackSent = YES;
                    }
                }
                self.floatingDockReady = YES;
                self.floatingDockControlArmed = YES;
                self.floatingDockInputGesture.enabled = YES;
                self.floatingDockEntryTargetFrame = dockTarget;
                CGRect presentationFrame =
                    [self floatingContainerPresentationFrame];
                self.floatingDockTouchCaptureFrame =
                    CGRectUnion(presentationFrame, dockTarget);
                [self setFloatingApplicationInputBlocked:YES];
                [self setFloatingDockRoutingSuppressed:YES];
                [self updateFloatingDockTouchGate];
                FLMDiagnosticLog(
                    @"sb dock-control-armed trigger=%.3f visual=%.3f source=%@ target=%@",
                    triggerProgress,
                    visualProgress,
                    NSStringFromCGRect(presentationFrame),
                    NSStringFromCGRect(dockTarget));
            } else if (self.floatingDockReady && triggerProgress < 0.90) {
                self.floatingDockReady = NO;
            }
        } else if (primaryMovement >= 3.0) {
            self.floatingDockReady = NO;
            if (self.floatingDockControlArmed) {
                // Crossing the dock threshold commits this touch stream to
                // dock control. A reversal may cancel back to centered, but
                // it must not reopen the remote Scene's input route or turn
                // into the unrelated centered-to-fullscreen gesture.
                [self setFloatingApplicationInputBlocked:YES];
                self.floatingHandleMoved = YES;
                self.floatingDockTransitionActive = YES;
                self.floatingDockShadowView.alpha = 0.0;
                self.floatingDockShadowView.hidden = YES;
                [UIView performWithoutAnimation:^{
                    self.floatingContainer.transform = CGAffineTransformIdentity;
                    self.floatingContainer.frame =
                        self.floatingHandleInitialContainerFrame;
                    self.floatingDimView.alpha = 1.0;
                    self.floatingHandle.alpha = 1.0;
                    self.floatingHandleBar.alpha = 1.0;
                    [self layoutFloatingHostView];
                    [self layoutFloatingHandleForCurrentContainer];
                }];
                return;
            }
            [self setFloatingApplicationInputBlocked:NO];
            self.floatingHandleMoved = YES;
            self.floatingDockTransitionActive = NO;
            self.floatingDockShadowView.alpha = 0.0;
            self.floatingDockShadowView.hidden = YES;
            if (!self.floatingInteractiveScenePrepared) {
                [self prepareFloatingSceneForInteractiveFullscreen];
            }
            CGFloat available =
                MAX(1.0,
                    CGRectGetHeight(bounds) -
                        CGRectGetMaxY(self.floatingHandleInitialContainerFrame));
            CGFloat progress = MIN(1.0, MAX(0.0, primaryMovement / available));
            [self updateFloatingFullscreenSnapshotForProgress:progress];
            if (progress >= FLMFloatingFullscreenActivationThreshold &&
                !self.floatingFullscreenActivationArmed &&
                self.floatingIdentifier.length > 0) {
                self.floatingFullscreenActivationArmed = YES;
                self.floatingReconnectSuppressed = YES;
                [self activateIdentifierFullscreen:self.floatingIdentifier];
            }
        } else {
            self.floatingDockReady = NO;
            [self setFloatingApplicationInputBlocked:NO];
            if (self.floatingInteractiveScenePrepared) {
                if (self.floatingFullscreenActivationArmed &&
                    self.floatingIdentifier.length > 0 &&
                    [self.floatingIdentifier
                        isEqualToString:FLMFrontmostApplicationIdentifier()]) {
                    [self transitionFloatingWindowToFullscreen];
                    return;
                }
                [self restoreFloatingSceneAfterCancelledTransition];
            }
            self.floatingDockTransitionActive = NO;
            self.floatingContainer.transform = CGAffineTransformIdentity;
            self.floatingContainer.frame =
                self.floatingHandleInitialContainerFrame;
            self.floatingDockShadowView.transform = CGAffineTransformIdentity;
            self.floatingContainer.layer.cornerRadius = 22.0;
            self.floatingDimView.alpha = 1.0;
            self.floatingDockShadowView.alpha = 0.0;
            self.floatingDockShadowView.hidden = YES;
            self.floatingHandle.alpha = 1.0;
            self.floatingHandleBar.alpha = 1.0;
            [self layoutFloatingHostView];
            [self layoutFloatingHandleForCurrentContainer];
        }
        return;
    }

    if (gesture.state == UIGestureRecognizerStateEnded &&
        self.floatingDockReady && primaryMovement < 0.0) {
        self.floatingDockReady = NO;
        [self transitionFloatingWindowToDocked];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded &&
        self.floatingHandleMoved && !self.floatingDockTransitionActive &&
        primaryMovement > 0.0 &&
        point.y >= CGRectGetHeight(bounds) - 80.0) {
        self.floatingDockReady = NO;
        [self transitionFloatingWindowToFullscreen];
        return;
    }
    self.floatingDockReady = NO;
    [self resetFloatingInteractiveLayoutAnimated:YES];
}

- (void)resetFloatingInteractiveLayoutAnimated:(BOOL)animated {
    if (self.floatingFullscreenActivationArmed &&
        !self.floatingWindow.hidden && self.floatingIdentifier.length > 0 &&
        [self.floatingIdentifier
            isEqualToString:FLMFrontmostApplicationIdentifier()]) {
        [self transitionFloatingWindowToFullscreen];
        return;
    }
    self.floatingDockReady = NO;
    [self restoreFloatingSceneAfterCancelledTransition];
    BOOL releaseDockControlAfterReset = self.floatingDockControlArmed;
    self.floatingDockEntrySettleActive = NO;
    self.floatingDockEntrySettleGeneration += 1;
    self.floatingDockEntryControlTouchPending = NO;
    self.floatingDockInputGesture.enabled =
        self.floatingDocked || self.floatingDockHidden;
    if (!releaseDockControlAfterReset) {
        self.floatingDockControlArmed = NO;
        self.floatingDockEntryTargetFrame = CGRectNull;
        self.floatingDockTouchCaptureFrame = CGRectNull;
        [self setFloatingApplicationInputBlocked:NO];
    } else {
        [self setFloatingApplicationInputBlocked:YES];
    }
    [self normalizeFloatingContainerTransform];
    void (^changes)(void) = ^{
        self.floatingContainer.alpha = 1.0;
        self.floatingContainer.layer.cornerRadius = 22.0;
        self.floatingDimView.alpha = 1.0;
        self.floatingHandle.alpha = 1.0;
        self.floatingHandleBar.alpha = 1.0;
        self.floatingHandleBar.transform = CGAffineTransformIdentity;
        self.floatingDockShadowView.alpha = 0.0;
        [self layoutFloatingWindow];
    };
    if (!animated) {
        changes();
        self.floatingDockTransitionActive = NO;
        self.floatingDockControlArmed = NO;
        self.floatingDockEntryTargetFrame = CGRectNull;
        self.floatingDockTouchCaptureFrame = CGRectNull;
        [self configureFloatingInteractionForDockedState];
        [self setFloatingDockRoutingSuppressed:NO];
        if (!self.floatingDocked) {
            self.floatingDockShadowView.hidden = YES;
        }
        return;
    }
    [self beginFloatingHighRefreshLeaseForDuration:0.34];
    [UIView animateWithDuration:0.34
                          delay:0.0
         usingSpringWithDamping:0.78
          initialSpringVelocity:0.25
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:changes
                     completion:^(BOOL finished) {
                         (void)finished;
                         self.floatingDockTransitionActive = NO;
                         self.floatingDockControlArmed = NO;
                         self.floatingDockEntryTargetFrame = CGRectNull;
                         self.floatingDockTouchCaptureFrame = CGRectNull;
                         [self configureFloatingInteractionForDockedState];
                         [self setFloatingDockRoutingSuppressed:NO];
                         if (!self.floatingDocked) {
                             self.floatingDockShadowView.hidden = YES;
                         }
                     }];
}

- (void)transitionFloatingWindowToFullscreen {
    self.floatingDockReady = NO;
    if (self.floatingWindow.hidden || self.floatingIdentifier.length == 0) {
        [self resetFloatingInteractiveLayoutAnimated:YES];
        return;
    }
    UIView *rootView = [self floatingLayoutView];
    [self endFloatingKeyboardSession];
    CGRect targetFrame = rootView.bounds;
    if (!self.floatingInteractiveScenePrepared) {
        self.floatingHandleInitialContainerFrame = self.floatingContainer.frame;
        [self prepareFloatingSceneForInteractiveFullscreen];
    }
    NSString *identifier = [self.floatingIdentifier copy];
    NSUInteger transitionGeneration = self.floatingLaunchGeneration;
    self.floatingReconnectSuppressed = YES;
    // Start the already-running scene promotion while the final part of the
    // same card morph is still on screen. The old implementation waited until
    // that animation ended, producing a visible motion/pause/activation split.
    if (!self.floatingFullscreenActivationArmed) {
        self.floatingFullscreenActivationArmed = YES;
        [self activateIdentifierFullscreen:identifier];
    }
    CGFloat remainingProgress =
        MAX(0.0, 1.0 - self.floatingFullscreenProgress);
    NSTimeInterval finishDuration = 0.10 + 0.22 * remainingProgress;
    [self beginFloatingHighRefreshLeaseForDuration:finishDuration];
    [UIView animateWithDuration:finishDuration
                           delay:0.0
                         options:UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionAllowUserInteraction
                       animations:^{
                          [self updateFloatingFullscreenSnapshotForProgress:1.0];
                      }
                      completion:^(BOOL finished) {
                          (void)finished;
                          BOOL currentTransition =
                              transitionGeneration ==
                                  self.floatingLaunchGeneration &&
                              !self.floatingCloseInProgress &&
                              !self.floatingWindow.hidden &&
                              [identifier
                                  isEqualToString:self.floatingIdentifier];
                          if (!currentTransition) {
                              FLMDiagnosticLog(
                                  @"sb fullscreen-transition stale target=%@ generation=%lu current=%lu close=%d hidden=%d currentTarget=%@",
                                  identifier ?: @"<none>",
                                  (unsigned long)transitionGeneration,
                                  (unsigned long)self.floatingLaunchGeneration,
                                  self.floatingCloseInProgress,
                                  self.floatingWindow.hidden,
                                  self.floatingIdentifier ?: @"<none>");
                              return;
                          }
                          UIView *snapshot = self.floatingInteractiveSnapshot;
                         self.floatingInteractiveSnapshot = nil;
                         self.floatingInteractiveSnapshotBackground = nil;
                         self.floatingInteractiveSnapshotContent = nil;
                         if (!snapshot) {
                             snapshot = [[UIView alloc] initWithFrame:targetFrame];
                             snapshot.backgroundColor = [UIColor blackColor];
                             [rootView addSubview:snapshot];
                         } else {
                             snapshot.layer.cornerRadius = 0.0;
                             [rootView addSubview:snapshot];
                         }

                          self.floatingInteractiveScenePrepared = NO;
                          self.floatingInteractiveFullscreenTransition = NO;
                          self.floatingFullscreenProgress = 1.0;
                         self.floatingLaunchGeneration += 1;
                         NSUInteger handoffGeneration =
                             self.floatingLaunchGeneration;
                         self.floatingExclusiveGesture.enabled = NO;
                         self.cornerGuardGesture.enabled = self.enabled;
                         self.cornerGesture.enabled = self.enabled;
                         self.floatingContainer.alpha = 0.0;
                          [self finishFullscreenHandoffWithCover:snapshot
                                                    identifier:identifier
                                                    generation:handoffGeneration
                                                      attempt:0];
                     }];
}

- (void)finishFullscreenHandoffWithCover:(UIView *)cover
                              identifier:(NSString *)identifier
                              generation:(NSUInteger)generation
                                 attempt:(NSUInteger)attempt {
    BOOL currentHandoff =
        generation == self.floatingLaunchGeneration &&
        !self.floatingCloseInProgress && !self.floatingWindow.hidden &&
        identifier.length > 0 &&
        [identifier isEqualToString:self.floatingIdentifier];
    if (!currentHandoff) {
        FLMDiagnosticLog(
            @"sb fullscreen-handoff stale target=%@ generation=%lu current=%lu close=%d hidden=%d currentTarget=%@",
            identifier ?: @"<none>", (unsigned long)generation,
            (unsigned long)self.floatingLaunchGeneration,
            self.floatingCloseInProgress, self.floatingWindow.hidden,
            self.floatingIdentifier ?: @"<none>");
        [cover removeFromSuperview];
        return;
    }
    BOOL targetIsFrontmost =
        identifier.length > 0 &&
        [identifier isEqualToString:FLMFrontmostApplicationIdentifier()];
    // Match the 0.8.46 handoff cadence. The cover already completed the
    // single continuous card-to-fullscreen animation; wait only one bounded
    // polling turn before swapping it with the real foreground Scene. The
    // polling cadence is shorter now because the app activation is armed
    // during the drag itself.
    BOOL displayCommitted = targetIsFrontmost && attempt >= 1;
    if (!displayCommitted && attempt < 24) {
        if (attempt == 0 || attempt >= 22) {
            FLMDiagnosticLog(
                @"sb fullscreen-handoff wait target=%@ frontmost=%@ attempt=%lu",
                identifier ?: @"<none>",
                FLMFrontmostApplicationIdentifier() ?: @"<none>",
                (unsigned long)attempt);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(FLMFloatingFullscreenHandoffPollInterval *
                                               NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self finishFullscreenHandoffWithCover:cover
                                       identifier:identifier
                                       generation:generation
                                          attempt:attempt + 1];
        });
        return;
    }

    if (!displayCommitted) {
        // Never remove the only visible surface merely because the promotion
        // deadline expired. Keep the app in centered mode and let the user
        // retry; this prevents an occasional black SpringBoard screen when
        // launchApplicationWithIdentifier: has not committed the target Scene.
        FLMDiagnosticLog(
            @"sb fullscreen-handoff timeout target=%@ frontmost=%@ restoring-card=1",
            identifier ?: @"<none>",
            FLMFrontmostApplicationIdentifier() ?: @"<none>");
        [cover removeFromSuperview];
        self.floatingReconnectSuppressed = NO;
        [self restoreFloatingSceneAfterCancelledTransition];
        [self resetFloatingInteractiveLayoutAnimated:NO];
        self.floatingExclusiveGesture.enabled = self.usesSystemGestureManager;
        self.cornerGuardGesture.enabled = self.enabled;
        self.cornerGesture.enabled = self.enabled;
        return;
    }

    // The fullscreen Scene is now committed behind the noninteractive cover.
    // Reopen its application event route immediately before removing that
    // cover, never while it is still presented as a Dock card.
    FLMPublishDockInputBlockState(identifier, NO, @"fullscreen-handoff");
    id scene = self.floatingScene;
    id presenter = self.floatingPresenter;
    [self.floatingHostView removeFromSuperview];
    self.floatingHostView = nil;
    self.floatingHostReferenceSize = CGSizeZero;
    self.floatingSceneEntity = nil;
    self.floatingSceneHandle = nil;
    self.floatingScene = nil;
    self.floatingPresentationManager = nil;
    self.floatingPresenter = nil;
    self.floatingIdentifier = nil;
    self.floatingFullscreenProgress = 0.0;
    [self applyKeyboardFrame:CGRectNull visible:NO];
    FLMClearProtectedScene(scene);
    @try {
        if ([presenter respondsToSelector:@selector(deactivate)]) {
            [presenter deactivate];
        }
        if ([presenter respondsToSelector:@selector(invalidate)]) {
            [presenter invalidate];
        }
    } @catch (__unused NSException *exception) {
    }

    // The geometry animation already ended at the exact physical-screen
    // bounds. Once SpringBoard confirms the real Scene is frontmost, exchange
    // the identical full-screen cover without a second visible animation.
    [UIView performWithoutAnimation:^{
        self.floatingWindow.hidden = YES;
        [self updateFloatingDockTouchGate];
        [cover removeFromSuperview];
        self.floatingContainer.alpha = 1.0;
        [self resetFloatingInteractiveLayoutAnimated:NO];
        [self stopLockMonitoringIfIdle];
    }];
}

- (void)protectedSceneDidDisappear:(NSNotification *)notification {
    (void)notification;
    if (self.floatingKeyboardSessionGeneration != 0) {
        [self endFloatingKeyboardSession];
    }
    if (self.floatingWindow.hidden) {
        return;
    }
    if (self.floatingReconnectSuppressed) {
        return;
    }
    if (FLMDeviceIsLocked() || self.floatingIdentifier.length == 0) {
        [self closeFloatingWindowKeepingApplication:YES];
        return;
    }

    NSString *identifier = [self.floatingIdentifier copy];
    if (self.floatingDocked &&
        [identifier isEqualToString:FLMFrontmostApplicationIdentifier()]) {
        // The user opened the docked application through SpringBoard. Its
        // primary scene now belongs to the fullscreen transition; reconnecting
        // that same scene into the dock produces a black, permanently stale
        // presenter. Detach our presenter without backgrounding the app.
        self.floatingReconnectSuppressed = YES;
        [self closeFloatingWindowKeepingApplication:NO];
        return;
    }
    if (self.floatingKeyboardSessionGeneration == 0) {
        self.floatingKeyboardSessionCounter += 1;
        if (self.floatingKeyboardSessionCounter == 0) {
            self.floatingKeyboardSessionCounter = 1;
        }
        self.floatingKeyboardSessionGeneration =
            self.floatingKeyboardSessionCounter;
    }
    self.floatingLaunchGeneration += 1;
    NSUInteger generation = self.floatingLaunchGeneration;
    self.floatingLaunchState = FLMFloatingLaunchStatePrewarming;
    self.floatingLaunchStartedAt = CACurrentMediaTime();
    self.floatingRevealRetryCount = 0;
    self.floatingScenePreparedAt = 0.0;
    // Card presentation is intentionally decoupled from Scene geometry. Mark
    // the presentation route ready immediately so keyboard/host callbacks do
    // not wait for a private compact-frame acknowledgement.
    self.floatingSceneUsesCardGeometry = NO;
    self.floatingSceneCardGeometryPending = NO;
    self.floatingSceneCardGeometryCommitted = YES;
    self.floatingSceneGeometryCommitGeneration = generation;
    self.floatingKeyboardFramePending = NO;
    self.floatingKeyboardPendingFrame = CGRectNull;
    self.floatingKeyboardPendingSessionGeneration = 0;
    id presenter = self.floatingPresenter;
    [self.floatingHostView removeFromSuperview];
    self.floatingHostView = nil;
    self.floatingHostReferenceSize = CGSizeZero;
    self.floatingSceneEntity = nil;
    self.floatingSceneHandle = nil;
    self.floatingScene = nil;
    self.floatingPresentationManager = nil;
    self.floatingPresenter = nil;
    @try {
        if ([presenter respondsToSelector:@selector(deactivate)]) {
            [presenter deactivate];
        }
        if ([presenter respondsToSelector:@selector(invalidate)]) {
            [presenter invalidate];
        }
    } @catch (__unused NSException *exception) {
    }
    [self configureFloatingLaunchCoverForIdentifier:identifier];
    self.floatingHandle.userInteractionEnabled = NO;
    self.floatingExclusiveGesture.enabled = NO;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [self attachFloatingIdentifier:identifier
                                generation:generation
                                   attempt:0];
    });
}

- (CGFloat)effectiveCenteredCardWidth {
    CGFloat width = self.centeredCardWidth;
    if (width <= 0.0) {
        width = FLMCenteredCardWidth;
    }
    return MAX(FLMMinimumCenteredCardWidth,
               MIN(FLMMaximumCenteredCardWidth, width));
}

- (CGFloat)effectiveCenteredCardHeight {
    CGFloat width = [self effectiveCenteredCardWidth];
    CGFloat baseHeight = width * FLMVirtualViewportHeight /
                         FLMVirtualViewportWidth;
    CGFloat topCrop = MAX(FLMMinimumCenteredCardCrop,
                          MIN(FLMMaximumCenteredCardCrop,
                              self.centeredCardTopCrop));
    CGFloat bottomCrop = MAX(FLMMinimumCenteredCardCrop,
                             MIN(FLMMaximumCenteredCardCrop,
                                 self.centeredCardBottomCrop));
    CGFloat height = baseHeight - topCrop - bottomCrop;
    // Keep the card visible even if a user enters unusually large crop values.
    // The full-screen Scene is never resized; this is only a presentation
    // surface guard.
    return MAX(240.0, MIN(780.0, height));
}

- (CGFloat)effectiveCenteredCardScaleX {
    return [self effectiveCenteredCardWidth] / FLMVirtualViewportWidth;
}

- (CGFloat)effectiveCenteredCardScaleY {
    // Full-screen content is always transformed by one uniform scale. Top and
    // bottom crop alter the visible card frame, never the app's logical frame.
    return [self effectiveCenteredCardScaleX];
}

- (CGFloat)effectiveCenteredDockSwipeThreshold {
    CGFloat value = self.centeredDockSwipeThreshold;
    if (!isfinite(value) || value <= 0.0) {
        value = FLMDefaultCenteredDockSwipeThreshold;
    }
    return MAX(FLMMinimumCenteredDockSwipeThreshold,
               MIN(FLMMaximumCenteredDockSwipeThreshold, value));
}

- (CGFloat)effectiveDockedPresentationWidth {
    CGFloat width = FLMMinimumDockWidth -
                    MAX(0.0, MIN(FLMMaximumDockedShrinkAmount,
                                  self.dockedShrinkAmount));
    return MAX(FLMMinimumDockPresentationWidth, width);
}

- (BOOL)isLandscapeFloatingSession {
    return self.floatingLandscapeSession &&
           self.floatingLandscapeSystemSize.width >
               self.floatingLandscapeSystemSize.height + 1.0;
}

- (UIView *)floatingLayoutView {
    return self.floatingPresentationView
               ?: self.floatingWindow.rootViewController.view;
}

- (UIEdgeInsets)floatingLayoutSafeInsets {
    if ([self isLandscapeFloatingSession]) {
        return self.floatingLandscapeSafeInsets;
    }
    UIView *rootView = self.floatingWindow.rootViewController.view;
    return rootView ? rootView.safeAreaInsets : UIEdgeInsetsZero;
}

- (CGPoint)visualPointForGesture:(UIGestureRecognizer *)gesture {
    if (!gesture) {
        return CGPointZero;
    }
    FLMCornerGestureRecognizer *landscapeRecognizer =
        [gesture isKindOfClass:[FLMCornerGestureRecognizer class]]
            ? (FLMCornerGestureRecognizer *)gesture
            : nil;
    if ((gesture == self.landscapeGlobalCornerGesture ||
         gesture == self.landscapeGlobalCornerGuardGesture) &&
        landscapeRecognizer &&
        landscapeRecognizer.flmLandscapeRawCoordinateMode !=
            FLMLandscapeRawCoordinateModeUnknown) {
        CGRect bounds = self.landscapeIngressActive
                            ? self.landscapeIngressBounds
                            : FLMVisualScreenBounds();
        return FLMLandscapeVisualPointFromRawPoint(
            [gesture locationInView:nil], bounds,
            landscapeRecognizer.flmLandscapeRawCoordinateMode);
    }
    UIWindow *window = gesture.view.window;
    if (window == self.floatingWindow && self.floatingPresentationView) {
        return [gesture locationInView:self.floatingPresentationView];
    }
    if (window == self.hotspotWindow) {
        UIView *root = self.hotspotWindow.rootViewController.view;
        CGPoint local = [gesture locationInView:root];
        return FLMVisualPointFromRootPoint(
            local, root.bounds,
            CGRectIsEmpty(self.hotspotWindow.visualBounds)
                ? FLMVisualScreenBounds()
                : self.hotspotWindow.visualBounds,
            self.hotspotWindow.visualOrientation);
    }
    if (window == self.floatingDockTouchGateWindow) {
        UIView *root =
            self.floatingDockTouchGateWindow.rootViewController.view;
        CGPoint local = [gesture locationInView:root];
        return FLMVisualPointFromRootPoint(
            local, root.bounds,
            CGRectIsEmpty(self.floatingDockTouchGateWindow.visualBounds)
                ? FLMVisualScreenBounds()
                : self.floatingDockTouchGateWindow.visualBounds,
            self.floatingDockTouchGateWindow.visualOrientation);
    }
    CGPoint rawPoint = [gesture locationInView:nil];
    return FLMVisualPointFromRawPoint(rawPoint);
}

- (CGPoint)visualPointForTouch:(UITouch *)touch {
    if (!touch) {
        return CGPointZero;
    }
    UIWindow *window = touch.view.window;
    if (window == self.floatingWindow && self.floatingPresentationView) {
        return [touch locationInView:self.floatingPresentationView];
    }
    if (window == self.hotspotWindow) {
        UIView *root = self.hotspotWindow.rootViewController.view;
        CGPoint local = [touch locationInView:root];
        return FLMVisualPointFromRootPoint(
            local, root.bounds,
            CGRectIsEmpty(self.hotspotWindow.visualBounds)
                ? FLMVisualScreenBounds()
                : self.hotspotWindow.visualBounds,
            self.hotspotWindow.visualOrientation);
    }
    if (window == self.floatingDockTouchGateWindow) {
        UIView *root =
            self.floatingDockTouchGateWindow.rootViewController.view;
        CGPoint local = [touch locationInView:root];
        return FLMVisualPointFromRootPoint(
            local, root.bounds,
            CGRectIsEmpty(self.floatingDockTouchGateWindow.visualBounds)
                ? FLMVisualScreenBounds()
                : self.floatingDockTouchGateWindow.visualBounds,
            self.floatingDockTouchGateWindow.visualOrientation);
    }
    CGPoint rawPoint = [touch locationInView:nil];
    return FLMVisualPointFromRawPoint(rawPoint);
}

- (void)captureFloatingOrientationContract {
    CGRect liveBounds = FLMVisualScreenBounds();
    BOOL landscapeIngress =
        self.landscapeIngressActive &&
        FLMBoundsAreLandscape(self.landscapeIngressBounds);
    CGRect bounds = landscapeIngress ? self.landscapeIngressBounds : liveBounds;
    CGSize systemSize = bounds.size;
    UIView *rootView = self.floatingWindow.rootViewController.view;
    [rootView layoutIfNeeded];
    BOOL landscape = FLMBoundsAreLandscape(bounds);
    UIEdgeInsets rawSafeInsets =
        rootView ? rootView.safeAreaInsets : UIEdgeInsetsZero;
    if (landscape &&
        rawSafeInsets.top + rawSafeInsets.left + rawSafeInsets.bottom +
                rawSafeInsets.right <
            0.5) {
        UIView *overlayRoot = self.overlayWindow.rootViewController.view;
        [overlayRoot layoutIfNeeded];
        UIEdgeInsets overlaySafeInsets =
            overlayRoot ? overlayRoot.safeAreaInsets : UIEdgeInsetsZero;
        if (overlaySafeInsets.top + overlaySafeInsets.left +
                overlaySafeInsets.bottom + overlaySafeInsets.right >
            0.5) {
            rawSafeInsets = overlaySafeInsets;
        }
    }
    if (landscape &&
        rawSafeInsets.top + rawSafeInsets.left + rawSafeInsets.bottom +
                rawSafeInsets.right <
            0.5) {
        UIView *hotspotRoot = self.hotspotWindow.rootViewController.view;
        [hotspotRoot layoutIfNeeded];
        UIEdgeInsets hotspotSafeInsets =
            hotspotRoot ? hotspotRoot.safeAreaInsets : UIEdgeInsetsZero;
        if (hotspotSafeInsets.top + hotspotSafeInsets.left +
                hotspotSafeInsets.bottom + hotspotSafeInsets.right >
            0.5) {
            rawSafeInsets = hotspotSafeInsets;
        }
    }
    UIInterfaceOrientation orientation = UIInterfaceOrientationPortrait;
    if (landscape) {
        if (self.landscapeIngressRawMode ==
            FLMLandscapeRawCoordinateModeFixedLandscapeLeft) {
            orientation = UIInterfaceOrientationLandscapeLeft;
        } else if (self.landscapeIngressRawMode ==
                   FLMLandscapeRawCoordinateModeFixedLandscapeRight) {
            orientation = UIInterfaceOrientationLandscapeRight;
        } else {
            orientation = FLMLandscapeOrientationForSafeInsets(rawSafeInsets);
        }
    }
    CGFloat notchInset =
        landscape ? FLMLandscapeNotchAvoidanceInset(rawSafeInsets) : 0.0;
    UIEdgeInsets physicalSafeInsets =
        landscape
            ? UIEdgeInsetsMake(0.0, notchInset,
                               MIN(21.0, MAX(0.0, rawSafeInsets.bottom)),
                               notchInset)
            : rawSafeInsets;

    self.floatingLandscapeSession = landscape;
    self.floatingLandscapeSystemSize = landscape ? systemSize : CGSizeZero;
    self.floatingLandscapeSafeInsets =
        landscape ? physicalSafeInsets : UIEdgeInsetsZero;
    self.floatingLandscapeInterfaceOrientation = orientation;

    FLMFloatingWindow *floatingWindow =
        (FLMFloatingWindow *)self.floatingWindow;
    floatingWindow.visualBounds = bounds;
    floatingWindow.visualOrientation = orientation;
    rootView.frame = self.floatingWindow.bounds;
    FLMConfigureVisualCanvas(self.floatingPresentationView, rootView, bounds,
                             orientation);
    self.floatingDimView.frame = self.floatingPresentationView.bounds;

    self.floatingDockTouchGateWindow.visualBounds = bounds;
    self.floatingDockTouchGateWindow.visualOrientation = orientation;

    FLMKeyboardSharedLandscapeScene = landscape;
    FLMKeyboardSharedInterfaceOrientation = orientation;
    FLMKeyboardSharedSystemWidth = landscape ? systemSize.width : 0.0;
    FLMKeyboardSharedSystemHeight = landscape ? systemSize.height : 0.0;
    FLMEnqueueDiagnosticLine(
        @"sb presentation-session landscape=%d system={%.1f,%.1f} orientation=%ld root=%@ rawSafe={%.1f,%.1f,%.1f,%.1f} physicalSafe={%.1f,%.1f,%.1f,%.1f}",
        landscape, systemSize.width, systemSize.height, (long)orientation,
        NSStringFromCGRect(rootView.bounds),
        rawSafeInsets.top, rawSafeInsets.left, rawSafeInsets.bottom,
        rawSafeInsets.right, physicalSafeInsets.top, physicalSafeInsets.left,
        physicalSafeInsets.bottom, physicalSafeInsets.right);
}

- (void)clearFloatingOrientationContract {
    self.floatingLandscapeSession = NO;
    self.floatingLandscapeInterfaceOrientation = UIInterfaceOrientationPortrait;
    self.floatingLandscapeSystemSize = CGSizeZero;
    self.floatingLandscapeSafeInsets = UIEdgeInsetsZero;
    self.landscapeIngressActive = NO;
    self.landscapeIngressBounds = CGRectZero;
    self.landscapeIngressRawMode = FLMLandscapeRawCoordinateModeUnknown;
    FLMKeyboardSharedLandscapeScene = NO;
    FLMKeyboardSharedInterfaceOrientation = UIInterfaceOrientationPortrait;
    FLMKeyboardSharedSystemWidth = 0.0;
    FLMKeyboardSharedSystemHeight = 0.0;
}

- (CGRect)landscapeFloatingFrame {
    UIView *rootView = [self floatingLayoutView];
    CGRect bounds = rootView.bounds;
    UIEdgeInsets safeInsets = [self floatingLayoutSafeInsets];
    CGFloat availableHeight =
        MAX(1.0, CGRectGetHeight(bounds) - safeInsets.top - safeInsets.bottom -
                     FLMLandscapeCardVerticalMargin * 2.0);
    CGFloat portraitAspect =
        [self effectiveCenteredCardWidth] /
        MAX(1.0, [self effectiveCenteredCardHeight]);
    CGFloat cardHeight = MIN([self effectiveCenteredCardHeight], availableHeight);
    CGFloat cardWidth = cardHeight * portraitAspect;
    CGFloat originX = safeInsets.left + FLMLandscapeCardSideMargin;
    CGFloat usableHeight = CGRectGetHeight(bounds) - safeInsets.top - safeInsets.bottom;
    CGFloat originY = safeInsets.top + MAX(FLMLandscapeCardVerticalMargin,
                                            floor((usableHeight - cardHeight) * 0.5));
    return CGRectMake(originX, originY, cardWidth, cardHeight);
}

- (CGRect)centeredFloatingFrame {
    if ([self isLandscapeFloatingSession]) {
        return [self landscapeFloatingFrame];
    }
    CGRect bounds = [self floatingLayoutView].bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    if (width <= 0.0 || height <= 0.0) {
        return CGRectZero;
    }

    UIEdgeInsets safeInsets =
        self.floatingWindow.rootViewController.view.safeAreaInsets;
    // The centered card dimensions are explicit presentation preferences.
    // Never derive them from orientation, safe-area height, keyboard state, or
    // Scene geometry. The app itself remains a full-screen Scene underneath.
    const CGFloat containerWidth = [self effectiveCenteredCardWidth];
    const CGFloat containerHeight = [self effectiveCenteredCardHeight];
    CGFloat centeredUpperTop =
        floor((height - containerHeight) * 0.5 - 44.0);
    CGFloat top = MAX(safeInsets.top + 8.0, centeredUpperTop);
    CGFloat originX = floor((width - containerWidth) * 0.5);
    return CGRectMake(originX, top, containerWidth, containerHeight);
}

- (CGRect)dockedFloatingFrameOnRight:(BOOL)onRight width:(CGFloat)width {
    UIView *rootView = [self floatingLayoutView];
    CGRect bounds = rootView.bounds;
    UIEdgeInsets safeInsets = [self floatingLayoutSafeInsets];
    CGRect centeredFrame = [self centeredFloatingFrame];
    CGFloat aspectRatio =
        CGRectGetWidth(centeredFrame) / MAX(1.0, CGRectGetHeight(centeredFrame));
    CGFloat clampedWidth =
        MAX(FLMMinimumDockPresentationWidth,
            MIN(FLMMaximumDockWidth, width));
    CGFloat height = clampedWidth / MAX(0.1, aspectRatio);
    CGFloat top = safeInsets.top + FLMDockTopMargin;
    CGFloat originX =
        onRight
            ? CGRectGetWidth(bounds) - safeInsets.right -
                  FLMDockSideMargin - clampedWidth
            : safeInsets.left + FLMDockSideMargin;
    return CGRectMake(originX, top, clampedWidth, height);
}

- (CGRect)dockedFloatingFrameOnRight:(BOOL)onRight
                               width:(CGFloat)width
             preservingVerticalCenter:(CGFloat)verticalCenter {
    CGRect frame = [self dockedFloatingFrameOnRight:onRight width:width];
    UIView *rootView = [self floatingLayoutView];
    UIEdgeInsets safeInsets = [self floatingLayoutSafeInsets];
    CGFloat halfHeight = CGRectGetHeight(frame) * 0.5;
    CGFloat minimumCenterY = safeInsets.top + halfHeight;
    CGFloat maximumCenterY =
        CGRectGetHeight(rootView.bounds) - safeInsets.bottom - halfHeight;
    if (maximumCenterY < minimumCenterY) {
        maximumCenterY = minimumCenterY;
    }
    CGFloat clampedCenterY =
        MAX(minimumCenterY, MIN(maximumCenterY, verticalCenter));
    frame.origin.y = clampedCenterY - halfHeight;
    return frame;
}

- (CGRect)dockedHiddenFloatingFrameOnRight:(BOOL)onRight
                                      width:(CGFloat)width {
    CGRect frame = [self dockedFloatingFrameOnRight:onRight width:width];
    return [self dockedHiddenFloatingFrameOnRight:onRight
                                            width:width
                          preservingVerticalCenter:CGRectGetMidY(frame)];
}

- (CGRect)dockedHiddenFloatingFrameOnRight:(BOOL)onRight
                                      width:(CGFloat)width
                    preservingVerticalCenter:(CGFloat)verticalCenter {
    CGRect frame =
        [self dockedFloatingFrameOnRight:onRight
                                  width:width
                preservingVerticalCenter:verticalCenter];
    // Fully hide the card off-screen: only the edge handle bar remains
    // visible, so the user never sees an app sliver next to it.
    CGFloat visibleSliver = 0.0;
    frame.origin.x = onRight
                         ? CGRectGetWidth([self floatingLayoutView].bounds) -
                               visibleSliver
                         : visibleSliver - CGRectGetWidth(frame);
    return frame;
}

- (void)layoutFloatingDockShadow {
    // The dock shadow was removed: the release animation previously left a
    // visible dark halo behind the card. Keep the view tree intact so all
    // callers stay valid, but never present the shadow.
    self.floatingDockShadowView.hidden = YES;
    self.floatingDockShadowView.alpha = 0.0;
    return;
}

- (void)updateFloatingDockAccessoryPositions {
    BOOL dockInputInFlight =
        self.floatingDockInputSessionActive &&
        (self.floatingDockInputMode == FLMFloatingDockInputModeCardDrag ||
         self.floatingDockInputMode == FLMFloatingDockInputModeResize);
    if (dockInputInFlight || self.floatingDockGlobalDragActivated) {
        // The active display-wide recognizer already owns this touch. The
        // resize target is invisible and the gate is only needed for the
        // next touch, so defer sibling-window/frame work until the settle
        // animation. This keeps the remote surface on the compositor path
        // instead of forcing a full accessory/layout update every sample.
        return;
    }
    if (!self.floatingDocked) {
        [self layoutFloatingResizeHandle];
        [self updateFloatingDockTouchGate];
        return;
    }
    if (!self.floatingDockShadowView.hidden) {
        self.floatingDockShadowView.center = self.floatingContainer.center;
        self.floatingDockShadowView.transform = self.floatingContainer.transform;
    }
    [self layoutFloatingResizeHandle];
    [self updateFloatingDockTouchGate];
}

- (void)layoutFloatingResizeHandle {
    if (!self.floatingResizeHandle || !self.floatingDocked ||
        [self isLandscapeFloatingSession] ||
        self.floatingDockHidden || self.floatingWindow.hidden) {
        self.floatingResizeHandle.hidden = YES;
        return;
    }
    CGRect frame = self.floatingContainer.frame;
    const CGFloat hitSize = 46.0;
    self.floatingResizeHandle.frame =
        self.floatingDockedOnRight
            ? CGRectMake(CGRectGetMinX(frame) - 32.0,
                         CGRectGetMaxY(frame) - 14.0,
                         hitSize,
                         hitSize)
            : CGRectMake(CGRectGetMaxX(frame) - 14.0,
                         CGRectGetMaxY(frame) - 14.0,
                         hitSize,
                         hitSize);
    // Keep the transparent target hit-testable.  No layer, border, alpha
    // animation, or other visual affordance is attached to this view.
    self.floatingResizeHandle.hidden = NO;
    self.floatingResizeHandle.alpha = 1.0;
}

- (BOOL)floatingResizeControlContainsPoint:(CGPoint)point {
    if (!self.floatingDocked || self.floatingDockHidden ||
        self.floatingResizeHandle.hidden) {
        return NO;
    }
    CGRect broadFrame = CGRectInset(self.floatingResizeHandle.frame, -10.0, -10.0);
    if (!CGRectContainsPoint(broadFrame, point)) {
        return NO;
    }
    UIBezierPath *path = [UIBezierPath bezierPath];
    if (self.floatingDockedOnRight) {
        [path moveToPoint:CGPointMake(24.0, 2.0)];
        [path addLineToPoint:CGPointMake(24.0, 12.0)];
        [path addQuadCurveToPoint:CGPointMake(34.0, 22.0)
                    controlPoint:CGPointMake(24.0, 22.0)];
        [path addLineToPoint:CGPointMake(44.0, 22.0)];
    } else {
        [path moveToPoint:CGPointMake(22.0, 2.0)];
        [path addLineToPoint:CGPointMake(22.0, 12.0)];
        [path addQuadCurveToPoint:CGPointMake(12.0, 22.0)
                    controlPoint:CGPointMake(22.0, 22.0)];
        [path addLineToPoint:CGPointMake(2.0, 22.0)];
    }
    CGPoint localPoint =
        CGPointMake(point.x - CGRectGetMinX(self.floatingResizeHandle.frame),
                    point.y - CGRectGetMinY(self.floatingResizeHandle.frame));
    CGPathRef touchPath =
        CGPathCreateCopyByStrokingPath(path.CGPath,
                                       NULL,
                                       20.0,
                                       kCGLineCapRound,
                                       kCGLineJoinRound,
                                       1.0);
    if (!touchPath) {
        return NO;
    }
    BOOL contains = CGPathContainsPoint(touchPath, NULL, localPoint, NO);
    CGPathRelease(touchPath);
    return contains;
}

- (void)saveFloatingDockWidth {
    self.floatingDockWidth =
        MAX(FLMMinimumDockPresentationWidth,
            MIN(FLMMaximumDockWidth, self.floatingDockWidth));
}

- (void)normalizeFloatingContainerTransform {
    if (CGAffineTransformIsIdentity(self.floatingContainer.transform)) {
        return;
    }
    CGRect visualFrame = self.floatingContainer.frame;
    [UIView performWithoutAnimation:^{
        self.floatingContainer.transform = CGAffineTransformIdentity;
        self.floatingContainer.frame = visualFrame;
        self.floatingDockShadowView.transform = CGAffineTransformIdentity;
        self.floatingDockShadowView.frame = visualFrame;
        if (self.floatingDocked) {
            self.floatingContainer.layer.cornerRadius =
                22.0 * self.floatingDockWidth / FLMCenteredCardWidth;
            self.floatingDockShadowView.layer.cornerRadius =
                22.0 * self.floatingDockWidth / FLMCenteredCardWidth;
        }
        self.floatingDockInteractionShield.frame = self.floatingContainer.bounds;
        [self layoutFloatingHostView];
        [self layoutFloatingResizeHandle];
    }];
}

- (void)configureFloatingInteractionForDockedState {
    if (self.floatingCloseInProgress) {
        // The close path already disabled every recognizer and owns presenter
        // teardown. Ignore completions from Dock/hidden animations that were
        // scheduled before close began.
        return;
    }
    if ([self isLandscapeFloatingSession]) {
        // Landscape minimal mode intentionally has no edge bar, dock, resize,
        // or hide gesture. The card is fixed at the left edge and the only
        // card-shell action is tapping outside to close it.
        self.floatingDocked = NO;
        self.floatingDockHidden = NO;
        self.floatingDockTransitionActive = NO;
        self.floatingDockControlArmed = NO;
        self.floatingHandle.hidden = YES;
        self.floatingHandle.userInteractionEnabled = NO;
        self.floatingResizeHandle.hidden = YES;
        self.floatingResizeHandle.userInteractionEnabled = NO;
        self.floatingDockTap.enabled = NO;
        self.floatingDockDragPress.enabled = NO;
        self.floatingDockInputGesture.enabled = NO;
        self.floatingExclusiveGesture.enabled = NO;
        self.floatingBackdropTap.enabled =
            self.floatingCloseInputArmed && !self.floatingWindow.hidden;
        self.floatingHostView.userInteractionEnabled = YES;
        ((FLMFloatingWindow *)self.floatingWindow)
            .passesTouchesOutsideFloatingContent = NO;
        FLMPublishDockInputBlockState(self.floatingIdentifier,
                                      NO,
                                      @"landscape-minimal");
        return;
    }
    FLMFloatingWindow *floatingWindow =
        (FLMFloatingWindow *)self.floatingWindow;
    BOOL docked = self.floatingDocked;
    BOOL hidden = self.floatingDockHidden;
    if (!self.floatingDockTransitionActive &&
        !self.floatingDockGlobalDragActivated &&
        !self.floatingDockHideGestureActive &&
        !self.floatingDockInputSessionActive) {
        floatingWindow.suppressesCornerRoutingDuringDockGesture = NO;
    }
    floatingWindow.passesTouchesOutsideFloatingContent = docked || hidden;
    self.floatingBackdropTap.enabled =
        self.floatingCloseInputArmed && !docked && !hidden;
    self.floatingDockTap.enabled = NO;
    self.floatingDockDragPress.enabled = NO;
    self.floatingDockInputGesture.enabled = docked || hidden;
    self.floatingResizeHandle.userInteractionEnabled = docked && !hidden;
    self.floatingResizeHandle.hidden = !docked || hidden;
    self.floatingResizeHandle.alpha = 1.0;
    BOOL contentTailProtected =
        self.floatingDockContentTailProtected && !docked && !hidden;
    BOOL contentControlProtected =
        self.floatingDockControlArmed && !docked && !hidden;
    BOOL contentProtected =
        contentTailProtected || contentControlProtected;
    BOOL shieldOwnsCard = (docked && !hidden) || contentProtected;
    // Hidden Dock cards remain blocked in their application process too. The
    // local shield is intentionally hidden with the card, but that must never
    // reopen the remote Scene's input channel.
    BOOL remoteInputBlocked = docked || hidden || contentProtected;
    FLMPublishDockInputBlockState(self.floatingIdentifier,
                                  remoteInputBlocked,
                                  @"interaction-configure");
    self.floatingHostView.userInteractionEnabled =
        !docked && !hidden && !contentProtected;
    self.floatingDockInteractionShield.frame = self.floatingContainer.bounds;
    self.floatingDockInteractionShield.hidden =
        (!docked || hidden) && !contentProtected;
    self.floatingDockInteractionShield.userInteractionEnabled =
        shieldOwnsCard;
    if (shieldOwnsCard) {
        [self.floatingContainer
            bringSubviewToFront:self.floatingDockInteractionShield];
    }
    self.floatingHandle.userInteractionEnabled = hidden || !docked;
    self.floatingHandle.hidden = docked && !hidden;
    self.floatingHandlePress.enabled = !docked || hidden;
    self.floatingHandleTap.enabled = !docked && !hidden;
    self.floatingExclusiveGesture.enabled =
        self.floatingCloseInputArmed &&
        !docked && !hidden && self.usesSystemGestureManager &&
        !self.floatingWindow.hidden;
    if (hidden) {
        self.floatingResizeHandle.hidden = YES;
        self.floatingDimView.alpha = 0.0;
        self.floatingHandle.alpha = 1.0;
        self.floatingHandleBar.alpha = 1.0;
        self.floatingDockShadowView.alpha = 0.0;
        self.floatingDockShadowView.hidden = YES;
        [self layoutFloatingHandleForCurrentContainer];
        if (self.previousKeyWindow &&
            self.previousKeyWindow != self.floatingWindow) {
            [self.previousKeyWindow makeKeyWindow];
        }
    } else if (docked) {
        [self layoutFloatingResizeHandle];
        self.floatingDimView.alpha = 0.0;
        self.floatingHandle.alpha = 0.0;
        self.floatingHandleBar.alpha = 1.0;
        self.floatingDockShadowView.alpha = 0.0;
        [self layoutFloatingDockShadow];
        if (self.previousKeyWindow &&
            self.previousKeyWindow != self.floatingWindow) {
            [self.previousKeyWindow makeKeyWindow];
        }
    } else {
        self.floatingResizeHandle.hidden = YES;
        self.floatingHandle.alpha = 1.0;
        self.floatingHandleBar.alpha = 1.0;
        self.floatingDockShadowView.alpha = 0.0;
        self.floatingDockShadowView.hidden = YES;
        [self.floatingWindow makeKeyWindow];
    }
    [self updateFloatingDockTouchGate];
}

- (void)armFloatingCloseInputForGeneration:(NSUInteger)generation {
    if (generation != self.floatingLaunchGeneration ||
        self.floatingWindow.hidden || self.floatingCloseInProgress) {
        return;
    }
    self.floatingCloseInputArmed = YES;
    self.floatingCloseArmAt = CACurrentMediaTime();
    [self configureFloatingInteractionForDockedState];
    FLMDiagnosticLog(
        @"sb close-input armed generation=%lu armAt=%.6f window=%@",
        (unsigned long)generation, self.floatingCloseArmAt,
        NSStringFromCGRect(self.floatingWindow.frame));
}

- (void)restoreFloatingHandleInteraction {
    // configureFloatingInteractionForDockedState deliberately disables the
    // handle for a docked card.  The old close/open path only unhid it, so a
    // subsequently centered card could display a white bar whose recognizers
    // never received touches.  Keep this reset independent of Scene startup.
    self.floatingHandle.hidden = NO;
    self.floatingHandle.alpha = 1.0;
    self.floatingHandleBar.alpha = 1.0;
    self.floatingHandle.userInteractionEnabled = YES;
    self.floatingHandlePress.enabled = YES;
    self.floatingHandleTap.enabled = YES;
}

- (void)transitionFloatingWindowToDocked {
    self.floatingDockReady = NO;
    if (self.floatingWindow.hidden || self.floatingDocked) {
        return;
    }
    self.floatingDockContentTailProtected = NO;
    self.floatingDockContentProtectionGeneration += 1;
    self.floatingDockControlArmed = YES;
    self.floatingDockEntryControlTouchPending = NO;
    // Invalidate any global dock recognizer that may still be observing the
    // centered handle's original touch.  The dock becomes eligible only for a
    // later touch, never for the tail of the docking swipe itself.
    [self cancelFloatingDockInputUpdates];
    self.floatingDockInputGeneration += 1;
    self.floatingDockInputSessionActive = NO;
    self.floatingDockInputMode = FLMFloatingDockInputModeNone;
    self.floatingDockInputTargetsResize = NO;
    self.floatingDockGlobalDragActivated = NO;
    self.floatingDockInputBlockedUntilNextTouch = YES;
    // The current centered-to-dock swipe may still be observed by the
    // display-wide recognizer after the visual transition starts.  Reject
    // only that old touch stream; the first touch with a newer timestamp is
    // allowed to operate the settled dock immediately.
    self.floatingDockInputBlockCutoffTimestamp = CACurrentMediaTime();
    [self setFloatingApplicationInputBlocked:YES];
    [self setFloatingDockRoutingSuppressed:YES];
    // A card session is created before the keyboard itself appears. When no
    // keyboard/forwarding host is active, tearing that route down here performs
    // several notify posts and shared-state writes on the animation's first
    // frame. Keep the visual transition independent and clear the idle route
    // after the card has settled. A live keyboard still gets the old immediate
    // teardown so its responder ownership cannot leak into docked mode.
    BOOL keyboardNeedsImmediateTeardown =
        self.floatingKeyboardVisible ||
        self.floatingKeyboardInteractionSessionActive ||
        self.floatingKeyboardLayerHostView != nil ||
        self.keyboardForwardingWindow.isKeyWindow;
    BOOL deferKeyboardTeardown =
        !keyboardNeedsImmediateTeardown &&
        self.floatingKeyboardSessionGeneration != 0;
    if (!deferKeyboardTeardown) {
        [self endFloatingKeyboardSession];
    }
    self.floatingDockTransitionActive = YES;
    self.floatingDockEntrySettleActive = YES;
    NSUInteger entrySettleGeneration =
        ++self.floatingDockEntrySettleGeneration;
    self.floatingDockHidden = NO;
    self.floatingDockHideGestureActive = NO;
    self.floatingDockHideInitialHandleFrame = CGRectNull;
    self.floatingDockedOnRight = [self isLandscapeFloatingSession] ? NO : YES;
    self.floatingDockWidth = [self effectiveDockedPresentationWidth];
    CGRect target =
        [self dockedFloatingFrameOnRight:self.floatingDockedOnRight
                                   width:self.floatingDockWidth];
    CGRect source = [self floatingContainerPresentationFrame];
    self.floatingDockEntryTargetFrame = target;
    self.floatingDockTouchCaptureFrame = CGRectUnion(source, target);
    self.floatingDockInputGesture.enabled = YES;
    [self updateFloatingDockTouchGate];
    self.floatingDockVerticalCenter = CGRectGetMidY(target);
    CGFloat targetScale =
        CGRectGetWidth(target) /
        MAX(1.0, CGRectGetWidth(self.floatingContainer.bounds));
    self.floatingDockShadowView.hidden = YES;
    [self beginFloatingHighRefreshLeaseForDuration:0.36 / FLMDockAnimationSpeed];
    [UIView animateWithDuration:0.36 / FLMDockAnimationSpeed
                          delay:0.0
         usingSpringWithDamping:0.84
          initialSpringVelocity:0.30
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         // Keep the release as one compositor transaction. The
                         // former nested spring first settled in place and then
                         // started a second spring to the dock, which made the
                         // remote surface and the card layer compete for two
                         // consecutive layout/animation commits.
                         self.floatingContainer.center =
                             CGPointMake(CGRectGetMidX(target),
                                         CGRectGetMidY(target));
                         self.floatingContainer.transform =
                             CGAffineTransformMakeScale(targetScale, targetScale);
                         self.floatingContainer.layer.cornerRadius = 22.0;
                         self.floatingDimView.alpha = 0.0;
                          self.floatingDockShadowView.alpha = 0.0;
                          self.floatingHandle.alpha = 0.0;
                      }
                      completion:^(__unused BOOL finished) {
                          if (entrySettleGeneration !=
                                  self.floatingDockEntrySettleGeneration ||
                              !self.floatingDockEntrySettleActive) {
                              return;
                          }
                          if (self.floatingWindow.hidden ||
                              self.floatingCloseInProgress ||
                              self.floatingIdentifier.length == 0) {
                              self.floatingDockEntrySettleActive = NO;
                              self.floatingDockControlArmed = NO;
                              self.floatingDockEntryTargetFrame = CGRectNull;
                              self.floatingDockTouchCaptureFrame = CGRectNull;
                              self.floatingDockTransitionActive = NO;
                              [self updateFloatingDockTouchGate];
                              if (deferKeyboardTeardown) {
                                  [self endFloatingKeyboardSession];
                              }
                              [self setFloatingDockRoutingSuppressed:NO];
                              return;
                          }
                          [UIView performWithoutAnimation:^{
                              self.floatingContainer.transform =
                                  CGAffineTransformIdentity;
                              self.floatingContainer.frame = target;
                              self.floatingContainer.layer.cornerRadius =
                                  22.0 * self.floatingDockWidth /
                                      FLMCenteredCardWidth;
                              self.floatingDockShadowView.transform =
                                  CGAffineTransformIdentity;
                              self.floatingDockShadowView.frame = target;
                              self.floatingDockShadowView.layer.cornerRadius =
                                  22.0 * self.floatingDockWidth /
                                      FLMCenteredCardWidth;
                              // Mark the state before the one final host layout
                               // so the docked crop is applied without a snap.
                               self.floatingDocked = YES;
                               [self layoutFloatingHostView];
                          }];
                          self.floatingDockEntrySettleActive = NO;
                          self.floatingDockControlArmed = NO;
                          self.floatingDockEntryTargetFrame = CGRectNull;
                          self.floatingDockTouchCaptureFrame = CGRectNull;
                          self.floatingDockTransitionActive = NO;
                          self.floatingDockHidden = NO;
                          self.lastObservedFrontmostIdentifier =
                              FLMFrontmostApplicationIdentifier();
                          self.floatingExternalActivationArmed =
                              ![self.lastObservedFrontmostIdentifier
                                  isEqualToString:self.floatingIdentifier];
                          self.floatingHandleBar.alpha = 1.0;
                          self.floatingHandleBar.transform =
                              CGAffineTransformIdentity;
                          [self configureFloatingInteractionForDockedState];
                          if (deferKeyboardTeardown) {
                              [self endFloatingKeyboardSession];
                          }
                          [self setFloatingDockRoutingSuppressed:NO];
                      }];
}

- (void)transitionFloatingWindowToCentered {
    self.floatingDockReady = NO;
    if (self.floatingWindow.hidden || !self.floatingDocked) {
        return;
    }
    self.floatingDockContentTailProtected = NO;
    self.floatingDockContentProtectionGeneration += 1;
    self.floatingDockEntrySettleActive = NO;
    self.floatingDockEntrySettleGeneration += 1;
    self.floatingDockEntryControlTouchPending = NO;
    self.floatingDockControlArmed = NO;
    self.floatingDockEntryTargetFrame = CGRectNull;
    self.floatingDockTouchCaptureFrame = CGRectNull;
    FLMFloatingWindow *floatingWindow =
        (FLMFloatingWindow *)self.floatingWindow;
    [self cancelFloatingDockInputUpdates];
    [self setFloatingDockRoutingSuppressed:YES];
    floatingWindow.passesTouchesOutsideFloatingContent = NO;
    self.floatingDockTap.enabled = NO;
    self.floatingDockDragPress.enabled = NO;
    self.floatingDockInputGesture.enabled = NO;
    self.floatingDockInputGeneration += 1;
    self.floatingDockGlobalDragActivated = NO;
    self.floatingDockInputSessionActive = NO;
    self.floatingDockInputMode = FLMFloatingDockInputModeNone;
    self.floatingDockInputTargetsResize = NO;
    self.floatingDockInputBlockedUntilNextTouch = YES;
    self.floatingDockInputBlockCutoffTimestamp = CACurrentMediaTime();
    self.floatingDockTransitionActive = YES;
    self.floatingResizeCenterReady = NO;
    self.floatingResizeHandle.hidden = YES;
    [self updateFloatingDockTouchGate];
    self.floatingDockShadowView.hidden = YES;
    self.floatingDocked = NO;
    self.floatingDockHidden = NO;
    self.floatingDockHideGestureActive = NO;
    [self setFloatingApplicationInputBlocked:YES];
    [self restoreFloatingHandleInteraction];
    self.floatingExternalActivationArmed = NO;
    self.floatingFullscreenActivationArmed = NO;
    self.lastObservedFrontmostIdentifier = nil;
    // Returning to the centered card changes only the presentation crop and
    // scale. Keep the application Scene full-screen and the keyboard route
    // unchanged.
    self.floatingSceneUsesCardGeometry = NO;
    self.floatingSceneCardGeometryPending = NO;
    self.floatingSceneCardGeometryCommitted = YES;
    [self applyFloatingSceneLogicalFrameForCurrentPresentation:
              @"content-viewport-restore"];
    [self discardFloatingKeyboardLayerHost];
    self.floatingKeyboardSessionCounter += 1;
    if (self.floatingKeyboardSessionCounter == 0) {
        self.floatingKeyboardSessionCounter = 1;
    }
    self.floatingKeyboardSessionGeneration =
        self.floatingKeyboardSessionCounter;
    FLMPublishKeyboardState(self.floatingIdentifier,
                            self.floatingScene,
                            self.floatingKeyboardSessionGeneration);
    [self.floatingWindow makeKeyWindow];
    CGRect target = [self centeredFloatingFrame];
    self.floatingHandle.hidden = NO;
    [self beginFloatingHighRefreshLeaseForDuration:0.42];
    [UIView animateWithDuration:0.42
                          delay:0.0
         usingSpringWithDamping:0.82
          initialSpringVelocity:0.30
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         self.floatingContainer.transform =
                             CGAffineTransformIdentity;
                         self.floatingContainer.layer.borderWidth = 0.0;
                         self.floatingContainer.frame = target;
                         self.floatingContainer.layer.cornerRadius = 22.0;
                         self.floatingDimView.alpha = 1.0;
                         self.floatingDockShadowView.alpha = 0.0;
                         self.floatingDockShadowView.frame = target;
                         self.floatingHandle.alpha = 1.0;
                         self.floatingHandleBar.alpha = 1.0;
                         [self layoutFloatingHostView];
                         [self layoutFloatingHandleForCurrentContainer];
                     }
                      completion:^(BOOL finished) {
                          (void)finished;
                          self.floatingDockTransitionActive = NO;
                          // Establish the short post-control tail before the
                          // centered configuration can reopen application
                          // delivery. This keeps one continuous block from
                          // Dock touch-begin through the return animation.
                          [self protectFloatingContentAfterDockTouch];
                          [self configureFloatingInteractionForDockedState];
                          [self setFloatingDockRoutingSuppressed:NO];
                      }];
}

- (void)snapDockedFloatingWindowUsingTouchPoint:(CGPoint)point {
    (void)point;
    if (!self.floatingDocked || self.floatingDockHidden) {
        self.floatingDockTransitionActive = NO;
        [self setFloatingDockRoutingSuppressed:NO];
        return;
    }
    // The drag is free in both axes.  Decide the landing side from the card's
    // actual final center (which represents which half of the screen contains
    // more of the card), not from the finger's last sample.  The target keeps
    // the current vertical center, so release never snaps the card upward or
    // downward into a corner.
    [self normalizeFloatingContainerTransform];
    CGRect bounds = [self floatingLayoutView].bounds;
    CGRect currentFrame = self.floatingContainer.frame;
    CGFloat currentMidX = CGRectGetMidX(currentFrame);
    CGFloat screenMidX = CGRectGetMidX(bounds);
    self.floatingDockedOnRight = [self isLandscapeFloatingSession]
                                      ? currentMidX > screenMidX
                                      : currentMidX >= screenMidX;
    CGRect target =
        [self dockedFloatingFrameOnRight:self.floatingDockedOnRight
                                   width:self.floatingDockWidth
                 preservingVerticalCenter:CGRectGetMidY(currentFrame)];
    self.floatingDockVerticalCenter = CGRectGetMidY(target);
    FLMDiagnosticLog(
        @"sb dock-snap side=%@ current=%@ target=%@ vertical=%.1f",
        self.floatingDockedOnRight ? @"right" : @"left",
        NSStringFromCGRect(currentFrame),
        NSStringFromCGRect(target),
        self.floatingDockVerticalCenter);
    self.floatingDockTransitionActive = YES;
    [self setFloatingDockRoutingSuppressed:YES];
    [self beginFloatingHighRefreshLeaseForDuration:0.28];
    [UIView animateWithDuration:0.28
                          delay:0.0
         usingSpringWithDamping:0.88
          initialSpringVelocity:0.28
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         self.floatingContainer.center =
                             CGPointMake(CGRectGetMidX(target),
                                         CGRectGetMidY(target));
                         [self updateFloatingDockAccessoryPositions];
                     }
                      completion:^(BOOL finished) {
                          (void)finished;
                          if (self.floatingWindow.hidden ||
                              !self.floatingDocked ||
                              self.floatingDockHidden) {
                              self.floatingDockTransitionActive = NO;
                              [self setFloatingDockRoutingSuppressed:NO];
                              return;
                          }
                         [UIView performWithoutAnimation:^{
                              self.floatingContainer.transform =
                                  CGAffineTransformIdentity;
                              self.floatingContainer.layer.borderWidth = 0.0;
                              [self layoutFloatingDockShadow];
                              [self layoutFloatingResizeHandle];
                          }];
                          self.floatingDockTransitionActive = NO;
                           [self updateFloatingDockAccessoryPositions];
                           [self setFloatingDockRoutingSuppressed:NO];
                       }];
}

- (void)configureFloatingLaunchCoverForIdentifier:(NSString *)identifier {
    self.floatingLaunchIconView.image = FLMApplicationIcon(identifier);
    self.floatingLaunchCoverView.alpha = 1.0;
    self.floatingLaunchCoverView.hidden = NO;
    self.floatingLaunchCoverView.userInteractionEnabled = YES;
    self.floatingStatusLabel.hidden = YES;
    [self.floatingContainer bringSubviewToFront:self.floatingLaunchCoverView];
    if (!self.floatingDockInteractionShield.hidden) {
        [self.floatingContainer bringSubviewToFront:self.floatingDockInteractionShield];
    }
}

- (void)revealFloatingContentForGeneration:(NSUInteger)generation {
    // A presentationView can exist one or two compositor frames before its
    // remote surface contains the app. Keep the neutral app cover above it for
    // that short interval, then reveal the already-laid-out content once.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(FLMFloatingLaunchCoverSettleDelay *
                                           NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != self.floatingLaunchGeneration ||
            self.floatingWindow.hidden) {
            return;
        }
        if (!self.floatingHostView ||
            self.floatingLaunchState != FLMFloatingLaunchStateAttached) {
            if (self.floatingRevealRetryCount < 4) {
                self.floatingRevealRetryCount += 1;
                FLMDiagnosticLog(
                    @"sb launch-cover retry-reveal generation=%lu retry=%lu state=%lu host=%p",
                    (unsigned long)generation,
                    (unsigned long)self.floatingRevealRetryCount,
                    (unsigned long)self.floatingLaunchState,
                    (__bridge void *)self.floatingHostView);
                [self revealFloatingContentForGeneration:generation];
            } else {
                FLMDiagnosticLog(
                    @"sb launch-cover recovery-failed generation=%lu state=%lu host=%p",
                    (unsigned long)generation,
                    (unsigned long)self.floatingLaunchState,
                    (__bridge void *)self.floatingHostView);
                [self failFloatingLaunchForIdentifier:self.floatingIdentifier
                                             generation:generation];
            }
            return;
        }
        self.floatingRevealRetryCount = 0;
        [self.floatingHostView setNeedsLayout];
        [self.floatingHostView layoutIfNeeded];
        [self beginFloatingHighRefreshLeaseForDuration:FLMFloatingLaunchCoverFadeDuration];
        [UIView animateWithDuration:FLMFloatingLaunchCoverFadeDuration
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseOut |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
                             self.floatingLaunchCoverView.alpha = 0.0;
                         }
                         completion:^(__unused BOOL finished) {
            if (generation != self.floatingLaunchGeneration ||
                self.floatingWindow.hidden ||
                self.floatingLaunchState != FLMFloatingLaunchStateAttached) {
                return;
            }
            self.floatingLaunchCoverView.hidden = YES;
            self.floatingLaunchCoverView.alpha = 1.0;
            self.floatingLaunchCoverView.userInteractionEnabled = NO;
            // The launch-cover completion is also used by the hidden-mode
            // frontmost-app route.  Do not blindly re-enable the remote host
            // here: the dock/hidden transition can still be pending, and the
            // completion itself must never be the first path that lets a
            // touch reach app content.
            BOOL contentCanInteract =
                !self.floatingDocked &&
                !self.floatingDockHidden &&
                !self.floatingDockTransitionActive &&
                !self.floatingDockControlArmed &&
                !self.floatingDockContentTailProtected &&
                !self.floatingOpenTargetDocked;
            [self setFloatingApplicationInputBlocked:!contentCanInteract];
            self.floatingHandle.userInteractionEnabled = contentCanInteract;
            self.floatingExclusiveGesture.enabled =
                contentCanInteract && self.usesSystemGestureManager;
            if (self.floatingOpenTargetDocked) {
                self.floatingOpenTargetDocked = NO;
                FLMDiagnosticLog(
                    @"sb home-dock transition app=%@",
                    self.floatingIdentifier ?: @"<none>");
                [self transitionFloatingWindowToDocked];
            }
        }];
    });
}

- (void)layoutFloatingWindow {
    if (!self.floatingWindow) {
        return;
    }
    CGRect bounds = [self floatingLayoutView].bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    if (width <= 0.0 || height <= 0.0) {
        return;
    }

    CGRect targetFrame = [self centeredFloatingFrame];
    if (self.floatingDocked) {
        CGFloat verticalCenter = self.floatingDockVerticalCenter;
        if (verticalCenter <= 0.0) {
            verticalCenter = CGRectGetMidY(self.floatingContainer.frame);
        }
        CGRect fallbackFrame =
            [self dockedFloatingFrameOnRight:self.floatingDockedOnRight
                                       width:self.floatingDockWidth];
        if (verticalCenter <= 0.0) {
            verticalCenter = CGRectGetMidY(fallbackFrame);
        }
        targetFrame = self.floatingDockHidden
                          ? [self dockedHiddenFloatingFrameOnRight:
                                   self.floatingDockedOnRight
                                                               width:self.floatingDockWidth
                                             preservingVerticalCenter:verticalCenter]
                          : [self dockedFloatingFrameOnRight:
                                   self.floatingDockedOnRight
                                                               width:self.floatingDockWidth
                                             preservingVerticalCenter:verticalCenter];
        self.floatingDockVerticalCenter = CGRectGetMidY(targetFrame);
    }
    self.floatingContainer.frame = targetFrame;
    [self layoutFloatingHostView];
    self.floatingStatusLabel.frame = self.floatingContainer.bounds;
    self.floatingLaunchCoverView.frame = self.floatingContainer.bounds;
    CGFloat iconSide = MIN(88.0,
                           MAX(64.0,
                               CGRectGetWidth(self.floatingContainer.bounds) *
                                   0.24));
    self.floatingLaunchIconView.bounds =
        CGRectMake(0.0, 0.0, iconSide, iconSide);
    self.floatingLaunchIconView.center =
        CGPointMake(CGRectGetMidX(self.floatingLaunchCoverView.bounds),
                    CGRectGetMidY(self.floatingLaunchCoverView.bounds));
    self.floatingDockInteractionShield.frame = self.floatingContainer.bounds;
    [self layoutFloatingHandleForCurrentContainer];
    [self layoutFloatingDockShadow];
    [self layoutFloatingResizeHandle];
    [self updateFloatingDockTouchGate];
}

- (void)layoutFloatingHandleForCurrentContainer {
    if ([self isLandscapeFloatingSession]) {
        self.floatingHandle.hidden = YES;
        self.floatingHandleBar.hidden = YES;
        self.floatingHandle.frame = CGRectZero;
        return;
    }
    CGRect bounds = [self floatingLayoutView].bounds;
    CGFloat containerWidth = CGRectGetWidth(self.floatingContainer.frame);
    if (self.floatingDockHidden) {
        CGFloat handleWidth = 44.0;
        CGFloat handleHeight = 72.0;
        UIEdgeInsets safeInsets = [self floatingLayoutSafeInsets];
        CGFloat leftEdge = [self isLandscapeFloatingSession]
                               ? safeInsets.left
                               : 0.0;
        CGFloat rightEdge = [self isLandscapeFloatingSession]
                                ? CGRectGetWidth(bounds) - safeInsets.right
                                : CGRectGetWidth(bounds);
        CGFloat x = self.floatingDockedOnRight
                         ? rightEdge - handleWidth
                         : leftEdge;
        CGFloat y = CGRectGetMinY(self.floatingContainer.frame) + 24.0;
        CGFloat minimumY = MAX(8.0, safeInsets.top + 4.0);
        CGFloat maximumY = CGRectGetHeight(bounds) - safeInsets.bottom -
                           handleHeight - 4.0;
        self.floatingHandle.frame =
            CGRectMake(x, MAX(minimumY, MIN(maximumY, y)),
                       handleWidth, handleHeight);
        // The hidden grab bar uses a stable vertical length while it remains
        // attached to the edge.
        CGFloat barLength = 44.0;
        self.floatingHandleBar.frame =
            CGRectMake(self.floatingDockedOnRight ? 36.0 : 3.0,
                       floor((handleHeight - barLength) * 0.5),
                       5.0,
                       barLength);
        return;
    }
    if ([self isLandscapeFloatingSession] && !self.floatingDocked) {
        CGFloat visibleLength = FLMLandscapeHandleVisibleLength;
        CGFloat handleWidth = 58.0;
        CGFloat handleHeight = visibleLength + 40.0;
        self.floatingHandle.frame =
            CGRectMake(CGRectGetMaxX(self.floatingContainer.frame),
                       floor(CGRectGetMidY(self.floatingContainer.frame) -
                             handleHeight * 0.5),
                       handleWidth, handleHeight);
        self.floatingHandleBar.frame =
            CGRectMake(floor((handleWidth - 5.0) * 0.5),
                       20.0, 5.0, visibleLength);
        return;
    }
    CGFloat visibleHandleWidth = containerWidth * 0.30;
    // Keep the invisible hit target outside the application card. The visible
    // bar remains centered, with exactly 20 pt of horizontal reach on each
    // side and a little more vertical forgiveness.
    CGFloat handleWidth = visibleHandleWidth + 40.0;
    CGFloat handleHeight = 58.0;
    self.floatingHandle.frame =
        CGRectMake(floor(CGRectGetMidX(self.floatingContainer.frame) -
                         handleWidth * 0.5),
                   CGRectGetMaxY(self.floatingContainer.frame),
                   handleWidth,
                   handleHeight);
    self.floatingHandleBar.frame =
        CGRectMake(20.0,
                   floor((handleHeight - 5.0) * 0.5),
                   visibleHandleWidth,
                   5.0);
}

- (void)layoutFloatingHostView {
    UIView *host = self.floatingHostView;
    if (!host || !self.floatingContainer) {
        return;
    }
    CGSize referenceSize = [self floatingSystemSceneReferenceSize];
    self.floatingHostReferenceSize = referenceSize;
    CGSize targetSize = self.floatingContainer.bounds.size;
    if (targetSize.width < 1.0 || targetSize.height < 1.0 ||
        referenceSize.width < 1.0 || referenceSize.height < 1.0) {
        return;
    }

    BOOL landscapePortraitStrip = [self isLandscapeFloatingSession] &&
                                  !self.floatingInteractiveFullscreenTransition;
    CGFloat widthScale = targetSize.width / referenceSize.width;
    CGFloat heightScale = targetSize.height / referenceSize.height;
    CGFloat hostScale = widthScale;
    CGFloat contentVisualScale = hostScale;
    CGFloat sourceStripWidth = referenceSize.width;
    NSString *policy = @"fullscreen-crop";
    if (landscapePortraitStrip) {
        CGFloat portraitStripScale =
            referenceSize.height / MAX(1.0, FLMVirtualViewportHeight);
        sourceStripWidth = FLMVirtualViewportWidth * portraitStripScale;
        hostScale = targetSize.width / MAX(1.0, sourceStripWidth);
        contentVisualScale = portraitStripScale * hostScale;
        policy = @"landscape-portrait-strip";
    } else if (self.floatingInteractiveFullscreenTransition) {
        hostScale = MAX(widthScale, heightScale);
        contentVisualScale = hostScale;
        policy = @"fullscreen-transition";
    }
    hostScale = MAX(0.05, hostScale);
    contentVisualScale = MAX(0.05, contentVisualScale);
    host.transform = CGAffineTransformIdentity;
    host.bounds = CGRectMake(0.0, 0.0, referenceSize.width, referenceSize.height);

    CGFloat cropScale = self.floatingDocked
                            ? (self.floatingDockWidth / FLMCenteredCardWidth)
                            : 1.0;
    if (landscapePortraitStrip && !self.floatingDocked) {
        cropScale = targetSize.width / FLMCenteredCardWidth;
    }
    CGFloat cropOffset = self.floatingInteractiveFullscreenTransition
        ? 0.0
        : (self.centeredCardBottomCrop - self.centeredCardTopCrop) * 0.5 * cropScale;
    CGPoint hostCenter = CGPointMake(CGRectGetMidX(self.floatingContainer.bounds),
                                     CGRectGetMidY(self.floatingContainer.bounds) + cropOffset);
    if (landscapePortraitStrip) {
        CGFloat stripCenterX = sourceStripWidth * 0.5;
        CGFloat sceneCenterX = referenceSize.width * 0.5;
        hostCenter.x += (sceneCenterX - stripCenterX) * hostScale;
    }
    host.center = hostCenter;
    host.clipsToBounds = NO;
    host.transform = CGAffineTransformMakeScale(hostScale, hostScale);
    FLMDiagnosticLog(
        @"sb content-scale policy=%@ systemSceneReference={%.4f,%.4f} sourceStripWidth=%.2f targetPhysicalCard={%.1f,%.1f} hostScale=%.6f contentScale=%.6f sceneFrameReference=system",
        policy, referenceSize.width, referenceSize.height, sourceStripWidth,
        targetSize.width, targetSize.height, hostScale, contentVisualScale);
    FLMPublishKeyboardCardGeometry(
        self.floatingKeyboardSessionGeneration,
        CGRectGetMaxY(self.floatingContainer.frame),
        contentVisualScale,
        [self isLandscapeFloatingSession] ? targetSize.width
                                          : [self effectiveCenteredCardWidth],
        [self isLandscapeFloatingSession] ? targetSize.height
                                          : [self effectiveCenteredCardHeight],
        !self.floatingWindow.hidden && !self.floatingDocked &&
            self.floatingKeyboardSessionGeneration != 0 &&
            !self.floatingSceneCardGeometryPending);
}

// Route a remote keyboard Scene to the native keyboard host without relying on
// the `updateClientSettingsWithBlock:` convenience, which FrontBoard's FBScene
// does not implement. The identity lives on the Scene's mutable settings, so
// mutate a copy and push it back the same way the App Scene frame is applied.
- (BOOL)setFloatingKeyboardPreferredHostIdentity:(id)identity
                                           scene:(id)scene {
    if (!scene ||
        ![scene respondsToSelector:
                  NSSelectorFromString(@"updateSettings:withTransitionContext:")]) {
        return NO;
    }
    id mutableSettings = nil;
    @try {
        id settings = [scene respondsToSelector:NSSelectorFromString(@"settings")]
                          ? [scene settings]
                          : nil;
        mutableSettings = [settings mutableCopy];
        if (!mutableSettings &&
            [scene respondsToSelector:NSSelectorFromString(@"mutableSettings")]) {
            mutableSettings = [scene mutableSettings];
        }
    } @catch (__unused NSException *exception) {
        mutableSettings = nil;
    }
    if (!mutableSettings) {
        return NO;
    }
    @try {
        SEL setter = NSSelectorFromString(@"setPreferredSceneHostIdentity:");
        if ([mutableSettings respondsToSelector:setter]) {
            ((void (*)(id, SEL, id))objc_msgSend)(mutableSettings, setter,
                                                 identity);
        } else {
            [mutableSettings setValue:identity
                               forKey:@"preferredSceneHostIdentity"];
        }
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            scene, NSSelectorFromString(@"updateSettings:withTransitionContext:"),
            mutableSettings, nil);
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

// Pins down what the remote keyboard Scene actually offers before any pairing
// attempt, so a failure can be attributed to the Scene instead of guessed at.
static void FLMLogKeyboardSceneDiscovery(id keyboardScene,
                                         id preferredHostIdentity) {
    if (!keyboardScene) {
        return;
    }
    static void *lastLoggedScene = NULL;
    void *currentScene = (__bridge void *)keyboardScene;
    if (lastLoggedScene == currentScene) {
        return;
    }
    lastLoggedScene = currentScene;
    BOOL hasUpdateSettings =
        [keyboardScene
            respondsToSelector:NSSelectorFromString(
                                   @"updateClientSettingsWithBlock:")];
    BOOL hasMutableSettings =
        [keyboardScene respondsToSelector:NSSelectorFromString(
                                              @"mutableSettings")] ||
        [keyboardScene
            respondsToSelector:NSSelectorFromString(@"clientSettings")];
    NSString *settingsClass = @"<none>";
    @try {
        id settings = nil;
        @try {
            settings = [keyboardScene valueForKey:@"settings"];
        } @catch (__unused NSException *exception) {
        }
        if (settings) {
            settingsClass = NSStringFromClass([settings class]);
        }
    } @catch (__unused NSException *exception) {
    }
    FLMDiagnosticLog(
        @"sb kbd-discover scene=%@ settingsClass=%@ hasUpdateSettings=%d hasMutableSettings=%d preferredHost=%p identityClass=%@",
        FLMSceneIdentifier(keyboardScene) ?: @"<none>", settingsClass,
        hasUpdateSettings, hasMutableSettings,
        (__bridge void *)preferredHostIdentity,
        preferredHostIdentity
            ? NSStringFromClass([preferredHostIdentity class])
            : @"<none>");
}

- (BOOL)propagateFloatingKeyboardScenePairing:(id)keyboardScene
                         preferredHostIdentity:(id)preferredHostIdentity
                             sessionGeneration:(NSUInteger)sessionGeneration {
    if (!keyboardScene || !preferredHostIdentity || sessionGeneration == 0 ||
        sessionGeneration != self.floatingKeyboardSessionGeneration ||
        self.floatingWindow.hidden || self.floatingDocked) {
        return NO;
    }
    FLMLogKeyboardSceneDiscovery(keyboardScene, preferredHostIdentity);
    if (self.floatingKeyboardScene == keyboardScene &&
        self.floatingKeyboardPreferredHostIdentity == preferredHostIdentity &&
        self.floatingKeyboardPairingSessionGeneration == sessionGeneration) {
        return YES;
    }

    SEL updateSelector = NSSelectorFromString(@"updateClientSettingsWithBlock:");
    if (![keyboardScene respondsToSelector:updateSelector]) {
        // `scene-pair apply=unsupported ... class=FBScene` is where 0.9.69 gave
        // up. The remote keyboard Scene then stayed unpaired, the App-side
        // input session never accepted (`adapterAccepted=0`), and a keyboard
        // that was genuinely on screen was reported hidden a moment later.
        BOOL applied = [self setFloatingKeyboardPreferredHostIdentity:
                                 preferredHostIdentity
                                                           scene:keyboardScene];
        FLMDiagnosticLog(
            @"sb kbd-pair-attempt route=mutable-settings error=%@ applied=%d session=%lu keyboardScene=%@",
            applied ? @"<none>"
                    : @"FBScene has no updateClientSettingsWithBlock:",
            applied, (unsigned long)sessionGeneration,
            FLMSceneIdentifier(keyboardScene) ?: @"<none>");
        FLMDiagnosticLog(
            @"sb scene-pair apply=%d session=%lu keyboardScene=%@ class=%@ preferredClass=%@ preferred=%p route=mutable-settings",
            applied, (unsigned long)sessionGeneration,
            FLMSceneIdentifier(keyboardScene) ?: @"<none>",
            NSStringFromClass([keyboardScene class]),
            NSStringFromClass([preferredHostIdentity class]),
            (__bridge void *)preferredHostIdentity);
        if (applied) {
            self.floatingKeyboardScene = keyboardScene;
            self.floatingKeyboardPreferredHostIdentity = preferredHostIdentity;
            self.floatingKeyboardPairingSessionGeneration = sessionGeneration;
        }
        return applied;
    }

    self.floatingKeyboardScene = keyboardScene;
    self.floatingKeyboardPreferredHostIdentity = preferredHostIdentity;
    self.floatingKeyboardPairingSessionGeneration = sessionGeneration;
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
                ((void (*)(id, SEL, id))objc_msgSend)(mutableSettings,
                                                     setter,
                                                     preferredHostIdentity);
            } else {
                [mutableSettings setValue:preferredHostIdentity
                                   forKey:@"preferredSceneHostIdentity"];
            }
            applied = YES;
        } @catch (NSException *exception) {
            failure = exception.reason ?: exception.name ?: @"exception";
        }
    };
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(keyboardScene,
                                             updateSelector,
                                             settingsBlock);
    } @catch (NSException *exception) {
        failure = exception.reason ?: exception.name ?: @"exception";
    }
    if (!applied) {
        self.floatingKeyboardScene = nil;
        self.floatingKeyboardPreferredHostIdentity = nil;
        self.floatingKeyboardPairingSessionGeneration = 0;
    }
    FLMDiagnosticLog(
        @"sb kbd-pair-attempt route=mutable-settings error=%@ applied=%d session=%lu keyboardScene=%@ preferred=%p",
        failure ?: @"<none>", applied, (unsigned long)sessionGeneration,
        FLMSceneIdentifier(keyboardScene) ?: @"<none>",
        (__bridge void *)preferredHostIdentity);
    FLMDiagnosticLog(
        @"sb scene-pair apply=%d session=%lu keyboardScene=%@ preferredClass=%@ preferred=%p failure=%@",
        applied, (unsigned long)sessionGeneration,
        FLMSceneIdentifier(keyboardScene) ?: @"<none>",
        NSStringFromClass([preferredHostIdentity class]),
        (__bridge void *)preferredHostIdentity, failure ?: @"<none>");
    return applied;
}

- (void)clearFloatingKeyboardScenePairingForSession:(NSUInteger)sessionGeneration {
    id keyboardScene = self.floatingKeyboardScene;
    BOOL owned = keyboardScene && sessionGeneration != 0 &&
                 self.floatingKeyboardPairingSessionGeneration ==
                     sessionGeneration;
    __block BOOL cleared = NO;
    __block NSString *failure = nil;
    SEL updateSelector = NSSelectorFromString(@"updateClientSettingsWithBlock:");
    if (owned && [keyboardScene respondsToSelector:updateSelector]) {
        id ownedIdentity = self.floatingKeyboardPreferredHostIdentity;
        void (^settingsBlock)(id) = ^(id mutableSettings) {
            @try {
                id currentIdentity = nil;
                @try {
                    currentIdentity =
                        [mutableSettings valueForKey:@"preferredSceneHostIdentity"];
                } @catch (__unused NSException *exception) {
                }
                if (currentIdentity && ownedIdentity &&
                    currentIdentity != ownedIdentity &&
                    ![currentIdentity isEqual:ownedIdentity]) {
                    failure = @"identity-changed";
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
    }
    if (owned && !cleared &&
        ![keyboardScene respondsToSelector:updateSelector]) {
        cleared = [self setFloatingKeyboardPreferredHostIdentity:nil
                                                          scene:keyboardScene];
    }
    FLMDiagnosticLog(
        @"sb scene-pair clear=%d owned=%d session=%lu keyboardScene=%@ failure=%@",
        cleared, owned, (unsigned long)sessionGeneration,
        FLMSceneIdentifier(keyboardScene) ?: @"<none>",
        failure ?: @"<none>");
    self.floatingKeyboardScene = nil;
    self.floatingKeyboardPreferredHostIdentity = nil;
    self.floatingKeyboardPairingSessionGeneration = 0;
}

- (void)configureKeyboardForwardingWindowGeometry:
    (FLMKeyboardForwardingWindow *)window {
    if (!window) {
        return;
    }
    // The forwarding window belongs to SpringBoard's own scene, so it keeps the
    // portrait scene bounds and carries the remote keyboard in a rotated
    // display-sized canvas, exactly like the wheel and the card. Sizing the
    // window with the physical bounds instead would tilt the keyboard.
    window.frame = FLMSpringBoardWindowBounds();
    UIView *rootView = window.rootViewController.view;
    if (!rootView) {
        return;
    }
    CGRect visualBounds = FLMVisualScreenBounds();
    UIInterfaceOrientation orientation =
        FLMBoundsAreLandscape(visualBounds)
            ? FLMLandscapeOrientationForSafeInsets(window.safeAreaInsets)
            : UIInterfaceOrientationPortrait;
    rootView.frame = window.bounds;
    FLMConfigureVisualCanvas(rootView, window, visualBounds, orientation);
}

- (void)prepareKeyboardForwardingWindowIfNeeded {
    UIWindowScene *targetWindowScene = self.floatingWindow.windowScene;
    if (!targetWindowScene) {
        targetWindowScene = FLMForegroundWindowScene();
    }
    if (!targetWindowScene) {
        return;
    }

    FLMKeyboardForwardingWindow *existingWindow =
        self.keyboardForwardingWindow;
    if (existingWindow && existingWindow.windowScene != targetWindowScene) {
        [self restoreFloatingKeyboardLayerHost];
        existingWindow.hidden = YES;
        existingWindow.rootViewController = nil;
        self.keyboardForwardingWindow = nil;
        existingWindow = nil;
    }
    if (existingWindow) {
        [self configureKeyboardForwardingWindowGeometry:existingWindow];
        existingWindow.windowLevel = self.floatingWindow.windowLevel + 1.0;
        return;
    }

    FLMKeyboardForwardingWindow *window =
        [[FLMKeyboardForwardingWindow alloc]
            initWithWindowScene:targetWindowScene];
    window.frame = FLMSpringBoardWindowBounds();
    // TrollOpen's level 45 sits above its own content hierarchy. Flyme's card
    // is itself an alert-level SpringBoard window, so the same absolute level
    // incorrectly places the native keyboard underneath it. Keep the keyboard
    // one level above the card while preserving the same Scene and responder.
    window.windowLevel = self.floatingWindow.windowLevel + 1.0;
    window.backgroundColor = [UIColor clearColor];
    window.opaque = NO;
    window.userInteractionEnabled = YES;
    window.keyboardInteractionFrame = CGRectNull;
    FLMOverlayViewController *rootController =
        [[FLMOverlayViewController alloc] init];
    rootController.view.backgroundColor = [UIColor clearColor];
    window.rootViewController = rootController;
    [self configureKeyboardForwardingWindowGeometry:window];
    SEL autorotationSelector =
        NSSelectorFromString(@"setAutorotates:forceUpdateInterfaceOrientation:");
    if ([window respondsToSelector:autorotationSelector]) {
        ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(window,
                                                     autorotationSelector,
                                                     NO,
                                                     NO);
    }
    window.hidden = YES;
    self.keyboardForwardingWindow = window;
}

- (void)keyboardLayerHostView:(UIView *)hostView
            didUpdateForScene:(id)scene
            sessionGeneration:(NSUInteger)sessionGeneration {
    FLMDiagnosticLog(
        @"sb host-update enter host=%p session=%lu current=%lu scene=%@ target=%@ hidden=%d docked=%d launch=%lu",
        (__bridge void *)hostView, (unsigned long)sessionGeneration,
        (unsigned long)self.floatingKeyboardSessionGeneration,
        FLMSceneIdentifier(scene) ?: @"<none>",
        FLMSceneIdentifier(self.floatingScene) ?: @"<none>",
        self.floatingWindow.hidden, self.floatingDocked,
        (unsigned long)self.floatingLaunchState);
    if (!hostView || sessionGeneration == 0 ||
        sessionGeneration != self.floatingKeyboardSessionGeneration ||
        self.floatingWindow.hidden || self.floatingDocked ||
        !self.floatingScene || self.floatingIdentifier.length == 0 ||
        self.floatingLaunchState == FLMFloatingLaunchStateClosing) {
        FLMDiagnosticLog(@"sb host-update rejected=inactive");
        return;
    }
    if (![self floatingApplicationHostReadyForKeyboardRoute]) {
        self.floatingKeyboardDeferredHostView = hostView;
        self.floatingKeyboardDeferredScene = scene;
        self.floatingKeyboardDeferredSessionGeneration = sessionGeneration;
        FLMDiagnosticLog(
            @"sb host-deferred waiting=application-host session=%lu host=%p scene=%@ contentViewportPending=%d contentViewportCommitted=%d launch=%lu",
            (unsigned long)sessionGeneration, (__bridge void *)hostView,
            FLMSceneIdentifier(scene) ?: @"<none>",
            self.floatingSceneCardGeometryPending,
            self.floatingSceneCardGeometryCommitted,
            (unsigned long)self.floatingLaunchState);
        return;
    }

    id owningScene = nil;
    id keyboardScene = nil;
    id preferredHostIdentity = nil;
    BOOL paired = NO;
    @try {
        owningScene = [hostView valueForKey:@"_owningScene"];
        keyboardScene = [hostView valueForKey:@"_keyboardScene"];
        preferredHostIdentity =
            [hostView valueForKey:@"_keyboardPreferredHostIdentity"];
        id pairedValue = [hostView valueForKey:@"_isPaired"];
        paired = [pairedValue respondsToSelector:@selector(boolValue)] &&
                 [pairedValue boolValue];
    } @catch (__unused NSException *exception) {
    }
    // A native keyboard host is not safe to reparent until UIKit has supplied
    // the keyboard Scene and its preferred host identity. In 0.8.59 two host
    // objects arrived for one session; accepting both made them alternately
    // steal the forwarding window and occasionally exposed the keyboard in
    // the card's own hierarchy.
    if (!paired || !keyboardScene || !preferredHostIdentity) {
        if (hostView == self.floatingKeyboardLayerHostView) {
            FLMDiagnosticLog(
                @"sb host-update ignored=unpaired-current host=%p session=%lu",
                (__bridge void *)hostView,
                (unsigned long)sessionGeneration);
        } else {
            self.floatingKeyboardDeferredHostView = hostView;
            self.floatingKeyboardDeferredScene = scene;
            self.floatingKeyboardDeferredSessionGeneration = sessionGeneration;
            FLMDiagnosticLog(
                @"sb host-deferred waiting=pairing host=%p session=%lu keyboardScene=%@ preferred=%p",
                (__bridge void *)hostView,
                (unsigned long)sessionGeneration,
                FLMSceneIdentifier(keyboardScene) ?: @"<none>",
                (__bridge void *)preferredHostIdentity);
        }
        return;
    }
    if (self.floatingKeyboardLayerHostView &&
        hostView != self.floatingKeyboardLayerHostView &&
        self.floatingKeyboardHostSessionGeneration == sessionGeneration) {
        // Keep one native host for the lifetime of a keyboard session. The
        // alternate host is a UIKit compositor callback, not a new route.
        FLMDiagnosticLog(
            @"sb host-update rejected=alternate-host active=%p incoming=%p session=%lu",
            (__bridge void *)self.floatingKeyboardLayerHostView,
            (__bridge void *)hostView,
            (unsigned long)sessionGeneration);
        return;
    }
    NSString *targetIdentifier = FLMSceneIdentifier(self.floatingScene);
    NSString *owningIdentifier = FLMSceneIdentifier(owningScene);
    NSString *updatedIdentifier = FLMSceneIdentifier(scene);
    FLMDiagnosticLog(
        @"sb host-native owner=%@ keyboardScene=%@ preferredHostClass=%@ preferredHost=%p paired=%d",
        owningIdentifier ?: @"<none>",
        FLMSceneIdentifier(keyboardScene) ?: @"<none>",
        preferredHostIdentity
            ? NSStringFromClass([preferredHostIdentity class])
            : @"<none>",
        (__bridge void *)preferredHostIdentity, paired);
    BOOL matches = owningScene == self.floatingScene || scene == self.floatingScene;
    if (!matches && targetIdentifier.length > 0) {
        matches = [targetIdentifier isEqualToString:owningIdentifier] ||
                  [targetIdentifier isEqualToString:updatedIdentifier];
    }
    if (!matches) {
        FLMDiagnosticLog(
            @"sb host-update rejected=scene-mismatch target=%@ owner=%@ updated=%@",
            targetIdentifier ?: @"<none>", owningIdentifier ?: @"<none>",
            updatedIdentifier ?: @"<none>");
        return;
    }

    if (paired && keyboardScene && preferredHostIdentity) {
        [self propagateFloatingKeyboardScenePairing:keyboardScene
                              preferredHostIdentity:preferredHostIdentity
                                  sessionGeneration:sessionGeneration];
    }

    [self prepareKeyboardForwardingWindowIfNeeded];
    UIView *forwardingRoot =
        self.keyboardForwardingWindow.rootViewController.view;
    if (!forwardingRoot) {
        FLMDiagnosticLog(@"sb host-update rejected=no-forwarding-root");
        return;
    }

    if (hostView != self.floatingKeyboardLayerHostView ||
        self.floatingKeyboardHostSessionGeneration != sessionGeneration) {
        if (self.floatingKeyboardLayerHostView) {
            if (self.floatingKeyboardHostSessionGeneration == sessionGeneration) {
                [self restoreFloatingKeyboardLayerHost];
            } else {
                [self discardFloatingKeyboardLayerHost];
            }
        }
        UIView *originalSuperview = hostView.superview;
        self.floatingKeyboardOriginalSuperview = originalSuperview;
        self.floatingKeyboardOriginalSubviewIndex =
            originalSuperview ? [originalSuperview.subviews indexOfObject:hostView]
                              : NSNotFound;
        self.floatingKeyboardOriginalFrame = hostView.frame;
        self.floatingKeyboardOriginalTransform = hostView.transform;
        self.floatingKeyboardOriginalAutoresizingMask = hostView.autoresizingMask;
        self.floatingKeyboardOriginalTranslatesAutoresizingMask =
            hostView.translatesAutoresizingMaskIntoConstraints;
        self.floatingKeyboardLayerHostView = hostView;
        self.floatingKeyboardHostSessionGeneration = sessionGeneration;
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
        if (!CGAffineTransformIsIdentity(hostView.transform))
            hostView.transform = CGAffineTransformIdentity;
        if (!CGRectEqualToRect(hostView.frame, forwardingRoot.bounds))
            hostView.frame = forwardingRoot.bounds;
    }
    // UIKit already marks real client-setting changes dirty. Do not force a
    // new layout pass merely because another identical host callback arrived.
    [hostView layoutIfNeeded];
    if (self.floatingKeyboardVisible) {
        [self.keyboardForwardingWindow makeKeyAndVisible];
    } else {
        // Keep the forwarding window completely hidden while the keyboard is
        // not visible. The native host can remain attached for the next
        // keyboard frame without becoming an accidental on-card keyboard.
        self.keyboardForwardingWindow.hidden = YES;
    }
    FLMDiagnosticLog(
        @"sb host-update paired host=%p session=%lu visible=%d hostFrame=%@ windowLevel=%.1f key=%d",
        (__bridge void *)hostView, (unsigned long)sessionGeneration,
        self.floatingKeyboardVisible, NSStringFromCGRect(hostView.frame),
        self.keyboardForwardingWindow.windowLevel,
        self.keyboardForwardingWindow.isKeyWindow);
    [self flushDeferredFloatingKeyboardHostIfReady];
    [self flushPendingFloatingKeyboardFrameIfReady];
}

- (void)deactivateKeyboardForwardingWindow {
    FLMKeyboardForwardingWindow *window = self.keyboardForwardingWindow;
    BOOL wasKey = window.isKeyWindow;
    window.keyboardInteractionFrame = CGRectNull;
    if (wasKey && !self.floatingWindow.hidden &&
        !self.floatingDocked) {
        [self.floatingWindow makeKeyWindow];
    }
    window.hidden = YES;
    FLMDiagnosticLog(
        @"sb forwarding-deactivate wasKey=%d cardHidden=%d docked=%d",
        wasKey, self.floatingWindow.hidden, self.floatingDocked);
}

- (void)restoreFloatingKeyboardLayerHost {
    UIView *hostView = self.floatingKeyboardLayerHostView;
    UIView *originalSuperview = self.floatingKeyboardOriginalSuperview;
    if (hostView) {
        @try {
            [hostView removeFromSuperview];
            hostView.transform = self.floatingKeyboardOriginalTransform;
            hostView.frame = self.floatingKeyboardOriginalFrame;
            hostView.autoresizingMask =
                self.floatingKeyboardOriginalAutoresizingMask;
            hostView.translatesAutoresizingMaskIntoConstraints =
                self.floatingKeyboardOriginalTranslatesAutoresizingMask;
            if (originalSuperview) {
                NSInteger index = self.floatingKeyboardOriginalSubviewIndex;
                if (index >= 0 &&
                    index <= (NSInteger)originalSuperview.subviews.count) {
                    [originalSuperview insertSubview:hostView
                                              atIndex:(NSUInteger)index];
                } else {
                    [originalSuperview addSubview:hostView];
                }
            }
        } @catch (__unused NSException *exception) {
        }
    }
    self.floatingKeyboardLayerHostView = nil;
    self.floatingKeyboardOriginalSuperview = nil;
    self.floatingKeyboardOriginalSubviewIndex = NSNotFound;
    self.floatingKeyboardHostSessionGeneration = 0;
    self.floatingKeyboardDeferredHostView = nil;
    self.floatingKeyboardDeferredScene = nil;
    self.floatingKeyboardDeferredSessionGeneration = 0;
    [self deactivateKeyboardForwardingWindow];
    FLMDiagnosticLog(
        @"sb host-restore host=%p originalSuperview=%p",
        (__bridge void *)hostView, (__bridge void *)originalSuperview);
}

- (void)discardFloatingKeyboardLayerHost {
    UIView *hostView = self.floatingKeyboardLayerHostView;
    @try {
        [hostView removeFromSuperview];
    } @catch (__unused NSException *exception) {
    }
    self.floatingKeyboardLayerHostView = nil;
    self.floatingKeyboardOriginalSuperview = nil;
    self.floatingKeyboardOriginalSubviewIndex = NSNotFound;
    self.floatingKeyboardHostSessionGeneration = 0;
    self.floatingKeyboardDeferredHostView = nil;
    self.floatingKeyboardDeferredScene = nil;
    self.floatingKeyboardDeferredSessionGeneration = 0;
    [self deactivateKeyboardForwardingWindow];
    FLMDiagnosticLog(@"sb host-discard host=%p",
                             (__bridge void *)hostView);
}

- (BOOL)floatingApplicationHostReadyForKeyboardRoute {
    if (self.floatingWindow.hidden || self.floatingDocked ||
        self.floatingKeyboardSessionGeneration == 0 ||
        !self.floatingIdentifier.length || !self.floatingScene ||
        !self.floatingHostView ||
        self.floatingLaunchState != FLMFloatingLaunchStateAttached) {
        return NO;
    }
    if (self.floatingInteractiveFullscreenTransition) {
        return YES;
    }
    if (self.floatingSceneCardGeometryPending) {
        return NO;
    }
    if (self.floatingSceneUsesCardGeometry &&
        !self.floatingSceneCardGeometryCommitted) {
        return NO;
    }
    return YES;
}

- (void)flushDeferredFloatingKeyboardHostIfReady {
    UIView *deferredHost = self.floatingKeyboardDeferredHostView;
    NSUInteger deferredSession =
        self.floatingKeyboardDeferredSessionGeneration;
    id deferredScene = self.floatingKeyboardDeferredScene;
    if (!deferredHost) {
        self.floatingKeyboardDeferredScene = nil;
        self.floatingKeyboardDeferredSessionGeneration = 0;
        return;
    }
    if (deferredSession == 0 ||
        deferredSession != self.floatingKeyboardSessionGeneration) {
        FLMDiagnosticLog(
            @"sb host-deferred discard=stale pendingSession=%lu current=%lu host=%p",
            (unsigned long)deferredSession,
            (unsigned long)self.floatingKeyboardSessionGeneration,
            (__bridge void *)deferredHost);
        self.floatingKeyboardDeferredHostView = nil;
        self.floatingKeyboardDeferredScene = nil;
        self.floatingKeyboardDeferredSessionGeneration = 0;
        return;
    }
    if (![self floatingApplicationHostReadyForKeyboardRoute]) {
        return;
    }
    self.floatingKeyboardDeferredHostView = nil;
    self.floatingKeyboardDeferredScene = nil;
    self.floatingKeyboardDeferredSessionGeneration = 0;
    FLMDiagnosticLog(
        @"sb host-deferred replay=1 session=%lu host=%p scene=%@",
        (unsigned long)deferredSession, (__bridge void *)deferredHost,
        FLMSceneIdentifier(deferredScene) ?: @"<none>");
    [self keyboardLayerHostView:deferredHost
              didUpdateForScene:deferredScene
              sessionGeneration:deferredSession];
}

- (BOOL)floatingKeyboardPresentationReady {
    if (![self floatingApplicationHostReadyForKeyboardRoute] ||
        !self.floatingKeyboardLayerHostView ||
        self.floatingKeyboardHostSessionGeneration !=
            self.floatingKeyboardSessionGeneration) {
        return NO;
    }
    return YES;
}

- (void)flushPendingFloatingKeyboardFrameIfReady {
    if (!self.floatingKeyboardFramePending) {
        return;
    }
    NSUInteger pendingSession = self.floatingKeyboardPendingSessionGeneration;
    if (pendingSession == 0 ||
        pendingSession != self.floatingKeyboardSessionGeneration) {
        FLMDiagnosticLog(
            @"sb frame-deferred discard=stale pendingSession=%lu current=%lu",
            (unsigned long)pendingSession,
            (unsigned long)self.floatingKeyboardSessionGeneration);
        self.floatingKeyboardFramePending = NO;
        self.floatingKeyboardPendingFrame = CGRectNull;
        self.floatingKeyboardPendingSessionGeneration = 0;
        return;
    }
    if (![self floatingKeyboardPresentationReady]) {
        return;
    }
    CGRect pendingFrame = self.floatingKeyboardPendingFrame;
    self.floatingKeyboardFramePending = NO;
    self.floatingKeyboardPendingFrame = CGRectNull;
    self.floatingKeyboardPendingSessionGeneration = 0;
    FLMDiagnosticLog(
        @"sb frame-deferred replay=1 session=%lu frame=%@ host=%p contentViewportCommitted=%d",
        (unsigned long)pendingSession, NSStringFromCGRect(pendingFrame),
        (__bridge void *)self.floatingKeyboardLayerHostView,
        self.floatingSceneCardGeometryCommitted);
    [self applyKeyboardFrame:pendingFrame visible:YES];
}

- (void)applyKeyboardFrame:(CGRect)frame visible:(BOOL)visible {
    if (self.floatingWindow.hidden || self.floatingDocked) {
        visible = NO;
    }
    if (visible &&
        (self.floatingKeyboardSessionGeneration == 0 ||
         !self.floatingScene)) {
        FLMDiagnosticLog(
            @"sb frame-apply rejected=inactive-session session=%lu scene=%@ frame=%@",
            (unsigned long)self.floatingKeyboardSessionGeneration,
            FLMSceneIdentifier(self.floatingScene) ?: @"<none>",
            NSStringFromCGRect(frame));
        return;
    }
    if (visible && ![self floatingKeyboardPresentationReady]) {
        self.floatingKeyboardFramePending = YES;
        self.floatingKeyboardPendingFrame = frame;
        self.floatingKeyboardPendingSessionGeneration =
            self.floatingKeyboardSessionGeneration;
        FLMDiagnosticLog(
            @"sb frame-deferred waiting=scene-host session=%lu frame=%@ appHost=%p keyboardHost=%p contentViewportPending=%d contentViewportCommitted=%d launch=%lu",
            (unsigned long)self.floatingKeyboardSessionGeneration,
            NSStringFromCGRect(frame), (__bridge void *)self.floatingHostView,
            (__bridge void *)self.floatingKeyboardLayerHostView,
            self.floatingSceneCardGeometryPending,
            self.floatingSceneCardGeometryCommitted,
            (unsigned long)self.floatingLaunchState);
        return;
    }
    if (!visible && !self.floatingKeyboardVisible &&
        !self.floatingKeyboardInteractionSessionActive &&
        ![self floatingKeyboardPresentationReady]) {
        if (self.floatingKeyboardFramePending) {
            FLMDiagnosticLog(
                @"sb frame-deferred hide=1 pendingSession=%lu current=%lu",
                (unsigned long)self.floatingKeyboardPendingSessionGeneration,
                (unsigned long)self.floatingKeyboardSessionGeneration);
        }
        self.floatingKeyboardFramePending = NO;
        self.floatingKeyboardPendingFrame = CGRectNull;
        self.floatingKeyboardPendingSessionGeneration = 0;
        return;
    }
    if (!visible && ![self floatingKeyboardPresentationReady] &&
        !self.floatingKeyboardVisible) {
        self.floatingKeyboardFramePending = NO;
        self.floatingKeyboardPendingFrame = CGRectNull;
        self.floatingKeyboardPendingSessionGeneration = 0;
        return;
    }
    CGRect bounds = [self floatingLayoutView].bounds;
    FLMDiagnosticLog(
        @"sb frame-apply inputVisible=%d inputFrame=%@ cardHidden=%d docked=%d session=%lu host=%p",
        visible, NSStringFromCGRect(frame), self.floatingWindow.hidden,
        self.floatingDocked,
        (unsigned long)self.floatingKeyboardSessionGeneration,
        (__bridge void *)self.floatingKeyboardLayerHostView);
    if (visible) {
        pid_t adapterPID = 0;
        BOOL adapterAccepted = FLMLogKeyboardAdapterHandshake(
            @"frame-visible", self.floatingIdentifier, &adapterPID);
        FLMDiagnosticLog(
            @"sb keyboard-relation target=%@ frontmost=%@ appScene=%@ appSceneClass=%@ keyboardScene=%@ keyboardSceneClass=%@ preferredHostClass=%@ preferredHost=%p nativeHostClass=%@ nativeHost=%p adapterAccepted=%d adapterPID=%d sbPID=%d",
            self.floatingIdentifier ?: @"<none>",
            FLMFrontmostApplicationIdentifier() ?: @"<none>",
            FLMSceneIdentifier(self.floatingScene) ?: @"<none>",
            self.floatingScene
                ? NSStringFromClass([self.floatingScene class])
                : @"<none>",
            FLMSceneIdentifier(self.floatingKeyboardScene) ?: @"<none>",
            self.floatingKeyboardScene
                ? NSStringFromClass([self.floatingKeyboardScene class])
                : @"<none>",
            self.floatingKeyboardPreferredHostIdentity
                ? NSStringFromClass(
                      [self.floatingKeyboardPreferredHostIdentity class])
                : @"<none>",
            (__bridge void *)self.floatingKeyboardPreferredHostIdentity,
            self.floatingKeyboardLayerHostView
                ? NSStringFromClass([self.floatingKeyboardLayerHostView class])
                : @"<none>",
            (__bridge void *)self.floatingKeyboardLayerHostView,
            adapterAccepted, adapterPID, getpid());
        [self beginFloatingKeyboardInteractionSession];
        BOOL landscape = [self isLandscapeFloatingSession];
        CGFloat reportedHeight = CGRectGetHeight(frame);
        CGFloat height = reportedHeight;
        if (landscape) {
            frame = CGRectIntersection(frame, bounds);
            if (CGRectIsNull(frame) || CGRectIsEmpty(frame)) {
                return;
            }
            height = CGRectGetHeight(frame);
            self.floatingKeyboardMaximumVisibleHeight = height;
        } else {
            if (reportedHeight < 180.0) {
                reportedHeight = self.lastPortraitKeyboardHeight;
            } else {
                self.lastPortraitKeyboardHeight = reportedHeight;
            }
            reportedHeight =
                MIN(CGRectGetHeight(bounds), MAX(216.0, reportedHeight));
            self.floatingKeyboardMaximumVisibleHeight =
                MAX(self.floatingKeyboardMaximumVisibleHeight, reportedHeight);
            height = self.floatingKeyboardMaximumVisibleHeight;
            frame = CGRectMake(0.0,
                               CGRectGetHeight(bounds) - height,
                               CGRectGetWidth(bounds),
                               height);
        }
        self.floatingKeyboardVisible = YES;
        self.floatingKeyboardFrame = frame;
        CGRect interactionFrame = [self floatingKeyboardInteractionFrame];
        self.floatingBackdropTap.additionalProtectedFrame = interactionFrame;
        ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame =
            interactionFrame;
        self.keyboardForwardingWindow.windowLevel =
            self.floatingWindow.windowLevel + 1.0;
        self.keyboardForwardingWindow.keyboardInteractionFrame = interactionFrame;
        // The application Scene frame remains immutable. UIKit in the target
        // application consumes this logical overlap through
        // _UIRemoteKeyboards and performs its own responder avoidance.
        //
        // In the landscape route the keyboard is a full-width system keyboard
        // sitting in front of the card, and the requirement is explicitly that
        // the target App handles its own input-field avoidance. Publishing an
        // overlap here double-counted it: the physical keyboard covers the
        // whole portrait-proportion card, so the value saturated at
        // `referenceSize.height * 0.72` (607.68 of the App's 844 logical
        // points) and shifted the App's input field out of its own card.
        BOOL landscapeKeyboard = [self isLandscapeFloatingSession];
        CGFloat avoidanceHeight =
            landscapeKeyboard
                ? 0.0
                : [self floatingKeyboardAvoidanceHeightForFrame:interactionFrame];
        FLMPublishKeyboardAvoidance(self.floatingKeyboardSessionGeneration,
                                    avoidanceHeight,
                                    YES);
        if (self.floatingKeyboardLayerHostView) {
            [self.keyboardForwardingWindow makeKeyAndVisible];
        }
        FLMDiagnosticLog(
            @"sb frame-visible reportedHeight=%.2f stableHeight=%.2f normalized=%@ interaction=%@ avoidance=%.2f forwardingKey=%d level=%.1f cardLevel=%.1f",
            reportedHeight, height,
            NSStringFromCGRect(frame), NSStringFromCGRect(interactionFrame),
            avoidanceHeight,
            self.keyboardForwardingWindow.isKeyWindow,
            self.keyboardForwardingWindow.windowLevel,
            self.floatingWindow.windowLevel);
        return;
    }
    BOOL wasKeyboardInteraction =
        self.floatingKeyboardVisible || self.floatingKeyboardInteractionSessionActive;
    self.floatingKeyboardVisible = NO;
    self.floatingKeyboardFrame = CGRectNull;
    [self deactivateKeyboardForwardingWindow];
    FLMPublishKeyboardAvoidance(self.floatingKeyboardSessionGeneration,
                                0.0,
                                NO);
    // Closing behavior is tied to the touch's immutable begin-domain snapshot,
    // not a guessed post-dismissal time window. A touch that began in the
    // keyboard remains a keyboard-only touch even after this state is cleared;
    // the next genuine outside touch is immediately eligible to close.
    self.floatingBackdropTap.additionalProtectedFrame = CGRectNull;
    ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame =
        CGRectNull;
    [self endFloatingKeyboardInteractionSession];
    FLMDiagnosticLog(
        @"sb frame-hidden protection=cleared policy=touch-origin centered-preserved=%d previousInteraction=%d session=%lu hidden=%d docked=%d",
        !self.floatingWindow.hidden && !self.floatingDocked,
        wasKeyboardInteraction,
        (unsigned long)self.floatingKeyboardSessionGeneration,
        self.floatingWindow.hidden, self.floatingDocked);
}

- (void)endFloatingKeyboardSession {
    NSUInteger endingSession = self.floatingKeyboardSessionGeneration;
    UIView *endingHost = self.floatingKeyboardLayerHostView;
    FLMDiagnosticLog(
        @"sb session-end begin session=%lu visible=%d interaction=%d host=%p app=%@ scene=%@",
        (unsigned long)endingSession, self.floatingKeyboardVisible,
        self.floatingKeyboardInteractionSessionActive,
        (__bridge void *)self.floatingKeyboardLayerHostView,
        self.floatingIdentifier ?: @"<none>",
        FLMSceneIdentifier(self.floatingScene) ?: @"<none>");
    self.floatingKeyboardFramePending = NO;
    self.floatingKeyboardPendingFrame = CGRectNull;
    self.floatingKeyboardPendingSessionGeneration = 0;
    self.floatingKeyboardDeferredHostView = nil;
    self.floatingKeyboardDeferredScene = nil;
    self.floatingKeyboardDeferredSessionGeneration = 0;
    if (endingSession == 0) {
        [self deactivateKeyboardForwardingWindow];
        [self endFloatingKeyboardInteractionSession];
        self.floatingKeyboardMaximumVisibleHeight = 0.0;
        return;
    }
    [self.floatingHostView endEditing:YES];
    FLMPublishKeyboardAvoidance(endingSession, 0.0, NO);
    FLMPublishKeyboardCardGeometry(endingSession, 0.0, 0.0, 0.0, 0.0, NO);
    [self clearFloatingKeyboardScenePairingForSession:endingSession];
    self.floatingKeyboardSessionGeneration = 0;
    FLMPublishKeyboardState(nil, nil, 0);
    self.floatingKeyboardVisible = NO;
    self.floatingKeyboardFrame = CGRectNull;
    self.floatingKeyboardMaximumVisibleHeight = 0.0;
    self.floatingBackdropTap.additionalProtectedFrame = CGRectNull;
    ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame =
        CGRectNull;
    [self deactivateKeyboardForwardingWindow];
    [self endFloatingKeyboardInteractionSession];
    FLMDiagnosticLog(
        @"sb session-end route-cleared session=%lu host=%p",
        (unsigned long)endingSession, (__bridge void *)endingHost);

    // The keyboard Scene's preferred host identity was cleared above. Keep the
    // native host hidden for one UIKit transaction so a third-party keyboard
    // can finish that unpair before its remote surface is discarded.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.24 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.floatingKeyboardSessionGeneration == 0 && endingHost &&
            self.floatingKeyboardLayerHostView == endingHost &&
            self.floatingKeyboardHostSessionGeneration == endingSession) {
            FLMDiagnosticLog(
                @"sb session-end host-discard session=%lu host=%p",
                (unsigned long)endingSession, (__bridge void *)endingHost);
            [self discardFloatingKeyboardLayerHost];
        }
    });
}

- (CGRect)floatingKeyboardInteractionFrame {
    if (!self.floatingKeyboardInteractionSessionActive) {
        return CGRectNull;
    }
    CGRect bounds = [self floatingLayoutView].bounds;
    if ([self isLandscapeFloatingSession]) {
        return self.floatingKeyboardVisible
            ? CGRectIntersection(bounds, self.floatingKeyboardFrame)
            : CGRectNull;
    }
    CGRect keyboardFrame = CGRectNull;
    if (self.floatingKeyboardVisible &&
        !CGRectIsNull(self.floatingKeyboardFrame) &&
        CGRectGetWidth(self.floatingKeyboardFrame) > 1.0 &&
        CGRectGetHeight(self.floatingKeyboardFrame) > 1.0) {
        keyboardFrame = self.floatingKeyboardFrame;
    } else {
        CGFloat height = MIN(CGRectGetHeight(bounds),
                             MAX(216.0, self.lastPortraitKeyboardHeight));
        keyboardFrame = CGRectMake(0.0,
                                   CGRectGetHeight(bounds) - height,
                                   CGRectGetWidth(bounds),
                                   height);
    }
    // Third-party keyboard toolbars can own controls above UIKit's reported
    // keyboard end frame. The captured target-app keyboard collapse touch began
    // 26 pt above that frame. Protect a bounded 56 pt accessory band so the
    // physical touch remains in the keyboard domain from begin through end.
    CGFloat top = MAX(CGRectGetMinY(bounds),
                      CGRectGetMinY(keyboardFrame) -
                          FLMKeyboardAccessoryProtectionHeight);
    return CGRectMake(CGRectGetMinX(bounds),
                      top,
                      CGRectGetWidth(bounds),
                      CGRectGetMaxY(bounds) - top);
}

- (BOOL)pointIsInsideFloatingInteractionDomain:(CGPoint)point {
    CGRect contentFrame = CGRectInset(self.floatingContainer.frame, -2.0, -2.0);
    CGRect handleFrame = CGRectInset(self.floatingHandle.frame, -22.0, -20.0);
    if (CGRectContainsPoint(contentFrame, point) ||
        (!self.floatingHandle.hidden && CGRectContainsPoint(handleFrame, point))) {
        return YES;
    }
    CGRect keyboardFrame = [self floatingKeyboardInteractionFrame];
    return !CGRectIsNull(keyboardFrame) &&
           CGRectContainsPoint(keyboardFrame, point);
}

- (CGFloat)floatingKeyboardAvoidanceHeightForFrame:(CGRect)frame {
    if (CGRectIsNull(frame) || CGRectGetHeight(frame) <= 1.0) {
        return 0.0;
    }
    CGRect contentFrame = self.floatingContainer.frame;
    CGFloat physicalOverlap =
        MAX(0.0, CGRectGetMaxY(contentFrame) - CGRectGetMinY(frame));
    if (physicalOverlap <= 1.0) {
        return 0.0;
    }
    CGAffineTransform transform = self.floatingHostView.transform;
    // Keyboard avoidance is vertical geometry. With an independent X/Y card
    // mapping, use the transform's Y scale rather than applying the
    // horizontal scale to vertical input movement.
    CGFloat visualScale = hypot(transform.b, transform.d);
    if (visualScale <= 0.05) {
        CGSize referenceSize = [self floatingSceneReferenceSize];
        visualScale = referenceSize.width > 1.0
                          ? CGRectGetHeight(contentFrame) / referenceSize.height
                          : 1.0;
    }
    visualScale = MAX(0.05, visualScale);
    CGSize referenceSize = [self floatingSceneReferenceSize];
    CGFloat logicalGap = 8.0 / visualScale;
    CGFloat logicalAvoidance = physicalOverlap / visualScale + logicalGap;
    return referenceSize.height > 1.0
               ? MIN(referenceSize.height * 0.72, logicalAvoidance)
               : logicalAvoidance;
}

- (void)beginFloatingKeyboardInteractionSession {
    if (self.floatingWindow.hidden || self.floatingDocked) {
        return;
    }
    if (self.floatingKeyboardInteractionSessionActive) {
        self.floatingBackdropTap.additionalProtectedFrame =
            [self floatingKeyboardInteractionFrame];
        return;
    }
    self.floatingKeyboardInteractionSessionActive = YES;
    self.floatingKeyboardInteractionGeneration += 1;
    NSUInteger generation = self.floatingKeyboardInteractionGeneration;
    CGRect protectedFrame = [self floatingKeyboardInteractionFrame];
    self.floatingBackdropTap.additionalProtectedFrame = protectedFrame;

    // A responder can fail to present a keyboard. Do not leave the lower screen
    // permanently protected if no keyboard frame arrives for this session.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation == self.floatingKeyboardInteractionGeneration &&
            self.floatingKeyboardInteractionSessionActive &&
            !self.floatingKeyboardVisible) {
            [self applyKeyboardFrame:CGRectNull visible:NO];
        }
    });
}

- (void)endFloatingKeyboardInteractionSession {
    self.floatingKeyboardInteractionGeneration += 1;
    self.floatingKeyboardInteractionSessionActive = NO;
}

// A keyboard notification frame can arrive in the target App's portrait Scene
// contract (390x844, the size `floatingSystemSceneReferenceSize` reports for a
// landscape session) while the locked display box is 844x390. Convert those
// frames with the same corner mapping the card uses; leave frames that already
// match the display box alone. The reference box is the one this session
// locked in when the card opened, never a live re-read: `FLMVisualScreenBounds`
// can flip back to portrait mid-transaction, and judging a landscape frame
// against a portrait box reports a keyboard sitting entirely below the screen
// as visible — the flicker-then-vanish the device log shows.
- (CGRect)floatingSessionVisualBounds {
    CGSize systemSize = self.floatingLandscapeSystemSize;
    if (self.floatingLandscapeSession && systemSize.width > 1.0 &&
        systemSize.height > 1.0) {
        return CGRectMake(0.0, 0.0, systemSize.width, systemSize.height);
    }
    return FLMVisualScreenBounds();
}

- (CGRect)landscapeKeyboardFrameFromScreenFrame:(CGRect)screenFrame
                                         bounds:(CGRect)bounds {
    CGRect direct = CGRectStandardize(screenFrame);
    if (![self isLandscapeFloatingSession] || CGRectIsEmpty(bounds)) {
        return direct;
    }
    CGSize appReference = [self floatingSystemSceneReferenceSize];
    CGFloat appTolerance = MAX(3.0, appReference.width * 0.06);
    BOOL matchesAppReference =
        appReference.width > 1.0 && appReference.height > 1.0 &&
        fabs(CGRectGetWidth(direct) - appReference.width) <= appTolerance;
    if (!matchesAppReference) {
        return direct;
    }
    CGRect appBounds = CGRectMake(0.0, 0.0, appReference.width,
                                  appReference.height);
    UIInterfaceOrientation orientation =
        self.floatingLandscapeInterfaceOrientation;
    if (!UIInterfaceOrientationIsLandscape(orientation)) {
        orientation =
            FLMLandscapeOrientationForSafeInsets(
                self.floatingLandscapeSafeInsets);
    }
    CGPoint corners[4] = {
        CGPointMake(CGRectGetMinX(direct), CGRectGetMinY(direct)),
        CGPointMake(CGRectGetMaxX(direct), CGRectGetMinY(direct)),
        CGPointMake(CGRectGetMinX(direct), CGRectGetMaxY(direct)),
        CGPointMake(CGRectGetMaxX(direct), CGRectGetMaxY(direct)),
    };
    CGRect converted = CGRectNull;
    for (NSUInteger index = 0; index < 4; index++) {
        CGPoint visualPoint =
            FLMVisualPointFromRootPoint(corners[index], appBounds, bounds,
                                        orientation);
        CGRect cornerRect =
            CGRectMake(visualPoint.x, visualPoint.y, 0.0, 0.0);
        converted = CGRectIsNull(converted)
                        ? cornerRect
                        : CGRectUnion(converted, cornerRect);
    }
    return CGRectIsNull(converted) ? direct : converted;
}

- (void)keyboardFrameWillChange:(NSNotification *)notification {
    NSValue *frameValue = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (![frameValue isKindOfClass:[NSValue class]]) {
        return;
    }
    CGRect frame = frameValue.CGRectValue;
    CGRect bounds = [self floatingSessionVisualBounds];
    CGRect converted =
        [self landscapeKeyboardFrameFromScreenFrame:frame bounds:bounds];
    BOOL visible = CGRectIntersectsRect(bounds, converted) &&
                   CGRectGetMinY(converted) < CGRectGetHeight(bounds) - 1.0;
    FLMDiagnosticLog(
        @"sb notification=%@ rawFrame=%@ convertedFrame=%@ bounds=%@ computedVisible=%d",
        notification.name, NSStringFromCGRect(frame),
        NSStringFromCGRect(converted), NSStringFromCGRect(bounds), visible);
    if (visible) {
        [self applyKeyboardFrame:converted visible:YES];
    } else {
        // WillChangeFrame marks the beginning of the physical dismissal
        // animation. Keep the stable avoidance and touch envelope until
        // UIKeyboardDidHide confirms that the keyboard is actually gone.
        FLMDiagnosticLog(
            @"sb frame-hidden pending-confirmation stableHeight=%.2f avoidance-retained=1",
            self.floatingKeyboardMaximumVisibleHeight);
    }
}

- (void)keyboardDidHide:(NSNotification *)notification {
    FLMDiagnosticLog(@"sb notification=%@ did-hide",
                             notification.name);
    // Record what the session looked like when the hide arrived. A hide that
    // lands right after a frame the coordinator accepted is the flicker path;
    // a hide with no frame at all is a different failure.
    FLMDiagnosticLog(
        @"sb kbd-hide-cause notification=%@ pendingFrame=%@ visible=%d host=%p session=%lu",
        notification.name,
        CGRectIsNull(self.floatingKeyboardFrame)
            ? @"<null>"
            : NSStringFromCGRect(self.floatingKeyboardFrame),
        self.floatingKeyboardVisible,
        (__bridge void *)self.floatingKeyboardLayerHostView,
        (unsigned long)self.floatingKeyboardSessionGeneration);
    [self applyKeyboardFrame:CGRectNull visible:NO];
    [self finalizeKeyboardDismissalProtection];
}

- (void)finalizeKeyboardDismissalProtection {
    // WillChangeFrame owns the protection for the physical keyboard-dismiss
    // touch. DidHide arrives after that touch and the keyboard animation have
    // completed, so it must finish the protection instead of extending it for
    // another half second. The outside recognizers already preserve each
    // touch's begin-domain classification.
    self.floatingKeyboardInteractionGeneration += 1;
    NSUInteger finalizedGeneration =
        self.floatingKeyboardInteractionGeneration;
    self.floatingBackdropTap.additionalProtectedFrame = CGRectNull;
    ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame =
        CGRectNull;
    [self endFloatingKeyboardInteractionSession];
    self.floatingKeyboardMaximumVisibleHeight = 0.0;
    FLMDiagnosticLog(
        @"sb frame-hidden protection=finalized generation=%lu",
        (unsigned long)finalizedGeneration);
}

- (CGSize)floatingSystemSceneReferenceSize {
    if ([self isLandscapeFloatingSession]) {
        // The target App keeps its proven portrait Scene contract. The
        // landscape coordinator is responsible for placing and scaling that
        // portrait surface into the physical card; the App must not receive
        // a second landscape-to-portrait rewrite.
        return CGSizeMake(FLMVirtualViewportWidth, FLMVirtualViewportHeight);
    }
    CGRect displayBounds = FLMVisualScreenBounds();
    CGSize size = displayBounds.size;
    if (size.width < 1.0 || size.height < 1.0) {
        size = self.floatingWindow.bounds.size;
    }
    return size.width > 1.0 && size.height > 1.0 ? size : CGSizeZero;
}

- (CGSize)floatingContentViewportReferenceSize {
    // The system Scene and keyboard are wide in landscape, while the target
    // application's visible logical content stays portrait.
    if ([self isLandscapeFloatingSession]) {
        return CGSizeMake(FLMVirtualViewportWidth, FLMVirtualViewportHeight);
    }
    return [self floatingSystemSceneReferenceSize];
}

- (CGSize)floatingSceneReferenceSize {
    // Keep the helper as a scene-only alias. The card never becomes a Scene
    // geometry contract.
    return [self floatingSystemSceneReferenceSize];
}

- (BOOL)applyFloatingSceneLogicalFrameForCurrentPresentation:(NSString *)policy {
    id scene = self.floatingScene;
    if (!scene ||
        ![scene respondsToSelector:@selector(updateSettings:withTransitionContext:)]) {
        return NO;
    }
    CGSize systemSceneReference = [self floatingSystemSceneReferenceSize];
    CGSize contentViewportReference =
        [self floatingContentViewportReferenceSize];
    if (systemSceneReference.width <= 1.0 ||
        systemSceneReference.height <= 1.0) {
        return NO;
    }
    @try {
        id settings = [scene respondsToSelector:@selector(settings)]
                          ? [scene settings]
                          : nil;
        id mutableSettings = [settings mutableCopy];
        if (!mutableSettings && [scene respondsToSelector:@selector(mutableSettings)]) {
            mutableSettings = [scene mutableSettings];
        }
        if (!mutableSettings ||
            ![mutableSettings respondsToSelector:@selector(setFrame:)]) {
            return NO;
        }
        [mutableSettings setFrame:CGRectMake(0.0,
                                              0.0,
                                              systemSceneReference.width,
                                              systemSceneReference.height)];
        if ([mutableSettings respondsToSelector:@selector(setInterfaceOrientation:)]) {
            [mutableSettings setInterfaceOrientation:
                UIInterfaceOrientationPortrait];
        }
        [scene updateSettings:mutableSettings withTransitionContext:nil];
        self.floatingHostReferenceSize =
            [self floatingContentViewportReferenceSize];
        FLMDiagnosticLog(
            @"sb scene-frame policy=fullscreen systemSceneReference={%.4f,%.4f} contentViewportReference={%.4f,%.4f} physical-card={%.1f,%.1f} requested=%@",
            systemSceneReference.width,
            systemSceneReference.height,
            contentViewportReference.width,
            contentViewportReference.height,
            [self effectiveCenteredCardWidth],
            [self effectiveCenteredCardHeight],
            policy ?: @"unknown");
        return YES;
    } @catch (__unused NSException *exception) {
        FLMDiagnosticLog(
            @"sb scene-frame policy=fullscreen rejected=exception systemSceneReference={%.4f,%.4f} contentViewportReference={%.4f,%.4f} physical-card={%.1f,%.1f} requested=%@",
            systemSceneReference.width,
            systemSceneReference.height,
            contentViewportReference.width,
            contentViewportReference.height,
            [self effectiveCenteredCardWidth],
            [self effectiveCenteredCardHeight],
            policy ?: @"unknown");
        return NO;
    }
}

- (FLMApplicationSceneHandle *)sceneHandleForIdentifier:(NSString *)identifier {
    if (identifier.length == 0) {
        return nil;
    }
    @try {
        if (self.floatingSceneEntity &&
            [identifier isEqualToString:self.floatingIdentifier] &&
            [self.floatingSceneEntity respondsToSelector:@selector(sceneHandle)]) {
            id existingCandidate = [self.floatingSceneEntity sceneHandle];
            if (([existingCandidate respondsToSelector:@selector(sceneIfExists)] ||
                 [existingCandidate respondsToSelector:@selector(scene)]) &&
                [self sceneForHandle:existingCandidate]) {
                return (FLMApplicationSceneHandle *)existingCandidate;
            }
            // Do not keep polling a handle whose primary scene was replaced
            // during cold launch.  This was the main source of the permanent
            // "Launching application" card on iOS 16.
            self.floatingSceneEntity = nil;
            self.floatingSceneHandle = nil;
        }

        Class controllerClass = NSClassFromString(@"SBApplicationController");
        if (![controllerClass respondsToSelector:@selector(sharedInstance)]) {
            return nil;
        }
        FLMSBApplicationController *controller =
            (FLMSBApplicationController *)[controllerClass sharedInstance];
        if (![controller respondsToSelector:
                            @selector(applicationWithBundleIdentifier:)]) {
            return nil;
        }
        FLMSBApplication *application =
            (FLMSBApplication *)[controller
                applicationWithBundleIdentifier:identifier];
        if (!application) {
            return nil;
        }

        Class entityClass =
            NSClassFromString(@"SBDeviceApplicationSceneEntity");
        SEL initializer =
            @selector(initWithApplicationForMainDisplay:
                 generatingNewPrimarySceneIfRequired:);
        id allocatedEntity = [entityClass alloc];
        if (!allocatedEntity ||
            ![allocatedEntity respondsToSelector:initializer]) {
            return nil;
        }
        // First let the normal suspended launch create its own primary scene.
        // Forcing one synchronously races UIKit's scene connection and often
        // yields a valid handle with a black, never-ready surface.  Only ask
        // SpringBoard to generate a scene after a bounded grace period.
        BOOL generatePrimaryScene =
            self.floatingLaunchStartedAt > 0.0 &&
            CACurrentMediaTime() - self.floatingLaunchStartedAt >=
                FLMFloatingSceneGenerationDelay;
        FLMDeviceApplicationSceneEntity *entity =
            [(FLMDeviceApplicationSceneEntity *)allocatedEntity
                initWithApplicationForMainDisplay:application
                generatingNewPrimarySceneIfRequired:generatePrimaryScene];
        if (!entity ||
            ![entity respondsToSelector:@selector(sceneHandle)]) {
            return nil;
        }
        id candidate = [entity sceneHandle];
        if (![candidate respondsToSelector:@selector(sceneIfExists)] &&
            ![candidate respondsToSelector:@selector(scene)]) {
            return nil;
        }
        if (generatePrimaryScene || [self sceneForHandle:candidate]) {
            self.floatingSceneEntity = entity;
        }
        return (FLMApplicationSceneHandle *)candidate;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

- (id)sceneForHandle:(FLMApplicationSceneHandle *)sceneHandle {
    if (!sceneHandle) {
        return nil;
    }
    id scene = nil;
    @try {
        if ([sceneHandle respondsToSelector:@selector(sceneIfExists)]) {
            scene = [sceneHandle sceneIfExists];
        }
        if (!scene && [sceneHandle respondsToSelector:@selector(scene)]) {
            scene = [sceneHandle scene];
        }
    } @catch (__unused NSException *exception) {
        scene = nil;
    }
    return scene;
}

- (BOOL)prepareFloatingScene:(id)scene
                      handle:(FLMApplicationSceneHandle *)sceneHandle {
    if (!scene) {
        return NO;
    }
    FLMProtectScene(scene, sceneHandle);
    @try {
        if ([scene respondsToSelector:@selector(_setContentState:)]) {
            [scene _setContentState:2];
        }
        // A rapidly replaced card can leave the resolved Scene in a
        // backgrounded transaction even though its mutable settings say
        // foreground. Ask the Scene to activate before creating a presenter;
        // this is guarded because the selector is private and absent on some
        // iOS 16 builds.
        if ([scene respondsToSelector:@selector(activate)]) {
            [scene activate];
        }
        id settings = [scene respondsToSelector:@selector(settings)]
                          ? [scene settings]
                          : nil;
        id mutableSettings = [settings mutableCopy];
        if (!mutableSettings &&
            [scene respondsToSelector:@selector(mutableSettings)]) {
            mutableSettings = [scene mutableSettings];
        }
        if (!mutableSettings) {
            FLMClearProtectedScene(scene);
            return NO;
        }
        if ([mutableSettings respondsToSelector:@selector(setDeactivationReasons:)]) {
            [mutableSettings setDeactivationReasons:0];
        }
        if ([mutableSettings respondsToSelector:@selector(setForeground:)]) {
            [mutableSettings setForeground:YES];
        }
        if ([mutableSettings respondsToSelector:@selector(setBackgrounded:)]) {
            [mutableSettings setBackgrounded:NO];
        }
        CGSize systemSceneReference = [self floatingSystemSceneReferenceSize];
        CGSize contentViewportReference =
            [self floatingContentViewportReferenceSize];
        if (systemSceneReference.width > 0.0 &&
            systemSceneReference.height > 0.0 &&
            [mutableSettings respondsToSelector:@selector(setFrame:)]) {
            [mutableSettings
                setFrame:CGRectMake(0.0,
                                    0.0,
                                    systemSceneReference.width,
                                    systemSceneReference.height)];
            FLMDiagnosticLog(
                @"sb scene-frame policy=fullscreen systemSceneReference={%.4f,%.4f} contentViewportReference={%.4f,%.4f} physical-card={%.1f,%.1f} requested=prepare",
                systemSceneReference.width,
                systemSceneReference.height,
                contentViewportReference.width,
                contentViewportReference.height,
                [self effectiveCenteredCardWidth],
                [self effectiveCenteredCardHeight]);
        }
        NSInteger orientation = UIInterfaceOrientationPortrait;
        if ([mutableSettings respondsToSelector:
                             @selector(setInterfaceOrientation:)]) {
            [mutableSettings setInterfaceOrientation:orientation];
        }
        if ([self isLandscapeFloatingSession]) {
            FLMEnqueueDiagnosticLine(
                @"sb landscape-scene-contract frame={%.1f,%.1f} orientation=%ld content={%.1f,%.1f}",
                systemSceneReference.width, systemSceneReference.height,
                (long)orientation, contentViewportReference.width,
                contentViewportReference.height);
        }
        if (![scene respondsToSelector:
                       @selector(updateSettings:withTransitionContext:)]) {
            FLMClearProtectedScene(scene);
            return NO;
        }
        [scene updateSettings:mutableSettings withTransitionContext:nil];
        return YES;
    } @catch (__unused NSException *exception) {
        FLMClearProtectedScene(scene);
        return NO;
    }
}

- (void)backgroundFloatingScene:(id)scene {
    // Release BEFORE the transaction: our deactivation hooks must not turn
    // this explicit background request back into a foreground transaction.
    FLMClearProtectedScene(scene);
    if (!scene) {
        FLMClearProtectedScene(nil);
        return;
    }
    @try {
        // Opening activates both the Scene and its presenter. Closing must
        // unwind that ownership symmetrically so SpringBoard can later hand
        // the same Scene to a notification or a normal application launch.
        if ([scene respondsToSelector:@selector(deactivate)]) {
            [scene deactivate];
        }
        id settings = [scene respondsToSelector:@selector(settings)]
                          ? [scene settings]
                          : nil;
        id mutableSettings = [settings mutableCopy];
        if (!mutableSettings &&
            [scene respondsToSelector:@selector(mutableSettings)]) {
            mutableSettings = [scene mutableSettings];
        }
        CGRect screenBounds = FLMVisualScreenBounds();
        if ([mutableSettings respondsToSelector:@selector(setFrame:)] &&
            !CGRectIsEmpty(screenBounds)) {
            [mutableSettings setFrame:CGRectMake(0.0,
                                                  0.0,
                                                  CGRectGetWidth(screenBounds),
                                                  CGRectGetHeight(screenBounds))];
        }
        if ([mutableSettings respondsToSelector:
                             @selector(setInterfaceOrientation:)]) {
            [mutableSettings setInterfaceOrientation:
                [self isLandscapeFloatingSession]
                    ? self.floatingLandscapeInterfaceOrientation
                    : UIInterfaceOrientationPortrait];
        }
        if ([mutableSettings respondsToSelector:@selector(setForeground:)]) {
            [mutableSettings setForeground:NO];
        }
        if ([mutableSettings respondsToSelector:@selector(setBackgrounded:)]) {
            [mutableSettings setBackgrounded:YES];
        }
        if (mutableSettings &&
            [scene respondsToSelector:
                       @selector(updateSettings:withTransitionContext:)]) {
            [scene updateSettings:mutableSettings withTransitionContext:nil];
        }
    } @catch (__unused NSException *exception) {
    }
    FLMClearProtectedScene(scene);
}

- (void)invalidateFloatingPresenterForRecoveryReason:(NSString *)reason {
    id presenter = self.floatingPresenter;
    id manager = self.floatingPresentationManager;
    id presenterScene = self.floatingPresenterScene;
    UIView *host = self.floatingHostView;
    self.floatingPresenter = nil;
    self.floatingPresentationManager = nil;
    self.floatingPresenterScene = nil;
    self.floatingPresenterUnavailableAt = 0.0;
    if (host) {
        [host removeFromSuperview];
        self.floatingHostView = nil;
    }
    @try {
        if ([presenter respondsToSelector:@selector(deactivate)]) {
            [presenter deactivate];
        }
        if ([presenter respondsToSelector:@selector(invalidate)]) {
            [presenter invalidate];
        }
    } @catch (__unused NSException *exception) {
    }
    FLMDiagnosticLog(
        @"sb presenter-recovery reason=%@ manager=%p presenter=%p scene=%@",
        reason ?: @"<unspecified>", (__bridge void *)manager,
        (__bridge void *)presenter,
        FLMSceneIdentifier(presenterScene) ?: @"<none>");
}

- (UIView *)hostViewForSceneHandle:(FLMApplicationSceneHandle *)sceneHandle {
    if (!sceneHandle) {
        return nil;
    }
    id scene = [self sceneForHandle:sceneHandle];
    if (self.floatingPresenterScene &&
        self.floatingPresenterScene != scene) {
        [self invalidateFloatingPresenterForRecoveryReason:@"scene-replaced"];
    }
    BOOL sceneChanged = scene && scene != self.floatingScene;
    BOOL needsInitialSceneSettle = self.floatingScenePreparedAt <= 0.0;
    FLMDiagnosticLog(
        @"sb presenter-query handle=%p scene=%@ changed=%d initialSettle=%d launch=%lu",
        (__bridge void *)sceneHandle, FLMSceneIdentifier(scene) ?: @"<none>",
        sceneChanged, needsInitialSceneSettle,
        (unsigned long)self.floatingLaunchState);
    if ((sceneChanged || needsInitialSceneSettle ||
         !FLMObjectMatchesProtectedScene(scene)) &&
        ![self prepareFloatingScene:scene handle:sceneHandle]) {
        return nil;
    }
    self.floatingScene = scene;
    FLMPublishKeyboardState(self.floatingIdentifier,
                            scene,
                            self.floatingKeyboardSessionGeneration);
    self.floatingHostReferenceSize =
        [self floatingContentViewportReferenceSize];

    // Let the foreground/frame settings reach the application process before
    // creating the remote presenter. Creating both in the same transaction is
    // fast on a warm app but intermittently leaves a permanently black surface
    // during cold launch.
    if (sceneChanged || needsInitialSceneSettle) {
        self.floatingScenePreparedAt = CACurrentMediaTime();
        self.floatingLaunchState = FLMFloatingLaunchStateWaitingForPresenter;
        return nil;
    }
    if (self.floatingScenePreparedAt > 0.0 &&
        CACurrentMediaTime() - self.floatingScenePreparedAt <
            FLMFloatingSceneSettleDelay) {
        return nil;
    }

    id manager = self.floatingPresentationManager;
    id presenter = self.floatingPresenter;
    UIView *host = nil;
    @try {
        if (!manager &&
            [scene respondsToSelector:@selector(uiPresentationManager)]) {
            manager = [scene uiPresentationManager];
        }
        if (!manager &&
            [scene respondsToSelector:@selector(presentationManager)]) {
            manager = [scene presentationManager];
        }
        if (manager && manager != self.floatingPresentationManager) {
            self.floatingPresentationManager = manager;
        }
        if (!presenter) {
            if ([manager respondsToSelector:
                             @selector(createPresenterWithIdentifier:)]) {
                presenter =
                    [manager createPresenterWithIdentifier:
                                 @"com.codex.flymemultitasking.centered"];
                if (presenter) {
                    self.floatingPresenter = presenter;
                }
                if ([presenter respondsToSelector:@selector(activate)]) {
                    [presenter activate];
                }
            }
        }
        if ([presenter respondsToSelector:@selector(presentationView)]) {
            host = [presenter presentationView];
        }
    } @catch (__unused NSException *exception) {
        host = nil;
    }
    if (![host isKindOfClass:[UIView class]]) {
        if (self.floatingPresenterUnavailableAt <= 0.0) {
            self.floatingPresenterUnavailableAt = CACurrentMediaTime();
        }
        NSTimeInterval unavailableFor =
            CACurrentMediaTime() - self.floatingPresenterUnavailableAt;
        if (unavailableFor >= FLMFloatingPresenterRecoveryTimeout ||
            (self.floatingPresenterRetryAttempt > 0 &&
             self.floatingPresenterRetryAttempt % 12 == 0)) {
            FLMDiagnosticLog(
                @"sb presenter-stale-retry manager=%p presenter=%p scene=%@ attempt=%lu unavailable=%.3f",
                (__bridge void *)manager, (__bridge void *)presenter,
                FLMSceneIdentifier(scene) ?: @"<none>",
                (unsigned long)self.floatingPresenterRetryAttempt,
                unavailableFor);
            [self invalidateFloatingPresenterForRecoveryReason:
                      @"nil-host-timeout"];
            // A manager can outlive the Scene transaction that created it.
            // Force the next retry through a fresh handle instead of polling
            // the stale manager indefinitely.
            self.floatingSceneEntity = nil;
            self.floatingSceneHandle = nil;
            self.floatingScene = nil;
            self.floatingScenePreparedAt = 0.0;
        }
        FLMDiagnosticLog(
            @"sb presenter-not-ready manager=%p presenter=%p scene=%@ attempt=%lu unavailable=%.3f",
            (__bridge void *)manager, (__bridge void *)presenter,
            FLMSceneIdentifier(scene) ?: @"<none>",
            (unsigned long)self.floatingPresenterRetryAttempt, unavailableFor);
        return nil;
    }
    self.floatingPresentationManager = manager;
    self.floatingPresenter = presenter;
    self.floatingPresenterScene = scene;
    self.floatingPresenterUnavailableAt = 0.0;
    host.backgroundColor = [UIColor blackColor];
    host.userInteractionEnabled = YES;
    // The host always uses the display-sized Scene reference. The physical
    // card is only a clipped presentation surface with the user-selected
    // width and top/bottom crop values.
    host.clipsToBounds = NO;
    self.floatingLaunchState = FLMFloatingLaunchStateAttached;
    FLMDiagnosticLog(
        @"sb presenter-attached host=%p frame=%@ scene=%@",
        (__bridge void *)host, NSStringFromCGRect(host.frame),
        FLMSceneIdentifier(scene) ?: @"<none>");
    return host;
}

- (void)openFloatingIdentifier:(NSString *)identifier {
    if (identifier.length == 0 || FLMDeviceIsLocked()) {
        self.prewarmedIdentifier = nil;
        self.floatingOpenTargetDocked = NO;
        return;
    }
    if (self.floatingCloseInProgress) {
        // All wheel targets share the same close transaction. Keep only the
        // latest request and let the close completion open it after the old
        // Scene/presenter has been released.
        self.floatingQueuedIdentifier = [identifier copy];
        FLMDiagnosticLog(
            @"sb centered-open queued target=%@ closeToken=%lu current=%@",
            identifier, (unsigned long)self.floatingActiveCloseToken,
            self.floatingIdentifier ?: @"<none>");
        return;
    }
    if (!self.floatingWindow.hidden && self.floatingIdentifier.length > 0 &&
        [identifier isEqualToString:self.floatingIdentifier]) {
        self.prewarmedIdentifier = nil;
        return;
    }
    if (!self.floatingWindow.hidden) {
        self.floatingQueuedIdentifier = [identifier copy];
        [self closeFloatingWindowKeepingApplication:YES];
        FLMDiagnosticLog(
            @"sb centered-open queued target=%@ closeToken=%lu reason=replace-current",
            identifier, (unsigned long)self.floatingActiveCloseToken);
        return;
    }
    if ([identifier isEqualToString:FLMFrontmostApplicationIdentifier()] &&
        !self.floatingOpenTargetDocked) {
        self.prewarmedIdentifier = nil;
        return;
    }

    BOOL alreadyPrewarmed =
        [self.prewarmedIdentifier isEqualToString:identifier];
    self.prewarmedIdentifier = nil;
    if (self.floatingKeyboardSessionGeneration != 0) {
        // End the old route while its original Scene/host are still retained;
        // assigning the new target first would make stale cleanup operate on
        // the wrong application generation.
        [self endFloatingKeyboardSession];
    }
    // A newly opened centered card must never inherit the previous Dock
    // target's process-level input block, including after an interrupted
    // SpringBoard/card lifecycle.
    FLMPublishDockInputBlockState(nil, NO, @"centered-open");

    // Lock one physical orientation/geometry contract for the whole card
    // session. This prevents stale portrait reports from flipping coordinates
    // after a wheel icon is tapped.
    [self captureFloatingOrientationContract];
    // Ignore the tail of the wheel-selection gesture so a newly opened card
    // cannot be mistaken for an outside tap and immediately closed.
    self.floatingOpenCloseGuardUntil = CACurrentMediaTime() + 0.55;
    self.floatingCloseInputArmed = NO;

    self.floatingDockWidth = [self effectiveDockedPresentationWidth];
    self.floatingReconnectSuppressed = NO;
    self.floatingDocked = NO;
    self.floatingDockHidden = NO;
    self.floatingDockHideGestureActive = NO;
    self.floatingDockHideInitialHandleFrame = CGRectNull;
    self.floatingDockedOnRight = YES;
    self.floatingExternalActivationArmed = NO;
    self.floatingFullscreenActivationArmed = NO;
    self.lastObservedFrontmostIdentifier = nil;
    self.floatingDockTransitionActive = NO;
    self.floatingDockControlArmed = NO;
    self.floatingDockEntrySettleActive = NO;
    self.floatingDockEntrySettleGeneration += 1;
    self.floatingDockEntryTargetFrame = CGRectNull;
    self.floatingDockTouchCaptureFrame = CGRectNull;
    self.floatingDockEntryControlTouchPending = NO;
    self.floatingDockInputSessionActive = NO;
    self.floatingDockInputMode = FLMFloatingDockInputModeNone;
    self.floatingDockInputTargetsResize = NO;
    self.floatingResizeCenterReady = NO;
    self.floatingResizeHandle.hidden = YES;
    self.floatingResizeHandle.userInteractionEnabled = NO;
    [self cancelFloatingDockInputUpdates];
    [self setFloatingDockRoutingSuppressed:NO];
    // Promote the target with the display-sized Scene first so it retains the
    // full-screen application-style activation and keyboard ownership. The
    // fixed card Scene is committed only after the presenter is attached;
    // this separates route establishment from geometry/layout.
    self.floatingSceneUsesCardGeometry = NO;
    self.floatingSceneCardGeometryPending = NO;
    self.floatingSceneCardGeometryCommitted = YES;
    self.floatingDockReady = NO;
    ((FLMFloatingWindow *)self.floatingWindow)
        .passesTouchesOutsideFloatingContent = NO;
    self.floatingDockTap.enabled = NO;
    self.floatingDockDragPress.enabled = NO;
    self.floatingDockInputGesture.enabled = NO;
    self.floatingDockInputGeneration += 1;
    self.floatingDockShadowView.hidden = YES;
    self.floatingDockShadowView.alpha = 0.0;
    self.floatingDockShadowView.transform = CGAffineTransformIdentity;
    self.floatingDockInteractionShield.hidden = YES;
    self.floatingDockInteractionShield.userInteractionEnabled = NO;
    [self restoreFloatingHandleInteraction];
    self.floatingContainer.layer.borderWidth = 0.0;
    self.floatingInteractiveScenePrepared = NO;
    self.floatingInteractiveFullscreenTransition = NO;
    [self.floatingInteractiveSnapshot removeFromSuperview];
    self.floatingInteractiveSnapshot = nil;
    self.floatingInteractiveSnapshotBackground = nil;
    self.floatingInteractiveSnapshotContent = nil;
    self.floatingFullscreenProgress = 0.0;
    self.floatingKeyboardInteractionGeneration += 1;
    self.floatingKeyboardInteractionSessionActive = NO;
    self.floatingKeyboardVisible = NO;
    self.floatingKeyboardFrame = CGRectNull;
    self.floatingKeyboardFramePending = NO;
    self.floatingKeyboardPendingFrame = CGRectNull;
    self.floatingKeyboardPendingSessionGeneration = 0;
    self.floatingExclusiveTapEligible = NO;
    self.floatingBackdropTap.additionalProtectedFrame = CGRectNull;
    ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame = CGRectNull;
    self.floatingLaunchGeneration += 1;
    NSUInteger generation = self.floatingLaunchGeneration;
    self.floatingCloseArmGeneration = generation;
    self.floatingCloseArmAt = CACurrentMediaTime() + 0.55;
    self.floatingLaunchState = FLMFloatingLaunchStatePrewarming;
    self.floatingLaunchStartedAt = CACurrentMediaTime();
    self.floatingScenePreparedAt = 0.0;
    [self.floatingHostView removeFromSuperview];
    self.floatingHostView = nil;
    self.floatingHostReferenceSize = CGSizeZero;
    self.floatingSceneEntity = nil;
    self.floatingSceneHandle = nil;
    self.floatingScene = nil;
    self.floatingPresentationManager = nil;
    self.floatingPresenter = nil;
    self.floatingPresenterScene = nil;
    self.floatingPresenterUnavailableAt = 0.0;
    self.floatingPresenterRetryAttempt = 0;
    self.floatingIdentifier = identifier;
    [self discardFloatingKeyboardLayerHost];
    self.floatingKeyboardSessionCounter += 1;
    if (self.floatingKeyboardSessionCounter == 0) {
        self.floatingKeyboardSessionCounter = 1;
    }
    self.floatingKeyboardSessionGeneration =
        self.floatingKeyboardSessionCounter;
    self.floatingSceneGeometryCommitGeneration = generation;
    FLMDiagnosticLog(
        @"sb centered-open app=%@ launchGen=%lu session=%lu prewarmed=%d previousHost=%p",
        identifier, (unsigned long)generation,
        (unsigned long)self.floatingKeyboardSessionGeneration,
        alreadyPrewarmed, (__bridge void *)self.floatingKeyboardLayerHostView);
    // Do not wake an old application responder with a target-gated route. The
    // route becomes active only after SpringBoard resolves the exact Scene.
    FLMPublishKeyboardState(nil, nil, 0);
    [self configureFloatingLaunchCoverForIdentifier:identifier];
    [self layoutFloatingWindow];

    self.floatingDimView.alpha = 0.0;
    self.floatingContainer.alpha = 0.0;
    self.floatingContainer.transform = CGAffineTransformMakeScale(0.90, 0.90);
    self.floatingHandle.alpha = 0.0;
    self.floatingHandle.userInteractionEnabled = NO;
    self.previousKeyWindow = FLMCurrentKeyWindow();
    self.floatingBackdropTap.enabled = NO;
    self.floatingExclusiveGesture.enabled = NO;
    // The corner-only priority window remains live while the card is
    // prewarming/attaching. Wheel presentation must not depend on the target
    // app's Scene or on the card animation having completed.
    self.cornerGuardGesture.enabled = self.enabled;
    self.cornerGesture.enabled = self.enabled;
    [self.floatingWindow makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self layoutFloatingWindow];
    });
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [self armFloatingCloseInputForGeneration:generation];
        });
    [self beginFloatingHighRefreshLeaseForDuration:0.40];
    [UIView animateWithDuration:0.40
                          delay:0.0
         usingSpringWithDamping:0.84
          initialSpringVelocity:0.30
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         self.floatingDimView.alpha = 1.0;
                         self.floatingContainer.alpha = 1.0;
                         self.floatingContainer.transform = CGAffineTransformIdentity;
                         self.floatingHandle.alpha = 1.0;
                     }
                     completion:nil];

    if (!alreadyPrewarmed) {
        FLMPrewarmApplicationIdentifier(identifier);
    }
    [self beginLockMonitoring];
    // Let UIKit publish its normal primary scene before querying an entity.
    // Creating both transactions in the same run-loop turn is racy on iOS 16.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(FLMFloatingSceneResolveGraceDelay *
                                           NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self attachFloatingIdentifier:identifier
                            generation:generation
                               attempt:0];
    });
}

- (void)attachFloatingIdentifier:(NSString *)identifier
                      generation:(NSUInteger)generation
                         attempt:(NSUInteger)attempt {
    if (generation != self.floatingLaunchGeneration ||
        ![identifier isEqualToString:self.floatingIdentifier] ||
        self.floatingWindow.hidden) {
        return;
    }
    if (self.floatingLaunchStartedAt <= 0.0) {
        self.floatingLaunchStartedAt = CACurrentMediaTime();
    }
    if (CACurrentMediaTime() - self.floatingLaunchStartedAt >
        FLMFloatingLaunchTimeout) {
        [self failFloatingLaunchForIdentifier:identifier generation:generation];
        return;
    }
    FLMApplicationSceneHandle *sceneHandle =
        [self sceneHandleForIdentifier:identifier];
    if (!sceneHandle) {
        self.floatingLaunchState = FLMFloatingLaunchStateWaitingForScene;
        self.floatingStatusLabel.text = @"正在准备应用…";
        if (attempt < 60) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(FLMFloatingSceneRetryDelay(attempt) *
                                        NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [self attachFloatingIdentifier:identifier
                                        generation:generation
                                           attempt:attempt + 1];
                });
            return;
        }
        [self failFloatingLaunchForIdentifier:identifier generation:generation];
        return;
    }

    id resolvedScene = [self sceneForHandle:sceneHandle];
    if (!resolvedScene) {
        self.floatingLaunchState = FLMFloatingLaunchStateWaitingForScene;
        self.floatingStatusLabel.text = @"正在启动应用…";
        if (attempt > 0 && attempt % 5 == 0) {
            // A generated primary-scene entity can retain a handle whose scene
            // was replaced during application launch. Resolve a fresh entity
            // instead of polling the dead handle for the full timeout.
            self.floatingSceneEntity = nil;
            self.floatingSceneHandle = nil;
        }
        if (attempt == 8) {
            FLMPrewarmApplicationIdentifier(identifier);
        }
        if (attempt < 60) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(FLMFloatingSceneRetryDelay(attempt) *
                                        NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [self attachFloatingIdentifier:identifier
                                        generation:generation
                                           attempt:attempt + 1];
                });
            return;
        }
        [self failFloatingLaunchForIdentifier:identifier generation:generation];
        return;
    }

    if (resolvedScene != self.floatingScene) {
        self.floatingScene = resolvedScene;
        FLMDiagnosticLog(
            @"sb scene-resolved app=%@ launchGen=%lu attempt=%lu scene=%@ session=%lu",
            identifier, (unsigned long)generation, (unsigned long)attempt,
            FLMSceneIdentifier(resolvedScene) ?: @"<none>",
            (unsigned long)self.floatingKeyboardSessionGeneration);
        FLMPublishKeyboardState(identifier,
                                resolvedScene,
                                self.floatingKeyboardSessionGeneration);
        // Give the freshly resolved application Scene one short main-run-loop
        // interval before foreground/frame settings are committed.
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(FLMFloatingSceneResolveGraceDelay *
                                    NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                [self attachFloatingIdentifier:identifier
                                    generation:generation
                                       attempt:attempt + 1];
            });
        return;
    }

    self.floatingPresenterRetryAttempt = attempt;
    UIView *host = [self hostViewForSceneHandle:sceneHandle];
    if (!host) {
        self.floatingLaunchState = FLMFloatingLaunchStateWaitingForPresenter;
        self.floatingStatusLabel.text = @"正在连接画面…";
        // Do not leave a neutral launch cover on screen indefinitely when
        // SpringBoard's presentation manager has lost its presenter during a
        // rapid app switch. After a short bounded retry window, the existing
        // fullscreen activation path is safer than a visually frozen card.
        if (attempt >= 28 && self.floatingPresenterUnavailableAt > 0.0) {
            FLMDiagnosticLog(
                @"sb presenter-watchdog fallback=fullscreen app=%@ generation=%lu attempt=%lu unavailable=%.3f",
                identifier, (unsigned long)generation, (unsigned long)attempt,
                CACurrentMediaTime() - self.floatingPresenterUnavailableAt);
            [self failFloatingLaunchForIdentifier:identifier
                                         generation:generation];
            return;
        }
        if (attempt < 60) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(FLMFloatingSceneRetryDelay(attempt) *
                                        NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [self attachFloatingIdentifier:identifier
                                        generation:generation
                                           attempt:attempt + 1];
                });
            return;
        }
        [self failFloatingLaunchForIdentifier:identifier generation:generation];
        return;
    }
    self.floatingSceneHandle = sceneHandle;
    self.floatingHostView = host;
    if (self.floatingHostReferenceSize.width < 1.0 ||
        self.floatingHostReferenceSize.height < 1.0) {
        CGSize referenceSize = host.bounds.size;
        if (referenceSize.width < 1.0 || referenceSize.height < 1.0) {
            referenceSize = [self floatingContentViewportReferenceSize];
        }
        self.floatingHostReferenceSize = referenceSize;
    }
    host.autoresizingMask = UIViewAutoresizingNone;
    host.userInteractionEnabled = NO;
    [self.floatingContainer insertSubview:host atIndex:0];
    [self layoutFloatingHostView];
    self.floatingStatusLabel.hidden = YES;
    [self.floatingContainer bringSubviewToFront:self.floatingLaunchCoverView];
    [self flushDeferredFloatingKeyboardHostIfReady];
    [self flushPendingFloatingKeyboardFrameIfReady];
    [self revealFloatingContentForGeneration:generation];
    FLMDiagnosticLog(
        @"sb centered-content-ready app=%@ launchGen=%lu attempt=%lu host=%p hostBounds=%@ systemSceneReference={%.4f,%.4f} hostReference={%.4f,%.4f} physical-card={%.1f,%.1f} topCrop=%.1f bottomCrop=%.1f sceneFrameReference=system contentViewportCommitted=%d",
        identifier, (unsigned long)generation, (unsigned long)attempt,
        (__bridge void *)host, NSStringFromCGRect(host.bounds),
        [self floatingSystemSceneReferenceSize].width,
        [self floatingSystemSceneReferenceSize].height,
        self.floatingHostReferenceSize.width,
        self.floatingHostReferenceSize.height,
        [self effectiveCenteredCardWidth],
        [self effectiveCenteredCardHeight],
        self.centeredCardTopCrop,
        self.centeredCardBottomCrop,
        self.floatingSceneCardGeometryCommitted);
}

- (BOOL)floatingSceneLogicalFrameMatchesSystemReference {
    id scene = self.floatingScene;
    CGSize systemSceneReference = [self floatingSystemSceneReferenceSize];
    if (!scene || systemSceneReference.width <= 1.0 ||
        systemSceneReference.height <= 1.0) {
        return NO;
    }
    @try {
        id settings = [scene respondsToSelector:@selector(settings)]
                          ? [scene settings]
                          : nil;
        id frameValue = [settings respondsToSelector:@selector(valueForKey:)]
                            ? [settings valueForKey:@"frame"]
                            : nil;
        if (![frameValue isKindOfClass:[NSValue class]]) {
            return NO;
        }
        CGRect frame = [frameValue CGRectValue];
        return fabs(CGRectGetWidth(frame) - systemSceneReference.width) <= 1.0 &&
               fabs(CGRectGetHeight(frame) - systemSceneReference.height) <= 1.0;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

- (void)commitFloatingCardSceneGeometryForIdentifier:(NSString *)identifier
                                           generation:(NSUInteger)generation
                                              attempt:(NSUInteger)attempt {
    if (generation != self.floatingLaunchGeneration ||
        ![identifier isEqualToString:self.floatingIdentifier] ||
        self.floatingWindow.hidden || !self.floatingHostView ||
        !self.floatingSceneCardGeometryPending) {
        return;
    }
    self.floatingSceneGeometryCommitGeneration = generation;
    CGSize previousReference = self.floatingHostReferenceSize;
    self.floatingSceneUsesCardGeometry = NO;
    BOOL applied =
        [self applyFloatingSceneLogicalFrameForCurrentPresentation:
                  @"content-viewport-request"];
    // Do not change the Scene reference here. The route was established using
    // the display-sized Scene and must remain that way. Only the presentation
    // host changes reference space after its content viewport is committed.
    CGSize systemSceneReference = [self floatingSystemSceneReferenceSize];
    CGSize contentViewportReference =
        [self floatingContentViewportReferenceSize];
    [self layoutFloatingHostView];
    FLMDiagnosticLog(
        @"sb content-viewport request generation=%lu attempt=%lu applied=%d previousHostReference={%.4f,%.4f} systemSceneReference={%.4f,%.4f} contentViewportReference={%.4f,%.4f} physical-card={%.1f,%.1f} scaleXY={%.6f,%.6f} host=%@ sceneFrameReference=system routeSession=%lu",
        (unsigned long)generation, (unsigned long)attempt, applied,
        previousReference.width,
        previousReference.height,
        systemSceneReference.width,
        systemSceneReference.height,
        contentViewportReference.width,
        contentViewportReference.height,
        [self effectiveCenteredCardWidth],
        [self effectiveCenteredCardHeight],
        [self effectiveCenteredCardScaleX],
        [self effectiveCenteredCardScaleY],
        NSStringFromCGRect(self.floatingHostView.bounds),
        (unsigned long)self.floatingKeyboardSessionGeneration);

    if (!applied && attempt >= 8) {
        [self finishFloatingCardSceneGeometryCommitForIdentifier:identifier
                                                         generation:generation
                                                            attempt:attempt];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(FLMFloatingSceneSettleDelay *
                                           NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self finishFloatingCardSceneGeometryCommitForIdentifier:identifier
                                                         generation:generation
                                                            attempt:attempt + 1];
    });
}

- (void)finishFloatingCardSceneGeometryCommitForIdentifier:(NSString *)identifier
                                                  generation:(NSUInteger)generation
                                                     attempt:(NSUInteger)attempt {
    if (generation != self.floatingLaunchGeneration ||
        ![identifier isEqualToString:self.floatingIdentifier] ||
        self.floatingWindow.hidden || !self.floatingHostView ||
        !self.floatingSceneCardGeometryPending) {
        return;
    }
    BOOL committed = [self floatingSceneLogicalFrameMatchesSystemReference];
    if (!committed && attempt < 8) {
        [self commitFloatingCardSceneGeometryForIdentifier:identifier
                                                 generation:generation
                                                    attempt:attempt];
        return;
    }
    if (!committed) {
        // A private Scene may reject the display-sized frame during lifecycle
        // churn. Keep the existing bounded fallback rather than exposing a
        // half-laid-out card or leaving the launch cover forever.
        self.floatingSceneUsesCardGeometry = NO;
        self.floatingSceneCardGeometryPending = NO;
        self.floatingSceneCardGeometryCommitted = NO;
        [self applyFloatingSceneLogicalFrameForCurrentPresentation:
                  @"content-viewport-fallback-fullscreen"];
        [self layoutFloatingHostView];
        CGSize systemSceneReference = [self floatingSystemSceneReferenceSize];
        CGSize contentViewportReference =
            [self floatingContentViewportReferenceSize];
        FLMDiagnosticLog(
            @"sb content-viewport fallback=fullscreen generation=%lu attempt=%lu systemSceneReference={%.4f,%.4f} contentViewportReference={%.4f,%.4f} physical-card={%.1f,%.1f} host=%@ sceneFrameReference=system",
            (unsigned long)generation, (unsigned long)attempt,
            systemSceneReference.width,
            systemSceneReference.height,
            contentViewportReference.width,
            contentViewportReference.height,
            [self effectiveCenteredCardWidth],
            [self effectiveCenteredCardHeight],
            NSStringFromCGRect(self.floatingHostView.bounds));
    } else {
        self.floatingSceneCardGeometryPending = NO;
        self.floatingSceneCardGeometryCommitted = YES;
        self.floatingHostReferenceSize =
            [self floatingContentViewportReferenceSize];
        [self layoutFloatingHostView];
        CGSize systemSceneReference = [self floatingSystemSceneReferenceSize];
        CGSize contentViewportReference =
            [self floatingContentViewportReferenceSize];
        FLMDiagnosticLog(
        @"sb content-viewport committed generation=%lu attempt=%lu systemSceneReference={%.4f,%.4f} contentViewportReference={%.4f,%.4f} physical-card={%.1f,%.1f} scaleXY={%.6f,%.6f} host=%@ sceneFrameReference=system routeSession=%lu",
            (unsigned long)generation, (unsigned long)attempt,
            systemSceneReference.width,
            systemSceneReference.height,
            contentViewportReference.width,
            contentViewportReference.height,
            [self effectiveCenteredCardWidth],
            [self effectiveCenteredCardHeight],
            [self effectiveCenteredCardScaleX],
            [self effectiveCenteredCardScaleY],
            NSStringFromCGRect(self.floatingHostView.bounds),
            (unsigned long)self.floatingKeyboardSessionGeneration);
    }

    [self flushDeferredFloatingKeyboardHostIfReady];
    [self flushPendingFloatingKeyboardFrameIfReady];
    [self revealFloatingContentForGeneration:generation];
    FLMDiagnosticLog(
        @"sb centered-content-ready app=%@ launchGen=%lu attempt=%lu host=%p hostBounds=%@ systemSceneReference={%.4f,%.4f} contentViewportReference={%.4f,%.4f} hostReference={%.4f,%.4f} physical-card={%.1f,%.1f} scaleXY={%.6f,%.6f} sceneFrameReference=system contentViewportCommitted=%d routeSession=%lu",
        identifier, (unsigned long)generation, (unsigned long)attempt,
        (__bridge void *)self.floatingHostView,
        NSStringFromCGRect(self.floatingHostView.bounds),
        [self floatingSystemSceneReferenceSize].width,
        [self floatingSystemSceneReferenceSize].height,
        [self floatingContentViewportReferenceSize].width,
        [self floatingContentViewportReferenceSize].height,
        self.floatingHostReferenceSize.width,
        self.floatingHostReferenceSize.height,
        [self effectiveCenteredCardWidth],
        [self effectiveCenteredCardHeight],
        [self effectiveCenteredCardScaleX],
        [self effectiveCenteredCardScaleY],
        self.floatingSceneCardGeometryCommitted,
        (unsigned long)self.floatingKeyboardSessionGeneration);
}

- (void)failFloatingLaunchForIdentifier:(NSString *)identifier
                               generation:(NSUInteger)generation {
    if (generation != self.floatingLaunchGeneration ||
        self.floatingWindow.hidden) {
        return;
    }
    // Invalidate delayed retries before releasing the protection lease.  A
    // retry from a prior launch must never attach a replaced primary scene.
    self.floatingLaunchState = FLMFloatingLaunchStateFailing;
    self.floatingReconnectSuppressed = YES;
    // Fullscreen fallback must be serialized behind the normal close cleanup.
    // Starting it immediately races presenter invalidation and can leave the
    // next activation attached to the old Scene generation.
    self.floatingQueuedFullscreenIdentifier = [identifier copy];
    [self closeFloatingWindowKeepingApplication:YES];
}

- (void)closeFloatingWindowKeepingApplication:(BOOL)keepApplication {
    if (self.floatingCloseInProgress) {
        FLMDiagnosticLog(
            @"sb centered-close no-op closeToken=%lu requestedKeep=%d queuedTarget=%@",
            (unsigned long)self.floatingActiveCloseToken, keepApplication,
            self.floatingQueuedIdentifier ?: @"<none>");
        return;
    }
    self.floatingCloseInProgress = YES;
    self.floatingCloseInputArmed = NO;
    self.floatingBackdropTap.enabled = NO;
    self.floatingExclusiveGesture.enabled = NO;
    self.floatingOpenCloseGuardUntil = 0.0;
    [self cancelFloatingDockInputUpdates];
    [self setFloatingDockRoutingSuppressed:NO];
    self.floatingOpenTargetDocked = NO;
    self.floatingCloseCleanupDone = NO;
    self.floatingCloseKeepApplication = keepApplication;
    self.floatingCloseTokenCounter += 1;
    if (self.floatingCloseTokenCounter == 0) {
        self.floatingCloseTokenCounter = 1;
    }
    NSUInteger closeToken = self.floatingCloseTokenCounter;
    self.floatingActiveCloseToken = closeToken;
    FLMDiagnosticLog(
        @"sb centered-close begin closeToken=%lu keep=%d app=%@ scene=%@ launchGen=%lu session=%lu keyboardVisible=%d interaction=%d host=%p forwardingKey=%d queuedTarget=%@",
        (unsigned long)closeToken,
        keepApplication, self.floatingIdentifier ?: @"<none>",
        FLMSceneIdentifier(self.floatingScene) ?: @"<none>",
        (unsigned long)self.floatingLaunchGeneration,
        (unsigned long)self.floatingKeyboardSessionGeneration,
        self.floatingKeyboardVisible,
        self.floatingKeyboardInteractionSessionActive,
        (__bridge void *)self.floatingKeyboardLayerHostView,
        self.keyboardForwardingWindow.isKeyWindow,
        self.floatingQueuedIdentifier ?: @"<none>");
    if (keepApplication && self.floatingIdentifier.length > 0 &&
        self.floatingKeyboardSessionGeneration != 0) {
        // Deliver the application-side responder cleanup while the retained
        // Scene and presenter are still attached. The normal 0.24 s close
        // animation supplies the grace window; no keyboard notification,
        // overlay, or close-state timeout is introduced.
        FLMPublishKeyboardDismissRequest(
            self.floatingIdentifier,
            self.floatingKeyboardSessionGeneration);
    }
    [self endFloatingKeyboardSession];
    self.floatingLaunchGeneration += 1;
    self.floatingLaunchState = FLMFloatingLaunchStateClosing;
    self.floatingLaunchStartedAt = 0.0;
    self.floatingRevealRetryCount = 0;
    self.floatingScenePreparedAt = 0.0;
    self.floatingSceneUsesCardGeometry = NO;
    self.floatingSceneCardGeometryPending = NO;
    self.floatingSceneCardGeometryCommitted = NO;
    [self.floatingInteractiveSnapshot removeFromSuperview];
    self.floatingInteractiveSnapshot = nil;
    self.floatingInteractiveSnapshotBackground = nil;
    self.floatingInteractiveSnapshotContent = nil;
    self.floatingFullscreenProgress = 0.0;
    self.floatingKeyboardInteractionGeneration += 1;
    self.floatingKeyboardInteractionSessionActive = NO;
    self.floatingInteractiveScenePrepared = NO;
    self.floatingInteractiveFullscreenTransition = NO;
    self.floatingDockControlArmed = NO;
    self.floatingDockEntrySettleActive = NO;
    self.floatingDockEntrySettleGeneration += 1;
    self.floatingDockEntryTargetFrame = CGRectNull;
    self.floatingDockTouchCaptureFrame = CGRectNull;
    self.floatingDockEntryControlTouchPending = NO;
    self.floatingDocked = NO;
    self.floatingDockHidden = NO;
    self.floatingDockHideGestureActive = NO;
    self.floatingDockHideInitialHandleFrame = CGRectNull;
    self.floatingDockTransitionActive = NO;
    self.floatingDockInputSessionActive = NO;
    self.floatingDockInputMode = FLMFloatingDockInputModeNone;
    self.floatingDockInputTargetsResize = NO;
    self.floatingResizeCenterReady = NO;
    self.floatingResizeHandle.hidden = YES;
    self.floatingResizeHandle.userInteractionEnabled = NO;
    self.floatingExternalActivationArmed = NO;
    self.floatingFullscreenActivationArmed = NO;
    self.lastObservedFrontmostIdentifier = nil;
    self.floatingDockReady = NO;
    ((FLMFloatingWindow *)self.floatingWindow)
        .passesTouchesOutsideFloatingContent = NO;
    // Both close recognizers are disabled before any asynchronous animation
    // begins. The close token, not launchGeneration, owns this transaction.
    self.floatingBackdropTap.enabled = NO;
    self.floatingDockTap.enabled = NO;
    self.floatingDockDragPress.enabled = NO;
    self.floatingDockInputGesture.enabled = NO;
    self.floatingDockInputGeneration += 1;
    [self updateFloatingDockTouchGate];
    self.floatingDockShadowView.hidden = YES;
    self.floatingDockShadowView.alpha = 0.0;
    self.floatingDockShadowView.transform = CGAffineTransformIdentity;
    self.floatingDockInteractionShield.hidden = YES;
    self.floatingDockInteractionShield.userInteractionEnabled = NO;
    self.floatingHandle.hidden = NO;
    self.floatingContainer.layer.borderWidth = 0.0;
    self.floatingContainer.transform = CGAffineTransformIdentity;
    id scene = self.floatingScene;
    id presenter = self.floatingPresenter;
    UIView *host = self.floatingHostView;
    UIWindow *previousKeyWindow = self.previousKeyWindow;
    self.floatingClosingScene = scene;
    self.floatingClosingPresenter = presenter;
    self.floatingClosingHostView = host;
    self.floatingSceneEntity = nil;
    self.floatingSceneHandle = nil;
    self.floatingScene = nil;
    self.floatingHostReferenceSize = CGSizeZero;
    self.floatingPresentationManager = nil;
    self.floatingPresenter = nil;
    self.floatingPresenterScene = nil;
    self.floatingPresenterUnavailableAt = 0.0;
    self.floatingPresenterRetryAttempt = 0;
    self.floatingIdentifier = nil;
    self.floatingExclusiveGesture.enabled = NO;
    self.floatingExclusiveTapEligible = NO;
    self.cornerGuardGesture.enabled = self.enabled;
    self.cornerGesture.enabled = self.enabled;
    self.previousKeyWindow = nil;
    self.floatingKeyboardVisible = NO;
    self.floatingKeyboardFrame = CGRectNull;
    self.floatingBackdropTap.additionalProtectedFrame = CGRectNull;
    ((FLMFloatingWindow *)self.floatingWindow).keyboardPassThroughFrame = CGRectNull;
    if (previousKeyWindow && previousKeyWindow != self.floatingWindow) {
        [previousKeyWindow makeKeyWindow];
    }
    if (self.floatingWindow.hidden) {
        [self finishFloatingCloseWithToken:closeToken];
        return;
    }

    [self beginFloatingHighRefreshLeaseForDuration:0.24];
    [UIView animateWithDuration:0.24
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         self.floatingDimView.alpha = 0.0;
                          self.floatingContainer.alpha = 0.0;
                          self.floatingHandle.alpha = 0.0;
                          self.floatingDockShadowView.alpha = 0.0;
                      }
                     completion:^(BOOL finished) {
                         (void)finished;
                         [self finishFloatingCloseWithToken:closeToken];
                     }];
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(FLMFloatingCloseFallbackDelay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [self finishFloatingCloseWithToken:closeToken];
        });
}

- (void)finishFloatingCloseWithToken:(NSUInteger)token {
    if (!self.floatingCloseInProgress ||
        token != self.floatingActiveCloseToken) {
        FLMDiagnosticLog(
            @"sb centered-close stale-completion token=%lu active=%lu inProgress=%d",
            (unsigned long)token, (unsigned long)self.floatingActiveCloseToken,
            self.floatingCloseInProgress);
        return;
    }
    if (self.floatingCloseCleanupDone) {
        FLMDiagnosticLog(
            @"sb centered-close cleanup-no-op token=%lu reason=already-cleaned",
            (unsigned long)token);
        return;
    }
    self.floatingCloseCleanupDone = YES;
    id scene = self.floatingClosingScene;
    id presenter = self.floatingClosingPresenter;
    UIView *host = self.floatingClosingHostView;
    BOOL keepApplication = self.floatingCloseKeepApplication;
    NSString *queuedIdentifier = [self.floatingQueuedIdentifier copy];
    [host removeFromSuperview];
    self.floatingHostView = nil;
    // Tear down SpringBoard's remote presenter before asking the Scene to
    // background. The previous order let the Scene receive a background
    // transaction while its old presenter still owned the remote surface,
    // which could leave notification activation and reply delivery attached
    // to a stale hosting generation.
    @try {
        if ([presenter respondsToSelector:@selector(deactivate)]) {
            [presenter deactivate];
        }
        if ([presenter respondsToSelector:@selector(invalidate)]) {
            [presenter invalidate];
        }
    } @catch (__unused NSException *exception) {
    }
    if (keepApplication) {
        [self backgroundFloatingScene:scene];
    } else {
        FLMClearProtectedScene(scene);
    }
    // Keep the application blocked through the close animation and host
    // teardown. Clearing here prevents a fading Dock card from receiving one
    // last content touch while still allowing the retained/fullscreen app to
    // resume as soon as presenter ownership has ended.
    FLMPublishDockInputBlockState(nil, NO, @"close-cleanup");
    self.floatingClosingScene = nil;
    self.floatingClosingPresenter = nil;
    self.floatingClosingHostView = nil;
    self.floatingQueuedIdentifier = nil;
    NSString *queuedFullscreenIdentifier =
        [self.floatingQueuedFullscreenIdentifier copy];
    self.floatingQueuedFullscreenIdentifier = nil;
    self.floatingWindow.hidden = YES;
    [self updateFloatingDockTouchGate];
    self.floatingLaunchState = FLMFloatingLaunchStateIdle;
    self.floatingDimView.alpha = 1.0;
    self.floatingContainer.alpha = 1.0;
    self.floatingContainer.transform = CGAffineTransformIdentity;
    self.floatingHandle.alpha = 1.0;
    self.floatingLaunchCoverView.hidden = YES;
    self.floatingLaunchCoverView.alpha = 1.0;
    self.floatingLaunchCoverView.userInteractionEnabled = NO;
    self.floatingLaunchIconView.image = nil;
    self.floatingStatusLabel.hidden = YES;
    self.floatingCloseInProgress = NO;
    self.floatingActiveCloseToken = 0;
    self.floatingFullscreenActivationArmed = NO;
    FLMDiagnosticLog(
        @"sb centered-close cleanup-once token=%lu scene=%@ presenter=%p queuedTarget=%@",
        (unsigned long)token, FLMSceneIdentifier(scene) ?: @"<none>",
        (__bridge void *)presenter,
        queuedFullscreenIdentifier ?: queuedIdentifier ?: @"<none>");
    [self clearFloatingOrientationContract];
    FLMScheduleKeyboardSharedStateWrite();
    [self stopLockMonitoringIfIdle];
    if (queuedFullscreenIdentifier.length > 0 && !FLMDeviceIsLocked()) {
        FLMDiagnosticLog(
            @"sb fullscreen-fallback dequeue target=%@ closeToken=%lu",
            queuedFullscreenIdentifier, (unsigned long)token);
        [self activateIdentifierFullscreen:queuedFullscreenIdentifier];
    } else if (queuedIdentifier.length > 0 && !FLMDeviceIsLocked()) {
        // This call occurs only after host removal, Scene background/protection
        // release, and presenter invalidate have all completed.
        FLMDiagnosticLog(
            @"sb centered-open dequeue target=%@ closeToken=%lu",
            queuedIdentifier, (unsigned long)token);
        [self openFloatingIdentifier:queuedIdentifier];
    }
}

- (void)beginLockMonitoring {
    if (self.lockMonitorTimer.valid) {
        return;
    }
    // Lock transitions arrive on the Darwin lock-state channel and are handled
    // immediately. The timer below is only a low-frequency fallback and keeps
    // driving external-frontmost detection; 1 Hz with a wide tolerance lets
    // the system coalesce the wakeup instead of a 3 Hz heartbeat.
    static dispatch_once_t lockStateObserverOnceToken;
    dispatch_once(&lockStateObserverOnceToken, ^{
        static int lockStateToken = -1;
        if (notify_register_dispatch("com.apple.springboard.lockstate",
                                     &lockStateToken,
                                     dispatch_get_main_queue(),
                                     ^(int token) {
                                         (void)token;
                                         [[FLMWheelController sharedController]
                                             checkLockState:nil];
                                     }) != NOTIFY_STATUS_OK) {
            lockStateToken = -1;
        }
    });
    self.lockMonitorTimer =
        [NSTimer timerWithTimeInterval:1.0
                               target:self
                             selector:@selector(checkLockState:)
                             userInfo:nil
                              repeats:YES];
    self.lockMonitorTimer.tolerance = 0.25;
    [[NSRunLoop mainRunLoop] addTimer:self.lockMonitorTimer
                              forMode:NSRunLoopCommonModes];
}

- (void)stopLockMonitoringIfIdle {
    if (self.wheelPinned || !self.floatingWindow.hidden) {
        return;
    }
    [self.lockMonitorTimer invalidate];
    self.lockMonitorTimer = nil;
}

- (void)checkLockState:(NSTimer *)timer {
    (void)timer;
    // Reuse the existing active-card monitor. No additional timer is created,
    // and capture-off performs no CPU sampling. cpuPct is SpringBoard only.
    static CFTimeInterval lastSampleTime = 0;
    static double lastCPUTime = 0;
    if (!FLMDiagnosticCaptureEnabled()) {
        lastSampleTime = 0;
    } else {
        CFTimeInterval now = CACurrentMediaTime();
        if (lastSampleTime == 0 || now - lastSampleTime >= 5.0) {
            struct rusage usage = {};
            if (getrusage(RUSAGE_SELF, &usage) == 0) {
                double cpuTime = usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 +
                                 usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
                if (lastSampleTime > 0) {
                    FLMDiagnosticLog(
                        @"sb energy-sample interval=%.2f cpuPct=%.2f thermal=%ld docked=%d hidden=%d protected=%d inputLinkActive=%d highRefreshActive=%d",
                        now - lastSampleTime,
                        MAX(0.0, 100.0 * (cpuTime - lastCPUTime) / (now - lastSampleTime)),
                        (long)[NSProcessInfo processInfo].thermalState,
                        self.floatingDocked, self.floatingDockHidden,
                        FLMProtectedSceneIsAlive(),
                        self.floatingDockInputDisplayLink != nil && !self.floatingDockInputDisplayLink.paused,
                        self.floatingHighRefreshDisplayLink != nil);
                }
                lastSampleTime = now;
                lastCPUTime = cpuTime;
            }
        }
    }
    [self refreshWheelPriorityWindow];
    if (self.floatingDocked && !self.floatingWindow.hidden &&
        self.floatingIdentifier.length > 0) {
        NSString *frontmostIdentifier = FLMFrontmostApplicationIdentifier();
        BOOL targetIsFrontmost =
            [frontmostIdentifier isEqualToString:self.floatingIdentifier];
        BOOL targetWasFrontmost =
            [self.lastObservedFrontmostIdentifier
                isEqualToString:self.floatingIdentifier];
        if (!targetIsFrontmost) {
            self.floatingExternalActivationArmed = YES;
        }
        self.lastObservedFrontmostIdentifier = frontmostIdentifier;
        if (self.floatingExternalActivationArmed && targetIsFrontmost &&
            !targetWasFrontmost) {
            // The docked app was opened by SpringBoard. Release only our
            // presenter; backgrounding here would black out the fullscreen app.
            self.floatingReconnectSuppressed = YES;
            [self closeFloatingWindowKeepingApplication:NO];
            return;
        }
    }
    if (!FLMDeviceIsLocked()) {
        [self stopLockMonitoringIfIdle];
        return;
    }
    if (self.wheelPinned || !self.overlayWindow.hidden) {
        [self dismissWheelLaunchingItem:nil];
    }
    if (!self.floatingWindow.hidden) {
        [self closeFloatingWindowKeepingApplication:YES];
    }
}

- (void)activateIdentifierFullscreen:(NSString *)identifier {
    if (identifier.length == 0) {
        return;
    }
    NSString *bundleIdentifier = [identifier copy];
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(FLMFloatingFullscreenActivationDelay *
                                NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            UIApplication *application = [UIApplication sharedApplication];
            if ([application respondsToSelector:
                             @selector(launchApplicationWithIdentifier:suspended:)] &&
                [application launchApplicationWithIdentifier:bundleIdentifier
                                                   suspended:NO]) {
                return;
            }
            id workspace =
                [NSClassFromString(@"LSApplicationWorkspace") defaultWorkspace];
            if ([workspace respondsToSelector:
                              @selector(openApplicationWithBundleID:)]) {
                [workspace openApplicationWithBundleID:bundleIdentifier];
            }
        });
}

- (void)activateIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:FLYME_LOCK_SCREEN_ITEM]) {
        UIApplication *application = [UIApplication sharedApplication];
        if ([application respondsToSelector:@selector(_simulateLockButtonPress)]) {
            [application _simulateLockButtonPress];
            return;
        }
        id manager = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
        if ([manager respondsToSelector:@selector(lockUIFromSource:withOptions:)]) {
            [manager lockUIFromSource:1 withOptions:nil];
        }
        return;
    }
    if (!self.floatingWindow.hidden && self.floatingIdentifier.length > 0 &&
        [identifier isEqualToString:self.floatingIdentifier]) {
        // The wheel target is the app already sitting in the card. Dismiss the
        // card and promote the running app straight to fullscreen instead of
        // swallowing the request.
        self.prewarmedIdentifier = nil;
        if (self.floatingCloseInProgress) {
            self.floatingQueuedFullscreenIdentifier = [identifier copy];
            return;
        }
        FLMDiagnosticLog(
            @"sb wheel-promote target=%@ closeToken=%lu card=%@",
            identifier, (unsigned long)self.floatingActiveCloseToken,
            self.floatingDocked
                ? (self.floatingDockHidden ? @"hidden" : @"docked")
                : @"centered");
        self.floatingQueuedFullscreenIdentifier = [identifier copy];
        [self closeFloatingWindowKeepingApplication:YES];
        return;
    }
    if ([identifier isEqualToString:FLMFrontmostApplicationIdentifier()]) {
        self.prewarmedIdentifier = nil;
        return;
    }
    [self openFloatingIdentifier:identifier];
}

@end

static BOOL FLMHomeDockZoneHitTest(CGRect bounds, CGPoint point) {
    FLMWheelController *controller = [FLMWheelController sharedController];
    if (!controller.enabled || controller.wheelPinned ||
        !controller.floatingWindow.hidden || controller.floatingCloseInProgress ||
        FLMDeviceIsLocked()) {
        return NO;
    }
    if (point.x < CGRectGetMinX(bounds) + CGRectGetWidth(bounds) * 0.30 ||
        point.x > CGRectGetMinX(bounds) + CGRectGetWidth(bounds) * 0.70 ||
        point.y < CGRectGetMaxY(bounds) - 100.0) {
        return NO;
    }
    NSString *frontmost = FLMFrontmostApplicationIdentifier();
    if (frontmost.length == 0 ||
        [frontmost isEqualToString:@"com.apple.springboard"] ||
        [frontmost isEqualToString:FLYME_LOCK_SCREEN_ITEM]) {
        return NO;
    }
    return YES;
}

%hook _UIKeyboardLayerHostView

- (void)scene:(id)scene
    didUpdateClientSettingsWithDiff:(id)diff
                  oldClientSettings:(id)oldClientSettings
                  transitionContext:(id)transitionContext {
    %orig;
    (void)diff;
    (void)oldClientSettings;
    (void)transitionContext;

    // UIKit must finish its private keyboard Scene transaction before the host
    // changes superviews.  Moving it synchronously is what leaves the remote
    // keyboard half-paired and makes keys or the collapse control stop routing.
    FLMWheelController *controller = [FLMWheelController sharedController];
    NSUInteger sessionGeneration =
        controller.floatingKeyboardSessionGeneration;
    if (sessionGeneration == 0 || controller.floatingWindow.hidden ||
        controller.floatingDocked || controller.floatingCloseInProgress) {
        return;
    }
    FLMDiagnosticLog(
        @"sb host-hook callback host=%p updatedScene=%@ session=%lu",
        (__bridge void *)self, FLMSceneIdentifier(scene) ?: @"<none>",
        (unsigned long)sessionGeneration);
    __weak UIView *weakHostView = (UIView *)self;
    __weak id weakUpdatedScene = scene;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *hostView = weakHostView;
        id updatedScene = weakUpdatedScene;
        if (!hostView) {
            FLMDiagnosticLog(
                @"sb host-hook expired updatedScene=%@ session=%lu",
                FLMSceneIdentifier(updatedScene) ?: @"<none>",
                (unsigned long)sessionGeneration);
            return;
        }
        [controller keyboardLayerHostView:hostView
                        didUpdateForScene:updatedScene
                        sessionGeneration:sessionGeneration];
    });
}

%end

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    (void)application;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [[FLMWheelController sharedController] start];
                   });
    // Diagnostics are deliberately initialized after SpringBoard launch and
    // away from keyboard host callbacks. UIKit clients only publish compact
    // Darwin events; this process is the sole asynchronous file writer.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       FLMStartDiagnosticWriter();
                       FLMPublishDiagnosticEvent(
                           FLMDiagnosticRoleSpringBoard,
                           FLMDiagnosticEventProcessReady,
                           0,
                           (uint16_t)(getpid() & 0xFFFF),
                           0);
                   });
}

%end

%ctor {
    // Darwin notification state can outlive a crashed/restarted SpringBoard.
    // Clear it before any card can be presented so no application remains
    // locked by a stale Dock session.
    FLMPublishDockInputBlockState(nil, NO, @"springboard-ctor-reset");
    if (notify_register_check(FLYME_RUNTIME_NOTIFICATION, &FlymeRuntimeToken) ==
        NOTIFY_STATUS_OK) {
        uint64_t state = (FLYME_RUNTIME_MAGIC << 32) | (uint32_t)getpid();
        notify_set_state(FlymeRuntimeToken, state);
        notify_post(FLYME_RUNTIME_NOTIFICATION);
    }
}
