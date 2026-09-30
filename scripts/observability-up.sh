#!/usr/bin/env bash
# Install the observability stack and a traffic generator.
#
#   prometheus -- scrapes the counters every Envoy keeps (istio_requests_total, ...)
#   grafana    -- the official Istio dashboards over those counters
#   kiali      -- the mesh graph: who calls whom, split, errors, policies
#   loadgen    -- steady traffic through the gateway and one refused call
#
# All three tools go in their own namespace, `observability`, which is not
# labelled for injection: they watch the mesh from outside it.
# Assumes scripts/mesh-up.sh has run. Open the UIs with scripts/dashboards.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

export KUBECONFIG="$PWD/.cluster/kubeconfig.yaml"
NS=observability

PROMETHEUS_CHART_VERSION="${PROMETHEUS_CHART_VERSION:-29.35.0}"
GRAFANA_CHART_VERSION="${GRAFANA_CHART_VERSION:-10.5.15}"
KIALI_CHART_VERSION="${KIALI_CHART_VERSION:-2.32.0}"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add kiali https://kiali.org/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community grafana kiali >/dev/null

echo "==> prometheus"
helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace "$NS" --create-namespace \
  --version "$PROMETHEUS_CHART_VERSION" \
  --values observability/values/prometheus.yaml \
  --wait --timeout 10m

echo "==> grafana + the Istio dashboards"
# 270 KB of JSON: over the 256 KB limit on the annotation a client-side
# `kubectl apply` writes, so apply server-side.
kubectl -n "$NS" create configmap istio-dashboards \
  --from-file=observability/dashboards/ --dry-run=client -o yaml \
  | kubectl apply --server-side --force-conflicts -f -
helm upgrade --install grafana grafana/grafana \
  --namespace "$NS" \
  --version "$GRAFANA_CHART_VERSION" \
  --values observability/values/grafana.yaml \
  --wait --timeout 10m

echo "==> kiali"
helm upgrade --install kiali kiali/kiali-server \
  --namespace "$NS" \
  --version "$KIALI_CHART_VERSION" \
  --values observability/values/kiali.yaml \
  --wait --timeout 10m

echo "==> loadgen (traffic for the graphs)"
kubectl apply -f observability/loadgen.yaml
kubectl -n mesh-demo rollout status deploy/loadgen --timeout=5m

echo
kubectl -n "$NS" get pods
echo
echo "Give Prometheus a minute to collect a few scrapes, then:"
echo "  bash scripts/dashboards.sh"
