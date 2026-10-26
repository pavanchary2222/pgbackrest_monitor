-- Normalisation of real and synthetic pgBackRest info output.
\pset null '<null>'
SET timezone = 'UTC';
-- each test file starts from a clean extension state (pg_regress shares one database)
DROP EXTENSION pgbackrest_monitor CASCADE;
CREATE EXTENSION pgbackrest_monitor;
\set lab `cat tests/fixtures/info_lab_healthy.json`
\set perm `cat tests/fixtures/info_lab_repo_permission_denied.json`
\set expired `cat tests/fixtures/info_lab_after_expire_synthetic.json`
\set witherr `cat tests/fixtures/info_lab_backup_error_synthetic.json`
\set legacy `cat tests/fixtures/info_legacy_single_repo_synthetic.json`
\set running `cat tests/fixtures/info_lab_backup_running_progress_synthetic.json`
\set empty `cat tests/fixtures/info_empty_no_backups.json`
\set missing `cat tests/fixtures/info_missing_stanza.json`
\set allst `cat tests/fixtures/info_all_stanzas.json`
\set bad1 `cat tests/fixtures/info_invalid_missing_fields_synthetic.json`
\set bad2 `cat tests/fixtures/info_invalid_no_status_code_synthetic.json`

SELECT pgbackrest_monitor.register_collector('c1', 'host1', 100, '1.0.0', '2.59.3', '1 minute', ARRAY['lab', 'empty', 'legacy', 'doesnotexist']);
SELECT pgbackrest_monitor.register_stanza('lab'), pgbackrest_monitor.register_stanza('empty'),
       pgbackrest_monitor.register_stanza('legacy', NULL), pgbackrest_monitor.register_stanza('doesnotexist');

-- invalid stanza names are refused by the table constraint
DO $$ BEGIN PERFORM pgbackrest_monitor.register_stanza('bad;name'); EXCEPTION WHEN check_violation THEN RAISE NOTICE 'rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM pgbackrest_monitor.register_stanza('../etc'); EXCEPTION WHEN check_violation THEN RAISE NOTICE 'rejected: %', SQLERRM; END $$;

-- 1. healthy multi-repo stanza
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:30:00+00', '2026-10-26 11:30:02+00', 0, 'success', NULL, :'lab'::jsonb) AS run_id;
SELECT stanza_name, observed_at, status_code, status_message, cipher, backup_lock_held, restore_lock_held, pgbackrest_version_seen, repo_count, backup_count
FROM pgbackrest_monitor.stanza_state ORDER BY 1;
SELECT stanza_name, repo_key, status_code, status_message, db_id, db_version, db_system_id, archive_id, archive_min, archive_max, has_backup_metadata, has_archive_metadata
FROM pgbackrest_monitor.repo_state ORDER BY 1, 2;
SELECT stanza_name, repo_key, archive_id, db_id, wal_min, wal_max FROM pgbackrest_monitor.archive_state ORDER BY 1, 2, 3;
SELECT repo_key, label, backup_type, started_at, stopped_at, duration, wal_start, wal_stop, lsn_start, lsn_stop,
       database_size, backup_size, repo_set_size, repo_backup_size, prior_label, reference_labels, has_error, backup_status, pgbackrest_version, pgbackrest_format
FROM pgbackrest_monitor.backup_history WHERE stanza_name = 'lab' ORDER BY stopped_at, repo_key;

-- 2. repo1 unreadable: status 99 recorded once, repo1 backups must NOT be marked expired
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:31:00+00', '2026-10-26 11:31:01+00', 0, 'success', NULL, :'perm'::jsonb) AS run_id;
SELECT repo_key, status_code, left(status_message, 40) AS status_message, has_backup_metadata, has_archive_metadata FROM pgbackrest_monitor.repo_state WHERE stanza_name = 'lab' ORDER BY 1;
SELECT count(*) FILTER (WHERE present) AS present, count(*) FILTER (WHERE NOT present) AS expired FROM pgbackrest_monitor.backup WHERE stanza_name = 'lab';
-- same failure again: no duplicate error row
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:32:00+00', '2026-10-26 11:32:01+00', 0, 'success', NULL, :'perm'::jsonb) AS run_id;
SELECT occurred_at, stanza_name, repo_key, source, operation, category, exit_code, left(message, 60) AS message FROM pgbackrest_monitor.error_history ORDER BY error_id;

