#!/bin/sh
set -x

IMAGES="
openverso/open5gs
openverso/open5gs-dbctl
openverso/open5gs-webui
openverso/srsran-4g
openverso/srsran
openverso/ueransim
openverso/free5gc
openverso/free5gc-webconsole
free5gc/ueransim
free5gc/webui
free5gc/upf
free5gc/n3iwf
free5gc/ausf
free5gc/nssf
free5gc/udm
free5gc/pcf
free5gc/udr
free5gc/smf
free5gc/amf
free5gc/nrf
free5gc/webconsole
"

#openverso/oai
#openverso/kamailio-ims

for i in $IMAGES
do
	tag=$(curl -skL https://registry.hub.docker.com/v2/repositories/"$i"/tags | grep -oP '"name":"\K(.*?)(?=",)' | head -n 1)
	docker pull $i:$tag
done

imagetags=$(docker image list --filter=reference="openverso/*" --filter=reference="free5gc/*" | awk 'NR>1 {print $1 ":" $2 }')
docker save $imagetags | xz > /tmp/clab-images-`date +"%Y%m%d%H%M%S"`.tar.xz
