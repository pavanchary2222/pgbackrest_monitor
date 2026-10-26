-- Health rules with a pinned clock.  Fixture backups finished 2026-10-26 11:00:44+00.
\pset null '<null>'
SET timezone = 'UTC';
-- each test file starts from a clean extension state (pg_regress shares one database)
DROP EXTENSION pgbackrest_monitor CASCADE;
CREATE EXTENSION pgbackrest_monitor;
\set lab `cat tests/fixtures/info_lab_healthy.json`
\set empty `cat tests/fixtures/info_empty_no_backups.json`
\set perm `cat tests/fixtures/info_lab_repo_permission_denied.json`
\set witherr `cat tests/fixtures/info_lab_backup_error_synthetic.json`

SELECT pgbackrest_monitor.register_collector('c1', 'host1', 100, '1.0.0', '2.59.3', '1 minute', ARRAY['lab', 'empty', 'remote']);
SELECT pgbackrest_monitor.register_stanza('lab'), pgbackrest_monitor.register_stanza('empty'),
       pgbackrest_monitor.register_stanza('remote', NULL), pgbackrest_monitor.register_stanza('nocollector');
UPDATE pgbackrest_monitor.collector SET last_heartbeat = '2026-10-26 11:59:30+00', started_at = '2026-10-26 10:00:00+00';
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:59:00+00', '2026-10-26 11:59:01+00', 0, 'success', NULL, :'lab'::jsonb) AS run_id;
SELECT pgbackrest_monitor.record_run('c1', 'empty', 'info', '2026-10-26 11:59:00+00', '2026-10-26 11:59:01+00', 0, 'success', NULL, :'empty'::jsonb) AS run_id;
SELECT pgbackrest_monitor.record_run('c1', 'remote', 'info', '2026-10-26 11:59:00+00', '2026-10-26 11:59:01+00', 0, 'success', NULL, jsonb_set(:'lab'::jsonb, '{0,name}', '"remote"')) AS run_id;

-- helper to insert archiver samples with fixed values
CREATE FUNCTION pg_temp.sample(p_at timestamptz, p_in_recovery boolean, p_mode text, p_archived bigint, p_last_wal text, p_last_time timestamptz,
                               p_failed bigint, p_failed_wal text, p_failed_time timestamptz, p_cur_file text) RETURNS void LANGUAGE sql AS $$
    INSERT INTO pgbackrest_monitor.pg_archiver_sample (instance, sampled_at, server_version_num, in_recovery, archive_mode, archive_command_set, wal_segment_size,
        archived_count, last_archived_wal, last_archived_time, failed_count, last_failed_wal, last_failed_time, stats_reset, current_wal_lsn, timeline_id, current_wal_file)
    VALUES ('local', p_at, 180006, p_in_recovery, p_mode, true, 16777216, p_archived, p_last_wal, p_last_time, p_failed, p_failed_wal, p_failed_time,
            '2026-10-26 09:00:00+00', '0/0', 1, p_cur_file)
$$;
CREATE FUNCTION pg_temp.show(p_stanza text) RETURNS TABLE (overall text, backup text, archive text, repository text, collector text, reasons text[]) LANGUAGE sql AS $$
    SELECT overall_status, backup_status, archive_status, repository_status, collector_status, reason_codes FROM pgbackrest_monitor.health WHERE stanza_name = p_stanza
$$;

SET pgbackrest_monitor.clock_override = '2026-10-26 12:00:00+00';

-- A. no archiver sample yet
SELECT * FROM pg_temp.show('lab');
SELECT stanza_name, component, status, reason_code, message FROM pgbackrest_monitor.health_components WHERE stanza_name = 'nocollector' ORDER BY component;

-- B. everything healthy: archiver up to date, idle for a few minutes, repo archive at the same segment
SELECT pg_temp.sample('2026-10-26 11:59:02+00', false, 'on', 7, '000000010000000000000007', '2026-10-26 11:58:00+00', 0, NULL, NULL, '000000010000000000000008');
SELECT * FROM pg_temp.show('lab');
SELECT stanza_name, component, status, reason_code, message FROM pgbackrest_monitor.health_components WHERE stanza_name IN ('lab', 'empty', 'remote') ORDER BY stanza_name, component;
SELECT stanza_name, repo_key, pg_segments_waiting, repo_segments_behind_pg, archive_health, reason_code FROM pgbackrest_monitor.archive_status ORDER BY 1, 2;

