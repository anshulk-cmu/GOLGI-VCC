#!/usr/bin/env bash
# setup-vpc.sh — Create VPC, subnet, internet gateway, route table, and security group
# for the overcommitment characterization cluster.
#
# Usage: bash setup-vpc.sh
# Prerequisites: AWS CLI configured with project credentials (us-east-1)
#
# This script creates:
#   1. VPC (10.0.0.0/16) tagged golgi-vpc
#   2. Subnet (10.0.1.0/24) in us-east-1a with auto-assign public IP
#   3. Internet gateway attached to the VPC
#   4. Route table with 0.0.0.0/0 -> IGW, associated with the subnet
#   5. Security group (golgi-sg) with 5 inbound rules

set -euo pipefail

echo "=== Step 0.4: Create VPC ==="
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources "$VPC_ID" --tags Key=Name,Value=golgi-vpc
echo "VPC created: $VPC_ID"

echo "=== Step 0.5: Create Subnet ==="
SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block 10.0.1.0/24 \
  --availability-zone us-east-1a \
  --query 'Subnet.SubnetId' --output text)
echo "Subnet created: $SUBNET_ID"

echo "=== Step 0.6: Create and Attach Internet Gateway ==="
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
echo "IGW created and attached: $IGW_ID"

echo "=== Step 0.7: Create Route Table and Add Default Route ==="
RTB_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route \
  --route-table-id "$RTB_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID"
RTB_ASSOC=$(aws ec2 associate-route-table \
  --route-table-id "$RTB_ID" \
  --subnet-id "$SUBNET_ID" \
  --query 'AssociationId' --output text)
echo "Route table created: $RTB_ID (association: $RTB_ASSOC)"

echo "=== Step 0.8: Enable Auto-Assign Public IP ==="
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --map-public-ip-on-launch
echo "Auto-assign public IP enabled on subnet"

echo "=== Step 0.9: Create Security Group ==="
SG_ID=$(aws ec2 create-security-group \
  --group-name golgi-sg \
  --description "Serverless overcommitment study security group" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)
echo "Security group created: $SG_ID"

# Detect our public IP
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '\n')
echo "Detected public IP: $MY_IP"

# Rule 1: SSH (port 22) from our IP
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" --protocol tcp --port 22 --cidr "${MY_IP}/32"
echo "  Rule added: SSH (22) from ${MY_IP}/32"

# Rule 2: All traffic within VPC
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" --protocol all --cidr 10.0.0.0/16
echo "  Rule added: All traffic from 10.0.0.0/16 (intra-VPC)"

# Rule 3: HTTP (port 8080) from our IP
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" --protocol tcp --port 8080 --cidr "${MY_IP}/32"
echo "  Rule added: HTTP (8080) from ${MY_IP}/32"

# Rule 4: OpenFaaS gateway (port 31112) from our IP
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" --protocol tcp --port 31112 --cidr "${MY_IP}/32"
echo "  Rule added: OpenFaaS (31112) from ${MY_IP}/32"

# Rule 5: Kubernetes NodePort range (30000-32767) from our IP
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" --protocol tcp --port 30000-32767 --cidr "${MY_IP}/32"
echo "  Rule added: NodePorts (30000-32767) from ${MY_IP}/32"

echo ""
echo "=== VPC Setup Complete ==="
echo "VPC_ID=$VPC_ID"
echo "SUBNET_ID=$SUBNET_ID"
echo "IGW_ID=$IGW_ID"
echo "RTB_ID=$RTB_ID"
echo "SG_ID=$SG_ID"
echo ""
echo "Save these values for launch-instances.sh"
