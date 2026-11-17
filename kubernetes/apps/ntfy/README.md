# ntfy — host-endpoint (exposure-only) migration

ntfy is a **host process** on `172.20.17.17:8084` — not a workload in the
Talos cluster. It is exposed only on the cluster side, via the selectorless
`Service` + manual `Endpoints` + `HTTPRoute` pattern (the same pattern as
`hermes-dashboard` and `k8s-api`).

## What moved

| Source (k3s)                           | Target (Talos)                         |
| -------------------------------------- | -------------------------------------- |
| Ingress `ntfy-ingress`                 | HTTPRoute `ntfy` (envoy-external)      |
| host `ntfy.cloud.neo-tix.com`          | `ntfy.garage.neo-tix.com`              |
| Service `ntfy` (no selector)           | Service `ntfy` (no selector)           |
| Endpoints `ntfy` → `172.20.17.17:8084` | Endpoints `ntfy` → `172.20.17.17:8084` |

## Why no Certificate / DNSEndpoint

- **TLS**: `envoy-gateway/app/certificate.yaml` issues a two-level wildcard
  for `*.garage.neo-tix.com`, which covers `ntfy.garage.neo-tix.com`.
- **Public DNS**: `public-dns/app/dnsendpoint.yaml` sets a wildcard A record
  for `*.garage.neo-tix.com` → the public IP. No per-app record needed.

The source Ingress carried a `configuration-snippet` adding WebSocket
`Upgrade`/`Connection` headers. The Talos Gateway API handles WebSocket
upgrades natively, so the HTTPRoute needs no equivalent annotation.

## Rollback

The k3s Ingress/Service/Endpoints are left in place until the new route is
verified; deleting them is the lost rollback.
