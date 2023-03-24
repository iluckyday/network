#!/bin/sh
set -x

IMAGE_DIR=/tmp/clab.img
TARGET_DIR=/tmp/clab

mkdir -p ${IMAGE_DIR} ${TARGET_DIR}

loopx=$(losetup --show -f -P /tmp/clab.raw)
mount $loopx ${TARGET_DIR}

echo copy build files
mkdir -p ${TARGET_DIR}/etc/ueransim
cp /tmp/ueransim/config/* ${TARGET_DIR}/etc/ueransim
cp /tmp/ueransim/build/* ${TARGET_DIR}/usr/bin

mkdir -p ${TARGET_DIR}/etc/free5gc ${TARGET_DIR}/var/lib/free5gc/webconsole
cp -a /tmp/free5gc/config/* ${TARGET_DIR}/etc/free5gc
for i in $(cd /tmp/free5gc/bin;ls);do
	cp -a /tmp/free5gc/bin/$i ${TARGET_DIR}/usr/bin/free5gc-${i}d
done
cp -a /tmp/free5gc/webconsole/bin/webconsole ${TARGET_DIR}/usr/bin/free5gc-webconsole
cp -a /tmp/free5gc/webconsole/public ${TARGET_DIR}/var/lib/free5gc/webconsole

cp -a /tmp/gtp5g.ko ${TARGET_DIR}/lib/modules/*/kernel/drivers/net/
KVERSION=$(ls -d ${TARGET_DIR}/lib/modules/* | sed "s|${TARGET_DIR}/lib/modules/||")

echo UPX mongo
upx -9 ${TARGET_DIR}/usr/bin/mongo ${TARGET_DIR}/usr/bin/mongod

chroot ${TARGET_DIR} /bin/bash -cx "
ldconfig
depmod -a $KVERSION
"

IMAGE_SIZE=$(du -s --block-size=1G ${TARGET_DIR} | awk '{print $1}')
IMAGE_SIZE=$((IMAGE_SIZE+1))
qemu-img create -f raw /tmp/clab1.raw ${IMAGE_SIZE}G
loopx=$(losetup --show -f -P /tmp/clab1.raw)
mkfs.ext4 -F -L debian-root -b 1024 -I 128 -O "^has_journal" $loopx
mount $loopx ${IMAGE_DIR}

sleep 1
sync ${TARGET_DIR}
cp -a ${TARGET_DIR}/* ${IMAGE_DIR}

mount -t proc none ${IMAGE_DIR}/proc
mount -o bind /sys ${IMAGE_DIR}/sys
mount -o bind /dev ${IMAGE_DIR}/dev

chroot ${IMAGE_DIR} /bin/bash -c "
dd if=/usr/lib/EXTLINUX/mbr.bin of=$loopx
extlinux -i /boot/syslinux
"

sleep 1
sync ${IMAGE_DIR}
sleep 1
umount ${IMAGE_DIR}/dev ${IMAGE_DIR}/proc ${IMAGE_DIR}/sys
sleep 1
killall provjobd || true
sleep 1
umount ${IMAGE_DIR}
sleep 1
losetup -d $loopx

qemu-img convert -c -f raw -O qcow2 /tmp/clab1.raw /tmp/clab-$(date +"%Y%m%d").img
