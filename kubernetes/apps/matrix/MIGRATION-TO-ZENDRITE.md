# MIGRATION-TO-ZENDRITE.md — Dendrite → Zendrite (DRAFT)

**Status:** Manifests written (this PR) — ready for cutover execution.
**Prerequisite resolved:** the homeserver databases now run on the
consolidated **PostgreSQL 18** instance at `172.20.17.150:5432` (docker-compose
on the TrueNAS host), which satisfies Zendrite's PG 17+ requirement.

## Background

The Matrix homeserver in `kubernetes/apps/matrix/` runs the Dendrite monolith
(image `matrixdotorg/dendrite-monolith:v0.15.2`) in the `matrix` namespace on
the Talos cluster:

- **Deployment** `dendrite` — 1 replica, `Recreate` strategy (RWO iSCSI PVC),
  requests 250m/512Mi, limits 2 CPU/2Gi. Slow first boot: the monolith
  rebuilds its in-memory JetStream from Postgres (~5.4GB of room/event state)
  before the API binds — the startupProbe budget (600 × 5s) is deliberately
  generous.
- **Config**: k8s Secrets `dendrite-config` (`dendrite.yaml`,
  `registration.yaml`) and `dendrite-key` (`matrix_key.pem`); source of truth
  in the repo is `app/matrix.sops.yaml` (sops/age-encrypted).
- **Media**: iSCSI PVC `dendrite-media` (5Gi, `truenas-iscsi`), mounted at
  `/var/dendrite/media`.
- **Bridge**: `mautrix-whatsapp` in the same namespace (own PVC
  `mautrix-whatsapp-data`).
- **Routes**: HTTPRoutes `matrix` (`matrix.garage.neo-tix.com`) and
  `matrix-well-known` (`neo-tix.com`), both → `svc dendrite:8008`.
- **Flux**: `ks.yaml` healthChecks track Deployment `dendrite` and
  `mautrix-whatsapp`.

## Database consolidation (DONE)

Part of the estate-wide database consolidation
(`migration/database-consolidation/README.md`): six k3s Postgres instances
converged into a single **PostgreSQL 18** docker-compose service on the
TrueNAS host at **`172.20.17.150:5432`**.

- All 10 Dendrite connection strings in the `dendrite-config` secret were
  repointed from `172.20.0.129:5432` (k3s PG12) to `172.20.17.150:5432`
  (commit `5264f42`), with the `dendrite` role password rotated to match the
  consolidated `roles.sql`. **Verified live**: all 10 strings point at
  `172.20.17.150:5432`, and the `dendrite` pod is Running/Ready.
- The `mautrix-whatsapp` bridge DB URI in its PVC `config.yaml` was likewise
  repointed to `172.20.17.150:5432/whatsapp`. **Verified live** in the running
  pod.
- Dendrite databases migrated (from `manifest.tsv`, sizes at dump time):
  `dendrite_roomserver` (3215M), `dendrite_syncapi` (1750M),
  `dendrite_keyserver` (383M), `dendrite_federationapi` (145M),
  `dendrite_userapi_accounts` (46M), `dendrite_mediaapi` (14M),
  `dendrite_userapi_devices` (8M), `dendrite_appservice` (8M),
  `dendrite_relayapi` (8M), plus `whatsapp` (33M).
- **Orphan database**: `dendrite_naffka` (8M) was migrated too, but is
  **not referenced by the live config** — a leftover from a Naffka
  (NATS-JetStream-on-Postgres) experiment. Safe to ignore for the migration.

## Key Findings

### 1. The live config is already a superset of the Zendrite schema

The running `dendrite.yaml` (from the `dendrite-config` secret) is `version: 2`
with top-level keys:

```
version, global, app_service_api, client_api, edu_server, federation_api,
key_server, media_api, mscs, room_server, sync_api, user_api, tracing,
logging, relay_api
```

The Zendrite config struct (`setup/config/config.go`) accepts **all** of these
except `edu_server`. Go's yaml decoder ignores unknown fields by default, so
`edu_server` is harmlessly dropped. **No config restructuring is needed** —
the existing file is directly readable by Zendrite.

### 2. The live config is NOT yet safe to hand to Zendrite as-is

- **Empty-room purge**: `room_server.auto_purge_empty_rooms` is unset in the
  live config, so Zendrite would apply its production default
  `on_all_forgotten` — rooms whose local users have forgotten are purged on
  first start. For a data-neutral cutover we must set
  `room_server: { auto_purge_empty_rooms: never }` (verified in
  `setup/config/config_roomserver.go`: tri-state
  `never` / `on_empty` / `on_all_forgotten`).
- **Database host**: already done — all 10 connection strings point at the
  consolidated PG18 (`172.20.17.150:5432`), verified live. No further DB
  change is needed for the Zendrite cutover.
- **JetStream**: `jetstream.in_memory: true` is accepted by Zendrite —
  RAM-backed streams, rebuilt from Postgres on every start (exactly the
  current Dendrite behavior). No migration of NATS data is required.
  `topic_prefix` may change to `Zendrite` (streams are rebuilt from the DB,
  so a fresh prefix is safe).
- Legacy sections (`edu_server`, `key_server`, `relay_api`,
  `internal_api` blocks, `federation_certificates`, `proxy_outbound`,
  `tracing.jaeger`) are all tolerated by Zendrite's lenient parsing and can
  stay.

### 3. The mautrix-whatsapp bridge has one hard dependency left on the old stack

From the live bridge `config.yaml` (in its PVC):

- `database.uri` → already on PG18 (`172.20.17.150:5432/whatsapp`), verified.
- `homeserver.address: http://dendrite.matrix.svc.cluster.local:8008` — must
  become `http://zendrite.matrix.svc.cluster.local:8008` after the cutover.
  This is persistent in the PVC, so it is a manual edit at cutover time
  (`kubectl exec`/`cp` into the bridge PVC), not a manifest change.

