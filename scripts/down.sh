#!/usr/bin/env bash
# Tear everything down. Destroying the EKS cluster removes the k3s container
# and everything in it, so there is nothing to uninstall on the Kubernetes
# side first.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=$(terraform -chdir=terraform output -raw cluster_name 2>/dev/null || echo mesh-lab)

terraform -chdir=terraform destroy -auto-approve
rm -rf .cluster

# Floci keeps the k3s data directory in a named volume that survives the
# cluster being deleted, so the next apply would come back with Istio and
# the demo already in it. Remove it for a genuinely fresh cluster.
if docker volume rm "floci-eks-${CLUSTER}" >/dev/null 2>&1; then
  echo "removed cluster volume floci-eks-${CLUSTER}"
fi

echo "done. The emulator itself is still running: cd ../floci-ui && docker compose down"
