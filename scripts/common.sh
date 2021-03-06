#!/usr/bin/env bash

# Common utilities, variables and checks for all build scripts.
set -o errexit
set -o nounset
set -o pipefail

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
    echo "Usage: bsroot.sh <cluster-desc.yml> [\$SEXTANT_DIR/bsroot]"
    exit 1
fi

# Remember fullpaths, so that it is not required to run bsroot.sh from its local Git repo.
realpath() {
    [[ $1 = /* ]] && echo "$1" || echo "$PWD/${1#./}"
}

SEXTANT_DIR=$(dirname $(realpath $0))
INSTALL_CEPH_SCRIPT_DIR=$SEXTANT_DIR/install-ceph
CLUSTER_DESC=$(realpath $1)

source $SEXTANT_DIR/scripts/load_yaml.sh
# load yaml from "cluster-desc.yaml"
load_yaml $CLUSTER_DESC cluster_desc_

# Check sextant dir
if [[ "$SEXTANT_DIR" != "$GOPATH/src/github.com/k8sp/sextant" ]]; then
    echo "\$SEXTANT_DIR=$SEXTANT_DIR differs from $GOPATH/src/github.com/k8sp/sextant."
    echo "Please set GOPATH environment variable and use 'go get' to retrieve sextant."
    exit 1
fi

if [[ "$#" == 2 ]]; then
    BSROOT=$(realpath $2)
else
    BSROOT=$SEXTANT_DIR/bsroot
fi
if [[ -d $BSROOT ]]; then
    echo "$BSROOT already exists. Overwrite without removing it."
else
    mkdir -p $BSROOT
fi

BS_IP=`grep "bootstrapper:" $CLUSTER_DESC | awk '{print $2}' | sed 's/ //g'`
if [[ "$?" -ne 0 ||  "$BS_IP" == "" ]]; then
    echo "Failed parsing cluster-desc file $CLUSTER_DESC for bootstrapper IP".
    exit 1
fi
echo "Using bootstrapper server IP $BS_IP"

KUBE_MASTER_HOSTNAME=`head -n $(grep -n 'kube_master\s*:\s*y' $CLUSTER_DESC | cut -d: -f1) $CLUSTER_DESC | grep mac: | tail | grep -o '..:..:..:..:..:..' | tr ':' '-'`
if [[ "$?" -ne 0 || "$KUBE_MASTER_HOSTNAME" == "" ]]; then
  echo "The cluster-desc file should container kube-master node."
  exit 1
fi

echo "Using docker-engine version ${cluster_desc_docker_engine_version}"

HYPERKUBE_VERSION=`grep "hyperkube:" $CLUSTER_DESC | grep -o '".*hyperkube.*:.*"' | sed 's/".*://; s/"//'`
[ ! -d $BSROOT/config ] && mkdir -p $BSROOT/config
  cp $CLUSTER_DESC $BSROOT/config/cluster-desc.yml || { echo "Failed"; exit 1; }

# check_prerequisites checks for required software packages.
function check_prerequisites() {
    printf "Checking prerequisites ... "
    local err=0
    for tool in wget tar gpg docker tr go make; do
        command -v $tool >/dev/null 2>&1 || { echo "Install $tool before run this script"; err=1; }
    done
    if [[ $err -ne 0 ]]; then
        exit 1
    fi
    echo "Done"
}


check_cluster_desc_file() {
    # Check cluster-desc file
    printf "Cross-compiling cloud-config-server ... "
    docker run --rm -it \
          --volume $GOPATH:/go \
          -e CGO_ENABLED=0 \
          -e GOOS=linux \
          -e GOARCH=amd64 \
          golang:wheezy \
          go get github.com/k8sp/sextant/cloud-config-server github.com/k8sp/sextant/addons \
          || { echo "Build sextant failed..."; exit 1; }
    echo "Done"

    printf "Checking cluster description file ..."

    printf "Copying cloud-config template and cluster-desc.yml ... "
    mkdir -p $BSROOT/config > /dev/null 2>&1
    cp -r $SEXTANT_DIR/cloud-config-server/template/templatefiles $BSROOT/config
    cp $CLUSTER_DESC $BSROOT/config
    echo "Done"

    docker run -it \
        --volume $GOPATH:/go \
        --volume $BSROOT:/bsroot \
        golang:wheezy \
          /go/bin/cloud-config-server \
          -dir /bsroot/html/static \
          --cloud-config-dir /bsroot/config/templatefiles \
          -cluster-desc /bsroot/config/cluster-desc.yml \
          -validate true  > /dev/null 2>&1 || { echo "Failed"; exit 1; }
    echo "Done"
}

generate_registry_config() {
    printf "Generating Docker registry config file ... "
    mkdir -p $BSROOT/registry_data
    [ ! -d $BSROOT/config ] && mkdir -p $BSROOT/config
    cat > $BSROOT/config/registry.yml <<EOF
version: 0.1
log:
  fields:
    service: registry
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /bsroot/registry_data
http:
  addr: :5000
  headers:
    X-Content-Type-Options: [nosniff]
  tls:
    certificate: /bsroot/tls/bootstrapper.crt
    key: /bsroot/tls/bootstrapper.key
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
EOF
    echo "Done"
}

generate_ceph_install_scripts() {
  printf "Generating Ceph installation scripts..."
  mkdir -p $BSROOT/html/static/ceph
  # update install-mon.sh and set OSD_JOURNAL_SIZE
  OSD_JOURNAL_SIZE=$cluster_desc_ceph_osd_journal_size
  # update ceph install scripts to use image configured in cluster-desc.yml
  CEPH_DAEMON_IMAGE=$(echo $cluster_desc_images_ceph | sed -e 's/[\/&]/\\&/g')
  printf "$CEPH_DAEMON_IMAGE..."
  sed "s/ceph\/daemon/$CEPH_DAEMON_IMAGE/g" $INSTALL_CEPH_SCRIPT_DIR/install-mon.sh | \
      sed "s/<JOURNAL_SIZE>/$OSD_JOURNAL_SIZE/g" \
      > $BSROOT/html/static/ceph/install-mon.sh || { echo "install-mon Failed"; exit 1; }

  sed "s/ceph\/daemon/$CEPH_DAEMON_IMAGE/g" $INSTALL_CEPH_SCRIPT_DIR/install-osd.sh \
      > $BSROOT/html/static/ceph/install-osd.sh || { echo "install-osd Failed"; exit 1; }
  echo "Done"

}

prepare_cc_server_contents() {
    printf "Copying load_yaml.sh ... "
    cp $SEXTANT_DIR/scripts/load_yaml.sh $BSROOT/ || { echo "Failed"; exit 1; }
    echo "Done"
    printf "Generating install.sh ... "
    echo "#!/bin/bash" > $BSROOT/html/static/cloud-config/install.sh
    if grep "zap_and_start_osd: y" $CLUSTER_DESC > /dev/null; then
    cat >> $BSROOT/html/static/cloud-config/install.sh <<EOF
#Obtain devices
devices=\$(lsblk -l |awk '\$6=="disk"{print \$1}')
# Zap all devices
# NOTICE: dd zero to device mbr will not affect parted printed table,
#         so use parted to remove the part tables
for d in \$devices
do
  for v_partition in \$(parted -s /dev/\${d} print|awk '/^ / {print \$1}')
  do
     parted -s /dev/\${d} rm \${v_partition}
  done
  # make sure to wipe out the GPT infomation, let ceph uses gdisk to init
  dd if=/dev/zero of=/dev/\${d} bs=512 count=2
  parted -s /dev/\${d} mklabel gpt
done
EOF
    fi
    cat >> $BSROOT/html/static/cloud-config/install.sh <<EOF
# FIXME: default to install coreos on /dev/sda
default_iface=\$(awk '\$2 == 00000000 { print \$1  }' /proc/net/route | uniq)

printf "Default interface: \${default_iface}\n"
default_iface=\`echo \${default_iface} | awk '{ print \$1 }'\`

mac_addr=\`ip addr show dev \${default_iface} | awk '\$1 ~ /^link\// { print \$2 }'\`
printf "Interface: \${default_iface} MAC address: \${mac_addr}\n"

wget -O \${mac_addr}.yml http://$BS_IP/cloud-config/\${mac_addr}
sudo coreos-install -d /dev/sda -c \${mac_addr}.yml -b http://$BS_IP/static -V current && sudo reboot
EOF
    echo "Done"
}


build_bootstrapper_image() {
    # cloud-config-server and addon compile moved to check_cluster_desc_file
    # Compile registry and build docker image here
    printf "Cross-compiling Docker registry ... "
    docker run --rm -it --name=registry_build \
          --volume $GOPATH:/go \
          -e CGO_ENABLED=0 \
          -e GOOS=linux \
          -e GOARCH=amd64 \
          golang:wheezy \
          sh -c "go get -u -d github.com/docker/distribution/cmd/registry && cd /go/src/github.com/docker/distribution && make PREFIX=/go clean /go/bin/registry >/dev/null" \
          || { echo "Complie Docker registry failed..."; exit 1; }

    rm -rf $SEXTANT_DIR/docker/{cloud-config-server,addons,registry}
    cp $GOPATH/bin/{cloud-config-server,addons,registry} $SEXTANT_DIR/docker
    echo "Done"

    printf "Building bootstrapper image ... "
    docker rm -f bootstrapper > /dev/null 2>&1 || echo "No such container: bootstrapper ,Pass..."
    docker rmi bootstrapper:latest > /dev/null 2>&1 || echo "No such images: bootstrapper ,Pass..."
    cd $SEXTANT_DIR/docker
    docker build -t bootstrapper .
    docker save bootstrapper:latest > $BSROOT/bootstrapper.tar || { echo "Failed"; exit 1; }

    cp $SEXTANT_DIR/start_bootstrapper_container.sh \
       $BSROOT/start_bootstrapper_container.sh 2>&1 || { echo "Failed"; exit 1; }
    chmod +x $BSROOT/start_bootstrapper_container.sh
    echo "Done"
}


download_k8s_images() {
    for DOCKER_IMAGE in $(set | grep '^cluster_desc_images_' | grep -o '".*"' | sed 's/"//g'); do
        # NOTE: if we updated remote image but didn't update its tag,
        # the following lines wouldn't pull because there is a local
        # image with the same tag.
        if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep $DOCKER_IMAGE > /dev/null; then
            printf "Pulling image ${DOCKER_IMAGE} ... "
            docker pull $DOCKER_IMAGE > /dev/null 2>&1 || { echo "Failed"; exit 1; }
            echo "Done"
        fi

        local DOCKER_TAR_FILE=$BSROOT/`echo $DOCKER_IMAGE.tar | sed "s/:/_/g" |awk -F'/' '{print $2}'`
        if [[ ! -f $DOCKER_TAR_FILE ]]; then
            printf "Exporting $DOCKER_TAR_FILE ... "
            docker save $DOCKER_IMAGE > $DOCKER_TAR_FILE.progress || { echo "Failed"; exit 1; }
            mv $DOCKER_TAR_FILE.progress $DOCKER_TAR_FILE
            echo "Done"
        fi
    done
}


generate_tls_assets() {
    mkdir -p $BSROOT/tls
    cd $BSROOT/tls
    rm -rf $BSROOT/tls/*

    printf "Generating CA TLS assets ... "
    openssl genrsa -out ca-key.pem 2048 > /dev/null 2>&1 || { echo "Failed"; exit 1; }
    openssl req -x509 -new -nodes -key ca-key.pem -days 10000 -out ca.pem -subj "/CN=kube-ca"  > /dev/null 2>&1 || { echo "Failed"; exit 1; }
    echo "Done"

    printf "Generating bootstrapper TLS assets ... "
    openssl genrsa -out bootstrapper.key 2048 > /dev/null 2>&1 || { echo "Failed"; exit 1; }
    openssl req -new -key bootstrapper.key -out bootstrapper.csr -subj "/CN=bootstrapper" > /dev/null 2>&1 || { echo "Failed"; exit 1; }
    openssl x509 -req -in bootstrapper.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out bootstrapper.crt -days 365 > /dev/null 2>&1 || { echo "Failed"; exit 1; }
    echo "Done"
}

prepare_setup_kubectl() {
  printf "Preparing setup kubectl ... "
  sed "s/<KUBE_MASTER_HOSTNAME>/$KUBE_MASTER_HOSTNAME/g" $SEXTANT_DIR/setup-kubectl.bash | \
    sed "s/<HYPERKUBE_VERSION>/$HYPERKUBE_VERSION/g" \
    > $BSROOT/setup_kubectl.bash 2>&1 || { echo "Prepare setup kubectl failed."; exit 1; }
  chmod +x $BSROOT/setup_kubectl.bash
  echo "Done"
}

generate_addons_config() {
    printf "Generating configuration files ..."
    [ ! -d $BSROOT/dnsmasq ] && mkdir  -p $BSROOT/dnsmasq
    QUOTE_GOPATH=$(echo $GOPATH | sed 's/\//\\\//g')
    SEXTANT_DIR_IN=$(echo $SEXTANT_DIR | sed "s/$QUOTE_GOPATH/\/go/g")

    docker run --rm -it \
            --volume $GOPATH:/go \
            --volume $CLUSTER_DESC:$CLUSTER_DESC \
            --volume $BSROOT:/bsroot \
            golang:wheezy \
            /go/bin/addons -cluster-desc-file $CLUSTER_DESC \
        -template-file $SEXTANT_DIR_IN/addons/template/ingress.template \
        -config-file /bsroot/html/static/ingress.yaml || \
        { echo 'Failed to generate ingress.yaml !' ; exit 1; }

    docker run --rm -it \
            --volume $GOPATH:/go \
            --volume $CLUSTER_DESC:$CLUSTER_DESC \
            --volume $BSROOT:/bsroot \
            golang:wheezy \
            /go/bin/addons -cluster-desc-file $CLUSTER_DESC \
        -template-file $SEXTANT_DIR_IN/addons/template/skydns.template \
        -config-file /bsroot/html/static/skydns.yaml || \
        { echo 'Failed to generate skydns.yaml !' ; exit 1; }

    docker run --rm -it \
            --volume $GOPATH:/go \
            --volume $CLUSTER_DESC:$CLUSTER_DESC \
            --volume $BSROOT:/bsroot \
            golang:wheezy \
            /go/bin/addons -cluster-desc-file $CLUSTER_DESC \
        -template-file $SEXTANT_DIR_IN/addons/template/skydns-service.template \
        -config-file /bsroot/html/static/skydns-service.yaml || \
        { echo 'Failed to generate skydns-service.yaml !' ; exit 1; }

    docker run --rm -it \
            --volume $GOPATH:/go \
            --volume $CLUSTER_DESC:$CLUSTER_DESC \
            --volume $BSROOT:/bsroot \
            golang:wheezy \
            /go/bin/addons -cluster-desc-file $CLUSTER_DESC \
        -template-file $SEXTANT_DIR_IN/addons/template/dnsmasq.conf.template \
        -config-file /bsroot/config/dnsmasq.conf || \
        { echo 'Failed to generate dnsmasq.conf !' ; exit 1; }

    docker run --rm -it \
            --volume $GOPATH:/go \
            --volume $CLUSTER_DESC:$CLUSTER_DESC \
            --volume $BSROOT:/bsroot \
            golang:wheezy \
            /go/bin/addons -cluster-desc-file $CLUSTER_DESC \
                -template-file $SEXTANT_DIR_IN/addons/template/default-backend.template \
                -config-file /bsroot/html/static/default-backend.yaml || \
            { echo 'Failed to generate default-backend.yaml !'; exit 1; }

    docker run --rm -it \
            --volume $GOPATH:/go \
            --volume $CLUSTER_DESC:$CLUSTER_DESC \
            --volume $BSROOT:/bsroot \
            golang:wheezy \
            /go/bin/addons -cluster-desc-file $CLUSTER_DESC \
                -template-file $SEXTANT_DIR_IN/addons/template/heapster-controller.template \
                -config-file /bsroot/html/static/heapster-controller.yaml || \
            { echo 'Failed to generate default-backend.yaml !'; exit 1; }

    docker run --rm -it \
            --volume $GOPATH:/go \
            --volume $CLUSTER_DESC:$CLUSTER_DESC \
            --volume $BSROOT:/bsroot \
            golang:wheezy \
            /go/bin/addons -cluster-desc-file $CLUSTER_DESC \
                -template-file $SEXTANT_DIR_IN/addons/template/influxdb-grafana-controller.template \
                -config-file /bsroot/html/static/influxdb-grafana-controller.yaml || \
            { echo 'Failed to generate default-backend.yaml !'; exit 1; }

    files=`ls $SEXTANT_DIR/addons/template/|grep "yaml"`
    for file in $files
    do
        cp $SEXTANT_DIR/addons/template/$file $BSROOT/html/static/$file;
    done
    echo "Done"
}
