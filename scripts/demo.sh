#!/usr/bin/env bash
# Exercise the mesh. Four things, each one resource in mesh/ made observable.
#
# The NLB does not forward packets locally, so the "outside" requests go
# through a port-forward to the ingress gateway Service. In AWS you would
# curl the NLB DNS name from `terraform output ingress_nlb_dns` instead.
set -euo pipefail
cd "$(dirname "$0")/.."

export KUBECONFIG="$PWD/.cluster/kubeconfig.yaml"
LOCAL_PORT="${LOCAL_PORT:-8080}"

SLEEP=$(kubectl -n mesh-demo get pod -l app=sleep -o jsonpath='{.items[0].metadata.name}')

hr() { echo; echo "── $1"; echo; }

hr "1. Sidecars: every pod is 2/2, the second container is istio-proxy"
kubectl -n mesh-demo get pods
echo
# Since Istio 1.28 the proxy is a native sidecar: an init container with
# restartPolicy Always, so it starts before the app and stops after it.
kubectl -n mesh-demo get pod "$SLEEP" \
  -o jsonpath='{range .spec.initContainers[*]}{"    init:      "}{.name}{"\n"}{end}{range .spec.containers[*]}{"    container: "}{.name}{"\n"}{end}'

hr "2. mTLS: a call inside the mesh carries the caller's certificate identity"
echo "    sleep -> httpbin GET /headers"
kubectl -n mesh-demo exec "$SLEEP" -c sleep -- \
  curl -s http://httpbin:8000/headers | grep -i -A1 'X-Forwarded-Client-Cert' | sed 's/^/    /' \
  || echo "    (no XFCC header: is PeerAuthentication applied?)"
echo
echo "    The By= is httpbin's own SPIFFE id, URI= is the caller's. The app did"
echo "    not add this header; the sidecars did, after verifying each other."

hr "3. AuthorizationPolicy: sleep may GET httpbin but not POST"
printf "    GET  /get  -> "
kubectl -n mesh-demo exec "$SLEEP" -c sleep -- curl -s -o /dev/null -w '%{http_code}\n' http://httpbin:8000/get
printf "    POST /post -> "
kubectl -n mesh-demo exec "$SLEEP" -c sleep -- curl -s -w ' %{http_code}\n' -X POST http://httpbin:8000/post
echo
echo "    helloworld has no policy, so it is not allowed to call httpbin at all:"
printf "    helloworld -> httpbin GET /get -> "
HELLO=$(kubectl -n mesh-demo get pod -l app=helloworld,version=v1 -o jsonpath='{.items[0].metadata.name}')
# The helloworld image has no curl; go through its sidecar with a python one-liner.
kubectl -n mesh-demo exec "$HELLO" -c helloworld -- \
  python3 -c 'import urllib.request,urllib.error
try: print(urllib.request.urlopen("http://httpbin:8000/get").status)
except urllib.error.HTTPError as e: print(e.code, e.read().decode())' 2>/dev/null || echo "(no python in image)"

hr "4. Traffic split: 90% v1 / 10% v2 through the ingress gateway"
kubectl -n istio-ingress port-forward svc/istio-ingress "${LOCAL_PORT}:80" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
sleep 2

echo "    50 x GET http://localhost:${LOCAL_PORT}/hello"
for _ in $(seq 1 50); do
  curl -s "http://localhost:${LOCAL_PORT}/hello"
done | awk '/version: v1/ {v1++} /version: v2/ {v2++} END {printf "    v1: %d\n    v2: %d\n", v1, v2}'
echo
echo "    Adjust the weights in mesh/gateway.yaml and re-apply; no pods restart."

hr "5. Through the gateway to httpbin (allowed: the gateway is in the policy)"
printf "    GET /httpbin/get -> "
curl -s -o /dev/null -w '%{http_code}\n' "http://localhost:${LOCAL_PORT}/httpbin/get"
printf "    POST /httpbin/post -> "
curl -s -w ' %{http_code}\n' -X POST "http://localhost:${LOCAL_PORT}/httpbin/post"

echo
echo "Gateway is still reachable at http://localhost:${LOCAL_PORT} until this script exits."
echo "Sidecar access log:  kubectl -n mesh-demo logs deploy/httpbin -c istio-proxy"