### 4. Media store is root-owned; Zendrite runs as uid 1000

The media PVC `dendrite-media` was written by Dendrite running as **root
(uid 0)** — the files are owned `0:0` with mode `drwxr-x---`. Zendrite runs as
**uid 1000**, so it cannot read or write the store as-is. The
`deployment-zendrite.yaml` adds a `chown-media` initContainer (runs as root,
`chown -R 1000:1000 /var/dendrite/media`) that runs once at pod start; it is
idempotent (after the first run the files are already `1000:1000`). The media
mount path stays `/var/dendrite/media` (matches the config's
`media_api.base_path`; least change).

### 5. Official Zendrite reference facts

- **Upstream**: `codefloe.com/pat-s/zendrite` (pat-s fork of Dendrite); docs at
  `zendrite.pat-s.me`.
- **Image**: `pats22/zendrite` on Docker Hub — latest release **3.9.1**
  (2026-11-12).
- **Container**: runs as uid 1000; config directory `/etc/zendrite`
  (default config file `zendrite.yaml`; it falls back to `dendrite.yaml`
  with a warning — so the existing secret key name keeps working); data
  directory `/var/lib/zendrite`.
- **Health endpoint**: `GET /_matrix/client/versions` (Dockerfile
  HEALTHCHECK) — an HTTP probe is possible, unlike the current TCP probe.
- **PostgreSQL**: 17+ required — satisfied by the consolidated PG18. Schema
  auto-migrates on first start (`dendrite_version` → `zendrite_version`
  tables).
- **Resources**: docs recommend a minimum of 1GB RAM; 2–4 CPU / 8GB for
  comfortable federated use. Current limits are 2 CPU/2Gi — a bump is
  recommended.

## Migration Plan

**Phase 0 — Prerequisite (DONE):** consolidated PG18 at `172.20.17.150:5432`
with all Dendrite databases and the `whatsapp` bridge DB; both the
`dendrite-config` secret and the bridge PVC `config.yaml` already repointed
(verified live, both pods Running/Ready).

**Phase 1 — Manifests (this repo):**

1. New `zendrite.yaml` in `matrix.sops.yaml`:
    - add `room_server.auto_purge_empty_rooms: never`
    - `jetstream.topic_prefix: Zendrite` (optional; streams rebuild from DB)
    - keep `in_memory: true`, keep `media_api.base_path: /var/dendrite/media`,
      keep the PG18 connection strings as-is
2. New `deployment-zendrite.yaml` (image `pats22/zendrite:3.9.1`, same
   mounts, same PVC, bumped resources; HTTP startupProbe on
   `/_matrix/client/versions`), `service-zendrite.yaml`, and updated
   `httproute.yaml` backendRefs (`dendrite` → `zendrite`).
3. Rename secrets `dendrite-config` → `zendrite-config`,
   `dendrite-key` → `zendrite-key` (sops-encrypted in `matrix.sops.yaml`);
   the `dendrite.yaml` key inside the secret can keep its name (the binary
   falls back to it).
4. Update `ks.yaml` healthChecks (Deployment `zendrite`),
   `kustomization.yaml` resources, and Flux `path` references.
5. Keep the PVC object name `dendrite-media` (only the consumer changes —
   no data movement; RWO LUN detach/attach is handled by the Recreate
   strategy).

**Phase 2 — Cutover (cluster, ~10 min + first-boot time):**

1. Apply Zendrite manifests; Flux prunes the Dendrite Deployment.
2. Watch the Zendrite pod through its first boot (DB schema migration +
   JetStream rebuild — expect the same slow startup as today; the startup
   probe budget covers it).
3. Verify: `/_matrix/client/versions`, login with the existing account,
   send a message, check an old room, check media download (PVC reuse).
4. **Bridge**: edit `config.yaml` in the mautrix PVC
   (`homeserver.address` → `http://zendrite.matrix.svc.cluster.local:8008`)
   and restart the bridge pod.
5. Verify the bridge connects (portal rooms, status notices).

**Phase 3 — Cleanup:**

- Remove Dendrite manifests/secret keys from the repo (git history is the
  rollback source of truth).
- Optionally rename the PVC object `dendrite-media` → `zendrite-media`
  (metadata-only, no data movement) — separate PR, low priority.

## Decisions

| #   | Item                   | Decision                                                                               |
| --- | ---------------------- | -------------------------------------------------------------------------------------- |
| 1   | JetStream              | keep `in_memory: true` (matches today; streams rebuild from the DB on every start)     |
| 2   | Resources              | bumped to requests 500m/1Gi, limits 2 CPU/4Gi                                          |
| 3   | Media mount path       | keep `/var/dendrite/media` (matches `media_api.base_path`; least change)               |
| 4   | Image pinning          | `pats22/zendrite:3.9.1` (tag pin, matching the repo's tag-pinning practice)            |
| 5   | Secret/manifest naming | full rename to `zendrite-*` (deployment, service, secrets, sops keys)                  |
| 6   | Orphan DB              | `dendrite_naffka` (8M, unused by the live config) — drop after the cutover is verified |

## Rollback

The cutover is a hard switch (both pods would want the same RWO iSCSI LUN, so
no blue/green overlap). Rollback = re-apply the Dendrite Deployment + Service
from git history (the PVC is untouched); the bridge `config.yaml` edit is
reverted the same way. The Zendrite first-boot DB migration is additive
(`dendrite_version` tables are kept), and Dendrite's minimum supported
Postgres is 11 — so rolling back to Dendrite against the same PG18 data is
expected to work, but has not been tested.
