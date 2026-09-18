# 0.9.66 validation

Base: e1a3c8f (0.9.65). Windows local Clang 22.1.7 with iPhoneOS16.5 SDK.

- Logos preprocessing and arm64/arm64e syntax checks: four tweak modules plus preferences, ten checks, no errors/warnings.
- Frozen foundation, lifecycle checks: pass.
- Executed production geometry helpers and keyboard branch as WebAssembly: both landscape orientations, bottom corners accepted, top/center rejected, more than 4,000 round trips, portrait right corner retained, 75/207pt keyboard replay without 291pt cache pollution.
- Existing notify performance/failure recovery tests executed as WebAssembly: pass.
- No device installation, live UIKit touch replay, visual keyboard orientation verification, or energy measurement has been performed locally.

Device retest: both landscape directions, both bottom corners, center must not open; swipe selection and pinned tap; app card content/touches; show/shrink/hide keyboard then tap outside; return to portrait and test wheel/dock/notification reply.

The log contains two SpringBoard processes/builds. Zero adapter-ready evidence and unsupported optional scene pairing remain diagnostic limitations; this patch does not claim that those private-API paths are verified or repaired.
