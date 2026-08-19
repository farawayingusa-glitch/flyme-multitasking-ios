ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FlymeLandscape

# This target is intentionally a separate package. It has no Keyboard.xm,
# no portrait Scene adapter, and no dependency on the portrait dylib.
FlymeLandscape_FILES = ../LandscapeWheel.xm ../LandscapeModule.xm ../LandscapeDiagnostics.xm ../SceneLifecycle.xm
FlymeLandscape_CFLAGS = -fobjc-arc -Wall -Wextra
FlymeLandscape_FRAMEWORKS = UIKit QuartzCore CoreGraphics
FlymeLandscape_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
