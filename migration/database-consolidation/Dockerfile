# Consolidated PostgreSQL image: PostgreSQL 18 + pgvector + vchord.
#
# Bundles every extension the source databases use, plus the "future
# requirement" vchord extension, into a single reproducible image:
#   - postgres:18 base image (PGDG)
#   - postgresql-18-pgvector  -> the `vector` extension (immich, honcho)
#   - postgresql-18-vchord    -> the `vchord` extension (VectorChord). PG18 is
#                                the newest major the VectorChord project
#                                supports, so we take its prebuilt deb.
#   - cube, earthdistance, pg_trgm, unaccent, uuid-ossp, btree_gin -> the
#     postgres:18 contrib modules (shipped in the base image)
#
# The init SQL is baked into /docker-entrypoint-initdb.d/ so a fresh instance
# creates the extensions on first start. docker-compose also mounts ./initdb
# over this path (ro), which takes precedence and lets the SQL evolve without
# rebuilding the image.

FROM postgres:19

ENV DEBIAN_FRONTEND=noninteractive

# pgvector (`vector`) + vchord. The vchord deb is pinned by SHA256 so the
# build is reproducible and verifiable. `vector` is installed first because
# `vchord` depends on it.
#
# NOTE: vchord must be preloaded via `shared_preload_libraries` (set in the
# docker-compose `command`), otherwise `CREATE EXTENSION vchord` fails with
# "vchord must be loaded via shared_preload_libraries".
RUN apt-get update && apt-get install -y --no-install-recommends \
        postgresql-18-pgvector \
        curl ca-certificates \
    && curl -fsSL -o /tmp/vchord.deb \
        https://github.com/supervc-stack/VectorChord/releases/download/1.1.1/postgresql-18-vchord_1.1.1-1_amd64.deb \
    && echo "7637a18a97157db8d904bb7093e5ce33b6a395c0acac9ae6b660032f3d57a33e  /tmp/vchord.deb" | sha256sum -c - \
    && dpkg -i /tmp/vchord.deb \
    && rm /tmp/vchord.deb \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Bake the extension-init SQL into the image (first-start bootstrap). The
# compose service mounts ./initdb over this path, which takes precedence.
RUN set -eux; \
    { \
        echo 'CREATE EXTENSION IF NOT EXISTS "uuid-ossp";'; \
        echo 'CREATE EXTENSION IF NOT EXISTS cube;'; \
        echo 'CREATE EXTENSION IF NOT EXISTS earthdistance;'; \
        echo 'CREATE EXTENSION IF NOT EXISTS pg_trgm;'; \
        echo 'CREATE EXTENSION IF NOT EXISTS unaccent;'; \
        echo 'CREATE EXTENSION IF NOT EXISTS vector;'; \
        echo 'CREATE EXTENSION IF NOT EXISTS vchord;'; \
        echo 'CREATE EXTENSION IF NOT EXISTS btree_gin;'; \
    } > /docker-entrypoint-initdb.d/01-init-extensions.sql