-- 3. back to healthy, then expiry removes two repo1 backups
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:33:00+00', '2026-10-26 11:33:01+00', 0, 'success', NULL, :'lab'::jsonb) AS run_id;
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:34:00+00', '2026-10-26 11:34:01+00', 0, 'success', NULL, :'expired'::jsonb) AS run_id;
SELECT repo_key, label, backup_type, backup_status, present, expired_detected_at FROM pgbackrest_monitor.backup_history WHERE stanza_name = 'lab' ORDER BY stopped_at, repo_key;
-- a backup reappearing (e.g. restored from another repo copy) is marked present again
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:35:00+00', '2026-10-26 11:35:01+00', 0, 'success', NULL, :'lab'::jsonb) AS run_id;
SELECT count(*) FILTER (WHERE present) AS present, count(*) FILTER (WHERE NOT present) AS expired FROM pgbackrest_monitor.backup WHERE stanza_name = 'lab';

-- 4. newest backup flagged with errors: error recorded once; latest good backup differs from latest
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:36:00+00', '2026-10-26 11:36:01+00', 0, 'success', NULL, :'witherr'::jsonb) AS run_id;
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:37:00+00', '2026-10-26 11:37:01+00', 0, 'success', NULL, :'witherr'::jsonb) AS run_id;
SELECT latest_backup_label, latest_good_backup_label, backup_health, reason_code, left(latest_backup_error, 50) AS latest_backup_error
FROM pgbackrest_monitor.backup_status WHERE stanza_name = 'lab';
SELECT count(*) FROM pgbackrest_monitor.error_history WHERE category = 'backup_error';
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:38:00+00', '2026-10-26 11:38:01+00', 0, 'success', NULL, :'lab'::jsonb) AS run_id;

-- 5. running backup with progress -> operation observations (running, then released)
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:39:00+00', '2026-10-26 11:39:01+00', 0, 'success', NULL, :'running'::jsonb) AS run_id;
SELECT backup_lock_held, backup_lock_size, backup_lock_size_cplt, backup_lock_pct_cplt, restore_lock_held FROM pgbackrest_monitor.stanza_state WHERE stanza_name = 'lab';
SELECT source, operation, state, observed_at, pct_complete, size_total, size_complete, is_current FROM pgbackrest_monitor.operation_status
WHERE stanza_name = 'lab' AND source = 'pgbackrest_lock' ORDER BY observed_at, operation;
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:40:00+00', '2026-10-26 11:40:01+00', 0, 'success', NULL, :'lab'::jsonb) AS run_id;
SELECT observed_at, operation, held, pct_complete, repo_progress FROM pgbackrest_monitor.operation_observation ORDER BY observation_id;

-- 6. pre-2.33 single-repository shape (no repo array / repo-key): synthesised repo key 1
SELECT pgbackrest_monitor.record_run('c1', 'legacy', 'info', '2026-10-26 11:41:00+00', '2026-10-26 11:41:01+00', 0, 'success', NULL,
       jsonb_set(:'legacy'::jsonb, '{0,name}', '"legacy"')) AS run_id;
SELECT stanza_name, repo_key, status_code, status_message, archive_id, archive_min, archive_max, db_version FROM pgbackrest_monitor.repo_state WHERE stanza_name = 'legacy';
SELECT repo_key, label, backup_type, lsn_start, has_error, pgbackrest_version FROM pgbackrest_monitor.backup_history WHERE stanza_name = 'legacy' ORDER BY stopped_at;
SELECT pgbackrest_version_seen, repo_count, backup_count FROM pgbackrest_monitor.stanza_state WHERE stanza_name = 'legacy';

-- 7. no backups / missing stanza
SELECT pgbackrest_monitor.record_run('c1', 'empty', 'info', '2026-10-26 11:42:00+00', '2026-10-26 11:42:01+00', 0, 'success', NULL, :'empty'::jsonb) AS run_id;
SELECT pgbackrest_monitor.record_run('c1', 'doesnotexist', 'info', '2026-10-26 11:42:00+00', '2026-10-26 11:42:01+00', 0, 'success', NULL, :'missing'::jsonb) AS run_id;
SELECT stanza_name, repo_key, status_code, status_message, archive_max, has_backup_metadata, has_archive_metadata FROM pgbackrest_monitor.repo_state WHERE stanza_name IN ('empty', 'doesnotexist') ORDER BY 1, 2;

