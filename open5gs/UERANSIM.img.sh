#!/bin/sh
set -ex

LATEST_LTS=$(curl -skL https://releases.ubuntu.com | awk '($0 ~ "p-list__item") && ($0 !~ "Beta") {sub(/\(/,"",$(NF-1));print tolower($(NF-1));exit}')
IMIRROR=${IMIRROR:-http://archive.ubuntu.com/ubuntu}
LINUX_KERNEL=linux-image-generic

include_apps="systemd,systemd-sysv,openssh-server,ca-certificates"
include_apps+=",${LINUX_KERNEL},extlinux,initramfs-tools,busybox"
include_apps+=",libsctp1,tcpdump,iproute2"
enable_services="systemd-networkd.service ssh.service"
disable_services="fstrim.timer motd-news.timer systemd-timesyncd.service"

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y --no-install-recommends mmdebstrap qemu-utils

TARGET_DIR=/tmp/ueransim

qemu-img create -f raw /tmp/ueransim.raw 22G
loopx=$(losetup --show -f -P /tmp/ueransim.raw)

mkfs.ext4 -F -L ubuntu-root -b 1024 -I 128 -O "^has_journal" $loopx

mkdir -p ${TARGET_DIR}
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
           --dpkgopt='path-exclude=/usr/share/locale/*' \
           --dpkgopt='path-include=/usr/share/locale/en*' \
           --dpkgopt='path-include=/usr/share/locale/locale.alias' \
           --dpkgopt='path-exclude=/lib/firmware/*' \
           --dpkgopt='path-exclude=/lib/modules/*/kernel/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/arch/x86/events/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/arch/x86/kvm/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/crypto/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/drivers/ata/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/drivers/block/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/drivers/char/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/drivers/firmware/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/drivers/gpu/drm/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/drivers/gpu/drm/ttm/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/drivers/i2c/busses/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/drivers/input/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/drivers/input/mouse/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/drivers/input/serio/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/drivers/macintosh/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/drivers/mfd/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/drivers/net/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/drivers/parport/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/drivers/powercap/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/drivers/pps/clients/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/drivers/ptp/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/drivers/staging/comedi/drivers/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/drivers/video/fbdev/core/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/fs/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/lib/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/net/core/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/net/ipv4/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/net/ipv6/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/net/netfilter/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/net/sched/*' \
           --dpkgopt='path-include=/lib/modules/*/kernel/net/sctp/*' \
           --dpkgopt='path-exclude=/lib/modules/*sound*' \
           --dpkgopt='path-exclude=/lib/modules/*wireless*' \
           --customize-hook='echo "root:ueransim" | chroot "$1" chpasswd' \
           --customize-hook='echo ueransim > "$1/etc/hostname"' \
           --customize-hook='find $1/usr/*/locale -mindepth 1 -maxdepth 1 ! -name "en*" ! -name "locale-archive" -prune -exec rm -rf {} +' \
           --customize-hook='find $1/usr -type d -name __pycache__ -prune -exec rm -rf {} +' \
           --customize-hook='rm -rf $1/etc/localtime $1/usr/share/doc $1/usr/share/man $1/usr/share/i18n $1/usr/share/X11 $1/usr/share/iso-codes $1/tmp/* $1/var/log/* $1/var/tmp/* $1/var/cache/apt/* $1/var/lib/apt/lists/* $1/usr/bin/perl*.* $1/usr/bin/systemd-analyze $1/boot/System.map-*' \
           --components="main restricted universe multiverse" \
           --variant=apt \
           --include=${include_apps} \
           ${LATEST_LTS} \
           ${TARGET_DIR} \
           "deb [trusted=yes] ${IMIRROR} ${LATEST_LTS} main restricted universe multiverse" \
           "deb [trusted=yes] ${IMIRROR} ${LATEST_LTS}-updates main restricted universe multiverse" \
           "deb [trusted=yes] ${IMIRROR} ${LATEST_LTS}-security main restricted universe multiverse"

mount -t proc none ${TARGET_DIR}/proc
mount -o bind /sys ${TARGET_DIR}/sys
mount -o bind /dev ${TARGET_DIR}/dev

cat << EOF > ${TARGET_DIR}/etc/fstab
LABEL=ubuntu-root /        ext4  defaults,noatime                0 0
tmpfs             /tmp     tmpfs mode=1777,size=90%              0 0
tmpfs             /var/log tmpfs defaults,noatime                0 0
EOF

mkdir -p ${TARGET_DIR}/root/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDyuzRtZAyeU3VGDKsGk52rd7b/rJ/EnT8Ce2hwWOZWp" >> ${TARGET_DIR}/root/.ssh/authorized_keys
chmod 600 ${TARGET_DIR}/root/.ssh/authorized_keys

cat << EOF > ${TARGET_DIR}/etc/systemd/network/20-dhcp.network
[Match]
Name=en*10

[Network]
DHCP=yes
IPv6AcceptRA=yes
EOF

cat << EOF > ${TARGET_DIR}/root/.bashrc
export HISTSIZE=1000 LESSHISTFILE=/dev/null HISTFILE=/dev/null
EOF

mkdir -p ${TARGET_DIR}/boot/syslinux
cat << EOF > ${TARGET_DIR}/boot/syslinux/syslinux.cfg
PROMPT 0
TIMEOUT 0
DEFAULT ueransim
LABEL ueransim
        LINUX /boot/vmlinuz
        INITRD /boot/initrd.img
        APPEND root=LABEL=ubuntu-root console=tty1 console=ttyS0 quiet
EOF

chroot ${TARGET_DIR} /bin/bash -c "
systemctl enable $enable_services
systemctl disable $disable_services
dd if=/usr/lib/EXTLINUX/mbr.bin of=$loopx
extlinux -i /boot/syslinux
"

echo 'ueransim' > ${TARGET_DIR}/etc/hostname

echo UERANSIM
UERANSIM_VERSION=$(ls /tmp/UERANSIM-*.tar.gz | sed -e 's|/tmp/UERANSIM-||' -e 's|.tar.gz||')
tar -xvf /tmp/UERANSIM-${UERANSIM_VERSION}.tar.gz -C ${TARGET_DIR}/usr/bin

sleep 1
sync ${TARGET_DIR}
umount ${TARGET_DIR}/dev ${TARGET_DIR}/proc ${TARGET_DIR}/sys
sleep 1
killall provjobd || true
sleep 1
umount ${TARGET_DIR}
sleep 1
losetup -d $loopx

qemu-img convert -c -f raw -O qcow2 /tmp/ueransim.raw /tmp/ueransim-${UERANSIM_VERSION}-${LATEST_LTS}.img
