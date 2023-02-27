#!/bin/sh
set -ex

EVE_UBUNTU_VERSION=$(curl -skL https://www.eve-ng.net/index.php/documentation/installation/system-requirement | awk -F' ' '/>Ubuntu/ {print tolower($4)}')
EVE_COM_VERSION=$(curl -skL https://www.eve-ng.net/focal/dists/focal/main/binary-amd64/Packages | awk '/Package: eve-ng$/ {getline;print $2}')
IMIRROR=${IMIRROR:-http://archive.ubuntu.com/ubuntu}
LINUX_KERNEL=linux-image-kvm

include_apps="systemd,systemd-sysv,ca-certificates"
include_apps+=",${LINUX_KERNEL},extlinux,initramfs-tools,busybox"
include_apps+=",eve-ng"
enable_services="systemd-networkd.service"
disable_services="fstrim.timer motd-news.timer systemd-timesyncd.service"

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y --no-install-recommends mmdebstrap qemu-utils

TARGET_DIR=/tmp/eve-com

qemu-img create -f raw /tmp/eve-com.raw 5G
loopx=$(losetup --show -f -P /tmp/eve-com.raw)

mkfs.ext4 -F -L eve-com-root -b 1024 -I 128 -O "^has_journal" $loopx

mkdir -p ${TARGET_DIR}
mount $loopx ${TARGET_DIR}

# wget -O - http://www.eve-ng.net/focal/eczema@ecze.com.gpg.key | sudo apt-key add -

mmdebstrap --debug \
           --aptopt='Apt::Install-Recommends "false"' \
           --aptopt='Apt::Install-Suggests "false"' \
           --aptopt='APT::Authentication  "false"' \
           --aptopt='APT::Get::AllowUnauthenticated "true"' \
           --aptopt='Acquire::AllowInsecureRepositories "true"' \
           --aptopt='Acquire::AllowDowngradeToInsecureRepositories "true"' \
           --dpkgopt='no-debsig' \
           --dpkgopt='path-exclude=/usr/share/initramfs-tools/hooks/fixrtc' \
           --customize-hook='echo "root:eve" | chroot "$1" chpasswd' \
           --customize-hook='echo eve-ng > "$1/etc/hostname"' \
           --customize-hook='chroot "$1" locale-gen en_US.UTF-8' \
           --customize-hook='find $1/usr/*/locale -mindepth 1 -maxdepth 1 ! -name "en*" ! -name "locale-archive" -prune -exec rm -rf {} +' \
           --customize-hook='find $1/usr -type d -name __pycache__ -prune -exec rm -rf {} +' \
           --customize-hook='rm -rf $1/etc/localtime $1/usr/share/doc $1/usr/share/man $1/usr/share/i18n $1/usr/share/X11 $1/usr/share/iso-codes $1/tmp/* $1/var/log/* $1/var/tmp/* $1/var/cache/apt/* $1/var/lib/apt/lists/* $1/usr/bin/perl*.* $1/usr/bin/systemd-analyze $1/boot/System.map-*' \
           --components="main restricted universe multiverse" \
           --variant=essential \
           --include=${include_apps} \
           ${EVE_UBUNTU_VERSION} \
           ${TARGET_DIR} \
           "deb [trusted=yes] ${IMIRROR} ${EVE_UBUNTU_VERSION} main restricted universe multiverse" \
           "deb [trusted=yes] ${IMIRROR} ${EVE_UBUNTU_VERSION}-updates main restricted universe multiverse" \
           "deb [trusted=yes] ${IMIRROR} ${EVE_UBUNTU_VERSION}-security main restricted universe multiverse" \
           "deb [trusted=yes] https://www.eve-ng.net/${EVE_UBUNTU_VERSION} ${EVE_UBUNTU_VERSION} main"

mount -t proc none ${TARGET_DIR}/proc
mount -o bind /sys ${TARGET_DIR}/sys
mount -o bind /dev ${TARGET_DIR}/dev

cat << EOF > ${TARGET_DIR}/etc/fstab
LABEL=eve-com-root /        ext4  defaults,noatime               0 0
tmpfs             /tmp     tmpfs mode=1777,size=90%              0 0
tmpfs             /var/log tmpfs defaults,noatime                0 0
EOF

mkdir -p ${TARGET_DIR}/etc/systemd/system-environment-generators
cat << EOF > ${TARGET_DIR}/etc/systemd/system-environment-generators/20-python
#!/bin/sh
echo 'PYTHONDONTWRITEBYTECODE=1'
echo 'PYTHONSTARTUP=/usr/lib/pythonstartup'
EOF
chmod +x ${TARGET_DIR}/etc/systemd/system-environment-generators/20-python

cat << EOF > ${TARGET_DIR}/etc/profile.d/python.sh
#!/bin/sh
export PYTHONDONTWRITEBYTECODE=1 PYTHONSTARTUP=/usr/lib/pythonstartup
EOF

cat << EOF > ${TARGET_DIR}/usr/lib/pythonstartup
import readline
import time
readline.add_history("# " + time.asctime())
readline.set_history_length(-1)
EOF

cat << EOF > ${TARGET_DIR}/etc/systemd/network/20-dhcp.network
[Match]
Name=en*

[Network]
DHCP=yes
IPv6AcceptRA=yes
EOF

cat << EOF > ${TARGET_DIR}/root/.bashrc
export HISTSIZE=1000 LESSHISTFILE=/dev/null HISTFILE=/dev/null PYTHONWARNINGS=ignore
EOF

mkdir -p ${TARGET_DIR}/boot/syslinux
cat << EOF > ${TARGET_DIR}/boot/syslinux/syslinux.cfg
PROMPT 0
TIMEOUT 0
DEFAULT eve-com
LABEL eve-com
        LINUX /boot/vmlinuz
        INITRD /boot/initrd.img
        APPEND root=LABEL=eve-com-root console=tty1 console=ttyS0 quiet intel_iommu=on iommu=pt
EOF

chroot ${TARGET_DIR} /bin/bash -c "
systemctl enable $enable_services
systemctl disable $disable_services
dd if=/usr/lib/EXTLINUX/mbr.bin of=$loopx
extlinux -i /boot/syslinux
dd if=/dev/zero of=/tmp/bigfile
sync
rm -f /tmp/bigfile
sync
"

sync ${TARGET_DIR}
umount ${TARGET_DIR}/dev ${TARGET_DIR}/proc ${TARGET_DIR}/sys
sleep 1
killall provjobd || true
sleep 1
umount ${TARGET_DIR}
sleep 1
losetup -d $loopx

qemu-img convert -c -f raw -O qcow2 /tmp/eve-com.raw /tmp/eve-com-${EVE_COM_VERSION}-${EVE_UBUNTU_VERSION}.img
