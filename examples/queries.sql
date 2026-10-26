-- pgbackrest_monitor: example queries (run with a role that has pgbackrest_monitor_reader)

-- 1. Is everything fine?  One line per stanza.
SELECT stanza_name, overall_status, backup_status, archive_status, repository_status, collector_status
FROM pgbackrest_monitor.health ORDER BY pgbackrest_monitor.health_rank(overall_status) DESC, stanza_name;

-- 2. Why not?  Every non-OK component with its reason code and message.
SELECT stanza_name, component, status, reason_code, message
FROM pgbackrest_monitor.health_components WHERE status <> 'OK' ORDER BY 1, 2;

-- 3. When did the last successful backup complete, and is it overdue?
SELECT stanza_name, last_successful_backup, last_successful_backup_type, last_successful_backup_at,
       date_trunc('second', backup_age) AS backup_age, backup_status,
       pgbackrest_monitor.setting(stanza_name, 'backup_max_age_warning') AS warning_after,
       pgbackrest_monitor.setting(stanza_name, 'backup_max_age_critical') AS critical_after
FROM pgbackrest_monitor.health;

-- 4. Which WAL range belongs to the last backup, and what does the repository archive contain?
SELECT h.stanza_name, h.last_successful_backup, h.backup_wal_start, h.backup_wal_stop,
       a.repo_key, a.repo_archive_min, a.repo_archive_max, a.pg_last_archived_wal
FROM pgbackrest_monitor.health h JOIN pgbackrest_monitor.archive_status a USING (stanza_name)
ORDER BY 1, a.repo_key;

-- 5. Is PostgreSQL archiving succeeding?  (per stanza/repo, with the derived lag figures)
SELECT stanza_name, repo_key, archive_mode, in_recovery, pg_last_archived_wal, pg_last_archived_time,
       pg_failed_count, pg_last_failed_wal, pg_last_failed_time,
       pg_segments_waiting, repo_segments_behind_pg, date_trunc('second', time_since_last_archive) AS since_last_archive,
       archive_health, reason_code
FROM pgbackrest_monitor.archive_status ORDER BY 1, 2;

-- 6. Repository health, fresh or cached?
SELECT stanza_name, repo_key, status_code, status_message, reachable_at_observation, is_fresh,
       date_trunc('second', observation_age) AS observation_age, repo_health, reason_code
FROM pgbackrest_monitor.repository_status ORDER BY 1, 2;

-- 7. Backup history of one stanza with sizes.
SELECT repo_key, label, backup_type, started_at, date_trunc('second', duration) AS duration,
       pg_size_pretty(database_size) AS database_size, pg_size_pretty(backup_size) AS backup_size,
       pg_size_pretty(repo_set_size) AS repo_set_size, pg_size_pretty(repo_backup_size) AS repo_delta,
       wal_start, wal_stop, backup_status
FROM pgbackrest_monitor.backup_history WHERE stanza_name = 'main' ORDER BY stopped_at DESC;

-- 8. Backup cadence: gaps between consecutive backups.
SELECT stanza_name, label, backup_type, stopped_at,
       stopped_at - lag(stopped_at) OVER (PARTITION BY stanza_name ORDER BY stopped_at) AS since_previous
FROM pgbackrest_monitor.backup_history WHERE present ORDER BY stanza_name, stopped_at DESC;

-- 9. Anything running right now?
SELECT stanza_name, operation, state, observed_at, pct_complete, pg_size_pretty(size_complete) AS done, pg_size_pretty(size_total) AS total
FROM pgbackrest_monitor.operation_status WHERE is_current AND state = 'running';

-- 10. Recent errors from every source.
SELECT occurred_at, stanza_name, repo_key, source, category, exit_code, message
FROM pgbackrest_monitor.error_history WHERE occurred_at > now() - interval '24 hours' ORDER BY occurred_at DESC;

-- 11. Is the collector alive and how old is the data?
SELECT c.collector_id, c.hostname, c.pid, c.collector_version, c.pgbackrest_version, c.last_heartbeat,
       date_trunc('second', now() - c.last_heartbeat) AS heartbeat_age, c.collection_interval, c.stanzas
FROM pgbackrest_monitor.collector c;
SELECT stanza_name, last_success_at, date_trunc('second', data_age) AS data_age, last_attempt_at, last_attempt_outcome, last_attempt_error
FROM pgbackrest_monitor.collection_status;

-- 12. Collector run log for one stanza.
SELECT run_id, started_at, finished_at - started_at AS took, exit_code, outcome, error_message
FROM pgbackrest_monitor.collection_run WHERE stanza_name = 'main' ORDER BY run_id DESC LIMIT 20;

-- 13. Effective thresholds and where they come from.
SELECT * FROM pgbackrest_monitor.effective_settings WHERE stanza_name = 'main' ORDER BY key;

-- 14. Tune thresholds (extension owner / superuser).
-- SELECT pgbackrest_monitor.set_setting('backup_max_age_warning', '30 hours');
-- SELECT pgbackrest_monitor.set_setting('backup_max_age_critical', '3 days', 'main');
-- SELECT pgbackrest_monitor.set_setting('repo_no_backups_severity', 'OK', 'main');
-- SELECT pgbackrest_monitor.unset_setting('backup_max_age_critical', 'main');

-- 15. Raw pgBackRest JSON of the latest successful collection (authoritative source for everything above).
SELECT r.finished_at, jsonb_pretty(r.raw_output)
FROM pgbackrest_monitor.stanza_state s JOIN pgbackrest_monitor.collection_run r USING (run_id)
WHERE s.stanza_name = 'main';
