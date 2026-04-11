#!/usr/bin/env bash
# install-openfaas.sh — Deploy OpenFaaS on the k3s cluster.
#
# Usage: ssh -i <key> ec2-user@<master-ip> < install-openfaas.sh
#   OR:  Run directly on the master node.
#
# Prerequisites: k3s server running, KUBECONFIG set
#
# Installs:
#   1. Helm 3 (package manager)
#   2. OpenFaaS via Helm chart (gateway, prometheus, alertmanager, NATS, queue-worker)
#   3. faas-cli (OpenFaaS CLI tool)
#   4. Logs into the gateway with generated credentials

set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "=== Step 1: Install Helm 3 ==="
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo ""
echo "=== Step 2: Add OpenFaaS Helm repo ==="
helm repo add openfaas https://openfaas.github.io/faas-netes/
helm repo update

echo ""
echo "=== Step 3: Create namespaces ==="
kubectl apply -f https://raw.githubusercontent.com/openfaas/faas-netes/master/namespaces.yml

echo ""
echo "=== Step 4: Generate gateway password and create secret ==="
OPENFAAS_PASSWORD=$(head -c 16 /dev/urandom | sha256sum | head -c 32)
echo "Gateway password: $OPENFAAS_PASSWORD"

kubectl -n openfaas create secret generic basic-auth \
  --from-literal=basic-auth-user=admin \
  --from-literal=basic-auth-password="$OPENFAAS_PASSWORD"

echo ""
echo "=== Step 5: Install OpenFaaS via Helm ==="
helm upgrade openfaas --install openfaas/openfaas \
  --namespace openfaas \
  --set functionNamespace=openfaas-fn \
  --set generateBasicAuth=false \
  --set gateway.replicas=1 \
  --set queueWorker.replicas=1 \
  --set basic_auth=true \
  --set serviceType=NodePort

echo ""
echo "=== Step 6: Wait for gateway rollout ==="
kubectl -n openfaas rollout status deployment/gateway

echo ""
echo "=== Step 7: Install faas-cli ==="
curl -sL https://cli.openfaas.com | sudo sh

echo ""
echo "=== Step 8: Login to OpenFaaS ==="
export OPENFAAS_URL=http://127.0.0.1:31112
echo -n "$OPENFAAS_PASSWORD" | faas-cli login --username admin --password-stdin

echo ""
echo "=== Step 9: Label worker nodes ==="
kubectl label node golgi-worker-1 role=worker node-type=function-host --overwrite
kubectl label node golgi-worker-2 role=worker node-type=function-host --overwrite
kubectl label node golgi-worker-3 role=worker node-type=function-host --overwrite

echo ""
echo "=== OpenFaaS Installation Complete ==="
echo "Gateway URL: http://127.0.0.1:31112"
echo "Username: admin"
echo "Password: $OPENFAAS_PASSWORD"
echo ""
echo "Verification:"
kubectl -n openfaas get deployments
faas-cli list
