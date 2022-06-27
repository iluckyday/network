#!/bin/sh
set -ex

DVERSION=sid
MIRROR=${MIRROR:-http://deb.debian.org/debian}
LINUX_KERNEL=linux-image-cloud-amd64

include_apps="systemd,systemd-sysv,dbus,ca-certificates,openssh-server"
include_apps+=",${LINUX_KERNEL},extlinux,initramfs-tools"
include_apps+=",make,gcc,g++,linux-headers-cloud-amd64"
enable_services="systemd-networkd systemd-resolved ssh"

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y --no-install-recommends mmdebstrap qemu-utils qemu-system-x86

TARGET_DIR=/tmp/gtp5g
mkdir -p ${TARGET_DIR}

qemu-img create -f raw /tmp/gtp5g.raw 2G
loopx=$(losetup --show -f -P /tmp/gtp5g.raw)
mkfs.ext4 -F -L debian-root -b 1024 -I 128 -O "^has_journal" $loopx
mount $loopx ${TARGET_DIR}

mmdebstrap --debug \
           --aptopt='Apt::Install-Recommends "false"' \
           --aptopt='Apt::Install-Suggests "false"' \
           --aptopt='APT::Authentication "false"' \
           --aptopt='APT::Get::AllowUnauthenticated "true"' \
           --aptopt='Acquire::AllowInsecureRepositories "true"' \
           --aptopt='Acquire::AllowDowngradeToInsecureRepositories "true"' \
           --aptopt='DPkg::Options::=--force-depends' \
           --dpkgopt='force-depends' \
           --dpkgopt='no-debsig' \
           --dpkgopt='path-exclude=/usr/share/initramfs-tools/hooks/fixrtc' \
           --customize-hook='find $1/usr/*/locale -mindepth 1 -maxdepth 1 ! -name "en*" ! -name "locale-archive" -prune -exec rm -rf {} +' \
           --customize-hook='find $1/usr -type d -name __pycache__ -prune -exec rm -rf {} +' \
           --customize-hook='rm -rf $1/etc/resolv.conf $1/etc/localtime $1/usr/share/doc $1/usr/share/man $1/usr/share/i18n $1/usr/share/X11 $1/usr/share/iso-codes $1/tmp/* $1/var/log/* $1/var/tmp/* $1/var/cache/apt/* $1/var/lib/apt/lists/* $1/usr/bin/perl*.* $1/usr/bin/systemd-analyze $1/boot/System.map-*' \
           --components="main contrib non-free" \
           --variant=apt \
           --include=${include_apps} \
           ${DVERSION} \
           ${TARGET_DIR} \
           "deb ${MIRROR} ${DVERSION} main contrib non-free"

mount -t proc none ${TARGET_DIR}/proc
mount -o bind /sys ${TARGET_DIR}/sys
mount -o bind /dev ${TARGET_DIR}/dev

cat << EOF > ${TARGET_DIR}/etc/fstab
LABEL=debian-root /        ext4  defaults,noatime                0 0
tmpfs             /tmp     tmpfs mode=1777,size=90%              0 0
tmpfs             /var/log tmpfs defaults,noatime                0 0
EOF

cat << EOF > ${TARGET_DIR}/etc/systemd/network/20-dhcp.network
[Match]
Name=en*

[Network]
DHCP=yes
EOF

mkdir -p ${TARGET_DIR}/boot/syslinux
cat << EOF > ${TARGET_DIR}/boot/syslinux/syslinux.cfg
PROMPT 0
TIMEOUT 0
DEFAULT gtp5g
LABEL gtp5g
        LINUX /vmlinuz
        INITRD /initrd.img
        APPEND root=LABEL=debian-root quiet
EOF

chroot ${TARGET_DIR} /bin/bash -c "
systemctl enable $enable_services
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
dd if=/usr/lib/EXTLINUX/mbr.bin of=$loopx
extlinux -i /boot/syslinux
"

ssh-keygen -q -P '' -f /root/.ssh/id_ed25519 -C '' -t ed25519
mkdir -p ${TARGET_DIR}/root/.ssh
ssh-keygen -y -f /root/.ssh/id_ed25519 >> ${TARGET_DIR}/root/.ssh/authorized_keys
chmod 600 ${TARGET_DIR}/root/.ssh/authorized_keys

git clone --depth=1 https://github.com/free5gc/gtp5g ${TARGET_DIR}/root/gtp5g

sleep 1
sync ${TARGET_DIR}
sleep 1
umount ${TARGET_DIR}/dev ${TARGET_DIR}/proc ${TARGET_DIR}/sys
sleep 1
killall provjobd || true
sleep 1
umount ${TARGET_DIR}
sleep 1
losetup -d $loopx

sleep 1
systemd-run -G -q qemu-system-x86_64 -machine q35,accel=kvm:hax:hvf:whpx:tcg -cpu kvm64 -smp "$(nproc)" -m 4G -display none -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 -boot c -drive file=/tmp/gtp5g.raw,if=virtio,format=raw,media=disk -netdev user,id=n0,ipv6=off,hostfwd=tcp:127.0.0.1:22222-:22 -device virtio-net,netdev=n0

sleep 30
ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22222 -l root 127.0.0.1 bash -sx << "CMD"
cd /root/gtp5g
sed -i 's|stdbool.h|linux/types.h|' api_version.c
sed -i '1i\#include <linux/etherdevice.h>' genl_far.c
make
CMD

sleep 1
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 22222 root@127.0.0.1:/root/gtp5g/gtp5g.ko /tmp/gtp5g.ko

sleep 1
ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22222 -l root 127.0.0.1 poweroff
