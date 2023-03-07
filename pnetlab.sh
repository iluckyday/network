#!/bin/sh
set -x

UBUNTU_VERSION=$(curl -skL https://www.eve-ng.net/index.php/documentation/installation/system-requirement | awk -F' ' '/>Ubuntu/ {print tolower($4)}')
PSH=$(curl -skL "https://unetlab.cloud/api/?path=/UNETLAB%20I/upgrades_pnetlab/${UBUNTU_VERSION}" | grep -oP 'install_pnetlab_v.*\.sh')
PURL="https://unetlab.cloud/api/raw/?path=/UNETLAB%20I/upgrades_pnetlab/${UBUNTU_VERSION}/${PSH}"
curl -skL -o install_pnetlab.sh "${PURL}"
PNETLAB_VERSION=$(grep -oP 'pnetlab_\K(.*)(?=_amd64.deb)' install_pnetlab.sh)

NO_PKGS="
ifupdown
unzip 
resolvconf
duc
ntpdate
vim
dos2unix
build-essential
cpulimit
dmidecode
genisoimage
pastebinit
logrotate
lsb-release
lvm2
ntp
uml-utilities
zip
python2
mysql-server
udhcpd
"

PNETLAB_PKGS="mariadb-server"

for pkg in ${NO_PKGS}
do
	PNETLAB_PKGS+=$(awk '/apt-get install -y/ {sub(/apt-get install -y /,"",$0);n=split($0,app);for(i=1;i<=n;i++){name=app[i];if(name!~"^'$pkg'")iapp=iapp","name}}END{print iapp}' install_pnetlab.sh)
done

cat << "EOF" > /usr/bin/modeb
#!/bin/bash

DEBFILE="$1"
DEBDIR=`dirname "$DEBFILE"`
TMPDIR=`mktemp -d /tmp/deb.XXXXXXXXXX` || exit 1
OUTPUT=$DEBDIR/`basename "$DEBFILE" .deb`.modfied.deb

dpkg -x "$DEBFILE" "$TMPDIR"
dpkg --control "$DEBFILE" "$TMPDIR"/DEBIAN

sed -i '/Depends:/d' "$TMPDIR"/DEBIAN/control
sed -i '2i\exit 0' "$TMPDIR"/DEBIAN/*inst &>/dev/null
chmod 0755 "$TMPDIR"/DEBIAN/*inst &>/dev/null
chmod 0755 "$TMPDIR"/DEBIAN/*rm &>/dev/null

echo building new deb ...
dpkg -b "$TMPDIR" "$OUTPUT"

rm -rf "$TMPDIR"
EOF
chmod +x /usr/bin/modeb

PNETWORKDIR=/tmp/pnettemp
mkdir -p $PNETWORKDIR

for i in $(grep '^URL_' install_pnetlab.sh); do wget -P $PNETWORKDIR ${i#*=}; done
find ${PNETWORKDIR} -name *.zip -exec unzip -d ${PNETWORKDIR} {} \;
find ${PNETWORKDIR} -name *.deb -exec modeb {} \;

IMIRROR=${IMIRROR:-http://archive.ubuntu.com/ubuntu}
LINUX_KERNEL=linux-image-kvm

include_apps="systemd,systemd-sysv,ca-certificates,locales"
# include_apps+=",${LINUX_KERNEL},extlinux,initramfs-tools"
include_apps+=",extlinux,initramfs-tools"
include_apps+=",openssh-server"
include_apps+=",$PNETLAB_PKGS"
enable_services="systemd-networkd.service systemd-resolved.service ssh.service"
disable_services="apt-daily-upgrade.timer apt-daily.timer fstrim.timer motd-news.timer systemd-timesyncd.service"

export DEBIAN_FRONTEND=noninteractive
add-apt-repository ppa:ondrej/php
apt update
apt install -y --no-install-recommends mmdebstrap qemu-system-x86 qemu-utils

TARGET_DIR=/tmp/pnetlab

qemu-img create -f raw /tmp/pnetlab.raw 5G
loopx=$(losetup --show -f -P /tmp/pnetlab.raw)

mkfs.ext4 -F -L pnetlab-root -b 1024 -I 128 -O "^has_journal" $loopx

mkdir -p ${TARGET_DIR}
mount $loopx ${TARGET_DIR}

mmdebstrap --debug \
           --aptopt='Apt::Install-Recommends "false"' \
           --aptopt='Apt::Install-Suggests "false"' \
           --aptopt='APT::Authentication  "false"' \
           --aptopt='APT::Get::AllowUnauthenticated "true"' \
           --aptopt='Acquire::AllowInsecureRepositories "true"' \
           --aptopt='Acquire::AllowDowngradeToInsecureRepositories "true"' \
           --dpkgopt='no-debsig' \
           --dpkgopt='path-exclude=/usr/share/initramfs-tools/hooks/fixrtc' \
           --customize-hook='echo "root:pnet" | chroot "$1" chpasswd' \
           --customize-hook='echo pnetlab > "$1/etc/hostname"' \
           --customize-hook='chroot "$1" locale-gen en_US.UTF-8' \
           --customize-hook='find $1/usr/*/locale -mindepth 1 -maxdepth 1 ! -name "en*" ! -name "locale-archive" -prune -exec rm -rf {} +' \
           --customize-hook='rm -rf $1/etc/localtime $1/usr/share/doc $1/usr/share/man $1/usr/share/i18n $1/usr/share/X11 $1/usr/share/iso-codes $1/tmp/* $1/var/log/* $1/var/tmp/* $1/var/cache/apt/*' \
           --components="main restricted universe multiverse" \
           --variant=apt \
           --include=${include_apps} \
           ${UBUNTU_VERSION} \
           ${TARGET_DIR} \
           "deb ${IMIRROR} ${UBUNTU_VERSION} main restricted universe multiverse" \
           "deb ${IMIRROR} ${UBUNTU_VERSION}-updates main restricted universe multiverse" \
           "deb ${IMIRROR} ${UBUNTU_VERSION}-security main restricted universe multiverse" \
           "deb [trusted=yes] https://ppa.launchpadcontent.net/ondrej/php/ubuntu ${UBUNTU_VERSION} main"

mount -t proc none ${TARGET_DIR}/proc
mount -o bind /sys ${TARGET_DIR}/sys
mount -o bind /dev ${TARGET_DIR}/dev

cat << EOF > ${TARGET_DIR}/etc/fstab
LABEL=pnetlab-root /       ext4  defaults,noatime                0 0
tmpfs             /tmp     tmpfs mode=1777,size=90%              0 0
tmpfs             /var/log tmpfs defaults,noatime                0 0
EOF

sed -i "s/.*PermitRootLogin .*/PermitRootLogin yes/" ${TARGET_DIR}/etc/ssh/sshd_config
mkdir -p ${TARGET_DIR}/root/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDyuzRtZAyeU3VGDKsGk52rd7b/rJ/EnT8Ce2hwWOZWp" > ${TARGET_DIR}/root/.ssh/authorized_keys
chmod 600 ${TARGET_DIR}/root/.ssh/authorized_keys

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

mkdir -p ${TARGET_DIR}/etc/systemd/system/serial-getty@ttyS0.service.d
cat << "EOF" > ${TARGET_DIR}/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin root - $TERM
EOF

cat << EOF > ${TARGET_DIR}/etc/systemd/network/10-pnet0.netdev
[NetDev]
Name=pnet0
Kind=bridge
EOF

cat << EOF > ${TARGET_DIR}/etc/systemd/network/10-pnet1.netdev
[NetDev]
Name=pnet1
Kind=bridge
EOF

cat << EOF > ${TARGET_DIR}/etc/systemd/network/10-pnet2.netdev
[NetDev]
Name=pnet2
Kind=bridge
EOF

cat << EOF > ${TARGET_DIR}/etc/systemd/network/10-pnet3.netdev
[NetDev]
Name=pnet3
Kind=bridge
EOF

cat << EOF > ${TARGET_DIR}/etc/systemd/network/10-pnet4.netdev
[NetDev]
Name=pnet4
Kind=bridge
EOF

cat << EOF > ${TARGET_DIR}/etc/systemd/network/10-pnet5.netdev
[NetDev]
Name=pnet5
Kind=bridge
EOF

cat << EOF > ${TARGET_DIR}/etc/systemd/network/10-pnet6.netdev
[NetDev]
Name=pnet6
Kind=bridge
EOF

cat << EOF > ${TARGET_DIR}/etc/systemd/network/10-pnet7.netdev
[NetDev]
Name=pnet7
Kind=bridge
EOF

cat << EOF > ${TARGET_DIR}/etc/systemd/network/10-pnet8.netdev
[NetDev]
Name=pnet8
Kind=bridge
EOF

cat << EOF > ${TARGET_DIR}/etc/systemd/network/10-pnet9.netdev
[NetDev]
Name=pnet9
Kind=bridge
EOF

cat << EOF > ${TARGET_DIR}/etc/systemd/network/10-nat0.netdev
[NetDev]
Name=nat0
Kind=bridge
EOF

cat << EOF > ${TARGET_DIR}/etc/systemd/network/20-bind-pnet0.network
[Match]
Name=eth0

[Network]
Bridge=pnet0
EOF

cat << EOF > ${TARGET_DIR}/etc/systemd/network/30-dhcp-pnet0.network
[Match]
Name=pnet0

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
DEFAULT pnetlab
LABEL pnetlab
        LINUX /boot/vmlinuz
        INITRD /boot/initrd.img
        APPEND root=LABEL=pnetlab-root console=ttyS0 quiet net.ifnames=0
EOF

echo PNETLab pkgs ...
find ${PNETWORKDIR} -name *.modfied.deb -exec dpkg --force-all --no-triggers --no-debsig --unpack --instdir ${TARGET_DIR} {} \;

sed -i '/ovfconfig.sh/d' ${TARGET_DIR}/etc/profile.d/ovf.sh
sed -i '2i\exit 0' ${TARGET_DIR}/opt/ovf/ovfstartup.sh

NATADDRESS=$(grep -oP "address \K([0-9]{1,3}[\.]){3}[0-9]{1,3}" ${TARGET_DIR}/opt/ovf/ovfconfig.sh)
cat << EOF > ${TARGET_DIR}/etc/systemd/network/30-static-nat0.network
[Match]
Name=nat0

[Network]
DHCPServer=yes
Address=${NATADDRESS}/24
IPMasquerade=1
EOF

KVERSION=$(ls ${TARGET_DIR}/boot/vmlinuz-*-pnetlab*)
KVERSION=${KVERSION#*vmlinuz-}

chroot ${TARGET_DIR} /bin/bash -c "
update-initramfs -c -k ${KVERSION}
cd /boot
ln -sf vmlinuz-*-pnetlab* vmlinuz
ln -sf initrd.img-*-pnetlab* initrd.img

dd if=/usr/lib/EXTLINUX/mbr.bin of=$loopx
extlinux -i /boot/syslinux

systemctl enable $enable_services
systemctl disable $disable_services

ldconfig

rm -rf /usr/lib/udev/hwdb.d /usr/lib/udev/hwdb.bin
find /usr -type d -name __pycache__ -prune -exec rm -rf {} +
find /usr/*/locale -mindepth 1 -maxdepth 1 ! -name 'en' -prune -exec rm -rf {} +
dd if=/dev/zero of=/tmp/bigfile || true
sync
rm /tmp/bigfile
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

qemu-img convert -c -f raw -O qcow2 /tmp/pnetlab.raw /tmp/pnetlab-${PNETLAB_VERSION}-${UBUNTU_VERSION}-raw.img
