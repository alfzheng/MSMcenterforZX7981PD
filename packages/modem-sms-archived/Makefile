include $(TOPDIR)/rules.mk

PKG_NAME:=modem-sms-archived
PKG_VERSION:=0.1.0
PKG_RELEASE:=12
PKG_LICENSE:=MIT
PKG_MAINTAINER:=ZX7981PD SMS Project

include $(INCLUDE_DIR)/package.mk

define Package/modem-sms-archived
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Disabled-by-default local SMS archive foundation
  DEPENDS:=+lua +libubox-lua +libubus-lua +libuci-lua +lsqlite3 +libsqlite3-0
endef

define Package/modem-sms-archived/description
 A0 local SQLite archive foundation for the SMS service. The archive and
 archive-copy capabilities are disabled by default and this package never
 accesses the modem backend.
endef

define Package/modem-sms-archived/conffiles
/etc/config/modem-sms-archive
endef

define Build/Compile
endef

define Package/modem-sms-archived/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/modem-sms-archive $(1)/etc/config/modem-sms-archive
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/modem-sms-archived $(1)/etc/init.d/modem-sms-archived
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/modem-sms-archived $(1)/lib/upgrade/keep.d/modem-sms-archived
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/modem-sms-archived $(1)/usr/sbin/modem-sms-archived
	$(INSTALL_DIR) $(1)/usr/share/modem-sms
	$(INSTALL_DATA) ./files/usr/share/modem-sms/archive_schema.sql $(1)/usr/share/modem-sms/archive_schema.sql
	$(INSTALL_DATA) ./files/usr/share/modem-sms/archive_store.lua $(1)/usr/share/modem-sms/archive_store.lua
	$(INSTALL_DATA) ./files/usr/share/modem-sms/stagec_worker.lua $(1)/usr/share/modem-sms/stagec_worker.lua
endef

$(eval $(call BuildPackage,modem-sms-archived))
