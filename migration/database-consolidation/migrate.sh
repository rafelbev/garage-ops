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
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$HERE/manifest.tsv"
CREDS="${CREDS_FILE:-$HERE/creds.env}"
TARGET_HOST="${TARGET_HOST:-172.20.17.150}"
TARGET_PORT="${TARGET_PORT:-5432}"
WORKDIR="$(mktemp -d /tmp/dbcons.XXXXXX)"
K3S_KUBECONFIG="${K3S_KUBECONFIG:-$HOME/home.yaml}"

DRY=0; VERIFY_ONLY=0; ONLY_DB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --verify-only) VERIFY_ONLY=1 ;;
    --db) ONLY_DB="${2:?--db needs a value}"; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
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

# Map an internal source to "namespace pod"
internal_pod () {
  case "$1" in
    internal:pgvector) echo "postgresql16-pgvector postgresql-pgvector-5d948c47b8-lfl7j" ;;
    internal:immich)   echo "immich immich-postgres-1" ;;
    *) return 1 ;;
  esac
}

dump_db () {
  local source="$1" sdb="$2" out="$3"
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

main () {
  local created=0
  echo "== consolidated postgres target: $TARGET_HOST:$TARGET_PORT =="
  [ "$DRY" -eq 0 ] && [ "$VERIFY_ONLY" -eq 0 ] && \
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
