# Open Web UI

Self-hosted [Open Web UI](https://github.com/open-webui/open-webui) — a chat UI
for LLM backends. Exposed at `chat.garage.neo-tix.com`. Deployed from the
upstream [open-webui Helm chart](https://open-webui.github.io/helm-charts/)
via Flux.

## Architecture

- **Deployment `open-webui`** (2 replicas) — the
  `ghcr.io/open-webui/open-webui:v0.13.5` image. The app is stateless: all
  durable state lives in PostgreSQL, so the replicas are interchangeable and
  can be scaled freely.
- **PostgreSQL backend** — the database is the consolidated Postgres at
  `172.20.17.150:5432` (database `openwebui`, role `openwebui`). This replaces
  the previous per-replica SQLite database that lived on an iSCSI-mounted
  volume. Moving the DB off the iSCSI volume is the main performance win, and
  it is what makes the 2-replica deployment possible.
- **Vector DB is pgvector** — embeddings are stored in the same Postgres
  database via the `vector` extension (`VECTOR_DB=pgvector`,
  `PGVECTOR_DB_URL` = the same `DATABASE_URL`). This is shared across both
  replicas. The previous ChromaDB (local SQLite under the data dir) cannot be
  shared across replicas, so it was dropped.
- **Shared storage** — a `truenas-nfs` RWX PVC (`10Gi`) holds uploads and the
  model cache. The database no longer lives here.
- **LLM backend is external** — the OpenAI-compatible endpoint is the
  self-hosted LiteLLM proxy (`https://litellm.garage.neo-tix.com/v1`). No API
  key is required; the chart's `openaiApiKey` is left empty so no
  `OPENAI_API_KEY` is set.
- **Redis is out-of-cluster.** The WebSocket manager uses the shared
  out-of-cluster Redis at `redis.intranet.neo-tix.com` (see below), not the
  Redis the chart bundles.

## Redis (out-of-cluster)

Open Web UI uses Redis as its WebSocket manager (task queues, realtime
multi-client updates). Per the cluster-wide rule of one logical database per
app (see `docs/redis.md` for the authoritative allocation table), Open Web UI
takes **database index `3`** (db `0` is immich's, db `1` is penpot's, db `2` is
firecrawl's).

The chart's bundled Redis is disabled (`websocket.redis.enabled: false`), and
the connection URL is sourced from the SOPS secret `open-webui` (key
`redis-url`, value `redis://:***@redis.intranet.neo-tix.com:6379/3`) via
`websocket.existingSecret` / `websocket.existingSecretKey`. The full URL
travels in the secret because Open Web UI reads a single `redis://user:***@host:port/db`
string for both `REDIS_URL` and `WEBSOCKET_REDIS_URL`.

> Note: `websocket.enabled` must stay `true` for the external Redis to be
> used — with it `false`, Open Web UI runs with no WebSocket support and never
> connects to Redis at all.

## PostgreSQL backend

The database was migrated from SQLite to the consolidated Postgres at
`172.20.17.150:5432`. The connection string (including the password) lives in
the SOPS secret `open-webui` under the key **`database-url`**, and is injected
as both `DATABASE_URL` and `PGVECTOR_DB_URL` via `extraEnvVars`. The password
is never committed to git.

The relevant environment variables (all set in `extraEnvVars`):

| Variable                     | Value                                                                                  | Notes                                                                          |
| ---------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `DATABASE_URL`               | `postgresql://openwebui:***@172.20.17.150:5432/openwebui` (from secret `database-url`) | Main database                                                                  |
| `PGVECTOR_DB_URL`            | same as `DATABASE_URL` (from secret `database-url`)                                    | Vector store; defaults to `DATABASE_URL`                                       |
| `VECTOR_DB`                  | `pgvector`                                                                             | Use pgvector, not the default ChromaDB                                         |
| `ENABLE_DB_MIGRATIONS`       | `false`                                                                                | Migrations are run manually (see below); do not let every replica auto-migrate |
| `DATABASE_POOL_SIZE`         | `15`                                                                                   | Connection pool size (per the docs)                                            |
| `DATABASE_POOL_MAX_OVERFLOW` | `20`                                                                                   | Max overflow above the pool size                                               |
| `THREAD_POOL_SIZE`           | `2000`                                                                                 | Thread pool size (per the docs)                                                |

### DB + role setup (run once, as the Postgres superuser)

Open Web UI does **not** create the database or role for you — it only creates
tables and runs Alembic migrations. The database, role, `vector` extension, and
schema grants must be created first, by the superuser:

```sql
-- In the postgres database (as superuser):
CREATE DATABASE openwebui;
CREATE ROLE openwebui LOGIN PASSWORD '<password>';
GRANT ALL PRIVILEGES ON DATABASE openwebui TO openwebui;

-- Connect to the openwebui database (as superuser):
CREATE EXTENSION IF NOT EXISTS vector;
GRANT ALL ON SCHEMA public TO openwebui;
```

The `vector` extension is **non-trusted**, so the `openwebui` role cannot create
it itself. Pre-creating it here means the app's own
`CREATE EXTENSION IF NOT EXISTS vector` (it runs with
`PGVECTOR_CREATE_EXTENSION=true` by default) is a harmless no-op. The
`GRANT ALL ON SCHEMA public` is required because, since Postgres 15, the `public`
schema is no longer writable by non-superusers by default — the role needs
CREATE privilege there to create tables (via Alembic and the pgvector
`document_chunk` table).

### Data migration (SQLite → Postgres)

Open Web UI does **not** migrate the SQLite database for you. Setting
`DATABASE_URL` gives you a fresh PostgreSQL schema; the existing SQLite data is
not copied over. So the migration is a separate, pre-production step:

1. Back up the SQLite DB and the Chroma vector DB (they are in the data dir of
   the running pod).
2. Let Open Web UI create the Postgres schema: run it once against
   `DATABASE_URL` with `ENABLE_DB_MIGRATIONS=true` (or run
   `alembic upgrade head` directly). This applies all 76 Alembic migrations.
3. Copy the SQLite rows into Postgres in foreign-key order. The migration
   script in this repo does this:
   `migration/open-webui-to-postgres/migrate_sqlite_to_pg.py`.

    It skips `migratehistory`/`alembic_version`, inserts tables in topological
    order (parents before children, self-referencing tables inserted in
    multiple passes), skips orphan rows that SQLite tolerated but Postgres
    rejects, and casts JSON columns properly (native values are serialized with
    `json.dumps`).

    ```bash
    python3 migration/open-webui-to-postgres/migrate_sqlite_to_pg.py \
      --sqlite /path/to/webui.db \
      --pg-dsn postgresql://openwebui:***@172.20.17.150:5432/openwebui \
      --dry-run   # drop --dry-run to actually migrate
    ```

    The source DB must be a consistent snapshot (no write in flight). The
    migration was verified against a local Postgres 16: all 54 tables migrated,
    12,534 rows committed, and a 3-row `chat_file` orphan (a `chat_file` row
    referencing a `chat` id that does not exist in SQLite — SQLite does not
    enforce FKs) was skipped and reported.

4. Verify the row counts match between SQLite and Postgres, then cut over.

### Vector DB / embeddings

Setting `VECTOR_DB=pgvector` before the first start means the app creates the
`document_chunk` table and stores embeddings in Postgres. **Existing ChromaDB
embeddings are not migrated** — any RAG/vector-indexed content (e.g. the
`web-search`, `file`, and `memory` collections in the old Chroma store) will
need to be re-indexed, or accepted as lost. This is an open design decision:
re-indexing can be done by re-adding documents to Open Web UI (which re-embeds
them) or by a one-off re-indexing script.

### Cut-over runbook (PVC swap + deploy)

The storage class cannot be changed on an existing PVC, so the old
`truenas-iscsi` PVC must be deleted and a fresh `truenas-nfs` PVC created.
Because the chart's `initContainer` runs `cp -R -n /app/backend/data/*
/tmp/app-data/`, which **fails on an empty data dir**, the new PVC must be
populated _before_ the Deployment is scaled up. The sequence used here:

1. **Back up the data you want to keep** (uploads + model cache; the DB and
   Chroma vector store are dropped). The model cache uses Hugging Face
   symlinked blobs, so `kubectl cp` will skip the symlinks and leave a broken
   cache — capture it as a tar instead, which preserves them:
    ```bash
    # one-shot probe pod mounting the old PVC at /data:
    kubectl exec <pod> -n open-webui -- sh -c "tar -cf /tmp/data.tar -C /data uploads cache"
    kubectl cp <pod>:/tmp/data.tar /tmp/data.tar -n open-webui
    ```
2. **Delete the old PVC**:
    ```bash
    kubectl delete pvc open-webui -n open-webui
    ```
3. **Create the new PVC** to match the chart's spec exactly (the chart
   provisions this same PVC; creating it first lets you populate it before the
   pods start). Use the exact labels the chart renders (`helm template
   open-webui ... --show-only templates/pvc.yaml`) so Flux sees no diff:
    ```yaml
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
        name: open-webui
        namespace: open-webui
        labels:
            helm.sh/chart: open-webui-18.4.0
            app.kubernetes.io/version: "0.13.4"
            app.kubernetes.io/managed-by: Helm
            app.kubernetes.io/name: open-webui
            app.kubernetes.io/instance: open-webui
            app.kubernetes.io/component: open-webui
    spec:
        accessModes: [ReadWriteMany]
        resources:
            requests:
                storage: 10Gi
        storageClassName: truenas-nfs
    ```
4. **Populate the new PVC**: mount it in a probe pod, copy the tar in, and
   extract it (preserves the symlinks).
5. **Push the HelmRelease** (`replicaCount: 2`). Flux deletes the old
   StatefulSet, sees the PVC already exists and matches, and creates the
   Deployment with two replicas.
6. **Verify**: pods are `Ready`, the app connects to Postgres, the UI works,
   and uploads are present.

> Note: if you do not need to preserve uploads or the model cache, you can
> skip steps 1 and 4 and go straight from deleting the old PVC to pushing the
> HelmRelease. The model cache will be rebuilt (re-downloaded) on first use if
> needed.

## Configuration

- **HelmRelease `open-webui`** — chart `open-webui` `18.4.0`, image
  `ghcr.io/open-webui/open-webui:v0.13.5`. Websocket wired to the shared
  out-of-cluster Redis (see "Redis" above). `persistence` uses `truenas-nfs`
  (RWX, 10Gi). `workload.kind: Deployment`, `replicaCount: 2`.
- **Secret `open-webui`** (SOPS-encrypted) — `redis-url` (the full connection
  URL to the shared out-of-cluster Redis, db index `3`), `webui-secret-key`
  (a stable `WEBUI_SECRET_KEY`, see below), and `database-url` (the full
  Postgres connection string, db `openwebui`).

## WEBUI_SECRET_KEY

Open Web UI signs its JWT session tokens (and encrypts some state) with
`WEBUI_SECRET_KEY`. When the env var is unset, the container falls back to
generating a fresh key on every boot and printing
`No WEBUI_SECRET_KEY environment variable set, loading from file.` — which
invalidates existing sessions on each restart. We set it explicitly from the
SOPS secret (`webui-secret-key`) via `extraEnvVars`, so the key is stable and
managed in git. The value is a 32-byte random hex string.

> Note: if the key is ever rotated, all existing sessions are invalidated
> (users re-login); stored passwords are unaffected (they are bcrypt-hashed,
> not keyed by `WEBUI_SECRET_KEY`).

## Pitfalls

- **The `vector` extension is non-trusted.** The `openwebui` role cannot
  `CREATE EXTENSION vector` — it must be pre-created by the superuser (see the
  DB + role setup above). Otherwise the app fails on first boot with a
  permission error.
- **`ENABLE_DB_MIGRATIONS=false` on both replicas.** Do not let both replicas
  run migrations against the shared DB simultaneously — they can conflict.
  When upgrading the app, scale to one replica, run migrations (or let that
  one replica run with `ENABLE_DB_MIGRATIONS=true`), then scale back up.
- **The `vector` extension must exist in the database.** If it was not
  pre-created and `PGVECTOR_CREATE_EXTENSION` is left at its default (`true`),
  the pod will crash-loop. Create it as the superuser, or set
  `PGVECTOR_CREATE_EXTENSION=false` after the superuser creates it.
- **The PVC swap is the risky cutover.** Deleting the old `truenas-iscsi` PVC
  loses all data on it. Copy uploads + cache first, and only delete the old
  PVC after the data is safely stored. There is no backup of the old PVC once
  it is deleted.
- **Vector embeddings are not migrated.** Switching to `pgvector` drops the
  existing ChromaDB embeddings. Re-index any content that relies on them, or
  accept the loss.
- **Postgres pool sizing.** With 2 replicas and the default pool, the
  combined connection count is `2 × (15 + 20)` in the worst case. Make sure the
  Postgres `max_connections` headroom covers this (the consolidated Postgres
  serves multiple apps). The values above (`DATABASE_POOL_SIZE=15`,
  `DATABASE_POOL_MAX_OVERFLOW=20`) follow the Open Web UI docs.
