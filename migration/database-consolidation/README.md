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
- `pgvector/pgvector/pg16` covers every extension in use (vector, cube,
  earthdistance, pg_trgm, unaccent, uuid-ossp).

## Source inventory (verified 2026-10-20)

| Source instance         | k3s LB IP    | PG ver | Databases (size)                                                                                          |
| ----------------------- | ------------ | ------ | --------------------------------------------------------------------------------------------------------- |
| `postgresql`            | 172.20.0.121 | 14     | gitea 337M, homeassistant 186M, firefly 16M, authelia 7.7M, wiki 7.6M                                     |
| `postgresql12`          | 172.20.0.129 | 12     | dendrite_* (≈5.4G total), homeassistant 824M, whatsapp 33M, mealie 10M, penpot 9M, planka 9M, mastodon 8M |
| `postgresql14`          | 172.20.0.135 | 14     | lidarr-main 804M, sonarr-main 68M, lidarr-log 37M, sonarr-log 17M, piped 8.4M                             |
| `postgresql16`          | 172.20.0.138 | 16     | litellm 4.1G, penpot 36M, ghostfolio 10M, acmedns 7.7M, n8n 7.4M, honcho 7.4M                             |
| `postgresql16-pgvector` | (internal)   | 16     | postgres 37M (vector) — **owner unknown**                                                                 |
| `immich` (CNPG)         | (internal)   | 15/16  | immich 571M (vector, cube, earthdistance, pg_trgm, unaccent, uuid-ossp)                                   |

Total ≈ **12 GiB**.

## Name conflicts (resolved in `manifest.tsv`)

A database name cannot exist twice in one server. Two pairs collide:

| Name            | Instances                              | Resolution                                                                                     |
| --------------- | -------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `homeassistant` | 121 (186M) + 129 (824M)                | 129 stays `homeassistant` (has live conns per `pg_stat_activity`); 121 → `homeassistant_121`   |
| `penpot`        | 129 (9M) + 138 (36M)                   | 138 stays `penpot` (penpot backend points there); 129 → `penpot_129`                           |
| `honcho`        | 138 (7.4M) + pgvector `postgres` (37M) | 138 stays `honcho`; pgvector copy → `honcho_pgvector` (owner role is `honcho`, has vector ext) |

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
- `pgvector` (37M): **verified** — `pg_stat_activity` shows it is owned and
  queried by the `honcho` role (client 10.42.9.7). Migrated as `honcho_pgvector`
  (owner `honcho`, vector extension). The `postgresql16` `honcho` (7.4M) has no
  live connections, so the vector copy is honcho's real database.

## IP re-pointing (k3s LB → 172.20.17.150)

| App (cluster)                         | Was                               | Becomes                                           |
| ------------------------------------- | --------------------------------- | ------------------------------------------------- |
| firefly-iii (Talos, this PR)          | 172.20.0.121:5432                 | 172.20.17.150:5432                                |
| firefly-iii importer (Talos, this PR) | 172.20.0.121:5432                 | 172.20.17.150:5432                                |
| cryptofolio (Talos, this PR)          | (no source DB — stateless)        | 172.20.17.150:5432 (fresh `cryptofolio` DB)       |
| ghostfolio (Talos, this PR)           | 172.20.0.138:5432 (see note)      | 172.20.17.150:5432                                |
| immich (Talos, on main)               | 172.20.0.113:32289 (k3s NodePort) | 172.20.17.150:5432                                |
| forgejo (Talos, on main)              | 172.20.0.121:5432 (in `app.ini`)  | 172.20.17.150:5432 — **PVC edit, not a manifest** |

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

1. Deploy the consolidated postgres on 172.20.17.150:
    ```
    cd <this-dir-on-TrueNAS> && docker compose up -d
    docker compose ps        # healthy?
    ```
2. Generate the local `creds.env` (chmod 600) with `TARGET_SU` + each source
   superuser + each role password (see `migrate.sh` header). Generate
   `./initdb/roles.sql` from `roles.example.sql` with the real role passwords
   and start the compose service (roles are created on first start).
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

Consumers to scale down (from the inventory):

- Talos: firefly-iii, cryptofolio, ghostfolio, immich, forgejo(gitea),
  home-assistant, litellm, n8n, lidarr, sonarr, readarr, radarr, authelia.
- k3s: matrix/dendrite, whatsapp(mautrix), mealie, penpot, planka, mastodon,
  piped, honcho, acmedns, wiki, and any `*arr` still on k3s.
- Verify each is at 0/1 before proceeding: `kubectl get pods -A | grep <app>`.

### 2. Dump + restore

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
- **pgvector owner unknown** — confirm before dumping; drop from manifest if unused.
- **immich redis** is a separate migration (not in this Postgres scope).
