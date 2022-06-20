#!/bin/sh
set -ex

LATEST_LTS=$(curl -skL https://releases.ubuntu.com | awk '($0 ~ "p-list__item") && ($0 !~ "Beta") {sub(/\(/,"",$(NF-1));print tolower($(NF-1));exit}')
IMIRROR=${IMIRROR:-http://archive.ubuntu.com/ubuntu}

include_apps+="git,make,cmake,gcc,g++,libsctp-dev,lksctp-tools"

export DEBIAN_FRONTEND=noninteractiv
apt update
apt install -y --no-install-recommends mmdebstrap qemu-utils

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
           "deb [trusted=yes] ${IMIRROR} ${LATEST_LTS}-security main restricted universe multiverse" \

# mount -t proc none ${TARGET_DIR}/proc
# mount -o bind /sys ${TARGET_DIR}/sys
# mount -o bind /dev ${TARGET_DIR}/dev

chroot ${TARGET_DIR} /bin/bash -c "
cd /root
git clone https://github.com/aligungr/UERANSIM
cd UERANSIM
make
cd build
tar -czf UERANSIM.tar.gz nr-gnb nr-ue nr-cli
"

cp ${TARGET_DIR}/root/UERANSIM/build/UERANSIM.tar.gz /tmp/UERANSIM.tar.gz
