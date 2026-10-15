# Forgejo Migration: k3s → Talos

Migrated from the k3s cluster (namespace `gitea`, service
`git.cloud.neo-tix.com`) to this cluster (`git.garage.neo-tix.com`).

## Source state at migration time (2026-10)

- **App**: `code.forgejo.org/forgejo/forgejo:14.0.2` (a Gitea fork; the k3s
  deployment was still named `gitea-1622298970`)
- **Data volume**: 10 GiB NFS PVC (`truenas-nfs-dynamic`), 3.2 GiB in use
  (git repositories dominate). The source pod was pinned to that NFS export.
- **Database**: PostgreSQL 11.14 on the k3s cluster (namespace `postgresql`,
  database `gitea`, schema `gitea`, user `gitea`, 337 MB — mostly a 298 MB
  `notice` table), exposed externally by the `postgresql-external`
  LoadBalancer service at `172.20.0.121:5432`.
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

| App       | Namespace | Contents                                                                                                                                                                |
| --------- | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `forgejo` | `forgejo` | Forgejo 14.0.2 Deployment, 10 GiB `truenas-iscsi` PVC, ClusterIP service (HTTP), LoadBalancer service (SSH, pinned `172.20.17.142`), HTTPRoute `git.garage.neo-tix.com` |

The database is **not** part of this PR — it stays on the k3s cluster (see
below).

### Deliberate differences from the source

1. **Database stays on k3s** — the standing decision is to stop running
   databases in-cluster. Forgejo connects to the existing PostgreSQL 11.14
   over the k3s `postgresql-external` LoadBalancer IP
   (`172.20.0.121:5432`), reachable from the Talos cluster's L2. User and
   password are unchanged (they live in `app.ini` on the data volume).
   **Caveat:** decommissioning the k3s cluster would cut off the database —
   plan a DB move before that happens.
2. **Cache adapter `lru`** — the memcached dependency is dropped; app.ini's
   `[cache]` section is rewritten in place on the data volume.
3. **Runs as root, like the source** (the image's s6-overlay `/init` chdirs
   to `/` before exec'ing s6-svscan, whose lock file is CWD-relative —
   `/.s6-svscan/lock` on the rootfs — so a non-root container cannot start
   s6-svscan; a `runAsNonRoot` pod crash-loops on the lock). The data volume
   is still chowned to 1000 by the `fix-ownership` init container on every
   start — this also repairs the source's root-owned `ssh` directory
   (root:root 0700).
4. **`/tmp` is a plain emptyDir** (source mounted it at `/tmp/gitea`).
5. **Explicit resource requests/limits** (source had none).
6. **SSH via a Cilium LoadBalancer VIP** (172.20.17.142) instead of a headless
   service with an unroutable pod IP.
7. **Deployment instead of StatefulSet** — single replica, RWO iSCSI volume;
   matches the repo convention for the other migrated apps.

### `app.ini`

Lives on the data volume at `/data/gitea/conf/app.ini` (it contains the
database password, `INTERNAL_TOKEN` and `JWT_SECRET`, so it is deliberately
**not** stored in this repo). It was updated in place on the target volume:

- `DOMAIN` / `ROOT_URL` / `SSH_DOMAIN` → `git.garage.neo-tix.com`
- `[cache]` → `ADAPTER = lru`, `HOST` removed
- `[database]` → `HOST = 172.20.0.121:5432` (k3s `postgresql-external`
  LoadBalancer); `USER` / `PASSWD` / `NAME` / `SCHEMA` unchanged

## Transfer procedure (executed out-of-band, not in this PR)

1. This PR merged → Flux provisions the PVC.
2. Forgejo deployment scaled to 0 (health check recovers once replicas return).
3. Helper pod mounting the new PVC + the source NFS share (read-only):
   `rsync -a` of the whole data volume (3.2 GiB), then
   `chown -R 1000:1000`.
4. `app.ini` patched in place (domain, cache, database host).
5. Deployment scaled back to 1; verified: pod Ready, web UI reachable,
   `git clone` over HTTP and SSH, repository and issue counts. The database
   is untouched — it keeps serving from k3s at `172.20.0.121:5432`.

## Follow-ups (not in this PR)

- **DNS**: `git.garage.neo-tix.com` must resolve to the external gateway VIP
  (172.20.17.137) — same pattern as the other `*.garage.neo-tix.com` apps.
  Until then the old `git.cloud.neo-tix.com` record is dead.
- **act-runner**: re-register a new runner on `git.garage.neo-tix.com` if
  Forgejo Actions are wanted (old token is bound to the old instance).
- **Database on k3s**: the `gitea` database stays on the k3s cluster
  (`postgresql-external` LoadBalancer, `172.20.0.121:5432`). Do **not** delete
  the k3s `postgresql` namespace as part of decommissioning — Forgejo on
  Talos depends on it. The `gitea` app namespace on k3s _can_ be deleted once
  the migration is verified (its PVCs use `Delete` reclaim policy — only after
  confirming the new instance is fully serving).