-- C. backup age thresholds (defaults 26h / 50h), per-stanza override, full-backup rule
SET pgbackrest_monitor.clock_override = '2026-10-27 14:00:00+00';   -- ~27h
UPDATE pgbackrest_monitor.collector SET last_heartbeat = '2026-10-27 13:59:30+00';
UPDATE pgbackrest_monitor.stanza_state SET observed_at = '2026-10-27 13:59:01+00';
UPDATE pgbackrest_monitor.repo_state SET observed_at = '2026-10-27 13:59:01+00';
SELECT pg_temp.sample('2026-10-27 13:59:02+00', false, 'on', 7, '000000010000000000000007', '2026-10-26 11:58:00+00', 0, NULL, NULL, '000000010000000000000008');
SELECT backup, reasons[2] AS backup_reason FROM pg_temp.show('lab');
SELECT pgbackrest_monitor.set_setting('backup_max_age_warning', '30 hours', 'lab');
SELECT backup, reasons[2] AS backup_reason FROM pg_temp.show('lab');
SELECT stanza_name, key, value, source FROM pgbackrest_monitor.effective_settings WHERE key = 'backup_max_age_warning' ORDER BY 1;
SELECT pgbackrest_monitor.set_setting('full_backup_max_age_warning', '24 hours');
SELECT backup, reasons[2] AS backup_reason, (SELECT message FROM pgbackrest_monitor.health_components WHERE stanza_name = 'lab' AND component = 'backup') FROM pg_temp.show('lab');
SELECT pgbackrest_monitor.unset_setting('full_backup_max_age_warning');
SELECT pgbackrest_monitor.unset_setting('backup_max_age_warning', 'lab');
SET pgbackrest_monitor.clock_override = '2026-10-28 14:00:00+00';   -- ~51h
UPDATE pgbackrest_monitor.collector SET last_heartbeat = '2026-10-28 13:59:30+00';
UPDATE pgbackrest_monitor.stanza_state SET observed_at = '2026-10-28 13:59:01+00';
UPDATE pgbackrest_monitor.repo_state SET observed_at = '2026-10-28 13:59:01+00';
SELECT pg_temp.sample('2026-10-28 13:59:02+00', false, 'on', 7, '000000010000000000000007', '2026-10-26 11:58:00+00', 0, NULL, NULL, '000000010000000000000008');
SELECT overall, backup, archive, reasons[2] AS backup_reason, reasons[3] AS archive_reason FROM pg_temp.show('lab');
-- invalid settings are rejected
SELECT pgbackrest_monitor.set_setting('backup_max_age_warning', 'soon');
SELECT pgbackrest_monitor.set_setting('no_such_setting', '1');
SELECT pgbackrest_monitor.set_setting('repo_no_backups_severity', 'FATAL');
DO $$ BEGIN INSERT INTO pgbackrest_monitor.config VALUES ('typo_setting', 'x'); EXCEPTION WHEN check_violation THEN RAISE NOTICE 'rejected: %', SQLERRM; END $$;

