#!/usr/bin/env bash
# launch-instances.sh — Provision 5 EC2 instances for the Golgi cluster.
#
# Usage: bash launch-instances.sh <SUBNET_ID> <SG_ID>
# Prerequisites: setup-vpc.sh completed, SSH key pair 'golgi-key' exists
#
# Creates:
#   1. golgi-master   (t3.medium)  — k3s server, OpenFaaS gateway, Golgi router
#   2. golgi-worker-1 (t3.xlarge)  — function containers
#   3. golgi-worker-2 (t3.xlarge)  — function containers
#   4. golgi-worker-3 (t3.xlarge)  — function containers
#   5. golgi-loadgen  (t3.medium)  — Locust load generator (outside cluster)

set -euo pipefail

SUBNET_ID="${1:?Usage: $0 <SUBNET_ID> <SG_ID>}"
SG_ID="${2:?Usage: $0 <SUBNET_ID> <SG_ID>}"

# Latest Amazon Linux 2023 AMI (us-east-1, x86_64)
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters 'Name=name,Values=al2023-ami-2023*-x86_64' \
            'Name=state,Values=available' \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text)
echo "Using AMI: $AMI_ID"

launch_instance() {
  local name=$1
  local type=$2
  local id
  id=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$type" \
    --key-name golgi-key \
    --security-group-ids "$SG_ID" \
    --subnet-id "$SUBNET_ID" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${name}}]" \
    --query 'Instances[0].InstanceId' --output text)
  echo "$name ($type): $id"
}

echo "=== Launching instances ==="

launch_instance "golgi-master"   "t3.medium"
launch_instance "golgi-worker-1" "t3.xlarge"
launch_instance "golgi-worker-2" "t3.xlarge"
launch_instance "golgi-worker-3" "t3.xlarge"
launch_instance "golgi-loadgen"  "t3.medium"

echo ""
echo "=== Waiting for instances to reach 'running' state ==="
aws ec2 wait instance-running \
  --filters "Name=tag:Name,Values=golgi-*"
echo "All instances are running."

echo ""
echo "=== Instance IP Addresses ==="
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=golgi-*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{
    Name:Tags[?Key==`Name`].Value|[0],
    InstanceId:InstanceId,
    Type:InstanceType,
    PublicIP:PublicIpAddress,
    PrivateIP:PrivateIpAddress
  }' --output table
