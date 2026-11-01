# Honcho

Self-hosted AI memory & conversation-management service
([plastic-labs/honcho](https://github.com/plastic-labs/honcho)).

Migrated from the k3s cluster to Talos (PR: migrate-honcho-from-k3s-to-talos).

## Architecture

Honcho is **stateless** — it has no PVC. All of its state (sessions,
messages, collections, documents, embeddings) lives in an external
**Postgres + pgvector** database. The app is a single FastAPI/uvicorn
container on port 8000.

| Dependency   | Location                                          | Notes                                     |
| ------------ | ------------------------------------------------- | ----------------------------------------- |
| Database     | k3s `postgresql16-pgvector`, NodePort 31532       | **cross-cluster** — see below             |
| Redis cache  | k3s `redis`, `172.20.0.139:6379`                  | disabled in practice (in-memory fallback) |
| LLM / embeds | Talos `litellm` (`litellm.garage.neo-tix.com/v1`) | OpenAI-compatible                         |

### Cross-cluster database dependency

The pgvector database is **not** migrated in-cluster (standing decision:
databases are not run in-cluster). It stays on k3s and is exposed to the
LAN via a `NodePort` service (`postgresql-pgvector-external`, port 5432 →
nodePort 31532) in the `postgresql16-pgvector` namespace. The DB is small
(~30 MB) and the NodePort is reachable from Talos (both clusters are on the
`172.20.0.0/16` LAN).

**The k3s `postgresql16-pgvector` namespace (and the node running the
`postgresql-pgvector` pod) must NOT be decommissioned until the database is
separated out** (e.g. moved to TrueNAS or a dedicated Postgres host). Until
then, honcho on Talos depends on k3s staying up for its database.

The NodePort service is applied live on k3s (not in this repo) and is
intentionally not GitOps-managed here.

### Redis cache

The source `CACHE_URL` carried a placeholder password, so the cache was
effectively disabled on k3s (`Cache disabled, using in-memory cache`). On
Talos the `CACHE_URL` is re-pointed to the existing external Redis
(`172.20.0.139:6379`) with the real password. Honcho still reports
`Cache disabled, using in-memory cache` at boot — matching the source
behaviour — so the cache remains an optional acceleration, not a hard
dependency.

### LLM / embeddings

The LLM base URL is re-pointed from the k3s litellm
(`litellm.cloud.neo-tix.com/v1`) to the Talos litellm
(`litellm.garage.neo-tix.com/v1`). The `LLM_OPENAI_COMPATIBLE_API_KEY` is
carried over as-is (empty on the source).

## Image

Pinned to `ghcr.io/plastic-labs/honcho:v3.5.0` (the latest current release).
The container's boot command keeps the source's `uv pip install ...` lines;
they fail harmlessly (`uv` is not in the image) because the image ships
`uvicorn` pre-installed and the app runs from the local `src/main.py`, so
`uvicorn src.main:app` starts directly.

## Verification

- The external DB is reachable from Talos (12 honcho tables present).
- A probe pod running `v3.5.0` with the source command boots, connects to the
  external DB, and serves `/docs` and `/openapi.json` (200).
- `kustomize build` of the app dir renders the Secret, Service, Deployment,
  and HTTPRoute cleanly.
