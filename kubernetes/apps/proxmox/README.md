# Proxmox (VM-server pool)

Exposes the Proxmox VE Web/API on **`proxmox.garage.neo-tix.com`** via the
Envoy Gateway, replacing the k3s `vmservers-balanced-service` load balancer at
`proxmox.cloud.neo-tix.com`.

## Architecture

Three Gateway-API resources, all in the `proxmox` namespace:

| Resource    | Kind / API                                                | Purpose                                                                                                 |
| ----------- | --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `vmservers` | `Backend` (`gateway.envoyproxy.io/v1alpha1`)              | External IP pool: `172.20.17.65:8006`, `172.20.17.66:8006`                                              |
| `vmservers` | `BackendTrafficPolicy` (`gateway.envoyproxy.io/v1alpha1`) | ConsistentHash / SourceIP sticky routing, targets the HTTPRoute                                         |
| `proxmox`   | `HTTPRoute` (`gateway.networking.k8s.io/v1`)              | `proxmox.garage.neo-tix.com` → `vmservers` Backend, attached to Gateway `envoy-external` (ns `network`) |

The wildcard cert `*.garage.neo-tix.com` (in `network`, managed by
cert-manager) already covers `proxmox.garage.neo-tix.com`, so no new
certificate is needed.

## Requirements

- **Envoy Gateway Backend API enabled.** The `Backend` CRD is an extension API
  that is **off by default**. It is enabled cluster-wide via
  `kubernetes/apps/network/envoy-gateway/app/helmrelease.yaml`
  (`config.envoyGateway.extensionApis.enableBackend: true`), which renders into
  the `envoy-gateway-config` ConfigMap in `network`.
- **No Service/Deployment** — Proxmox runs on external VM IPs, so the
  `Backend` uses static IP endpoints (this is exactly what the Backend API is
  for).

## Configuration

- **Pool** mirrors the live k3s `vmservers-balanced-service` endpoints
  (`172.20.17.65`, `172.20.17.66`) on port `8006`.
- **TLS:** `tls.insecureSkipVerify: true` on the Backend. The Proxmox servers
  present self-signed certs (same Proxmox Cluster Manager CA) and do not serve
  the CA chain; the k3s nginx ingress also did not verify backend certs
  (`proxy_ssl_verify` defaults off), so skipping verification is the faithful
  replication.
- **Sticky routing:** Proxmox sessions are per-node, so a `BackendTrafficPolicy`
  with `loadBalancer.type: ConsistentHash` + `consistentHash.type: SourceIP`
  pins a client source IP to the same VM server (avoids mid-session node
  switches). Remove the `BackendTrafficPolicy` for plain round-robin.

## Pitfalls

- **`BackendTrafficPolicy` cannot target a `Backend`.** Its `targetRefs` only
  accept `Gateway`/`HTTPRoute`/`GRPCRoute`/`TCPRoute`/`UDPRoute`/`TLSRoute` /
  `ListenerSet` (group `gateway.networking.k8s.io`). Attach it to the
  **HTTPRoute**; the load-balancing policy then applies to the route's
  backends. (A `targetRef` with `kind: Backend` is rejected by admission.)
- **Enable the Backend API before creating `Backend`s.** Without
  `extensionApis.enableBackend: true`, a `Backend` is accepted by the API server
  but never programmed (no `status`).
- **The `Backend` pool is only the live k3s servers** (`.65`, `.66`), not the
  older `.0.11`/`.0.12`/`.0.13` hosts, which are reachable but were not in the
  live balanced pool.

## Verification

```bash
# Backend + route accepted
kubectl get backend vmservers -n proxmox -o jsonpath='{.status.conditions[*].type}'
kubectl get httproute proxmox -n proxmox -o jsonpath='{.status.parents[0].conditions[*].type}'
# Traffic (gateway LB IP 172.20.17.137)
curl -sk -H "Host: proxmox.garage.neo-tix.com" https://172.20.17.137/
```
