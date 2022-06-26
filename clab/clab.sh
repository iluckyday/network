#!/bin/sh
set -ex

DVERSION=sid
MIRROR=${MIRROR:-http://deb.debian.org/debian}
LINUX_KERNEL=linux-image-cloud-amd64

include_apps="systemd,systemd-sysv,ca-certificates,openssh-server"
include_apps+=",${LINUX_KERNEL},extlinux,initramfs-tools,busybox"
include_apps+=",procps,locales"
include_apps+=",libsctp1,tcpdump,iproute2,iptables"
include_apps+=",open5gs"
include_apps+=",libmnl0,libyaml-0-2"
enable_services="systemd-networkd.service ssh.service"
disable_services="apt-daily.timer apt-daily-upgrade.timer dpkg-db-backup.timer e2scrub_all.timer fstrim.timer motd-news.timer systemd-timesyncd.service"

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y --no-install-recommends mmdebstrap qemu-utils extlinux

IMAGE_DIR=/tmp/clab
TARGET_DIR=/tmp/clab.tmp
BUILD_DIR=/tmp/build

mkdir -p ${IMAGE_DIR} ${TARGET_DIR}

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
           --dpkgopt='path-exclude=*__pycache__*' \
           --dpkgopt='path-exclude=*.py[co]' \
           --dpkgopt='path-exclude=/usr/share/doc/*' \
           --dpkgopt='path-exclude=/usr/share/man/*' \
           --dpkgopt='path-exclude=/usr/share/bug/*' \
           --dpkgopt='path-exclude=/usr/share/locale/*' \
           --dpkgopt='path-include=/usr/share/locale/en*' \
           --dpkgopt='path-include=/usr/share/locale/locale.alias' \
           --dpkgopt='path-exclude=/usr/lib/udev/hwdb.bin' \
           --dpkgopt='path-exclude=/usr/lib/udev/hwdb.d/*' \
           --dpkgopt='path-exclude=/usr/bin/mongosh' \
           --dpkgopt='path-exclude=/usr/bin/mongos' \
           --dpkgopt='path-exclude=/usr/bin/bsondump' \
           --dpkgopt='path-exclude=/usr/bin/mongodump' \
           --dpkgopt='path-exclude=/usr/bin/mongoexport' \
           --dpkgopt='path-exclude=/usr/bin/mongofiles' \
           --dpkgopt='path-exclude=/usr/bin/mongoimport' \
           --dpkgopt='path-exclude=/usr/bin/mongorestore' \
           --dpkgopt='path-exclude=/usr/bin/mongostat' \
           --dpkgopt='path-exclude=/usr/bin/mongotop' \
           --dpkgopt='path-exclude=/lib/modules/*sound*' \
           --dpkgopt='path-exclude=/lib/modules/*wireless*' \
           --customize-hook='echo "root:clab" | chroot "$1" chpasswd' \
           --customize-hook='echo clab > "$1/etc/hostname"' \
           --customize-hook='chroot "$1" locale-gen en_US.UTF-8' \
           --customize-hook='find $1/usr/*/locale -mindepth 1 -maxdepth 1 ! -name "en*" ! -name "locale-archive" -prune -exec rm -rf {} +' \
           --customize-hook='find $1/usr -type d -name __pycache__ -prune -exec rm -rf {} +' \
           --customize-hook='rm -rf $1/etc/localtime $1/usr/share/doc $1/usr/share/man $1/usr/share/i18n $1/usr/share/X11 $1/usr/share/iso-codes $1/tmp/* $1/var/log/* $1/var/tmp/* $1/var/cache/apt/* $1/var/lib/apt/lists/* $1/usr/bin/perl*.* $1/usr/bin/systemd-analyze $1/boot/System.map-*' \
           --components="main contrib non-free" \
           --variant=apt \
           --include=${include_apps} \
           ${DVERSION} \
           ${TARGET_DIR} \
           "deb ${MIRROR} ${DVERSION} main contrib non-free" \
           "deb [trusted=yes] http://download.opensuse.org/repositories/network:/osmocom:/nightly/Debian_Testing/ ./" \
           "deb [trusted=yes] http://repo.mongodb.org/apt/debian buster/mongodb-org/5.0 main"

# mount -t proc none ${TARGET_DIR}/proc
# mount -o bind /sys ${TARGET_DIR}/sys
# mount -o bind /dev ${TARGET_DIR}/dev

cat << EOF > ${TARGET_DIR}/etc/fstab
LABEL=debian-root /        ext4  defaults,noatime                0 0
tmpfs             /tmp     tmpfs mode=1777,size=90%              0 0
tmpfs             /var/log tmpfs defaults,noatime                0 0
EOF

mkdir -p ${TARGET_DIR}/root/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDyuzRtZAyeU3VGDKsGk52rd7b/rJ/EnT8Ce2hwWOZWp" >> ${TARGET_DIR}/root/.ssh/authorized_keys
chmod 600 ${TARGET_DIR}/root/.ssh/authorized_keys

sed -i 's/#\?\(PermitRootLogin\s*\).*$/\1 yes/' ${TARGET_DIR}/etc/ssh/sshd_config
sed -i 's/#\?\(PubkeyAuthentication\s*\).*$/\1 yes/' ${TARGET_DIR}/etc/ssh/sshd_config
sed -i 's/#\?\(PermitEmptyPasswords\s*\).*$/\1 no/' ${TARGET_DIR}/etc/ssh/sshd_config
sed -i 's/#\?\(PasswordAuthentication\s*\).*$/\1 yes/' ${TARGET_DIR}/etc/ssh/sshd_config

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
extlinux -i ${TARGET_DIR}/boot/syslinux
cat << EOF > ${TARGET_DIR}/boot/syslinux/syslinux.cfg
PROMPT 0
TIMEOUT 0
DEFAULT clab
LABEL clab
        LINUX /vmlinuz
        INITRD /initrd.img
        APPEND root=LABEL=debian-root quiet
EOF

echo copy build files
mkdir -p ${TARGET_DIR}/etc/ueransim
cp ${BUILD_DIR}/root/UERANSIM-*/config/* ${TARGET_DIR}/etc/ueransim
cp ${BUILD_DIR}/root/UERANSIM-*/build/* ${TARGET_DIR}/usr/bin

mkdir -p ${TARGET_DIR}/etc/free5gc
cp -r ${BUILD_DIR}/root/free5gc/config/* ${TARGET_DIR}/etc/free5gc
for i in $(cd ${BUILD_DIR}/root/free5gc/bin;ls);do
	cp -a ${BUILD_DIR}/root/free5gc/bin/$i ${TARGET_DIR}/usr/bin/free5gc-${i}d
done
cp ${BUILD_DIR}/root/free5gc/NFs/upf/build/bin/free5gc-upfd ${TARGET_DIR}/usr/bin
cp -r ${BUILD_DIR}/root/free5gc/NFs/upf/build/config/* ${TARGET_DIR}/etc/free5gc
cp ${BUILD_DIR}/root/free5gc/NFs/upf/build/updk/src/third_party/libgtp5gnl/lib/libgtp5gnl.so* ${TARGET_DIR}/usr/local/lib
cp ${BUILD_DIR}/root/free5gc/NFs/upf/build/utlt_logger/liblogger.so* ${TARGET_DIR}/usr/local/lib

chroot ${TARGET_DIR} /bin/bash -c "
systemctl enable $enable_services
systemctl disable $disable_services
ldconfig

rm -rf /etc/systemd/system/multi-user.target.wants/open5gs-*.service
"

IMAGE_SIZE=$(du -s --block-size=1G ${TARGET_DIR} | awk '{print $1}')
qemu-img create -f raw /tmp/clab.raw ${IMAGE_SIZE}G
loopx=$(losetup --show -f -P /tmp/clab.raw)
mkfs.ext4 -F -L debian-root -b 1024 -I 128 -O "^has_journal" $loopx
mount $loopx ${IMAGE_DIR}
dd if=/usr/lib/EXTLINUX/mbr.bin of=$loopx

sleep 1
sync ${TARGET_DIR}
cp -a ${TARGET_DIR}/* ${IMAGE_DIR}
sleep 1

sleep 1
# umount ${TARGET_DIR}/dev ${TARGET_DIR}/proc ${TARGET_DIR}/sys
sleep 1
killall provjobd || true
sleep 1
umount ${IMAGE_DIR}
sleep 1
losetup -d $loopx

qemu-img convert -c -f raw -O qcow2 /tmp/clab.raw /tmp/clab-$(date +"%Y%m%d").img
