ARCHS = arm64

TARGET := iphone:clang:16.5:16.5
INSTALL_TARGET_PROCESSES = SpringBoard


include $(THEOS)/makefiles/common.mk

TWEAK_NAME = arg-capture

arg-capture_FILES = Tweak.m
arg-capture_CFLAGS = -fobjc-arc -I./frameworks
arg-capture_LDFLAGS = -F./frameworks
arg-capture_FRAMEWORKS = libobjsee



include $(THEOS_MAKE_PATH)/tweak.mk
