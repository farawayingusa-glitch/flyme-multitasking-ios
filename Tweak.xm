#import <notify.h>
#import <stdint.h>
#import <unistd.h>

#define FLYME_RUNTIME_NOTIFICATION "com.codex.flymemultitasking.runtime"
#define FLYME_RUNTIME_MAGIC 0x464C594DULL

static int FlymeRuntimeToken = -1;

%ctor {
    if (notify_register_check(FLYME_RUNTIME_NOTIFICATION, &FlymeRuntimeToken) != NOTIFY_STATUS_OK) {
        return;
    }

    uint64_t state = (FLYME_RUNTIME_MAGIC << 32) | (uint32_t)getpid();
    notify_set_state(FlymeRuntimeToken, state);
    notify_post(FLYME_RUNTIME_NOTIFICATION);
}
