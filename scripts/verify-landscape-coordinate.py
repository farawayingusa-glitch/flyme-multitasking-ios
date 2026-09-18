#!/usr/bin/env python3
"""Compile production geometry helpers and keyboard-frame branch, then replay regressions."""
import argparse, pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
s = (root/'Tweak.xm').read_text(encoding='utf-8')
def function(signature):
    start = s.index(signature); brace = s.index('{', start); depth = 1; end = brace + 1
    while depth:
        depth += (s[end] == '{') - (s[end] == '}'); end += 1
    return s[start:end]
prelude = r'''
typedef double CGFloat;
typedef int BOOL;
#define YES 1
#define NO 0
#define MIN(a,b) ((a)<(b)?(a):(b))
#define MAX(a,b) ((a)>(b)?(a):(b))
#define isfinite(x) __builtin_isfinite(x)
typedef int UIInterfaceOrientation;
enum { UIInterfaceOrientationPortrait=1, UIInterfaceOrientationLandscapeRight=3, UIInterfaceOrientationLandscapeLeft=4 };
typedef struct { CGFloat x,y; } CGPoint;
typedef struct { CGFloat width,height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;
static CGPoint CGPointMake(CGFloat x,CGFloat y) { return (CGPoint){x,y}; }
static CGRect CGRectMake(CGFloat x,CGFloat y,CGFloat w,CGFloat h) { return (CGRect){{x,y},{w,h}}; }
#define CGRectGetWidth(r) ((r).size.width)
#define CGRectGetHeight(r) ((r).size.height)
#define CGRectIsNull(r) ((r).size.width<0)
#define CGRectIsEmpty(r) ((r).size.width<=0 || (r).size.height<=0)
static CGRect CGRectIntersection(CGRect a,CGRect b) {
    double x=MAX(a.origin.x,b.origin.x), y=MAX(a.origin.y,b.origin.y);
    double right=MIN(a.origin.x+a.size.width,b.origin.x+b.size.width);
    double bottom=MIN(a.origin.y+a.size.height,b.origin.y+b.size.height);
    return CGRectMake(x,y,right-x,bottom-y);
}
static const CGFloat FLMDefaultCornerTriggerSize=58, FLMMinimumCornerTriggerSize=36, FLMMaximumCornerTriggerSize=96;
static CGFloat FLMCornerTriggerSize=58;
#define CHECK(x) do { if (!(x)) return __LINE__; } while(0)
static double absolute(double x) { return x<0?-x:x; }
static int equal(CGPoint a,CGPoint b) { return absolute(a.x-b.x)<0.00001 && absolute(a.y-b.y)<0.00001; }
'''
actual = '\n'.join(function(sig) for sig in [
    'static BOOL FLMBoundsAreLandscape(',
    'static CGPoint FLMVisualPointFromRootPoint(',
    'static CGPoint FLMFixedPointFromVisualPoint(',
    'static CGFloat FLMClampedCornerTriggerSize(',
    'static BOOL FLMPointInsideCornerTrigger('])