-- D. archive rules (clock back to 12:00, data fresh again)
SET pgbackrest_monitor.clock_override = '2026-10-26 12:00:00+00';
UPDATE pgbackrest_monitor.collector SET last_heartbeat = '2026-10-26 11:59:30+00';
UPDATE pgbackrest_monitor.stanza_state SET observed_at = '2026-10-26 11:59:01+00';
UPDATE pgbackrest_monitor.repo_state SET observed_at = '2026-10-26 11:59:01+00';
DELETE FROM pgbackrest_monitor.pg_archiver_sample;
-- D1. failing right now (last failure after last success, success 5 minutes ago) -> WARNING; success 20 min ago -> CRITICAL
SELECT pg_temp.sample('2026-10-26 11:59:02+00', false, 'on', 7, '000000010000000000000007', '2026-10-26 11:55:00+00', 3, '000000010000000000000008', '2026-10-26 11:59:00+00', '000000010000000000000009');
SELECT archive, reasons[3] AS repo1_reason, (SELECT message FROM pgbackrest_monitor.health_components WHERE stanza_name = 'lab' AND component = 'archive/repo1') FROM pg_temp.show('lab');
SELECT pg_temp.sample('2026-10-26 11:59:03+00', false, 'on', 7, '000000010000000000000007', '2026-10-26 11:40:00+00', 4, '000000010000000000000008', '2026-10-26 11:59:00+00', '000000010000000000000009');
SELECT archive, reasons[3] AS repo1_reason FROM pg_temp.show('lab');
-- failures in the past, archiving recovered since: not failing
SELECT pg_temp.sample('2026-10-26 11:59:04+00', false, 'on', 9, '000000010000000000000009', '2026-10-26 11:59:30+00', 4, '000000010000000000000008', '2026-10-26 11:50:00+00', '00000001000000000000000A');
SELECT archive, reasons[3] AS repo1_reason FROM pg_temp.show('lab');
-- D2. lag: 10 completed segments waiting -> WARNING (8); 70 -> CRITICAL (64)
SELECT pg_temp.sample('2026-10-26 11:59:05+00', false, 'on', 7, '000000010000000000000007', '2026-10-26 11:58:00+00', 0, NULL, NULL, '000000010000000000000012');
SELECT archive, reasons[3] AS repo1_reason, (SELECT message FROM pgbackrest_monitor.health_components WHERE stanza_name = 'lab' AND component = 'archive/repo1') FROM pg_temp.show('lab');
SELECT pg_temp.sample('2026-10-26 11:59:06+00', false, 'on', 7, '000000010000000000000007', '2026-10-26 11:58:00+00', 0, NULL, NULL, '00000001000000000000004E');
SELECT archive, reasons[3] AS repo1_reason FROM pg_temp.show('lab');
-- D3. idle database: nothing waiting, last archive 3 hours ago -> OK / ARCHIVE_IDLE (not a failure)
SELECT pg_temp.sample('2026-10-26 11:59:07+00', false, 'on', 7, '000000010000000000000007', '2026-10-26 09:00:00+00', 0, NULL, NULL, '000000010000000000000008');
SELECT archive, reasons[3] AS repo1_reason FROM pg_temp.show('lab');
-- D4. one segment waiting for 3 hours -> WARNING / ARCHIVE_STALE
SELECT pg_temp.sample('2026-10-26 11:59:08+00', false, 'on', 7, '000000010000000000000007', '2026-10-26 09:00:00+00', 0, NULL, NULL, '000000010000000000000009');
SELECT archive, reasons[3] AS repo1_reason FROM pg_temp.show('lab');
-- D5. repository behind PostgreSQL's archiver by 20 segments -> WARNING / ARCHIVE_REPO_BEHIND
SELECT pg_temp.sample('2026-10-26 11:59:09+00', false, 'on', 59, '00000001000000000000003B', '2026-10-26 11:59:00+00', 0, NULL, NULL, '00000001000000000000003C');
SELECT archive, reasons[3] AS repo1_reason, (SELECT message FROM pgbackrest_monitor.health_components WHERE stanza_name = 'lab' AND component = 'archive/repo1') FROM pg_temp.show('lab');
-- D6. never archived since stats reset while 8 segments completed -> ARCHIVE_NEVER
SELECT pg_temp.sample('2026-10-26 11:59:10+00', false, 'on', 0, NULL, NULL, 0, NULL, NULL, '000000010000000000000008');
SELECT archive, reasons[3] AS repo1_reason FROM pg_temp.show('lab');
-- D7. timeline changed (after failover): no lag arithmetic across timelines, still OK
SELECT pg_temp.sample('2026-10-26 11:59:11+00', false, 'on', 7, '000000010000000000000007', '2026-10-26 11:58:00+00', 0, NULL, NULL, '000000020000000000000009');
SELECT archive, reasons[3] AS repo1_reason FROM pg_temp.show('lab');
-- D8. standby with archive_mode=on does not archive -> OK / ARCHIVE_NOT_EXPECTED; with always it is evaluated normally
SELECT pg_temp.sample('2026-10-26 11:59:12+00', true, 'on', 0, NULL, NULL, 0, NULL, NULL, '000000010000000000000008');
SELECT archive, reasons[3] AS repo1_reason FROM pg_temp.show('lab');
SELECT pg_temp.sample('2026-10-26 11:59:13+00', true, 'always', 7, '000000010000000000000007', '2026-10-26 11:58:00+00', 0, NULL, NULL, '000000010000000000000008');
SELECT archive, reasons[3] AS repo1_reason FROM pg_temp.show('lab');
-- D9. primary with archive_mode=off -> CRITICAL
SELECT pg_temp.sample('2026-10-26 11:59:14+00', false, 'off', 0, NULL, NULL, 0, NULL, NULL, '000000010000000000000008');
SELECT archive, reasons[3] AS repo1_reason FROM pg_temp.show('lab');
-- D10. archive_command unset
INSERT INTO pgbackrest_monitor.pg_archiver_sample (instance, sampled_at, server_version_num, in_recovery, archive_mode, archive_command_set, archive_library_set, wal_segment_size, archived_count, failed_count, current_wal_lsn, timeline_id, current_wal_file)
VALUES ('local', '2026-10-26 11:59:15+00', 180006, false, 'on', false, false, 16777216, 0, 0, '0/0', 1, '000000010000000000000008');
SELECT archive, reasons[3] AS repo1_reason FROM pg_temp.show('lab');
-- D11. stale archiver sample -> UNKNOWN
DELETE FROM pgbackrest_monitor.pg_archiver_sample;
SELECT pg_temp.sample('2026-10-26 10:00:00+00', false, 'on', 7, '000000010000000000000007', '2026-10-26 09:58:00+00', 0, NULL, NULL, '000000010000000000000008');
SELECT archive, reasons[3] AS repo1_reason FROM pg_temp.show('lab');
-- D12. stanza without PostgreSQL comparison and stanza whose instance has no sample
SELECT pg_temp.sample('2026-10-26 11:59:16+00', false, 'on', 7, '000000010000000000000007', '2026-10-26 11:58:00+00', 0, NULL, NULL, '000000010000000000000008');
SELECT archive, reasons[3] AS repo1_reason FROM pg_temp.show('remote');
UPDATE pgbackrest_monitor.stanza SET pg_instance = 'standby1' WHERE stanza_name = 'remote';
SELECT archive, reasons[3] AS repo1_reason FROM pg_temp.show('remote');
SELECT pgbackrest_monitor.record_pg_archiver_sample('standby1', 180006, true, 'on', true, false, 16777216, 0, NULL, NULL, 0, NULL, NULL, NULL, '0/8000000', 1, 0) > 0 AS recorded;
SELECT archive, reasons[3] AS repo1_reason, (SELECT message FROM pgbackrest_monitor.health_components WHERE stanza_name = 'remote' AND component = 'archive/repo1') FROM pg_temp.show('remote');
-- archiver failure counts turn into error_history rows once per increase
SELECT pgbackrest_monitor.record_pg_archiver_sample('standby1', 180006, true, 'always', true, false, 16777216, 5, '000000010000000000000007', '2026-10-26 11:58:00+00', 2, '000000010000000000000008', '2026-10-26 11:59:00+00', NULL, '0/8000000', 1, 0) > 0 AS recorded;
SELECT pgbackrest_monitor.record_pg_archiver_sample('standby1', 180006, true, 'always', true, false, 16777216, 5, '000000010000000000000007', '2026-10-26 11:58:00+00', 2, '000000010000000000000008', '2026-10-26 11:59:00+00', NULL, '0/8000000', 1, 0) > 0 AS recorded;
SELECT pgbackrest_monitor.record_pg_archiver_sample('standby1', 180006, true, 'always', true, false, 16777216, 5, '000000010000000000000007', '2026-10-26 11:58:00+00', 3, '000000010000000000000009', '2026-10-26 11:59:30+00', NULL, '0/8000000', 1, 0) > 0 AS recorded;
SELECT occurred_at, source, category, message FROM pgbackrest_monitor.error_history WHERE source = 'postgres_archiver' ORDER BY error_id;

