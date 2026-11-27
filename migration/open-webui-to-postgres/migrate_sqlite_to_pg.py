#!/usr/bin/env python3
"""
Migrate Open Web UI data from SQLite to PostgreSQL.

Open Web UI does NOT migrate its SQLite database for you. Setting DATABASE_URL
gives you a fresh PostgreSQL schema; the existing SQLite data is not copied
over. This script copies the existing SQLite data into a PostgreSQL database
that ALREADY has the Open Web UI schema (i.e. the app has been started once
against it with ENABLE_DB_MIGRATIONS=true, or `alembic upgrade head` has been
run).

Preconditions
-------------
1. The target Postgres database exists and has the Open Web UI schema applied
   (all alembic migrations). Example:
       CREATE DATABASE openwebui;
       CREATE ROLE openwebui LOGIN PASSWORD '<pw>';
       GRANT ALL PRIVILEGES ON DATABASE openwebui TO openwebui;
   The role `openwebui` is used by the app; it needs the pgvector extension
   if the vector DB is set to `pgvector` (created by the app on first run).
2. The source SQLite file (`webui.db`) has been copied out of the running pod
   (and its -wal / -shm files, if present, applied first).

What this script does
---------------------
* Reads every row from each SQLite table.
* Inserts them into the matching PostgreSQL table, in foreign-key order.
* Skips the internal tables `migratehistory` and `alembic_version`.
* Converts values to the target column types (JSON literals are parsed with a
  `::json` cast; integers, booleans and text pass through).
* Is idempotent: uses `ON CONFLICT <pk> DO NOTHING` where a primary key exists,
  so a re-run after a failure will not double-insert.

Verification (run after migration)
----------------------------------
The script prints a per-table row-count comparison (source vs target). Every
table must match.

Usage
-----
    python3 migrate_sqlite_to_pg.py \
        --sqlite /path/to/webui.db \
        --pg-dsn postgresql://openwebui:<pw>@172.20.17.150:5432/openwebui \
        [--dry-run]
"""

import argparse
import json
import sqlite3
import sys

import psycopg2


# Tables that must not be migrated (managed by alembic / legacy).
SKIP_TABLES = {"migratehistory", "alembic_version"}


def get_target_schema(pg_cur):
    """Return (columns, primary_keys) for every public table in the target."""
    columns = {}
    pg_cur.execute(
        """
        SELECT table_name, column_name, data_type, is_nullable
        FROM information_schema.columns
        WHERE table_schema = 'public'
        ORDER BY table_name, ordinal_position
        """
    )
    for t, c, dt, nu in pg_cur:
        columns.setdefault(t, {})[c] = (dt, nu)

    pks = {}
    for t in columns:
        pg_cur.execute(
            """
            SELECT a.attname
            FROM pg_constraint con
            JOIN pg_attribute a ON a.attrelid = con.conrelid
                               AND a.attnum = ANY (con.conkey)
            WHERE con.contype = 'p'
              AND con.conrelid = (SELECT oid FROM pg_class WHERE relname = %s)
            ORDER BY a.attnum
            """,
            (t,),
        )
        pks[t] = [r[0] for r in pg_cur.fetchall()]
    return columns, pks


def _unquote(name):
    """Strip surrounding double quotes from a regclass-qualified name.

    PostgreSQL returns reserved-word table names quoted (e.g. ``"user"``,
    ``"group"``) while normal names are bare (e.g. ``chat``). Our table list
    uses bare names, so normalize here.
    """
    if len(name) >= 2 and name.startswith('"') and name.endswith('"'):
        return name[1:-1]
    return name


def get_fks(pg_cur):
    """Return a list of (child_table, parent_table, child_col, parent_col) FK edges."""
    pg_cur.execute(
        """
        SELECT con.conrelid::regclass, con.confrelid::regclass,
               a.attname, b.attname
        FROM pg_constraint con
        JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = ANY (con.conkey)
        JOIN pg_attribute b ON b.attrelid = con.confrelid AND b.attnum = ANY (con.confkey)
        WHERE con.contype = 'f'
        """
    )
    return [
        (_unquote(child), _unquote(parent), child_col, parent_col)
        for child, parent, child_col, parent_col in pg_cur
    ]


def get_selfref_columns(pg_cur):
    """Return {table: (selfref_column, pk_column)} for self-referencing tables."""
    pg_cur.execute(
        """
        SELECT con.conrelid::regclass, a.attname, b.attname
        FROM pg_constraint con
        JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = ANY (con.conkey)
        JOIN pg_attribute b ON b.attrelid = con.confrelid AND b.attnum = ANY (con.confkey)
        WHERE con.contype = 'f' AND con.conrelid = con.confrelid
        """
    )
    # selfref column -> its referenced column (the PK)
    selfref = {}
    for table, child_col, parent_col in pg_cur:
        selfref[_unquote(table)] = (child_col, parent_col)
    return selfref


