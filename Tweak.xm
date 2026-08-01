#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <notify.h>
#import <objc/message.h>
#import <errno.h>
#import <fcntl.h>
#import <stdarg.h>
#import <stdint.h>
#import <sys/time.h>
#import <unistd.h>

#import "FLMDiagnostics.h"
#import "FLMSceneLifecycle.h"

#define FLYME_RUNTIME_NOTIFICATION "com.codex.flymemultitasking.runtime"
#define FLYME_PREFERENCES_NOTIFICATION CFSTR("com.codex.flymemultitasking.preferences-changed")
#define FLYME_PREFERENCES_DOMAIN CFSTR("com.codex.flymemultitasking")
#define FLYME_KEYBOARD_NOTIFICATION "com.codex.flymemultitasking.keyboard-state-changed"
#define FLYME_KEYBOARD_SCENE_NOTIFICATION "com.codex.flymemultitasking.keyboard-scene-changed"
#define FLYME_KEYBOARD_SESSION_NOTIFICATION "com.codex.flymemultitasking.keyboard-session-changed"
#define FLYME_KEYBOARD_FRAME_NOTIFICATION "com.codex.flymemultitasking.keyboard-frame-changed"
#define FLYME_KEYBOARD_AVOIDANCE_NOTIFICATION "com.codex.flymemultitasking.keyboard-avoidance-changed"
#define FLYME_KEYBOARD_CARD_GEOMETRY_NOTIFICATION "com.codex.flymemultitasking.keyboard-card-geometry-changed"
#define FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION "com.codex.flymemultitasking.keyboard-dismiss-acknowledged"
#define FLYME_RUNTIME_MAGIC 0x464C594DULL
#define FLYME_LOCK_SCREEN_ITEM @"com.codex.flymemultitasking.lockscreen"

static const char *FLMDiagnosticPrimaryPath =
    "/var/jb/var/mobile/Documents/FlymeMultitasking-Diagnostic.log";
static const char *FLMDiagnosticFallbackPath =
    "/var/mobile/Documents/FlymeMultitasking-Diagnostic.log";
static dispatch_queue_t FLMDiagnosticWriterQueue;
static BOOL FLMDiagnosticWriterReady = NO;
static int FLMDiagnosticReceiverToken = -1;

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
        default: return "unknown-event";
    }
}

static int FLMOpenDiagnosticFile(void) {
    int descriptor = open(FLMDiagnosticPrimaryPath,
                          O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                          0644);
    if (descriptor >= 0) {
        return descriptor;
    }
    return open(FLMDiagnosticFallbackPath,
                O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                0644);
}

