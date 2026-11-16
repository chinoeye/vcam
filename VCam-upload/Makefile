# VCam — iPhone 摄像头硬改（OBS 画面注入）
# 目标：iPhone 8 (A11) / iOS 15.1 / palera1n rootless
#
# 编译需要在 macOS 或 Linux 上装 Theos。
# 没有 Mac 就用仓库里的 .github/workflows/build.yml 走 GitHub Actions。

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

VCam_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Aweme || true"
	install.exec "killall -9 AwemeLite || true"
	install.exec "killall -9 快手 || true"
