include $(TOPDIR)/rules.mk

PKG_NAME:=newt
PKG_VERSION:=0.52.24
PKG_RELEASE:=3

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://releases.pagure.org/newt
PKG_HASH:=5ded7e221f85f642521c49b1826c8de19845aa372baf5d630a51774b544fbdbb

PKG_LICENSE:=LGPL-2.0-only
PKG_LICENSE_FILES:=COPYING
PKG_INSTALL:=1
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define Package/libnewt
  SECTION:=libs
  CATEGORY:=Libraries
  SOURCE:=packages/newt-gpm
  TITLE:=Newt text UI library with Linux console mouse support
  URL:=https://pagure.io/newt
  DEPENDS:=+libslang2
endef

define Package/libnewt/description
 Newt widget library built with its GPM protocol client enabled.
endef

define Package/whiptail
  SECTION:=utils
  CATEGORY:=Utilities
  SOURCE:=packages/newt-gpm
  TITLE:=Whiptail with Linux console mouse support
  URL:=https://pagure.io/newt
  DEPENDS:=+libnewt +libpopt +libslang2
endef

define Package/whiptail/description
 Whiptail built against the GPM-enabled Newt variant for the installer.
endef

CONFIGURE_ARGS += \
	--enable-largefile \
	--without-python \
	--without-tcl \
	--with-gpm-support \
	--disable-nls \
	--with-colorsfile=/etc/newt/palette

define Build/InstallDev
	$(INSTALL_DIR) $(1)/usr/include
	$(CP) $(PKG_INSTALL_DIR)/usr/include/newt.h $(1)/usr/include/
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libnewt.{a,so*} $(1)/usr/lib/
	$(INSTALL_DIR) $(1)/usr/lib/pkgconfig
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/pkgconfig/libnewt.pc $(1)/usr/lib/pkgconfig/
endef

define Package/libnewt/install
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libnewt.so* $(1)/usr/lib/
endef

define Package/whiptail/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/whiptail $(1)/usr/bin/
endef

$(eval $(call BuildPackage,libnewt))
$(eval $(call BuildPackage,whiptail))
