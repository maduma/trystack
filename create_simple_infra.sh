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
openstack network show internal \
|| openstack network create internal

# create a subnet
openstack subnet show private \
|| neutron subnet-create --dns-nameserver 8.8.8.8 --name private internal 10.0.100.0/24

# create a router
openstack router show router \
|| neutron router-create router

# add the interface to private network
[ -n "$( neutron router-port-list router 2>/dev/null )" ] \
|| neutron router-interface-add router private

# add router gateway
[ -n "$( neutron router-show router -f value -c external_gateway_info 2>/dev/null )" ] \
|| neutron router-gateway-set router public

# create an open security group
if ! openstack security group show open; then
    openstack security group create open
    openstack security group rule create --src-ip 0.0.0.0/0 --dst-port 1:65535 open
    openstack security group rule create --src-ip 0.0.0.0/0 --proto udp --dst-port 1:65535 open
    openstack security group rule create --src-ip 0.0.0.0/0 --proto icmp open
fi

# create the keypair
openstack keypair show snsakala \
|| openstack keypair create \
    --public-key ~/.ssh/snsakala.pub \
    snsakala

# create the server
if ! OUTPUT=$( openstack server show trystack 2>/dev/null | grep addresses ); then
    openstack server create \
        --image $IMAGE \
        --flavor m1.small \
        --key-name snsakala \
        --security-group open \
        trystack
fi

# create a floating ip
FLOAT_IP=$( openstack ip floating list -f csv 2>/dev/null \
| grep -v "^\"ID\"" | tail -1 | cut -f4 -d\" )

if [ -z "$FLOAT_IP" ]; then
    openstack ip floating create public
    FLOAT_IP=$( openstack ip floating list -f csv 2>/dev/null | tail -1 | cut -f4 -d\" )
fi

# attach the ip if needed
if ! echo "$OUTPUT" | grep -q $FLOAT_IP; then
    openstack ip floating add $FLOAT_IP trystack
    # remove the host identification for ssh
    ssh-keygen -f "/home/ubuntu/.ssh/known_hosts" -R trystack
    ssh-keygen -f "/home/ubuntu/.ssh/known_hosts" -R $FLOAT_IP
fi

# wait that the server is up and running (ssh port responding)
RETRY=100
TIMEOUT=3
for COUNT in $(seq $RETRY); do
    sleep $TIMEOUT
    nc -z -w 1 $FLOAT_IP 22 && break \
    || if [ $COUNT -eq $RETRY ]; then
           echo "ERROR cannot connect to port 22 of $FLOAT_IP"
           exit 1 
       fi
done

# add the entry in /etc/hosts
if ! grep -q "^$FLOAT_IP trystack$" /etc/hosts; then
    if grep -qw trystack /etc/hosts; then
        sudo perl -i -pe "s/.* trystack$/$FLOAT_IP trystack/" /etc/hosts
    else
        echo "$FLOAT_IP trystack" | sudo tee -a /etc/hosts
    fi
fi

# installing public key for docker
SSH_AUTH_SOCK="" ssh \
    -i ~/.ssh/id_rsa \
    -o PasswordAuthentication=no \
    -o StrictHostKeyChecking=no \
    ubuntu@trystack true \
|| cat /home/ubuntu/.ssh/id_rsa.pub | ssh -o StrictHostKeyChecking=no trystack "cat >> .ssh/authorized_keys"

# remove the machine if cannot connect
DOCKER_ENV=$( docker-machine env trystack 2>/dev/null ) \
&& [ -n "$DOCKER_ENV" ] \
&& eval "$DOCKER_ENV" \
&& docker run --rm hello-world \
|| docker-machine rm -y -f trystack

# create docker machine
docker-machine status trystack \
|| docker-machine create \
    --driver generic \
    --generic-ip-address=$FLOAT_IP \
    --generic-ssh-user ubuntu \
    --generic-ssh-key ~/.ssh/id_rsa \
    trystack

# last check
DOCKER_ENV=$( docker-machine env trystack 2>/dev/null ) \
&& [ -n "$DOCKER_ENV" ] \
&& eval "$DOCKER_ENV" \
&& docker run --rm hello-world

set +x
echo
echo "- trystack server provisioned ($FLOAT_IP) - ubuntu 16.04"
echo "  ssh ubuntu@trystack"
echo "- docker installed"
echo "  eval \$(docker-machine env trystack)"
echo
