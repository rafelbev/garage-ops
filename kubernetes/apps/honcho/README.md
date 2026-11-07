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
(`litellm.garage.neo-tix.com/v1`). The `LLM_OPENAI_COMPATIBLE_API_KEY`
is set to the real OpenAI-compatible key in the `honcho-env` SOPS secret
(it was empty on the k3s source and carried over as-is during migration).
The `LLM_EMBEDDING_MODEL` is `garage/granite-embedding`, served by the same
Talos litellm proxy (replacing the original `nomic-ai/nomic-embed-text-v1`).

## Embedding model change (nomic → granite)

The embedding model was switched from `nomic-ai/nomic-embed-text-v1` (1024-dim)
to `garage/granite-embedding` (768-dim), served by the same Talos litellm proxy.
This required:

1. **DB schema migration**: The deployed v3.5.0 image expects the v3.5.0 schema
   (notably `messages.deleted_at`). The DB was at an older alembic revision
   (`e4eba9cfaa6f`), so the v3.5.0 tag's Alembic migrations were applied to
   bring the schema in line. The migration scripts were taken from the v3.5.0
   git tag (not master), to match the deployed image.
2. **Embedding column resize**: The `messages.embedding` and
   `message_embeddings.embedding` columns were resized from `vector(1024)` to
   `vector(768)` to match the new model's output dimension.
3. **Backfill**: All 5,848 existing messages were re-embedded with the new
   model (10,083 embeddings total; some long messages are chunked into
   multiple embeddings).

### Backfill details

The backfill uses the image's `/app/scripts/generate_message_embeddings.py`
script, run inside the honcho pod. Key gotchas:

- **Env var mapping**: The deployed image's `embedding_client` reads
  `settings.EMBEDDING.MODEL_CONFIG` (from `EMBEDDING_MODEL_CONFIG`) and
  `settings.LLM.OPENAI_API_KEY` (from `LLM_OPENAI_API_KEY`), but the pod is
  provisioned with the older `LLM_EMBEDDING_MODEL` /
  `LLM_OPENAI_COMPATIBLE_API_KEY` / `LLM_OPENAI_COMPATIBLE_BASE_URL` names.
  The backfill script maps them:
  `EMBEDDING_MODEL_CONFIG` is set to a JSON with the model, transport, and
  base URL; `LLM_OPENAI_API_KEY` is set to the value of
  `LLM_OPENAI_COMPATIBLE_API_KEY`.
- **Token limit**: The `garage/granite-embedding` backend has a physical batch
  size of 512 tokens per request. The client tokenizes with `cl100k_base`
  (tiktoken fallback, since `garage/granite-embedding` is not a known tiktoken
  model), but the backend uses the granite tokenizer — a variable ~2–3×
  mismatch. So `EMBEDDING_MAX_INPUT_TOKENS` and
  `EMBEDDING_MAX_TOKENS_PER_REQUEST` are set to 100 (client) → ~300 tokens
  (backend), safely under 512.
- **Vector dimensions**: `EMBEDDING_VECTOR_DIMENSIONS=768` is set to match the
  model's output dimension.

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