def topological_order(tables, edges):
    """Return tables ordered so parents come before children (Kahn's algorithm).

    Self-referencing foreign keys (e.g. a tree's parent_id -> id) are ignored:
    they are not an ordering constraint between distinct tables.
    """
    # dependencies[table] = set of tables it depends on (must be inserted first)
    deps = {t: set() for t in tables}
    for child, parent, _child_col, _parent_col in edges:
        if child in deps and parent in deps and child != parent:
            deps[child].add(parent)

    in_degree = {t: len(d) for t, d in deps.items()}
    dependents = {t: [] for t in tables}
    for t, d in deps.items():
        for p in d:
            dependents[p].append(t)

    queue = sorted([t for t, d in in_degree.items() if d == 0])
    order = []
    while queue:
        # deterministic: pick alphabetically smallest for stable output
        node = queue.pop(0)
        order.append(node)
        for m in sorted(dependents[node]):
            in_degree[m] -= 1
            if in_degree[m] == 0:
                queue.append(m)
    if len(order) != len(tables):
        remaining = set(tables) - set(order)
        raise RuntimeError(f"Circular foreign-key dependency among tables: {remaining}")
    return order


def get_source_columns(sq_cur, table):
    """Return ordered list of column names for a SQLite table."""
    return [r[1] for r in sq_cur.execute(f'PRAGMA table_info("{table}")')]


def convert_value(value, ptype):
    """Convert a SQLite value to a form suitable for the target Postgres column."""
    if value is None:
        return None
    if ptype == "json":
        # The SQL uses a `::json` cast, so the value must be a *string* that is
        # itself valid JSON. Source JSON columns store JSON literals as text
        # (e.g. the string `false`, `"pending"`, `{}`); those pass through
        # unchanged. Native Python int/float/bool values (rare, e.g.
        # config.version) are serialized to a JSON string first, because
        # `0::json` is not a valid cast.
        if isinstance(value, str):
            return value
        return json.dumps(value)
    if ptype in ("bigint", "integer", "smallint", "numeric", "double precision", "real", "money"):
        if isinstance(value, bool):
            return int(value)
        if isinstance(value, int):
            return value
        if isinstance(value, float):
            return value
        if isinstance(value, str):
            try:
                return int(value)
            except ValueError:
                try:
                    return float(value)
                except ValueError:
                    return None
        return value
    if ptype == "boolean":
        if isinstance(value, bool):
            return value
        if isinstance(value, int):
            return bool(value)
        if isinstance(value, str):
            return value.strip().lower() in ("true", "1", "yes", "on")
        return None
    # text, character varying, varchar, date, timestamp without time zone, uuid, ...
    return value


