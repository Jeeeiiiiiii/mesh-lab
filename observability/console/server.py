"""Traffic console: fire bursts of requests through the mesh on demand.

Standard library only, so it runs from a ConfigMap on a stock Python image
with nothing to build or push. It sits in mesh-demo with its own
ServiceAccount, so every request it sends carries the identity
`console` -- which is what lets Grafana and Kiali show your clicks apart
from loadgen's background traffic.

Routes (all under /console, the prefix the ingress gateway forwards here):
  GET  /console/               the page
  POST /console/api/fire       {"kind": ..., "count": n} -> burst result
  GET  /console/api/loadgen    {"replicas": n}
  POST /console/api/loadgen    {"running": bool} -> scales loadgen 1 or 0
"""

import json
import os
import ssl
import threading
import time
import urllib.error
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
GATEWAY = os.environ.get("GATEWAY_URL", "http://istio-ingress.istio-ingress.svc.cluster.local")
HTTPBIN = os.environ.get("HTTPBIN_URL", "http://httpbin.mesh-demo.svc.cluster.local:8000")
NAMESPACE = os.environ.get("POD_NAMESPACE", "mesh-demo")
MAX_COUNT = 200
CONCURRENCY = 10

# What each button sends. The path decides which mesh rule it exercises.
KINDS = {
    # Through the front door: the VirtualService picks v1 or v2 per request.
    "split": ("GET", GATEWAY + "/hello"),
    # Straight to httpbin: console is not in the AuthorizationPolicy -> 403.
    "denied": ("POST", HTTPBIN + "/post"),
    # Through the front door; httpbin answers 500 on purpose.
    "errors": ("GET", GATEWAY + "/httpbin/status/500"),
    # Through the front door; httpbin waits 2s before answering.
    "slow": ("GET", GATEWAY + "/httpbin/delay/2"),
}


def one_request(method, url):
    start = time.monotonic()
    req = urllib.request.Request(url, method=method, data=b"" if method == "POST" else None)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            code, body = resp.status, resp.read(512)
    except urllib.error.HTTPError as e:
        code, body = e.code, b""
    except Exception:
        code, body = 0, b""  # connection refused, reset, timeout
    version = None
    if b"version: v1" in body:
        version = "v1"
    elif b"version: v2" in body:
        version = "v2"
    return code, version, (time.monotonic() - start) * 1000


def fire(kind, count):
    method, url = KINDS[kind]
    start = time.monotonic()
    with ThreadPoolExecutor(max_workers=CONCURRENCY) as pool:
        results = list(pool.map(lambda _: one_request(method, url), range(count)))
    latencies = sorted(r[2] for r in results)

    def pct(p):
        return round(latencies[min(len(latencies) - 1, int(len(latencies) * p))])

    return {
        "kind": kind,
        "sent": count,
        "target": url,
        "codes": dict(Counter(str(r[0]) for r in results)),
        "versions": dict(Counter(r[1] for r in results if r[1])),
        "latency_ms": {"p50": pct(0.50), "p95": pct(0.95), "max": round(latencies[-1])},
        "elapsed_ms": round((time.monotonic() - start) * 1000),
    }


# --- Kubernetes API, for the loadgen switch -------------------------------
# The console's ServiceAccount may read and scale exactly one Deployment,
# loadgen (see console.yaml). Nothing else in the cluster.

SA = "/var/run/secrets/kubernetes.io/serviceaccount"
K8S = "https://kubernetes.default.svc"
SCALE_URL = f"{K8S}/apis/apps/v1/namespaces/{NAMESPACE}/deployments/loadgen/scale"


def k8s(method, url, body=None, content_type="application/json"):
    with open(f"{SA}/token") as f:
        token = f.read()
    req = urllib.request.Request(
        url,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {token}", "Content-Type": content_type},
    )
    ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
    with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
        return json.loads(resp.read())


def loadgen_replicas():
    return k8s("GET", SCALE_URL)["spec"].get("replicas", 0)


def set_loadgen(running):
    patch = {"spec": {"replicas": 1 if running else 0}}
    return k8s("PATCH", SCALE_URL, patch, "application/merge-patch+json")["spec"].get("replicas", 0)


# --- HTTP ------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"{}")

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        if path == "/console":
            with open(os.path.join(HERE, "index.html"), "rb") as f:
                body = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif path == "/console/api/loadgen":
            try:
                self.send_json(200, {"replicas": loadgen_replicas()})
            except Exception as e:
                self.send_json(502, {"error": f"could not read loadgen: {e}"})
        elif path == "/healthz":
            self.send_json(200, {"ok": True})
        else:
            self.send_json(404, {"error": f"no route for {path}"})

    def do_POST(self):
        path = self.path.split("?")[0].rstrip("/")
        try:
            data = self.read_json()
        except ValueError:
            return self.send_json(400, {"error": "body is not JSON"})
        if path == "/console/api/fire":
            kind = data.get("kind")
            if kind not in KINDS:
                return self.send_json(400, {"error": f"kind must be one of {sorted(KINDS)}"})
            count = max(1, min(MAX_COUNT, int(data.get("count", 50))))
            self.send_json(200, fire(kind, count))
        elif path == "/console/api/loadgen":
            try:
                self.send_json(200, {"replicas": set_loadgen(bool(data.get("running")))})
            except Exception as e:
                self.send_json(502, {"error": f"could not scale loadgen: {e}"})
        else:
            self.send_json(404, {"error": f"no route for {path}"})

    def log_message(self, fmt, *args):
        # One line per API call; skip the probe noise.
        if "/healthz" not in self.path:
            print(f"{self.command} {self.path} -> {args[1] if len(args) > 1 else ''}", flush=True)


def warm_up():
    """Send one request of each kind so every counter exists before you click.

    Envoy creates a counter on its first request, so Prometheus first sees
    it already at 50 after a burst of 50. rate() and increase() need a
    previous value to subtract from, and a series that is born at 50 has
    none: the first burst of each kind would never appear in Grafana. Born
    at 1 instead, the counter is in place and your first click shows as a
    jump from 1 to 51.
    """
    for _ in range(30):  # the sidecar and the gateway may still be starting
        if one_request("GET", GATEWAY + "/hello")[0] == 200:
            break
        time.sleep(2)
    for kind, (method, url) in KINDS.items():
        one_request(method, url)
    print("warm-up done: one request of each kind sent", flush=True)


if __name__ == "__main__":
    print(f"traffic console on :8080 (gateway {GATEWAY})", flush=True)
    threading.Thread(target=warm_up, daemon=True).start()
    ThreadingHTTPServer(("", 8080), Handler).serve_forever()
