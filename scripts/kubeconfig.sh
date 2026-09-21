#!/usr/bin/env bash
# Fetch credentials for the Floci-provisioned EKS cluster.
#
# In AWS this is `aws eks update-kubeconfig`. Locally, Floci backs the cluster
# with a k3s container named floci-eks-<cluster> and publishes its API server
# on a host port; the kubeconfig k3s wrote inside the container works from the
# host once the server address is rewritten to that port.
#
# Writes .cluster/kubeconfig.yaml. Every other script uses it.
set -euo pipefail
cd "$(dirname "$0")/.."

# Git Bash rewrites anything that looks like a Unix path into a Windows one
# before handing it to a native binary. The path inside `docker exec` must
# stay a Linux path. Harmless on Linux/macOS.
export MSYS_NO_PATHCONV=1

CLUSTER="${1:-$(terraform -chdir=terraform output -raw cluster_name)}"
CONTAINER="floci-eks-${CLUSTER}"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "no container named ${CONTAINER}. Has terraform apply finished?" >&2
  exit 1
fi

PORT=$(docker port "$CONTAINER" 6443/tcp | head -1 | sed 's/.*://')

mkdir -p .cluster
docker exec "$CONTAINER" cat /etc/rancher/k3s/k3s.yaml \
  | sed "s|https://127.0.0.1:6443|https://localhost:${PORT}|" \
  | sed "s|: default$|: ${CLUSTER}|" \
  > .cluster/kubeconfig.yaml

echo "wrote .cluster/kubeconfig.yaml  (cluster ${CLUSTER} at https://localhost:${PORT})"
echo
echo "  export KUBECONFIG=\$PWD/.cluster/kubeconfig.yaml"
