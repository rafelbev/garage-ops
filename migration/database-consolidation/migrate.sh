#!/usr/bin/env bash
#
# migrate.sh - converge the six k3s PostgreSQL instances into the single
# consolidated docker-compose PostgreSQL instance (172.20.17.150:5432).
#
# Driven by manifest.tsv (one row per source database). Reads secrets from a
# LOCAL, gitignored creds.env (never committed). Only changes the DB *host*
# for each app - role names and passwords are preserved, so consuming apps do
# not need credential changes.
#
# Prerequisites (see README.md):
#   1. The consolidated postgres is up and healthy on the target.
#   2. ALL workloads using the source databases are SCALED DOWN (see the
#      cutover runbook) so the dumps are consistent and nothing writes during
#      the copy.
#   3. creds.env is populated (see below).
#
# creds.env format (chmod 600, gitignored):
#   TARGET_SU=<superuser password of the consolidated instance>
#   SU_172_20_0_121=<source superuser pw>   # dots -> underscores
#   SU_172_20_0_129=...
#   SU_172_20_0_135=...
#   SU_172_20_0_138=...
#   SU_internal_pgvector=postgres
#   SU_internal_immich=<superuser pw>
#   ROLE_<role>=<role password>             # used for verification only
#
# Usage:
#   ./migrate.sh --dry-run                 # show what would be done
#   ./migrate.sh --db firefly              # migrate a single database
#   ./migrate.sh                           # migrate all
#   ./migrate.sh --verify-only             # verify existing target state
#   TALOS_KUBECONFIG=<path> ./migrate.sh --verify-talos
#                                          # verify from the Talos cluster:
#                                          # reachability + role auth for
#                                          # every manifest row, from a probe
#                                          # pod in the Talos cluster
#
# Before every dump, migrate.sh checks `standard_conforming_strings` on the
# source and sets it to `on` if needed (defensive: it is `on` by default since
# PG9.1, and a clean cross-version restore wants consistent string-literal
# handling).
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$HERE/manifest.tsv"
CREDS="${CREDS_FILE:-$HERE/creds.env}"
TARGET_HOST="${TARGET_HOST:-172.20.17.150}"
TARGET_PORT="${TARGET_PORT:-5432}"
WORKDIR="$(mktemp -d /tmp/dbcons.XXXXXX)"
K3S_KUBECONFIG="${K3S_KUBECONFIG:-$HOME/home.yaml}"
TALOS_KUBECONFIG="${TALOS_KUBECONFIG:-}"

DRY=0; VERIFY_ONLY=0; VERIFY_TALOS=0; ONLY_DB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --verify-only) VERIFY_ONLY=1 ;;
    --verify-talos) VERIFY_TALOS=1 ;;
    --db) ONLY_DB="${2:?--db needs a value}"; shift ;;
    -h|--help) sed -n '2,55p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -f "$CREDS" ] || { echo "creds.env not found at $CREDS (see header for format)" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CREDS"
[ -n "${TARGET_SU:-}" ] || { echo "TARGET_SU not set in creds.env" >&2; exit 1; }

tgt_ps () { PGPASSWORD="$TARGET_SU" psql -h "$TARGET_HOST" -p "$TARGET_PORT" -U postgres -d postgres -tA -F'|' "$@"; }
src_su_var () { local s="$1"; local k; k=$(echo "$s" | sed 's/\./_/g'); echo "SU_$k"; }
# safe indirect expansion: print the value of the variable named by $1 (empty if unset)
getvar () { local n="$1"; eval "printf '%s' \"\${$n}\"" 2>/dev/null || true; }

# Map an internal source to "namespace pod" (pod resolved dynamically).
internal_pod () {
  local ns pod
  case "$1" in
    internal:pgvector) ns="postgresql16-pgvector" ;;
    internal:immich)   ns="immich" ;;
    *) return 1 ;;
  esac
  pod="$(kubectl --kubeconfig "$K3S_KUBECONFIG" get pods -n "$ns" \
    -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | awk '{print $1}')"
  [ -n "$pod" ] || { echo "no running pod in k3s namespace $ns" >&2; exit 1; }
  echo "$ns $pod"
}

