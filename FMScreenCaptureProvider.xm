#import "FMScreenCaptureProvider.h"

#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurfaceTypes.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <limits.h>
#import <mach/kern_return.h>
#import <math.h>
#import <stdint.h>

#import "FLMDiagnostics.h"

// iPhoneOS SDKs expose IOSurfaceTypes.h but intentionally omit the C API
// header from the public SDK. These are the small IOSurface declarations used
// by this provider; they are linked from IOSurface.framework at build time.
#ifdef __cplusplus
extern "C" {
#endif
extern const CFStringRef kIOSurfaceAllocSize;
extern const CFStringRef kIOSurfaceBytesPerElement;
extern const CFStringRef kIOSurfaceBytesPerRow;
extern const CFStringRef kIOSurfaceColorSpace;
extern const CFStringRef kIOSurfaceHeight;
extern const CFStringRef kIOSurfacePixelFormat;
extern const CFStringRef kIOSurfaceWidth;
size_t IOSurfaceAlignProperty(CFStringRef property, size_t value);
IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
size_t IOSurfaceGetAllocSize(IOSurfaceRef buffer);
void *IOSurfaceGetBaseAddress(IOSurfaceRef buffer);
size_t IOSurfaceGetBytesPerRow(IOSurfaceRef buffer);
size_t IOSurfaceGetHeight(IOSurfaceRef buffer);
uint32_t IOSurfaceGetPixelFormat(IOSurfaceRef buffer);
size_t IOSurfaceGetWidth(IOSurfaceRef buffer);
kern_return_t IOSurfaceLock(IOSurfaceRef buffer,
                            uint32_t options,
                            uint32_t *seed);
kern_return_t IOSurfaceUnlock(IOSurfaceRef buffer,
                              uint32_t options,
                              uint32_t *seed);
#ifdef __cplusplus
}
#endif

// This target is deliberately a DEBUG POC. The file is overwritten on every
// successful capture so it never becomes a screenshot archive. Remove or set
// this to 0 after the one-shot capture path has been verified on-device.
#ifndef FMSCREEN_CAPTURE_POC_DEBUG
#define FMSCREEN_CAPTURE_POC_DEBUG 1
#endif

static NSString *const FMScreenCapturePOCPrimaryPath =
    @"/var/jb/var/mobile/Library/Preferences/FlymeMultitasking-ScreenSense-POC.png";
static NSString *const FMScreenCapturePOCFallbackPath =
    @"/var/mobile/Library/Preferences/FlymeMultitasking-ScreenSense-POC.png";

typedef void (*FMScreenRenderDisplayFunction)(kern_return_t,
                                                CFStringRef,
                                                IOSurfaceRef,
                                                int,
                                                int);

typedef struct {
    size_t width;
    size_t height;
    UIInterfaceOrientation orientation;
} FMScreenCaptureDimensions;

