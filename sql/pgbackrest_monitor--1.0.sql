-- pgbackrest_monitor 1.0
-- PostgreSQL extension exposing pgBackRest backup, archive and repository health through SQL.
-- The extension owns the schema and data model; an external collector feeds it by calling the
-- SECURITY DEFINER functions in section 6.  Nothing here executes pgBackRest.

\echo Use "CREATE EXTENSION pgbackrest_monitor" to load this file. \quit

------------------------------------------------------------------------------------------------
-- 0. Roles (cluster-wide, created only if missing; they survive DROP EXTENSION - see SECURITY.md)
------------------------------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'pgbackrest_monitor_collector') THEN
        CREATE ROLE pgbackrest_monitor_collector NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'pgbackrest_monitor_reader') THEN
        CREATE ROLE pgbackrest_monitor_reader NOLOGIN;
    END IF;
END
$$;

------------------------------------------------------------------------------------------------
-- 1. Types and clock
------------------------------------------------------------------------------------------------
CREATE TYPE pgbackrest_monitor.health_component AS (
    status      text,   -- OK | WARNING | CRITICAL | UNKNOWN
    reason_code text,   -- machine readable, stable identifier
    message     text    -- human readable diagnostic
);

-- Compact, IntervalStyle-independent rendering of durations for diagnostic messages.
CREATE FUNCTION pgbackrest_monitor.fmt_interval(p_iv interval) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_iv IS NULL THEN 'n/a' ELSE
        COALESCE(NULLIF(concat_ws(' ',
            CASE WHEN d <> 0 THEN d || 'd' END,
            CASE WHEN h <> 0 THEN h || 'h' END,
            CASE WHEN m <> 0 THEN m || 'm' END,
            CASE WHEN s <> 0 OR (d = 0 AND h = 0 AND m = 0) THEN s || 's' END), ''), '0s') END
    FROM (SELECT floor(extract(epoch FROM p_iv))::bigint AS total) t0,
         LATERAL (SELECT total / 86400 AS d, (total % 86400) / 3600 AS h, (total % 3600) / 60 AS m, total % 60 AS s) t1
$$;

-- Constructor used by the evaluate_* functions.
CREATE FUNCTION pgbackrest_monitor.hc(p_status text, p_reason_code text, p_message text)
RETURNS pgbackrest_monitor.health_component
LANGUAGE sql IMMUTABLE AS $$ SELECT ROW(p_status, p_reason_code, p_message)::pgbackrest_monitor.health_component $$;

-- All age calculations go through clock() so tests can pin "now" with
--   SET pgbackrest_monitor.clock_override = '2026-10-26 12:00:00+00';
CREATE FUNCTION pgbackrest_monitor.clock() RETURNS timestamptz
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(NULLIF(current_setting('pgbackrest_monitor.clock_override', true), '')::timestamptz, now())
$$;

CREATE FUNCTION pgbackrest_monitor.health_rank(p_status text) RETURNS int
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_status WHEN 'CRITICAL' THEN 3 WHEN 'WARNING' THEN 2 WHEN 'UNKNOWN' THEN 1 WHEN 'OK' THEN 0 ELSE 1 END
$$;

-- Worst status wins: CRITICAL > WARNING > UNKNOWN > OK.
CREATE FUNCTION pgbackrest_monitor.worst_status(p_statuses text[]) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE(
        (SELECT s FROM unnest(p_statuses) s ORDER BY pgbackrest_monitor.health_rank(s) DESC LIMIT 1),
        'UNKNOWN')
$$;

------------------------------------------------------------------------------------------------
-- 2. Configuration
------------------------------------------------------------------------------------------------
-- Built-in defaults.  Overrides live in config (global) and stanza_setting (per stanza).
CREATE FUNCTION pgbackrest_monitor.default_settings()
RETURNS TABLE (key text, value text, value_type text, description text)
LANGUAGE sql IMMUTABLE AS $$
    VALUES
    ('backup_max_age_warning',          '26 hours',   'interval', 'WARNING when the latest good backup is older than this'),
    ('backup_max_age_critical',         '50 hours',   'interval', 'CRITICAL when the latest good backup is older than this'),
    ('full_backup_max_age_warning',     '',           'interval', 'WARNING when the latest good full backup is older than this (empty = disabled)'),
    ('archive_failing_critical_after',  '15 minutes', 'interval', 'When PostgreSQL archiving is failing, escalate to CRITICAL once the last success is older than this'),
    ('archive_lag_segments_warning',    '8',          'integer',  'WARNING when this many completed WAL segments are waiting for the PostgreSQL archiver'),
    ('archive_lag_segments_critical',   '64',         'integer',  'CRITICAL when this many completed WAL segments are waiting for the PostgreSQL archiver'),
    ('archive_stale_warning',           '1 hour',     'interval', 'WARNING when WAL is waiting to be archived and the last successful archive is older than this'),
    ('archive_repo_gap_segments_warning','16',        'integer',  'WARNING when the repository archive max is this many segments behind pg_stat_archiver.last_archived_wal'),
    ('repo_no_backups_severity',        'WARNING',    'status',   'Severity when a repository reports "no valid backups" (OK, WARNING or CRITICAL)'),
    ('collector_heartbeat_warning',     '10 minutes', 'interval', 'WARNING when no collector heartbeat for this long'),
    ('collector_heartbeat_critical',    '30 minutes', 'interval', 'CRITICAL when no collector heartbeat for this long'),
    ('data_stale_warning',              '15 minutes', 'interval', 'WARNING when the last successful stanza observation is older than this'),
    ('data_stale_critical',             '1 hour',     'interval', 'CRITICAL when the last successful stanza observation is older than this'),
    ('retention_runs',                  '7 days',     'interval', 'Delete collection_run rows older than this'),
    ('retention_raw_output',            '2 days',     'interval', 'Drop stored raw JSON from collection_run rows older than this (latest success per stanza is kept)'),
    ('retention_errors',                '30 days',    'interval', 'Delete error_history rows older than this'),
    ('retention_operations',            '30 days',    'interval', 'Delete operation_observation rows older than this'),
    ('retention_archiver_samples',      '7 days',     'interval', 'Delete pg_archiver_sample rows older than this (latest is kept)'),
    ('retention_expired_backups',       '365 days',   'interval', 'Delete backup rows no longer present in the repository after this long')
$$;