-- 8. output of `info` without --stanza contains several stanzas: the right element is picked
SELECT pgbackrest_monitor.record_run('c1', 'empty', 'info', '2026-10-26 11:43:00+00', '2026-10-26 11:43:01+00', 0, 'success', NULL, :'allst'::jsonb) AS run_id;
SELECT stanza_name, status_code, backup_count FROM pgbackrest_monitor.stanza_state WHERE stanza_name = 'empty';

-- 9. invalid documents are recorded as validation_failed and leave state untouched
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:44:00+00', '2026-10-26 11:44:01+00', 0, 'success', NULL, :'bad1'::jsonb) AS run_id;
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:44:10+00', '2026-10-26 11:44:11+00', 0, 'success', NULL, :'bad2'::jsonb) AS run_id;
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:44:20+00', '2026-10-26 11:44:21+00', 0, 'success', NULL, '{"name":"lab"}'::jsonb) AS run_id;
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:44:30+00', '2026-10-26 11:44:31+00', 0, 'success', NULL, :'empty'::jsonb) AS run_id;
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:44:40+00', '2026-10-26 11:44:41+00', 0, 'success', NULL, NULL) AS run_id;
SELECT started_at, outcome, exit_code, error_message FROM pgbackrest_monitor.collection_run WHERE stanza_name = 'lab' AND started_at >= '2026-10-26 11:44:00+00' ORDER BY run_id;
SELECT observed_at, backup_count FROM pgbackrest_monitor.stanza_state WHERE stanza_name = 'lab';

-- 10. collector-side failures
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:45:00+00', '2026-10-26 11:45:00+00', NULL, 'binary_missing', 'pgbackrest executable not found: /usr/bin/pgbackrest', NULL) AS run_id;
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:45:10+00', '2026-10-26 11:46:10+00', NULL, 'timeout', 'pgbackrest info did not finish within 60s and was killed', NULL) AS run_id;
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:46:20+00', '2026-10-26 11:46:21+00', 41, 'command_failed', 'pgbackrest info exited with code 41: ERROR: [041]: unable to open file ''/etc/pgbackrest.conf'' for read: [13] Permission denied', NULL) AS run_id;
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:46:30+00', '2026-10-26 11:46:30+00', NULL, 'skipped_locked', 'another collector holds the lock for this stanza', NULL) AS run_id;
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:46:40+00', '2026-10-26 11:46:40+00', NULL, 'bogus_outcome', NULL, NULL) AS run_id;
SET pgbackrest_monitor.clock_override = '2026-10-26 11:47:00+00';
SELECT pgbackrest_monitor.record_error('lab', 'config_error', 'stanza section misconfigured', 'load_config', '{"key": "repo"}');
RESET pgbackrest_monitor.clock_override;
SELECT occurred_at, stanza_name, source, operation, category, exit_code, left(message, 70) AS message FROM pgbackrest_monitor.error_history WHERE occurred_at >= '2026-10-26 11:44:00+00' OR category = 'config_error' ORDER BY error_id;
SELECT stanza_name, last_success_at, last_attempt_at, last_attempt_outcome, last_failure_outcome FROM pgbackrest_monitor.collection_status WHERE stanza_name = 'lab';
SELECT source, operation, state, observed_at, finished_at, exit_code, left(detail, 40) AS detail FROM pgbackrest_monitor.operation_status
WHERE stanza_name = 'lab' AND source = 'collector' AND observed_at >= '2026-10-26 11:45:00+00' ORDER BY observed_at;

-- 11. local archiver sample: shape only (values depend on the server)
SELECT pgbackrest_monitor.sample_pg_archiver() > 0 AS sampled;
SELECT instance, server_version_num >= 130000 AS version_ok, in_recovery IS NOT NULL AS has_recovery, archive_mode IS NOT NULL AS has_mode,
       wal_segment_size > 0 AS seg_ok, current_wal_lsn IS NOT NULL AS has_lsn, current_wal_file ~ '^[0-9A-F]{24}$' AS wal_file_ok,
       archived_count IS NOT NULL AS has_counts
FROM pgbackrest_monitor.latest_pg_archiver;
-- remote sample recorder rejects bad instance names
SELECT pgbackrest_monitor.record_pg_archiver_sample('bad name', 160000, true, 'on', true, NULL, 16777216, 0, NULL, NULL, 0, NULL, NULL, NULL, '0/1', 1, 0);
