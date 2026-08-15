include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=input-mousedev
PKG_VERSION:=6.12.94
PKG_RELEASE:=1

PKG_SOURCE:=mousedev-$(PKG_VERSION).c
PKG_SOURCE_URL:=https://raw.githubusercontent.com/gregkh/linux/v$(PKG_VERSION)/drivers/input
PKG_SOURCE_URL_FILE:=mousedev.c
PKG_HASH:=557ca92e46bcb2ed1d65265fad230a366b4c9fe9891ee6ffb24c411d58f080ba
UNPACK_CMD=$(CP) $(DL_DIR)/$(PKG_SOURCE) $(1)/mousedev.c

PKG_LICENSE:=GPL-2.0-only
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define KernelPackage/input-mousedev
  SUBMENU:=Input modules
  TITLE:=PS/2-compatible mouse device multiplexer
  SOURCE:=packages/input-mousedev
  DEPENDS:=+kmod-input-core
  FILES:=$(PKG_BUILD_DIR)/mousedev.ko
  AUTOLOAD:=$(call AutoProbe,mousedev)
endef

define KernelPackage/input-mousedev/description
 Linux input compatibility handler providing per-device mouse nodes and the
 aggregate /dev/input/mice stream for relative and absolute pointer devices.
endef

define Build/Prepare
	$(call Build/Prepare/Default)
	$(CP) ./files/Kbuild $(PKG_BUILD_DIR)/Kbuild
endef

define Build/Compile
	+$(KERNEL_MAKE) $(PKG_JOBS) M="$(PKG_BUILD_DIR)" modules
endef

$(eval $(call KernelPackage,input-mousedev))
