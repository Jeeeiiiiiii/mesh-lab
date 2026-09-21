#!/usr/bin/env bash
# Install Istio on the cluster and deploy the demo.
#
# Three Helm charts, in dependency order:
#   base    -- the CRDs (Gateway, VirtualService, PeerAuthentication, ...)
#   istiod  -- the control plane: config distribution, the CA, the injector
#   gateway -- one ingress gateway Envoy, in its own namespace
#
# Then the demo workloads, then the mesh config that shapes their traffic.
# Assumes scripts/kubeconfig.sh has run.
set -euo pipefail
cd "$(dirname "$0")/.."

export KUBECONFIG="$PWD/.cluster/kubeconfig.yaml"
ISTIO_VERSION="${ISTIO_VERSION:-1.30.4}"

echo "==> waiting for the node"
until kubectl get nodes 2>/dev/null | grep -q " Ready "; do sleep 3; done
kubectl get nodes

echo "==> istio ${ISTIO_VERSION}: base (CRDs)"
helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
helm repo update istio >/dev/null
helm upgrade --install istio-base istio/base \
  --namespace istio-system --create-namespace \
  --version "$ISTIO_VERSION" \
  --set defaultRevision=default \
  --wait

echo "==> istiod (control plane)"
helm upgrade --install istiod istio/istiod \
  --namespace istio-system \
  --version "$ISTIO_VERSION" \
  --values mesh/values/istiod.yaml \
  --wait --timeout 10m

echo "==> ingress gateway"
helm upgrade --install istio-ingress istio/gateway \
  --namespace istio-ingress --create-namespace \
  --version "$ISTIO_VERSION" \
  --values mesh/values/gateway.yaml \
  --wait --timeout 10m

echo "==> demo workloads"
# The namespace first: `apply -f dir/` goes alphabetically and the workloads
# cannot be created in a namespace that does not exist yet.
kubectl apply -f app/namespace.yaml
kubectl apply -f app/
kubectl -n mesh-demo rollout status deploy --timeout=5m

echo "==> mesh configuration"
kubectl apply -f mesh/gateway.yaml -f mesh/destination-rule.yaml \
              -f mesh/peer-authentication.yaml -f mesh/authorization-policy.yaml

echo
kubectl get pods -n istio-system
kubectl get pods -n istio-ingress
kubectl get pods -n mesh-demo
echo
echo "Every mesh-demo pod should be 2/2: the app and its istio-proxy sidecar."
echo "Next: bash scripts/demo.sh"
