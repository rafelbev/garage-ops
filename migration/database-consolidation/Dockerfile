FROM postgres:19

# Install pgvector from the pre-configured PostgreSQL (PGDG) apt repository.
# The other 5 extensions are standard contrib modules already included in postgres:19.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        postgresql-19-pgvector \
    && rm -rf /var/lib/apt/lists/*

# Create an initialization script to enable all extensions on first startup.
# Note: "cube" must be created before "earthdistance", and "uuid-ossp" requires double quotes.
RUN printf '%s\n' \
    'CREATE EXTENSION IF NOT EXISTS vector;' \
    'CREATE EXTENSION IF NOT EXISTS cube;' \
    'CREATE EXTENSION IF NOT EXISTS earthdistance;' \
    'CREATE EXTENSION IF NOT EXISTS pg_trgm;' \
    'CREATE EXTENSION IF NOT EXISTS unaccent;' \
    'CREATE EXTENSION IF NOT EXISTS "uuid-ossp";' \
    > /docker-entrypoint-initdb.d/01-init-extensions.sql
