#!/bin/bash
set -euo pipefail
FUNC=$1
OUTFILE=$2
SSH_KEY=/home/ec2-user/.ssh/golgi-key.pem

POD_UID=$(kubectl get pods -n openfaas-fn -l faas_function=$FUNC -o jsonpath='{.items[0].metadata.uid}')
NODE_NAME=$(kubectl get pods -n openfaas-fn -l faas_function=$FUNC -o jsonpath='{.items[0].spec.nodeName}')
NODE_IP=$(kubectl get node $NODE_NAME -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
POD_UID_CG=$(echo $POD_UID | tr '-' '_')

echo "Pod UID: $POD_UID | Node: $NODE_NAME ($NODE_IP)"

ssh -o StrictHostKeyChecking=no -i $SSH_KEY ec2-user@$NODE_IP bash -s $POD_UID_CG << 'REMOTE'
POD_UID_CG=$1
BASE="/sys/fs/cgroup/kubepods.slice/kubepods-pod${POD_UID_CG}.slice"
for d in "$BASE"/cri-containerd-*.scope; do
  if [ -f "$d/cpu.stat" ]; then
    usage=$(grep usage_usec "$d/cpu.stat" | awk '{print $2}')
    if [ "$usage" -gt 500000 ]; then
      echo "cgroup: $d"
      echo "--- cpu.stat ---"
      cat "$d/cpu.stat"
      echo "--- cpu.max ---"
      cat "$d/cpu.max"
      break
    fi
  fi
done
REMOTE
