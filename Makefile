# VCam - inject OBS output as the iPhone back-camera feed
# Target: iPhone 8 (A11) / iOS 15.1 / palera1n rootless
#
# Building requires Theos on macOS or Linux.
# No Mac? use .github/workflows/build.yml on GitHub Actions.

export THEOS_PACKAGE_SCHEME = rootless
export ARCHS = arm64
export TARGET = iphone:clang:latest:15.0
export FINALPACKAGE = 1

DEBUG = 0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCam

VCam_FILES = Tweak.xm \
             $(wildcard src/*.m)

VCam_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/src -Wall -Wno-unused-function

VCam_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreVideo \
                  CoreImage ImageIO QuartzCore CoreGraphics \
                  VideoToolbox AudioToolbox

# 不再链接 libsubstrate —— TrollStore 环境没有它。
# hook 能力由 src/VCSubstrateCompat.m 内建：
#   MSHookMessageEx → method_setImplementation（objc runtime 原生）
#   MSHookFunction  → fishhook 按符号名重绑定
# 产出的 dylib 自包含，越狱和 TrollStore 两边都能用。
# VCam_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

# The asset directory is empty, and Theos skips empty directories when
# packaging, so after install the path would not exist at all.
# Force it into the staging tree, and make sure it lands in the data archive.
after-stage::
	@echo ">>> creating asset directory"
	mkdir -p "$(THEOS_STAGING_DIR)/Library/Application Support/VCam/assets"
	chmod -R 755 "$(THEOS_STAGING_DIR)/Library/Application Support/VCam"
	@echo ">>> staging tree:"
	@find "$(THEOS_STAGING_DIR)" -maxdepth 4 | head -40

after-package::
	@echo ">>> package done"
	@ls -lh packages/*.deb 2>/dev/null || true

after-install::
	install.exec "killall -9 Aweme || true"
	install.exec "killall -9 AwemeLite || true"
