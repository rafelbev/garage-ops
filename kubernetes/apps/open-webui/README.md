# Open WebUI

Self-hosted [Open WebUI](https://github.com/open-webui/open-webui) — a chat UI
for LLM backends. Exposed at `chat.garage.neo-tix.com`. Deployed from the
upstream [open-webui Helm chart](https://open-webui.github.io/helm-charts/)
via Flux.

## Architecture

- **StatefulSet `open-webui`** (1 replica) — the `ghcr.io/open-webui/open-webui`
  image, with an `truenas-iscsi` RWO config PVC (`8Gi`) for its SQLite database
  and uploads.
- **LLM backend is external** — the OpenAI-compatible endpoint is the
  self-hosted LiteLLM proxy (`https://litellm.garage.neo-tix.com/v1`); the API
  key lives in the SOPS secret `open-webui` (key `openai-api-key`).
- **Redis is out-of-cluster.** The WebSocket manager uses the shared
  out-of-cluster Redis at `redis.intranet.neo-tix.com` (see below), not the
  Redis the chart bundles.

## Redis (out-of-cluster)

Open WebUI uses Redis as its WebSocket manager (task queues, realtime
multi-client updates). Per the cluster-wide rule of one logical database per
app (see `docs/redis.md` for the authoritative allocation table), Open WebUI
takes **database index `3`** (db `0` is immich's, db `1` is penpot's, db `2` is
firecrawl's).

The chart's bundled Redis is disabled (`websocket.redis.enabled: false`), and
the connection URL is sourced from the SOPS secret `open-webui` (key
`redis-url`, value `redis://:***@redis.intranet.neo-tix.com:6379/3`) via
`websocket.existingSecret` / `websocket.existingSecretKey`. The full URL
travels in the secret because Open WebUI reads a single `redis://user:***@host:port/db`
string for both `REDIS_URL` and `WEBSOCKET_REDIS_URL`.

> Note: `websocket.enabled` must stay `true` for the external Redis to be
> used — with it `false`, Open WebUI runs with no WebSocket support and never
> connects to Redis at all.

## Configuration

- **HelmRelease `open-webui`** — chart `open-webui` `18.4.0`, image
  `ghcr.io/open-webui/open-webui:v0.13.4`. Websocket wired to the shared
  out-of-cluster Redis (see "Redis" above); `persistence` uses `truenas-iscsi`.
- **Secret `open-webui`** (SOPS-encrypted) — `openai-api-key` (the LiteLLM
  proxy key) and `redis-url` (the full connection URL to the shared
  out-of-cluster Redis, db index `3`).
