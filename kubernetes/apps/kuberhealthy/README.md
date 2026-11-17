# Kubehealthy — end-to-end synthetic monitoring

Deploys [Kubehealthy](https://kuberhealthy.github.io/kuberhealthy/) (v3, `HealthCheck`
CRD) to run **end-to-end synthetic checks** against the `envoy-external`
gateway, and exposes the results as Prometheus metrics.

## What it does

Kubehealthy runs the `HealthCheck` resources defined in
[`kuberhealthy/app/healthchecks.yaml`](kuberhealthy/app/healthchecks.yaml) on a
schedule. Each check performs an HTTPS request against a representative public
host served by the `envoy-external` gateway:

| HealthCheck       | Target                                    | Why                                                       |
| ----------------- | ----------------------------------------- | --------------------------------------------------------- |
| `e2e-jellyfin`    | `https://jellyfin.garage.neo-tix.com/`    | Host that 503'd in the incident that motivated issue #512 |
| `e2e-qbittorrent` | `https://qbittorrent.garage.neo-tix.com/` | The other host that 503'd in that incident                |

A `200` (or a redirect that resolves to `200`) is healthy; any `4xx`/`5xx`
fails the check. A single degraded `envoy-external` replica 503s whatever host
it serves, so **either** check catching a failure is enough to alert.

## How it works

- **Checks**: each `HealthCheck` runs a small `curl` container (`podSpec`) that
  does the HTTPS request. `runInterval: 1m`, `timeout: 30s`.
- **Metrics**: Kubehealthy exposes the `kuberhealthy_check` gauge
  (`1` = pass, `0` = fail) plus `kuberhealthy_check_duration_seconds`,
  `kuberhealthy_check_consecutive_failures`, etc.
- **Alerting**: Prometheus (see the `observability` app) scrapes the metrics
  via a static scrape config and fires the `HealthCheckFailed` alert
  (`kuberhealthy_check == 0 for 5m`) to Alertmanager. See
  [`kubernetes/apps/observability/README.md`](../observability/README.md).

## Why `podSpec` and not the built-in `spec.http` probe?

The latest chart (`kuberhealthy` `1.1.0`) bundles Kubehealthy **v3.0.5**, whose
`HealthCheck` CRD only supports `podSpec` (it has no `spec.http` field). The
built-in `spec.http`/`spec.tcp` probes landed in **v3.1.0**. Once a chart
version bundling v3.1.0+ is published, these checks can be migrated to
`spec.http` (no checker pod required) — the CRD change is additive, so existing
`podSpec` checks keep working.

## Viewing check status

- **Kubehealthy UI**: `kubectl port-forward svc/kuberhealthy -n kuberhealthy 8080:80`
  then open `http://localhost:8080`.
- **Checks**: `kubectl get healthchecks -n kuberhealthy` (columns: `OK`,
  `RunInterval`, `ErrorMessage`).
- **Metrics**: see the `observability` README for Prometheus access.

## Adding a check

Add a new `HealthCheck` to
[`kuberhealthy/app/healthchecks.yaml`](kuberhealthy/app/healthchecks.yaml)
(follow the existing pattern) — no other changes needed. Push to git; Flux
reconciles it.