-- E. repository rules
SELECT repository, reasons[5] AS repo1_reason, reasons[6] AS repo2_reason FROM pg_temp.show('empty');
SELECT pgbackrest_monitor.set_setting('repo_no_backups_severity', 'OK', 'empty');
SELECT overall, backup, repository, reasons[5] AS repo1_reason FROM pg_temp.show('empty');
SELECT pgbackrest_monitor.set_setting('repo_no_backups_severity', 'CRITICAL');
SELECT repository FROM pg_temp.show('empty');
SELECT pgbackrest_monitor.unset_setting('repo_no_backups_severity');
SELECT pgbackrest_monitor.unset_setting('repo_no_backups_severity', 'empty');
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:59:20+00', '2026-10-26 11:59:21+00', 0, 'success', NULL, :'perm'::jsonb) AS run_id;
SELECT overall, backup, archive, repository, reasons FROM pg_temp.show('lab');
SELECT repo_key, status_code, reachable_at_observation, is_fresh, repo_health, reason_code, left(latest_repo_error, 40) AS latest_repo_error FROM pgbackrest_monitor.repository_status WHERE stanza_name = 'lab' ORDER BY 1;
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:59:22+00', '2026-10-26 11:59:23+00', 0, 'success', NULL, :'lab'::jsonb) AS run_id;

-- F. backup with errors
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:59:24+00', '2026-10-26 11:59:25+00', 0, 'success', NULL, :'witherr'::jsonb) AS run_id;
SELECT backup, reasons[2] AS backup_reason, (SELECT message FROM pgbackrest_monitor.health_components WHERE stanza_name = 'lab' AND component = 'backup') FROM pg_temp.show('lab');
UPDATE pgbackrest_monitor.backup SET has_error = true WHERE stanza_name = 'lab';
SELECT backup, reasons[2] AS backup_reason FROM pg_temp.show('lab');
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:59:26+00', '2026-10-26 11:59:27+00', 0, 'success', NULL, :'lab'::jsonb) AS run_id;