static void FLMAppendDiagnosticLineNow(NSString *message) {
    if (message.length == 0) {
        return;
    }
    struct timeval now;
    gettimeofday(&now, NULL);
    NSString *line =
        [NSString stringWithFormat:@"%lld.%03d pid=%d %@\n",
                                   (long long)now.tv_sec,
                                   (int)(now.tv_usec / 1000),
                                   getpid(),
                                   message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) {
        return;
    }
    int descriptor = FLMOpenDiagnosticFile();
    if (descriptor < 0) {
        return;
    }
    const uint8_t *bytes = data.bytes;
    size_t remaining = data.length;
    while (remaining > 0) {
        ssize_t written = write(descriptor, bytes, remaining);
        if (written > 0) {
            bytes += written;
            remaining -= (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        break;
    }
    close(descriptor);
}

static void FLMEnqueueDiagnosticLine(NSString *format, ...) {
    if (!FLMDiagnosticWriterReady || !FLMDiagnosticWriterQueue ||
        format.length == 0) {
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
    });
}

static void FLMStartDiagnosticWriter(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FLMDiagnosticWriterQueue =
            dispatch_queue_create("com.codex.flymemultitasking.diagnostic-writer",
                                  DISPATCH_QUEUE_SERIAL);
        uint32_t status = notify_register_dispatch(
            FLYME_DIAGNOSTIC_EVENT_NOTIFICATION,
            &FLMDiagnosticReceiverToken,
            FLMDiagnosticWriterQueue,
            ^(__unused int token) {
                uint64_t state = 0;
                if (FLMDiagnosticReceiverToken < 0 ||
                    notify_get_state(FLMDiagnosticReceiverToken, &state) !=
                        NOTIFY_STATUS_OK) {
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
                        FLMDiagnosticRoleName(role),
                        FLMDiagnosticEventName(event),
                        session, first, second,
                        (unsigned long long)state]);
            });
        FLMDiagnosticWriterReady = YES;
        dispatch_async(FLMDiagnosticWriterQueue, ^{
            @autoreleasepool {
                FLMAppendDiagnosticLineNow(
                    @"logger-ready build=0.8.29-diagnostic1 schema=2");
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
static const CGFloat FLMDefaultDockWidth = 156.0;
static const CGFloat FLMMinimumDockWidth = 156.0;
static const CGFloat FLMMaximumDockWidth = 270.0;
static const CGFloat FLMDockSideMargin = 10.0;
static const CGFloat FLMDockTopMargin = 8.0;
static const CGFloat FLMCenteredDockActivationDistance = 110.0;
static const NSTimeInterval FLMFloatingLaunchTimeout = 6.5;
static const NSTimeInterval FLMFloatingSceneSettleDelay = 0.18;
static const NSTimeInterval FLMFloatingSceneGenerationDelay = 0.75;
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
- (NSInteger)currentInterfaceOrientation;
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

static UIInterfaceOrientation FLMActiveInterfaceOrientation(void) {
    UIInterfaceOrientation portraitCandidate = UIInterfaceOrientationUnknown;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            if (scene.activationState == UISceneActivationStateForegroundActive ||
                scene.activationState == UISceneActivationStateForegroundInactive) {
                UIInterfaceOrientation orientation =
                    ((UIWindowScene *)scene).interfaceOrientation;
                if (UIInterfaceOrientationIsLandscape(orientation)) {
                    return orientation;
                }
                if (orientation != UIInterfaceOrientationUnknown) {
                    portraitCandidate = orientation;
                }
            }
        }
    }
    UIApplication *application = [UIApplication sharedApplication];
    SEL statusBarSelector = NSSelectorFromString(@"statusBarOrientation");
    if ([application respondsToSelector:statusBarSelector]) {
        UIInterfaceOrientation (*orientationGetter)(id, SEL) =
            (UIInterfaceOrientation (*)(id, SEL))
                [application methodForSelector:statusBarSelector];
        UIInterfaceOrientation statusBarOrientation =
            orientationGetter
                ? orientationGetter(application, statusBarSelector)
                : UIInterfaceOrientationUnknown;
        if (UIInterfaceOrientationIsLandscape(statusBarOrientation)) {
            return statusBarOrientation;
        }
        if (statusBarOrientation != UIInterfaceOrientationUnknown) {
            portraitCandidate = statusBarOrientation;
        }
    }
    UIDeviceOrientation deviceOrientation = [UIDevice currentDevice].orientation;
    if (deviceOrientation == UIDeviceOrientationLandscapeLeft) {
        return UIInterfaceOrientationLandscapeRight;
    }
    if (deviceOrientation == UIDeviceOrientationLandscapeRight) {
        return UIInterfaceOrientationLandscapeLeft;
    }
    if (deviceOrientation == UIDeviceOrientationPortraitUpsideDown) {
        return UIInterfaceOrientationPortraitUpsideDown;
    }
    return portraitCandidate != UIInterfaceOrientationUnknown
               ? portraitCandidate
               : UIInterfaceOrientationPortrait;
}

static CGRect FLMVisualScreenBounds(void) {
    CGRect bounds = [UIScreen mainScreen].bounds;
    UIInterfaceOrientation orientation = FLMActiveInterfaceOrientation();
    BOOL targetLandscape = UIInterfaceOrientationIsLandscape(orientation);
    BOOL boundsLandscape =
        CGRectGetWidth(bounds) > CGRectGetHeight(bounds);
    if (targetLandscape && !boundsLandscape) {
        bounds.size = CGSizeMake(bounds.size.height, bounds.size.width);
    }
    return bounds;
}

static CGPoint FLMVisualPointFromRawPoint(CGPoint rawPoint) {
    CGRect rawBounds = [UIScreen mainScreen].bounds;
    UIInterfaceOrientation orientation = FLMActiveInterfaceOrientation();
    BOOL targetLandscape = UIInterfaceOrientationIsLandscape(orientation);
    BOOL rawBoundsLandscape =
        CGRectGetWidth(rawBounds) > CGRectGetHeight(rawBounds);
    if (rawBoundsLandscape || !targetLandscape) {
        return rawPoint;
    }

    CGFloat rawWidth = CGRectGetWidth(rawBounds);
    CGFloat rawHeight = CGRectGetHeight(rawBounds);
    if (orientation == UIInterfaceOrientationLandscapeLeft) {
        return CGPointMake(rawPoint.y, rawWidth - rawPoint.x);
    }
    if (orientation == UIInterfaceOrientationLandscapeRight) {
        return CGPointMake(rawHeight - rawPoiëÎºŞÚ$z{-®éÜj×6VÆbæfÆöF–æt†÷7E&VfW&Væ6U6—¦Rçv–GF‚À¢6VÆbæfÆöF–æt†÷7E&VfW&Væ6U6—¦Ræ†V–v‡B“°§Ğ ¢Ò‡fö–B–f–ÄfÆöF–ætÆVæ6„f÷$–FVçF–f–W#¢„å57G&–ær¢––FVçF–f–W ¢vVæW&F–öã¢„å5T–çFVvW"–vVæW&F–öâ°¢–b†vVæW&F–öâÒ6VÆbæfÆöF–ætÆVæ6„vVæW&F–öâÇÀ¢6VÆbæfÆöF–æuv–æF÷ræ†–FFVâ’°¢&WGW&ã°¢Ğ¢òò–çfÆ–FFRFVÆ–VB&WG&–W2&Vf÷&R&VÆV6–ærF†R&÷FV7F–öâÆV6Râ¢òò&WG'’g&öÒ&–÷"ÆVæ6‚×W7BæWfW"GF6‚&WÆ6VB&–Ö'’66VæRà¢6VÆbæfÆöF–ætÆVæ6…7FFRÒdÄÔfÆöF–ætÆVæ6…7FFTf–Æ–æs°¢6VÆbæfÆöF–æu&V6öææV7E7W&W76VBÒ”U3°¢·6VÆb6Æ÷6TfÆöF–æuv–æF÷t¶VW–ætÆ–6F–öã¥”U5Ó°¢·6VÆb7F—fFT–FVçF–f–W$gVÆÇ67&VVã¦–FVçF–f–W%Ó°§Ğ ¢Ò‡fö–B–6Æ÷6TfÆöF–æuv–æF÷t¶VW–ætÆ–6F–öã¢„$ôôÂ–¶VWÆ–6F–öâ°¢dÄÔVçVWVTF–væ÷7F–4Æ–æR€¢'6"6VçFW&VBÖ6Æ÷6R&Vv–â¶VWÒVBÒT66VæSÒTÆVæ6„vVãÒVÇR6W76–öãÒVÇR¶W–&ö&Ef—6–&ÆSÒVB–çFW&7F–öãÒVB†÷7CÒWf÷'v&F–æt¶W“ÒVB"À¢¶VWÆ–6F–öâÂ6VÆbæfÆöF–æt–FVçF–f–W"ó¢#ÆæöæSâ"À¢dÄÕ66VæT–FVçF–f–W"‡6VÆbæfÆöF–æu66VæR’ó¢#ÆæöæSâ"À¢‡Vç6–væVBÆöær—6VÆbæfÆöF–ætÆVæ6„vVæW&F–öâÀ¢‡Vç6–væVBÆöær—6VÆbæfÆöF–æt¶W–&ö&E6W76–öävVæW&F–öâÀ¢6VÆbæfÆöF–æt¶W–&ö&Ef—6–&ÆRÀ¢6VÆbæfÆöF–æt¶W–&ö&D–çFW&7F–öå6W76–öä7F—fRÀ¢…õö'&–FvRfö–B¢—6VÆbæfÆöF–æt¶W–&ö&DÆ–W$†÷7Ef–WrÀ¢6VÆbæ¶W–&ö&Df÷'v&F–æuv–æF÷ræ—4¶W•v–æF÷r“°¢·6VÆbVæDfÆöF–æt¶W–&ö&E6W76–öåÓ°¢6VÆbæfÆöF–ætÆVæ6„vVæW&F–öâ³Ò°¢6VÆbæfÆöF–ætÆVæ6…7FFRÒdÄÔfÆöF–ætÆVæ6…7FFT6Æ÷6–æs°¢6VÆbæfÆöF–ætÆVæ6…7F'FVDBÒã°¢6VÆbæfÆöF–æu66VæU&W&VDBÒã°¢·6VÆbæfÆöF–æt–çFW&7F—fU6æ6†÷B&VÖ÷fTg&öÕ7WW'f–WuÓ°¢6VÆbæfÆöF–æt–çFW&7F—fU6æ6†÷BÒæ–Ã°¢6VÆbæfÆöF–æt–çFW&7F—fU6æ6†÷D&6¶w&÷VæBÒæ–Ã°¢6VÆbæfÆöF–æt–çFW&7F—fU6æ6†÷D6öçFVçBÒæ–Ã°¢6VÆbæfÆöF–ætgVÆÇ67&VVå&öw&W72Òã°¢6VÆbæfÆöF–æt¶W–&ö&D–çFW&7F–öävVæW&F–öâ³Ò°¢6VÆbæfÆöF–æt¶W–&ö&D–çFW&7F–öå6W76–öä7F—fRÒäó°¢6VÆbæfÆöF–æt–çFW&7F—fU66VæU&W&VBÒäó°¢6VÆbæfÆöF–æt–çFW&7F—fTgVÆÇ67&VVåG&ç6—F–öâÒäó°¢6VÆbæfÆöF–ætFö6¶VBÒäó°¢6VÆbæfÆöF–ætFö6µG&ç6—F–öä7F—fRÒäó°¢6VÆbæfÆöF–ætW‡FW&æÄ7F—fF–öä&ÖVBÒäó°¢6VÆbæÆ7Dö'6W'fVDg&öçFÖ÷7D–FVçF–f–W"Òæ–Ã°¢6VÆbæfÆöF–æu&W6—¦T6VçFW%&VG’Òäó°¢·6VÆb6WDfÆöF–ætFö6µ&VG“¤äòæ–ÖFVC¤äõÓ°¢‚„dÄÔfÆöF–æuv–æF÷r¢—6VÆbæfÆöF–æuv–æF÷r¢ç76W5F÷V6†W4÷WG6–FTfÆöF–æt6öçFVçBÒäó°¢6VÆbæfÆöF–æt&6¶G&÷FæVæ&ÆVBÒ”U3°¢6VÆbæfÆöF–ætFö6µFæVæ&ÆVBÒäó°¢6VÆbæfÆöF–ætFö6´G&u&W72æVæ&ÆVBÒäó°¢6VÆbæfÆöF–æu&W6—¦U&W72æVæ&ÆVBÒäó°¢6VÆbæfÆöF–ætFö6´–çWDvW7GW&RæVæ&ÆVBÒäó°¢6VÆbæfÆöF–ætFö6´–çWDvVæW&F–öâ³Ò°¢6VÆbæfÆöF–æu&W6—¦T†æFÆRæ†–FFVâÒ”U3°¢6VÆbæfÆöF–æu&W6—¦T†æFÆRæÇ†Òã°¢6VÆbæfÆöF–ætFö6µ6†F÷uf–Wræ†–FFVâÒ”U3°¢6VÆbæfÆöF–ætFö6µ6†F÷uf–WræÇ†Òã°¢6VÆbæfÆöF–ætFö6µ6†F÷uf–WrçG&ç6f÷&ÒÒ4tff–æUG&ç6f÷&Ô–FVçF—G“°¢6VÆbæfÆöF–ætFö6´–çFW&7F–öå6†–VÆBæ†–FFVâÒ”U3°¢6VÆbæfÆöF–ætFö6´–çFW&7F–öå6†–VÆBçW6W$–çFW&7F–öäVæ&ÆVBÒäó°¢6VÆbæfÆöF–æt†æFÆRæ†–FFVâÒäó°¢6VÆbæfÆöF–æt6öçF–æW"æÆ–W"æ&÷&FW%v–GF‚Òã°¢6VÆbæfÆöF–æt6öçF–æW"çG&ç6f÷&ÒÒ4tff–æUG&ç6f÷&Ô–FVçF—G“°¢å5T–çFVvW"vVæW&F–öâÒ6VÆbæfÆöF–ætÆVæ6„vVæW&F–öã°¢–B66VæRÒ6VÆbæfÆöF–æu66VæS°¢–B&W6VçFW"Ò6VÆbæfÆöF–æu&W6VçFW#°¢T•v–æF÷r§&Wf–÷W4¶W•v–æF÷rÒ6VÆbç&Wf–÷W4¶W•v–æF÷s°¢6VÆbæfÆöF–æu66VæTVçF—G’Òæ–Ã°¢6VÆbæfÆöF–æu66VæT†æFÆRÒæ–Ã°¢6VÆbæfÆöF–æu66VæRÒæ–Ã°¢6VÆbæfÆöF–æt†÷7E&VfW&Væ6U6—¦RÒ4u6—¦U¦W&ó°¢6VÆbæfÆöF–æu&W6VçFF–öäÖævW"Òæ–Ã°¢6VÆbæfÆöF–æu&W6VçFW"Òæ–Ã°¢6VÆbæfÆöF–æt–FVçF–f–W"Òæ–Ã°¢6VÆbæfÆöF–ætW†6ÇW6—fTvW7GW&RæVæ&ÆVBÒäó°¢6VÆbæfÆöF–ætW†6ÇW6—fUFVÆ–v–&ÆRÒäó°¢6VÆbæ6÷&æW$wV&DvW7GW&RæVæ&ÆVBÒ6VÆbæVæ&ÆVC°¢6VÆbæ6÷&æW$vW7GW&RæVæ&ÆVBÒ6VÆbæVæ&ÆVC°¢6VÆbç&Wf–÷W4¶W•v–æF÷rÒæ–Ã°¢6VÆbæfÆöF–æt¶W–&ö&Ef—6–&ÆRÒäó°¢6VÆbæfÆöF–æt¶W–&ö&DF—6Ö—75&WVW7DvVæW&F–öâ³Ò°¢6VÆbæfÆöF–æt¶W–&ö&DF—6Ö—75&WVW7D7F—fRÒäó°¢6VÆbæfÆöF–æt¶W–&ö&Dg&ÖRÒ4u&V7DçVÆÃ°¢6VÆbæfÆöF–æt&6¶G&÷FæFF—F–öæÅ&÷FV7FVDg&ÖRÒ4u&V7DçVÆÃ°¢‚„dÄÔfÆöF–æuv–æF÷r¢—6VÆbæfÆöF–æuv–æF÷r’æ¶W–&ö&E75F‡&÷Vv„g&ÖRÒ4u&V7DçVÆÃ°¢–b‡&Wf–÷W4¶W•v–æF÷rbb&Wf–÷W4¶W•v–æF÷rÒ6VÆbæfÆöF–æuv–æF÷r’°¢·&Wf–÷W4¶W•v–æF÷rÖ¶T¶W•v–æF÷uÓ°¢Ğ¢–b‡6VÆbæfÆöF–æuv–æF÷ræ†–FFVâ’°¢·6VÆbæfÆöF–æt†÷7Ef–Wr&VÖ÷fTg&öÕ7WW'f–WuÓ°¢6VÆbæfÆöF–æt†÷7Ef–WrÒæ–Ã°¢–b†¶VWÆ–6F–öâ’°¢·6VÆb&6¶w&÷VæDfÆöF–æu66VæS§66VæUÓ°¢ÒVÇ6R°¢dÄÔ6ÆV%&÷FV7FVE66VæR‡66VæR“°¢Ğ¢G'’°¢–b…·&W6VçFW"&W7öæG5Fõ6VÆV7F÷#¤6VÆV7F÷"†FV7F—fFR•Ò’°¢·&W6VçFW"FV7F—fFUÓ°¢Ğ¢–b…·&W6VçFW"&W7öæG5Fõ6VÆV7F÷#¤6VÆV7F÷"†–çfÆ–FFR•Ò’°¢·&W6VçFW"–çfÆ–FFUÓ°¢Ğ¢Ò6F6‚…õ÷VçW6VBå4W†6WF–öâ¦W†6WF–öâ’°¢Ğ¢6VÆbæfÆöF–ætÆVæ6„6÷fW%f–Wræ†–FFVâÒ”U3°¢6VÆbæfÆöF–ætÆVæ6„6÷fW%f–WræÇ†Òã°¢6VÆbæfÆöF–ætÆVæ6„6÷fW%f–WrçW6W$–çFW&7F–öäVæ&ÆVBÒäó°¢6VÆbæfÆöF–ætÆVæ6„–6öåf–Wræ–ÖvRÒæ–Ã°¢6VÆbæfÆöF–æu7FGW4Æ&VÂæ†–FFVâÒ”U3°¢6VÆbæfÆöF–ætÆVæ6…7FFRÒdÄÔfÆöF–ætÆVæ6…7FFT–FÆS°¢·6VÆb7F÷Æö6´Ööæ—F÷&–æt–d–FÆUÓ°¢&WGW&ã°¢Ğ ¢µT•f–Wræ–ÖFUv—F„GW&F–öã£ã#@¢FVÆ“£ã ¢÷F–öç3¥T•f–Wtæ–ÖF–öä÷F–öä&Vv–äg&öÔ7W'&VçE7FFRÀ¢T•f–Wtæ–ÖF–öä÷F–öä7W'fTV6T÷W@¢æ–ÖF–öç3¥ç°¢6VÆbæfÆöF–ætF–Õf–WræÇ†Òã°¢6VÆbæfÆöF–æt6öçF–æW"æÇ†Òã°¢6VÆbæfÆöF–æt†æFÆRæÇ†Òã°¢6VÆbæfÆöF–ætFö6µ6†F÷uf–WræÇ†Òã°¢6VÆbæfÆöF–æu&W6—¦T†æFÆRæÇ†Òã°¢Ğ¢6ö×ÆWF–öã¥â„$ôôÂf–æ—6†VB’°¢‡fö–B–f–æ—6†VC°¢–b†vVæW&F–öâÒ6VÆbæfÆöF–ætÆVæ6„vVæW&F–öâ’°¢&WGW&ã°¢Ğ¢·6VÆbæfÆöF–æt†÷7Ef–Wr&VÖ÷fTg&öÕ7WW'f–WuÓ°¢6VÆbæfÆöF–æt†÷7Ef–WrÒæ–Ã°¢–b†¶VWÆ–6F–öâ’°¢·6VÆb&6¶w&÷VæDfÆöF–æu66VæS§66VæUÓ°¢ÒVÇ6R°¢dÄÔ6ÆV%&÷FV7FVE66VæR‡66VæR“°¢Ğ¢G'’°¢–b…·&W6VçFW"&W7öæG5Fõ6VÆV7F÷#¤6VÆV7F÷"†FV7F—fFR•Ò’°¢·&W6VçFW"FV7F—fFUÓ°¢Ğ¢–b…·&W6VçFW"&W7öæG5Fõ6VÆV7F÷#¤6VÆV7F÷"†–çfÆ–FFR•Ò’°¢·&W6VçFW"–çfÆ–FFUÓ°¢Ğ¢Ò6F6‚…õ÷VçW6VBå4W†6WF–öâ¦W†6WF–öâ’°¢Ğ¢6VÆbæfÆöF–æuv–æF÷ræ†–FFVâÒ”U3°¢6VÆbæfÆöF–ætÆVæ6…7FFRÒdÄÔfÆöF–ætÆVæ6…7FFT–FÆS°¢6VÆbæfÆöF–ætF–Õf–WræÇ†Òã°¢6VÆbæfÆöF–æt6öçF–æW"æÇ†Òã°¢6VÆbæfÆöF–æt6öçF–æW"çG&ç6f÷&ÒĞ¢4tff–æUG&ç6f÷&Ô–FVçF—G“°¢6VÆbæfÆöF–æt†æFÆRæÇ†Òã°¢6VÆbæfÆöF–ætÆVæ6„6÷fW%f–Wræ†–FFVâÒ”U3°¢6VÆbæfÆöF–ætÆVæ6„6÷fW%f–WræÇ†Òã°¢6VÆbæfÆöF–ætÆVæ6„6÷fW%f–WrçW6W$–çFW&7F–öäVæ&ÆVBÒäó°¢6VÆbæfÆöF–ætÆVæ6„–6öåf–Wræ–ÖvRÒæ–Ã°¢6VÆbæfÆöF–æu7FGW4Æ&VÂæ†–FFVâÒ”U3°¢·6VÆb7F÷Æö6´Ööæ—F÷&–æt–d–FÆUÓ°¢ÕÓ°§Ğ ¢Ò‡fö–B–&Vv–äÆö6´Ööæ—F÷&–ær°¢–b‡6VÆbæÆö6´Ööæ—F÷%F–ÖW"çfÆ–B’°¢&WGW&ã°¢Ğ¢6VÆbæÆö6´Ööæ—F÷%F–ÖW"Ğ¢´å5F–ÖW"F–ÖW%v—F…F–ÖT–çFW'fÃ£ã3P¢F&vWC§6VÆ`¢6VÆV7F÷#¤6VÆV7F÷"†6†V6´Æö6µ7FFS¢¢W6W$–æfó¦æ–À¢&WVG3¥”U5Ó°¢µ´å5'VäÆö÷Ö–å'VäÆö÷ÒFEF–ÖW#§6VÆbæÆö6´Ööæ—F÷%F–ÖW ¢f÷$ÖöFS¤å5'VäÆö÷6öÖÖöäÖöFW5Ó°§Ğ ¢Ò‡fö–B—7F÷Æö6´Ööæ—F÷&–æt–d–FÆR°¢–b‡6VÆbçv†VVÅ–ææVBÇÂ6VÆbæfÆöF–æuv–æF÷ræ†–FFVâ’°¢&WGW&ã°¢Ğ¢·6VÆbæÆö6´Ööæ—F÷%F–ÖW"–çfÆ–FFUÓ°¢6VÆbæÆö6´Ööæ—F÷%F–ÖW"Òæ–Ã°§Ğ ¢Ò‡fö–B–6†V6´Æö6µ7FFS¢„å5F–ÖW"¢—F–ÖW"°¢‡fö–B—F–ÖW#°¢–b‡6VÆbæfÆöF–ætFö6¶VBbb6VÆbæfÆöF–æuv–æF÷ræ†–FFVâb`¢6VÆbæfÆöF–æt–FVçF–f–W"æÆVæwF‚â’°¢å57G&–ær¦g&öçFÖ÷7D–FVçF–f–W"ÒdÄÔg&öçFÖ÷7DÆ–6F–öä–FVçF–f–W"‚“°¢$ôôÂF&vWD—4g&öçFÖ÷7BĞ¢¶g&öçFÖ÷7D–FVçF–f–W"—4WVÅFõ7G&–æs§6VÆbæfÆöF–æt–FVçF–f–W%Ó°¢$ôôÂF&vWEv4g&öçFÖ÷7BĞ¢·6VÆbæÆ7Dö'6W'fVDg&öçFÖ÷7D–FVçF–f–W ¢—4WVÅFõ7G&–æs§6VÆbæfÆöF–æt–FVçF–f–W%Ó°¢–b‚F&vWD—4g&öçFÖ÷7B’°¢6VÆbæfÆöF–ætW‡FW&æÄ7F—fF–öä&ÖVBÒ”U3°¢Ğ¢6VÆbæÆ7Dö'6W'fVDg&öçFÖ÷7D–FVçF–f–W"Òg&öçFÖ÷7D–FVçF–f–W#°¢–b‡6VÆbæfÆöF–ætW‡FW&æÄ7F—fF–öä&ÖVBbbF&vWD—4g&öçFÖ÷7Bb`¢F&vWEv4g&öçFÖ÷7B’°¢òòF†RFö6¶VBv2÷VæVB'’7&–æt&ö&Bâ&VÆV6RöæÇ’÷W ¢òò&W6VçFW#²&6¶w&÷VæF–ær†W&Rv÷VÆB&Æ6²÷WBF†RgVÆÇ67&VVâà¢6VÆbæfÆöF–æu&V6öææV7E7W&W76VBÒ”U3°¢·6VÆb6Æ÷6TfÆöF–æuv–æF÷t¶VW–ætÆ–6F–öã¤äõÓ°¢&WGW&ã°¢Ğ¢Ğ¢–b‚dÄÔFWf–6T—4Æö6¶VB‚’’°¢·6VÆb7F÷Æö6´Ööæ—F÷&–æt–d–FÆUÓ°¢&WGW&ã°¢Ğ¢–b‡6VÆbçv†VVÅ–ææVBÇÂ6VÆbæ÷fW&Æ•v–æF÷ræ†–FFVâ’°¢·6VÆbF—6Ö—75v†VVÄÆVæ6†–æt—FVÓ¦æ–ÅÓ°¢Ğ¢–b‚6VÆbæfÆöF–æuv–æF÷ræ†–FFVâ’°¢·6VÆb6Æ÷6TfÆöF–æuv–æF÷t¶VW–ætÆ–6F–öã¥”U5Ó°¢Ğ§Ğ ¢Ò‡fö–B–7F—fFT–FVçF–f–W$gVÆÇ67&VVã¢„å57G&–ær¢––FVçF–f–W"°¢–b†–FVçF–f–W"æÆVæwF‚ÓÒ’°¢&WGW&ã°¢Ğ¢å57G&–ær¦'VæFÆT–FVçF–f–W"Ò¶–FVçF–f–W"6÷•Ó°¢F—7F6…ögFW"€¢F—7F6…÷F–ÖR„D•5D4…õD”ÔUôäõrÂ†–çCcE÷B’ƒãR¢å4T5õU%õ4T2’’À¢F—7F6…övWEöÖ–å÷VWVR‚’Âç°¢T”Æ–6F–öâ¦Æ–6F–öâÒµT”Æ–6F–öâ6†&VDÆ–6F–öåÓ°¢–b…¶Æ–6F–öâ&W7öæG5Fõ6VÆV7F÷# ¢6VÆV7F÷"†ÆVæ6„Æ–6F–öåv—F„–FVçF–f–W#§7W7VæFVC¢•Òb`¢¶Æ–6F–öâÆVæ6„Æ–6F–öåv—F„–FVçF–f–W#¦'VæFÆT–FVçF–f–W ¢7W7VæFVC¤äõÒ’°¢&WGW&ã°¢Ğ¢–Bv÷&·76RĞ¢´å46Æ74g&öÕ7G&–ær„$Å4Æ–6F–öåv÷&·76R"’FVfVÇEv÷&·76UÓ°¢–b…·v÷&·76R&W7öæG5Fõ6VÆV7F÷# ¢6VÆV7F÷"†÷VäÆ–6F–öåv—F„'VæFÆT”C¢•Ò’°¢·v÷&·76R÷VäÆ–6F–öåv—F„'VæFÆT”C¦'VæFÆT–FVçF–f–W%Ó°¢Ğ¢Ò“°§Ğ ¢Ò‡fö–B–7F—fFT–FVçF–f–W#¢„å57G&–ær¢––FVçF–f–W"°¢–b…¶–FVçF–f–W"—4WVÅFõ7G&–æs¤dÅ”ÔUôÄô4µõ45$TTåô•DTÕÒ’°¢T”Æ–6F–öâ¦Æ–6F–öâÒµT”Æ–6F–öâ6†&VDÆ–6F–öåÓ°¢–b…¶Æ–6F–öâ&W7öæG5Fõ6VÆV7F÷#¤6VÆV7F÷"…÷6–×VÆFTÆö6´'WGFöå&W72•Ò’°¢¶Æ–6F–öâ÷6–×VÆFTÆö6´'WGFöå&W75Ó°¢&WGW&ã°¢Ğ¢–BÖævW"Ò´å46Æ74g&öÕ7G&–ær„%4$Æö6µ67&VVäÖævW""’6†&VD–ç7Fæ6UÓ°¢–b…¶ÖævW"&W7öæG5Fõ6VÆV7F÷#¤6VÆV7F÷"†Æö6µT”g&öÕ6÷W&6S§v—F„÷F–öç3¢•Ò’°¢¶ÖævW"Æö6µT”g&öÕ6÷W&6S£v—F„÷F–öç3¦æ–ÅÓ°¢Ğ¢&WGW&ã°¢Ğ¢–b‚6VÆbæfÆöF–æuv–æF÷ræ†–FFVâbb6VÆbæfÆöF–æt–FVçF–f–W"æÆVæwF‚âb`¢¶–FVçF–f–W"—4WVÅFõ7G&–æs§6VÆbæfÆöF–æt–FVçF–f–W%Ò’°¢6VÆbç&Wv&ÖVD–FVçF–f–W"Òæ–Ã°¢&WGW&ã°¢Ğ¢–b…¶–FVçF–f–W"—4WVÅFõ7G&–æs¤dÄÔg&öçFÖ÷7DÆ–6F–öä–FVçF–f–W"‚•Ò’°¢6VÆbç&Wv&ÖVD–FVçF–f–W"Òæ–Ã°¢&WGW&ã°¢Ğ¢·6VÆb÷VäfÆöF–æt–FVçF–f–W#¦–FVçF–f–W%Ó°§Ğ ¤Væ@ ¢V†öö²õT”¶W–&ö&DÆ–W$†÷7Ef–Wp ¢Ò‡fö–B—66VæS¢†–B—66VæP¢F–EWFFT6Æ–VçE6WGF–æw5v—F„F–fc¢†–B–F–f`¢öÆD6Æ–VçE6WGF–æw3¢†–B–öÆD6Æ–VçE6WGF–æw0¢G&ç6—F–öä6öçFW‡C¢†–B—G&ç6—F–öä6öçFW‡B°¢V÷&–s°¢‡fö–B–F–fc°¢‡fö–B–öÆD6Æ–VçE6WGF–æw3°¢‡fö–B—G&ç6—F–öä6öçFW‡C° ¢òòT”¶—B×W7Bf–æ—6‚—G2&—fFR¶W–&ö&B66VæRG&ç67F–öâ&Vf÷&RF†R†÷7@¢òò6†ævW27WW'f–Ww2âÖ÷f–ær—B7–æ6‡&öæ÷W6Ç’—2v†BÆVfW2F†R&VÖ÷FP¢òò¶W–&ö&B†Æb×—&VBæBÖ¶W2¶W—2÷"F†R6öÆÆ6R6öçG&öÂ7F÷&÷WF–ærà¢dÄÕv†VVÄ6öçG&öÆÆW"¦6öçG&öÆÆW"Ò´dÄÕv†VVÄ6öçG&öÆÆW"6†&VD6öçG&öÆÆW%Ó°¢å5T–çFVvW"6W76–öävVæW&F–öâĞ¢6öçG&öÆÆW"æfÆöF–æt¶W–&ö&E6W76–öävVæW&F–öã°¢dÄÔVçVWVTF–væ÷7F–4Æ–æR€¢'6"†÷7BÖ†öö²6ÆÆ&6²†÷7CÒWWFFVE66VæSÒT6W76–öãÒVÇR"À¢…õö'&–FvRfö–B¢—6VÆbÂdÄÕ66VæT–FVçF–f–W"‡66VæR’ó¢#ÆæöæSâ"À¢‡Vç6–væVBÆöær—6W76–öävVæW&F–öâ“°¢õ÷vV²T•f–Wr§vV´†÷7Ef–WrÒ…T•f–Wr¢—6VÆc°¢õ÷vV²–BvVµWFFVE66VæRÒ66VæS°¢F—7F6…ö7–æ2†F—7F6…övWEöÖ–å÷VWVR‚’Âç°¢T•f–Wr¦†÷7Ef–WrÒvV´†÷7Ef–Ws°¢–BWFFVE66VæRÒvVµWFFVE66VæS°¢–b‚†÷7Ef–Wr’°¢dÄÔVçVWVTF–væ÷7F–4Æ–æR€¢'6"†÷7BÖ†öö²W‡—&VBWFFVE66VæSÒT6W76–öãÒVÇR"À¢dÄÕ66VæT–FVçF–f–W"‡WFFVE66VæR’ó¢#ÆæöæSâ"À¢‡Vç6–væVBÆöær—6W76–öävVæW&F–öâ“°¢&WGW&ã°¢Ğ¢¶6öçG&öÆÆW"¶W–&ö&DÆ–W$†÷7Ef–Ws¦†÷7Ef–Wp¢F–EWFFTf÷%66VæS§WFFVE66VæP¢6W76–öävVæW&F–öã§6W76–öävVæW&F–öåÓ°¢Ò“°§Ğ ¢VVæ@ ¢V†öö²7&–æt&ö&@ ¢Ò‡fö–B–Æ–6F–öäF–Df–æ—6„ÆVæ6†–æs¢†–B–Æ–6F–öâ°¢V÷&–s°¢‡fö–B–Æ–6F–öã°¢F—7F6…ögFW"†F—7F6…÷F–ÖR„D•5D4…õD”ÔUôäõrÂ†–çCcE÷B’ƒã‚¢å4T5õU%õ4T2’’À¢F—7F6…övWEöÖ–å÷VWVR‚’Âç°¢µ´dÄÕv†VVÄ6öçG&öÆÆW"6†&VD6öçG&öÆÆW%Ò7F'EÓ°¢Ò“°¢òòF–væ÷7F–72&RFVÆ–&W&FVÇ’–æ—F–Æ—¦VBgFW"7&–æt&ö&BÆVæ6‚æ@¢òòv’g&öÒ¶W–&ö&B†÷7B6ÆÆ&6·2âT”¶—B6Æ–VçG2öæÇ’V&Æ—6‚6ö×7@¢òòF'v–âWfVçG3²F†—2&ö6W72—2F†R6öÆR7–æ6‡&öæ÷W2f–ÆRw&—FW"à¢F—7F6…ögFW"†F—7F6…÷F–ÖR„D•5D4…õD”ÔUôäõrÂ†–çCcE÷B’ƒãb¢å4T5õU%õ4T2’’À¢F—7F6…övWEöÖ–å÷VWVR‚’Âç°¢dÄÕ7F'DF–væ÷7F–5w&—FW"‚“°¢dÄÕV&Æ—6„F–væ÷7F–4WfVçB€¢dÄÔF–væ÷7F–5&öÆU7&–æt&ö&BÀ¢dÄÔF–væ÷7F–4WfVçE&ö6W75&VG’À¢À¢‡V–çCe÷B’†vWG–B‚’b„dddb’À¢“°¢Ò“°§Ğ ¢VVæ@ ¢V7F÷"°¢–b†æ÷F–g•÷&Vv—7FW%ö6†V6²„dÅ”ÔUõ%TåD”ÔUôäõD”d”4D”ôâÂdfÇ–ÖU'VçF–ÖUFö¶Vâ’ÓĞ¢äõD”e•õ5DEU5ôô²’°¢V–çCcE÷B7FFRÒ„dÅ”ÔUõ%TåD”ÔUôÔt”2ÃÂ3"’Â‡V–çC3%÷B–vWG–B‚“°¢æ÷F–g•÷6WE÷7FFR„fÇ–ÖU'VçF–ÖUFö¶VâÂ7FFR“°¢æ÷F–g•÷÷7B„dÅ”ÔUõ%TåD”ÔUôäõD”d”4D”ôâ“°¢Ğ§Ğ 