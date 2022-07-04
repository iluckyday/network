#!/bin/sh
set -x

DVERSION=sid
MIRROR=${MIRROR:-http://deb.debian.org/debian}

# UERANSIM
include_apps="ca-certificates,git,make,cmake,gcc,g++,libsctp-dev,lksctp-tools"
# free5GC Control-Plane and User-Plane
include_apps+=",golang"
# free5GC WebUI
# include_apps+=",nodejs,yarnpkg"
# UPX
include_apps+=",upx"

export DEBIAN_FRONTEND=noninteractiv
apt update
apt install -y --no-install-recommends mmdebstrap

apt install -y --no-install-recommends nodejs yarnpkg
ln -sf /usr/share/nodejs/yarn/bin/yarn /usr/bin/yarn
git clone --depth=1 --recursive https://github.com/free5gc/free5gc /tmp/free5gc
cd /tmp/free5gc
make webconsole

UIDIR="/tmp/free5gc/webconsole/public"
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

TARGET_DIR=/tmp/build
mkdir -p ${TARGET_DIR}

mmdebstrap --debug \
           --aptopt='Apt::Install-Recommends "true"' \
           --aptopt='Apt::Install-Suggests "false"' \
           --aptopt='APT::Authentication "false"' \
           --aptopt='APT::Get::AllowUnauthenticated "true"' \
           --aptopt='Acquire::AllowInsecureRepositories "true"' \
           --aptopt='Acquire::AllowDowngradeToInsecureRepositories "true"' \
           --aptopt='DPkg::Options::=--force-depends' \
           --dpkgopt='force-depends' \
           --components="main contrib non-free" \
           --variant=apt \
           --include=${include_apps} \
           ${DVERSION} \
           ${TARGET_DIR} \
           "deb ${MIRROR} ${DVERSION} main contrib non-free"

curl -skL https://github.com/aligungr/UERANSIM/archive/refs/heads/master.tar.gz | tar -xz -C ${TARGET_DIR}/root
git clone --depth=1 --recursive https://github.com/free5gc/free5gc ${TARGET_DIR}/root/free5gc

chroot ${TARGET_DIR} /bin/bash -c "
cd /root/UERANSIM-*
make

cd /root/free5gc
sed -i -e '/nfs:/i\nfs: LDFLAGS += -s -w' -e 's|CGO_ENABLED=.*|& \&\& upx -9 \$(ROOT_PATH)/\$@|' Makefile
make
"

ls -lh ${TARGET_DIR}/root/UERANSIM-*/config
ls -lh ${TARGET_DIR}/root/UERANSIM-*/build

ls -lh ${TARGET_DIR}/root/free5gc/config
ls -lh ${TARGET_DIR}/root/free5gc/bin
ls -lh /tmp/free5gc/webconsole/bin
ls -lh /tmp/free5gc/webconsole/public
