# Database consolidation: six k3s Postgres instances → one docker-compose Postgres

## Goal

Replace the six separate PostgreSQL instances on the (decommissioning) k3s
cluster with a **single** PostgreSQL instance running as a docker-compose
service on the TrueNAS host (**172.20.17.150**). Every application database
converges into that one instance, one database per source database. Apps on the
Talos cluster (and any that remain on k3s) are then re-pointed from the old
k3s LoadBalancer IPs to **172.20.17.150:5432**.

Benefits:

- One database engine instead of six → less RAM, fewer images, one backup target.
- Frees k3s of its databases, unblocking k3s decommissioning.
- The built image (`postgres:18` + PGDG `postgresql-18-pgvector` + the
  prebuilt `postgresql-18-vchord` deb, see the `Dockerfile` in this
  directory) covers every extension in use (vector, vchord, cube,
  earthdistance, pg_trgm, btree_gin, unaccent, uuid-ossp).

## Source inventory (verified 2026-10-20)

| Source instance         | k3s LB IP    | PG ver | Databases (size)                                                                                          |
| ----------------------- | ------------ | ------ | --------------------------------------------------------------------------------------------------------- |
| `postgresql`            | 172.20.0.121 | 11     | gitea 337M, homeassistant 186M, firefly 16M, authelia 7.7M, wiki 7.6M                                     |
| `postgresql12`          | 172.20.0.129 | 12     | dendrite_* (≈5.4G total), homeassistant 824M, whatsapp 33M, mealie 10M, penpot 9M, planka 9M, mastodon 8M |
| `postgresql14`          | 172.20.0.135 | 14     | lidarr-main 804M, sonarr-main 68M, lidarr-log 37M, sonarr-log 17M, piped 8.4M                             |
| `postgresql16`          | 172.20.0.138 | 16     | litellm 4.1G, penpot 36M, ghostfolio 10M, acmedns 7.7M, n8n 7.4M, honcho 7.4M                             |
| `postgresql16-pgvector` | (internal)   | 16     | postgres 37M (vector) — **owner unknown**                                                                 |
| `immich` (CNPG)         | (internal)   | 16     | immich 571M (vector, cube, earthdistance, pg_trgm, unaccent, uuid-ossp)                                   |

Total ≈ **12 GiB**.

> Source versions verified from the live k3s cluster images (2026-11-02):
> `postgresql` is **PG11** (`bitnamilegacy/postgresql:11.14.0`), not PG14; the
> `immich` CNPG image is PG16 (`cloudnative-pgvecto.rs:16.5`). The newest source
> is therefore PG16 and the oldest is PG11.

## Postgres version compatibility (why PG18)

The consolidated image is **PostgreSQL 18** (`postgres:18` plus the PGDG
`postgresql-18-pgvector` package and the prebuilt `postgresql-18-vchord`
deb, built via the `Dockerfile` in this directory). The plan is to run the
consolidated instance on PG18 — the newest major with full support for every
extension the estate uses, including `vchord` (VectorChord), which is a
"future requirement" extension no current source database uses but the
consolidated instance provisions. This answers the review question of which
target version to pick.

1. **The target must be ≥ the newest source.** The sources run PG11, 12, 14
   and 16 (verified above). The newest is PG16, so the target must be ≥ 16.
2. **Forward-compatible restore.** `pg_dump` custom-format dumps are
   forward-compatible: a dump taken from PG11/12/14/15/16 restores cleanly
   into PG18. `standard_conforming_strings` is `on` (the default since
   PG9.1) on every source, so backslash-escape handling is consistent across
   the restore; `migrate.sh` re-checks this on every source before dumping
   and fixes it if needed (see the cutover runbook). Optionally, install a
   PG18 `pg_dump`/`pg_dumpall` client on a separate machine and point it at
   the source clusters to guarantee a fully PG18-native dump.