static UIInterfaceOrientation FMScreenCaptureActiveOrientation(void) {
    UIInterfaceOrientation portraitCandidate = UIInterfaceOrientationUnknown;
    UIApplication *application = [UIApplication sharedApplication];

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            if (scene.activationState != UISceneActivationStateForegroundActive &&
                scene.activationState != UISceneActivationStateForegroundInactive) {
                continue;
            }
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

static BOOL FMScreenCaptureResolveDimensions(FMScreenCaptureDimensions *dimensions) {
    if (!dimensions) {
        return NO;
    }

    // nativeBounds is expressed in physical pixels. Do not use bounds here:
    // on an iPhone 13 Pro bounds is 390x844 while the display is 1170x2532.
    CGRect nativeBounds = [UIScreen mainScreen].nativeBounds;
    CGFloat rawWidth = CGRectGetWidth(nativeBounds);
    CGFloat rawHeight = CGRectGetHeight(nativeBounds);
    if (!isfinite(rawWidth) || !isfinite(rawHeight) ||
        rawWidth < 1.0 || rawHeight < 1.0) {
        return NO;
    }

    UIInterfaceOrientation orientation = FMScreenCaptureActiveOrientation();
    BOOL targetLandscape = UIInterfaceOrientationIsLandscape(orientation);
    BOOL rawLandscape = rawWidth > rawHeight;
    if (targetLandscape != rawLandscape) {
        CGFloat swap = rawWidth;
        rawWidth = rawHeight;
        rawHeight = swap;
    }

    dimensions->width = (size_t)llround(rawWidth);
    dimensions->height = (size_t)llround(rawHeight);
    dimensions->orientation = orientation;
    return dimensions->width > 0 && dimensions->height > 0;
}

static FMScreenRenderDisplayFunction FMScreenCaptureLoadRenderSymbol(void) {
    static FMScreenRenderDisplayFunction renderDisplay = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *quartzCoreHandle =
            dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
                   RTLD_LAZY | RTLD_LOCAL);
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Capture] QuartzCore handle=%p",
            quartzCoreHandle);
        void *symbol = quartzCoreHandle
                           ? dlsym(quartzCoreHandle, "CARenderServerRenderDisplay")
                           : NULL;
        if (!symbol) {
            symbol = dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        }
        if (symbol) {
            renderDisplay = (FMScreenRenderDisplayFunction)symbol;
            FLMEnqueueDiagnosticLine(
                @"[ScreenSense][Capture] render symbol available");
        } else {
            const char *errorText = dlerror();
            FLMEnqueueDiagnosticLine(
                @"[ScreenSense][Capture][ERROR] render symbol unavailable error=%@",
                errorText ? [NSString stringWithUTF8String:errorText]
                          : @"<none>");
        }
        // Keep the handle open for the lifetime of the process. The function
        // pointer remains valid even if another component unloads its image.
        (void)quartzCoreHandle;
    });
    return renderDisplay;
}

static IOSurfaceRef FMScreenCaptureCreateSurface(size_t width,
                                                  size_t height,
                                                  size_t *bytesPerRowOut,
                                                  uint32_t *pixelFormatOut) {
    const size_t bytesPerElement = 4;
    if (width == 0 || height == 0 || width > SIZE_MAX / bytesPerElement) {
        return NULL;
    }

    size_t unalignedBytesPerRow = width * bytesPerElement;
    size_t bytesPerRow =
        IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, unalignedBytesPerRow);
    if (bytesPerRow < unalignedBytesPerRow ||
        bytesPerRow == 0 || height > SIZE_MAX / bytesPerRow) {
        return NULL;
    }

    // IOSurface uses the in-memory four-character value for ARGB. The
    // matching CGImage bitmap info is selected below after the render.
    const uint32_t pixelFormat = 0x42475241U;
    size_t unalignedAllocationSize = bytesPerRow * height;
    size_t allocationSize =
        IOSurfaceAlignProperty(kIOSurfaceAllocSize, unalignedAllocationSize);
    if (allocationSize < unalignedAllocationSize || allocationSize == 0) {
        return NULL;
    }

    NSMutableDictionary *properties = [NSMutableDictionary dictionary];
    properties[(__bridge NSString *)kIOSurfaceWidth] = @(width);
    properties[(__bridge NSString *)kIOSurfaceHeight] = @(height);
    properties[(__bridge NSString *)kIOSurfaceBytesPerElement] =
        @(bytesPerElement);
    properties[(__bridge NSString *)kIOSurfaceBytesPerRow] = @(bytesPerRow);
    properties[(__bridge NSString *)kIOSurfacePixelFormat] = @(pixelFormat);
    properties[(__bridge NSString *)kIOSurfaceAllocSize] = @(allocationSize);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (colorSpace) {
        CFPropertyListRef colorSpacePropertyList =
            CGColorSpaceCopyPropertyList(colorSpace);
        CGColorSpaceRelease(colorSpace);
        if (colorSpacePropertyList) {
            properties[(__bridge NSString *)kIOSurfaceColorSpace] =
                CFBridgingRelease(colorSpacePropertyList);
        }
    }

    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    if (bytesPerRowOut) {
        *bytesPerRowOut = bytesPerRow;
    }
    if (pixelFormatOut) {
        *pixelFormatOut = pixelFormat;
    }
    return surface;
}

