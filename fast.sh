#!/bin/sh
set -ex

DVERSION=$(curl https://www.debian.org/releases/ | grep -oP 'codenamed <em>\K(.*)(?=</em>)')
MIRROR=${MIRROR:-http://deb.debian.org/debian}
LINUX_KERNEL=linux-image-cloud-amd64

include_apps="systemd,systemd-sysv,ca-certificates,openssh-server"
include_apps+=",${LINUX_KERNEL},extlinux,initramfs-tools,busybox"
include_apps+=",openvswitch-switch-dpdk,libdpdk-dev,dpdk-dev"
include_apps+=",vpp,vpp-plugin-core,vpp-plugin-dpdk,vpp-plugin-devtools,python3-vpp-api,vpp-dbg,vpp-dev"
enable_services="systemd-networkd.service ssh.service"
disable_services="apt-daily.timer apt-daily-upgrade.timer dpkg-db-backup.timer e2scrub_all.timer fstrim.timer motd-news.timer systemd-timesyncd.service"

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y --no-install-recommends mmdebstrap qemu-utils

TARGET_DIR=/tmp/fast

qemu-img create -f raw /tmp/fast.raw 2G
loopx=$(losetup --show -f -P /tmp/fast.raw)

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
           --dpkgopt='path-exclude=/usr/share/locale/*' \
           --dpkgopt='path-include=/usr/share/locale/en*' \
           --dpkgopt='path-include=/usr/share/locale/locale.alias' \
           --customize-hook='echo "root:fast" | chroot "$1" chpasswd' \
           --customize-hook='echo fast > "$1/etc/hostname"' \
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
           "deb ${MIRROR} ${DVERSION}-updates main contrib non-free" \
           "deb ${MIRROR} ${DVERSION}-proposed-updates main contrib non-free" \
           "deb [trusted=yes] https://packagecloud.io/fdio/release/debian ${DVERSION} main"

mount -t proc none ${TARGET_DIR}/proc
mount -o bind /sys ${TARGET_DIR}/sys
mount -o bind /dev ${TARGET_DIR}/dev

cat << EOF > ${TARGET_DIR}/etc/fstab
LABEL=debian-root /        ext4  defaults,noatime                0 0
tmpfs             /tmp     tmpfs mode=1777,size=90%              0 0
tmpfs             /var/log tmpfs defaults,noatime                0 0
EOF

mkdir -p ${TARGET_DIR}/root/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDyuzRtZAyeU3VGDKsGk52rd7b/rJ/EnT8Ce2hwWOZWp" >> ${TARGET_DIR}/root/.ssh/authorized_keys
chmod 600 ${TARGET_DIR}/root/.ssh/authorized_keys

cat << EOF > ${TARGET_DIR}/etc/systemd/network/20-dhcp.network
[Match]
Name=en*

[Network]
DHCP=yes
IPv6AcceptRA=yes
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

cat << EOF > ${TARGET_DIR}/root/.bashrc
export HISTSIZE=1000 LESSHISTFILE=/dev/null HISTFILE=/dev/null
EOF

mkdir -p ${TARGET_DIR}/boot/syslinux
cat << EOF > ${TARGET_DIR}/boot/syslinux/syslinux.cfg
PROMPT 0
TIMEOUT 0
DEFAULT fast
LABEL fast
        LINUX /vmlinuz
        INITRD /initrd.img
        APPEND root=LABEL=debian-root quiet intel_iommu=on iommu=pt
EOF

chroot ${TARGET_DIR} /bin/bash -c "
systemctl enable $enable_services
systemctl disable $disable_services

dd if=/usr/lib/EXTLINUX/mbr.bin of=$loopx
extlinux -i /boot/syslinux
dd if=/dev/zero of=/tmp/bigfile
sync
rm /tmp/bigfile
sync
"

sleep 1
sync ${TARGET_DIR}
umount ${TARGET_DIR}/dev ${TARGET_DIR}/proc ${TARGET_DIR}/sys
sleep 1
killall provjobd || true
sleep 1
umount ${TARGET_DIR}
sleep 1
losetup -d $loopx

qemu-img convert -c -f raw -O qcow2 /tmp/fast.raw /tmp/fast-${DVERSION}-$(date +"%Y%m%d").img
