#import <Foundation/Foundation.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <stdarg.h>
#import <stdio.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <unistd.h>

#import "FLMDiagnostics.h"

static dispatch_queue_t FLMLandscapeDiagnosticQueue;
static BOOL FLMLandscapeDiagnosticReady = NO;
static const char *const FLMLandscapeDiagnosticPaths[] = {
    "/var/jb/var/mobile/Library/Preferences/FlymeMultitasking-Diagnostic.log",
    "/var/mobile/Library/Preferences/FlymeMultitasking-Diagnostic.log",
    "/var/jb/tmp/FlymeLandscape-Bootstrap.log",
    "/var/tmp/FlymeLandscape-Bootstrap.log",
};

static void FLMLandscapeStartDiagnosticWriter(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FLMLandscapeDiagnosticQueue =
            dispatch_queue_create("com.codex.flyme.landscape-diagnostic",
                                  DISPATCH_QUEUE_SERIAL);
        FLMLandscapeDiagnosticReady = YES;
    });
}

static int FLMLandscapeOpenDiagnosticFile(void) {
    for (NSUInteger index = 0;
         index < sizeof(FLMLandscapeDiagnosticPaths) /
                    sizeof(FLMLandscapeDiagnosticPaths[0]);
         index++) {
        int descriptor = open(FLMLandscapeDiagnosticPaths[index],
                              O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                              0644);
        if (descriptor >= 0) {
            return descriptor;
        }
    }
    return -1;
}

void FLMWriteLandscapeBootstrapMarker(const char *reason) {
    if (!reason) {
        reason = "<none>";
    }
    struct timeval now;
    gettimeofday(&now, NULL);
    char line[512];
    int length = snprintf(line,
                          sizeof(line),
                          "%lld.%03d pid=%d landscape-plugin bootstrap reason=%s\n",
                          (long long)now.tv_sec,
                          (int)(now.tv_usec / 1000),
                          getpid(),
                          reason);
    if (length <= 0 || (size_t)length >= sizeof(line)) {
        return;
    }
    int descriptor = FLMLandscapeOpenDiagnosticFile();
    if (descriptor < 0) {
        return;
    }
    const uint8_t *bytes = (const uint8_t *)line;
    size_t remaining = (size_t)length;
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

void FLMEnqueueDiagnosticLine(NSString *format, ...) {
    FLMLandscapeStartDiagnosticWriter();
    if (!format.length || !FLMLandscapeDiagnosticQueue) {
        return;
    }
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format
                                              arguments:arguments];
    va_end(arguments);
    dispatch_async(FLMLandscapeDiagnosticQueue, ^{
        @autoreleasepool {
            if (!FLMLandscapeDiagnosticReady || !message.length) {
                return;
            }
            struct timeval now;
            gettimeofday(&now, NULL);
            NSString *line = [NSString stringWithFormat:
                @"%lld.%03d pid=%d landscape-plugin %@\n",
                (long long)now.tv_sec,
                (int)(now.tv_usec / 1000),
                getpid(), message];
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            int descriptor = FLMLandscapeOpenDiagnosticFile();
            if (descriptor < 0 || !data.length) {
                if (descriptor >= 0) {
                    close(descriptor);
                }
                return;
            }
            const uint8_t *bytes = (const uint8_t *)data.bytes;
            size_t remaining = data.length;
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
    });
}
