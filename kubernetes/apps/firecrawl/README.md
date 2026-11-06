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

| Deployment            | Replicas | Role                                                      | Image                                         |
| --------------------- | -------- | --------------------------------------------------------- | --------------------------------------------- |
| `api`                 | 1        | HTTP API (scrape/crawl/map/search), port 3002             | `ghcr.io/firecrawl/firecrawl:2.11.162`        |
| `worker`              | 1        | Legacy queue worker, port 3005                            | `ghcr.io/firecrawl/firecrawl:2.11.162`        |
| `extract-worker`      | 1        | Consumes the RabbitMQ extract + webhook queues, port 3004 | `ghcr.io/firecrawl/firecrawl:2.11.162`        |
| `nuq-worker`          | 1        | NUQ job-queue workers (consume scrape/crawl jobs)         | `ghcr.io/firecrawl/firecrawl:2.11.162`        |
| `nuq-prefetch-worker` | 1        | Claims queued jobs from Postgres, republishes to RabbitMQ | `ghcr.io/firecrawl/firecrawl:2.11.162`        |
| `playwright-service`  | 1        | Headless Chromium for JS-heavy pages, port 3000           | `ghcr.io/firecrawl/playwright-service:latest` |
| `nuq-postgres`        | 1        | Postgres job queue (port 5432)                            | `ghcr.io/firecrawl/nuq-postgres:latest`       |

- **Redis is out-of-cluster.** Firecrawl's rate limiting / cache now uses the
  shared out-of-cluster Redis at `redis.intranet.neo-tix.com` (database index
  `2`), configured via `REDIS_URL` / `REDIS_RATE_LIMIT_URL` in the SOPS secret.
  See the "Redis" section below and `docs/redis.md` for the authoritative
  per-app database-index allocation.

- **RabbitMQ is the NUQ job-queue transport.** The NUQ job queue is backed
  by Postgres (`NUQ_DATABASE_URL`) for durability, but `NUQ_RABBITMQ_URL`
  turns it into a pull model: `nuq-prefetch-worker` polls Postgres for
  queued jobs, marks them `active`, and republishes them onto RabbitMQ;
  `nuq-worker` then consumes them from RabbitMQ (and — with
  `NUQ_RABBITMQ_URL` set — no longer polls Postgres directly). The legacy
  `/v2/extract` and webhook queues also use RabbitMQ.
- The five `firecrawl` node deployments all run the same image; only the
  `args` (entrypoint) and `FLY_PROCESS_GROUP` differ.

### Database decision (deviation from the no-in-cluster-databases rule)

This cluster keeps persistent user databases off-cluster (see the litellm /
forgejo / immich learnings in `AGENTS.md`). Firecrawl's `nuq-postgres` is an
**exception**: it is the **job queue** — it stores in-flight scrape/crawl
job state, not user data. It is run on an **ephemeral `emptyDir`** (matching
the upstream cluster-install example), so a pod restart drops in-flight jobs
but no user data is lost. This is the same class of transient state as the
out-of-cluster Redis cache and the Compose path's RabbitMQ. If a persistent,
user-data database is ever added to Firecrawl (e.g. Supabase-backed auth),
it must be moved off-cluster per the standing rule.

### Redis (out-of-cluster)

Firecrawl's rate limiting / cache uses the shared out-of-cluster Redis at
`redis.intranet.neo-tix.com:6379` — the same instance all cluster apps now use
(see `AGENTS.md` for the per-app database-index allocation). Firecrawl takes
**database index `2`** (db `0` is immich's, db `1` is penpot's), so its keys
never collide with the other apps. The connection URLs live in the SOPS secret
as `REDIS_URL` and `REDIS_RATE_LIMIT_URL` (both
`redis://:…@redis.intranet.neo-tix.com:6379/2`);
they are full connection strings because Firecrawl reads a single URL and does
not split host/port/password, so the shared Redis password travels in the URL.
The old in-cluster `redis` deployment / service / PVC were removed. The data
is transient (rate-limit counters + cache), so dropping the in-cluster
instance loses nothing.

## Configuration