static UIImage *FMScreenCaptureCreateImage(NSData *pixelData,
                                           size_t width,
                                           size_t height,
                                           size_t bytesPerRow,
                                           CGFloat scale) {
    if (pixelData.length == 0 || width == 0 || height == 0 ||
        bytesPerRow == 0) {
        return nil;
    }

    CGDataProviderRef provider =
        CGDataProviderCreateWithCFData((__bridge CFDataRef)pixelData);
    if (!provider) {
        return nil;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!colorSpace) {
        CGDataProviderRelease(provider);
        return nil;
    }

    CGBitmapInfo bitmapInfo =
        kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst;
    CGImageRef imageRef = CGImageCreate(width,
                                        height,
                                        8,
                                        32,
                                        bytesPerRow,
                                        colorSpace,
                                        bitmapInfo,
                                        provider,
                                        NULL,
                                        false,
                                        kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    if (!imageRef) {
        return nil;
    }

    UIImage *image = [UIImage imageWithCGImage:imageRef
                                          scale:scale > 0.0 ? scale : 1.0
                                    orientation:UIImageOrientationUp];
    CGImageRelease(imageRef);
    return image;
}

#if FMSCREEN_CAPTURE_POC_DEBUG
static void FMScreenCaptureWriteDebugPNG(UIImage *image) {
    if (!image) {
        return;
    }
    NSData *pngData = UIImagePNGRepresentation(image);
    if (pngData.length == 0) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Capture][ERROR] debug PNG encoding failed");
        return;
    }

    NSArray<NSString *> *paths = @[FMScreenCapturePOCPrimaryPath,
                                   FMScreenCapturePOCFallbackPath];
    for (NSString *path in paths) {
        if ([pngData writeToFile:path options:NSDataWritingAtomic error:nil]) {
            FLMEnqueueDiagnosticLine(
                @"[ScreenSense][Capture] debug PNG written path=%@ bytes=%lu",
                path, (unsigned long)pngData.length);
            return;
        }
    }
    FLMEnqueueDiagnosticLine(
        @"[ScreenSense][Capture][ERROR] debug PNG write failed");
}
#endif

