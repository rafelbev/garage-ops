# kritika

AI pull-request reviewer, installed via the [home-operations/kritika](https://github.com/home-operations/kritika) OCI Helm chart (`oci://ghcr.io/home-operations/charts/kritika`, pinned to `0.0.121`). See [issue #573](https://github.com/rafelbev/garage-ops/issues/573) for the full plan.

## Architecture

- **kritika serve**: one-replica Deployment in this namespace. It serves the webhooks, the dashboard, the job queue and creates runner Jobs (one pod per review).
- **Database**: external Postgres on Truenas (`172.20.17.150:5432`), per the standing decision that databases are not run in the cluster. Postgres 18 with the `vector` and `vchord` extensions (`vchord` in `shared_preload_libraries`). Two non-superuser roles: `kritika_owner` (owns the `kritika` database) and `kritika_app`.
- **LLM**: the LiteLLM gateway (`litellm.litellm.svc.cluster.local:4000/v1`), configured as an `openai`-type provider. The gateway must be running with a tool-calling model for reviews to work; `config.review.model` names the model as `litellm/<model>`.
- **Ingress**: Gateway API `HTTPRoute` for `kritika.garage.neo-tix.com` to the chart's Service (the `envoy-external` Gateway in `network`). cert-manager handles the certificate.
- **NetworkPolicy**: the chart's policies stay on. The built-in `networkPolicy.postgres` values only support pod selectors, so egress to the external database IP is added via `networkPolicy.extraEgress` (`ipBlock 172.20.17.150/32` on port 5432, service pods only; runner pods never reach the database).

## Secrets

| Secret                         | Key                         | Purpose                                       |
| ------------------------------ | --------------------------- | --------------------------------------------- |
| `kritika-postgres-credentials` | `uri`                       | Owner connection string (`kritika_owner`)     |
| `kritika-postgres-app`         | `uri`                       | Application connection string (`kritika_app`) |
| `kritika-credentials`          | `ADMIN_PASSWORD`            | Dashboard admin password                      |
|                                | `LITELLM_API_KEY`           | LiteLLM master key                            |
|                                | `GITHUB_APP_PRIVATE_KEY`    | GitHub App private key (PEM)                  |
|                                | `GITHUB_APP_WEBHOOK_SECRET` | GitHub App webhook secret                     |

The GitHub App itself is registered in GitHub's Developer settings (not in this repo): webhook URL `https://kritika.garage.neo-tix.com/hooks/github`, permissions per issue #573, installed on the `rafelbev` account.

## Configuration

All values live in `kritika/app/helmrelease.yaml`:

- `config.webUrl: https://kritika.garage.neo-tix.com` — must match the HTTPRoute host.
- `config.apps.github.clientId` + `GITHUB_APP_PRIVATE_KEY` — the registered GitHub App's identity.
- `config.apps.github.accounts: [rafelbev]` — the GitHub account kritika acts under.
- `config.providers.litellm` — OpenAI-compatible provider pointing at the LiteLLM gateway.
- `config.review.model` — the model used for reviews, `<provider>/<model>`.

## Pitfalls

- **Postgres 18 is required.** kritika verifies the version, extensions, roles and grants at startup and refuses to start otherwise. The database must be prepared before the release can become ready (see issue #573 for the preparation steps).
- **`vchord` must be in `shared_preload_libraries`** on the Truenas Postgres and the server must have been restarted after the change.
- **Neither database role may be a superuser**; `kritika_app` must not have `BYPASSRLS` and must not own tables. kritika checks this at startup.
- **The LiteLLM gateway must be up** (it was scaled to 0 at install time) and must serve a tool-calling model for `config.review.model` before reviews work.
- **Runner sandbox**: no RuntimeClass (gVisor/Kata) is configured on this cluster. Runner pods run unsandboxed; the NetworkPolicy confines their egress to the gateway port, DNS and the database. Documented follow-up, not a blocker.

## Verification

1. `flux get hs -n kritika` — the HelmRelease goes ready.
2. `kubectl -n kritika get pods` — the serve pod passes readiness.
3. Sign in at `https://kritika.garage.neo-tix.com` as `admin` (password in `kritika-credentials`).
4. Enable the account and repository in the dashboard, then test with a PR.
