# k8s-api (Kubernetes API server endpoint)

Exposes the Talos Kubernetes API server VIP on **`k8s.garage.neo-tix.com`**
via the Envoy Gateway, so the cluster API can be reached from outside the node
network with **`kubectl --server=https://k8s.garage.neo-tix.com`** using a
client certificate (mTLS).

## Why TLS passthrough (not a terminated HTTPS route)

`kubectl` authenticates to the API server with a **client certificate** (mTLS).
The original implementation used an `HTTPRoute` (a terminated HTTPS route):
Envoy terminated the client TLS on the gateway and re-encrypted to the API
server. In that mode the client certificate is **not forwarded** upstream, so
`kube-apiserver` answered:

```
the server has asked for the client to provide credentials
```

The fix is **TLS passthrough**: Envoy does _not_ terminate the client TLS. It
inspects the SNI from the ClientHello and forwards the still-encrypted bytes —
client certificate intact — to the API server VIP. The API server sees the real
client cert and authenticates normally. This is the standard way to expose an
mTLS endpoint behind a shared reverse proxy.

## Architecture

A Gateway listener (Passthrough mode) plus a `Service` + `Endpoints` +
`TLSRoute`:

| Resource  | Kind / API                                        | Purpose                                                                                       |
| --------- | ------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `k8s-tls` | Gateway listener (`envoy-external`, ns `network`) | TLS listener, `protocol: TLS`, `tls.mode: Passthrough`, `hostname: k8s.garage.neo-tix.com`    |
| `k8s-api` | `Service` (`v1`)                                  | `ClusterIP`, no selector — the static backend the `TLSRoute` points at                        |
| `k8s-api` | `Endpoints` (`v1`)                                | The k8s VIP `172.20.17.138:6443` (node-network L4 LB in front of the three `kube-apiservers`) |
| `k8s-api` | `TLSRoute` (`gateway.networking.k8s.io/v1alpha2`) | SNI `k8s.garage.neo-tix.com` → `k8s-api` `Service`; attached to the `k8s-tls` listener        |

Traffic path: client (kubectl, client cert) → (public: Cloudflare → tunnel /
LAN: k8s-gateway A record) → `envoy-external` LB (172.20.17.137) → Envoy
inspects SNI `k8s.garage.neo-tix.com` → **raw TLS passthrough** (no
termination) → `172.20.17.138:6443` (VIP) → the VIP L4-loads to one of the three
control-plane `kube-apiservers`. The client certificate is never touched by
Envoy.

The `k8s-tls` listener coexists with the wildcard `https` (Terminate) listener
on the same port 443 — Envoy builds one SNI-matched filter chain per listener:
SNI `k8s.garage.neo-tix.com` is dispatched to the passthrough chain, every
other SNI to the terminated `https` chain.

## Requirements

- **Gateway listener in Passthrough mode.** The `k8s-tls` listener is defined in
  `kubernetes/apps/network/envoy-gateway/app/envoy.yaml` (the `envoy-external`
  Gateway). `tls.mode: Passthrough` takes no `certificateRefs` — there is no
  serving cert because Envoy does not terminate.
- **No `Backend`, no CA secret.** The previous `Backend`
  (`gateway.envoyproxy.io/v1alpha1`) + `k8s-api-ca` Secret existed only to
  configure the terminated backend leg (Envoy → API server TLS + CA
  verification). In passthrough mode Envoy establishes no upstream TLS, so both
  are gone. (The `Backend` API stays enabled cluster-wide — the `proxmox` app
  still uses it.)
- **Static endpoint via `Service` + `Endpoints`.** The VIP is an external
  (node-network) IP, so it is modelled as a `ClusterIP` `Service` with no
  selector plus a hand-written `Endpoints` — the same pattern as `headscale`
  and `hermes-dashboard`. A `TLSRoute` (unlike a `TCPRoute`) matches on SNI,
  which is what a shared 443 port needs. The `TLSRoute`'s `backendRefs` use a
  plain `Service` (not the `gateway.envoyproxy.io` `Backend`), matching the
  official Envoy Gateway passthrough example.

## DNS

The `k8s-gateway` coreDNS plugin (watches `HTTPRoute`/`Service`/`TLSRoute`
across all namespaces — `TLSRoute` added to `watchedResources` in
`kubernetes/apps/network/k8s-gateway/app/helmrelease.yaml`) creates the A
record `k8s.garage.neo-tix.com → 172.20.17.137` (the `envoy-external` LB IP)
from the `TLSRoute` hostname. **The plugin resolves the `TLSRoute` at
`gateway.networking.k8s.io/v1alpha2`** (k8s_gateway 1.7.0), so the route must
be `v1alpha2`, not `v1`. Public resolution is covered by the existing
`*.garage.neo-tix.com` Cloudflare CNAME → tunnel.

## Pitfalls

- **A terminated HTTPS route (HTTPRoute) cannot forward the client cert.** This
  is the root cause of the original
  "the server has asked for the client to provide credentials" error. mTLS to a
  backend must always be a TLS passthrough (listener `tls.mode: Passthrough` +
  `TLSRoute`), never a terminated route.
- **`TLSRoute` must be `v1alpha2`.** k8s_gateway 1.7.0 (chart 3.7.2) watches
  `TLSRoute` via `GatewayV1alpha2`. A `v1` `TLSRoute` would route fine in Envoy
  but the DNS plugin would ignore it, silently dropping the internal A record.
- **Add `TLSRoute` to the coreDNS `watchedResources`.** Without it the plugin
  only watches `HTTPRoute`/`Service` and the `k8s.garage.neo-tix.com` A record
  disappears. RBAC is already broad (`gateway.networking.k8s.io` `*`
  watch/list), so no ClusterRole change is needed.
- **Listener `hostname` is the SNI match.** For a Passthrough listener the SNI
  filter chain is derived from the listener's `hostname` field; the `TLSRoute`
  `hostnames` must intersect it. Both are set to `k8s.garage.neo-tix.com`.
- **Two listeners on port 443.** The `k8s-tls` (TLS/Passthrough) and `https`
  (HTTPS/Terminate) listeners share port 443; Envoy merges them into one
  listener with per-SNI filter chains. Keep the `k8s-tls` `hostname` specific so
  it does not shadow the wildcard `https` listener.
- **The VIP is not `kubernetes/default`'s ClusterIP.** The service ClusterIP is
  172.20.64.1; the VIP is 172.20.17.138 (node network). Do not "simplify" the
  backend to a `Service` backendRef of `kubernetes`.

## Verification

```bash
# Listener present on the gateway
kubectl -n network get gateway envoy-external \
  -o jsonpath='{range .status.listeners[*]}{.name}: {range .conditions[*]}{.type}={.status} {end}{"\n"}{end}'
# Route accepted + resolved
kubectl -n k8s-api get tlsroute k8s-api -o jsonpath='{.status.parents[0].conditions[*].type}{"\n"}'
# DNS (k8s-gateway zone)
dig +short k8s.garage.neo-tix.com @172.20.17.136
# The actual fix: mTLS with a real client cert (no -k; the cert is presented)
kubectl --server=https://k8s.garage.neo-tix.com \
  --client-certificate=./client.crt --client-key=./client.key \
  --ca-file=./ca.crt get nodes
```
