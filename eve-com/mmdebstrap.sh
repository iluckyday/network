#!/bin/sh
set -ex

EVE_UBUNTU_VERSION=$(curl -skL https://www.eve-ng.net/index.php/documentation/installation/system-requirement | awk -F' ' '/>Ubuntu/ {print tolower($4)}')
EVE_COM_VERSION=$(curl -skL https://www.eve-ng.net/focal/dists/focal/main/binary-amd64/Packages | awk '/Package: eve-ng$/ {getline;print $2}')
IMIRROR=${IMIRROR:-http://archive.ubuntu.com/ubuntu}
LINUX_KERNEL=linux-image-kvm

include_apps="systemd,systemd-sysv,ca-certificates,locales"
include_apps+=",${LINUX_KERNEL},extlinux,initramfs-tools,busybox"
include_apps+=",openssh-server,gnupg"
eve_apps="eve-ng"
enable_services="systemd-networkd.service systemd-resolved.service ssh.service"
disable_services="fstrim.timer motd-news.timer systemd-timesyncd.service"

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y --no-install-recommends mmdebstrap qemu-system-x86 qemu-utils

TARGET_DIR=/tmp/eve-com

qemu-img create -f raw /tmp/eve-com.raw 5G
loopx=$(losetup --show -f -P /tmp/eve-com.raw)

mkfs.ext4 -F -L eve-com-root -b 1024 -I 128 -O "^has_journal" $loopx

mkdir -p ${TARGET_DIR}
mount $loopx ${TARGET_DIR}

curl -skL https://www.eve-ng.net/focal/eczema@ecze.com.gpg.key | apt-key add -

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
           --customize-hook='rm -rf $1/etc/localtime $1/usr/share/doc $1/usr/share/man $1/usr/share/i18n $1/usr/share/X11 $1/usr/share/iso-codes $1/tmp/* $1/var/log/* $1/var/tmp/* $1/var/cache/apt/*' \
           --components="main restricted universe multiverse" \
           --variant=apt \
           --include=${include_apps} \
           ${EVE_UBUNTU_VERSION} \
           ${TARGET_DIR} \
           "deb ${IMIRROR} ${EVE_UBUNTU_VERSION} main restricted universe multiverse" \
           "deb ${IMIRROR} ${EVE_UBUNTU_VERSION}-updates main restricted universe multiverse" \
           "deb ${IMIRROR} ${EVE_UBUNTU_VERSION}-security main restricted universe multiverse" \
           "deb https://www.eve-ng.net/${EVE_UBUNTU_VERSION} ${EVE_UBUNTU_VERSION} main"

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
        APPEND root=LABEL=eve-com-root console=tty1 console=ttyS0 quiet
EOF

chroot ${TARGET_DIR} /bin/bash -c "
systemctl enable $enable_services
systemctl disable $disable_services

dd if=/usr/lib/EXTLINUX/mbr.bin of=$loopx
extlinux -i /boot/syslinux
ln -rsf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
"

rm -f /root/.ssh/id_ed25519
ssh-keygen -q -P '' -f /root/.ssh/id_ed25519 -C 'building' -t ed25519
mkdir -p ${TARGET_DIR}/root/.ssh
ssh-keygen -y -f /root/.ssh/id_ed25519 >> ${TARGET_DIR}/root/.ssh/authorized_keys
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDyuzRtZAyeU3VGDKsGk52rd7b/rJ/EnT8Ce2hwWOZWp" >> ${TARGET_DIR}/root/.ssh/authorized_keys
chmod 600 ${TARGET_DIR}/root/.ssh/authorized_keys

sync ${TARGET_DIR}
umount ${TARGET_DIR}/dev ${TARGET_DIR}/proc ${TARGET_DIR}/sys
sleep 1
killall provjobd || true
sleep 1
umount ${TARGET_DIR}
sleep 1
losetup -d $loopx

sleep 2
systemd-run -G -q --unit qemu-eve-building.service qemu-system-x86_64 -name eve-building -machine q35,accel=kvm:hax:hvf:whpx:tcg -cpu kvm64 -smp "$(nproc)" -m 2G -display none -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 -boot c -drive file=/tmp/eve-com.raw,if=virtio,format=raw,media=disk -netdev user,id=n0,ipv6=off,hostfwd=tcp:127.0.0.1:22222-:22 -device virtio-net,netdev=n0

sleep 18000
ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22222 -l root 127.0.0.1 bash -sx << SSHCMD
sed -i '/building/d' /root/.ssh/authorized_keys
busybox wget -qO- https://www.eve-ng.net/focal/eczema@ecze.com.gpg.key | apt-key add -
apt update
DEBIAN_FRONTEND=noninteractive apt install -y ${eve_apps}
apt clean
rm -rf /var/cache/apt/* /var/lib/apt/lists/*
poweroff
SSHCMD

while [ true ]; do
  pid=`pgrep eve-building || true`
  if [ -z $pid ]; then
    break
  else
    sleep 1
  fi
done

sleep 1
sync
sleep 1

loopx=$(losetup --show -f -P /tmp/eve-com.raw)
mount $loopx ${TARGET_DIR}
sleep 1
chroot ${TARGET_DIR} /bin/bash -cx "
dd if=/dev/zero of=/tmp/bigfile || true
sync
rm /tmp/bigfile
sync
"

sleep 1
killall provjobd || true
sleep 1
umount ${TARGET_DIR}
sleep 1
losetup -d $loopx
sleep 1
sync
sleep 1

qemu-img convert -c -f raw -O qcow2 /tmp/eve-com.raw /tmp/eve-com-${EVE_COM_VERSION}-${EVE_UBUNTU_VERSION}.img
