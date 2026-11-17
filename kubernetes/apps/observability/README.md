# Observability — minimal Prometheus + Alertmanager

A **minimal** Prometheus + Alertmanager stack that scrapes Kubehealthy metrics
and fires alerts when a synthetic check fails. This is the alerting backend for
the `kuberhealthy` app (see
[`kubernetes/apps/kuberhealthy/README.md`](../kuberhealthy/README.md)).

## What it does

- **Prometheus** scrapes the `kuberhealthy_check` metric from the Kubehealthy
  service via a static scrape config (`extraScrapeConfigs`).
- **Alert rule** `HealthCheckFailed` fires when `kuberhealthy_check == 0 for 5m`.
- **Alertmanager** receives the alert from Prometheus and routes it to a
  `blackhole` receiver (recorded + visible in the Alertmanager UI, no external
  notification).

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

## Wiring a real notification receiver

The default route sends alerts to a `blackhole` receiver (no external
notification). To page on a failing check, replace the `alertmanager.config`
in [`prometheus/app/helmrelease.yaml`](prometheus/app/helmrelease.yaml) with a
real receiver, e.g. an n8n webhook:

```yaml
route:
    group_by: ["alertname"]
    receiver: "n8n"
receivers:
    - name: "n8n"
      webhook_configs:
          - url: http://n8n.n8n.svc.cluster.local/webhook/kuberhealthy
```

Other common receivers: `email_configs`, `opsgem_configs`, `pagerduty_configs`,
`wechat_configs`, etc. See the
[Alertmanager docs](https://prometheus.io/docs/alerting/latest/configuration/).
