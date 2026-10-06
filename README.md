# Mesh Lab

A private EKS cluster behind a load balancer, with Istio inside it. The
application is three sample services and is beside the point; **the
infrastructure and the mesh are the subject.**

Everything runs locally against [Floci](https://github.com/floci-io/floci), an
AWS emulator. The Terraform is written for a real account and the only thing
pointing it at the emulator is the `endpoints` block in `terraform/providers.tf`.

```
                         VPC 10.0.0.0/16
   ┌──────────────────────────────────────────────────────────────┐
   │  public 10.0.0.0/24 (1a)      public 10.0.1.0/24 (1b)        │
   │  ┌──────────┐ ┌─────────┐    ┌─────────┐                     │
   │  │ bastion  │ │   NAT   │    │         │  ◄── NLB :80        │◄── internet
   │  └────┬─────┘ └────┬────┘    └─────────┘        │            │
   │       │ 443        │ egress                     │ 30080      │
   │  ─────┼────────────┼────────────────────────────┼──────────  │
   │       ▼            ▼                            ▼            │
   │  private 10.0.10.0/24 (1a)    private 10.0.11.0/24 (1b)      │
   │  ┌─────────────────────────────────────────────────────────┐ │
   │  │ EKS  ┌─────────────┐  ┌────────────┐  ┌──────────────┐  │ │
   │  │      │ingress-gw   │─►│helloworld  │  │ httpbin      │  │ │
   │  │      │  (Envoy)    │  │ v1 90/v2 10│  │ GET-only ACL │  │ │
   │  │      └─────────────┘  └────────────┘  └──────────────┘  │ │
   │  │                         ▲ mTLS ▲          ▲ mTLS        │ │
   │  │      ┌─────────┐        └───────┴──────────┘            │ │
   │  │      │ istiod  │        ┌─────────┐                     │ │
   │  │      └─────────┘        │ sleep   │ (curl client)       │ │
   │  └─────────────────────────┴─────────┴─────────────────────┘ │
   └──────────────────────────────────────────────────────────────┘
```

## What Terraform builds

| Layer | Resources | The decision it encodes |
|---|---|---|
| **Network** | VPC, 2 public + 2 private subnets across 2 AZs, IGW, one NAT gateway, two route tables | The cluster has no public addresses. It gets out via NAT and is reached only through the NLB. Two AZs because an NLB and EKS both refuse fewer. |
| **Security groups** | `bastion`, `nlb`, `cluster`, `node` — rules reference each other, not CIDRs | The one that matters for Istio: **control plane → nodes on 1025–65535**. The API server calls the istiod injection webhook on 15017; block that and every pod in an injected namespace fails admission. |
| **IAM** | Cluster role + node role with the standard managed policies | Two identities: one the control plane uses to manage your account, one the kubelets use to join. |
| **EKS** | Cluster (private endpoint only) + managed node group in the private subnets | `endpoint_public_access = false`. kubectl goes through the bastion. |
| **Load balancer** | Internet-facing NLB in the public subnets → target group on NodePort 30080 → the Istio ingress gateway | NLB, not ALB: the mesh wants the raw connection and terminates HTTP itself. |
| **EC2** | Bastion in a public subnet, SSH from `admin_cidr`, user data installs kubectl | The only way to reach a private API endpoint without a VPN. |

## What Istio adds

Sidecar mode, installed with the three official Helm charts (`base`, `istiod`,
`gateway`). Every pod in `mesh-demo` gets an Envoy proxy that owns all of its
traffic. Four resources in `mesh/` then use that:

| Resource | What it does | What `scripts/demo.sh` shows |
|---|---|---|
| `Gateway` + `VirtualService` | The ingress gateway listens on :80; `/hello` splits **90% v1 / 10% v2**, `/httpbin/` rewrites and forwards | 50 requests → ~45 v1, ~5 v2. Change the weights and re-apply; nothing restarts. |
| `DestinationRule` | Turns the `version` pod label into named subsets; adds outlier detection | (used by the split above) |
| `PeerAuthentication` STRICT | Mesh-wide: sidecars refuse any inbound that is not mTLS from another sidecar | `sleep → httpbin /headers` carries `X-Forwarded-Client-Cert` with both SPIFFE identities. The app never added it. |
| `AuthorizationPolicy` | Only `sleep` and the ingress gateway may call httpbin, and only `GET` | `POST` → `403 RBAC: access denied`. `helloworld → httpbin` → 403. The app never sees the request. |

## Running it

Prerequisites: Docker, Terraform, kubectl, Helm. Commands are bash; on Windows
run them from Git Bash or `bash scripts/...` from PowerShell.

```powershell
# 1. Emulator + console (separate repo)
cd ..\floci-ui
docker compose up -d                  # emulator :4566, console :4500

# 2. Infrastructure
cd ..\mesh-lab
terraform -chdir=terraform init
terraform -chdir=terraform apply -auto-approve
# ~90s. Floci starts a real k3s container for the EKS cluster and a real
# Amazon Linux container for the bastion. See it all at http://localhost:4500.

# 3. Cluster credentials, Istio, demo workloads
bash scripts/kubeconfig.sh            # writes .cluster/kubeconfig.yaml
bash scripts/mesh-up.sh               # ~1-3 min, pulls the Istio images the first time

# 4. Exercise the mesh
bash scripts/demo.sh

# 5. Tear down
bash scripts/down.sh
```

From PowerShell, to poke at the cluster yourself:

```powershell
$env:KUBECONFIG = "$PWD\.cluster\kubeconfig.yaml"
kubectl get pods -n mesh-demo
kubectl -n mesh-demo logs deploy/httpbin -c istio-proxy      # Envoy access log
kubectl -n istio-ingress port-forward svc/istio-ingress 8080:80
```

## Things to try

- Move the split to 50/50 in `mesh/gateway.yaml`, `kubectl apply -f mesh/gateway.yaml`, re-run the demo.
- Delete `mesh/authorization-policy.yaml` from the cluster and watch `POST` start working: with no policy selecting a workload, everything is allowed.
- Set `PeerAuthentication` to `PERMISSIVE`, then `kubectl run` a pod in the `default` namespace (no sidecar) and curl `httpbin.mesh-demo:8000`. Flip back to `STRICT` and it is refused — at the proxy, before the app.
- Add a `fault.delay` to the httpbin route in the `VirtualService` and see latency appear without touching httpbin.
- Remove the `node_from_cluster` security group rule in `terraform/security.tf`. In a real account, the next pod created in `mesh-demo` would fail admission with a webhook timeout. (Locally the emulator does not enforce security groups, so this one is thought-experiment only.)

## Observability

Every sidecar already counts what it does: each request, by source, destination,
version and response code (`istio_requests_total`), plus latency and bytes. None
of that is visible until something collects it. The optional stack in
`observability/` does:

| Tool | Role | What to look at |
|---|---|---|
| Prometheus | Scrapes every Envoy's counters every 5s (the pods are annotated by Istio; nothing to configure) | `sum by (destination_version) (rate(istio_requests_total{destination_app="helloworld"}[1m]))` |
| Grafana | The official Istio dashboards over those metrics | Dashboards → Istio → Istio Service Dashboard, service `helloworld` |
| Kiali | The mesh as a live graph, with the Istio config that shapes it | Graph → namespace `mesh-demo`, Display → Traffic Distribution |
| `loadgen` | Constant traffic, so the graphs have something to draw | Its direct call to httpbin is refused, so one edge is always red |

The three tools run in their own namespace, `observability`, which is not
injected: they watch the mesh without being part of it.

```bash
bash scripts/observability-up.sh     # ~2-3 min: three Helm releases + loadgen
bash scripts/dashboards.sh           # port-forwards until Ctrl+C
```

Kiali on http://localhost:20001, Grafana on :3000, Prometheus on :9090. If a
port is taken, override it: `KIALI_PORT=21001 bash scripts/dashboards.sh`.

Things to watch while you change the mesh:

- **The split.** With Traffic Distribution on, the `helloworld` edges show the
  percentage going to v1 and v2. Change the weights in `mesh/gateway.yaml`,
  apply, and watch the numbers move over the next minute.
- **The refusal.** `loadgen → httpbin` is red: 100% 4xx. Click the edge to see
  the 403s; click httpbin and the Istio Config tab lists the
  `AuthorizationPolicy` that did it. Add `cluster.local/ns/mesh-demo/sa/loadgen`
  to the policy's principals and the edge turns green.
- **The padlock.** Display → Security draws a lock on every mTLS edge. Switch
  `PeerAuthentication` to `PERMISSIVE` and run the `default`-namespace pod from
  "Things to try": its edge arrives from `unknown` with no lock.
- **Latency.** Add the `fault.delay` to the httpbin route and watch the P99 on
  the Istio Service Dashboard for httpbin climb to 3s.

No tracing: traces need the apps to forward trace headers, and the samples
do not. The stack is torn down with the cluster by `scripts/down.sh`.

### Traffic console

A page with buttons that send a burst of requests through the mesh, so you can
cause something and then find it in the graphs. `observability-up.sh`
installs it; it is served through the ingress gateway like any outside request:

```bash
kubectl -n istio-ingress port-forward svc/istio-ingress 18080:80
# http://localhost:18080/console
```

| Button | Path through the mesh | Result |
|---|---|---|
| Split traffic between versions | console → gateway → helloworld v1/v2 | the v1/v2 ratio from `mesh/gateway.yaml` |
| Get refused by the guest list | console → httpbin (POST) | 403 from httpbin's sidecar: `console` is not in the policy |
| Make httpbin fail | console → gateway → httpbin `/status/500` | a 5xx spike |
| Make httpbin slow | console → gateway → httpbin `/delay/2` | p95 latency of about 2s |

Under each button, a bar shows where that burst went. The **Background
traffic** switch scales `loadgen` to 0 or 1, so the graphs show only your
requests. The console's ServiceAccount may scale that one Deployment and
nothing else (`observability/console.yaml`).

The matching Grafana dashboard is **Istio → Traffic console**
(`localhost:3000/d/traffic-console`). It refreshes every 5s and its first
panel counts only `source_workload="console"`. A burst appears 10–20 seconds
after the click.

How it works: `observability/console/server.py` is a standard-library Python
server, loaded from a ConfigMap onto a stock `python:3.13-alpine` image, so
there is nothing to build. It runs in `mesh-demo` with its own identity, which
is why it shows up as its own node in Kiali and can be filtered on in
Grafana. A second VirtualService adds `/console` to the gateway without
touching `mesh/gateway.yaml`: Istio merges gateway VirtualServices that share
a host.

One Prometheus detail it works around: Envoy creates a counter on its first
request, so after a burst of 50 the first value Prometheus scrapes is
already 50. `rate()` needs an earlier value to compare against, so that first
burst would never appear. The console sends one request of each kind at
startup, so every counter exists before your first click.

## Diagram

`docs/architecture.html` — an interactive version of the picture above with
three guided views (traffic in, inside the mesh, operator access). Open it in
a browser. Source: `docs/architecture.archify.json`.

## Next steps

Each of these is a self-contained afternoon and builds on what is here:

1. **Register the nodes into the NLB for real.** Install the AWS Load Balancer Controller and a `TargetGroupBinding` for the ingress gateway Service — the piece the README lists as gap 1. Locally the NLB stays metadata, but the manifests are what a real cluster needs.
2. **Ambient mode.** Re-install Istio with the `ambient` profile (ztunnel + a waypoint for `httpbin`) and re-run `demo.sh`. Same policies, no sidecars; compare `kubectl get pods` before and after.
3. **Egress control.** Switch `outboundTrafficPolicy` to `REGISTRY_ONLY`, watch `sleep` lose the internet, then add a `ServiceEntry` and an egress gateway for one external host.
4. **Tracing.** Metrics and the graph are in `observability/` (see above). Traces are not: add Tempo or Jaeger, set the mesh's tracing provider in `mesh/values/istiod.yaml`, and deploy an app that forwards the `traceparent` header (Istio's Bookinfo does) to see one request as a single trace across the gateway and every hop.
5. **Progressive delivery.** Replace the fixed 90/10 with Argo Rollouts driving the `VirtualService` weights from a Prometheus success-rate query — a canary that promotes itself.
6. **Run it on real AWS.** Delete the `endpoints` block, add IRSA for the load balancer controller, and apply. Everything else is already written for it.

