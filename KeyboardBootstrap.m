#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <unistd.h>

#import "FLMDiagnostics.h"

// Some rootless injectors do not treat a framework bundle filter as an
// application-process match.  This class-filtered shim gives every real UIKit
// application a deterministic path to the single keyboard adapter image.  If
// the normal com.apple.UIKit filter already loaded FlymeKeyboard, dlopen simply
// returns the existing image and its constructor is not run twice.
__attribute__((constructor))
static void FLMKeyboardBootstrapLoad(void) {
    @autoreleasepool {
        Dl_info imageInfo = {0};
        BOOL loaded = NO;
        if (dladdr((const void *)&FLMKeyboardBootstrapLoad, &imageInfo) != 0 &&
            imageInfo.dli_fname != NULL) {
            NSString *bootstrapPath =
                [NSString stringWithUTF8String:imageInfo.dli_fname];
            NSString *adapterPath =
                [[bootstrapPath stringByDeletingLastPathComponent]
                    stringByAppendingPathComponent:@"FlymeKeyboard.dylib"];
            loaded = dlopen(adapterPath.fileSystemRepresentation,
                            RTLD_NOW | RTLD_LOCAL) != NULL;
        }

        NSString *bundleIdentifier = [NSBundle mainBundle].bundleIdentifier;
        FLMDiagnosticRole role =
            [bundleIdentifier isEqualToString:@"com.apple.springboard"]
                ? FLMDiagnosticRoleUIKitOther
                : FLMDiagnosticRoleApplication;
        FLMPublishDiagnosticEvent(role,
                                  FLMDiagnosticEventRouteReady,
                                  0,
                                  loaded ? 1 : 0,
                                  (uint16_t)(getpid() & 0xFFFF));
    }
}
