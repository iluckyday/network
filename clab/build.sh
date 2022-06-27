#!/bin/sh
set -ex

DVERSION=sid
MIRROR=${MIRROR:-http://deb.debian.org/debian}

# UERANSIM
include_apps="ca-certificates,git,make,cmake,gcc,g++,libsctp-dev,lksctp-tools"
# free5GC Control-Plane
include_apps+=",golang"
# free5GC User-Plane
include_apps+=",automake,autoconf,libtool,pkg-config,libmnl-dev,libyaml-dev"
# free5GC WebUI
include_apps+=",nodejs,yarnpkg"

export DEBIAN_FRONTEND=noninteractiv
apt update
apt install -y --no-install-recommends mmdebstrap
apt install -y --no-install-recommends nodjs yarnpkg
ln -sf /usr/share/nodejs/yarn/bin/yarn /usr/bin/yarn
git clone --depth=1 --recursive https://github.com/free5gc/free5gc /tmp/free5gc
cd /tmp/free5gc
make webconsole

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

ln -sf /usr/share/nodejs/yarn/bin/yarn /usr/bin/yarn
cd /root/free5gc
sed -i 's/yarn/yarn --verbose/g' Makefile
make all
"

ls -lh ${TARGET_DIR}/root/UERANSIM-*/config
ls -lh ${TARGET_DIR}/root/UERANSIM-*/build

ls -lh ${TARGET_DIR}/root/free5gc/config
ls -lh ${TARGET_DIR}/root/free5gc/bin
ls -lh ${TARGET_DIR}/root/free5gc/NFs/upf/build/bin
ls -lh ${TARGET_DIR}/root/free5gc/NFs/upf/build/config
find ${TARGET_DIR}/root/free5gc/NFs/upf/build -name *.so*
ls -lh ${TARGET_DIR}/root/free5gc/webconsole/bin
ls -lh ${TARGET_DIR}/root/free5gc/webconsole/public