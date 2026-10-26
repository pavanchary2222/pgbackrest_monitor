-- Retention / purge_history
\pset null '<null>'
SET timezone = 'UTC';
-- each test file starts from a clean extension state (pg_regress shares one database)
DROP EXTENSION pgbackrest_monitor CASCADE;
CREATE EXTENSION pgbackrest_monitor;
\set lab `cat tests/fixtures/info_lab_healthy.json`
SELECT pgbackrest_monitor.register_collector('c1', 'host1', 100, '1.0.0', '2.59.3', '1 minute', ARRAY['lab']);
SELECT pgbackrest_monitor.register_stanza('lab');
SET pgbackrest_monitor.clock_override = '2026-11-30 12:00:00+00';

-- old runs (40 days), recent runs, and the latest success (which must survive with its raw JSON)
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-20 10:00:00+00', '2026-10-20 10:00:01+00', 0, 'success', NULL, :'lab'::jsonb) AS run_id;
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-21 10:00:00+00', '2026-10-21 10:00:01+00', 41, 'command_failed', 'old failure', NULL) AS run_id;
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-11-26 10:00:00+00', '2026-11-26 10:00:01+00', 0, 'success', NULL, :'lab'::jsonb) AS run_id;
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-11-30 11:00:00+00', '2026-11-30 11:00:01+00', 0, 'success', NULL, :'lab'::jsonb) AS run_id;
INSERT INTO pgbackrest_monitor.error_history (occurred_at, stanza_name, source, category, message) VALUES
    ('2026-10-01 00:00:00+00', 'lab', 'collector', 'timeout', 'old'), ('2026-11-29 00:00:00+00', 'lab', 'collector', 'timeout', 'recent');
INSERT INTO pgbackrest_monitor.operation_observation (stanza_name, observed_at, operation, held) VALUES
    ('lab', '2026-10-01 00:00:00+00', 'backup/expire', true), ('lab', '2026-11-29 00:00:00+00', 'backup/expire', false);
INSERT INTO pgbackrest_monitor.pg_archiver_sample (instance, sampled_at, server_version_num, in_recovery, archive_mode, wal_segment_size) VALUES
    ('local', '2026-11-01 00:00:00+00', 180006, false, 'on', 16777216), ('local', '2026-11-02 00:00:00+00', 180006, false, 'on', 16777216),
    ('standby1', '2026-11-01 00:00:00+00', 180006, true, 'on', 16777216), ('local', '2026-11-30 11:00:00+00', 180006, false, 'on', 16777216);
UPDATE pgbackrest_monitor.backup SET present = false, expired_detected_at = '2025-01-01 00:00:00+00' WHERE label = '20261026-110039F_20261026-110042D';
UPDATE pgbackrest_monitor.backup SET present = false, expired_detected_at = '2026-11-01 00:00:00+00' WHERE label = '20261026-110039F_20261026-110043I';

SELECT count(*) AS runs, count(raw_output) AS with_raw FROM pgbackrest_monitor.collection_run;
SELECT * FROM pgbackrest_monitor.purge_history();
SELECT started_at, outcome, raw_output IS NOT NULL AS has_raw FROM pgbackrest_monitor.collection_run ORDER BY run_id;
SELECT occurred_at, message FROM pgbackrest_monitor.error_history ORDER BY error_id;
SELECT observed_at, held FROM pgbackrest_monitor.operation_observation ORDER BY observation_id;
SELECT instance, sampled_at FROM pgbackrest_monitor.pg_archiver_sample ORDER BY instance, sampled_at;
SELECT label, present, expired_detected_at FROM pgbackrest_monitor.backup ORDER BY label;
-- shorter retention via settings
SELECT pgbackrest_monitor.set_setting('retention_runs', '1 day');
SELECT pgbackrest_monitor.set_setting('retention_raw_output', '1 hour');
SELECT * FROM pgbackrest_monitor.purge_history() WHERE table_name LIKE 'collection_run%';
SELECT started_at, outcome, raw_output IS NOT NULL AS has_raw FROM pgbackrest_monitor.collection_run ORDER BY run_id;
-- second purge is a no-op
SELECT * FROM pgbackrest_monitor.purge_history();
RESET pgbackrest_monitor.clock_override;
