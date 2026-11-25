# Theos build for the AppClone container engine (tweak + daemon).
#
# Build on macOS with Theos + Xcode (CI does this — see
# .github/workflows/ios-engine-deb.yml):
#
#   export THEOS=$HOME/theos
#   export THEOS_PACKAGE_SCHEME=rootless     # Dopamine/palera1n on iOS 15+
#   make package FINALPACKAGE=1
#
# Output: packages/com.levothanhlam.appclone_<version>_iphoneos-arm64.deb

TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
  COMMON_CFLAGS += -DROOTLESS
endif

# ---------------------------------------------------------------- tweak ----
TWEAK_NAME = AppCloneKit
AppCloneKit_FILES = tweak/AppCloneKit.xm
AppCloneKit_CFLAGS = -fobjc-arc $(COMMON_CFLAGS)
AppCloneKit_FRAMEWORKS = Foundation Security
AppCloneKit_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

# --------------------------------------------------------------- daemon ----
TOOL_NAME = appcloned
appcloned_FILES = daemon/appcloned.m
appcloned_CFLAGS = -fobjc-arc $(COMMON_CFLAGS)
appcloned_FRAMEWORKS = Foundation
appcloned_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
