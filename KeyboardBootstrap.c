#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <notify.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define FLYME_KEYBOARD_BOOTSTRAP_NOTIFICATION \
    "com.codex.flymemultitasking.keyboard-bootstrap-v41"
#define FLYME_KEYBOARD_BOOTSTRAP_SUCCESS_MAGIC 0xF341ULL
#define FLYME_KEYBOARD_BOOTSTRAP_FAILURE_MAGIC 0xE341ULL
#define FLYME_KEYBOARD_ADAPTER_BUILD 41ULL

static int FLMProcessIsWeChat(void) {
    const char *processName = getprogname();
    if (processName && strcmp(processName, "WeChat") == 0) {
        return 1;
    }

    char executablePath[PATH_MAX];
    uint32_t executablePathSize = sizeof(executablePath);
    if (_NSGetExecutablePath(executablePath, &executablePathSize) != 0) {
        return 0;
    }
    const char *lastSlash = strrchr(executablePath, '/');
    const char *executableName = lastSlash ? lastSlash + 1 : executablePath;
    return strcmp(executableName, "WeChat") == 0;
}

static void FLMPublishBootstrapResult(int loaded) {
    static int token = -1;
    if (notify_register_check(FLYME_KEYBOARD_BOOTSTRAP_NOTIFICATION, &token) !=
        NOTIFY_STATUS_OK) {
        token = -1;
        return;
    }
    uint64_t magic = loaded ? FLYME_KEYBOARD_BOOTSTRAP_SUCCESS_MAGIC
                            : FLYME_KEYBOARD_BOOTSTRAP_FAILURE_MAGIC;
    uint64_t state = (magic << 48) |
                     (FLYME_KEYBOARD_ADAPTER_BUILD << 32) |
                     (uint32_t)getpid();
    notify_set_state(token, state);
    notify_post(FLYME_KEYBOARD_BOOTSTRAP_NOTIFICATION);
}

// NathanLR does not inject FlymeKeyboard through its executable filter on the
// target device. The original compatible package uses a UIKit bundle filter,
// so this tiny loader uses the same entry point but performs no UIKit or
// Objective-C work. Every non-WeChat process returns before dlopen; only the
// exact WeChat executable receives the full application-side adapter.
__attribute__((constructor))
static void FLMKeyboardBootstrapLoad(void) {
    if (!FLMProcessIsWeChat()) {
        return;
    }

    Dl_info imageInfo = {0};
    if (dladdr((const void *)&FLMKeyboardBootstrapLoad, &imageInfo) == 0 ||
        !imageInfo.dli_fname) {
        FLMPublishBootstrapResult(0);
        return;
    }
    const char *lastSlash = strrchr(imageInfo.dli_fname, '/');
    if (!lastSlash) {
        FLMPublishBootstrapResult(0);
        return;
    }
    size_t directoryLength = (size_t)(lastSlash - imageInfo.dli_fname);
    if (directoryLength + sizeof("/FlymeKeyboard.dylib") > PATH_MAX) {
        FLMPublishBootstrapResult(0);
        return;
    }
    char adapterPath[PATH_MAX];
    int pathLength = snprintf(adapterPath,
                              sizeof(adapterPath),
                              "%.*s/FlymeKeyboard.dylib",
                              (int)directoryLength,
                              imageInfo.dli_fname);
    int loaded = pathLength > 0 && (size_t)pathLength < sizeof(adapterPath) &&
                 dlopen(adapterPath, RTLD_NOW | RTLD_LOCAL) != NULL;
    FLMPublishBootstrapResult(loaded);
}
