ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

# Plain dylib (no CydiaSubstrate dependency) so it can be injected with
# ESign on a non-jailbroken device. Hooks use the Objective-C runtime.
LIBRARY_NAME = AgoraRecorder

AgoraRecorder_FILES = Tweak.m AgoraRecorder.m AgoraMenu.m
AgoraRecorder_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
AgoraRecorder_FRAMEWORKS = UIKit AVFoundation Foundation QuartzCore

include $(THEOS_MAKE_PATH)/library.mk
