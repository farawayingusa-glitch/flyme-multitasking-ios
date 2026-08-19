#import <errno.h>
#import <fcntl.h>
#import <stdio.h>
#import <sys/time.h>
#import <unistd.h>

#import "FLMLandscapeModule.h"

// This writer is intentionally isolated from the portrait diagnostic writer.
// It is safe to call from a dylib constructor and leaves a POSIX-only trace
// before UIKit, SpringBoard, or the normal asynchronous logger is available.
static const char *const FLMLandscapeBootstrapPaths[] = {
    "/var/jb/tmp/FlymeLandscape-Bootstrap.log",
    "/var/tmp/FlymeLandscape-Bootstrap.log",
};

static void FLMLandscapeWriteBootstrapLine(const char *path,
                                           const char *line,
                                           size_t length) {
    int descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                          0644);
    if (descriptor < 0) {
        return;
    }

    const unsigned char *bytes = (const unsigned char *)line;
    size_t remaining = length;
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

void FLMWriteLandscapeBootstrapMarker(const char *reason) {
    if (!reason) {
        reason = "<none>";
    }

    struct timeval now;
    gettimeofday(&now, NULL);
    char line[512];
    int length = snprintf(line,
                          sizeof(line),
                          "%lld.%03d pid=%d flyme-multitasking landscape "
                          "bootstrap reason=%s\n",
                          (long long)now.tv_sec,
                          (int)(now.tv_usec / 1000),
                          getpid(),
                          reason);
    if (length <= 0 || (size_t)length >= sizeof(line)) {
        return;
    }

    for (size_t index = 0;
         index < sizeof(FLMLandscapeBootstrapPaths) /
                    sizeof(FLMLandscapeBootstrapPaths[0]);
         index++) {
        FLMLandscapeWriteBootstrapLine(FLMLandscapeBootstrapPaths[index],
                                       line,
                                       (size_t)length);
    }
}
