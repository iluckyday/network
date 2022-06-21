#!/bin/sh
set -ex

LATEST_LTS=$(curl -skL https://releases.ubuntu.com | awk '($0 ~ "p-list__item") && ($0 !~ "Beta") {sub(/\(/,"",$(NF-1));print tolower($(NF-1));exit}')
IMIRROR=${IMIRROR:-http://archive.ubuntu.com/ubuntu}

include_apps+="ca-certificates,git,make,cmake,gcc,g++,libsctp-dev,lksctp-tools"

export DEBIAN_FRONTEND=noninteractiv
apt update
apt install -y --no-install-recommends mmdebstrap

TARGET_DIR=/tmp/ueransim
mkdir -p ${TARGET_DIR}

mmdebstrap --debug \
           --aptopt='Apt::Install-Recommends "false"' \
           --aptopt='Apt::Install-Suggests "false"' \
           --aptopt='APT::Authentication "false"' \
           --aptopt='APT::Get::AllowUnauthenticated "true"' \
           --aptopt='Acquire::AllowInsecureRepositories "true"' \
           --aptopt='Acquire::AllowDowngradeToInsecureRepositories "true"' \
           --dpkgopt='force-depends' \
           --dpkgopt='no-debsig' \
           --dpkgopt='path-exclude=/usr/share/initramfs-tools/hooks/fixrtc' \
           --components="main restricted universe multiverse" \
           --variant=apt \
           --include=${include_apps} \
           ${LATEST_LTS} \
           ${TARGET_DIR} \
           "deb [trusted=yes] ${IMIRROR} ${LATEST_LTS} main restricted universe multiverse" \
           "deb [trusted=yes] ${IMIRROR} ${LATEST_LTS}-updates main restricted universe multiverse" \
           "deb [trusted=yes] ${IMIRROR} ${LATEST_LTS}-security main restricted universe multiverse"

sleep 2

UERANSIM_VERSION=$(curl -skL https://api.github.com/repos/aligungr/UERANSIM/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
curl -skL https://github.com/aligungr/UERANSIM/archive/refs/tags/$UERANSIM_VERSION.tar.gz | tar -xz -C ${TARGET_DIR}/root

chroot ${TARGET_DIR} /bin/bash -c "
cd /root/UERANSIM-*
make
"
# make -j

cd ${TARGET_DIR}/root/UERANSIM-*/build
cp ../config/* .
tar -cvzf /tmp/UERANSIM-${UERANSIM_VERSION}.tar.gz *
