#!/usr/bin/env python3
"""Source contracts + native tests of ACTUAL extracted notify helpers.
These mocks test cache/state behavior, not iOS scheduling or private APIs.
Run: python3 scripts/verify-energy-repair.py [--cc clang]
"""
import argparse
import pathlib
import subprocess
import tempfile
import os

root = pathlib.Path(__file__).resolve().parents[1]
tweak = (root / 'Tweak.xm').read_text(encoding='utf-8')
keyboard = (root / 'Keyboard.xm').read_text(encoding='utf-8')
header = (root / 'FLMDiagnostics.h').read_text(encoding='utf-8')
radius = (root / 'Radius.xm').read_text(encoding='utf-8')

def function(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    while ';' in source[start:brace]:
        start = source.index(signature, start + len(signature))
        brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

background = function(tweak, '- (void)backgroundFloatingScene:(id)scene {')
assert background.index('FLMClearProtectedScene(scene);') < background.index('updateSettings:mutableSettings')
flush = function(tweak, '- (void)flushFloatingDockInputFrame:(CADisplayLink *)displayLink {')
assert 'displayLink.paused = YES;' in flush
ensure = function(tweak, '- (void)ensureFloatingDockInputDisplayLink {')
assert 'self.floatingDockInputDisplayLink.paused = NO;' in ensure
lease = function(tweak, '- (void)beginFloatingHighRefreshLeaseForDuration:(NSTimeInterval)duration {')
assert 'MIN(2.0, MAX(0.08, duration))' in lease and 'dispatch_after' not in lease
tick = function(tweak, '- (void)tickFloatingHighRefreshDisplayLink:(CADisplayLink *)displayLink {')
assert 'CACurrentMediaTime() >= self.floatingHighRefreshDeadline' in tick
assert '[displayLink invalidate]' in tick
writer = function(tweak, 'static void FLMScheduleKeyboardSharedStateWrite(void) {')
assert 'FLMKeyboardPendingSnapshot = snapshot;' in writer
assert 'isEqualToDictionary:FLMKeyboardLastRequestedSnapshot' in writer
assert writer.index('FLMKeyboardPendingSnapshot = snapshot;') < writer.index('if (FLMKeyboardWriteScheduled)')
reader = function(keyboard, 'static NSDictionary *FLMReadKeyboardSharedState(void) {')
assert reader.index('return FLMKeyboardCachedSharedState;') < reader.index('dictionaryWithContentsOfFile:')
route = function(keyboard, 'static void FLMReloadKeyboardRoute(void) {')
assert 'FLMKeyboardSharedCacheRevision' in route
assert 'FLMKeyboardFallbackReadFailed = YES;' in route
assert route.index('do not commit a partial tuple') < route.index('lastAppliedRevision = FLMKeyboardSharedCacheRevision;')
retry = function(radius, 'static void FLMRadiusInstallControllerHooks(void) {')
assert 'retryCount >= 20' in retry and 'retryScheduled' in retry
assert retry.index('if (!controllerClass)') < retry.index('MSHookMessageEx([CALayer class]')
assert 'NS_FORMAT_FUNCTION(1, 2)' in header
# Preserve the user's explicit choice: hidden windows remain live.
for signature in ['- (void)transitionFloatingWindowToHiddenAnimated:(BOOL)animated {',
                  '- (void)finishFloatingDockHiddenGesture:(BOOL)shouldHide']:
    assert 'backgroundFloatingScene:' not in function(tweak, signature)
print('PASS: source/lifecycle/performance contracts')

prelude = r'''
typedef unsigned long long uint64_t;
typedef int BOOL;
#define YES 1
#define NO 0
#define NOTIFY_STATUS_OK 0
#define UINT64_C(x) x##ULL
#define FLYME_DOCK_INPUT_BLOCK_NOTIFICATION "test.block"
#define FLYME_DOCK_INPUT_BLOCK_ACTIVE_MASK (1ULL << 63)
typedef struct { uint64_t value; BOOL valid; } FLMNotifyPublication;
static int FLMDockInputBlockToken = -1;
static uint64_t serverState = 0;
static int changed = 1, getCalls = 0, setCalls = 0, postCalls = 0;
static int failGet = 0, failCheck = 0, failSet = 0, failPost = 0;
static int notify_register_check(const char *name, int *token) { (void)name; *token = 1; return 0; }
static int notify_check(int token, int *out) {
    (void)token;
    if (failCheck) { failCheck = 0; return 1; }
    *out = changed; changed = 0; return 0;
}
static int notify_get_state(int token, uint64_t *state) {
    (void)token; ++getCalls;
    if (failGet) { failGet = 0; return 1; }
    *state = serverState; return 0;
}
static int notify_set_state(int token, uint64_t state) {
    (void)token; ++setCalls;
    if (failSet) { failSet = 0; return 1; }
    serverState = state; return 0;
}
static int notify_post(const char *name) {
    (void)name; ++postCalls;
    if (failPost) { failPost = 0; return 1; }
    changed = 1; return 0;
}
static uint64_t FLMCurrentApplicationIdentifierHash(void) { return 42; }
#define CHECK(x) do { if (!(x)) return __LINE__; } while (0)
'''
actual = '\n'.join([
    function(header, 'static inline uint64_t FLMDockInputBlockState('),
    function(header, 'static inline BOOL FLMDockInputBlockStateMatches('),
    function(keyboard, 'static BOOL FLMDockInputBlockedForCurrentApplication(void) {'),
    function(tweak, 'static void FLMPublishChangedNotifyState('),
])
main = r'''
int main(void) {
    CHECK(!FLMDockInputBlockedForCurrentApplication());
    for (int i = 0; i < 10000; i++) CHECK(!FLMDockInputBlockedForCurrentApplication());
    CHECK(getCalls == 1);
    serverState = FLMDockInputBlockState(42, YES); changed = 1;
    CHECK(FLMDockInputBlockedForCurrentApplication());
    for (int i = 0; i < 10000; i++) CHECK(FLMDockInputBlockedForCurrentApplication());
    CHECK(getCalls == 2);
    serverState = 0; changed = 1;
    CHECK(!FLMDockInputBlockedForCurrentApplication());
    serverState = FLMDockInputBlockState(42, YES); changed = 1; failGet = 1;
    CHECK(!FLMDockInputBlockedForCurrentApplication());
    CHECK(FLMDockInputBlockedForCurrentApplication());
    serverState = 0; failCheck = 1;
    CHECK(!FLMDockInputBlockedForCurrentApplication());
    serverState = FLMDockInputBlockState(43, YES); changed = 1;
    CHECK(!FLMDockInputBlockedForCurrentApplication());
    FLMNotifyPublication last = {0, NO};
    setCalls = postCalls = 0;
    FLMPublishChangedNotifyState(1, "test", 0, &last);
    CHECK(setCalls == 1 && postCalls == 1 && serverState == 0 && last.valid);
    for (int i = 0; i < 10000; i++) FLMPublishChangedNotifyState(1, "test", 0, &last);
    CHECK(setCalls == 1 && postCalls == 1);
    failPost = 1;
    FLMPublishChangedNotifyState(1, "test", 123, &last);
    CHECK(!last.valid && serverState == 123);
    FLMPublishChangedNotifyState(1, "test", 0, &last);
    CHECK(last.valid && serverState == 0 && last.value == 0);
    failSet = 1;
    FLMPublishChangedNotifyState(1, "test", 456, &last);
    CHECK(!last.valid && serverState == 0);
    FLMPublishChangedNotifyState(1, "test", 456, &last);
    CHECK(last.valid && serverState == 456 && last.value == 456);
    return 0;
}
'''
parser = argparse.ArgumentParser()
parser.add_argument('--cc', default='clang')
parser.add_argument('--wasm-output', help='Compile portable behavioral tests for a WebAssembly runner')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='flyme-energy-') as d:
    source = pathlib.Path(d) / 'notify-test.c'
    binary = pathlib.Path(d) / ('notify-test.exe' if os.name == 'nt' else 'notify-test')
    source.write_text(prelude + actual + main, encoding='utf-8')
    command = [args.cc, '-O1', '-fno-stack-protector', str(source), '-o', str(binary)]
    if os.name == 'nt':
        command += ['-fuse-ld=lld', '-nostdlib', '-Wl,/entry:main', '-Wl,/subsystem:console']
    if args.wasm_output:
        command = [args.cc, '-target', 'wasm32', '-O1', '-nostdlib', str(source),
                   '-Wl,--no-entry', '-Wl,--export=main', '-o', args.wasm_output]
    subprocess.run(command, check=True)
    if not args.wasm_output:
        subprocess.run([str(binary)], check=True)
print(('COMPILED (runner required): ' if args.wasm_output else 'PASS: ') + 'actual C helpers; 20,000 unchanged touch reads; 10,000 duplicate publications; target isolation; initial zero publication; read/check/set/post failure recovery')