-- G. collector / data freshness rules
SELECT collector, reasons[1] AS collector_reason FROM pg_temp.show('lab');
-- latest attempt failed but data fresh -> WARNING COLLECTION_FAILING
SELECT pgbackrest_monitor.record_run('c1', 'lab', 'info', '2026-10-26 11:59:40+00', '2026-10-26 11:59:41+00', 41, 'command_failed', 'pgbackrest info exited with code 41: cannot read config', NULL) AS run_id;
SELECT collector, reasons[1] AS collector_reason, (SELECT message FROM pgbackrest_monitor.health_components WHERE stanza_name = 'lab' AND component = 'collector') FROM pg_temp.show('lab');
-- data stale (observation 20 min / 2 h old) while heartbeat fresh
SET pgbackrest_monitor.clock_override = '2026-10-26 12:20:00+00';
UPDATE pgbackrest_monitor.collector SET last_heartbeat = '2026-10-26 12:19:30+00';
SELECT collector, reasons[1] AS collector_reason FROM pg_temp.show('lab');
SET pgbackrest_monitor.clock_override = '2026-10-26 14:00:00+00';
UPDATE pgbackrest_monitor.collector SET last_heartbeat = '2026-10-26 13:59:30+00';
SELECT overall, collector, backup, reasons[1] AS collector_reason FROM pg_temp.show('lab');
-- heartbeat stale 12 min -> WARNING, 45 min -> CRITICAL
SET pgbackrest_monitor.clock_override = '2026-10-26 12:00:00+00';
UPDATE pgbackrest_monitor.collector SET last_heartbeat = '2026-10-26 11:48:00+00';
SELECT collector, reasons[1] AS collector_reason FROM pg_temp.show('lab');
UPDATE pgbackrest_monitor.collector SET last_heartbeat = '2026-10-26 11:15:00+00';
SELECT overall, collector, reasons[1] AS collector_reason FROM pg_temp.show('lab');
UPDATE pgbackrest_monitor.collector SET last_heartbeat = '2026-10-26 11:59:30+00';
-- a stanza nobody collects
SELECT * FROM pg_temp.show('nocollector');
-- registered, collector alive, every attempt failed so far
SELECT pgbackrest_monitor.register_stanza('newstanza');
UPDATE pgbackrest_monitor.collector SET stanzas = stanzas || ARRAY['newstanza'];
SELECT collector, reasons[1] AS collector_reason FROM pg_temp.show('newstanza');
SELECT pgbackrest_monitor.record_run('c1', 'newstanza', 'info', '2026-10-26 11:59:50+00', '2026-10-26 11:59:51+00', NULL, 'binary_missing', 'pgbackrest executable not found: /usr/bin/pgbackrest', NULL) AS run_id;
SELECT overall, collector, backup, reasons[1] AS collector_reason FROM pg_temp.show('newstanza');
SELECT pgbackrest_monitor.record_run('c1', 'newstanza', 'info', '2026-10-26 11:59:52+00', '2026-10-26 11:59:53+00', NULL, 'binary_missing', 'pgbackrest executable not found: /usr/bin/pgbackrest', NULL) AS run_id;
SELECT pgbackrest_monitor.record_run('c1', 'newstanza', 'info', '2026-10-26 11:59:54+00', '2026-10-26 11:59:55+00', NULL, 'binary_missing', 'pgbackrest executable not found: /usr/bin/pgbackrest', NULL) AS run_id;
SELECT overall, collector, reasons[1] AS collector_reason FROM pg_temp.show('newstanza');
-- disabled stanza
UPDATE pgbackrest_monitor.stanza SET enabled = false WHERE stanza_name = 'empty';
SELECT * FROM pg_temp.show('empty');
SELECT pgbackrest_monitor.stanza_enabled('empty'), pgbackrest_monitor.stanza_enabled('lab'), pgbackrest_monitor.stanza_enabled('unregistered');

-- H. the consolidated view carries the facts the Definition of Done asks for
SELECT stanza_name, overall_status, last_successful_backup, last_successful_backup_type, last_successful_backup_at, backup_age,
       backup_wal_start, backup_wal_stop, pg_last_archived_wal, pg_archive_failed_count, repository_summary, repository_archive_summary,
       backup_or_expire_running, restore_running, collector_id, data_age, evaluated_at
FROM pgbackrest_monitor.health WHERE stanza_name = 'lab';
RESET pgbackrest_monitor.clock_override;