3. **No app needs a version newer than PG18** — and none needs a PG18+
   feature either; PG18 is simply high enough that every consuming
   application's supported range is satisfied:

    | App (cluster)             | Min supported PG |
    | ------------------------- | ---------------- |
    | firefly-iii (k3s → Talos) | 9.5              |
    | ghostfolio (k3s → Talos)  | 10               |
    | cryptofolio (k3s → Talos) | 10               |
    | immich (Talos)            | 14 (uses vector) |
    | forgejo/gitea (Talos)     | 11               |
    | litellm (Talos)           | 9.6              |
    | mastodon (k3s)            | 12               |
    | dendrite (Talos)          | 11               |
    | mealie (k3s)              | 11               |
    | planka (k3s)              | 11               |
    | whatsapp/mautrix (Talos)  | 11               |
    | piped (k3s)               | 13               |
    | honcho (Talos)            | 13               |
    | acmedns (k3s)             | 11               |
    | wiki/mediawiki (k3s)      | 12               |
    | penpot (k3s)              | 11               |

    (The `*arr` `postgresql14` DBs are legacy/SQLite-on-Talos and preserved,
    not wired, so they impose no requirement. The Talos `authelia` and `n8n`
    instances no longer use Postgres — file-based user DB and built-in
    SQLite respectively — so their DBs are preserved, not wired.)

4. **Full extension support.** PG18 is the newest major the VectorChord
   project supports: it ships prebuilt `postgresql-18-vchord` debs and a
   `pg18` build feature. PG19 (the current stable) is _not_ yet supported by
   VectorChord — its `pgrx` pin caps at `pg18` — so PG18 is the highest major
   that can provision the complete extension set (`vector`, `vchord`, `cube`,
   `earthdistance`, `pg_trgm`, `btree_gin`, `unaccent`, `uuid-ossp`) cleanly.
   The image bundles the `vector` extension (immich, honcho) via the PGDG
   `postgresql-18-pgvector` package, `vchord` via the prebuilt
   `postgresql-18-vchord` deb, and every contrib module the sources use —
   `cube`, `earthdistance`, `pg_trgm`, `btree_gin`, `unaccent`, `uuid-ossp` —
   so no app is left without an extension it needs. **`vchord` must be
   preloaded** via `shared_preload_libraries = 'vchord'` (set in the
   docker-compose `command`), otherwise `CREATE EXTENSION vchord` fails with
   "vchord must be loaded via shared_preload_libraries" — live-verified in a
   k3s test pod on 2026-11-21.

### Behavioral audit (live-verified 2026-11-21)

All six sources were audited as superuser (37 databases total) for behavioral
changes that could affect a cross-version restore, plus the
`standard_conforming_strings` preflight state:

| Change                                       | Finding (all 6 sources / 37 DBs)                                                                                                                                                                                                                                                                                 |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `standard_conforming_strings` (dump loading) | **`on` on every server, no per-database overrides** — the preflight is already satisfied; `migrate.sh` re-checks before every dump.                                                                                                                                                                              |
| `\'` backslash escapes in SQL strings        | No risk — `standard_conforming_strings = on` everywhere and no `\'` in any migration script (`migrate.sh` uses `E''` escapes only).                                                                                                                                                                              |
| `json_array()` returns `[]` not `NULL`       | No risk — no user SQL objects reference `json_array` in any database.                                                                                                                                                                                                                                            |
| `postgres_fdw` + `READ ONLY` transactions    | No risk — `postgres_fdw` is not installed in any database.                                                                                                                                                                                                                                                       |
| `COPY FROM ... WHERE` disallowed             | No risk — no COPY-based ETL; the migration is `pg_dump`/`pg_restore` only.                                                                                                                                                                                                                                       |
| FTS / `pg_trgm` locale-provider results      | No risk — **every database uses the libc locale provider** (`en_US.UTF-8` on the five bitnami/pgvector sources, `C` on immich), so results are identical after restore. No stored `tsvector` columns anywhere; the only `pg_trgm` indexes in the estate are immich's seven trigram indexes on its `C`-locale DB. |
| `fuzzystrmatch` non-ASCII behavior           | No risk — extension not installed anywhere; zero user fuzzy functions.                                                                                                                                                                                                                                           |
| Text-search stemmer changes                  | No risk — no full-text search usage in any database.                                                                                                                                                                                                                                                             |

