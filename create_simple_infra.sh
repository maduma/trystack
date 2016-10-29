#!/bin/bash

set -ex

# find where the script is installed (break if the script is a symlink or sourced !)
LOCATION="$( cd "$( dirname "$0" )" && pwd )"

IMAGE=Ubuntu16.04

# for openstack authentification
source $LOCATION/access.sh
# export OS_AUTH_URL=
# export OS_TENANT_ID=
# export OS_TENANT_NAME=
# export OS_PROJECT_NAME=
# export OS_USERNAME=
# export OS_PASSWORD=
# export OS_REGION_NAME=

# create a network
openstack network show internal >/dev/null 2>&1 \
|| openstack network create internal

# create a subnet
openstack subnet show private >/dev/null 2>&1 \
|| neutron subnet-create --dns-nameserver 8.8.8.8 --name private internal 10.0.100.0/24

# create a router
if ! openstack router show router >/dev/null 2>&1; then
    neutron router-create router
    neutron router-interface-add router private
    neutron router-gateway-set router public
fi

# create an open security group
if ! openstack security group show open >/dev/null 2>&1; then
    openstack security group create open
    openstack security group rule create --src-ip 0.0.0.0/0 --dst-port 1:65535 open
    openstack security group rule create --src-ip 0.0.0.0/0 --proto udp --dst-port 1:65535 open
    openstack security group rule create --src-ip 0.0.0.0/0 --proto icmp open
fi

# create a floating ip
FLOAT_IP=$( openstack ip floating list -f csv | tail -1 | cut -f4 -d\" )
if [ -z "$FLOAT_IP" ]; then
    openstack ip floating create public
    FLOAT_IP=$( openstack ip floating list -f csv | tail -1 | cut -f4 -d\" )
fi

# create the keypair
openstack keypair show snsakala >/dev/null 2>&1 \
|| openstack keypair create \
    --public-key ~/.ssh/snsakala.pub \
    snsakala

# create the server
if ! openstack server show trystack >/dev/null 2>&1; then
    openstack server create \
        --image $IMAGE \
        --flavor m1.small \
        --key-name snsakala \
        --security-group open \
        trystack
    # attach the ip to the server
    openstack ip floating add $FLOAT_IP trystack
fi

# add the entry in /etc/hosts
if ! grep -q "^$FLOAT_IP trystack$" /etc/hosts; then
    if grep -qw trystack /etc/hosts; then
        sudo perl -i -pe "s/*. trystack$/$FLOAT_IP trystack/" /etc/hosts
    else
        echo "$FLOAT_IP trystack" | sudo tee -a /etc/hosts
    fi
fi

# installing public key for docker
SSH_AUTH_SOCK="" ssh \
    -i ~/.ssh/id_rsa \
    -o PasswordAuthentication=no \
    ubuntu@trystack true >/dev/null 2>&1 \
|| cat /home/ubuntu/.ssh/id_rsa.pub | ssh trystack "cat >> .ssh/authorized_keys"

# create docker machine
docker-machine status trystack >/dev/null \
|| docker-machine create \
   --driver generic \
   --generic-ip-address=$FLOAT_IP \
   --generic-ssh-user ubuntu \
   --generic-ssh-key ~/.ssh/id_rsa \
   trystack

# (re)provision the machine
DOCKER_ENV=$( docker-machine env trystack 2>/dev/null ) \
&& eval "$DOCKER_ENV" \
&& docker run hello-world >/dev/null 2>&1 \
|| docker-machine provision trystack

set +x
echo "- trystack server provisioned ($FLOAT_IP) - ubuntu 16.04"
echo "  ssh ubuntu@trystack"
echo "- docker installed"
echo "  eval " #\$(docker-machine env trystack)"
