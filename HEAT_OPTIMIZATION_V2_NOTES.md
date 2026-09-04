# 0.9.59 Heat Optimization v2

Changes:

- Kept ProMotion / CADisplayLink high refresh behavior unchanged.
- Kept input display link idle release from the previous version.
- Added an idle guard to lock monitoring: when no wheel is pinned and the floating window is hidden, the housekeeping timer exits instead of continuing to wake the main run loop.

Goal: reduce CPU wakeups while the tweak is inactive.
