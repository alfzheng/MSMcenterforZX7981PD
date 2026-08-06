include $(TOPDIR)/rules.mk

PKG_NAME:=modem-sms-broker
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=ZX7981PD SMS Project

include $(INCLUDE_DIR)/package.mk

define Package/modem-sms-broker
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Single-owner SMS serial broker foundation
  DEPENDS:=+libubus +libubox +libuci
endef

define Package/modem-sms-broker/description
 A disabled-by-default serial owner foundation for the SMS broker. It exposes
 a private scan lease and bounded indexed reads; it does not replace lteat or
 enable device deletion until the compatibility and target gates pass.
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_CPPFLAGS) \
		-I$(STAGING_DIR)/usr/include \
		-o $(PKG_BUILD_DIR)/modem-sms-broker \
		./src/modem-sms-broker.c \
		$(TARGET_LDFLAGS) -lubus -lubox -luci
endef

define Package/modem-sms-broker/conffiles
/etc/config/modem-sms-broker
endef

define Package/modem-sms-broker/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/modem-sms-broker $(1)/etc/config/modem-sms-broker
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/modem-sms-broker $(1)/etc/init.d/modem-sms-broker
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/modem-sms-broker $(1)/usr/sbin/modem-sms-broker
endef

$(eval $(call BuildPackage,modem-sms-broker))
