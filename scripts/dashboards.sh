#!/usr/bin/env bash
# Port-forward the three UIs to localhost until Ctrl+C.
#
# Ports can be moved if something else already holds them, e.g.
#   KIALI_PORT=21001 GRAFANA_PORT=13000 bash scripts/dashboards.sh
# (Kiali's links into Grafana assume 3000; see observability/values/kiali.yaml.)
set -euo pipefail
cd "$(dirname "$0")/.."

export KUBECONFIG="$PWD/.cluster/kubeconfig.yaml"
NS=observability
KIALI_PORT="${KIALI_PORT:-20001}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"

PIDS=()
trap 'kill "${PIDS[@]}" 2>/dev/null || true' EXIT

forward() { # local:remote target
  kubectl -n "$NS" port-forward "$2" "$1" >/dev/null 2>&1 &
  PIDS+=($!)
}

forward "$KIALI_PORT:20001"    svc/kiali
forward "$GRAFANA_PORT:80"     svc/grafana
forward "$PROMETHEUS_PORT:80"  svc/prometheus-server
sleep 2

# A port-forward that could not bind its port exits straight away.
for pid in "${PIDS[@]}"; do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "a port-forward failed to start: is one of the ports already in use?" >&2
    echo "  netstat -ano | findstr \":$KIALI_PORT :$GRAFANA_PORT :$PROMETHEUS_PORT\"" >&2
    exit 1
  fi
done

cat <<EOF
  Kiali       http://localhost:$KIALI_PORT     Graph -> namespace mesh-demo
  Grafana     http://localhost:$GRAFANA_PORT      Dashboards -> Istio
  Prometheus  http://localhost:$PROMETHEUS_PORT      try: sum by (destination_version) (rate(istio_requests_total{destination_app="helloworld"}[1m]))

Ctrl+C to stop.
EOF
wait
