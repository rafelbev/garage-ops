# Observability — minimal Prometheus + Alertmanager

A **minimal** Prometheus + Alertmanager stack that scrapes Kubehealthy metrics
and fires alerts when a synthetic check fails. This is the alerting backend for
the `kuberhealthy` app (see
[`kubernetes/apps/kuberhealthy/README.md`](../kuberhealthy/README.md)).

## What it does

- **Prometheus** scrapes the `kuberhealthy_check` metric from the Kubehealthy
  service via a static scrape config (`extraScrapeConfigs`).
- **Alert rule** `HealthCheckFailed` fires when `kuberhealthy_check == 0 for 5m`.
- **Alertmanager** receives the alert from Prometheus and routes it to an
  ntfy webhook (`https://ntfy.garage.neo-tix.com/kuberhealthy`). Both firing
  and resolved alerts are delivered to subscribers of the `kuberhealthy`
  topic; the JSON alert payload is the notification message body.

## Why this chart / shape

- Uses the `prometheus-community/prometheus` chart in single-instance mode with
  only the Prometheus server + Alertmanager enabled (kube-state-metrics,
  node-exporter, and pushgateway are disabled).
- The chart's generated `prometheus.yml` does **not** read `ServiceMonitor`
  CRDs, so Kubehealthy is scraped with a static `extraScrapeConfigs` entry
  rather than a `ServiceMonitor`.
- The alert rule lives in `serverFiles.alerting_rules.yml` (the chart's
  `prometheus.yml` already references `/etc/config/alerting_rules.yml`).
- Alertmanager routing is set via `alertmanager.config`.

## Viewing / accessing

- **Prometheus UI**: `kubectl port-forward svc/prometheus-server -n observability 9090:80`
  then open `http://localhost:9090` (Alerts → Active alerts).
- **Alertmanager UI**: `kubectl port-forward svc/alertmanager-operated -n observability 9093:9093`
  then open `http://localhost:9093`.
- **Kubehealthy UI**: see the `kuberhealthy` README.

## Notification receiver

Alerts are routed to an ntfy webhook
(`https://ntfy.garage.neo-tix.com/kuberhealthy`). Subscribers of the
`kuberhealthy` topic receive a push notification for each firing and
resolved alert; the JSON body is the full Alertmanager payload.

NB: no `header_params` on the webhook entry — Alertmanager 0.35 does not
accept it in `webhook_configs` and crash-loops on load. It had broken
the whole alerting pipeline since day one (see the case study below).

To change the receiver, edit the `alertmanager.config` in
[`prometheus/app/helmrelease.yaml`](prometheus/app/helmrelease.yaml).
Other common receivers: `email_configs`, `opsgem_configs`,
`pagerduty_configs`, `wechat_configs`, etc. See the
[Alertmanager docs](https://prometheus.io/docs/alerting/latest/configuration/).

## Case study: the 2026-11-18 cluster-6 outage

On 2026-11-18 the Proxmox VM hosting `cluster-6` (172.20.17.199) went
down. The failure was not detected for ~13 hours, and the recovery had
to be done by hand. This section records what went wrong and what was
changed so it cannot happen the same way again.

### Timeline and symptoms

- `cluster-6` left the Ready state at 18:46 UTC; the node object stayed
  `NotReady`/`Unknown` for 13+ hours.
- ~20 pods got stuck:
    - pods whose node died mid-run sat in `Terminating` for up to 34h
      (Kubernetes keeps terminating pods on a dead node until the node
      object is deleted — finalizer cleanup never happens on a hard
      power-loss);
    - replacement pods sat in `ContainerCreating` for 13h. The home-
      assistant replacement is the clearest example: its RWO
      `home-assistant-config` PVC stayed attached to the dead node, so
      the new pod on `cluster-3` could never attach it.
- Affected apps: home-assistant, firecrawl, litellm, open-webui,
  prometheus, kuberhealthy (its pod was on the dead node, so the
  alerting pipeline went silent with it).

### Why the monitoring did not catch it

Three independent failures, each of which would have been enough:

1. **No Kubehealthy node/Proxmox checks existed.** The E2E checks
   (jellyfin, qbittorrent) were passing — those apps had been
   rescheduled to healthy nodes and kept working.
2. **The kuberhealthy pod was on the dead node** (single replica).
   Even the `KubehealthyFailedCheck` alerts it had been emitting for
   the affected checks were no longer being processed.
3. **The alertmanager was crash-looping since day one.** The ntfy
   webhook config contained a `header_params` field, which
   Alertmanager 0.35 does not accept in `webhook_configs`; the
   container crash-looped on every load, so no alert was ever
   delivered to ntfy. (Fixed by removing the field.)

### Recovery procedure (what was done by hand)

1. `kubectl delete node cluster-6` — clears the stuck `Terminating`
   pods and lets replacements schedule.
2. Delete the stale `VolumeAttachment` objects for the dead node
   (`kubectl get volumeattachments | grep cluster-6`) — the Truenas
   csi-attacher does not always reprocess them after node deletion,
   and they keep the RWO PVCs pinned to the dead node.
3. Pods rescheduled and the PVCs attached on healthy nodes.

### What was changed

- `prometheus/app/helmrelease.yaml`: removed the invalid
  `header_params` from the ntfy webhook (alertmanager crash-loop).
- `kuberhealthy/app/helmrelease.yaml`: `replicas: 1` → `2` (alerting
  pipeline survives a single node death; leader election makes it
  safe, chart's default anti-affinity spreads the replicas).
- New Kubehealthy checks: `nodes-ready`, `pods-not-stuck`,
  `proxmox-hosts-up`, `e2e-home-assistant` — see
  [`../kuberhealthy/README.md`](../kuberhealthy/README.md).
