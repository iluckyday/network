#!/bin/sh
set -ex

LATEST_LTS=$(curl -skL https://releases.ubuntu.com | awk '($0 ~ "p-list__item") && ($0 !~ "Beta") {sub(/\(/,"",$(NF-1));print tolower($(NF-1));exit}')
LATEST_LTS=focal
OPEN5GS_VERSION=$(curl -kL https://launchpad.net/~open5gs/+archive/ubuntu/latest | awk -F'~' '/~'''$LATEST_LTS'''/ {gsub(/ /,"",$1);print $1}')
IMIRROR=${IMIRROR:-http://archive.ubuntu.com/ubuntu}
LINUX_KERNEL=linux-image-kvm

include_apps="systemd,systemd-sysv,ca-certificates"
include_apps+=",${LINUX_KERNEL},extlinux,initramfs-tools,busybox"
include_apps+=",procps,locales"
include_apps+=",libsctp1"
include_apps+=",open5gs"
enable_services="systemd-networkd.service"
disable_services="fstrim.timer motd-news.timer systemd-timesyncd.service"

export DEBIAN_FRONTEND=noninteractive
add-apt-repository ppa:open5gs/latest
apt update
apt install -y --no-install-recommends mmdebstrap qemu-utils

TARGET_DIR=/tmp/open5gs

qemu-img create -f raw /tmp/open5gs.raw 504G
loopx=$(losetup --show -f -P /tmp/open5gs.raw)

mkfs.ext4 -F -L open5gs-root -b 1024 -I 128 -O "^has_journal" $loopx

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
           --customize-hook='echo "root:open5gs" | chroot "$1" chpasswd' \
           --customize-hook='echo open5gs > "$1/etc/hostname"' \
           --customize-hook='chroot "$1" locale-gen en_US.UTF-8' \
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
           "deb [trusted=yes] ${IMIRROR} ${LATEST_LTS}-security main restricted universe multiverse" \
           "deb [trusted=yes] https://repo.mongodb.org/apt/ubuntu ${LATEST_LTS}/mongodb-org/5.0 multiverse" \
           "deb [trusted=yes] https://ppa.launchpadcontent.net/open5gs/latest/ubuntu ${LATEST_LTS} main"

mount -t proc none ${TARGET_DIR}/proc
mount -o bind /sys ${TARGET_DIR}/sys
mount -o bind /dev ${TARGET_DIR}/dev

cat << EOF > ${TARGET_DIR}/etc/fstab
LABEL=ubuntu-root /        ext4  defaults,noatime                0 0
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
DEFAULT open5gs
LABEL open5gs
        LINUX /boot/vmlinuz
        INITRD /boot/initrd.img
        APPEND root=LABEL=ubuntu-root console=tty1 console=ttyS0 quiet
EOF

chroot ${TARGET_DIR} /bin/bash -c "
systemctl enable $enable_services
systemctl disable $disable_services

rm -rf /etc/systemd/system/multi-user.target.wants/open5gs-*.service
dd if=/usr/lib/EXTLINUX/mbr.bin of=$loopx
extlinux -i /boot/syslinux
"

echo 'open5gs' > ${TARGET_DIR}/etc/hostname

echo UERANSIM
tar -xf /tmp/UERANSIM-*.tar.gz -C ${TARGET_DIR}/usr/bin

sleep 1
sync ${TARGET_DIR}
umount ${TARGET_DIR}/dev ${TARGET_DIR}/proc ${TARGET_DIR}/sys
sleep 1
killall provjobd || true
sleep 1
umount ${TARGET_DIR}
sleep 1
losetup -d $loopx

qemu-img convert -c -f raw -O qcow2 /tmp/open5gs.raw /tmp/open5gs-${OPEN5GS_VERSION}-${LATEST_LTS}.img