# Run psql against a source (external host or in-cluster pod), as superuser.
src_psql () {
  local source="$1"; shift
  if [[ "$source" == internal:* ]]; then
    local ns pod suvar su
    read -r ns pod <<<"$(internal_pod "$source")"
    suvar="$(src_su_var "${source#internal:}")"; su="$(getvar "$suvar")"
    [ -z "$su" ] && { echo "missing $suvar in creds.env" >&2; exit 1; }
    kubectl --kubeconfig "$K3S_KUBECONFIG" exec -i "$pod" -n "$ns" -- \
      env PGPASSWORD="$su" psql -h 127.0.0.1 -U postgres -d postgres -tA "$@"
  else
    local suvar su
    suvar="$(src_su_var "$source")"; su="$(getvar "$suvar")"
    [ -z "$su" ] && { echo "missing $suvar in creds.env" >&2; exit 1; }
    PGPASSWORD="$su" psql -h "$source" -p 5432 -U postgres -d postgres -tA "$@"
  fi
}

# Pre-dump check: ensure standard_conforming_strings = on on every source
# before dumping (it is `on` by default since PG9.1; this is defensive so the
# cross-version restore has consistent string-literal handling).
source_preflight () {
  local source="$1" s
  s="$(src_psql "$source" -c "SHOW standard_conforming_strings" | tr -d ' ')"
  case "$s" in
    on)  echo "  preflight $source: standard_conforming_strings=on OK" ;;
    off) echo "  preflight $source: standard_conforming_strings=off - fixing (cross-version restore hygiene)"
         [ "$DRY" -eq 1 ] && { echo "  [dry] would ALTER SYSTEM SET standard_conforming_strings = on; SELECT pg_reload_conf();"; return; }
         src_psql "$source" -c "ALTER SYSTEM SET standard_conforming_strings = on;"
         src_psql "$source" -c "SELECT pg_reload_conf();" ;;
    *)   echo "  preflight $source: could not read standard_conforming_strings (got: $s)" >&2; return 1 ;;
  esac
}

