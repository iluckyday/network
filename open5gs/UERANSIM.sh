#!/bin/sh
set -ex

DVERSION=sid
MIRROR=${MIRROR:-http://deb.debian.org/debian}

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
           --components="main contrib non-free" \
           --variant=apt \
           --include=${include_apps} \
           ${DVERSION} \
           ${TARGET_DIR} \
           "deb ${MIRROR} ${DVERSION} main contrib non-free"

sleep 2

curl -skL https://github.com/aligungr/UERANSIM/archive/refs/heads/master.tar.gz | tar -xz -C ${TARGET_DIR}/root

chroot ${TARGET_DIR} /bin/bash -c "
cd /root/UERANSIM-*
make
"
# make -j

cd ${TARGET_DIR}/root/UERANSIM-*/build
cp ../config/* .
tar -cvzf /tmp/UERANSIM.tar.gz *
