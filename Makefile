ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME = rootless
TARGET_CODESIGN = codesign
TARGET_CODESIGN_FLAGS = --force --sign - --timestamp=none

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FlymeMultitasking FlymeKeyboard

FlymeMultitasking_FILES = Tweak.xm SceneLifecycle.xm
FlymeMultitasking_CFLAGS = -fobjc-arc -Wall -Wextra
FlymeMultitasking_FRAMEWORKS = UIKit

FlymeKeyboard_FILES = Keyboard.xm
FlymeKeyboard_CFLAGS = -fobjc-arc -Wall -Wextra
FlymeKeyboard_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
