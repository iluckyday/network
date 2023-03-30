#!/bin/sh
set -x

DVERSION=$(curl -skL https://www.debian.org/releases/ | grep -oP 'codenamed <em>\K(.*)(?=</em>)')
DVERSION_NUM=$(curl -skL https://www.debian.org/releases/ | grep -oP '  \K(.*)(?=, codenamed)')
MIRROR=${MIRROR:-http://deb.debian.org/debian}
LINUX_KERNEL=linux-image-cloud-amd64

include_apps="systemd,systemd-sysv,dbus,ca-certificates"
include_apps+=",${LINUX_KERNEL},extlinux,initramfs-tools,busybox"
include_apps+=",procps,locales"
include_apps+=",libsctp1,tcpdump,iproute2,iptables"
include_apps+=",open5gs"
include_apps+=",libmnl0,libyaml-0-2"
# include_apps+=",kea"
include_apps+=",openssh-server"
enable_services="systemd-networkd.service systemd-resolved.service ssh.service"
disable_services="apt-daily.timer apt-daily-upgrade.timer dpkg-db-backup.timer e2scrub_all.timer fstrim.timer motd-news.timer systemd-timesyncd.service"

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y --no-install-recommends mmdebstrap qemu-system-x86 qemu-utils upx sshpass

curl -skL https://download.opensuse.org/repositories/home:/acetcom:/open5gs:/latest/Debian_${DVERSION_NUM}/Release.key | gpg --dearmour -o /etc/apt/trusted.gpg.d/open5gs_debian_${DVERSION_NUM}.gpg

TARGET_DIR=/tmp/clab.tmp

qemu-img create -f raw /tmp/clab.tmp.raw 10G
loopx=$(losetup --show -f -P /tmp/clab.tmp.raw)
mkfs.ext4 -F -L debian-root -b 1024 -I 128 -O "^has_journal" $loopx

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
           --dpkgopt='path-exclude=/usr/bin/bsondump' \
           --dpkgopt='path-exclude=/usr/bin/mongos' \
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
           --customize-hook='rm -rf $1/etc/resolv.conf $1/etc/localtime $1/usr/share/doc $1/usr/share/man $1/usr/share/i18n $1/usr/share/X11 $1/usr/share/iso-codes $1/tmp/* $1/var/log/* $1/var/tmp/* $1/var/cache/apt/* $1/var/lib/apt/lists/* $1/usr/bin/perl*.* $1/usr/bin/systemd-analyze $1/boot/System.map-*' \
           --components="main contrib non-free" \
           --variant=apt \
           --include=${include_apps} \
           ${DVERSION} \
           ${TARGET_DIR} \
           "deb ${MIRROR} stable main contrib non-free" \
           "deb ${MIRROR} stable-updates main contrib non-free" \
           "deb [trusted=yes] https://downloads.osmocom.org/packages/osmocom:/nightly/Debian_${DVERSION_NUM}/ ./" \
           "deb [trusted=yes] https://repo.mongodb.org/apt/debian ${DVERSION}/mongodb-org/6.0 main"

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
cat << EOF > ${TARGET_DIR}/boot/syslinux/syslinux.cfg
PROMPT 0
TIMEOUT 0
DEFAULT clab
LABEL clab
        LINUX /vmlinuz
        INITRD /initrd.img
        APPEND root=LABEL=debian-root quiet console=ttyS0
EOF

curl -skL -o ${TARGET_DIR}/usr/bin/open5gs-dbctl https://github.com/open5gs/open5gs/raw/main/misc/db/open5gs-dbctl
chmod +x ${TARGET_DIR}/usr/bin/open5gs-dbctl

mount -t proc none ${TARGET_DIR}/proc
mount -o bind /sys ${TARGET_DIR}/sys
mount -o bind /dev ${TARGET_DIR}/dev

chroot ${TARGET_DIR} /bin/bash -c "
systemctl enable $enable_services
systemctl disable $disable_services

rm -rf /etc/systemd/system/multi-user.target.wants/open5gs-*.service

dd if=/usr/lib/EXTLINUX/mbr.bin of=$loopx
extlinux -i /boot/syslinux
"

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
