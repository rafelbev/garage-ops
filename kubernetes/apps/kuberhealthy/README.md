# kuberhealthy

[Kubehealthy](https://github.com/kuberhealthy/kuberhealthy) is a K8s health-check
operator that runs [health checks](https://kuberhealthy.org/docs/) in K8s and
reports the results to Prometheus.

## Checks

| Check                | Type           | Interval | What it verifies                                                                         |
| -------------------- | -------------- | -------- | ---------------------------------------------------------------------------------------- |
| `e2e-jellyfin`       | E2E (network)  | 20m      | `jellyfin.garage.neo-tix.com` responds with HTTP 200                                     |
| `e2e-qbittorrent`    | E2E (network)  | 12h      | `qbittorrent.garage.neo-tix.com` responds with HTTP 200                                  |
| `e2e-home-assistant` | E2E (network)  | 20m      | `home-assistant.garage.neo-tix.com` serves its root page                                 |
| `proxmox-hosts-up`   | Infrastructure | 5m       | Both Proxmox VE hosts answer on `:8006` (401/403 = up, anything else = down)             |
| `nodes-ready`        | Kubernetes API | 10m      | Every node in the cluster reports `Ready=True`                                           |
| `pods-not-stuck`     | Kubernetes API | 10m      | No pod is terminating for >15m, pending for >30m, or stuck in ContainerCreating for >30m |

E2E checks follow the same pattern as the other K8s apps in this repo:
a `curl`-based checker pod makes an HTTPS request to the public URL
(through Envoy Gateway + Authelia) and reports `ok: true` / `ok: false`
to the Kubehealthy API server via the `KH_REPORTING_URL` env var
that Kubehealthy injects.

The API checks (`nodes-ready`, `pods-not-stuck`) run a small Python
script (stdlib only — no pip packages) inside a `python:3.13.5-alpine3.22`
checker pod. The pod authenticates to the API server with the
`kuberhealthy-checks` ServiceAccount (see
[`kuberhealthy/app/rbac.yaml`](kuberhealthy/app/rbac.yaml), minimal
read access to `nodes` and `pods` only) and queries
`https://kubernetes.default.svc` directly.

All HTTP (the API call and the Kubehealthy report) is done with `curl`
(subprocess), not Python's `urllib`: the cluster's API-server load
balancer ties bearer-token auth to the TLS/ALPN handshake that curl
negotiates correctly (ALPN h2, TLS 1.3) but Python's `ssl` does not —
`urllib` requests are rejected with `401` while identical `curl`
requests succeed. `curl` is not in the `python:alpine` base image, so it
is installed on first use via `apk` (idempotent; each checker run is a
fresh pod, so this runs each interval). Python is kept for the JSON and
logic layer only.

The Proxmox check is the early-warning layer for hypervisor-level
failures: a Proxmox host dies before its VMs become unreachable, so
`proxmox-hosts-up` firing means a Talos node is about to go down.

## Why these checks exist (2026-11-18 incident)

On 2026-11-18 the Proxmox VM hosting `cluster-6` went down. It was not
detected for ~13 hours, and in the meantime:

- ~20 pods were stuck: `Terminating` for up to 34h (node object never
  removed), and `ContainerCreating` for 13h (the RWO
  `home-assistant-config` PVC stayed attached to the dead node, so the
  replacement pod could not attach it elsewhere).
- home-assistant, firecrawl, litellm, open-webui, prometheus and
  kuberhealthy itself were all affected.
- The kuberhealthy pod itself was on the dead node, so the alerting
  pipeline went silent with it.
- The Prometheus alertmanager was crash-looping (an invalid
  `header_params` field in the ntfy webhook config), so even the
  `KubehealthyFailedCheck` alert it had been emitting was never
  delivered.

After the incident the following was added:

- `nodes-ready` + `pods-not-stuck` — would have caught the node-down and
  the stuck pods within 10 minutes.
- `proxmox-hosts-up` — would have caught the Proxmox VM dying before any
  K8s symptom appeared.
- `e2e-home-assistant` — the most stateful workload gets its own synthetic.
- Kubehealthy `replicas: 2` — with one replica the whole alerting
  pipeline dies with its node; the chart's default hard pod
  anti-affinity keeps the two replicas on different nodes, and Kubehealthy
  uses leader election so a second instance is safe.

See [`../observability/README.md`](../observability/README.md) for the
full case study, including the alertmanager root cause and the manual
recovery procedure (stale VolumeAttachments).

## Architecture

```
                        ┌─────────────────────┐
                        │   Prometheus        │
                        │   (alerting via     │
                        │    alertmanager)    │
                        └─────────▲───────────┘
                                    │  /metrics
┌───────────────────────────────────┴───────────────────────────────────┐
│                        Kubehealthy API server                         │
│                     (statefulset, replicas: 2)                        │
└───▲───────────────────────────────────────────────────────────────────┬┘
    │ healthcheck results (kh-reporting-url)                            │ check definitions
    │ (POST /api/v1/healthcheck/runs)                                   │ (HealthCheck CR)
┌───┴───────────────────────────────────┐
│  Checker pods (one per check, per run)│
│  e2e-*, proxmox-hosts-up,            │
│  nodes-ready, pods-not-stuck          │
└───────────────────────────────────────┘
```

The Kubehealthy operator creates one short-lived pod per check per
`runInterval`. The pod's container runs the check and POSTs the result
to `KH_REPORTING_URL`. Results are exposed as Prometheus metrics
(`kuberhealthy_*`), and failures raise the `KubehealthyFailedCheck`
alert (fired when a check fails 3+ consecutive times).

## Configuration

All checks are defined in
[`kuberhealthy/app/healthchecks.yaml`](kuberhealthy/app/healthchecks.yaml)
as Kubehealthy `HealthCheck` custom resources. The checker podSpec is
inline in each CR (Kubehealthy v3 has no built-in check types — every
check is a pod spec).

To add a new E2E check for an app, copy one of the existing `e2e-*`
entries and change the URL. To change an interval, edit
`runInterval` on the relevant `HealthCheck`.

### Proxmox host list

`proxmox-hosts-up` hard-codes the two Proxmox host IPs
(`172.20.17.65`, `172.20.17.66`) in the shell loop. If a third host is
added, update the `for host in ...` line in the check's
`healthchecks.yaml` entry.

## Alerting

Kubehealthy exposes Prometheus metrics; the
`KubehealthyFailedCheck` alert fires when a check fails 3+ consecutive
times. Alerts are routed via the Prometheus alertmanager to ntfy
(see [`../observability/README.md`](../observability/README.md)).
Check state is also visible in the Kubehealthy dashboard
(`kuberhealthy` ingress, if exposed) and via:

```bash
kubectl get healthchecks -n kuberhealthy
kubectl get pods -n kuberhealthy -l app.kubernetes.io/part-of=kuberhealthy
```

## Resources

- [Kubehealthy GitHub](https://github.com/kuberhealthy/kuberhealthy)
- [Kubehealthy documentation](https://kuberhealthy.org/docs/)
- [Kubehealthy Helm chart](https://charts.kuberhealthy.com)