dump_db () {
  local source="$1" sdb="$2" out="$3"
  source_preflight "$source"
  if [[ "$source" == internal:* ]]; then
    local ns pod suvar su
    read -r ns pod <<<"$(internal_pod "$source")"
    suvar="$(src_su_var "${source#internal:}")"; su="$(getvar "$suvar")"
    [ -z "$su" ] && { echo "missing $suvar in creds.env" >&2; exit 1; }
    [ "$DRY" -eq 1 ] && { echo "  [dry] kubectl exec $ns/$pod pg_dump -d $sdb -> $out"; return; }
    echo "  dumping (in-cluster) $source/$sdb -> $out"
    kubectl --kubeconfig "$K3S_KUBECONFIG" exec -i "$pod" -n "$ns" \
      -- env PGPASSWORD="$su" pg_dump -h 127.0.0.1 -U postgres -d "$sdb" -Fc -f - > "$out"
  else
    local suvar su
    suvar="$(src_su_var "$source")"; su="$(getvar "$suvar")"
    [ -z "$su" ] && { echo "missing $suvar in creds.env" >&2; exit 1; }
    [ "$DRY" -eq 1 ] && { echo "  [dry] pg_dump -h $source -d $sdb -> $out"; return; }
    echo "  dumping $source/$sdb -> $out"
    PGPASSWORD="$su" pg_dump -h "$source" -p 5432 -U postgres -d "$sdb" -Fc -f "$out"
  fi
}

restore_db () {
  local source="$1" sdb="$2" tdb="$3" role="$4" out="$5"
  local create_ext="$6"
  if [ "$DRY" -eq 1 ]; then echo "  [dry] create db $tdb (owner $role); pg_restore; $create_ext"; return; fi
  echo "  creating target db $tdb (owner $role)"
  tgt_ps -c "CREATE DATABASE \"$tdb\" OWNER \"$role\";"
  echo "  restoring $tdb"
  PGPASSWORD="$TARGET_SU" pg_restore -h "$TARGET_HOST" -p "$TARGET_PORT" -U postgres -d "$tdb" --no-owner --no-acl "$out"
  # --no-owner/--no-acl so the DB is owned by the role we set; re-own below.
  tgt_ps -c "REASSIGN OWNED BY postgres TO \"$role\";" -d "$tdb" 2>/dev/null || true
  if [ -n "$create_ext" ]; then
    echo "  creating extensions: $create_ext"
    IFS=',' read -ra exts <<<"$create_ext"
    for e in "${exts[@]}"; do
      tgt_ps -c "CREATE EXTENSION IF NOT EXISTS \"$e\";" -d "$tdb"
    done
  fi
}

verify_db () {
  local tdb="$1" role="$2" src_db="$3" source="$4"
  local rpw_var rpw
  rpw_var="ROLE_$role"; rpw="$(getvar "$rpw_var")"
  echo "  verifying $tdb:"
  local tcount
  tcount="$(PGPASSWORD="$TARGET_SU" psql -h "$TARGET_HOST" -p "$TARGET_PORT" -U postgres -d "$tdb" -tA -c "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema');" 2>/dev/null | tr -d ' ')"
  echo "    tables in target: ${tcount:-0}"
  if [ -n "$rpw" ]; then
    if PGPASSWORD="$rpw" psql -h "$TARGET_HOST" -p "$TARGET_PORT" -U "$role" -d "$tdb" -tA -c "select 1;" >/dev/null 2>&1; then
      echo "    role $role can authenticate + query: OK"
    else
      echo "    WARNING: role $role cannot authenticate/query $tdb"
    fi
  else
    echo "    (no ROLE_$role in creds.env - skipping auth check)"
  fi
}

# Verify from the Talos cluster: a probe pod in the Talos cluster must be able
# to reach the consolidated DB (firewall check), and every app role must be
# able to authenticate and query its target database. This is the check that
# proves the migrated (Talos-side) workloads can use the new DB.
verify_talos () {
  [ -n "$TALOS_KUBECONFIG" ] || { echo "TALOS_KUBECONFIG not set (path to the Talos kubeconfig)" >&2; exit 1; }
  local ns="dbcons-verify" pod="dbcons-probe"
  kubectl --kubeconfig "$TALOS_KUBECONFIG" create namespace "$ns" --dry-run=client -o yaml \
    | kubectl --kubeconfig "$TALOS_KUBECONFIG" apply -f - >/dev/null
  kubectl --kubeconfig "$TALOS_KUBECONFIG" -n "$ns" run "$pod" --image=postgres:18 \
    --restart=Never --command -- sleep 3600 >/dev/null
  kubectl --kubeconfig "$TALOS_KUBECONFIG" -n "$ns" wait --for=condition=Ready pod/"$pod" --timeout=180s >/dev/null
  echo "== verifying from the Talos cluster (pod $ns/$pod) =="
  local failures=0
  if kubectl --kubeconfig "$TALOS_KUBECONFIG" -n "$ns" exec "$pod" -- \
      pg_isready -h "$TARGET_HOST" -p "$TARGET_PORT" -U postgres >/dev/null 2>&1; then
    echo "  tcp $TARGET_HOST:$TARGET_PORT: OK"
  else
    echo "  tcp $TARGET_HOST:$TARGET_PORT: UNREACHABLE from Talos pod CIDR"
    failures=$((failures+1))
  fi
  local tdb role source sdb size notes
  while IFS=$'\t' read -r tdb role source sdb size notes; do
    [ -z "${tdb:-}" ] && continue
    [[ "$tdb" == \#* ]] && continue
    [ "$tdb" = "target_db" ] && continue
    [ -n "$ONLY_DB" ] && [ "$tdb" != "$ONLY_DB" ] && continue
    local rpw_var rpw
    rpw_var="ROLE_$role"; rpw="$(getvar "$rpw_var")"
    if [ -z "$rpw" ]; then
      echo "  $tdb (role $role): SKIPPED (no ROLE_$role in creds.env)"
      continue
    fi
    if kubectl --kubeconfig "$TALOS_KUBECONFIG" -n "$ns" exec "$pod" -- \
        env PGPASSWORD="$rpw" psql -h "$TARGET_HOST" -p "$TARGET_PORT" -U "$role" -d "$tdb" \
        -tA -c "select 1;" >/dev/null 2>&1; then
      echo "  $tdb (role $role): OK"
    else
      echo "  $tdb (role $role): FAIL"
      failures=$((failures+1))
    fi
  done < "$MANIFEST"
  kubectl --kubeconfig "$TALOS_KUBECONFIG" delete namespace "$ns" --wait=false >/dev/null
  if [ "$failures" -gt 0 ]; then
    echo "== verify-talos: $failures failure(s) =="
    return 1
  fi
  echo "== verify-talos: all OK =="
}

main () {
  local created=0
  echo "== consolidated postgres target: $TARGET_HOST:$TARGET_PORT =="
  [ "$DRY" -eq 0 ] && [ "$VERIFY_ONLY" -eq 0 ] && [ "$VERIFY_TALOS" -eq 0 ] && \
    { PGPASSWORD="$TARGET_SU" pg_isready -h "$TARGET_HOST" -p "$TARGET_PORT" -U postgres >/dev/null || { echo "target not ready"; exit 1; }; }

  # Extensions required per database name (only immich needs them explicitly).
  ext_for () { case "$1" in immich) echo "vector,cube,earthdistance,pg_trgm,unaccent,uuid-ossp";; *) echo "";; esac; }

  local -a rows=()
  while IFS=$'\t' read -r tdb role source sdb size notes; do
    [ -z "${tdb:-}" ] && continue
    [[ "$tdb" == \#* ]] && continue
    [ "$tdb" = "target_db" ] && continue
    rows+=("$tdb"$'\t'"$role"$'\t'"$source"$'\t'"$sdb"$'\t'"$size"$'\t'"$notes")
  done < "$MANIFEST"

  [ ${#rows[@]} -eq 0 ] && { echo "no rows in manifest"; exit 1; }

  if [ "$VERIFY_TALOS" -eq 1 ]; then
    verify_talos
    return
  fi

  local total=${#rows[@]} i=0
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r tdb role source sdb size notes <<<"$row"
    [ -n "$ONLY_DB" ] && [ "$tdb" != "$ONLY_DB" ] && continue
    i=$((i+1))
    echo "[$i/$total] $tdb  (source $source/$sdb, ~$size, role $role)"
    [ "$VERIFY_ONLY" -eq 1 ] && { verify_db "$tdb" "$role" "$sdb" "$source"; continue; }
    local out="$WORKDIR/$tdb.dump"
    dump_db "$source" "$sdb" "$out"
    if [ "$DRY" -eq 0 ] && [ -s "$out" ]; then
      local ext; ext="$(ext_for "$tdb")"
      restore_db "$source" "$sdb" "$tdb" "$role" "$out" "$ext"
      verify_db "$tdb" "$role" "$sdb" "$source"
    fi
  done
  echo "done. workdir: $WORKDIR (kept for inspection)"
}
main "$@"
