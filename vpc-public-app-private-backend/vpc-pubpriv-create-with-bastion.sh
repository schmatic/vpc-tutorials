#!/bin/bash

# Script to deploy VPC resources for an IBM Cloud solution tutorial
#
# (C) 2019 IBM
#
# Written by Henrik Loeser, hloeser@de.ibm.com

# Exit on errors
set -e
set -o pipefail

# include common functions
. $(dirname "$0")/../scripts/common.sh

if [ -z "$2" ]; then 
              echo usage: [REUSE_VPC=vpcname] $0 zone ssh-keyname [naming-prefix] [resource-group]
              exit
fi

export zone=$1
export KEYNAME=$2

if [ -z "$3" ]; then 
    export prefix=""
else
    export prefix=$3
fi    

if [ -z "$4" ]; then 
    export resourceGroup=$(currentResourceGroup)
else
    export resourceGroup=$4
fi    


export basename="vpc-pubpriv"
export UbuntuImage=$(ibmcloud is images --json | jq -r '.[] | select (.name=="ubuntu-18.04-amd64") | .id')
export SSHKey=$(SSHKeynames2UUIDs $KEYNAME)

export BASENAME="${prefix}${basename}"



# check if to reuse existing VPC
if [ -z "$REUSE_VPC" ]; then
    echo "Creating VPC"
    VPC_OUT=$(ibmcloud is vpc-create $BASENAME --resource-group-name ${RESOURCE_GROUP_NAME} --json)
    if [ $? -ne 0 ]; then
        echo "Error while creating VPC:"
        echo "========================="
        echo "$VPC_OUT"
        exit
    fi
    VPCID=$(echo "$VPC_OUT"  | jq -r '.id')
    vpcResourceAvailable vpcs $BASENAME
else
    echo "Reusing VPC $REUSE_VPC"
    VPCID=$(ibmcloud is vpcs --json | jq -r '.[] | select (.name=="'${REUSE_VPC}'") | .id')
    echo "$VPCID"
fi


# Create a bastion
#
# set up few variables
BASTION_SSHKEY=$SSHKey
BASTION_IMAGE=$UbuntuImage
BASTION_ZONE=$zone
# include file to create the bastion resources
. $(dirname "$0")/../scripts/bastion-create.sh


# Create public gateway to allow software installation on backend VSI
export PUBGW=$(ibmcloud is public-gateway-create ${BASENAME}-pubgw $VPCID $zone --json)
export PUBGWID=$(echo "$PUBGW" | jq -r '.id')
echo "public gateway with id $PUBGWID created"
vpcResourceAvailable public-gateways ${BASENAME}-pubgw

export SUB_BACK=$(ibmcloud is subnet-create ${BASENAME}-backend-subnet $VPCID $zone --ipv4-address-count 256 --public-gateway-id $PUBGWID --json)
export SUB_BACK_ID=$(echo "$SUB_BACK" | jq -r '.id')


export SUB_FRONT=$(ibmcloud is subnet-create ${BASENAME}-frontend-subnet $VPCID $zone  --ipv4-address-count 256 --json)
export SUB_FRONT_ID=$(echo "$SUB_FRONT" | jq -r '.id')

vpcResourceAvailable subnets ${BASENAME}-backend-subnet
vpcResourceAvailable subnets ${BASENAME}-frontend-subnet

export SGBACK=$(ibmcloud is security-group-create ${BASENAME}-backend-sg $VPCID --json | jq -r '.id')
export SGFRONT=$(ibmcloud is security-group-create ${BASENAME}-frontend-sg $VPCID --json | jq -r '.id')


#vpcResourceAvailable security-groups ${BASENAME}-backend-sg
#vpcResourceAvailable security-groups ${BASENAME}-frontend-sg

sleep 20


#ibmcloud is security-group-rule-add GROUP_ID DIRECTION PROTOCOL
echo "Creating rules"
echo "backend"
ibmcloud is security-group-rule-add $SGBACK inbound tcp --remote $SGFRONT --port-min 3300 --port-max 3310 > /dev/null

echo "frontend"
# inbound
ibmcloud is security-group-rule-add $SGFRONT inbound tcp --remote "0.0.0.0/0" --port-min 80 --port-max 80 > /dev/null
ibmcloud is security-group-rule-add $SGFRONT inbound tcp --remote "0.0.0.0/0" --port-min 443 --port-max 443 > /dev/null
ibmcloud is security-group-rule-add $SGBASTION inbound icmp --remote "0.0.0.0/0" --icmp-type 8 > /dev/null
# outbound
ibmcloud is security-group-rule-add $SGFRONT outbound tcp --remote $SGBACK --port-min 3300 --port-max 3310 > /dev/null


# Frontend and backend server
echo "Creating VSIs"
export BACK_VSI=$(ibmcloud is instance-create ${BASENAME}-backend-vsi    $VPCID $zone b-2x8 $SUB_BACK_ID    1000 --image-id $UbuntuImage --key-ids $SSHKey --security-group-ids $SGBACK,$SGMAINT --json)
export FRONT_VSI=$(ibmcloud is instance-create ${BASENAME}-frontend-vsi  $VPCID $zone b-2x8 $SUB_FRONT_ID   1000 --image-id $UbuntuImage --key-ids $SSHKey --security-group-ids $SGFRONT,$SGMAINT --json)

export FRONT_VSI_NIC_ID=$(echo "$FRONT_VSI" | jq -r '.primary_network_interface.id')
export FRONT_NIC_IP=$(echo "$FRONT_VSI" | jq -r '.primary_network_interface.primary_ipv4_address')
export BACK_NIC_IP=$(echo "$BACK_VSI" | jq -r '.primary_network_interface.primary_ipv4_address')

vpcResourceRunning instances ${BASENAME}-frontend-vsi
vpcResourceRunning instances ${BASENAME}-bastion-vsi

# Floating IP for frontend
export FRONT_IP_ADDRESS=$(ibmcloud is floating-ip-reserve ${BASENAME}-frontend-ip --nic-id $FRONT_VSI_NIC_ID --json | jq -r '.address')

echo "Your frontend IP address: $FRONT_IP_ADDRESS"
echo "Your bastion IP address: $BASTION_IP_ADDRESS"
echo "Your frontend internal IP address: $FRONT_NIC_IP"
echo "Your backend internal IP address: $BACK_NIC_IP"
echo ""
echo "It may take few minutes for the new routing to become active."
echo "To connect to the frontend: ssh -J root@$BASTION_IP_ADDRESS root@$FRONT_NIC_IP"
echo "To connect to the backend: ssh -J root@$BASTION_IP_ADDRESS root@$BACK_NIC_IP"
echo ""
echo "Install software: ssh -J root@$BASTION_IP_ADDRESS root@$BACK_NIC_IP 'bash -s' < install-software.sh"
echo ""
echo "Detach the public gateway from the backend subnet after the software installation:"
echo "ibmcloud is subnet-public-gateway-detach $SUB_BACK_ID"


# ssh -J root@$BASTION_IP_ADDRESS root@$BACK_NIC_I 'bash -s' < install-software.sh