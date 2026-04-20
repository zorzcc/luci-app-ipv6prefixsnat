include $(TOPDIR)/rules.mk

PKG_LICENSE:=GPL-3.0-only
PKG_MAINTAINER:=you

LUCI_TITLE:=LuCI support for automatic IPv6 prefix translation
LUCI_DEPENDS:=+luci-base +rpcd +uhttpd-mod-ubus +firewall4 +nftables +jsonfilter +libubox
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-ipv6prefixsnat/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/ipv6prefixsnat $(1)/etc/config/ipv6prefixsnat

	# 不直接装到 /etc/init.d，避免 apk/default_postinst 自动 enable/start
	$(INSTALL_DIR) $(1)/usr/share/ipv6prefixsnat
	$(INSTALL_BIN) ./root/usr/share/ipv6prefixsnat/ipv6prefixsnat.init \
		$(1)/usr/share/ipv6prefixsnat/ipv6prefixsnat.init

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/99-ipv6prefixsnat \
		$(1)/etc/uci-defaults/99-ipv6prefixsnat

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./root/etc/hotplug.d/iface/95-ipv6prefixsnat \
		$(1)/etc/hotplug.d/iface/95-ipv6prefixsnat

	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./root/usr/libexec/ipv6prefixsnat.sh \
		$(1)/usr/libexec/ipv6prefixsnat.sh

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/ipv6prefixsnat \
		$(1)/usr/libexec/rpcd/ipv6prefixsnat

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-ipv6prefixsnat.json \
		$(1)/usr/share/luci/menu.d/luci-app-ipv6prefixsnat.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-ipv6prefixsnat.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-ipv6prefixsnat.json

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/ipv6prefixsnat
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/ipv6prefixsnat/settings.js \
		$(1)/www/luci-static/resources/view/ipv6prefixsnat/settings.js
endef

define Package/luci-app-ipv6prefixsnat/postinst
#!/bin/sh
exit 0
endef

define Package/luci-app-ipv6prefixsnat/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

/usr/libexec/ipv6prefixsnat.sh disable >/dev/null 2>&1 || true
rm -f /etc/rc.d/S??ipv6prefixsnat /etc/rc.d/K??ipv6prefixsnat
rm -f /etc/init.d/ipv6prefixsnat

/etc/init.d/rpcd reload >/dev/null 2>&1 || true

exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
