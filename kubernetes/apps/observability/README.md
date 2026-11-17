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
  topic; the `X-Title` header sets the notification title to the alert name.

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
resolved alert. The `X-Title` header sets the notification title to the
alert name; the JSON body is the full Alertmanager payload.

To change the receiver, edit the `alertmanager.config` in
[`prometheus/app/helmrelease.yaml`](prometheus/app/helmrelease.yaml).
Other common receivers: `email_configs`, `opsgem_configs`,
`pagerduty_configs`, `wechat_configs`, etc. See the
[Alertmanager docs](https://prometheus.io/docs/alerting/latest/configuration/).
