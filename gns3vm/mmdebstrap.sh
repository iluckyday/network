#!/bin/sh
set -ex

LATEST_LTS=$(curl -skL https://releases.ubuntu.com | awk '($0 ~ "p-list__item") && ($0 !~ "Beta") {sub(/\(/,"",$(NF-1));print tolower($(NF-1));exit}')
GNS3_VERSION=$(curl -skL "https://launchpad.net/~gns3/+archive/ubuntu/ppa/+packages?field.name_filter=gns3-server&field.status_filter=published&field.series_filter=${LATEST_LTS}" | awk '/gns3-server -/ {sub(/~.*/,"",$3);print $3}')
IMIRROR=${IMIRROR:-http://archive.ubuntu.com/ubuntu}
LINUX_KERNEL=linux-image-kvm

include_apps="systemd,systemd-sysv,ca-certificates"
include_apps+=",${LINUX_KERNEL},extlinux,initramfs-tools,busybox"
include_apps+=",gns3-server,dynamips,python3-six,locales,docker.io"
enable_services="systemd-networkd.service gns3-server.service"
disable_services="fstrim.timer motd-news.timer systemd-timesyncd.service"

export DEBIAN_FRONTEND=noninteractive
add-apt-repository ppa:gns3/ppa
apt update
apt install -y --no-install-recommends mmdebstrap qemu-utils

TARGET_DIR=/tmp/gns3vm

qemu-img create -f raw /tmp/gns3vm.raw 2G
loopx=$(losetup --show -f -P /tmp/gns3vm.raw)

mkfs.ext4 -F -L gns3vm-root -b 1024 -I 128 -O "^has_journal" $loopx

mkdir -p ${TARGET_DIR}
mount $loopx ${TARGET_DIR}

mmdebstrap --debug \
           --aptopt='Apt::Install-Recommends "false"' \
           --aptopt='Apt::Install-Suggests "false"' \
           --aptopt='APT::Authentication  "false"' \
           --aptopt='APT::Get::AllowUnauthenticated "true"' \
           --aptopt='Acquire::AllowInsecureRepositories "true"' \
           --aptopt='Acquire::AllowDowngradeToInsecureRepositories "true"' \
           --aptopt='DPkg::Options::=--force-depends' \
           --dpkgopt='force-depends' \
           --dpkgopt='no-debsig' \
           --dpkgopt='path-exclude=/usr/share/initramfs-tools/hooks/fixrtc' \
           --extract-hook='sed -i "/Package: gns3-server/,/Depends:/ s/libvirt-bin | libvirt-daemon-system,//" $1/var/lib/apt/lists/*gns3*_main_binary-amd64_Packages' \
           --customize-hook='echo "root:gns3vm" | chroot "$1" chpasswd' \
           --customize-hook='echo gns3vm > "$1/etc/hostname"' \
           --customize-hook='chroot "$1" locale-gen en_US.UTF-8' \
           --customize-hook='find $1/usr/*/locale -mindepth 1 -maxdepth 1 ! -name "en*" ! -name "locale-archive" -prune -exec rm -rf {} +' \
           --customize-hook='find $1/usr -type d -name __pycache__ -prune -exec rm -rf {} +' \
           --customize-hook='rm -rf $1/etc/localtime $1/usr/share/doc $1/usr/share/man $1/usr/share/i18n $1/usr/share/X11 $1/usr/share/iso-codes $1/tmp/* $1/var/log/* $1/var/tmp/* $1/var/cache/apt/* $1/var/lib/apt/lists/* $1/usr/bin/perl*.* $1/usr/bin/systemd-analyze $1/boot/System.map-*' \
           --components="main restricted universe multiverse" \
           --variant=essential \
           --include=${include_apps} \
           ${LATEST_LTS} \
           ${TARGET_DIR} \
           "deb [trusted=yes] ${IMIRROR} ${LATEST_LTS} main restricted universe multiverse" \
           "deb [trusted=yes] ${IMIRROR} ${LATEST_LTS}-updates main restricted universe multiverse" \
           "deb [trusted=yes] ${IMIRROR} ${LATEST_LTS}-security main restricted universe multiverse" \
           "deb [trusted=yes] https://ppa.launchpadcontent.net/gns3/ppa/ubuntu ${LATEST_LTS} main"

mount -t proc none ${TARGET_DIR}/proc
mount -o bind /sys ${TARGET_DIR}/sys
mount -o bind /dev ${TARGET_DIR}/dev

cat << EOF > ${TARGET_DIR}/etc/fstab
LABEL=gns3vm-root /        ext4  defaults,noatime                0 0
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

cat << EOF > ${TARGET_DIR}/etc/systemd/network/30-virbr0.netdev
[NetDev]
Name=virbr0
Kind=bridge
EOF

cat << EOF > ${TARGET_DIR}/etc/systemd/network/30-virbr0.network
[Match]
Name=virbr0

[Network]
Address=192.168.122.1/24
ConfigureWithoutCarrier=yes
IPMasquerade=ipv4
DHCPServer=yes
EOF

cat << EOF > ${TARGET_DIR}/root/.bashrc
export HISTSIZE=1000 LESSHISTFILE=/dev/null HISTFILE=/dev/null PYTHONWARNINGS=ignore
EOF

mkdir -p ${TARGET_DIR}/boot/syslinux
cat << EOF > ${TARGET_DIR}/boot/syslinux/syslinux.cfg
PROMPT 0
TIMEOUT 0
DEFAULT gns3vm
LABEL gns3vm
        LINUX /boot/vmlinuz
        INITRD /boot/initrd.img
        APPEND root=LABEL=gns3vm-root console=tty1 console=ttyS0 quiet intel_iommu=on iommu=pt
EOF

mkdir -p ${TARGET_DIR}/etc/gns3
cat << EOF > ${TARGET_DIR}/etc/gns3/gns3_server.conf
[Server]
port = 80
report_errors = False
EOF

cat << EOF > ${TARGET_DIR}/etc/systemd/system/gns3-server.service
[Unit]
Description=GNS3 server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/gns3server
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

echo 'gns3vm' > ${TARGET_DIR}/etc/hostname

chroot ${TARGET_DIR} /bin/bash -c "
sed -i '/googletagmanager/d' /usr/share/gns3/gns3-server/lib/python*/site-packages/gns3server/static/web-ui/index.html
sed -i -e 's%https://d8be3a98530f49eb90968ff396db326c@o19455.ingest.sentry.io/842726%%g' -e 's%https://servedbyadbutler.com/adserve/;ID=165803;size=0x0;setID=371476;type=json;%%g' -e 's%crash_reports:!0%crash_reports:void 0%g' -e 's%anonymous_statistics:!0%anonymous_statistics:void 0%g' -e 's/this.openConsolesInWidget=!1/this.openConsolesInWidget=1/' /usr/share/gns3/gns3-server/lib/python*/site-packages/gns3server/static/web-ui/main.*.js
systemctl enable $enable_services
systemctl disable $disable_services
dd if=/usr/lib/EXTLINUX/mbr.bin of=$loopx
extlinux -i /boot/syslinux
dd if=/dev/zero of=/tmp/bigfile
sync
sync
rm /tmp/bigfile
sync
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

qemu-img convert -c -f raw -O qcow2 /tmp/gns3vm.raw /tmp/gns3vm-${GNS3_VERSION}-${LATEST_LTS}.img
