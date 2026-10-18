# public-dns — split DNS horizon (public side)

Splits `*.garage.neo-tix.com` resolution into two horizons:

| Horizon  | Resolver                           | Record                                                                     |
| -------- | ---------------------------------- | -------------------------------------------------------------------------- |
| Public   | Cloudflare (zone `${SECRET_ZONE}`) | A `*.garage.neo-tix.com` / `${SECRET_DOMAIN}` → current public IPv4 (grey) |
| Internal | `k8s-gateway` (172.20.17.136)      | A `<app>.garage.neo-tix.com` → envoy-external LB IP                        |

## Public traffic path

```
internet → CF DNS (grey A record, no edge TLS)
        → router WAN IP
        → router port forward 80/443
        → envoy-external LB (172.20.17.137)
        → envoy (TLS terminated with the Let's Encrypt cert for *.garage.neo-tix.com)
        → backend
```

The router must forward:

- **TCP 80** → `172.20.17.137:80` (envoy 301-redirects to HTTPS)
- **TCP 443** → `172.20.17.137:443` (TLS terminates here)
- **UDP 443** → `172.20.17.137:443` (optional, HTTP/3)

No 8080/8443 are needed because the records are unproxied.

## Why grey (unproxied)

The CF free plan has no edge certificate for the two-level wildcard
(`*.garage.neo-tix.com`), so a proxied (orange) record fails the TLS
handshake at the Cloudflare edge. Grey records send visitors straight to the
public IP, where envoy terminates TLS with the origin Let's Encrypt cert.

The DNSEndpoint sets `providerSpecific: cloudflare/proxied: "false"` on each
endpoint to override the global `--cloudflare-proxied` flag of external-dns
(the flag must stay on: the tunnel CNAME `external.garage.neo-tix.com` has to
remain proxied for the cloudflared tunnel to work).

## Why the per-app CNAMEs were removed

Previously external-dns ran with sources `crd` + `gateway-httproute`, creating
one proxied CNAME per HTTPRoute hostname (`<app>.garage.neo-tix.com` →
`external.garage.neo-tix.com` → tunnel). Exact CNAMEs beat the wildcard, so
every app name still terminated TLS at the CF edge (no cert → broken).
`cloudflare-dns` now runs with sources `["crd"]` only: `policy: sync` deleted
the per-app CNAMEs, and all names fall back to the wildcard A record.

The tunnel CNAME `external.garage.neo-tix.com` (CRD source, DNSEndpoint
`cloudflare-tunnel` in `cloudflare-tunnel/`) is kept as a fallback path.

## Dynamic public IP

`updater.yaml` runs a CronJob every 5 minutes in this namespace:

1. Resolves the cluster's egress public IPv4 (`ifconfig.co`, `api.ipify.org`,
   `ifconfig.me` fallbacks). The cluster NATs through the same router as the
   WAN, so the egress IP equals the WAN IP.
2. Compares against the current target of DNSEndpoint `garage-public`.
3. Patches the DNSEndpoint when it changed; external-dns (CRD source) syncs
   the new A record to Cloudflare within its next cycle.

RBAC: ServiceAccount `public-dns-updater` may `get/list/patch/update`
`dnsendpoints` in `network` only.

## Verification

```bash
# CRD state
kubectl -n network get dnse garage-public -o yaml
kubectl -n network logs cronjob/public-dns-updater --tail=20

# Public resolution (Cloudflare authoritative)
dig @172.64.35.51 radarr.garage.neo-tix.com A
dig @172.64.35.51 garage.neo-tix.com A

# Zone records (should show grey A records, no per-app CNAMEs)
curl -H "Authorization: Bearer $CF_TOKEN" \
  https://api.cloudflare.com/client/v4/zones/neo-tix.com/dns_records
```

## Pitfalls

- **Egress IP must equal the WAN IP.** If a node ever egresses through a
  different uplink (VPN, secondary ISP), the CronJob would pin the A record to
  the wrong address.
- **Don't proxy these records.** Keep `cloudflare/proxied: "false"` in both
  the DNSEndpoint and the CronJob patch payload.
- **The CronJob patch replaces the whole `spec.endpoints` array** (JSON merge
  patch semantics). Both endpoints must always be listed.
- **Manual apex records** (`neo-tix.com`, `intranet.neo-tix.com`, `www`,
  `mail`) have no external-dns owner TXT, so external-dns skips them — they
  are maintained manually and are outside this app's scope.
