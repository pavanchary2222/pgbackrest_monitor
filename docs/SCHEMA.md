# Schema reference (`pgbackrest_monitor`, version 1.0)

Column origin: **A** = authoritative pgBackRest output, **P** = authoritative PostgreSQL statistics,
**D** = derived by the extension, **C** = collector execution record.

## Configuration

| Object | Purpose |
|---|---|
| `default_settings()` | built-in thresholds and retention (key, value, value_type, description) |
| `config` | global overrides (key must be a known setting) |
| `stanza` | registered stanzas: `stanza_name`, `enabled`, `pg_instance` ('local', an instance name or NULL), `collection_interval`, `description` |
| `stanza_setting` | per-stanza overrides |
| `effective_settings` (view) | resolved value per stanza with its source (`stanza`, `global`, `default`) |
| `setting(stanza, key)`, `setting_interval()`, `setting_bigint()` | resolution helpers |
| `set_setting(key, value [, stanza])`, `unset_setting(key [, stanza])` | validating setters ('' disables a rule) |

## Latest state

| Table | Key | Columns |
|---|---|---|
| `collector` | `collector_id` | C: `hostname`, `pid`, `collector_version`, `pgbackrest_version` (from `pgbackrest version` on the collector host), `started_at`, `last_heartbeat`, `collection_interval`, `stanzas[]` |
| `stanza_state` | `stanza_name` | A: `status_code`, `status_message`, `cipher`, `backup_lock_held`, `backup_lock_size`, `backup_lock_size_cplt`, `backup_lock_pct_cplt`, `restore_lock_*`, `pgbackrest_version_seen` (version that wrote the newest backup); D: `observed_at`, `run_id`, `repo_count`, `backup_count` |
| `repo_state` | `(stanza_name, repo_key)` | A: `status_code`, `status_message`, `cipher`, `db_id`, `db_version`, `db_system_id`, `archive_id`, `archive_min`, `archive_max` (current database id); D: `observed_at`, `has_backup_metadata`, `has_archive_metadata` |
| `archive_state` | `(stanza_name, repo_key, archive_id)` | A: `db_id`, `wal_min`, `wal_max` (one row per database id, prior ids kept after upgrades) |

## History

| Table | Columns |
|---|---|
| `collection_run` | C: `collector_id`, `stanza_name`, `command`, `started_at`, `finished_at`, `exit_code` (NULL when the process never finished), `outcome` (`success`, `command_failed`, `timeout`, `binary_missing`, `permission_denied`, `parse_failed`, `validation_failed`, `skipped_locked`), `error_message` (redacted); A: `raw_output` (jsonb, successful runs only, pruned by `retention_raw_output`) |
| `backup` | A: `label`, `backup_type`, `started_at`, `stopped_at`, `wal_start`, `wal_stop`, `lsn_start`, `lsn_stop`, `db_id`, `database_size` (info.size), `backup_size` (info.delta), `repo_set_size` (info.repository.size), `repo_backup_size` (info.repository.delta), `prior_label`, `reference_labels`, `has_error`, `annotation`, `pgbackrest_version`, `pgbackrest_format`; D: `first_seen_at`, `last_seen_at`, `present`, `expired_detected_at` |
| `pg_archiver_sample` | P: `instance`, `server_version_num`, `in_recovery`, `archive_mode`, `archive_command_set`, `archive_library_set`, `wal_segment_size`, `archived_count`, `last_archived_wal`, `last_archived_time`, `failed_count`, `last_failed_wal`, `last_failed_time`, `stats_reset`, `current_wal_lsn`, `timeline_id`, `wal_bytes`; D: `sampled_at`, `current_wal_file` |
| `error_history` | `occurred_at`, `stanza_name`, `repo_key`, `source` (`collector`, `pgbackrest`, `postgres_archiver`), `operation`, `category`, `exit_code`, `message` (redacted), `details` jsonb, `run_id` |
| `operation_observation` | A: `operation` (`backup/expire`, `restore`), `held`, `size_total`, `size_complete`, `pct_complete`, `repo_progress`; D: `observed_at` (rows while a lock is held and once when released) |

Error categories: `binary_missing`, `permission_denied`, `timeout`, `command_failed`, `parse_failed`,
`validation_failed`, `repo_status`, `backup_error`, `archive_failed`, `pg_sample_failed`, `db_error`,
`config_error`.

## Required views

### `backup_status` (one row per stanza)
`stanza_name`, `repo_key` (of the latest backup), `latest_backup_label`, `latest_backup_type`, `backup_started_at`,
`backup_stopped_at`, `backup_duration`, `database_size`, `backup_size`, `repo_set_size`, `repo_backup_size`,
`wal_start`, `wal_stop`, `lsn_start`, `lsn_stop`, `latest_backup_completed_at`, `backup_age`,
`latest_good_backup_label`, `latest_good_backup_completed_at`, `backup_health`, `reason_code`, `message`,
`backup_or_expire_running`, `latest_backup_error`, `latest_backup_error_at`, `last_collected_at`, `data_age`,
`last_attempt_outcome`, `latest_collection_error`, `latest_collection_error_at`.
`backup_status_by_repo` gives the same per repository.