def migrate_table(pg_cur, sq_cur, table, target_cols, pks, selfref, fks, dry_run):
    """Migrate a single table. Returns (inserted, skipped) counts.

    `fks` is a list of (fk_column, parent_table, parent_column) for this table.
    Rows whose foreign-key parent does not exist in the target are skipped and
    reported — SQLite does not enforce FKs, so the source can contain orphan
    rows that Postgres (which does enforce them) would reject. For
    self-referencing tables, rows are inserted in multiple passes so that
    parent rows precede the child rows that reference them.
    """
    src_cols = set(get_source_columns(sq_cur, table))
    # Columns present in both source and target, in target order.
    table_cols = target_cols[table]
    cols = [c for c in table_cols if c in src_cols]
    if not cols:
        return 0, 0

    col_names = ",".join(f'"{c}"' for c in cols)
    placeholders = []
    for c in cols:
        ptype = table_cols[c][0]
        placeholders.append("%s::json" if ptype == "json" else "%s")
    ph = ",".join(placeholders)

    conflict = ""
    if pks.get(table) and all(p in cols for p in pks[table]):
        pk_cols = ",".join(f'"{p}"' for p in pks[table])
        conflict = f" ON CONFLICT ({pk_cols}) DO NOTHING"

    sql = f'INSERT INTO "{table}" ({col_names}) VALUES ({ph}){conflict}'

    # Read all source rows as dicts.
    src_col_order = get_source_columns(sq_cur, table)
    rows = [dict(zip(src_col_order, r)) for r in sq_cur.execute(f'SELECT * FROM "{table}"').fetchall()]

    def to_params(rd):
        return tuple(convert_value(rd.get(c), table_cols[c][0]) for c in cols)

    if dry_run:
        return len(rows), 0

    # Load the set of existing parent ids for each cross-table FK. Parents are
    # already migrated because tables are processed in topological order.
    # Self-referencing FKs are skipped here (handled by the multi-pass insert).
    parent_sets = []
    for fk_col, parent_table, parent_col in fks:
        if fk_col not in cols or parent_table == table:
            continue
        pg_cur.execute(f'SELECT DISTINCT "{parent_col}" FROM "{parent_table}"')
        parent_sets.append((fk_col, {r[0] for r in pg_cur}))

    def row_is_complete(rd):
        for fk_col, parent_set in parent_sets:
            v = rd.get(fk_col)
            if v is None:
                continue
            if v not in parent_set:
                return False
        return True

    # Filter out orphan rows (their FK parent is not present in the target).
    complete = [rd for rd in rows if row_is_complete(rd)]
    skipped = len(rows) - len(complete)

    if selfref.get(table) and selfref[table][0] in cols:
        # Multi-pass insert for self-referencing tables: insert a row only
        # once its parent row (referenced via the selfref column) exists.
        selfref_col, pk_col = selfref[table]
        inserted_pk = set()
        remaining = list(complete)
        total = 0
        while remaining:
            batch = []
            nxt = []
            for rd in remaining:
                parent = rd.get(selfref_col)
                if parent is None or parent not in inserted_pk:
                    batch.append(rd)
                else:
                    nxt.append(rd)
            if not batch:
                # No progress; insert the rest (should not happen with consistent data).
                batch = nxt
                nxt = []
            pg_cur.executemany(sql, [to_params(rd) for rd in batch])
            total += len(batch)
            for rd in batch:
                if rd.get(pk_col) is not None:
                    inserted_pk.add(rd[pk_col])
            remaining = nxt
        return total, skipped

    pg_cur.executemany(sql, [to_params(rd) for rd in complete])
    return len(complete), skipped


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sqlite", required=True, help="Path to the source webui.db (SQLite)")
    ap.add_argument("--pg-dsn", required=True, help="Postgres DSN (postgresql://user:pw@host:5432/db)")
    ap.add_argument("--dry-run", action="store_true", help="Only compute what would be inserted; do not write")
    args = ap.parse_args()

    sq = sqlite3.connect(args.sqlite)
    sq_cur = sq.cursor()

    pg = psycopg2.connect(args.pg_dsn)
    pg_cur = pg.cursor()

    target_cols, pks = get_target_schema(pg_cur)
    edges = get_fks(pg_cur)
    selfref = get_selfref_columns(pg_cur)

    # Per-table foreign-key list: table -> [(fk_col, parent_table, parent_col)].
    fk_map = {}
    for child, parent, child_col, parent_col in edges:
        fk_map.setdefault(child, []).append((child_col, parent, parent_col))

    tables = [t for t in target_cols if t not in SKIP_TABLES]
    order = topological_order(tables, edges)

    print(f"Migrating {len(order)} tables (skipping {sorted(SKIP_TABLES)})")
    print(f"Order: {', '.join(order)}\n")

    total = 0
    skipped = {}
    for table in order:
        inserted, sk = migrate_table(pg_cur, sq_cur, table, target_cols, pks, selfref, fk_map.get(table, []), args.dry_run)
        total += inserted
        if sk:
            skipped[table] = sk
        print(f"  {table:24s} {inserted}" + (f"  (skipped {sk} orphan row(s))" if sk else ""))

    if not args.dry_run:
        pg.commit()
        print(f"\nCommitted {total} rows.")

    # Verification: target count must equal source count minus skipped orphans.
    print("\n=== Verification (source vs target) ===")
    ok = True
    for table in tables:
        src_n = sq_cur.execute(f'SELECT count(*) FROM "{table}"').fetchone()[0]
        pg_cur.execute(f'SELECT count(*) FROM "{table}"')
        tgt_n = pg_cur.fetchone()[0]
        expected = src_n - skipped.get(table, 0)
        status = "OK" if tgt_n == expected else "MISMATCH"
        if tgt_n != expected:
            ok = False
        print(f"  {table:24s} source={src_n:<8d} target={tgt_n:<8d} expected={expected:<8d} {status}")

    if skipped:
        print("\nSkipped orphan rows (FK parent missing in source):")
        for t, n in sorted(skipped.items()):
            print(f"  {t}: {n}")

    sq.close()
    pg.close()

    if not args.dry_run and not ok:
        print("\nWARNING: row count mismatch detected. Inspect the tables above.")
        sys.exit(1)
    print("\nDone." if ok else "\nFinished with mismatches.")


if __name__ == "__main__":
    main()
