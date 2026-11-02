# Envoy Gateway

Envoy Gateway provides north-south ingress for the Talos cluster. Two
gateway deployments handle external and internal traffic:

| Deployment       | Namespace | Purpose                    | Exposed via            |
| ---------------- | --------- | -------------------------- | ---------------------- |
| `envoy-external` | `network` | External (LAN) ingress     | Cilium L2 announcement |
| `envoy-internal` | `network` | Internal (cluster) ingress | Cilium L2 announcement |

Both are exposed as LoadBalancer services on the LAN via Cilium L2
announcements. See the [Cilium README](../../kube-system/cilium/README.md)
for the full load-balancer configuration and the DSR return-path fix.

## External Gateway

The `envoy-external` Deployment runs two replicas — one per worker node
(cluster-3 and cluster-4) — and is exposed on the LAN as a LoadBalancer
service. HTTPRoutes in each app namespace direct traffic from the external
gateway to the appropriate backend `Service`.

The service exposes:

- `443/TCP` → Envoy HTTPS (port 10443)
- `80/TCP` → Envoy HTTP (port 10443, redirects to HTTPS)
- `443/UDP` → Envoy QUIC/H3 (port 10443)

### Intermittent Connectivity (resolved Nov 2026)

**Symptom:** External requests to `https://<app>.garage.neo-tix.com`
intermittently failed with connection timeouts (`HTTP 000`). The failure rate
was ~50%, correlating with which envoy pod the socket-LB selected per-flow.

**Root cause:** DSR mode with the default `opt` dispatch produced an asymmetric
L2 return path when the socket-LB (maglev) selected the remote envoy pod
(cluster-4) while the L2-announcer Lease was held by cluster-3. The reply's
source MAC (cluster-4) did not match the client's ARP entry for the VIP
(cluster-3), so the packet was dropped. Full explanation in the
[Cilium README](../../kube-system/cilium/README.md#dsr--l2-announcer--cross-node-backends).

**Fix:** Cilium `loadBalancer.dsrDispatch` changed from the implicit `opt`
default to `geneve`. Geneve-encapsulated DSR tunnels the reply back through
the original receiving node, making the return path symmetric.

**Verification (post-merge):**

1. Flux reconciles the Cilium HelmRelease; all cilium-agent pods roll.
2. `kubectl -n kube-system exec ds/cilium -- cilium bpf lb maglev list`
   confirms the maglev table is populated.
3. Repeated external requests to any `*.garage.neo-tix.com` hostname succeed
   consistently (no `HTTP 000` timeouts across 15+ requests).
