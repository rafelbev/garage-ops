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
- The built image (`postgres:19` + PGDG `postgresql-19-pgvector`, see the
  `Dockerfile` in this directory) covers every extension in use (vector,
  cube, earthdistance, pg_trgm, unaccent, uuid-ossp).

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

## Postgres version compatibility (why PG19)

The consolidated image is **PostgreSQL 19** (`postgres:19` plus the PGDG
`postgresql-19-pgvector` package, built via the `Dockerfile` in this
directory). The plan is to run the consolidated instance on PG19 — the
current stable major. This answers the review question of which target
version to pick.

1. **The target must be ≥ the newest source.** The sources run PG11, 12, 14
   and 16 (verified above). The newest is PG16, so the target must be ≥ 16.
2. **Forward-compatible restore.** `pg_dump` custom-format dumps are
   forward-compatible: a dump taken from PG11/12/14/15/16 restores cleanly
   into PG19, **provided `standard_conforming_strings = on` on the source**
   (the default since PG9.1 — the PG19 release notes explicitly warn that
   dumps made with pre-PG19 `pg_dump` _and_ `standard_conforming_strings =
   off` will not load properly into PG19+). `migrate.sh` checks this on every
   source before dumping and fixes it if needed (see the cutover runbook).
   Optionally, install the PG19 `pg_dump`/`pg_dumpall` client tools on a
   separate machine and point them at the source clusters to guarantee a
   fully PG19-native dump.
3. **No app needs a version newer than PG19** — and none needs a PG19+
   feature either; PG19 is simply the newest supported major, so every
   consuming application's supported range is satisfied:

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

4. **All required extensions are present.** The image bundles the `vector`
   extension (immich, honcho) via the PGDG `postgresql-19-pgvector` package,
   plus every contrib module the sources use — `cube`, `earthdistance`,
   `pg_trgm`, `unaccent`, `uuid-ossp` — so no app is left without an extension
   it needs.

## Name conflicts (resolved in `manifest.tsv`)

A database name cannot exist twice in one server. Two pairs collide:

| Name            | Instances                              | Resolution                                                                                                   |
| --------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `homeassistant` | 121 (186M) + 129 (824M)                | 129 stays `homeassistant` (has live conns per `pg_stat_activity`); 121 → `homeassistant_121`                 |
| `penpot`        | 129 (9M) + 138 (36M)                   | 138 stays `penpot` (penpot backend points there); 129 → `penpot_129`                                         |
| `honcho`        | 138 (7.4M) + pgvector `postgres` (37M) | 138 stays `honcho`; pgvector copy → `honcho_pgvector` (owner role `honcho`, vector ext — the live honcho DB) |

`pg_stat_activity` (verified 2026-10-20) shows which copies have live
connections: the 129 `homeassistant` (824M) has 3, the 121 copy (186M) has
none, so 129 is kept as the primary name. HA on Talos uses SQLite, so neither
is currently wired to a live app — both are preserved, not lost. **Raphael to
confirm** which `homeassistant` copy is authoritative if he revives HA on
Postgres. The `penpot` server is not running (ns holds only an exporter); the
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
   committed `./initdb/01-init-extensions.sql` creates the six extensions;
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
sets it to `on` if needed — required for PG19 restores (see the version
compatibility section). You can also verify manually:

```
psql -h <source> -U postgres -c "SHOW standard_conforming_strings;"
# if off:
psql -h <source> -U postgres -c "ALTER SYSTEM SET standard_conforming_strings = on;"
psql -h <source> -U postgres -c "SELECT pg_reload_conf();"
```

Optionally, install the PG19 `pg_dump`/`pg_dumpall` client tools on a
separate machine and point them at the source clusters to guarantee a
fully PG19-native dump.

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