start = s.index('        BOOL landscape = [self isLandscapeFloatingSession];', s.index('- (void)applyKeyboardFrame:'))
end = s.index('        self.floatingKeyboardVisible = YES;', start)
keyboard = s[start:end].replace('        BOOL landscape = [self isLandscapeFloatingSession];', '')
keyboard = keyboard.replace('self.lastPortraitKeyboardHeight','portraitCache').replace('self.floatingKeyboardMaximumVisibleHeight','maximumHeight')
actual += '\nstatic double portraitCache=291, maximumHeight=0;\nstatic CGRect measured;\nstatic void applyFrame(BOOL landscape, CGRect frame, CGRect bounds) {\n'+keyboard+'\nmeasured=frame; }\n'
main = r'''
int main(void) {
    CGRect display=CGRectMake(0,0,844,390), fixed=CGRectMake(0,0,390,844);
    for(int orientation=3;orientation<=4;orientation++) {
        CGPoint corners[]={{10,380},{834,380},{10,10},{834,10},{422,195},{195,195},{200,360}};
        for(int i=0;i<7;i++) {
            CGPoint f=FLMFixedPointFromVisualPoint(corners[i],display,orientation);
            CGPoint p=FLMVisualPointFromRootPoint(f,fixed,display,orientation);
            CHECK(equal(p,corners[i]));
            BOOL right=NO;
            CHECK(FLMPointInsideCornerTrigger(p,display,&right)==(i<2));
            if(i<2) CHECK(right==(i==1));
        }
        for(int x=0;x<=844;x+=13) for(int y=0;y<=390;y+=11) {
            CGPoint p=CGPointMake(x,y);
            CHECK(equal(p,FLMVisualPointFromRootPoint(FLMFixedPointFromVisualPoint(p,display,orientation),fixed,display,orientation)));
        }
    }
    BOOL right=NO;
    CHECK(FLMPointInsideCornerTrigger(CGPointMake(365.3,813.7),fixed,&right)&&right);
    CHECK(!FLMPointInsideCornerTrigger(CGPointMake(195,422),fixed,0));
    CHECK(!FLMPointInsideCornerTrigger(CGPointMake(-1,390),display,0));
    CHECK(!FLMPointInsideCornerTrigger(CGPointMake(845,390),display,0));
    // The log's 75pt accessory must not reserve a 291pt portrait keyboard.
    applyFrame(YES,CGRectMake(0,315,844,75),display);
    CHECK(measured.origin.y==315 && measured.size.height==75 && portraitCache==291);
    applyFrame(YES,CGRectMake(0,183,844,207),display);
    CHECK(measured.origin.y==183 && maximumHeight==207 && portraitCache==291);
    applyFrame(YES,CGRectMake(0,315,844,75),display);
    CHECK(maximumHeight==75); // no stale maximum after a keyboard height change
    maximumHeight=0;
    applyFrame(NO,CGRectMake(0,769,390,75),fixed);
    CHECK(measured.size.height==291); // original portrait behavior
    return 0;
}
'''
# Integration contracts cover live ingress without requiring a notification.
hotspot=s[s.index('@implementation FLMHotspotWindow'):s.index('@end',s.index('@implementation FLMHotspotWindow'))]
assert 'FLMVisualScreenBounds()' in hotspot and 'FLMVisualPointFromWindowPoint(point, self' in hotspot
assert 'self.hotspotWindow.hidden = !self.enabled;' in s
assert s.count('BOOL landscapeIngress = FLMDisplayIsLandscape();') == 2
assert 'fromCoordinateSpace:fixedSpace' in function('static void FLMConfigureVisualCanvas(')
assert 'CGRectContainsPoint(visualBounds, rawPoint)' not in s
assert '((UIWindowScene *)scene).coordinateSpace.bounds' in s
assert '[self isLandscapeFloatingSession] ? targetSize.width' in s
assert '[self isLandscapeFloatingSession] ? targetSize.height' in s
assert 'self.cornerGesture.minimumPressDuration = 0.12;' in s
assert 'self.landscapeCornerGesture.minimumPressDuration = 0.12;' in s
parser=argparse.ArgumentParser(); parser.add_argument('--cc',default='clang'); parser.add_argument('--wasm-output'); args=parser.parse_args()
with tempfile.TemporaryDirectory(prefix='flyme-coordinates-') as d:
    c=pathlib.Path(d)/'coordinates.c'; exe=pathlib.Path(d)/'coordinates'
    c.write_text(prelude+actual+main,encoding='utf-8')
    command=[args.cc,'-O1',str(c),'-o',str(exe)]
    if args.wasm_output: command=[args.cc,'-target','wasm32','-O1','-nostdlib',str(c),'-Wl,--no-entry','-Wl,--export=main','-o',args.wasm_output]
    subprocess.run(command,check=True)
    if not args.wasm_output: subprocess.run([str(exe)],check=True)
print('COMPILED: geometry and keyboard regressions (runner required)' if args.wasm_output else 'PASS: geometry and keyboard regressions')
