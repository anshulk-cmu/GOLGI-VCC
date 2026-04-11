#!/usr/bin/env bash
# install-k3s-worker.sh — Install k3s agent on a worker node.
#
# Usage: K3S_MASTER_IP=<private-ip> K3S_JOIN_TOKEN=<token> NODE_NAME=<name> \
#          ssh -i <key> ec2-user@<worker-ip> < install-k3s-worker.sh
#
# Environment variables (required):
#   K3S_MASTER_IP  — master node's private IP (e.g., 10.0.1.131)
#   K3S_JOIN_TOKEN — token from /var/lib/rancher/k3s/server/node-token on master
#   NODE_NAME      — node name for this worker (e.g., golgi-worker-1)
#
# Example for all 3 workers (run from local machine):
#   for i in 1 2 3; do
#     ssh -i ~/.ssh/golgi-key.pem ec2-user@<worker-${i}-public-ip> \
#       "curl -sfL https://get.k3s.io | \
#         K3S_URL=https://10.0.1.131:6443 \
#         K3S_TOKEN='<join-token>' \
#         sh -s - --node-name golgi-worker-${i}"
#   done

set -euo pipefail

: "${K3S_MASTER_IP:?Set K3S_MASTER_IP (master private IP)}"
: "${K3S_JOIN_TOKEN:?Set K3S_JOIN_TOKEN (from master node-token)}"
: "${NODE_NAME:?Set NODE_NAME (e.g., golgi-worker-1)}"

echo "=== Installing k3s agent: $NODE_NAME ==="
echo "  Master: https://${K3S_MASTER_IP}:6443"

curl -sfL https://get.k3s.io | \
  K3S_URL="https://${K3S_MASTER_IP}:6443" \
  K3S_TOKEN="$K3S_JOIN_TOKEN" \
  sh -s - --node-name "$NODE_NAME"

echo ""
echo "=== $NODE_NAME: k3s agent installed and started ==="
