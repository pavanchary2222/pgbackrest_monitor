-- Least privilege: reader sees, collector feeds, neither can alter configuration or history directly.
\pset null '<null>'
SET timezone = 'UTC';
-- each test file starts from a clean extension state (pg_regress shares one database)
DROP EXTENSION pgbackrest_monitor CASCADE;
CREATE EXTENSION pgbackrest_monitor;
\set lab `cat tests/fixtures/info_lab_healthy.json`
CREATE ROLE regress_pgbrmon_reader LOGIN;
CREATE ROLE regress_pgbrmon_collector LOGIN;
CREATE ROLE regress_pgbrmon_nobody LOGIN;
GRANT pgbackrest_monitor_reader TO regress_pgbrmon_reader;
GRANT pgbackrest_monitor_collector TO regress_pgbrmon_collector;

SELECT pgbackrest_monitor.register_collector('c1', 'host1', 100, '1.0.0', '2.59.3', '1 minute', ARRAY['lab']);
SELECT pgbackrest_monitor.register_stanza('lab');
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', now() - interval '2s', now() - interval '1s', 0, 'success', NULL, :'lab'::jsonb) > 0 AS recorded;

-- unrelated role: nothing
SET ROLE regress_pgbrmon_nobody;
SELECT count(*) FROM pgbackrest_monitor.health;
SELECT pgbackrest_monitor.record_run('x', 'lab', 'info', now(), now(), 0, 'success', NULL, '[]');
RESET ROLE;

-- reader: all views and tables readable, nothing writable, no collector API
SET ROLE regress_pgbrmon_reader;
SELECT stanza_name, backup_status, collector_status FROM pgbackrest_monitor.health;
SELECT count(*) > 0 AS has_backups FROM pgbackrest_monitor.backup_history;
SELECT count(*) FROM pgbackrest_monitor.error_history;
SELECT count(*) FROM pgbackrest_monitor.effective_settings;
SELECT count(*) FROM pgbackrest_monitor.operation_status;
SELECT count(*) FROM pgbackrest_monitor.archive_status;
SELECT count(*) FROM pgbackrest_monitor.repository_status;
SELECT count(*) FROM pgbackrest_monitor.backup_status;
INSERT INTO pgbackrest_monitor.config VALUES ('backup_max_age_warning', '1 hour');
UPDATE pgbackrest_monitor.stanza SET enabled = false;
DELETE FROM pgbackrest_monitor.backup;
SELECT pgbackrest_monitor.set_setting('backup_max_age_warning', '1 hour');
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', now(), now(), 0, 'success', NULL, '[]');
SELECT pgbackrest_monitor.heartbeat('c1');
SELECT pgbackrest_monitor.purge_history();
RESET ROLE;

-- collector: API only; no direct DML, no settings
SET ROLE regress_pgbrmon_collector;
SELECT pgbackrest_monitor.heartbeat('c1');
SELECT pgbackrest_monitor.try_lock_stanza('lab'), pgbackrest_monitor.try_lock_stanza('lab');
SELECT pgbackrest_monitor.unlock_stanza('lab');
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', now(), now(), 0, 'success', NULL, :'lab'::jsonb) > 0 AS recorded;
SELECT pgbackrest_monitor.record_error('lab', 'config_error', 'x') > 0 AS recorded;
SELECT pgbackrest_monitor.sample_pg_archiver() > 0 AS sampled;
SELECT count(*) FROM pgbackrest_monitor.purge_history();
SELECT stanza_name, backup_status FROM pgbackrest_monitor.health;
INSERT INTO pgbackrest_monitor.config VALUES ('backup_max_age_warning', '1 hour');
UPDATE pgbackrest_monitor.backup SET has_error = true;
DELETE FROM pgbackrest_monitor.error_history;
SELECT pgbackrest_monitor.set_setting('backup_max_age_warning', '1 hour');
RESET ROLE;

-- concurrent collection: the advisory lock is per session
SELECT pgbackrest_monitor.try_lock_stanza('lab') AS first_lock;
\c - - - -
SELECT pgbackrest_monitor.try_lock_stanza('lab') AS second_session_lock;
-- (the first session's lock vanished with its connection above; take and release in this one)
SELECT pgbackrest_monitor.unlock_stanza('lab');
SELECT pgbackrest_monitor.unlock_stanza('lab') AS already_unlocked;

-- secrets never land in stored messages when the collector passes them redacted (DB side stores verbatim)
SELECT left(pgbackrest_monitor.setting('lab', 'retention_errors'), 20) AS retention_errors;

DROP ROLE regress_pgbrmon_reader, regress_pgbrmon_collector, regress_pgbrmon_nobody;
