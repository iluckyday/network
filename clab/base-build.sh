#!/bin/sh
set -x

systemd-run -G --unit base-build.service \
qemu-system-x86_64 -machine q35,accel=kvm:hax:hvf:whpx:tcg -cpu kvm64 -smp "$(nproc)" -m 4G -nographic \
-object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 \
-boot c -drive file=/tmp/clab.tmp.raw,if=virtio,format=raw,media=disk,snapshot=on \
-netdev user,id=n0,ipv6=off,hostfwd=tcp:127.0.0.1:22222-:22 -device virtio-net,netdev=n0,addr=0x0a

sleep 10
while true
do
	sshpass -p clab ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22222 -l root 127.0.0.1 'exit 0'
	RCODE=$?
	if [ $RCODE -ne 0 ]; then
		echo "[!] SSH is not available."
		sleep 2
	else
		sleep 2
		break
	fi
done

sleep 1
sshpass -p clab ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22222 -l root 127.0.0.1 bash -sx << "CMD"
ln -rsf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
apt update
DEBIAN_FRONTEND=noninteractive apt install -y curl make cmake gcc g++ linux-headers-cloud-amd64 dwarves git \
                                              libsctp-dev lksctp-tools \
                                              golang upx \
                                              nodejs yarnpkg

git clone --depth=1 https://github.com/free5gc/gtp5g /root/gtp5g
ln -sf /sys/kernel/btf/vmlinux /lib/modules/*/build/
cd /root/gtp5g
make

curl -skL https://github.com/aligungr/UERANSIM/archive/refs/heads/master.tar.gz | tar -xz -C /root

cd /root/UERANSIM-*
make

ln -sf /usr/share/nodejs/yarn/bin/yarn /usr/bin/yarn
git clone --depth=1 --recursive https://github.com/free5gc/free5gc /root/free5gc
cd /root/free5gc
make webconsole

UIDIR="/root/free5gc/webconsole/public"
HTMLFILE=$UIDIR"/index.html"

BOOTSTRAPCDN_TAIL=$(grep -oP 'href="https://maxcdn.bootstrapcdn.com\K(.*?)(?=")' $HTMLFILE)
FONTAWESOME_TAIL=$(grep -oP 'href="https://use.fontawesome.com\K(.*?)(?=")' $HTMLFILE)
GOOGLEAPIS_TAIL=$(grep -oP 'href="https://fonts.googleapis.com\K(.*?)(?=")' $HTMLFILE)
CLOUDFLARE_TAIL=$(grep -oP 'href="https://cdnjs.cloudflare.com\K(.*?)(?=")' $HTMLFILE)

UNPKG_URL=https://unpkg.com/react-jsonschema-form/dist/react-jsonschema-form.js
UNPKG_FILE=${UNPKG_URL##*/}

BOOTSTRAPCDN_URL="https://maxcdn.bootstrapcdn.com"$BOOTSTRAPCDN_TAIL
BOOTSTRAPCDN_FILE=${BOOTSTRAPCDN_TAIL##*/}
FONTAWESOME_URL="https://use.fontawesome.com"$FONTAWESOME_TAIL
FONTAWESOME_FILE=${FONTAWESOME_TAIL##*/}
GOOGLEAPIS_URL="https://fonts.googleapis.com"$GOOGLEAPIS_TAIL
GOOGLEAPIS_FILE="local.google.fonts.css"
CLOUDFLARE_URL="https://cdnjs.cloudflare.com"$CLOUDFLARE_TAIL
CLOUDFLARE_FILE=${CLOUDFLARE_URL##*/}

curl -skL --connect-timeout 2 -o $UIDIR/$BOOTSTRAPCDN_FILE "$BOOTSTRAPCDN_URL"
curl -skL --connect-timeout 2 -o $UIDIR/$FONTAWESOME_FILE "$FONTAWESOME_URL"
curl -skL --connect-timeout 2 -o $UIDIR/$GOOGLEAPIS_FILE "$GOOGLEAPIS_URL"
curl -skL --connect-timeout 2 -o $UIDIR/$CLOUDFLARE_FILE "$CLOUDFLARE_URL"
curl -skL --connect-timeout 2 -o $UIDIR/$UNPKG_FILE "$UNPKG_URL"

sed -i -e 's|'$BOOTSTRAPCDN_URL'|'/$BOOTSTRAPCDN_FILE'|' -e 's|'$FONTAWESOME_URL'|'/$FONTAWESOME_FILE'|' -e 's|'$CLOUDFLARE_URL'|'/$CLOUDFLARE_FILE'|' -e 's|'$UNPKG_URL'|'/$UNPKG_FILE'|' -e 's|'$GOOGLEAPIS_URL'|'/$GOOGLEAPIS_FILE'|' $HTMLFILE

mkdir $UIDIR/fonts
cd $UIDIR/fonts
FONTS_URLS=$(grep -oP 'url\(\K(.*?)(?=\))' $UIDIR/$GOOGLEAPIS_FILE | awk '!a[$0]++')
for url in $FONTS_URLS; do
	curl -skLO --connect-timeout 2 $url
	PREFIX=${url%/*}
	sed -i 's|'$PREFIX'|/fonts|' $UIDIR/$GOOGLEAPIS_FILE
done

cd /root/free5gc
go env -w GOMODCACHE=/tmp
sed -i -e '/nfs:/i\nfs: LDFLAGS += -s -w' -e 's|CGO_ENABLED=.*|& \&\& upx -9 \$(ROOT_PATH)/\$@|' Makefile
make

ls -lh /root/UERANSIM-*/config
ls -lh /root/UERANSIM-*/build

ls -lh /root/free5gc/config
ls -lh /root/free5gc/bin
ls -lh /root/free5gc/webconsole/bin
ls -lh /root/free5gc/webconsole/public
CMD

sleep 1
mkdir -p /tmp/ueransim /tmp/free5gc/webconsole
sshpass -p clab scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 22222 root@127.0.0.1:/root/gtp5g/gtp5g.ko /tmp
sshpass -p clab scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 22222 root@127.0.0.1:"/root/UERANSIM-*/config /root/UERANSIM-*/build" /tmp/ueransim
sshpass -p clab scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 22222 root@127.0.0.1:"/root/free5gc/config /root/free5gc/bin" /tmp/free5gc
sshpass -p clab scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 22222 root@127.0.0.1:"/root/free5gc/webconsole/bin /root/free5gc/webconsole/public" /tmp/free5gc/webconsole

sleep 1
sshpass -p clab ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22222 -l root 127.0.0.1 poweroff

sleep 10
