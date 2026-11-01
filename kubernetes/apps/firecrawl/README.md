# Firecrawl

Self-hosted [Firecrawl](https://firecrawl.dev) — the web scraping / search
API used by AI agents. Exposed at `firecrawl.garage.neo-tix.com`.

Based on the upstream
[cluster-install example](https://github.com/firecrawl/firecrawl/tree/v2.11.162/examples/kubernetes/cluster-install),
adapted to this repo's Flux + SOPS conventions.

## Architecture

Firecrawl is a multi-process stack. The API process spawns worker processes
in the Docker Compose world; on Kubernetes they run as separate deployments
sharing the same `ghcr.io/firecrawl/firecrawl` image, each with its own
entrypoint:

| Deployment           | Replicas | Role                                            | Image                                         |
| -------------------- | -------- | ----------------------------------------------- | --------------------------------------------- |
| `api`                | 1        | HTTP API (scrape/crawl/map/search), port 3002   | `ghcr.io/firecrawl/firecrawl:2.11.162`        |
| `worker`             | 1        | Legacy queue worker, port 3005                  | `ghcr.io/firecrawl/firecrawl:2.11.162`        |
| `nuq-worker`         | 2        | NUQ job-queue workers (consume Postgres jobs)   | `ghcr.io/firecrawl/firecrawl:2.11.162`        |
| `playwright-service` | 1        | Headless Chromium for JS-heavy pages, port 3000 | `ghcr.io/firecrawl/playwright-service:latest` |
| `nuq-postgres`       | 1        | Postgres job queue (port 5432)                  | `ghcr.io/firecrawl/nuq-postgres:latest`       |
| `redis`              | 1        | Rate limiting + cache (port 6379)               | `redis:alpine`                                |

- **No RabbitMQ** on the K8s path — the job queue runs on Postgres
  (`NUQ_DATABASE_URL`), unlike the Docker Compose path.
- The three `firecrawl` node deployments all run the same image; only the
  `args` (entrypoint) and `FLY_PROCESS_GROUP` differ.

### Database decision (deviation from the no-in-cluster-databases rule)

This cluster keeps persistent user databases off-cluster (see the litellm /
forgejo / immich learnings in `AGENTS.md`). Firecrawl's `nuq-postgres` is an
**exception**: it is the **job queue** — it stores in-flight scrape/crawl
job state, not user data. It is run on an **ephemeral `emptyDir`** (matching
the upstream cluster-install example), so a pod restart drops in-flight jobs
but no user data is lost. This is the same class of transient state as the
in-cluster `redis` and the Compose path's RabbitMQ. If a persistent,
user-data database is ever added to Firecrawl (e.g. Supabase-backed auth),
it must be moved off-cluster per the standing rule.

## Configuration

- **ConfigMap `firecrawl-config`** — non-secret env: `REDIS_URL`,
  `PLAYWRIGHT_MICCURRENT_SERVICE_URL`, `USE_DB_AUTHENTICATION=false`,
  concurrency knobs (`CRAWL_CONCURRENT_REQUESTS`, `MAX_CONCURRENT_JOBS`,
  `BROWSER_POOL_SIZE`) tuned down from upstream defaults for a home cluster.
- **Secret `firecrawl`** (SOPS-encrypted) — `POSTGRES_PASSWORD`,
  `BULL_AUTH_KEY` (queue admin UI gate), and `NUQ_DATABASE_URL` (the DSN,
  which embeds the password, so it lives in the secret not the ConfigMap).

### Authentication

`USE_DB_AUTHENTICATION=false` — self-hosted Firecrawl has **no API-key auth**
(Supabase-backed auth is not available self-hosted). Requests need no
`Authorization` header. Public traffic is therefore gated by **Authelia 2FA**
via the catch-all `two_factor` rule (Firecrawl has no app-level login, so it
is **not** in the Authelia bypass whitelist). LAN (`172.20.0.0/16`) and
headscale (`100.64.0.0/10`) sources bypass Authelia as usual.

## Using the API

```bash
# Scrape a page to markdown
curl -X POST https://firecrawl.garage.neo-tix.com/v2/scrape \
  -H 'Content-Type: application/json' \
  -d '{"url": "https://example.com"}'

# Web search (uses Google by default; see SearXNG note below)
curl -X POST https://firecrawl.garage.neo-tix.com/v2/search \
  -H 'Content-Type: application/json' \
  -d '{"query": "talos linux"}'
```

From inside the cluster, agents can call the service directly:
`http://api.firecrawl.svc.cluster.local:3002`.

## Pitfalls

- **Image tags.** Upstream only publishes a **version tag for the API image**
  (`2.11.162`); `playwright-service` and `nuq-postgres` publish only
  `latest` / `linux-amd64` / sha tags (no version tags). Those two are pinned
  to `latest` (matching the upstream cluster-install example) — Renovate
  tracks them by digest.
- **The firecrawl node image runs as root** (no `USER` directive), so the
  `api` / `worker` / `nuq-worker` pods do not set the restricted
  `securityContext` (`runAsNonRoot` would break startup). The
  `nuq-postgres` (postgres:999), `redis` (redis:997), and
  `playwright-service` (uid 1000) pods do set it.
- **`/search` uses Google by default.** To point it at the in-cluster
  SearXNG instead (no external calls), set `SEARXNG_ENDPOINT` in the
  ConfigMap **and** enable the JSON format on the SearXNG app (it currently
  runs with the default config, JSON format off). Not wired up here.
- **LLM features are off.** `OPENAI_API_KEY` is not set, so `/extract` and
  other LLM-backed formats are unavailable. Add the key to the secret to
  enable them.
- **Queue state is ephemeral.** Restarting `nuq-postgres` drops in-flight
  jobs (by design, see the database decision above).
- **Resource sizing** is tuned for a home cluster: `nuq-worker` runs 1
  replica (upstream runs 5), and all requests are right-sized down (total
  ≈ 5.3 Gi memory, ≈ 2.2 CPU) so the stack schedules on the worker nodes
  (cluster-3 / cluster-4).