- **ConfigMap `firecrawl-config`** — non-secret env:
  `PLAYWRIGHT_MICROSERVICE_URL`, `USE_DB_AUTHENTICATION=false`,
  concurrency knobs (`CRAWL_CONCURRENT_REQUESTS`, `MAX_CONCURRENT_JOBS`,
  `BROWSER_POOL_SIZE`) tuned down from upstream defaults for a home cluster,
  and the LLM backend wiring: `OPENAI_BASE_URL` (the self-hosted LiteLLM
  proxy), `MODEL_NAME` (reasoning LLM) and `MODEL_EMBEDDING_NAME`
  (embedding model behind the semantic ranker).
- **Secret `firecrawl`** (SOPS-encrypted) — `POSTGRES_PASSWORD`,
  `BULL_AUTH_KEY` (queue admin UI gate), `NUQ_DATABASE_URL` (the DSN, which
  embeds the password, so it lives in the secret not the ConfigMap),
  `NUQ_RABBITMQ_URL` (RabbitMQ DSN for the NUQ job queue, legacy extract
  and webhook queues), `OPENAI_API_KEY` (a dedicated LiteLLM key
  Firecrawl uses to call the proxy, so its traffic is auditable/revocable
  on its own), and `REDIS_URL` / `REDIS_RATE_LIMIT_URL` (the full
  connection URLs to the shared out-of-cluster Redis, db index `2` —
  see the "Redis" section above).

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
  `nuq-postgres` (postgres:999) and `playwright-service` (uid 1000)
  pods do set it.
- **`/search` uses Google by default.** To point it at the in-cluster
  SearXNG instead (no external calls), set `SEARXNG_ENDPOINT` in the
  ConfigMap **and** enable the JSON format on the SearXNG app (it currently
  runs with the default config, JSON format off). Not wired up here.
- **LLM features are on via LiteLLM.** `OPENAI_API_KEY` (in the secret),
  `OPENAI_BASE_URL` (in the ConfigMap, `https://litellm.garage.neo-tix.com/v1`),
  `MODEL_NAME` (`garage/qwen3.8:27B`) and `MODEL_EMBEDDING_NAME`
  (`garage/granite-embedding`) point Firecrawl's LLM-backed features —
  reasoning (`/extract`, LLM markdown), embeddings and the semantic
  reranking of search/crawl results — at the self-hosted LiteLLM proxy.
  Firecrawl's calls default to `gpt-4o-mini` / `text-embedding-3-small`, so
  both vars override those with models LiteLLM actually serves (without
  them, every LLM/embedding call fails with "no healthy deployments").
  The key is a dedicated per-service LiteLLM key (not the proxy master
  key). If LiteLLM is unavailable, LLM-backed formats fail (scrape/search
  still work).
- **`/v2/extract` is async and needs the `extract-worker` pod.** The
  endpoint only enqueues the job onto RabbitMQ and returns a job `id`
  (poll `GET /v2/extract/:jobId`); the actual scrape + LLM extraction runs
  in the `extract-worker` deployment. Without that pod, jobs sit in the
  queue forever at `status: "processing"`. The endpoint is deprecated
  upstream — `/v2/scrape` with a `json` format does the same thing inline.
- **The `nuq-prefetch-worker` pod is required when `NUQ_RABBITMQ_URL` is
  set.** The extract path enqueues a scrape job onto the NUQ queue
  (Postgres). With RabbitMQ enabled, `nuq-worker` reads jobs only from
  RabbitMQ, so without the prefetch worker (which republishes queued
  Postgres jobs onto RabbitMQ) every extract fails with
  `SCRAPE_TIMEOUT` ("timed out after waiting in the concurrency limit
  queue") and `nuq.queue_scrape` fills up with stuck `queued` rows.
- **Queue state is ephemeral.** Restarting `nuq-postgres` drops in-flight
  jobs (by design, see the database decision above).
- **Resource sizing** is tuned for a home cluster: `nuq-worker` runs 1
  replica (upstream runs 5), and all requests are right-sized down (total
  ≈ 6.3 Gi memory, ≈ 2.7 CPU) so the stack schedules on the worker nodes
  (cluster-3 / cluster-4).
