#!/bin/sh
set -ex

OPENWRTURL="https://downloads.openwrt.org/snapshots/targets/x86/generic/openwrt-imagebuilder-x86-generic.Linux-x86_64.tar.xz"
curl -skL ${OPENWRTURL} | tar -xJ

cd openwrt-imagebuilder-*

cat << EOF >> .config
CONFIG_IMAGEOPT=y
CONFIG_PREINITOPT=y
CONFIG_TARGET_PREINIT_DISABLE_FAILSAFE=y
CONFIG_TARGET_ROOTFS_SQUASHFS=n
CONFIG_GRUB_EFI_IMAGES=n
CONFIG_GRUB_TIMEOUT="0"
CONFIG_SIGNED_PACKAGES=n
CONFIG_SIGNATURE_CHECK=n
CONFIG_KERNEL_PRINTK=n
CONFIG_KERNEL_CRASHLOG=n
CONFIG_KERNEL_SWAP=n
CONFIG_KERNEL_KALLSYMS=n
CONFIG_KERNEL_DEBUG_INFO=n
CONFIG_KERNEL_ELF_CORE=n
CONFIG_KERNEL_MAGIC_SYSRQ=n
CONFIG_KERNEL_PRINTK_TIME=n
CONFIG_PACKAGE_MAC80211_DEBUGFS=n
CONFIG_PACKAGE_MAC80211_MESH=n
CONFIG_STRIP_KERNEL_EXPORTS=y
#CONFIG_USE_MKLIBS=y
CONFIG_SERIAL_8250=n
CONFIG_EARLY_PRINTK=n
EOF

make image DISABLED_SERVICES="network odhcpd cron gpio_switch led sysntpd" PACKAGES="frr \
frr-babeld \
frr-bfdd \
frr-bgpd \
frr-eigrpd \
frr-fabricd \
frr-isisd \
frr-ldpd \
frr-libfrr \
frr-nhrpd \
frr-ospf6d \
frr-ospfd \
frr-pbrd \
frr-pimd \
frr-ripd \
frr-ripngd \
frr-staticd \
frr-vrrpd \
frr-vtysh \
frr-watchfrr \
frr-zebra \
-ppp \
-ppp-mod-pppoe \
-dnsmasq \
-dropbear \
-fstools \
-logd \
-opkg \
-kmod-3c59x \
-kmod-8139too \
-kmod-button-hotplug \
-kmod-e100 \
-kmod-e1000 \
-kmod-forcedeth \
-kmod-fs-vfat \
-kmod-natsemi \
-kmod-ne2k-pci \
-kmod-pcnet32 \
-kmod-r8169 \
-kmod-sis900 \
-kmod-tg3 \
-kmod-via-rhine \
-kmod-via-velocity"

#cp bin/targets/x86/generic/openwrt-x86-generic-generic-ext4-combined.img.gz /tmp/boot2wrt-$(date "+%Y%m%d").img.gz
gzip -d -c bin/targets/x86/generic/openwrt-x86-generic-generic-ext4-combined.img.gz > /tmp/boot2wrt.raw
qemu-img convert -f raw -O qcow2 -c /tmp/boot2wrt.raw /tmp/boot2wrt.img
