# k8s-api (Kubernetes API server endpoint)

Exposes the Talos Kubernetes API server VIP on **`k8s.garage.neo-tix.com`**
via the Envoy Gateway, so the cluster API can be reached from outside the
node network (e.g. `kubectl --server=https://k8s.garage.neo-tix.com`).
Same pattern as `proxmox` (PR #180).

## Architecture

Two Gateway-API resources plus a Secret, all in the `k8s-api` namespace:

| Resource     | Kind / API                                   | Purpose                                                                                           |
| ------------ | -------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `k8s-api`    | `Backend` (`gateway.envoyproxy.io/v1alpha1`) | Static endpoint `172.20.17.138:6443` (the k8s VIP) with backend TLS settings                      |
| `k8s-api`    | `HTTPRoute` (`gateway.networking.k8s.io/v1`) | `k8s.garage.neo-tix.com` → `k8s-api` Backend, attached to Gateway `envoy-external` (ns `network`) |
| `k8s-api-ca` | `Secret` (`v1`)                              | Cluster CA used to verify the API server's serving cert on the backend leg                        |

Traffic path: client → (public: Cloudflare → tunnel / LAN: k8s-gateway A
record) → `envoy-external` LB (172.20.17.137) → Envoy terminates client TLS
(wildcard cert) → Envoy re-encrypts to `172.20.17.138:6443` (VIP) → the VIP
L4-loads to one of the three control-plane `kube-apiservers`.

## Requirements

- **Envoy Gateway Backend API enabled.** The `Backend` CRD is an extension
  API that is **off by default**. It is enabled cluster-wide via
  `kubernetes/apps/network/envoy-gateway/app/helmrelease.yaml`
  (`config.envoyGateway.extensionApis.enableBackend: true`), which renders
  into the `envoy-gateway-config` ConfigMap in `network`.
- **No Service/Endpoints objects** — the VIP is an external (node-network)
  IP, so the `Backend` uses a static IP endpoint (this is exactly what the
  Backend API is for). The ClusterIP of `kubernetes/default`
  (172.20.64.1) is _not_ the VIP and is not used.
- **API server cert SAN.** The `KubeAPIServerConfig.certExtraSANs` patch
  (`talos/control-plane/00-cluster.yaml.tpl`) already adds
  `${data.apiServerDomain}` (`k8s.garage.neo-tix.com`) and the VIP to the
  serving cert, so both the client leg (wildcard cert) and the backend leg
  (cluster CA) verify cleanly.

## Configuration

- **Endpoint:** the k8s VIP `172.20.17.138` (`talos/topf.yaml`
  `data.clusterVip`) on port `6443`.
- **TLS:** `tls.caCertificateRefs` → `k8s-api-ca` Secret (cluster CA).
  Unlike the Proxmox pool (self-signed certs, `tls.insecureSkipVerify:
  true`), the API server serves a proper cert chain-anchored to the cluster
  CA, so verification is _not_ skipped. Envoy validates the backend
  address (VIP IP) against the cert's IP SAN.

## DNS

No manual DNS work: the `k8s-gateway` coreDNS plugin (watches `HTTPRoute`
across all namespaces) creates the A record
`k8s.garage.neo-tix.com → 172.20.17.137` (the `envoy-external` LB IP) once
the route reconciles. Public resolution is covered by the existing
`*.garage.neo-tix.com` Cloudflare CNAME → tunnel.

## Pitfalls

- **`caCertificateRefs` requires `group` and `kind`.** Unlike a classic
  `LocalObjectReference`, the `Backend` CRD's `tls.caCertificateRefs`
  entries are rejected by admission without explicit `group: ""` and
  `kind: Secret` (`spec.tls.caCertificateRefs[0].group: Required value`).
- **Byte-compare any pasted CA/cert.** A single base64 character typo in
  the CA PEM makes Envoy reject the config with
  `Failed to load trusted CA certificates from <inline>` in the envoy logs,
  and the route fails with `remote connection failure` — the objects all
  show `Accepted=True`, so the logs are the only signal.
- **Enable the Backend API before creating `Backend`s.** Without
  `extensionApis.enableBackend: true`, a `Backend` is accepted by the API
  server but never programmed (no `status`).
- **The VIP is not `kubernetes/default`'s ClusterIP.** The service
  ClusterIP is 172.20.64.1; the VIP is 172.20.17.138 (node network). Do not
  "simplify" the Backend to a `Service` backendRef of `kubernetes`.

## Verification

```bash
# Backend + route accepted
kubectl get backend k8s-api -n k8s-api -o jsonpath='{.status.conditions[*].type}'
kubectl get httproute k8s-api -n k8s-api -o jsonpath='{.status.parents[0].conditions[*].type}'
# DNS (k8s-gateway zone)
dig +short k8s.garage.neo-tix.com @172.20.17.136
# Traffic with full cert verification (no -k)
curl -sS --resolve k8s.garage.neo-tix.com:443:172.20.17.137 \
  https://k8s.garage.neo-tix.com/version
```
