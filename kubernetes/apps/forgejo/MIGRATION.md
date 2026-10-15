# Forgejo Migration: k3s → Talos

Migrated from the k3s cluster (namespace `gitea`, service
`git.cloud.neo-tix.com`) to this cluster (`git.garage.neo-tix.com`).

## Source state at migration time (2026-10)

- **App**: `code.forgejo.org/forgejo/forgejo:14.0.2` (a Gitea fork; the k3s
  deployment was still named `gitea-1622298970`)
- **Data volume**: 10 GiB NFS PVC (`truenas-nfs-dynamic`), 3.2 GiB in use
  (git repositories dominate). The source pod was pinned to that NFS export.
- **Database**: PostgreSQL 11 (bitnami) in the k3s `postgresql` namespace —
  database `gitea`, schema `gitea`, user `gitea`, 337 MB (mostly a 298 MB
  `notice` table).
- **Cache**: `memcache` adapter pointing at a memcached sidecar deployment
  that had been **Pending for weeks** — this was the cause of the source pod
  crash-looping (1,600+ restarts). Forgejo started, reached
  `cache.Init`, and died with `memcache: connect timeout`.
- **act-runner** (Forgejo Actions, `code.forgejo.org/forgejo/runner:12` +
  docker:dind): also crash-looping (503 from the dead instance). Not migrated —
  it was already dead before this migration and its registration token is
  tied to the old instance. Re-register a runner on the new instance if
  Actions are needed.

## What this PR adds

| App          | Namespace    | Contents                                                                                                                                                                |
| ------------ | ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `forgejo-db` | `forgejo-db` | PostgreSQL 16 StatefulSet, 2 GiB `truenas-iscsi` PVC, ClusterIP service, sops-encrypted password secret                                                                 |
| `forgejo`    | `forgejo`    | Forgejo 14.0.2 Deployment, 10 GiB `truenas-iscsi` PVC, ClusterIP service (HTTP), LoadBalancer service (SSH, pinned `172.20.17.138`), HTTPRoute `git.garage.neo-tix.com` |

### Deliberate differences from the source

1. **PostgreSQL 16 instead of 11** — 11 is EOL. Moved via `pg_dump`/`pg_restore`
   (supported across major versions). New password (sops-encrypted, not
   reusing the k3s one).
2. **Cache adapter `lru`** — the memcached dependency is dropped; app.ini's
   `[cache]` section is rewritten in place on the data volume.
3. **Runs as uid/gid 1000** (source ran as root with `fsGroup: 1000`). The data
   volume is chowned to 1000 by the `fix-ownership` init container on every
   start — this also repairs the source's root-owned `ssh` directory
   (root:root 0700).
4. **`/tmp` is a plain emptyDir** (source mounted it at `/tmp/gitea`).
5. **Explicit resource requests/limits** (source had none).
6. **SSH via a Cilium LoadBalancer VIP** (172.20.17.138) instead of a headless
   service with an unroutable pod IP.
7. **Deployment instead of StatefulSet** — single replica, RWO iSCSI volume;
   matches the repo convention for the other migrated apps.

### `app.ini`

Lives on the data volume at `/data/gitea/conf/app.ini` (it contains the
database password, `INTERNAL_TOKEN` and `JWT_SECRET`, so it is deliberately
**not** stored in this repo). It was updated in place on the target volume:

- `DOMAIN` / `ROOT_URL` / `SSH_DOMAIN` → `git.garage.neo-tix.com`
- `[cache]` → `ADAPTER = lru`, `HOST` removed
- `[database]` → `HOST = postgres.forgejo-db.svc.cluster.local:5432`, new
  password

## Transfer procedure (executed out-of-band, not in this PR)

1. This PR merged → Flux provisions the PVCs and the fresh Postgres.
2. Forgejo deployment scaled to 0 (health check recovers once replicas return).
3. Helper pod mounting the new PVC + the source NFS share (read-only):
   `rsync -a` of the whole data volume (3.2 GiB), then
   `chown -R 1000:1000`.
4. `app.ini` patched in place (domain, cache, database).
5. `pg_dump -Fc` of the k3s `gitea` database (337 MB) → `pg_restore` into the
   new Postgres 16 (role `gitea` owns database and schema, as in the source).
6. Deployment scaled back to 1; verified: pod Ready, web UI reachable,
   `git clone` over HTTP and SSH, repository and issue counts.

## Follow-ups (not in this PR)

- **DNS**: `git.garage.neo-tix.com` must resolve to the external gateway VIP
  (172.20.17.137) — same pattern as the other `*.garage.neo-tix.com` apps.
  Until then the old `git.cloud.neo-tix.com` record is dead.
- **act-runner**: re-register a new runner on `git.garage.neo-tix.com` if
  Forgejo Actions are wanted (old token is bound to the old instance).
- **k3s cleanup**: delete the `gitea` namespace on k3s once the migration is
  verified (its PVCs use `Delete` reclaim policy — do this only after
  confirming the new instance is fully serving).
