include $(TOPDIR)/rules.mk

PKG_NAME:=modem-smsd
PKG_VERSION:=0.1.0
PKG_RELEASE:=16
PKG_LICENSE:=MIT
PKG_MAINTAINER:=ZX7981PD SMS Project

include $(INCLUDE_DIR)/package.mk

define Package/modem-smsd
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Module-independent SMS service for OpenWrt
  DEPENDS:=+ubus +ucode +ucode-mod-ubus +ucode-mod-uloop +ucode-mod-uci +ucode-mod-fs
endef

define Package/modem-smsd/description
 A small ubus service that validates, decodes and sends SMS messages through
 a replaceable modem backend. The initial backend wraps the firmware lteat
 ubus object and never opens a modem TTY directly.
endef

define Package/modem-smsd/conffiles
/etc/config/modem-sms
endef

define Build/Compile
endef

define Package/modem-smsd/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/modem-sms $(1)/etc/config/modem-sms
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/modem-smsd $(1)/etc/init.d/modem-smsd
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/modem-smsd $(1)/usr/sbin/modem-smsd
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/modem-smsctl $(1)/usr/bin/modem-smsctl
	$(INSTALL_DIR) $(1)/usr/share/modem-sms
	$(INSTALL_DATA) ./files/usr/share/modem-sms/core.uc $(1)/usr/share/modem-sms/core.uc
	$(INSTALL_DATA) ./files/usr/share/modem-sms/backend-lteat.uc $(1)/usr/share/modem-sms/backend-lteat.uc
endef

$(eval $(call BuildPackage,modem-smsd))