## What is real and what is not

Floci does a lot more than return metadata:

- **EKS is a real cluster.** `aws_eks_cluster` becomes a privileged k3s container (`floci-eks-mesh-lab`) with its API server published on a host port. Istio, the sidecars, mTLS, the policies — all genuinely running.
- **The bastion is a real instance.** An Amazon Linux 2023 container with the user data executed; kubectl is installed and it can reach the cluster API.
- **VPC, subnets, route tables, security groups, IAM, NLB** are created and validated (the NLB really does refuse a single AZ) and visible in the console.

The gaps, stated here rather than left to be found:

1. **The NLB forwards nothing.** It is metadata. `scripts/demo.sh` port-forwards to the ingress gateway Service instead. In AWS, the AWS Load Balancer Controller would register the nodes into the target group (a `TargetGroupBinding`), which this repo does not install.
2. **The node group is one node.** Floci's k3s is single-node; the node group reports `ACTIVE` with `desired_size = 2` but there is one kubelet. Nothing in the demo depends on node count.
3. **Security groups are not enforced locally.** They are created, referenced, and inspectable, but the emulator does not filter traffic with them.
4. **`kubeconfig.sh` reads credentials out of the k3s container.** In AWS you run `aws eks update-kubeconfig` from the bastion (the alias `kube-login` is in its profile). The token-webhook auth that would make that work is configured on the local cluster, but the AWS CLI is not installed on this machine.
5. **The cluster's disk outlives the cluster.** Floci keeps k3s state in a Docker volume named after the cluster, so `terraform destroy` + `apply` brings the cluster back with Istio and the demo already in it. `scripts/down.sh` removes the volume so the next apply is genuinely fresh.
6. **`max_retries = 2` in the provider is for the emulator.** Deleting an NLB makes the provider poll `DescribeNetworkInterfaces` with a `description` filter, which Floci answers with a 500. The SDK's default 25 retries with backoff turn that into a half-hour hang on one resource; with 2 it fails in seconds, the provider logs a warning, and the destroy continues. Remove that line against a real account.
7. **The cluster does not survive a Docker restart.** The k3s node comes back with a different IP and refuses to start (`failed to find interface with specified node ip`). Terraform still thinks the cluster exists. Recreate it: `terraform -chdir=terraform apply -replace=aws_eks_cluster.this -auto-approve`, then `scripts/kubeconfig.sh` and `scripts/mesh-up.sh` again.

## Layout

```
terraform/     VPC, subnets, NAT, security groups, IAM, EKS, NLB, bastion
mesh/values/   Helm values for istiod and the ingress gateway
mesh/          Gateway, VirtualService, DestinationRule, PeerAuthentication, AuthorizationPolicy
app/           helloworld v1+v2, httpbin, sleep -- namespace labelled for injection
observability/ Helm values for Prometheus, Grafana, Kiali; Istio + Traffic console
               dashboards; loadgen; the traffic console (console/, console.yaml)
scripts/       kubeconfig.sh, mesh-up.sh, demo.sh, observability-up.sh, dashboards.sh,
               down.sh, bastion-bootstrap.sh (EC2 user data)
```