### `archive_status` (one row per stanza and repository)
`stanza_name`, `repo_key`, `pg_instance`, `archive_id`, `repo_archive_min`, `repo_archive_max`, `repo_observed_at`,
`pg_last_archived_wal`, `pg_last_archived_time`, `pg_archived_count`, `pg_failed_count`, `pg_last_failed_wal`,
`pg_last_failed_time`, `pg_stats_reset`, `pg_sampled_at`, `pg_sample_age`, `in_recovery`, `archive_mode`,
`pg_current_wal_file`, `time_since_last_archive`, `pg_segments_waiting` (D: completed segments not yet archived,
same timeline only), `repo_segments_behind_pg` (D: `last_archived_wal` minus repository `archive_max`; negative
means the repository is ahead, which happens because the two are observed seconds apart), `archive_health`,
`reason_code`, `message`.  No timestamps are ever derived from WAL file names.

### `repository_status` (one row per stanza and repository)
`stanza_name`, `repo_key`, `status_code`, `status_message`, `cipher`, `reachability_checked` (always true: the
`info` command listed the repository at `last_status_collected_at`), `reachable_at_observation`
(status not in 1, 99), `last_status_collected_at`, `observation_age`, `is_fresh` (age within
`data_stale_warning`: distinguishes a cached from a fresh observation), `has_backup_metadata`,
`has_archive_metadata`, `db_id`, `db_version`, `db_system_id`, `latest_repo_error`, `latest_repo_error_at`,
`latest_collection_error`, `latest_collection_error_at`, `repo_health`, `reason_code`, `message`.

### `backup_history`
All `backup` columns plus `duration` and `backup_status` (`ok`, `error`, `expired`).

### `operation_status`
`stanza_name`, `source` (`pgbackrest_lock` or `collector`), `operation`, `state` (`running`, `not running`,
`released`, `completed`, `failed`, `skipped`), `observed_at`, `finished_at`, `pct_complete`, `size_total`,
`size_complete`, `exit_code`, `detail`, `is_current` (true for the two rows reflecting the latest lock
observation).  Visibility limits are documented in README "Limitations".

### `error_history`
The table itself (see above).

### `health` (one row per stanza)
`stanza_name`, `overall_status`, `backup_status`, `archive_status`, `repository_status`, `collector_status`,
`last_successful_backup`, `last_successful_backup_type`, `last_successful_backup_at`, `backup_age`,
`backup_wal_start`, `backup_wal_stop`, `pg_last_archived_wal`, `pg_last_archived_time`, `pg_archive_failed_count`,
`pg_last_failed_wal`, `pg_last_failed_time`, `repository_summary`, `repository_archive_summary`,
`backup_or_expire_running`, `restore_running`, `collector_id`, `last_heartbeat`, `heartbeat_age`,
`last_collected_at`, `data_age`, `last_attempt_outcome`, `latest_collection_error`, `reason_codes[]`,
`messages[]`, `evaluated_at`.

`health_components` flattens the same evaluation to one row per (stanza, component) with
`status`, `reason_code`, `message`.  `collection_status` and `latest_pg_archiver` are helper views.

## Functions

| Function | Who | Purpose |
|---|---|---|
| `register_collector(id, host, pid, version, pgbackrest_version, interval, stanzas[])` | collector | upsert collector row, heartbeat |
| `heartbeat(id)` | collector | |
| `register_stanza(name, pg_instance DEFAULT 'local', interval DEFAULT NULL)` | collector | upsert; never touches `enabled` or settings |
| `stanza_enabled(name)` | collector | |
| `try_lock_stanza(name)` / `unlock_stanza(name)` | collector | session advisory lock |
| `record_run(collector, stanza, command, started, finished, exit_code, outcome, error, raw jsonb)` | collector | records the attempt; on success normalises (`ingest_info`) in the same transaction |
| `record_error(stanza, category, message, operation, details)` | collector | collector-side problems |
| `sample_pg_archiver()` | collector | local instance sample |
| `record_pg_archiver_sample(instance, ...)` | collector | sample of a remote instance |
| `purge_history()` | collector | retention; returns rows removed per table |
| `ingest_info(stanza, jsonb, observed_at, run_id)` | internal | normalisation |
| `evaluate_collector(stanza)`, `evaluate_backup(stanza)`, `evaluate_repo(stanza, repo)`, `evaluate_archive(stanza, repo)` | reader | health components |
| `wal_segment_name(text)`, `wal_timeline(text)`, `wal_segno(text, segsize)`, `wal_file_name(timeline, lsn, segsize)` | reader | WAL arithmetic |
| `clock()`, `fmt_interval(interval)`, `hc(...)`, `health_rank(text)`, `worst_status(text[])` | reader | helpers; `clock()` honours `SET pgbackrest_monitor.clock_override` (tests) |

## pgBackRest status codes (info.c)

0 ok · 1 missing stanza path · 2 no valid backups · 3 missing stanza data · 4 different across repos
(stanza level) · 5 database mismatch across repos · 6 requested backup not found · 99 other (message carries
the storage error).

## Upgrades

Future versions ship `sql/pgbackrest_monitor--1.0--1.1.sql` and are applied with
`ALTER EXTENSION pgbackrest_monitor UPDATE`.  All tables are registered with
`pg_extension_config_dump`, so `pg_dump` includes monitoring data and configuration.
