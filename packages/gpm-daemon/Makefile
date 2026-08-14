include $(TOPDIR)/rules.mk

PKG_NAME:=gpm
PKG_VERSION:=1.20.7
PKG_RELEASE:=4

PKG_SOURCE:=$(PKG_NAME)_$(PKG_VERSION).orig.tar.gz
PKG_SOURCE_URL:=https://deb.debian.org/debian/pool/main/g/gpm
PKG_HASH:=c7e4661c24e05ae13547176b649bac8e3a0db2575f7dd57559f9e0b509f90f49
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

PKG_LICENSE:=GPL-2.0-or-later
PKG_LICENSE_FILES:=COPYING

include $(INCLUDE_DIR)/package.mk

define Package/gpm-daemon
  SECTION:=utils
  CATEGORY:=Utilities
  SOURCE:=packages/gpm-daemon
  TITLE:=Minimal GPM mouse daemon for the OpenWrt installer
  URL:=https://github.com/telmich/gpm
  DEPENDS:=+libc +libgcc
endef

define Package/gpm-daemon/description
 GPM console mouse server packaged without its legacy client utilities.
 The installer profile supplies the matching input-event kernel module and
 runs the daemon with kernel selection and paste support compiled out.
endef

CONFIGURE_ARGS += \
	--without-curses \
	--disable-static

define Build/Prepare
	$(call Build/Prepare/Default)
	(cd $(PKG_BUILD_DIR) && ./autogen.sh)
endef

define Build/Compile
	touch $(PKG_BUILD_DIR)/src/prog/gpm-root.c
	touch $(PKG_BUILD_DIR)/src/.depend
	+$(MAKE_VARS) $(MAKE) $(PKG_JOBS) -C $(PKG_BUILD_DIR)/src gpm
endef

define Package/gpm-daemon/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/src/gpm $(1)/usr/sbin/gpm
endef

$(eval $(call BuildPackage,gpm-daemon))
