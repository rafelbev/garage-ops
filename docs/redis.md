# Shared out-of-cluster Redis

All cluster applications that need Redis use a **single standalone Redis
server** hosted out of cluster, rather than running their own in-cluster
deployment. This keeps operational burden low (one server to patch, back up,
and monitor) and gives every app an isolated key space via its own logical
database index.

- **Host:** `redis.intranet.neo-tix.com` (host `172.20.17.17`, port `6379`)
- **Server:** standalone Docker Redis (AOF persistence)
- **Auth:** a shared password (see each app's SOPS secret — never plain text)
- **Databases:** 16 logical databases (`db0`–`db15`), one per app

> History: the old in-cluster Redis (bitnami chart: 1 master + 2 replicas,
> AOF-only) lived in the k3s `redis` namespace and was migrated here in 2026-11
> via live replication. See `AGENTS.md` → _Key Learnings from the Redis
> Migration_ for the migration method and pitfalls.

## Database-index allocation

The table below is the **authoritative allocation list** of Redis database
indexes. Keep it current whenever an app starts (or stops) using the shared
instance, and mirror the change in the consuming app's README.

| db index | app       | cluster | status  | where the connection is configured                                             |
| -------- | --------- | ------- | ------- | ------------------------------------------------------------------------------ |
| 0        | immich    | Talos   | active  | `REDIS_HOSTNAME` in `kubernetes/apps/immich/immich/app/server-deployment.yaml` |
| 1        | penpot    | k3s     | dormant | `PENPOT_REDIS_URI` in `penpot-backend` and `penpot-exporter`                   |
| 2        | firecrawl | Talos   | active  | `REDIS_URL` / `REDIS_RATE_LIMIT_URL` in the SOPS secret `firecrawl`            |

## Standing rule — one logical DB per app

Every app that uses the shared Redis gets its **own database index** (the `/N`
suffix in the connection URL, or the app's db config) so key spaces never
collide. When adding a new Redis consumer:

1. Pick the **next free index** from the table above (do not reuse an index of
   a dormant app — a 0/0 replica can still "own" an index that shows 0 keys).
2. Add a row to the table in this file **and** to the consuming app's README.
3. Store the full connection URL in the app's SOPS secret (not a ConfigMap),
   since most apps read a single `redis://user:pass@host:port/db` string.
4. Verify the index is free before assigning it:
   `redis-cli -h redis.intranet.neo-tix.com -a <password> -n <db> DBSIZE` —
   the keyspace summary only lists non-empty DBs, so an empty result is not
   proof the index is unallocated.

## Accessing the server from the workstation

```bash
# Install redis-tools if needed; the password is per-app, e.g. immich's:
PW=$(kubectl -n immich get secret immich-redis -o jsonpath='{.data.password}' | base64 -d)

# Per-DB key count (verify allocation / liveness)
redis-cli -h redis.intranet.neo-tix.com -a "$PW" -n 2 DBSIZE
```
