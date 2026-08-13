ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME = rootless

# Keep Theos' jailbreak-native signer. Overriding this with Apple's
# `codesign -s -` produces a macOS ad-hoc CodeDirectory (CS_ADHOC) that can be
# accepted in SpringBoard while being rejected before our constructor runs in
# a sandboxed application process under NathanLR.

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FlymeMultitasking FlymeKeyboard FlymeRadius

FlymeMultitasking_FILES = Tweak.xm SceneLifecycle.xm FMScreenCaptureProvider.xm FMScreenSenseSession.xm FMScreenSenseTranslation.xm
FlymeMultitasking_SWIFT_FILES = FMScreenSenseVisionBridge.swift
FlymeMultitasking_CFLAGS = -fobjc-arc -Wall -Wextra
FlymeMultitasking_FRAMEWORKS = UIKit QuartzCore IOSurface CoreGraphics VisionKit

FlymeKeyboard_FILES = Keyboard.xm
FlymeKeyboard_CFLAGS = -fobjc-arc -Wall -Wextra
FlymeKeyboard_FRAMEWORKS = UIKit QuartzCore

FlymeRadius_FILES = Radius.xm
FlymeRadius_CFLAGS = -fobjc-arc -Wall -Wextra
FlymeRadius_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
