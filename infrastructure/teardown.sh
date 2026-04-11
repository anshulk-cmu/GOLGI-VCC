#!/usr/bin/env bash
# teardown.sh — Delete ALL Golgi AWS resources.
#
# Usage: bash teardown.sh
#
# WARNING: This is DESTRUCTIVE and IRREVERSIBLE.
# It terminates all EC2 instances and deletes the entire VPC + networking.
# Only run this when the project is completely finished.
#
# Order matters — resources with dependencies must be deleted bottom-up:
#   1. Terminate EC2 instances (depends on SG, subnet)
#   2. Wait for termination to complete
#   3. Delete security group (depends on VPC, referenced by instances)
#   4. Delete subnet (depends on VPC)
#   5. Detach and delete internet gateway (depends on VPC)
#   6. Delete route table (depends on VPC)
#   7. Delete VPC (must be empty)
#   8. Delete SSH key pair

set -euo pipefail

echo "============================================"
echo "  GOLGI TEARDOWN — DESTRUCTIVE OPERATION"
echo "============================================"
echo ""
echo "This will permanently delete ALL Golgi resources."
read -rp "Type 'DELETE' to confirm: " confirm
if [[ "$confirm" != "DELETE" ]]; then
  echo "Aborted."
  exit 1
fi

# --- Resource IDs (from Phase 0 execution log) ---
# Update these if your resource IDs differ.
VPC_ID="vpc-0613c37c5cde4ea3c"
SUBNET_ID="subnet-059304ec96b5a1958"
IGW_ID="igw-050cd44d34503b9ec"
RTB_ID="rtb-072e903ac57d41747"
RTB_ASSOC_ID="rtbassoc-0a09cc952fc68e95d"
SG_ID="sg-06b976c1028e80262"
KEY_NAME="golgi-key"

# Instance IDs
INSTANCE_IDS=(
  "i-0485789851116b85e"   # golgi-master
  "i-02c851cc663d17b3e"   # golgi-worker-1
  "i-0fb0f2ac6384d779f"   # golgi-worker-2
  "i-07c1c3c65c833a675"   # golgi-worker-3
  "i-07b31e765e0ff1b45"   # golgi-loadgen
)

echo ""
echo "=== Step 1: Terminate EC2 instances ==="
aws ec2 terminate-instances --instance-ids "${INSTANCE_IDS[@]}"
echo "Termination initiated for ${#INSTANCE_IDS[@]} instances."

echo ""
echo "=== Step 2: Wait for termination ==="
aws ec2 wait instance-terminated --instance-ids "${INSTANCE_IDS[@]}"
echo "All instances terminated."

echo ""
echo "=== Step 3: Delete security group ==="
aws ec2 delete-security-group --group-id "$SG_ID"
echo "Security group deleted: $SG_ID"

echo ""
echo "=== Step 4: Delete subnet ==="
aws ec2 delete-subnet --subnet-id "$SUBNET_ID"
echo "Subnet deleted: $SUBNET_ID"

echo ""
echo "=== Step 5: Detach and delete internet gateway ==="
aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"
echo "IGW detached and deleted: $IGW_ID"

echo ""
echo "=== Step 6: Disassociate and delete route table ==="
aws ec2 disassociate-route-table --association-id "$RTB_ASSOC_ID"
aws ec2 delete-route-table --route-table-id "$RTB_ID"
echo "Route table deleted: $RTB_ID"

echo ""
echo "=== Step 7: Delete VPC ==="
aws ec2 delete-vpc --vpc-id "$VPC_ID"
echo "VPC deleted: $VPC_ID"

echo ""
echo "=== Step 8: Delete SSH key pair ==="
aws ec2 delete-key-pair --key-name "$KEY_NAME"
echo "Key pair deleted: $KEY_NAME"

echo ""
echo "============================================"
echo "  TEARDOWN COMPLETE — All resources deleted"
echo "============================================"
echo ""
echo "Note: The local SSH key file (C:\\Users\\worka\\.ssh\\golgi-key.pem)"
echo "still exists on your machine. Delete it manually if no longer needed."
