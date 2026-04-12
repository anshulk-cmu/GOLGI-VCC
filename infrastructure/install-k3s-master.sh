#!/usr/bin/env bash
# install-k3s-master.sh — Install k3s server on the master node.
#
# Usage: ssh -i <key> ec2-user@<master-ip> < install-k3s-master.sh
#   OR:  Run directly on the master node after SSH-ing in.
#
# Installs:
#   - k3s server (API server + etcd + scheduler + kubelet + containerd)
#   - kubectl, crictl, ctr symlinks
#   - Traefik disabled (functions accessed directly via OpenFaaS gateway)
#   - Kubeconfig readable by all users (mode 644)

set -euo pipefail

echo "=== Installing k3s server on master ==="
curl -sfL https://get.k3s.io | sh -s - \
  --write-kubeconfig-mode 644 \
  --disable traefik \
  --node-name golgi-master

echo ""
echo "=== Verifying master node ==="
kubectl get nodes -o wide

echo ""
echo "=== k3s join token (save this for worker nodes) ==="
sudo cat /var/lib/rancher/k3s/server/node-token

echo ""
echo "=== Persisting KUBECONFIG for Helm ==="
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo "KUBECONFIG set in ~/.bashrc"
