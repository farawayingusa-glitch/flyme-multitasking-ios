#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <errno.h>
#import <notify.h>
#import <signal.h>
#import <stdint.h>

#define FLYME_RUNTIME_NOTIFICATION "com.codex.flymemultitasking.runtime"
#define FLYME_RUNTIME_MAGIC 0x464C594DULL

static BOOL FlymeRuntimeIsConnected(void) {
    int token = -1;
    uint64_t state = 0;
    if (notify_register_check(FLYME_RUNTIME_NOTIFICATION, &token) != NOTIFY_STATUS_OK) {
        return NO;
    }

    uint32_t status = notify_get_state(token, &state);
    notify_cancel(token);
    if (status != NOTIFY_STATUS_OK || (state >> 32) != FLYME_RUNTIME_MAGIC) {
        return NO;
    }

    pid_t processIdentifier = (pid_t)(state & 0xffffffffULL);
    if (processIdentifier <= 1) {
        return NO;
    }
    if (kill(processIdentifier, 0) == 0) {
        return YES;
    }
    return errno == EPERM;
}

@interface FLMRootListController : PSListController
@end

@implementation FLMRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (NSString *)runtimeStatus:(PSSpecifier *)specifier {
    (void)specifier;
    return FlymeRuntimeIsConnected() ? @"已连接" : @"未连接";
}

@end