Extensions actually in use across all sources: `plpgsql`, `vector` (immich),
`pg_trgm` (immich), `btree_gin`, `uuid-ossp` (penpot), `unaccent`, `cube`,
`earthdistance` (immich) — all covered by the consolidated image (see
`initdb/01-init-extensions.sql`).

Additional pre-dump checks (same audit pass):

| Check                          | Finding (all 6 sources)                                                                                                                                                                                                                                                 |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MULE_INTERNAL` encoding       | None — every one of the 37 databases is `UTF8`.                                                                                                                                                                                                                         |
| Custom shared libraries        | `pgaudit` preloaded on the four bitnami sources (audit logging only — invisible to apps; logging stops when the k3s instances decommission) and `vectors.so` on immich (preloads the `vector` extension, which the consolidated image bundles). Nothing app-critical.   |
| `btree_gist` inet/cidr indexes | None anywhere (`btree_gist` is not even installed — only `btree_gin`).                                                                                                                                                                                                  |
| Custom GUCs                    | Only standard tuning plus `default_text_search_config = pg_catalog.english` (valid in PG18). The one deprecated GUC in use, `wal_keep_segments` (replaced by `wal_keep_size`, gone in PG17+), is set on the k3s sources only and is not carried into the target config. |

## Name conflicts (resolved in `manifest.tsv`)

A database name cannot exist twice in one server. Two pairs collide:

| Name            | Instances                              | Resolution                                                                                                   |
| --------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `homeassistant` | 121 (186M) + 129 (824M)                | 129 stays `homeassistant` (has live conns per `pg_stat_activity`); 121 → `homeassistant_121`                 |
| `penpot`        | 129 (9M) + 138 (36M)                   | 138 stays `penpot` (penpot backend points there); 129 → `penpot_129`                                         |
| `honcho`        | 138 (7.4M) + pgvector `postgres` (37M) | 138 stays `honcho`; pgvector copy → `honcho_pgvector` (owner role `honcho`, vector ext — the live honcho DB) |

`pg_stat_activity` (verified 2026-11-21) shows which copies have live
connections: the 129 `homeassistant` (824M) is **live** — it has 3 active
connections and its app config lives at `/config/configuration.yaml` in the
HA PVC — so 129 is the authoritative copy and is kept as the primary name.
The 121 copy (186M) has no live connections and is legacy (preserved, not
wired). The `penpot` server is not running (ns holds only an exporter); the
138 copy is kept because the penpot backend's `PENPOT_DATABASE_URI` points at
`postgresql16`. The two `honcho` copies are both preserved (138 as `honcho`,
the vector copy as `honcho_pgvector`) — honcho uses pgvector, so the
`honcho_pgvector` copy is likely the real one; verify before wiring.

Other notes:

- `cryptofolio`: **verified** — no such database exists on any source instance
  (the k3s app runs stateless, no DB env). A fresh `cryptofolio` DB + role is
  created for the migrated app; nothing to dump.
- `pgvector` (37M): **verified** — owned and queried by the `honcho` role
  (client 10.42.9.7), and the live honcho app (now on Talos) points at it via
  the k3s NodePort `172.20.0.116:31532` on source DB `postgres`. Migrated as
  `honcho_pgvector` (owner `honcho`, vector extension). The `postgresql16`
  `honcho` (7.4M) has no live connections, so the vector copy is honcho's real
  database.

## IP re-pointing (k3s LB → 172.20.17.150)

| App (cluster)                       | Was                                                                       | Becomes                                                                 |
| ----------------------------------- | ------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| firefly-iii (k3s, this PR)          | 172.20.0.121:5432                                                         | 172.20.17.150:5432                                                      |
| firefly-iii importer (k3s, this PR) | 172.20.0.121:5432                                                         | 172.20.17.150:5432                                                      |
| cryptofolio (this PR)               | (no source DB — stateless)                                                | 172.20.17.150:5432 (fresh `cryptofolio` DB)                             |
| ghostfolio (k3s, this PR)           | 172.20.0.138:5432 (see note)                                              | 172.20.17.150:5432                                                      |
| immich (Talos, on main)             | 172.20.0.113:32289 (k3s NodePort)                                         | 172.20.17.150:5432                                                      |
| forgejo (Talos, on main)            | 172.20.0.121:5432 (in `app.ini`)                                          | 172.20.17.150:5432 — **PVC edit, not a manifest**                       |
| matrix/dendrite (Talos, on main)    | 172.20.0.129:5432 (10 connection strings in the `dendrite-config` secret) | 172.20.17.150:5432                                                      |
| mautrix-whatsapp (Talos, on main)   | 172.20.0.129:5432 (DB URI in the `whatsapp` PVC `config.yaml`)            | 172.20.17.150:5432                                                      |
| honcho (Talos, on main)             | 172.20.0.116:31532 (k3s NodePort; source DB `postgres`)                   | 172.20.17.150:5432 — **DB name changes** `postgres` → `honcho_pgvector` |
| litellm (Talos, on main)            | 172.20.0.138:5432                                                         | 172.20.17.150:5432                                                      |
| authelia (Talos, on main)           | (none — file-based user DB)                                               | none — legacy `authelia` DB preserved, not wired                        |
| n8n (Talos, on main)                | (none — built-in SQLite)                                                  | none — legacy `n8n` DB preserved, not wired                             |

> **ghostfolio source correction:** the PR originally pointed all three apps at
> 172.20.0.121, but the k3s `ghostfolio` `DATABASE_URL` actually references
> `postgres16-postgresql.postgresql16.svc.cluster.local` = **172.20.0.138**
> (the `postgresql16` instance). The `manifest.tsv` dumps ghostfolio from 138,
> which is correct. Because every database converges to 172.20.17.150, the
> final `DB_HOST` for all three apps is the same; only the _source_ of the
> ghostfolio dump differs from the PR's original claim.

Only the **host** changes; DB name and user/password are unchanged (the
consolidated instance recreates each role with its original password).

> **forgejo** keeps its DB config in `app.ini` inside the `forgejo-data` PVC
> (not in env vars), so re-pointing it is a PVC edit at cutover
> (`[database] HOST` → 172.20.17.150), done in the runbook, not a manifest
> change. The `gitea` role is recreated with the same password, so no secret
> change is needed.

> **`*arr` apps (lidarr/sonarr/radarr/readarr) need NO re-pointing** — verified
> they carry no DB env vars and use their SQLite config files in their PVCs.
> The `postgresql14` `lidarr-*`/`sonarr-*` databases are **legacy** and are
> preserved in the consolidated instance for safety, not wired to any app.

> immich also uses a k3s **redis** (172.20.0.139). That is a separate migration
> (redis → docker-compose), tracked outside this PR's Postgres scope.

## Cutover checklist status

Status of the full pre-dump / dump-restore / post-restore checklist
(live-audited 2026-11-21, all six sources / 37 databases):

**Before dumping**

- [x] `standard_conforming_strings = on` — verified `on` on every server;
      `migrate.sh` re-checks and fixes before each dump.
- [x] No `MULE_INTERNAL` encoding — all 37 databases are `UTF8`.
- [x] Extensions + shared libraries inventoried — see the audit tables above
      (`pgaudit` on the bitnami sources, `vectors.so` on immich; nothing else).
- [x] No `btree_gist` inet/cidr indexes anywhere.
- [x] No backslash-escaped strings in any migration script (`migrate.sh` uses
      `E''` escapes only).
- [x] No `READ ONLY` + `postgres_fdw` patterns — `postgres_fdw` not installed.
- [x] Custom GUCs checked — only standard tuning plus
      `default_text_search_config = pg_catalog.english` (valid in PG18); the one
      deprecated GUC in use (`wal_keep_segments`) stays on the k3s sources and is
      not carried into the target.

**Dump & restore**

- [ ] PG18 `pg_dump`/`pg_dumpall` — optional; not required because
      `standard_conforming_strings = on` on every source and the target (PG18)
      is ≥ every source version. Available if wanted: install the PG18 client
      tools on any machine that can reach the source.
- [x] Restore target is a clean PG18 instance (the compose service,
      `postgres:18` image — see the version compatibility section).
- [x] Reindex FTS / `pg_trgm` after restore — **not needed**: `pg_restore`
      rebuilds all indexes from the restored data, and every database keeps the
      same libc locale, so index contents are identical.
- [x] Recompute stored `tsvector` values — **not needed**: no `tsvector`
      columns exist in any database.
- [x] Reindex `fuzzystrmatch` indexes — **not needed**: extension not installed.

**After restore**

- [ ] Verify extensions loaded — `migrate.sh` checks table counts and role
      auth per DB; also confirm
      `SELECT extname FROM pg_extension;` matches `initdb/01-init-extensions.sql`
      (eight extensions: vector, vchord, cube, earthdistance, pg_trgm,
      btree_gin, unaccent, uuid-ossp).
- [ ] Run application smoke tests — scale each app back up (runbook step 4)
      and confirm it connects and loads its data; app healthchecks cover the rest.
- [x] MD5 → SCRAM authentication — no action needed: roles are recreated on
      PG18 with their original passwords, so PG18 stores SCRAM-SHA-256 hashes and
      the `md5`/`scram-sha-256` pg_hba methods both negotiate SCRAM. `migrate.sh
  --verify-talos` exercises real role auth from the Talos cluster.
- [x] Analytical queries / JIT — JIT is off by default in PG18; all of these
      databases are OLTP (no analytical workloads), so no tuning required.
- [ ] Monitoring — the consolidated instance is a new host
      (172.20.17.150:5432, one port, 37 databases): point any Postgres exporter /
      alerts at the new instance and drop the six per-DB targets. The k3s
      `pgaudit` audit logging ends with the k3s instances; nothing downstream
      consumes it.
- [x] Replication — not applicable: every source is standalone
      (the immich CNPG `primary_conninfo`/`restore_command` entries are its
      controller's own bookkeeping, not a user replica).

## Cutover runbook

Everything happens as a short, deliberate window. **Do not skip the scale-down**
— a consistent dump requires no active writers.

### 0. Prep (before the window)

1. Deploy the consolidated postgres on 172.20.17.150 (the compose service
   builds the image from the local `Dockerfile` on first start):
    ```
    cd <this-dir-on-TrueNAS> && docker compose up -d --build
    docker compose ps        # healthy?
    ```
2. Generate the local `creds.env` (chmod 600) with `TARGET_SU` + each source
   superuser + each role password (see `migrate.sh` header). Generate
   `./initdb/roles.sql` from `roles.example.sql` with the real role passwords
   and start the compose service (roles are created on first start). The
   committed `./initdb/01-init-extensions.sql` creates the eight extensions;
   the `Dockerfile` bakes the same SQL into the image, so a fresh instance
   gets them either way.
3. `./migrate.sh --dry-run` — sanity-check the plan.

### 1. Scale down ALL consumers (k3s + Talos)

Order matters only in that everything must be down before dumps. For each app
that reads one of these databases:

```
# Talos (KUBECONFIG=.../kubeconfig)
kubectl -n <ns> scale deploy/<app> --replicas=0
# k3s (KUBECONFIG=.../home.yaml)
kubectl --kubeconfig <k3s> -n <ns> scale deploy/<app> --replicas=0
```

Consumers to scale down (verified against the live clusters, 2026-11-18):

- Talos: immich, forgejo(gitea), home-assistant, litellm, matrix/dendrite
  (`dendrite` deployment), mautrix-whatsapp (`whatsapp` deployment), honcho.
- k3s: firefly-iii (+ importer), ghostfolio, mealie, penpot, planka,
  mastodon, piped, acmedns, wiki, and any `*arr` still on k3s.
- No scale-down needed: authelia (file-based user DB), n8n (built-in
  SQLite), lidarr/sonarr/readarr/radarr (SQLite in PVCs) — none of these
  touch Postgres.
- Verify each is at 0/1 before proceeding: `kubectl get pods -A | grep <app>`.

### 2. Dump + restore

`migrate.sh` first checks `standard_conforming_strings` on every source and
sets it to `on` if needed (the default since PG9.1; defensive — see the
version compatibility section). You can also verify manually:

```
psql -h <source> -U postgres -c "SHOW standard_conforming_strings;"
# if off:
psql -h <source> -U postgres -c "ALTER SYSTEM SET standard_conforming_strings = on;"
psql -h <source> -U postgres -c "SELECT pg_reload_conf();"
```

Optionally, install a PG18 `pg_dump`/`pg_dumpall` client on a separate
machine and point it at the source clusters to guarantee a fully PG18-native
dump.

```
./migrate.sh            # all databases, per manifest.tsv
```

The script dumps each DB (custom format), creates the target DB + owner,
restores it, creates required extensions, and verifies table count + role auth.
Large DBs (litellm 4.1G, dendrite 5.4G) take the longest — run in a tracked
background session.

### 3. Verify before re-pointing

```
./migrate.sh --verify-only
```

Spot-check the big/important DBs by connecting as each app role and running a
real query (row counts on key tables) and compare against the source.

Additionally, verify from the Talos cluster itself — this proves the Talos
pod CIDR can reach 172.20.17.150:5432 (firewall) and that every Talos-side
workload can authenticate against the new DB:

```
TALOS_KUBECONFIG=<talos-kubeconfig> ./migrate.sh --verify-talos
```

### 4. Re-point the apps

Apply the IP changes (this PR's manifests already point at 172.20.17.150).
For immich (on main) apply its DB_HOST/DB_PORT change. Then scale the apps back
up and confirm each connects and loads its data.

### 5. Clean up

- Leave the k3s postgres instances running (scaled, not deleted) until every
  app is verified on the new host.
- Once verified, the k3s postgres namespaces can be decommissioned as part of
  k3s shutdown.

## Rollback

- The source instances are untouched (dumps are read-only `pg_dump`). If an app
  misbehaves on the new host, re-point it back to its original k3s LB IP and
  scale it up. Nothing is deleted from the sources during the window.

## Pitfalls

- **Consistency requires writers stopped.** A `pg_dump` of a busy DB can restore
  into an inconsistent state for some apps. Scale down first, every time.
- **Role passwords must match the app's existing password** — only the host
  changes. If a role is created with a new password, the app breaks until its
  config is also changed.
- **Extensions** (immich) must be created in the target DB before/after restore
  as appropriate; the image bundles them.
- **The `postgres` template DB is not migrated** (it is not app data).
- **Firewall**: 172.20.17.150:5432 must accept the Talos pod CIDR (172.20.128.0/18)
  and node subnet; keep it off the public internet.
- **pgvector owner confirmed** — the `honcho` role owns and queries it (the
  live honcho app on Talos points at it via the k3s NodePort); kept in the
  manifest as `honcho_pgvector`.
- **immich redis** is a separate migration (not in this Postgres scope).