static UIImage *FMScreenCaptureOneFrame(void) {
    CFTimeInterval startTime = CACurrentMediaTime();
    FLMEnqueueDiagnosticLine(@"[ScreenSense][Capture] initializing");

    FMScreenRenderDisplayFunction renderDisplay =
        FMScreenCaptureLoadRenderSymbol();
    if (!renderDisplay) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Capture][ERROR] capture aborted reason=no-render-symbol");
        return nil;
    }

    FMScreenCaptureDimensions dimensions;
    if (!FMScreenCaptureResolveDimensions(&dimensions)) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Capture][ERROR] capture aborted reason=invalid-pixel-size");
        return nil;
    }

    FLMEnqueueDiagnosticLine(
        @"[ScreenSense][Capture] iOS=%@ nativeScale=%.2f",
        [UIDevice currentDevice].systemVersion,
        [UIScreen mainScreen].nativeScale);

    size_t bytesPerRow = 0;
    uint32_t requestedPixelFormat = 0;
    IOSurfaceRef surface = FMScreenCaptureCreateSurface(dimensions.width,
                                                         dimensions.height,
                                                         &bytesPerRow,
                                                         &requestedPixelFormat);
    FLMEnqueueDiagnosticLine(
        @"[ScreenSense][Capture] pixel size=%zux%zu orientation=%ld bytesPerRow=%zu allocSize=%zu pixelFormat=0x%08x",
        dimensions.width, dimensions.height, (long)dimensions.orientation,
        bytesPerRow,
        IOSurfaceGetAllocSize(surface),
        requestedPixelFormat);
    if (!surface) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Capture][ERROR] IOSurfaceCreate failed");
        return nil;
    }
    FLMEnqueueDiagnosticLine(@"[ScreenSense][Capture] surface created");

    kern_return_t lockResult = IOSurfaceLock(surface, 0, NULL);
    if (lockResult != KERN_SUCCESS) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Capture][ERROR] IOSurfaceLock failed result=%d",
            lockResult);
        CFRelease(surface);
        return nil;
    }

    FLMEnqueueDiagnosticLine(@"[ScreenSense][Capture] render begin");
    renderDisplay(0, CFSTR("LCD"), surface, 0, 0);
    FLMEnqueueDiagnosticLine(@"[ScreenSense][Capture] render completed");

    kern_return_t unlockResult = IOSurfaceUnlock(surface, 0, NULL);
    if (unlockResult != KERN_SUCCESS) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Capture][ERROR] IOSurfaceUnlock failed result=%d",
            unlockResult);
        CFRelease(surface);
        return nil;
    }

    size_t surfaceWidth = IOSurfaceGetWidth(surface);
    size_t surfaceHeight = IOSurfaceGetHeight(surface);
    size_t surfaceBytesPerRow = IOSurfaceGetBytesPerRow(surface);
    uint32_t surfacePixelFormat = IOSurfaceGetPixelFormat(surface);
    if (surfaceWidth == 0 || surfaceHeight == 0 ||
        surfaceBytesPerRow == 0 || surfaceHeight > SIZE_MAX / surfaceBytesPerRow) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Capture][ERROR] invalid rendered surface width=%zu height=%zu bytesPerRow=%zu",
            surfaceWidth, surfaceHeight, surfaceBytesPerRow);
        CFRelease(surface);
        return nil;
    }

    size_t totalBytes = surfaceBytesPerRow * surfaceHeight;
    kern_return_t readLockResult = IOSurfaceLock(surface, 0, NULL);
    if (readLockResult != KERN_SUCCESS) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Capture][ERROR] IOSurface read lock failed result=%d",
            readLockResult);
        CFRelease(surface);
        return nil;
    }
    void *baseAddress = IOSurfaceGetBaseAddress(surface);
    NSData *pixelData = baseAddress
                            ? [NSData dataWithBytes:baseAddress length:totalBytes]
                            : nil;
    kern_return_t readUnlockResult = IOSurfaceUnlock(surface, 0, NULL);
    CFRelease(surface);
    if (readUnlockResult != KERN_SUCCESS || pixelData.length != totalBytes) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Capture][ERROR] pixel copy failed unlock=%d copied=%lu expected=%zu",
            readUnlockResult, (unsigned long)pixelData.length, totalBytes);
        return nil;
    }

    FLMEnqueueDiagnosticLine(
        @"[ScreenSense][Capture] surface pixels width=%zu height=%zu bytesPerRow=%zu pixelFormat=0x%08x",
        surfaceWidth, surfaceHeight, surfaceBytesPerRow, surfacePixelFormat);
    CGFloat scale = [UIScreen mainScreen].nativeScale;
    UIImage *image = FMScreenCaptureCreateImage(pixelData,
                                                 surfaceWidth,
                                                 surfaceHeight,
                                                 surfaceBytesPerRow,
                                                 scale);
    if (!image) {
        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Capture][ERROR] CGImage/UIImage creation failed");
        return nil;
    }

    FLMEnqueueDiagnosticLine(
        @"[ScreenSense][Capture] UIImage created size={%.1f,%.1f} scale=%.2f",
        image.size.width, image.size.height, image.scale);
#if FMSCREEN_CAPTURE_POC_DEBUG
    FMScreenCaptureWriteDebugPNG(image);
#endif
    FLMEnqueueDiagnosticLine(
        @"[ScreenSense][Capture] elapsed=%.2f ms",
        (CACurrentMediaTime() - startTime) * 1000.0);
    return image;
}

@implementation FMScreenCaptureProvider

+ (UIImage *)captureCurrentDisplay {
    if (![NSThread isMainThread]) {
        __block UIImage *capturedImage = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            capturedImage = FMScreenCaptureOneFrame();
        });
        return capturedImage;
    }
    return FMScreenCaptureOneFrame();
}

@end
