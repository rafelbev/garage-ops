-- Example role bootstrap for the consolidated PostgreSQL instance.
--
-- The REAL roles.sql (with live passwords) is generated LOCALLY and placed in
-- ./initdb/roles.sql on the TrueNAS host. It is NEVER committed to git.
-- Each role's password MUST match the password the consuming app already uses,
-- so that migrating only changes the DB *host*, not the credentials.
--
-- Run by the image on first start via /docker-entrypoint-initdb.d/roles.sql.
-- Idempotency: CREATE ROLE ... IF NOT EXISTS is not available for roles in PG,
-- so the initdb script only runs on an empty data dir (first start). For a
-- re-run against a populated server, use the guarded form shown at the bottom.

-- One role per application database owner (passwords redacted here).
-- DO/CREATE ... WITH LOGIN is the idempotent form safe for re-runs.
DO $$ BEGIN
  CREATE ROLE gitea        LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE firefly      LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE authelia     LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE wiki         LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE homeassistant LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE homeassistant_121 LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE dendrite     LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE whatsapp     LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE mealie       LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE planka       LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE mastodon     LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE penpot_129   LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE lidarr       LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE sonarr       LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE piped        LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE litellm      LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE penpot       LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE ghostfolio   LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE acmedns      LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE n8n          LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE honcho       LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE immich       LOGIN PASSWORD '<REDACTED>';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Extensions that specific databases require (created after their DB exists,
-- see migrate.sh). The image bundles all of these:
--   vector, cube, earthdistance, pg_trgm, unaccent, uuid-ossp, plpgsql