CREATE FUNCTION pgbackrest_monitor.is_known_setting(p_key text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT EXISTS (SELECT 1 FROM pgbackrest_monitor.default_settings() d WHERE d.key = p_key)
$$;

CREATE TABLE pgbackrest_monitor.config (
    key         text PRIMARY KEY CHECK (pgbackrest_monitor.is_known_setting(key)),
    value       text NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE pgbackrest_monitor.stanza (
    stanza_name         text PRIMARY KEY CHECK (stanza_name ~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$'),
    enabled             boolean NOT NULL DEFAULT true,
    -- Name of the PostgreSQL instance whose pg_stat_archiver is comparable with this stanza's
    -- repository archive: 'local' is the instance holding this extension, other names are
    -- instances the collector samples remotely (e.g. a standby).  NULL = no archiver statistics.
    pg_instance         text DEFAULT 'local',
    registered_at       timestamptz NOT NULL DEFAULT now(),
    collection_interval interval,
    description         text
);

CREATE TABLE pgbackrest_monitor.stanza_setting (
    stanza_name text NOT NULL REFERENCES pgbackrest_monitor.stanza ON DELETE CASCADE,
    key         text NOT NULL CHECK (pgbackrest_monitor.is_known_setting(key)),
    value       text NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (stanza_name, key)
);

CREATE FUNCTION pgbackrest_monitor.setting(p_stanza text, p_key text) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT value FROM pgbackrest_monitor.stanza_setting WHERE stanza_name = p_stanza AND key = p_key),
        (SELECT value FROM pgbackrest_monitor.config WHERE key = p_key),
        (SELECT value FROM pgbackrest_monitor.default_settings() d WHERE d.key = p_key))
$$;

CREATE FUNCTION pgbackrest_monitor.setting_interval(p_stanza text, p_key text) RETURNS interval
LANGUAGE sql STABLE AS $$
    SELECT NULLIF(pgbackrest_monitor.setting(p_stanza, p_key), '')::interval
$$;

CREATE FUNCTION pgbackrest_monitor.setting_bigint(p_stanza text, p_key text) RETURNS bigint
LANGUAGE sql STABLE AS $$
    SELECT NULLIF(pgbackrest_monitor.setting(p_stanza, p_key), '')::bigint
$$;

-- Validating setter.  p_stanza NULL sets the global override.
CREATE FUNCTION pgbackrest_monitor.set_setting(p_key text, p_value text, p_stanza text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_type text;
BEGIN
    SELECT value_type INTO v_type FROM pgbackrest_monitor.default_settings() d WHERE d.key = p_key;
    IF v_type IS NULL THEN
        RAISE EXCEPTION 'unknown setting "%"', p_key USING ERRCODE = '22023';
    END IF;
    IF p_value <> '' THEN
        CASE v_type
            WHEN 'interval' THEN PERFORM p_value::interval;
            WHEN 'integer'  THEN PERFORM p_value::bigint;
            WHEN 'status'   THEN
                IF p_value NOT IN ('OK', 'WARNING', 'CRITICAL') THEN
                    RAISE EXCEPTION 'setting "%" must be OK, WARNING or CRITICAL', p_key USING ERRCODE = '22023';
                END IF;
            ELSE NULL;
        END CASE;
    END IF;
    IF p_stanza IS NULL THEN
        INSERT INTO pgbackrest_monitor.config (key, value) VALUES (p_key, p_value)
        ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
    ELSE
        INSERT INTO pgbackrest_monitor.stanza_setting (stanza_name, key, value) VALUES (p_stanza, p_key, p_value)
        ON CONFLICT (stanza_name, key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
    END IF;
END
$$;

CREATE FUNCTION pgbackrest_monitor.unset_setting(p_key text, p_stanza text DEFAULT NULL) RETURNS void
LANGUAGE sql AS $$
    DELETE FROM pgbackrest_monitor.config WHERE key = p_key AND p_stanza IS NULL;
    DELETE FROM pgbackrest_monitor.stanza_setting WHERE key = p_key AND stanza_name = p_stanza;
$$;

-- Effective settings, resolved per stanza.
CREATE VIEW pgbackrest_monitor.effective_settings AS
SELECT s.stanza_name, d.key, pgbackrest_monitor.setting(s.stanza_name, d.key) AS value, d.value_type,
       CASE WHEN ss.key IS NOT NULL THEN 'stanza' WHEN c.key IS NOT NULL THEN 'global' ELSE 'default' END AS source,
       d.description
FROM pgbackrest_monitor.stanza s
CROSS JOIN pgbackrest_monitor.default_settings() d
LEFT JOIN pgbackrest_monitor.config c ON c.key = d.key
LEFT JOIN pgbackrest_monitor.stanza_setting ss ON ss.stanza_name = s.stanza_name AND ss.key = d.key;

------------------------------------------------------------------------------------------------
-- 3. Data model
------------------------------------------------------------------------------------------------
-- One row per collector process instance.  Freshness of last_heartbeat tells whether it is alive.
CREATE TABLE pgbackrest_monitor.collector (
    collector_id        text PRIMARY KEY,
    hostname            text,
    pid                 integer,
    collector_version   text,
    pgbackrest_version  text,          -- reported by `pgbackrest version` on the collector host
    started_at          timestamptz NOT NULL,
    last_heartbeat      timestamptz NOT NULL,
    collection_interval interval,
    stanzas             text[] NOT NULL DEFAULT '{}'
);

-- Every pgBackRest invocation made by the collector, successful or not (the collector's own
-- execution record; this is the only reliable source for "what did monitoring run and when").
CREATE TABLE pgbackrest_monitor.collection_run (
    run_id          bigserial PRIMARY KEY,
    collector_id    text NOT NULL,
    stanza_name     text NOT NULL REFERENCES pgbackrest_monitor.stanza ON DELETE CASCADE,
    command         text NOT NULL,                      -- pgBackRest command, e.g. 'info'
    started_at      timestamptz NOT NULL,
    finished_at     timestamptz NOT NULL,
    exit_code       integer,                            -- NULL when the process never ran/finished
    outcome         text NOT NULL CHECK (outcome IN
                        ('success', 'command_failed', 'timeout', 'binary_missing', 'permission_denied',
                         'parse_failed', 'validation_failed', 'skipped_locked')),
    error_message   text,                               -- redacted by the collector
    raw_output      jsonb                               -- parsed info JSON (authoritative pgBackRest output)
);
CREATE INDEX collection_run_stanza_started_idx ON pgbackrest_monitor.collection_run (stanza_name, started_at DESC);
CREATE INDEX collection_run_started_idx ON pgbackrest_monitor.collection_run (started_at);

-- Latest successfully observed state per stanza (last known good; only updated on success).
CREATE TABLE pgbackrest_monitor.stanza_state (
    stanza_name             text PRIMARY KEY REFERENCES pgbackrest_monitor.stanza ON DELETE CASCADE,
    observed_at             timestamptz NOT NULL,
    run_id                  bigint,
    status_code             integer NOT NULL,   -- pgBackRest stanza status code (0 ok ... 99 other)
    status_message          text NOT NULL,
    cipher                  text,
    backup_lock_held        boolean,            -- status.lock.backup.held  (backup or expire running)
    backup_lock_size        bigint,
    backup_lock_size_cplt   bigint,
    backup_lock_pct_cplt    numeric(5,2),
    restore_lock_held       boolean,            -- status.lock.restore.held
    restore_lock_size       bigint,
    restore_lock_size_cplt  bigint,
    restore_lock_pct_cplt   numeric(5,2),
    pgbackrest_version_seen text,               -- version that wrote the newest backup (not the installed binary)
    repo_count              integer NOT NULL DEFAULT 0,
    backup_count            integer NOT NULL DEFAULT 0
);

-- Latest observed state per repository.
CREATE TABLE pgbackrest_monitor.repo_state (
    stanza_name         text NOT NULL REFERENCES pgbackrest_monitor.stanza ON DELETE CASCADE,
    repo_key            integer NOT NULL,
    observed_at         timestamptz NOT NULL,
    status_code         integer NOT NULL,       -- pgBackRest repo status code
    status_message      text NOT NULL,
    cipher              text,
    db_id               integer,                -- current (highest) database id seen in this repo
    db_version          text,
    db_system_id        bigint,
    archive_id          text,                   -- archive id of the current database, e.g. '18-1'
    archive_min         text,                   -- oldest WAL segment in the repository archive
    archive_max         text,                   -- newest WAL segment in the repository archive
    has_backup_metadata boolean NOT NULL,
    has_archive_metadata boolean NOT NULL,
    PRIMARY KEY (stanza_name, repo_key)
);

-- All archive ranges (one per database id per repository; prior ids remain after pg_upgrade).
CREATE TABLE pgbackrest_monitor.archive_state (
    stanza_name text NOT NULL REFERENCES pgbackrest_monitor.stanza ON DELETE CASCADE,
    repo_key    integer NOT NULL,
    archive_id  text NOT NULL,
    db_id       integer,
    wal_min     text,
    wal_max     text,
    observed_at timestamptz NOT NULL,
    PRIMARY KEY (stanza_name, repo_key, archive_id)
);

-- Backup history as reported by pgBackRest, kept after a backup disappears (expired).
CREATE TABLE pgbackrest_monitor.backup (
    stanza_name         text NOT NULL REFERENCES pgbackrest_monitor.stanza ON DELETE CASCADE,
    repo_key            integer NOT NULL,
    label               text NOT NULL,
    backup_type         text NOT NULL CHECK (backup_type IN ('full', 'diff', 'incr')),
    started_at          timestamptz NOT NULL,
    stopped_at          timestamptz NOT NULL,
    wal_start           text,
    wal_stop            text,
    lsn_start           pg_lsn,
    lsn_stop            pg_lsn,
    db_id               integer,
    database_size       bigint,     -- info.size: size of the database at backup time
    backup_size         bigint,     -- info.delta: bytes read for this backup
    repo_set_size       bigint,     -- info.repository.size: backup set size in the repository
    repo_backup_size    bigint,     -- info.repository.delta: bytes this backup added to the repository
    prior_label         text,
    reference_labels    text[],
    has_error           boolean,    -- backup.error (pgBackRest >= 2.36); NULL when not reported
    annotation          jsonb,
    pgbackrest_version  text,
    pgbackrest_format   integer,
    first_seen_at       timestamptz NOT NULL,
    last_seen_at        timestamptz NOT NULL,
    present             boolean NOT NULL DEFAULT true,
    expired_detected_at timestamptz,
    PRIMARY KEY (stanza_name, repo_key, label)
);
CREATE INDEX backup_stanza_stopped_idx ON pgbackrest_monitor.backup (stanza_name, stopped_at DESC) WHERE present;

-- Snapshots of PostgreSQL's own archiver statistics (instance wide, not per stanza).
CREATE TABLE pgbackrest_monitor.pg_archiver_sample (
    sample_id           bigserial PRIMARY KEY,
    instance            text NOT NULL DEFAULT 'local',
    sampled_at          timestamptz NOT NULL,
    server_version_num  integer NOT NULL,
    in_recovery         boolean NOT NULL,
    archive_mode        text NOT NULL,
    archive_command_set boolean,        -- NULL when the caller may not read archive_command
    archive_library_set boolean,        -- PostgreSQL >= 15
    wal_segment_size    bigint NOT NULL,
    archived_count      bigint,
    last_archived_wal   text,
    last_archived_time  timestamptz,
    failed_count        bigint,
    last_failed_wal     text,
    last_failed_time    timestamptz,
    stats_reset         timestamptz,
    current_wal_lsn     pg_lsn,          -- pg_current_wal_lsn() on a primary, receive/replay LSN on a standby
    timeline_id         bigint,
    current_wal_file    text,            -- derived from current_wal_lsn + timeline
    wal_bytes           numeric          -- pg_stat_wal.wal_bytes (PostgreSQL >= 14)
);
CREATE INDEX pg_archiver_sample_time_idx ON pgbackrest_monitor.pg_archiver_sample (instance, sampled_at DESC);

CREATE TABLE pgbackrest_monitor.error_history (
    error_id    bigserial PRIMARY KEY,
    occurred_at timestamptz NOT NULL,
    stanza_name text,
    repo_key    integer,
    source      text NOT NULL CHECK (source IN ('collector', 'pgbackrest', 'postgres_archiver')),
    operation   text,
    category    text NOT NULL,
    exit_code   integer,
    message     text NOT NULL,
    details     jsonb,
    run_id      bigint
);
CREATE INDEX error_history_time_idx ON pgbackrest_monitor.error_history (occurred_at DESC);
CREATE INDEX error_history_stanza_idx ON pgbackrest_monitor.error_history (stanza_name, occurred_at DESC);

-- Backup/restore lock observations taken from `info` output (progress while held, and the
-- observation at which the lock was released).
CREATE TABLE pgbackrest_monitor.operation_observation (
    observation_id  bigserial PRIMARY KEY,
    stanza_name     text NOT NULL REFERENCES pgbackrest_monitor.stanza ON DELETE CASCADE,
    observed_at     timestamptz NOT NULL,
    operation       text NOT NULL CHECK (operation IN ('backup/expire', 'restore')),
    held            boolean NOT NULL,
    size_total      bigint,
    size_complete   bigint,
    pct_complete    numeric(5,2),
    repo_progress   jsonb
);
CREATE INDEX operation_observation_idx ON pgbackrest_monitor.operation_observation (stanza_name, observed_at DESC);

-- Include data in pg_dump (the tables are extension members and would otherwise be skipped).
SELECT pg_catalog.pg_extension_config_dump('pgbackrest_monitor.config', '');
SELECT pg_catalog.pg_extension_config_dump('pgbackrest_monitor.stanza', '');
SELECT pg_catalog.pg_extension_config_dump('pgbackrest_monitor.stanza_setting', '');
SELECT pg_catalog.pg_extension_config_dump('pgbackrest_monitor.collector', '');
SELECT pg_catalog.pg_extension_config_dump('pgbackrest_monitor.collection_run', '');
SELECT pg_catalog.pg_extension_config_dump('pgbackrest_monitor.collection_run_run_id_seq', '');
SELECT pg_catalog.pg_extension_config_dump('pgbackrest_monitor.stanza_state', '');
SELECT pg_catalog.pg_extension_config_dump('pgbackrest_monitor.repo_state', '');
SELECT pg_catalog.pg_extension_config_dump('pgbackrest_monitor.archive_state', '');
SELECT pg_catalog.pg_extension_config_dump('pgbackrest_monitor.backup', '');
SELECT pg_catalog.pg_extension_config_dump('pgbackrest_monitor.pg_archiver_sample', '');
SELECT pg_catalog.pg_extension_config_dump('pgbackrest_monitor.pg_archiver_sample_sample_id_seq', '');
SELECT pg_catalog.pg_extension_config_dump('pgbackrest_monitor.error_history', '');
SELECT pg_catalog.pg_extension_config_dump('pgbackrest_monitor.error_history_error_id_seq', '');
SELECT pg_catalog.pg_extension_config_dump('pgbackrest_monitor.operation_observation', '');
SELECT pg_catalog.pg_extension_config_dump('pgbackrest_monitor.operation_observation_observation_id_seq', '');

------------------------------------------------------------------------------------------------
-- 4. WAL name helpers (pure, derived calculations)
------------------------------------------------------------------------------------------------
-- Normalise a pg_stat_archiver value to a 24-character WAL segment name; strips .partial /
-- .backup history suffixes.  Returns NULL for anything that is not a WAL segment name.
CREATE FUNCTION pgbackrest_monitor.wal_segment_name(p_name text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT CASE WHEN p_name ~ '^[0-9A-F]{24}' THEN substr(p_name, 1, 24) END
$$;

CREATE FUNCTION pgbackrest_monitor.wal_timeline(p_name text) RETURNS bigint
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT ('x' || substr(pgbackrest_monitor.wal_segment_name(p_name), 1, 8))::bit(32)::bigint
$$;

-- Absolute segment number of a WAL file name for a given wal_segment_size (bytes).
CREATE FUNCTION pgbackrest_monitor.wal_segno(p_name text, p_segment_size bigint) RETURNS bigint
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT ('x' || substr(n, 9, 8))::bit(32)::bigint * (4294967296 / p_segment_size)
         + ('x' || substr(n, 17, 8))::bit(32)::bigint
    FROM pgbackrest_monitor.wal_segment_name(p_name) n
    WHERE n IS NOT NULL
$$;

-- WAL file name containing an LSN on a timeline (same result as pg_walfile_name(), but usable on
-- a standby, where pg_walfile_name() raises an error).
CREATE FUNCTION pgbackrest_monitor.wal_file_name(p_timeline bigint, p_lsn pg_lsn, p_segment_size bigint) RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT upper(lpad(to_hex(p_timeline), 8, '0')
              || lpad(to_hex(segno / per_log), 8, '0')
              || lpad(to_hex(segno % per_log), 8, '0'))
    FROM (SELECT floor((p_lsn - '0/0'::pg_lsn) / p_segment_size)::bigint AS segno,
                 (4294967296 / p_segment_size)::bigint AS per_log) x
$$;

------------------------------------------------------------------------------------------------
-- 5. Ingestion (normalisation of pgBackRest info JSON)
------------------------------------------------------------------------------------------------
CREATE FUNCTION pgbackrest_monitor.ingest_info(p_stanza text, p_raw jsonb, p_observed_at timestamptz, p_run_id bigint)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    s               jsonb;      -- the stanza element
    v_repos         jsonb;      -- normalised repo array
    r               jsonb;
    b               jsonb;
    a               jsonb;
    v_repo_key      integer;
    v_prev_backup_held  boolean;
    v_prev_restore_held boolean;
    v_prev_code     integer;
    v_prev_error    boolean;
    v_label         text;
    v_version_seen  text;
    v_ok_repos      integer[] := '{}';
BEGIN
    IF p_raw IS NULL OR jsonb_typeof(p_raw) <> 'array' THEN
        RAISE EXCEPTION 'info output must be a JSON array' USING ERRCODE = '22023';
    END IF;

    SELECT e INTO s FROM jsonb_array_elements(p_raw) e WHERE e->>'name' = p_stanza;
    IF s IS NULL THEN
        RAISE EXCEPTION 'stanza "%" is not present in info output', p_stanza USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(s->'status') <> 'object' OR (s->'status'->>'code') IS NULL THEN
        RAISE EXCEPTION 'stanza "%" has no status.code', p_stanza USING ERRCODE = '22023';
    END IF;
    IF s ? 'backup' AND jsonb_typeof(s->'backup') <> 'array' THEN
        RAISE EXCEPTION 'stanza "%" backup element is not an array', p_stanza USING ERRCODE = '22023';
    END IF;

    -- Multi-repository output (pgBackRest >= 2.33) carries a repo array and repo-key fields.
    -- Older single-repository output has neither; synthesise repo key 1 from the stanza status.
    IF jsonb_typeof(s->'repo') = 'array' THEN
        v_repos := s->'repo';
    ELSE
        v_repos := jsonb_build_array(jsonb_build_object(
            'key', 1, 'cipher', s->>'cipher',
            'status', jsonb_build_object('code', (s->'status'->>'code')::int, 'message', s->'status'->>'message')));
    END IF;

    SELECT backup_lock_held, restore_lock_held INTO v_prev_backup_held, v_prev_restore_held
    FROM pgbackrest_monitor.stanza_state WHERE stanza_name = p_stanza;

    SELECT (b2->'backrest'->>'version') INTO v_version_seen
    FROM jsonb_array_elements(COALESCE(s->'backup', '[]'::jsonb)) b2
    ORDER BY (b2->'timestamp'->>'stop')::bigint DESC NULLS LAST LIMIT 1;

    INSERT INTO pgbackrest_monitor.stanza_state AS ss (
        stanza_name, observed_at, run_id, status_code, status_message, cipher,
        backup_lock_held, backup_lock_size, backup_lock_size_cplt, backup_lock_pct_cplt,
        restore_lock_held, restore_lock_size, restore_lock_size_cplt, restore_lock_pct_cplt,
        pgbackrest_version_seen, repo_count, backup_count)
    VALUES (
        p_stanza, p_observed_at, p_run_id,
        (s->'status'->>'code')::int, COALESCE(s->'status'->>'message', ''), s->>'cipher',
        (s->'status'->'lock'->'backup'->>'held')::boolean,
        (s->'status'->'lock'->'backup'->>'size')::bigint,
        (s->'status'->'lock'->'backup'->>'size-cplt')::bigint,
        (s->'status'->'lock'->'backup'->>'pct-cplt')::numeric / 100,
        (s->'status'->'lock'->'restore'->>'held')::boolean,
        (s->'status'->'lock'->'restore'->>'size')::bigint,
        (s->'status'->'lock'->'restore'->>'size-cplt')::bigint,
        (s->'status'->'lock'->'restore'->>'pct-cplt')::numeric / 100,
        v_version_seen,
        jsonb_array_length(v_repos),
        jsonb_array_length(COALESCE(s->'backup', '[]'::jsonb)))
    ON CONFLICT (stanza_name) DO UPDATE SET
        observed_at = EXCLUDED.observed_at, run_id = EXCLUDED.run_id,
        status_code = EXCLUDED.status_code, status_message = EXCLUDED.status_message, cipher = EXCLUDED.cipher,
        backup_lock_held = EXCLUDED.backup_lock_held, backup_lock_size = EXCLUDED.backup_lock_size,
        backup_lock_size_cplt = EXCLUDED.backup_lock_size_cplt, backup_lock_pct_cplt = EXCLUDED.backup_lock_pct_cplt,
        restore_lock_held = EXCLUDED.restore_lock_held, restore_lock_size = EXCLUDED.restore_lock_size,
        restore_lock_size_cplt = EXCLUDED.restore_lock_size_cplt, restore_lock_pct_cplt = EXCLUDED.restore_lock_pct_cplt,
        pgbackrest_version_seen = EXCLUDED.pgbackrest_version_seen,
        repo_count = EXCLUDED.repo_count, backup_count = EXCLUDED.backup_count;

    -- Operation observations: record while a lock is held, and once when it is released.
    IF COALESCE((s->'status'->'lock'->'backup'->>'held')::boolean, false) OR COALESCE(v_prev_backup_held, false) THEN
        INSERT INTO pgbackrest_monitor.operation_observation
            (stanza_name, observed_at, operation, held, size_total, size_complete, pct_complete, repo_progress)
        VALUES (p_stanza, p_observed_at, 'backup/expire',
            COALESCE((s->'status'->'lock'->'backup'->>'held')::boolean, false),
            (s->'status'->'lock'->'backup'->>'size')::bigint,
            (s->'status'->'lock'->'backup'->>'size-cplt')::bigint,
            (s->'status'->'lock'->'backup'->>'pct-cplt')::numeric / 100,
            s->'status'->'lock'->'backup'->'repo');
    END IF;
    IF COALESCE((s->'status'->'lock'->'restore'->>'held')::boolean, false) OR COALESCE(v_prev_restore_held, false) THEN
        INSERT INTO pgbackrest_monitor.operation_observation
            (stanza_name, observed_at, operation, held, size_total, size_complete, pct_complete)
        VALUES (p_stanza, p_observed_at, 'restore',
            COALESCE((s->'status'->'lock'->'restore'->>'held')::boolean, false),
            (s->'status'->'lock'->'restore'->>'size')::bigint,
            (s->'status'->'lock'->'restore'->>'size-cplt')::bigint,
            (s->'status'->'lock'->'restore'->>'pct-cplt')::numeric / 100);
    END IF;

    -- Repositories: replace the latest-state rows for this stanza.
    DELETE FROM pgbackrest_monitor.archive_state WHERE stanza_name = p_stanza;
    FOR r IN SELECT * FROM jsonb_array_elements(v_repos) LOOP
        v_repo_key := COALESCE((r->>'key')::int, 1);
        IF (r->'status'->>'code') IS NULL THEN
            RAISE EXCEPTION 'repo % of stanza "%" has no status.code', v_repo_key, p_stanza USING ERRCODE = '22023';
        END IF;

        SELECT status_code INTO v_prev_code FROM pgbackrest_monitor.repo_state
        WHERE stanza_name = p_stanza AND repo_key = v_repo_key;

        -- archive ranges for this repo (repo-key absent => single-repo output => key 1)
        FOR a IN SELECT * FROM jsonb_array_elements(COALESCE(s->'archive', '[]'::jsonb)) ae
                 WHERE COALESCE((ae->'database'->>'repo-key')::int, 1) = v_repo_key LOOP
            INSERT INTO pgbackrest_monitor.archive_state (stanza_name, repo_key, archive_id, db_id, wal_min, wal_max, observed_at)
            VALUES (p_stanza, v_repo_key, a->>'id', (a->'database'->>'id')::int, a->>'min', a->>'max', p_observed_at)
            ON CONFLICT (stanza_name, repo_key, archive_id) DO UPDATE SET
                db_id = EXCLUDED.db_id, wal_min = EXCLUDED.wal_min, wal_max = EXCLUDED.wal_max, observed_at = EXCLUDED.observed_at;
        END LOOP;

        INSERT INTO pgbackrest_monitor.repo_state AS rs (
            stanza_name, repo_key, observed_at, status_code, status_message, cipher,
            db_id, db_version, db_system_id, archive_id, archive_min, archive_max,
            has_backup_metadata, has_archive_metadata)
        SELECT p_stanza, v_repo_key, p_observed_at,
               (r->'status'->>'code')::int, COALESCE(r->'status'->>'message', ''), r->>'cipher',
               d.db_id, d.db_version, d.db_system_id,
               ar.archive_id, ar.wal_min, ar.wal_max,
               EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(s->'backup', '[]'::jsonb)) be
                       WHERE COALESCE((be->'database'->>'repo-key')::int, 1) = v_repo_key),
               ar.archive_id IS NOT NULL
        FROM (SELECT 1) one
        LEFT JOIN LATERAL (
            SELECT (de->>'id')::int AS db_id, de->>'version' AS db_version, (de->>'system-id')::bigint AS db_system_id
            FROM jsonb_array_elements(COALESCE(s->'db', '[]'::jsonb)) de
            WHERE COALESCE((de->>'repo-key')::int, 1) = v_repo_key
            ORDER BY (de->>'id')::int DESC LIMIT 1) d ON true
        LEFT JOIN LATERAL (
            SELECT archive_id, wal_min, wal_max FROM pgbackrest_monitor.archive_state
            WHERE stanza_name = p_stanza AND repo_key = v_repo_key
            ORDER BY db_id DESC NULLS LAST LIMIT 1) ar ON true
        ON CONFLICT (stanza_name, repo_key) DO UPDATE SET
            observed_at = EXCLUDED.observed_at, status_code = EXCLUDED.status_code,
            status_message = EXCLUDED.status_message, cipher = EXCLUDED.cipher,
            db_id = EXCLUDED.db_id, db_version = EXCLUDED.db_version, db_system_id = EXCLUDED.db_system_id,
            archive_id = EXCLUDED.archive_id, archive_min = EXCLUDED.archive_min, archive_max = EXCLUDED.archive_max,
            has_backup_metadata = EXCLUDED.has_backup_metadata, has_archive_metadata = EXCLUDED.has_archive_metadata;

        -- A repository error is recorded once per status transition (not once per collection).
        IF (r->'status'->>'code')::int NOT IN (0, 2) AND (v_prev_code IS DISTINCT FROM (r->'status'->>'code')::int) THEN
            INSERT INTO pgbackrest_monitor.error_history
                (occurred_at, stanza_name, repo_key, source, operation, category, exit_code, message, run_id)
            VALUES (p_observed_at, p_stanza, v_repo_key, 'pgbackrest', 'info', 'repo_status',
                    (r->'status'->>'code')::int,
                    format('repo%s status %s: %s', v_repo_key, r->'status'->>'code', r->'status'->>'message'), p_run_id);
        END IF;

        -- Only repositories that were actually listed can tell us a backup has gone away.
        IF (r->'status'->>'code')::int IN (0, 2) THEN
            v_ok_repos := v_ok_repos || v_repo_key;
        END IF;
    END LOOP;

    DELETE FROM pgbackrest_monitor.repo_state
    WHERE stanza_name = p_stanza AND observed_at < p_observed_at;

    -- Backups
    FOR b IN SELECT * FROM jsonb_array_elements(COALESCE(s->'backup', '[]'::jsonb)) LOOP
        IF (b->>'label') IS NULL OR (b->>'type') IS NULL OR (b->'timestamp'->>'start') IS NULL OR (b->'timestamp'->>'stop') IS NULL THEN
            RAISE EXCEPTION 'backup entry in stanza "%" lacks label/type/timestamp', p_stanza USING ERRCODE = '22023';
        END IF;
        v_repo_key := COALESCE((b->'database'->>'repo-key')::int, 1);
        v_label := b->>'label';

        SELECT has_error INTO v_prev_error FROM pgbackrest_monitor.backup
        WHERE stanza_name = p_stanza AND repo_key = v_repo_key AND label = v_label;

        INSERT INTO pgbackrest_monitor.backup AS bk (
            stanza_name, repo_key, label, backup_type, started_at, stopped_at,
            wal_start, wal_stop, lsn_start, lsn_stop, db_id,
            database_size, backup_size, repo_set_size, repo_backup_size,
            prior_label, reference_labels, has_error, annotation, pgbackrest_version, pgbackrest_format,
            first_seen_at, last_seen_at, present, expired_detected_at)
        VALUES (
            p_stanza, v_repo_key, v_label, b->>'type',
            to_timestamp((b->'timestamp'->>'start')::bigint), to_timestamp((b->'timestamp'->>'stop')::bigint),
            b->'archive'->>'start', b->'archive'->>'stop',
            (b->'lsn'->>'start')::pg_lsn, (b->'lsn'->>'stop')::pg_lsn,
            (b->'database'->>'id')::int,
            (b->'info'->>'size')::bigint, (b->'info'->>'delta')::bigint,
            (b->'info'->'repository'->>'size')::bigint, (b->'info'->'repository'->>'delta')::bigint,
            b->>'prior',
            CASE WHEN jsonb_typeof(b->'reference') = 'array'
                 THEN ARRAY(SELECT jsonb_array_elements_text(b->'reference')) END,
            (b->>'error')::boolean,
            CASE WHEN jsonb_typeof(b->'annotation') = 'object' THEN b->'annotation' END,
            b->'backrest'->>'version', (b->'backrest'->>'format')::int,
            p_observed_at, p_observed_at, true, NULL)
        ON CONFLICT (stanza_name, repo_key, label) DO UPDATE SET
            backup_type = EXCLUDED.backup_type, started_at = EXCLUDED.started_at, stopped_at = EXCLUDED.stopped_at,
            wal_start = EXCLUDED.wal_start, wal_stop = EXCLUDED.wal_stop,
            lsn_start = EXCLUDED.lsn_start, lsn_stop = EXCLUDED.lsn_stop, db_id = EXCLUDED.db_id,
            database_size = EXCLUDED.database_size, backup_size = EXCLUDED.backup_size,
            repo_set_size = EXCLUDED.repo_set_size, repo_backup_size = EXCLUDED.repo_backup_size,
            prior_label = EXCLUDED.prior_label, reference_labels = EXCLUDED.reference_labels,
            has_error = EXCLUDED.has_error, annotation = EXCLUDED.annotation,
            pgbackrest_version = EXCLUDED.pgbackrest_version, pgbackrest_format = EXCLUDED.pgbackrest_format,
            last_seen_at = EXCLUDED.last_seen_at, present = true, expired_detected_at = NULL;

        IF COALESCE((b->>'error')::boolean, false) AND NOT COALESCE(v_prev_error, false) THEN
            INSERT INTO pgbackrest_monitor.error_history
                (occurred_at, stanza_name, repo_key, source, operation, category, message, details, run_id)
            VALUES (p_observed_at, p_stanza, v_repo_key, 'pgbackrest', 'backup', 'backup_error',
                    format('backup %s (%s) in repo%s is flagged with errors by pgBackRest', v_label, b->>'type', v_repo_key),
                    jsonb_build_object('label', v_label, 'type', b->>'type', 'error_list', b->'error-list'), p_run_id);
        END IF;
    END LOOP;

    -- Backups that vanished from a readable repository have been expired (or removed).
    UPDATE pgbackrest_monitor.backup
    SET present = false, expired_detected_at = p_observed_at
    WHERE stanza_name = p_stanza AND present AND last_seen_at < p_observed_at
      AND repo_key = ANY (v_ok_repos);
END
$$;

------------------------------------------------------------------------------------------------
-- 6. Collector API (SECURITY DEFINER; the collector role needs EXECUTE on these only)
------------------------------------------------------------------------------------------------
CREATE FUNCTION pgbackrest_monitor.register_collector(
    p_collector_id text, p_hostname text, p_pid integer, p_collector_version text,
    p_pgbackrest_version text, p_interval interval, p_stanzas text[])
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    INSERT INTO pgbackrest_monitor.collector
        (collector_id, hostname, pid, collector_version, pgbackrest_version, started_at, last_heartbeat, collection_interval, stanzas)
    VALUES (p_collector_id, p_hostname, p_pid, p_collector_version, p_pgbackrest_version, now(), now(), p_interval, COALESCE(p_stanzas, '{}'))
    ON CONFLICT (collector_id) DO UPDATE SET
        hostname = EXCLUDED.hostname, pid = EXCLUDED.pid, collector_version = EXCLUDED.collector_version,
        pgbackrest_version = EXCLUDED.pgbackrest_version, started_at = now(), last_heartbeat = now(),
        collection_interval = EXCLUDED.collection_interval, stanzas = EXCLUDED.stanzas;
$$;

CREATE FUNCTION pgbackrest_monitor.heartbeat(p_collector_id text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    UPDATE pgbackrest_monitor.collector SET last_heartbeat = now() WHERE collector_id = p_collector_id;
$$;

-- Registers a stanza the collector is configured to monitor.  Never changes DBA-managed columns
-- (enabled, settings) of an existing row.
CREATE FUNCTION pgbackrest_monitor.register_stanza(p_stanza text, p_pg_instance text DEFAULT 'local', p_interval interval DEFAULT NULL)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    INSERT INTO pgbackrest_monitor.stanza (stanza_name, pg_instance, collection_interval)
    VALUES (p_stanza, p_pg_instance, p_interval)
    ON CONFLICT (stanza_name) DO UPDATE SET pg_instance = EXCLUDED.pg_instance, collection_interval = EXCLUDED.collection_interval;
$$;

CREATE FUNCTION pgbackrest_monitor.stanza_enabled(p_stanza text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT COALESCE((SELECT enabled FROM pgbackrest_monitor.stanza WHERE stanza_name = p_stanza), true)
$$;

-- Session-level advisory lock preventing two collectors from working the same stanza at once.
CREATE FUNCTION pgbackrest_monitor.try_lock_stanza(p_stanza text) RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT pg_try_advisory_lock(hashtext('pgbackrest_monitor'), hashtext(p_stanza))
$$;

CREATE FUNCTION pgbackrest_monitor.unlock_stanza(p_stanza text) RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT pg_advisory_unlock(hashtext('pgbackrest_monitor'), hashtext(p_stanza))
$$;

-- Records one collector attempt.  On success the JSON is normalised in the same transaction;
-- a normalisation failure is converted into outcome 'validation_failed' so the attempt is
-- always recorded and the previous good state is left untouched.
CREATE FUNCTION pgbackrest_monitor.record_run(
    p_collector_id text, p_stanza text, p_command text,
    p_started_at timestamptz, p_finished_at timestamptz,
    p_exit_code integer, p_outcome text, p_error_message text, p_raw_output jsonb)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_run_id bigint;
    v_source text;
BEGIN
    INSERT INTO pgbackrest_monitor.collection_run
        (collector_id, stanza_name, command, started_at, finished_at, exit_code, outcome, error_message, raw_output)
    VALUES (p_collector_id, p_stanza, p_command, p_started_at, p_finished_at, p_exit_code, p_outcome,
            left(p_error_message, 4000), p_raw_output)
    RETURNING run_id INTO v_run_id;

    IF p_outcome = 'success' THEN
        BEGIN
            PERFORM pgbackrest_monitor.ingest_info(p_stanza, p_raw_output, p_finished_at, v_run_id);
        EXCEPTION WHEN OTHERS THEN
            UPDATE pgbackrest_monitor.collection_run
            SET outcome = 'validation_failed', error_message = left(SQLERRM, 4000)
            WHERE run_id = v_run_id;
            INSERT INTO pgbackrest_monitor.error_history
                (occurred_at, stanza_name, source, operation, category, exit_code, message, run_id)
            VALUES (p_finished_at, p_stanza, 'collector', p_command, 'validation_failed', p_exit_code, left(SQLERRM, 4000), v_run_id);
        END;
    ELSIF p_outcome <> 'skipped_locked' THEN
        v_source := CASE WHEN p_outcome = 'command_failed' THEN 'pgbackrest' ELSE 'collector' END;
        INSERT INTO pgbackrest_monitor.error_history
            (occurred_at, stanza_name, source, operation, category, exit_code, message, run_id)
        VALUES (p_finished_at, p_stanza, v_source, p_command, p_outcome, p_exit_code,
                COALESCE(left(p_error_message, 4000), p_outcome), v_run_id);
    END IF;
    RETURN v_run_id;
END
$$;

-- Collector-side problems not tied to a single pgBackRest run (configuration, database errors...).
CREATE FUNCTION pgbackrest_monitor.record_error(
    p_stanza text, p_category text, p_message text, p_operation text DEFAULT NULL, p_details jsonb DEFAULT NULL)
RETURNS bigint
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    INSERT INTO pgbackrest_monitor.error_history (occurred_at, stanza_name, source, operation, category, message, details)
    VALUES (pgbackrest_monitor.clock(), p_stanza, 'collector', p_operation, p_category, left(p_message, 4000), p_details)
    RETURNING error_id
$$;

-- Stores one archiver observation for a named instance.  Used by sample_pg_archiver() for the
-- local instance and by the collector for instances it samples remotely (standbys, other
-- clusters).  Only values from pg_stat_archiver / pg_stat_wal / GUCs are accepted; no command text.
CREATE FUNCTION pgbackrest_monitor.record_pg_archiver_sample(
    p_instance text, p_server_version_num integer, p_in_recovery boolean, p_archive_mode text,
    p_archive_command_set boolean, p_archive_library_set boolean, p_wal_segment_size bigint,
    p_archived_count bigint, p_last_archived_wal text, p_last_archived_time timestamptz,
    p_failed_count bigint, p_last_failed_wal text, p_last_failed_time timestamptz, p_stats_reset timestamptz,
    p_current_wal_lsn pg_lsn, p_timeline_id bigint, p_wal_bytes numeric)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_id   bigint;
    v_prev record;
BEGIN
    IF p_instance IS NULL OR p_instance !~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$' THEN
        RAISE EXCEPTION 'invalid instance name' USING ERRCODE = '22023';
    END IF;
    SELECT failed_count, last_failed_time, stats_reset INTO v_prev
    FROM pgbackrest_monitor.pg_archiver_sample WHERE instance = p_instance ORDER BY sampled_at DESC, sample_id DESC LIMIT 1;

    INSERT INTO pgbackrest_monitor.pg_archiver_sample (
        instance, sampled_at, server_version_num, in_recovery, archive_mode, archive_command_set, archive_library_set,
        wal_segment_size, archived_count, last_archived_wal, last_archived_time,
        failed_count, last_failed_wal, last_failed_time, stats_reset,
        current_wal_lsn, timeline_id, current_wal_file, wal_bytes)
    VALUES (
        p_instance, pgbackrest_monitor.clock(), p_server_version_num, p_in_recovery, p_archive_mode, p_archive_command_set, p_archive_library_set,
        p_wal_segment_size, p_archived_count, pgbackrest_monitor.wal_segment_name(p_last_archived_wal), p_last_archived_time,
        p_failed_count, left(p_last_failed_wal, 64), p_last_failed_time, p_stats_reset,
        p_current_wal_lsn, p_timeline_id,
        CASE WHEN p_timeline_id IS NOT NULL AND p_current_wal_lsn IS NOT NULL
             THEN pgbackrest_monitor.wal_file_name(p_timeline_id, p_current_wal_lsn, p_wal_segment_size) END,
        p_wal_bytes)
    RETURNING sample_id INTO v_id;

    -- New archiver failures since the previous sample become error_history rows.
    IF p_failed_count > 0 AND (v_prev IS NULL OR p_failed_count > v_prev.failed_count
                               OR p_stats_reset IS DISTINCT FROM v_prev.stats_reset
                               OR p_last_failed_time IS DISTINCT FROM v_prev.last_failed_time) THEN
        INSERT INTO pgbackrest_monitor.error_history
            (occurred_at, source, operation, category, message, details)
        VALUES (COALESCE(p_last_failed_time, pgbackrest_monitor.clock()), 'postgres_archiver', 'archive_command', 'archive_failed',
                format('instance %s: pg_stat_archiver reports %s failed archive attempt(s); last failure on %s at %s',
                       p_instance, p_failed_count, p_last_failed_wal, p_last_failed_time),
                jsonb_build_object('instance', p_instance, 'failed_count', p_failed_count,
                                   'last_failed_wal', p_last_failed_wal, 'previous_failed_count', v_prev.failed_count));
    END IF;
    RETURN v_id;
END
$$;

-- Snapshot of THIS instance's archiver statistics (instance name 'local').  Reads only pg_stat_*
-- views and GUCs; never resets statistics.  archive_command text is reduced to a boolean.
CREATE FUNCTION pgbackrest_monitor.sample_pg_archiver() RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_version       integer := current_setting('server_version_num')::int;
    v_in_recovery   boolean := pg_is_in_recovery();
    v_segsize       bigint  := pg_size_bytes(current_setting('wal_segment_size'));
    v_cmd_set       boolean;
    v_lib_set       boolean;
    v_lsn           pg_lsn;
    v_tl            bigint;
    v_wal_bytes     numeric;
    v_cur           record;
BEGIN
    BEGIN
        v_cmd_set := length(btrim(current_setting('archive_command'))) > 0
                     AND current_setting('archive_command') <> '(disabled)';
    EXCEPTION WHEN insufficient_privilege THEN
        v_cmd_set := NULL;
    END;
    IF v_version >= 150000 THEN
        BEGIN
            v_lib_set := length(btrim(current_setting('archive_library'))) > 0;
        EXCEPTION WHEN insufficient_privilege THEN
            v_lib_set := NULL;
        END;
    END IF;

    IF v_in_recovery THEN
        v_lsn := COALESCE(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn());
        BEGIN
            SELECT timeline_id INTO v_tl FROM pg_control_checkpoint();
        EXCEPTION WHEN insufficient_privilege THEN
            v_tl := NULL;
        END;
    ELSE
        v_lsn := pg_current_wal_lsn();
        v_tl  := pgbackrest_monitor.wal_timeline(pg_walfile_name(v_lsn));
    END IF;

    IF v_version >= 140000 THEN
        SELECT wal_bytes INTO v_wal_bytes FROM pg_stat_wal;
    END IF;

    SELECT archived_count, last_archived_wal, last_archived_time, failed_count, last_failed_wal, last_failed_time, stats_reset
    INTO v_cur FROM pg_stat_archiver;

    RETURN pgbackrest_monitor.record_pg_archiver_sample(
        'local', v_version, v_in_recovery, current_setting('archive_mode'), v_cmd_set, v_lib_set, v_segsize,
        v_cur.archived_count, v_cur.last_archived_wal, v_cur.last_archived_time,
        v_cur.failed_count, v_cur.last_failed_wal, v_cur.last_failed_time, v_cur.stats_reset,
        v_lsn, v_tl, v_wal_bytes);
END
$$;

-- Retention.  Returns the number of rows removed per table.
CREATE FUNCTION pgbackrest_monitor.purge_history()
RETURNS TABLE (table_name text, rows_removed bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_now timestamptz := pgbackrest_monitor.clock();
    n bigint;
BEGIN
    -- Raw JSON is bulky: drop it early, but keep the latest successful run per stanza.
    UPDATE pgbackrest_monitor.collection_run r SET raw_output = NULL
    WHERE raw_output IS NOT NULL
      AND started_at < v_now - COALESCE(pgbackrest_monitor.setting_interval(NULL, 'retention_raw_output'), '2 days')
      AND run_id NOT IN (SELECT run_id FROM pgbackrest_monitor.stanza_state WHERE run_id IS NOT NULL);
    GET DIAGNOSTICS n = ROW_COUNT; table_name := 'collection_run.raw_output'; rows_removed := n; RETURN NEXT;

    DELETE FROM pgbackrest_monitor.collection_run
    WHERE started_at < v_now - COALESCE(pgbackrest_monitor.setting_interval(NULL, 'retention_runs'), '7 days')
      AND run_id NOT IN (SELECT run_id FROM pgbackrest_monitor.stanza_state WHERE run_id IS NOT NULL);
    GET DIAGNOSTICS n = ROW_COUNT; table_name := 'collection_run'; rows_removed := n; RETURN NEXT;

    DELETE FROM pgbackrest_monitor.error_history
    WHERE occurred_at < v_now - COALESCE(pgbackrest_monitor.setting_interval(NULL, 'retention_errors'), '30 days');
    GET DIAGNOSTICS n = ROW_COUNT; table_name := 'error_history'; rows_removed := n; RETURN NEXT;

    DELETE FROM pgbackrest_monitor.operation_observation
    WHERE observed_at < v_now - COALESCE(pgbackrest_monitor.setting_interval(NULL, 'retention_operations'), '30 days');
    GET DIAGNOSTICS n = ROW_COUNT; table_name := 'operation_observation'; rows_removed := n; RETURN NEXT;

    DELETE FROM pgbackrest_monitor.pg_archiver_sample
    WHERE sampled_at < v_now - COALESCE(pgbackrest_monitor.setting_interval(NULL, 'retention_archiver_samples'), '7 days')
      AND sample_id NOT IN (SELECT DISTINCT ON (instance) sample_id FROM pgbackrest_monitor.pg_archiver_sample ORDER BY instance, sampled_at DESC, sample_id DESC);
    GET DIAGNOSTICS n = ROW_COUNT; table_name := 'pg_archiver_sample'; rows_removed := n; RETURN NEXT;

    DELETE FROM pgbackrest_monitor.backup
    WHERE NOT present
      AND expired_detected_at < v_now - COALESCE(pgbackrest_monitor.setting_interval(NULL, 'retention_expired_backups'), '365 days');
    GET DIAGNOSTICS n = ROW_COUNT; table_name := 'backup'; rows_removed := n; RETURN NEXT;
    RETURN;
END
$$;

------------------------------------------------------------------------------------------------
-- 7. Health evaluation
------------------------------------------------------------------------------------------------
-- Collection freshness per stanza (helper view).
CREATE VIEW pgbackrest_monitor.collection_status AS
SELECT st.stanza_name, st.enabled, st.pg_instance,
       ss.observed_at                                   AS last_success_at,
       pgbackrest_monitor.clock() - ss.observed_at      AS data_age,
       lr.started_at                                    AS last_attempt_at,
       lr.outcome                                       AS last_attempt_outcome,
       lr.exit_code                                     AS last_attempt_exit_code,
       lr.error_message                                 AS last_attempt_error,
       lf.finished_at                                   AS last_failure_at,
       lf.outcome                                       AS last_failure_outcome,
       lf.error_message                                 AS last_failure_error,
       hb.collector_id, hb.last_heartbeat,
       pgbackrest_monitor.clock() - hb.last_heartbeat   AS heartbeat_age,
       hb.collection_interval
FROM pgbackrest_monitor.stanza st
LEFT JOIN pgbackrest_monitor.stanza_state ss USING (stanza_name)
LEFT JOIN LATERAL (SELECT * FROM pgbackrest_monitor.collection_run r
                   WHERE r.stanza_name = st.stanza_name ORDER BY r.started_at DESC LIMIT 1) lr ON true
LEFT JOIN LATERAL (SELECT * FROM pgbackrest_monitor.collection_run r
                   WHERE r.stanza_name = st.stanza_name AND r.outcome NOT IN ('success', 'skipped_locked')
                   ORDER BY r.started_at DESC LIMIT 1) lf ON true
LEFT JOIN LATERAL (SELECT * FROM pgbackrest_monitor.collector c
                   WHERE c.stanzas @> ARRAY[st.stanza_name]
                   ORDER BY c.last_heartbeat DESC LIMIT 1) hb ON true;

CREATE VIEW pgbackrest_monitor.latest_pg_archiver AS
SELECT DISTINCT ON (s.instance) s.*, pgbackrest_monitor.clock() - s.sampled_at AS sample_age
FROM pgbackrest_monitor.pg_archiver_sample s ORDER BY s.instance, s.sampled_at DESC, s.sample_id DESC;

CREATE FUNCTION pgbackrest_monitor.evaluate_collector(p_stanza text)
RETURNS pgbackrest_monitor.health_component
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    cs  record;
    hb_warn interval := pgbackrest_monitor.setting_interval(p_stanza, 'collector_heartbeat_warning');
    hb_crit interval := pgbackrest_monitor.setting_interval(p_stanza, 'collector_heartbeat_critical');
    da_warn interval := pgbackrest_monitor.setting_interval(p_stanza, 'data_stale_warning');
    da_crit interval := pgbackrest_monitor.setting_interval(p_stanza, 'data_stale_critical');
    v_err   text;
BEGIN
    SELECT * INTO cs FROM pgbackrest_monitor.collection_status WHERE stanza_name = p_stanza;
    IF cs IS NULL THEN
        RETURN pgbackrest_monitor.hc('UNKNOWN', 'STANZA_NOT_REGISTERED', format('stanza %s is not registered', p_stanza));
    END IF;
    IF NOT cs.enabled THEN
        RETURN pgbackrest_monitor.hc('UNKNOWN', 'MONITORING_DISABLED', format('monitoring of stanza %s is disabled', p_stanza));
    END IF;
    v_err := COALESCE(cs.last_attempt_error, cs.last_attempt_outcome, 'none');

    IF cs.last_heartbeat IS NULL THEN
        IF cs.last_success_at IS NULL THEN
            RETURN pgbackrest_monitor.hc('UNKNOWN', 'COLLECTOR_NEVER_SEEN', 'no collector has registered for this stanza and no data has been collected');
        END IF;
        RETURN pgbackrest_monitor.hc('CRITICAL', 'COLLECTOR_NO_HEARTBEAT',
                format('no collector heartbeat registered for this stanza; last observation %s ago', pgbackrest_monitor.fmt_interval(cs.data_age)));
    END IF;
    IF hb_crit IS NOT NULL AND cs.heartbeat_age > hb_crit THEN
        RETURN pgbackrest_monitor.hc('CRITICAL', 'COLLECTOR_HEARTBEAT_STALE',
                format('collector %s last heartbeat %s ago (critical threshold %s)', cs.collector_id, pgbackrest_monitor.fmt_interval(cs.heartbeat_age), pgbackrest_monitor.fmt_interval(hb_crit)));
    END IF;
    IF hb_warn IS NOT NULL AND cs.heartbeat_age > hb_warn THEN
        RETURN pgbackrest_monitor.hc('WARNING', 'COLLECTOR_HEARTBEAT_STALE',
                format('collector %s last heartbeat %s ago (warning threshold %s)', cs.collector_id, pgbackrest_monitor.fmt_interval(cs.heartbeat_age), pgbackrest_monitor.fmt_interval(hb_warn)));
    END IF;
    IF cs.last_success_at IS NULL THEN
        IF cs.last_attempt_at IS NULL THEN
            RETURN pgbackrest_monitor.hc('UNKNOWN', 'NO_DATA', 'collector is alive but has not attempted this stanza yet');
        END IF;
        IF da_crit IS NOT NULL AND pgbackrest_monitor.clock() - cs.last_attempt_at >= da_crit
           OR (SELECT count(*) FROM pgbackrest_monitor.collection_run r WHERE r.stanza_name = p_stanza AND r.outcome <> 'skipped_locked') >= 3 THEN
            RETURN pgbackrest_monitor.hc('CRITICAL', 'NO_DATA', format('no successful collection for this stanza; latest attempt: %s', v_err));
        END IF;
        RETURN pgbackrest_monitor.hc('WARNING', 'NO_DATA', format('no successful collection for this stanza yet; latest attempt: %s', v_err));
    END IF;
    IF da_crit IS NOT NULL AND cs.data_age > da_crit THEN
        RETURN pgbackrest_monitor.hc('CRITICAL', 'DATA_STALE',
                format('last successful observation %s ago (critical threshold %s); latest attempt: %s', pgbackrest_monitor.fmt_interval(cs.data_age), pgbackrest_monitor.fmt_interval(da_crit), v_err));
    END IF;
    IF da_warn IS NOT NULL AND cs.data_age > da_warn THEN
        RETURN pgbackrest_monitor.hc('WARNING', 'DATA_STALE',
                format('last successful observation %s ago (warning threshold %s); latest attempt: %s', pgbackrest_monitor.fmt_interval(cs.data_age), pgbackrest_monitor.fmt_interval(da_warn), v_err));
    END IF;
    IF cs.last_attempt_outcome NOT IN ('success', 'skipped_locked') THEN
        RETURN pgbackrest_monitor.hc('WARNING', 'COLLECTION_FAILING',
                format('latest collection attempt failed (%s): %s; showing data from %s ago', cs.last_attempt_outcome, v_err, pgbackrest_monitor.fmt_interval(cs.data_age)));
    END IF;
    RETURN pgbackrest_monitor.hc('OK', 'COLLECTOR_OK', format('collector %s alive, data %s old', cs.collector_id, pgbackrest_monitor.fmt_interval(cs.data_age)));
END
$$;

CREATE FUNCTION pgbackrest_monitor.evaluate_backup(p_stanza text)
RETURNS pgbackrest_monitor.health_component
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    ss      record;
    lb      record;     -- latest good backup (any repo)
    lf      record;     -- latest good full backup
    v_age   interval;
    v_err_count int;
    warn    interval := pgbackrest_monitor.setting_interval(p_stanza, 'backup_max_age_warning');
    crit    interval := pgbackrest_monitor.setting_interval(p_stanza, 'backup_max_age_critical');
    fwarn   interval := pgbackrest_monitor.setting_interval(p_stanza, 'full_backup_max_age_warning');
    v_note  text := '';
BEGIN
    SELECT * INTO ss FROM pgbackrest_monitor.stanza_state WHERE stanza_name = p_stanza;
    IF ss IS NULL THEN
        RETURN pgbackrest_monitor.hc('UNKNOWN', 'BACKUP_NO_DATA', 'no successful collection yet; backup state unknown');
    END IF;
    IF ss.status_code = 5 THEN
        RETURN pgbackrest_monitor.hc('CRITICAL', 'STANZA_DB_MISMATCH', format('pgBackRest reports: %s', ss.status_message));
    END IF;

    SELECT * INTO lb FROM pgbackrest_monitor.backup
    WHERE stanza_name = p_stanza AND present AND NOT COALESCE(has_error, false)
    ORDER BY stopped_at DESC LIMIT 1;
    SELECT count(*) INTO v_err_count FROM pgbackrest_monitor.backup
    WHERE stanza_name = p_stanza AND present AND has_error;

    IF lb IS NULL THEN
        IF v_err_count > 0 THEN
            RETURN pgbackrest_monitor.hc('CRITICAL', 'BACKUP_NONE_VALID', format('%s backup(s) present but all are flagged with errors by pgBackRest', v_err_count));
        END IF;
        IF ss.backup_lock_held THEN
            RETURN pgbackrest_monitor.hc('CRITICAL', 'BACKUP_NONE', 'no completed backup exists in any repository (a backup/expire operation is currently running)');
        END IF;
        RETURN pgbackrest_monitor.hc('CRITICAL', 'BACKUP_NONE', 'no completed backup exists in any repository');
    END IF;

    v_age := pgbackrest_monitor.clock() - lb.stopped_at;
    IF v_err_count > 0 THEN
        v_note := format('; %s present backup(s) flagged with errors', v_err_count);
    END IF;
    IF crit IS NOT NULL AND v_age > crit THEN
        RETURN pgbackrest_monitor.hc('CRITICAL', 'BACKUP_TOO_OLD',
                format('latest good backup %s (%s, repo%s) completed %s ago, exceeds critical threshold %s%s',
                       lb.label, lb.backup_type, lb.repo_key, pgbackrest_monitor.fmt_interval(v_age), pgbackrest_monitor.fmt_interval(crit), v_note));
    END IF;
    IF warn IS NOT NULL AND v_age > warn THEN
        RETURN pgbackrest_monitor.hc('WARNING', 'BACKUP_TOO_OLD',
                format('latest good backup %s (%s, repo%s) completed %s ago, exceeds warning threshold %s%s',
                       lb.label, lb.backup_type, lb.repo_key, pgbackrest_monitor.fmt_interval(v_age), pgbackrest_monitor.fmt_interval(warn), v_note));
    END IF;
    IF fwarn IS NOT NULL THEN
        SELECT * INTO lf FROM pgbackrest_monitor.backup
        WHERE stanza_name = p_stanza AND present AND NOT COALESCE(has_error, false) AND backup_type = 'full'
        ORDER BY stopped_at DESC LIMIT 1;
        IF lf IS NULL OR pgbackrest_monitor.clock() - lf.stopped_at > fwarn THEN
            RETURN pgbackrest_monitor.hc('WARNING', 'BACKUP_FULL_TOO_OLD',
                    format('latest good full backup %s, exceeds threshold %s%s',
                           CASE WHEN lf IS NULL THEN 'does not exist' ELSE 'completed ' || pgbackrest_monitor.fmt_interval(pgbackrest_monitor.clock() - lf.stopped_at) || ' ago' END, pgbackrest_monitor.fmt_interval(fwarn), v_note));
        END IF;
    END IF;
    IF v_err_count > 0 THEN
        RETURN pgbackrest_monitor.hc('WARNING', 'BACKUP_HAS_ERROR',
                format('latest good backup %s (%s) completed %s ago%s', lb.label, lb.backup_type, pgbackrest_monitor.fmt_interval(v_age), v_note));
    END IF;
    RETURN pgbackrest_monitor.hc('OK', 'BACKUP_OK',
            format('latest backup %s (%s, repo%s) completed %s ago', lb.label, lb.backup_type, lb.repo_key, pgbackrest_monitor.fmt_interval(v_age)));
END
$$;

CREATE FUNCTION pgbackrest_monitor.evaluate_repo(p_stanza text, p_repo_key integer)
RETURNS pgbackrest_monitor.health_component
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    rs record;
    v_sev text := COALESCE(NULLIF(pgbackrest_monitor.setting(p_stanza, 'repo_no_backups_severity'), ''), 'WARNING');
BEGIN
    SELECT * INTO rs FROM pgbackrest_monitor.repo_state WHERE stanza_name = p_stanza AND repo_key = p_repo_key;
    IF rs IS NULL THEN
        RETURN pgbackrest_monitor.hc('UNKNOWN', 'REPO_NO_DATA', format('repo%s has not been observed', p_repo_key));
    END IF;
    CASE rs.status_code
        WHEN 0 THEN RETURN pgbackrest_monitor.hc('OK', 'REPO_OK', format('repo%s ok', p_repo_key));
        WHEN 2 THEN RETURN pgbackrest_monitor.hc(v_sev, 'REPO_NO_BACKUPS', format('repo%s: %s', p_repo_key, rs.status_message));
        WHEN 1 THEN RETURN pgbackrest_monitor.hc('CRITICAL', 'REPO_STANZA_MISSING', format('repo%s: %s (stanza path missing: not created, wrong repo path, or repository unreachable)', p_repo_key, rs.status_message));
        WHEN 3 THEN RETURN pgbackrest_monitor.hc('CRITICAL', 'REPO_STANZA_DATA_MISSING', format('repo%s: %s', p_repo_key, rs.status_message));
        WHEN 5 THEN RETURN pgbackrest_monitor.hc('CRITICAL', 'REPO_DB_MISMATCH', format('repo%s: %s', p_repo_key, rs.status_message));
        WHEN 6 THEN RETURN pgbackrest_monitor.hc('WARNING', 'REPO_BACKUP_NOT_FOUND', format('repo%s: %s', p_repo_key, rs.status_message));
        WHEN 99 THEN RETURN pgbackrest_monitor.hc('CRITICAL', 'REPO_ERROR', format('repo%s: %s', p_repo_key, rs.status_message));
        ELSE RETURN pgbackrest_monitor.hc('WARNING', 'REPO_STATUS_UNRECOGNIZED', format('repo%s: status code %s (%s)', p_repo_key, rs.status_code, rs.status_message));
    END CASE;
END
$$;

-- Archive health for one stanza/repository pair.
CREATE FUNCTION pgbackrest_monitor.evaluate_archive(p_stanza text, p_repo_key integer)
RETURNS pgbackrest_monitor.health_component
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    st      record;
    rs      record;
    pg      record;
    v_expected      boolean;
    v_last_wal      text;
    v_lag           bigint;      -- completed segments not yet archived by PostgreSQL
    v_repo_gap      bigint;      -- segments pg_stat_archiver is ahead of the repository archive max
    v_since_ok      interval;
    lag_warn  bigint   := pgbackrest_monitor.setting_bigint(p_stanza, 'archive_lag_segments_warning');
    lag_crit  bigint   := pgbackrest_monitor.setting_bigint(p_stanza, 'archive_lag_segments_critical');
    stale     interval := pgbackrest_monitor.setting_interval(p_stanza, 'archive_stale_warning');
    fail_crit interval := pgbackrest_monitor.setting_interval(p_stanza, 'archive_failing_critical_after');
    gap_warn  bigint   := pgbackrest_monitor.setting_bigint(p_stanza, 'archive_repo_gap_segments_warning');
    da_crit   interval := pgbackrest_monitor.setting_interval(p_stanza, 'data_stale_critical');
BEGIN
    SELECT * INTO st FROM pgbackrest_monitor.stanza WHERE stanza_name = p_stanza;
    SELECT * INTO rs FROM pgbackrest_monitor.repo_state WHERE stanza_name = p_stanza AND repo_key = p_repo_key;
    IF rs IS NULL THEN
        RETURN pgbackrest_monitor.hc('UNKNOWN', 'ARCHIVE_NO_REPO_DATA', format('repo%s has not been observed', p_repo_key));
    END IF;
    IF rs.status_code IN (1, 3, 5, 99) THEN
        RETURN pgbackrest_monitor.hc('UNKNOWN', 'ARCHIVE_REPO_UNAVAILABLE', format('repo%s archive metadata unavailable: %s', p_repo_key, rs.status_message));
    END IF;

    IF st.pg_instance IS NULL THEN
        IF rs.archive_max IS NULL THEN
            RETURN pgbackrest_monitor.hc('WARNING', 'ARCHIVE_REPO_EMPTY', format('repo%s contains no archived WAL for the current database; no PostgreSQL archiver statistics configured for this stanza', p_repo_key));
        END IF;
        RETURN pgbackrest_monitor.hc('OK', 'ARCHIVE_NO_PG_COMPARISON',
                format('repo%s archive %s..%s; no PostgreSQL archiver statistics configured for this stanza', p_repo_key, rs.archive_min, rs.archive_max));
    END IF;

    SELECT * INTO pg FROM pgbackrest_monitor.latest_pg_archiver WHERE instance = st.pg_instance;
    IF pg IS NULL THEN
        RETURN pgbackrest_monitor.hc('UNKNOWN', 'ARCHIVE_NO_PG_SAMPLE', format('no pg_stat_archiver sample has been collected for instance %s', st.pg_instance));
    END IF;
    IF da_crit IS NOT NULL AND pg.sample_age > da_crit THEN
        RETURN pgbackrest_monitor.hc('UNKNOWN', 'ARCHIVE_PG_SAMPLE_STALE', format('latest pg_stat_archiver sample is %s old', pgbackrest_monitor.fmt_interval(pg.sample_age)));
    END IF;

    v_expected := pg.archive_mode = 'always' OR (pg.archive_mode = 'on' AND NOT pg.in_recovery);
    IF NOT v_expected THEN
        IF pg.archive_mode = 'off' AND NOT pg.in_recovery THEN
            RETURN pgbackrest_monitor.hc('CRITICAL', 'ARCHIVE_MODE_OFF', 'archive_mode is off on this primary; WAL is not being archived');
        END IF;
        RETURN pgbackrest_monitor.hc('OK', 'ARCHIVE_NOT_EXPECTED',
                format('this %s does not archive WAL (archive_mode=%s); repo%s archive max %s',
                       CASE WHEN pg.in_recovery THEN 'standby' ELSE 'server' END, pg.archive_mode, p_repo_key, COALESCE(rs.archive_max, 'none')));
    END IF;
    IF pg.archive_command_set IS FALSE AND pg.archive_library_set IS NOT TRUE THEN
        RETURN pgbackrest_monitor.hc('CRITICAL', 'ARCHIVE_COMMAND_UNSET', 'archive_mode is on but neither archive_command nor archive_library is set');
    END IF;

    v_last_wal := pgbackrest_monitor.wal_segment_name(pg.last_archived_wal);
    v_since_ok := pgbackrest_monitor.clock() - pg.last_archived_time;

    -- Currently failing: the most recent archiver event is a failure.
    IF pg.last_failed_time IS NOT NULL AND (pg.last_archived_time IS NULL OR pg.last_failed_time > pg.last_archived_time) THEN
        IF pg.last_archived_time IS NULL OR (fail_crit IS NOT NULL AND v_since_ok > fail_crit) THEN
            RETURN pgbackrest_monitor.hc('CRITICAL', 'ARCHIVE_FAILING',
                    format('PostgreSQL archiver is failing: %s failure(s), last on %s at %s; last success %s',
                           pg.failed_count, pg.last_failed_wal, to_char(pg.last_failed_time, 'YYYY-MM-DD HH24:MI:SSOF'),
                           CASE WHEN v_since_ok IS NULL THEN 'never' ELSE pgbackrest_monitor.fmt_interval(v_since_ok) || ' ago' END));
        END IF;
        RETURN pgbackrest_monitor.hc('WARNING', 'ARCHIVE_FAILING',
                format('PostgreSQL archiver failed on %s at %s (%s failure(s)); last success %s ago',
                       pg.last_failed_wal, to_char(pg.last_failed_time, 'YYYY-MM-DD HH24:MI:SSOF'), pg.failed_count, pgbackrest_monitor.fmt_interval(v_since_ok)));
    END IF;

    -- Lag: completed segments the archiver has not yet shipped (same timeline only).
    IF pg.current_wal_file IS NOT NULL AND v_last_wal IS NOT NULL
       AND pgbackrest_monitor.wal_timeline(pg.current_wal_file) = pgbackrest_monitor.wal_timeline(v_last_wal) THEN
        v_lag := greatest(pgbackrest_monitor.wal_segno(pg.current_wal_file, pg.wal_segment_size)
                        - pgbackrest_monitor.wal_segno(v_last_wal, pg.wal_segment_size) - 1, 0);
    ELSIF v_last_wal IS NULL AND pg.current_wal_file IS NOT NULL AND COALESCE(pg.archived_count, 0) = 0 THEN
        -- Nothing archived since statistics were (re)set; every completed segment on this timeline is unaccounted for.
        v_lag := pgbackrest_monitor.wal_segno(pg.current_wal_file, pg.wal_segment_size)
               - pgbackrest_monitor.wal_segno(pgbackrest_monitor.wal_file_name(pg.timeline_id, '0/0'::pg_lsn, pg.wal_segment_size), pg.wal_segment_size);
        IF v_lag > 0 THEN
            RETURN pgbackrest_monitor.hc(CASE WHEN lag_crit IS NOT NULL AND v_lag >= lag_crit THEN 'CRITICAL' ELSE 'WARNING' END, 'ARCHIVE_NEVER',
                    format('pg_stat_archiver shows no successful archive since %s while %s WAL segment(s) have completed', COALESCE(to_char(pg.stats_reset, 'YYYY-MM-DD HH24:MI:SSOF'), 'startup'), v_lag));
        END IF;
    END IF;

    IF v_lag IS NOT NULL AND lag_crit IS NOT NULL AND v_lag >= lag_crit THEN
        RETURN pgbackrest_monitor.hc('CRITICAL', 'ARCHIVE_LAG',
                format('%s completed WAL segment(s) waiting for the archiver (critical threshold %s); last archived %s %s ago',
                       v_lag, lag_crit, v_last_wal, pgbackrest_monitor.fmt_interval(v_since_ok)));
    END IF;
    IF v_lag IS NOT NULL AND lag_warn IS NOT NULL AND v_lag >= lag_warn THEN
        RETURN pgbackrest_monitor.hc('WARNING', 'ARCHIVE_LAG',
                format('%s completed WAL segment(s) waiting for the archiver (warning threshold %s); last archived %s %s ago',
                       v_lag, lag_warn, v_last_wal, pgbackrest_monitor.fmt_interval(v_since_ok)));
    END IF;
    IF v_lag IS NOT NULL AND v_lag > 0 AND stale IS NOT NULL AND v_since_ok > stale THEN
        RETURN pgbackrest_monitor.hc('WARNING', 'ARCHIVE_STALE',
                format('%s completed WAL segment(s) waiting and the last successful archive (%s) was %s ago', v_lag, v_last_wal, pgbackrest_monitor.fmt_interval(v_since_ok)));
    END IF;

    -- Repository side: does pgBackRest's archive keep up with what PostgreSQL says it archived?
    IF rs.archive_max IS NULL THEN
        IF v_last_wal IS NOT NULL THEN
            RETURN pgbackrest_monitor.hc('WARNING', 'ARCHIVE_REPO_EMPTY',
                    format('PostgreSQL has archived up to %s but repo%s reports no archived WAL for the current database', v_last_wal, p_repo_key));
        END IF;
        RETURN pgbackrest_monitor.hc('OK', 'ARCHIVE_IDLE', format('no WAL archived yet and none waiting; repo%s archive empty', p_repo_key));
    END IF;
    IF v_last_wal IS NOT NULL AND pgbackrest_monitor.wal_timeline(rs.archive_max) = pgbackrest_monitor.wal_timeline(v_last_wal) THEN
        v_repo_gap := pgbackrest_monitor.wal_segno(v_last_wal, pg.wal_segment_size)
                    - pgbackrest_monitor.wal_segno(rs.archive_max, pg.wal_segment_size);
        IF gap_warn IS NOT NULL AND v_repo_gap >= gap_warn THEN
            RETURN pgbackrest_monitor.hc('WARNING', 'ARCHIVE_REPO_BEHIND',
                    format('repo%s archive max %s is %s segment(s) behind pg_stat_archiver.last_archived_wal %s (observed %s apart)',
                           p_repo_key, rs.archive_max, v_repo_gap, v_last_wal, pgbackrest_monitor.fmt_interval(greatest(pg.sampled_at - rs.observed_at, rs.observed_at - pg.sampled_at))));
        END IF;
    END IF;

    IF COALESCE(v_lag, 0) = 0 AND stale IS NOT NULL AND v_since_ok > stale THEN
        RETURN pgbackrest_monitor.hc('OK', 'ARCHIVE_IDLE',
                format('no completed WAL waiting; last archived %s %s ago (idle database); repo%s archive max %s',
                       v_last_wal, pgbackrest_monitor.fmt_interval(v_since_ok), p_repo_key, rs.archive_max));
    END IF;
    RETURN pgbackrest_monitor.hc('OK', 'ARCHIVE_OK',
            format('last archived %s %s ago, %s segment(s) waiting; repo%s archive %s..%s',
                   COALESCE(v_last_wal, 'none'), pgbackrest_monitor.fmt_interval(v_since_ok), COALESCE(v_lag, 0), p_repo_key, rs.archive_min, rs.archive_max));
END
$$;

------------------------------------------------------------------------------------------------
-- 8. Public views
------------------------------------------------------------------------------------------------
CREATE VIEW pgbackrest_monitor.backup_status AS
SELECT st.stanza_name,
       lb.repo_key,
       lb.label                                     AS latest_backup_label,
       lb.backup_type                               AS latest_backup_type,
       lb.started_at                                AS backup_started_at,
       lb.stopped_at                                AS backup_stopped_at,
       lb.stopped_at - lb.started_at                AS backup_duration,
       lb.database_size, lb.backup_size, lb.repo_set_size, lb.repo_backup_size,
       lb.wal_start, lb.wal_stop, lb.lsn_start, lb.lsn_stop,
       lb.stopped_at                                AS latest_backup_completed_at,
       pgbackrest_monitor.clock() - lb.stopped_at   AS backup_age,
       lg.label                                     AS latest_good_backup_label,
       lg.stopped_at                                AS latest_good_backup_completed_at,
       (b).status                                   AS backup_health,
       (b).reason_code,
       (b).message,
       ss.backup_lock_held                          AS backup_or_expire_running,
       be.message                                   AS latest_backup_error,
       be.occurred_at                               AS latest_backup_error_at,
       cs.last_success_at                           AS last_collected_at,
       cs.data_age,
       cs.last_attempt_outcome,
       cs.last_failure_error                        AS latest_collection_error,
       cs.last_failure_at                           AS latest_collection_error_at
FROM pgbackrest_monitor.stanza st
LEFT JOIN pgbackrest_monitor.stanza_state ss USING (stanza_name)
LEFT JOIN pgbackrest_monitor.collection_status cs USING (stanza_name)
LEFT JOIN LATERAL (SELECT * FROM pgbackrest_monitor.backup bk
                   WHERE bk.stanza_name = st.stanza_name AND bk.present ORDER BY bk.stopped_at DESC LIMIT 1) lb ON true
LEFT JOIN LATERAL (SELECT * FROM pgbackrest_monitor.backup bk
                   WHERE bk.stanza_name = st.stanza_name AND bk.present AND NOT COALESCE(bk.has_error, false)
                   ORDER BY bk.stopped_at DESC LIMIT 1) lg ON true
LEFT JOIN LATERAL (SELECT * FROM pgbackrest_monitor.error_history e
                   WHERE e.stanza_name = st.stanza_name AND e.category IN ('backup_error', 'repo_status')
                   ORDER BY e.occurred_at DESC LIMIT 1) be ON true
CROSS JOIN LATERAL (SELECT pgbackrest_monitor.evaluate_backup(st.stanza_name) AS b) h;

-- Same facts per repository (the latest backup in each repository).
CREATE VIEW pgbackrest_monitor.backup_status_by_repo AS
SELECT rs.stanza_name, rs.repo_key, rs.status_code AS repo_status_code, rs.status_message AS repo_status_message,
       lb.label AS latest_backup_label, lb.backup_type AS latest_backup_type,
       lb.started_at AS backup_started_at, lb.stopped_at AS backup_stopped_at,
       lb.stopped_at - lb.started_at AS backup_duration,
       lb.database_size, lb.backup_size, lb.repo_set_size, lb.repo_backup_size, lb.has_error,
       pgbackrest_monitor.clock() - lb.stopped_at AS backup_age,
       (SELECT count(*) FROM pgbackrest_monitor.backup b WHERE b.stanza_name = rs.stanza_name AND b.repo_key = rs.repo_key AND b.present) AS backup_count,
       rs.observed_at
FROM pgbackrest_monitor.repo_state rs
LEFT JOIN LATERAL (SELECT * FROM pgbackrest_monitor.backup bk
                   WHERE bk.stanza_name = rs.stanza_name AND bk.repo_key = rs.repo_key AND bk.present
                   ORDER BY bk.stopped_at DESC LIMIT 1) lb ON true;

CREATE VIEW pgbackrest_monitor.archive_status AS
SELECT rs.stanza_name, rs.repo_key, st.pg_instance,
       rs.archive_id,
       rs.archive_min                               AS repo_archive_min,
       rs.archive_max                               AS repo_archive_max,
       rs.observed_at                               AS repo_observed_at,
       pg.last_archived_wal                         AS pg_last_archived_wal,
       pg.last_archived_time                        AS pg_last_archived_time,
       pg.archived_count                            AS pg_archived_count,
       pg.failed_count                              AS pg_failed_count,
       pg.last_failed_wal                           AS pg_last_failed_wal,
       pg.last_failed_time                          AS pg_last_failed_time,
       pg.stats_reset                               AS pg_stats_reset,
       pg.sampled_at                                AS pg_sampled_at,
       pg.sample_age                                AS pg_sample_age,
       pg.in_recovery, pg.archive_mode,
       pg.current_wal_file                          AS pg_current_wal_file,
       pgbackrest_monitor.clock() - pg.last_archived_time AS time_since_last_archive,
       -- derived: completed segments PostgreSQL has not archived yet (same timeline only)
       CASE WHEN pg.current_wal_file IS NOT NULL
                 AND pgbackrest_monitor.wal_segment_name(pg.last_archived_wal) IS NOT NULL
                 AND pgbackrest_monitor.wal_timeline(pg.current_wal_file) = pgbackrest_monitor.wal_timeline(pg.last_archived_wal)
            THEN greatest(pgbackrest_monitor.wal_segno(pg.current_wal_file, pg.wal_segment_size)
                        - pgbackrest_monitor.wal_segno(pg.last_archived_wal, pg.wal_segment_size) - 1, 0) END AS pg_segments_waiting,
       -- derived: how far the repository archive trails what PostgreSQL reports as archived
       CASE WHEN rs.archive_max IS NOT NULL
                 AND pgbackrest_monitor.wal_segment_name(pg.last_archived_wal) IS NOT NULL
                 AND pgbackrest_monitor.wal_timeline(rs.archive_max) = pgbackrest_monitor.wal_timeline(pg.last_archived_wal)
            THEN pgbackrest_monitor.wal_segno(pg.last_archived_wal, pg.wal_segment_size)
               - pgbackrest_monitor.wal_segno(rs.archive_max, pg.wal_segment_size) END AS repo_segments_behind_pg,
       (a).status AS archive_health, (a).reason_code, (a).message
FROM pgbackrest_monitor.repo_state rs
JOIN pgbackrest_monitor.stanza st USING (stanza_name)
LEFT JOIN pgbackrest_monitor.latest_pg_archiver pg ON pg.instance = st.pg_instance
CROSS JOIN LATERAL (SELECT pgbackrest_monitor.evaluate_archive(rs.stanza_name, rs.repo_key) AS a) h;

CREATE VIEW pgbackrest_monitor.repository_status AS
SELECT rs.stanza_name, rs.repo_key,
       rs.status_code, rs.status_message, rs.cipher,
       -- the info command listed this repository's stanza path at observed_at: that is the reachability test
       true                                         AS reachability_checked,
       rs.status_code NOT IN (1, 99)                AS reachable_at_observation,
       rs.observed_at                               AS last_status_collected_at,
       pgbackrest_monitor.clock() - rs.observed_at  AS observation_age,
       (pgbackrest_monitor.clock() - rs.observed_at) <= COALESCE(pgbackrest_monitor.setting_interval(rs.stanza_name, 'data_stale_warning'), '15 minutes')
                                                    AS is_fresh,
       rs.has_backup_metadata, rs.has_archive_metadata,
       rs.db_id, rs.db_version, rs.db_system_id,
       re.message                                   AS latest_repo_error,
       re.occurred_at                               AS latest_repo_error_at,
       cs.last_failure_error                        AS latest_collection_error,
       cs.last_failure_at                           AS latest_collection_error_at,
       (r).status AS repo_health, (r).reason_code, (r).message
FROM pgbackrest_monitor.repo_state rs
LEFT JOIN pgbackrest_monitor.collection_status cs USING (stanza_name)
LEFT JOIN LATERAL (SELECT * FROM pgbackrest_monitor.error_history e
                   WHERE e.stanza_name = rs.stanza_name AND e.repo_key = rs.repo_key AND e.category = 'repo_status'
                   ORDER BY e.occurred_at DESC LIMIT 1) re ON true
CROSS JOIN LATERAL (SELECT pgbackrest_monitor.evaluate_repo(rs.stanza_name, rs.repo_key) AS r) h;

CREATE VIEW pgbackrest_monitor.backup_history AS
SELECT b.stanza_name, b.repo_key, b.label, b.backup_type,
       b.started_at, b.stopped_at, b.stopped_at - b.started_at AS duration,
       b.database_size, b.backup_size, b.repo_set_size, b.repo_backup_size,
       b.wal_start, b.wal_stop, b.lsn_start, b.lsn_stop,
       b.prior_label, b.reference_labels, b.annotation,
       CASE WHEN b.has_error THEN 'error' WHEN NOT b.present THEN 'expired' ELSE 'ok' END AS backup_status,
       b.has_error, b.present, b.first_seen_at, b.last_seen_at, b.expired_detected_at,
       b.pgbackrest_version, b.pgbackrest_format, b.db_id
FROM pgbackrest_monitor.backup b;

-- Current and recent operations.  Two sources, both with limits (see README "Operation visibility"):
--  * pgbackrest_lock: backup/expire and restore lock state reported by `info`, sampled at collection time
--  * collector:       the monitoring collector's own pgBackRest invocations
CREATE VIEW pgbackrest_monitor.operation_status AS
SELECT ss.stanza_name, 'pgbackrest_lock'::text AS source, 'backup/expire'::text AS operation,
       CASE WHEN ss.backup_lock_held THEN 'running' ELSE 'not running' END AS state,
       ss.observed_at AS observed_at, NULL::timestamptz AS finished_at,
       ss.backup_lock_pct_cplt AS pct_complete, ss.backup_lock_size AS size_total, ss.backup_lock_size_cplt AS size_complete,
       NULL::integer AS exit_code, NULL::text AS detail, true AS is_current
FROM pgbackrest_monitor.stanza_state ss
UNION ALL
SELECT ss.stanza_name, 'pgbackrest_lock', 'restore',
       CASE WHEN ss.restore_lock_held THEN 'running' ELSE 'not running' END,
       ss.observed_at, NULL, ss.restore_lock_pct_cplt, ss.restore_lock_size, ss.restore_lock_size_cplt, NULL, NULL, true
FROM pgbackrest_monitor.stanza_state ss
UNION ALL
SELECT o.stanza_name, 'pgbackrest_lock', o.operation,
       CASE WHEN o.held THEN 'running' ELSE 'released' END,
       o.observed_at, NULL, o.pct_complete, o.size_total, o.size_complete, NULL, o.repo_progress::text, false
FROM pgbackrest_monitor.operation_observation o
UNION ALL
SELECT r.stanza_name, 'collector', 'pgbackrest ' || r.command,
       CASE WHEN r.outcome = 'success' THEN 'completed' WHEN r.outcome = 'skipped_locked' THEN 'skipped' ELSE 'failed' END,
       r.started_at, r.finished_at, NULL, NULL, NULL, r.exit_code,
       COALESCE(r.error_message, r.outcome), false
FROM pgbackrest_monitor.collection_run r;

CREATE VIEW pgbackrest_monitor.health AS
WITH per_stanza AS (
    SELECT st.stanza_name,
           pgbackrest_monitor.evaluate_collector(st.stanza_name) AS c,
           pgbackrest_monitor.evaluate_backup(st.stanza_name)    AS b,
           (SELECT array_agg(pgbackrest_monitor.evaluate_archive(st.stanza_name, rs.repo_key) ORDER BY rs.repo_key)
            FROM pgbackrest_monitor.repo_state rs WHERE rs.stanza_name = st.stanza_name) AS a,
           (SELECT array_agg(pgbackrest_monitor.evaluate_repo(st.stanza_name, rs.repo_key) ORDER BY rs.repo_key)
            FROM pgbackrest_monitor.repo_state rs WHERE rs.stanza_name = st.stanza_name) AS r
    FROM pgbackrest_monitor.stanza st
), agg AS (
    SELECT stanza_name, c, b,
           COALESCE(a, ARRAY[ROW('UNKNOWN', 'ARCHIVE_NO_REPO_DATA', 'no repository observed yet')::pgbackrest_monitor.health_component]) AS a,
           COALESCE(r, ARRAY[ROW('UNKNOWN', 'REPO_NO_DATA', 'no repository observed yet')::pgbackrest_monitor.health_component]) AS r
    FROM per_stanza
), worst AS (
    SELECT stanza_name, c, b, a, r,
           (SELECT x FROM unnest(a) x ORDER BY pgbackrest_monitor.health_rank((x).status) DESC LIMIT 1) AS aw,
           (SELECT x FROM unnest(r) x ORDER BY pgbackrest_monitor.health_rank((x).status) DESC LIMIT 1) AS rw
    FROM agg
)
SELECT w.stanza_name,
       CASE WHEN (w.c).reason_code = 'MONITORING_DISABLED' THEN 'UNKNOWN'
            ELSE pgbackrest_monitor.worst_status(ARRAY[(w.c).status, (w.b).status, (w.aw).status, (w.rw).status]) END AS overall_status,
       (w.b).status  AS backup_status,
       (w.aw).status AS archive_status,
       (w.rw).status AS repository_status,
       (w.c).status  AS collector_status,
       lb.label                                     AS last_successful_backup,
       lb.backup_type                               AS last_successful_backup_type,
       lb.stopped_at                                AS last_successful_backup_at,
       pgbackrest_monitor.clock() - lb.stopped_at   AS backup_age,
       lb.wal_start                                 AS backup_wal_start,
       lb.wal_stop                                  AS backup_wal_stop,
       pg.last_archived_wal                         AS pg_last_archived_wal,
       pg.last_archived_time                        AS pg_last_archived_time,
       pg.failed_count                              AS pg_archive_failed_count,
       pg.last_failed_wal                           AS pg_last_failed_wal,
       pg.last_failed_time                          AS pg_last_failed_time,
       (SELECT string_agg(format('repo%s=%s(%s)', rs.repo_key, rs.status_message, rs.status_code), ', ' ORDER BY rs.repo_key)
        FROM pgbackrest_monitor.repo_state rs WHERE rs.stanza_name = w.stanza_name) AS repository_summary,
       (SELECT string_agg(format('repo%s=%s..%s', rs.repo_key, COALESCE(rs.archive_min, '-'), COALESCE(rs.archive_max, '-')), ', ' ORDER BY rs.repo_key)
        FROM pgbackrest_monitor.repo_state rs WHERE rs.stanza_name = w.stanza_name) AS repository_archive_summary,
       ss.backup_lock_held                          AS backup_or_expire_running,
       ss.restore_lock_held                         AS restore_running,
       cs.collector_id, cs.last_heartbeat, cs.heartbeat_age,
       cs.last_success_at                           AS last_collected_at,
       cs.data_age,
       cs.last_attempt_outcome,
       cs.last_failure_error                        AS latest_collection_error,
       ARRAY[(w.c).reason_code, (w.b).reason_code] || ARRAY(SELECT (x).reason_code FROM unnest(w.a) x) || ARRAY(SELECT (x).reason_code FROM unnest(w.r) x) AS reason_codes,
       ARRAY[(w.c).message, (w.b).message]         || ARRAY(SELECT (x).message FROM unnest(w.a) x)     || ARRAY(SELECT (x).message FROM unnest(w.r) x)     AS messages,
       pgbackrest_monitor.clock()                   AS evaluated_at
FROM worst w
LEFT JOIN pgbackrest_monitor.stanza st USING (stanza_name)
LEFT JOIN pgbackrest_monitor.stanza_state ss USING (stanza_name)
LEFT JOIN pgbackrest_monitor.collection_status cs USING (stanza_name)
LEFT JOIN pgbackrest_monitor.latest_pg_archiver pg ON pg.instance = st.pg_instance
LEFT JOIN LATERAL (SELECT * FROM pgbackrest_monitor.backup bk
                   WHERE bk.stanza_name = w.stanza_name AND bk.present AND NOT COALESCE(bk.has_error, false)
                   ORDER BY bk.stopped_at DESC LIMIT 1) lb ON true;

-- Flat, one row per (stanza, component) for alerting systems.
CREATE VIEW pgbackrest_monitor.health_components AS
SELECT h.stanza_name, 'collector' AS component, (c).status, (c).reason_code, (c).message
FROM pgbackrest_monitor.stanza h CROSS JOIN LATERAL (SELECT pgbackrest_monitor.evaluate_collector(h.stanza_name) c) x
UNION ALL
SELECT h.stanza_name, 'backup', (c).status, (c).reason_code, (c).message
FROM pgbackrest_monitor.stanza h CROSS JOIN LATERAL (SELECT pgbackrest_monitor.evaluate_backup(h.stanza_name) c) x
UNION ALL
SELECT rs.stanza_name, 'archive/repo' || rs.repo_key, (c).status, (c).reason_code, (c).message
FROM pgbackrest_monitor.repo_state rs CROSS JOIN LATERAL (SELECT pgbackrest_monitor.evaluate_archive(rs.stanza_name, rs.repo_key) c) x
UNION ALL
SELECT rs.stanza_name, 'repository/repo' || rs.repo_key, (c).status, (c).reason_code, (c).message
FROM pgbackrest_monitor.repo_state rs CROSS JOIN LATERAL (SELECT pgbackrest_monitor.evaluate_repo(rs.stanza_name, rs.repo_key) c) x;

------------------------------------------------------------------------------------------------
-- 9. Privileges
------------------------------------------------------------------------------------------------
REVOKE ALL ON SCHEMA pgbackrest_monitor FROM PUBLIC;
GRANT USAGE ON SCHEMA pgbackrest_monitor TO pgbackrest_monitor_reader, pgbackrest_monitor_collector;

REVOKE ALL ON ALL TABLES IN SCHEMA pgbackrest_monitor FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgbackrest_monitor FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA pgbackrest_monitor FROM PUBLIC;

GRANT SELECT ON ALL TABLES IN SCHEMA pgbackrest_monitor TO pgbackrest_monitor_reader, pgbackrest_monitor_collector;

GRANT EXECUTE ON FUNCTION
    pgbackrest_monitor.clock(), pgbackrest_monitor.fmt_interval(interval), pgbackrest_monitor.hc(text, text, text), pgbackrest_monitor.health_rank(text), pgbackrest_monitor.worst_status(text[]),
    pgbackrest_monitor.default_settings(), pgbackrest_monitor.is_known_setting(text),
    pgbackrest_monitor.setting(text, text), pgbackrest_monitor.setting_interval(text, text), pgbackrest_monitor.setting_bigint(text, text),
    pgbackrest_monitor.wal_segment_name(text), pgbackrest_monitor.wal_timeline(text),
    pgbackrest_monitor.wal_segno(text, bigint), pgbackrest_monitor.wal_file_name(bigint, pg_lsn, bigint),
    pgbackrest_monitor.evaluate_collector(text), pgbackrest_monitor.evaluate_backup(text),
    pgbackrest_monitor.evaluate_repo(text, integer), pgbackrest_monitor.evaluate_archive(text, integer)
    TO pgbackrest_monitor_reader, pgbackrest_monitor_collector;

GRANT EXECUTE ON FUNCTION
    pgbackrest_monitor.register_collector(text, text, integer, text, text, interval, text[]),
    pgbackrest_monitor.heartbeat(text),
    pgbackrest_monitor.register_stanza(text, text, interval),
    pgbackrest_monitor.stanza_enabled(text),
    pgbackrest_monitor.try_lock_stanza(text), pgbackrest_monitor.unlock_stanza(text),
    pgbackrest_monitor.record_run(text, text, text, timestamptz, timestamptz, integer, text, text, jsonb),
    pgbackrest_monitor.record_error(text, text, text, text, jsonb),
    pgbackrest_monitor.sample_pg_archiver(),
    pgbackrest_monitor.record_pg_archiver_sample(text, integer, boolean, text, boolean, boolean, bigint, bigint, text, timestamptz, bigint, text, timestamptz, timestamptz, pg_lsn, bigint, numeric),
    pgbackrest_monitor.purge_history()
    TO pgbackrest_monitor_collector;
