# pgbackrest_monitor

A PostgreSQL extension plus a small collector that let a DBA monitor **pgBackRest** entirely through SQL:
last successful backup and its age, backup history, WAL archiving health (PostgreSQL side and repository
side), repository status, running backup/restore operations, monitoring errors, and a consolidated
`OK` / `WARNING` / `CRITICAL` / `UNKNOWN` health status with machine-readable reason codes.

It works with an existing pgBackRest installation: it only runs `pgbackrest --output=json info`
(read-only) and reads `pg_stat_archiver`.  It never modifies pgBackRest, its configuration, or any
repository, and never runs a backup, restore or expire.

```
                 ┌──────────────────────────┐           ┌──────────────────────────────────────┐
 pgbackrest ───▶ │ collector (python)       │ ─SQL────▶ │ PostgreSQL + extension pgbackrest_monitor │
  info JSON      │ fixed argv, timeout,     │  calls    │  record_run() → ingest_info()        │
                 │ validation, redaction    │           │  sample_pg_archiver()                │
 pg_stat_archiver│ heartbeat, retention     │           │  tables → health rules → views       │
 (local/standby) └──────────────────────────┘           └──────────────────────────────────────┘
                                                                        │
                                                      SELECT * FROM pgbackrest_monitor.health;
```

## Contents

| Path | What |
|---|---|
| `pgbackrest_monitor.control`, `sql/pgbackrest_monitor--1.0.sql`, `Makefile` | the extension (PGXS; plain SQL/PLpgSQL, no C) |
| `collector/pgbackrest_monitor_collector/` | the collector (Python 3.8+, stdlib + psycopg2) |
| `config/collector.conf.example` | collector configuration |
| `systemd/` | daemon unit, one-shot unit + timer, cron example |
| `install.sh` | installs extension files and collector (root) |
| `tests/` | pg_regress SQL tests, Python unit tests, integration test + lab, JSON fixtures |
| `docs/INSTALL.md` | step-by-step installation on any PostgreSQL server, deployment variants, upgrade, uninstall |
| `docs/PUBLISHING.md` | pushing this project to your own GitHub repository |
| `docs/ARCHITECTURE.md` | design, data flow, what is authoritative vs derived, limitations |
| `docs/SCHEMA.md` | every table, view, function and reason code |
| `docs/SECURITY.md` | privileges, roles, redaction, hardening |
| `docs/ALERTING.md` | Prometheus / Nagios / Zabbix integration examples |
| `docs/SAMPLE_HEALTH_REPORT.md` | real output for healthy and unhealthy stanzas |
| `examples/queries.sql` | ready-to-use SQL |

## Supported versions

| Component | Tested | Expected to work |
|---|---|---|
| PostgreSQL | 18.6 | 13 and later (`pg_stat_wal` optional, PG 14+; `archive_library`, PG 15+) |
| pgBackRest | 2.59.3 | 2.33 and later (multi-repository JSON). Older single-repository output is parsed with repo key 1 (synthetic fixture only, not tested against a real binary) |
| Python | 3.12 | 3.8+ with psycopg2 2.8+ |

Version-dependent JSON fields (`lsn` 2.35+, `error` 2.36+, lock progress 2.38/2.48+, `annotation` 2.41+,
restore progress 2.56+, per-repo progress 2.59+) are optional everywhere: missing fields become NULL.

## Installation

The short version follows; `docs/INSTALL.md` has the full walkthrough with distribution-specific
packages, standby and repository-host layouts (including backups taken from a standby with the
repository on a separate host), and troubleshooting of first results.

Prerequisites: PostgreSQL server dev package (`postgresql-server-dev-NN`), `pgbackrest`,
`python3`, `python3-psycopg2`.

```bash
# 1. files
sudo ./install.sh                          # make install + collector to /usr/local + systemd units
# or:  sudo make install   /   sudo ./install.sh collector

# 2. database (as a superuser, in the database the collector will connect to)
psql -d postgres -c "CREATE EXTENSION pgbackrest_monitor;"
psql -d postgres -c "CREATE ROLE pgbrmon_collector LOGIN; GRANT pgbackrest_monitor_collector TO pgbrmon_collector;"
psql -d postgres -c "GRANT pgbackrest_monitor_reader TO grafana;"      # whoever reads the views
#    Note: the NOLOGIN group roles pgbackrest_monitor_collector and pgbackrest_monitor_reader are
#    created by CREATE EXTENSION itself (if missing in the cluster); you only create the LOGIN
#    role and grant the group role to it.  DROP EXTENSION does not remove them.

# 3. collector
sudo -e /etc/pgbackrest-monitor/collector.conf       # dsn + one [stanza:<name>] per stanza
sudo -u postgres pgbackrest-monitor-collector --check-config
sudo -u postgres pgbackrest-monitor-collector --once --log-level debug   # first cycle, watch the log
sudo systemctl enable --now pgbackrest-monitor-collector.service         # daemon
#   or: sudo systemctl enable --now pgbackrest-monitor-collector.timer   # one cycle per minute

# 4. look
psql -d postgres -c "SELECT * FROM pgbackrest_monitor.health;"
```

The collector must run as an OS user that can read the pgBackRest configuration and reach the
repositories, normally the same user that runs pgBackRest (`postgres`).  Database credentials go
in `~/.pgpass`, not in the configuration file.

### Uninstall

```bash
sudo systemctl disable --now pgbackrest-monitor-collector.service pgbackrest-monitor-collector.timer
psql -d postgres -c "DROP EXTENSION pgbackrest_monitor CASCADE;"     # drops schema and all monitoring data
psql -d postgres -c "DROP ROLE pgbackrest_monitor_collector, pgbackrest_monitor_reader;"  # roles are not dropped automatically
sudo rm -rf /usr/local/lib/pgbackrest-monitor /usr/local/bin/pgbackrest-monitor-collector /etc/pgbackrest-monitor \
            /etc/systemd/system/pgbackrest-monitor-collector*
sudo make uninstall
```

## Using it

```sql
-- consolidated status, one row per stanza
SELECT stanza_name, overall_status, backup_status, archive_status, repository_status, collector_status,
       last_successful_backup, backup_age, pg_last_archived_wal, reason_codes
FROM pgbackrest_monitor.health;

-- why?  one row per component with a stable reason code and a human message
SELECT * FROM pgbackrest_monitor.health_components WHERE status <> 'OK';

-- the seven views required by the design
SELECT * FROM pgbackrest_monitor.backup_status;
SELECT * FROM pgbackrest_monitor.archive_status;
SELECT * FROM pgbackrest_monitor.repository_status;
SELECT * FROM pgbackrest_monitor.backup_history ORDER BY stopped_at DESC;
SELECT * FROM pgbackrest_monitor.operation_status ORDER BY observed_at DESC;
SELECT * FROM pgbackrest_monitor.error_history ORDER BY occurred_at DESC;
SELECT * FROM pgbackrest_monitor.health;
```

### Thresholds

Defaults live in `pgbackrest_monitor.default_settings()`; override globally or per stanza:

```sql
SELECT * FROM pgbackrest_monitor.effective_settings WHERE stanza_name = 'main';
SELECT pgbackrest_monitor.set_setting('backup_max_age_warning', '30 hours');            -- global
SELECT pgbackrest_monitor.set_setting('backup_max_age_critical', '3 days', 'main');     -- per stanza
SELECT pgbackrest_monitor.set_setting('full_backup_max_age_warning', '8 days');         -- '' disables a rule
SELECT pgbackrest_monitor.set_setting('repo_no_backups_severity', 'OK', 'main');        -- repo2 is a new mirror
SELECT pgbackrest_monitor.unset_setting('backup_max_age_critical', 'main');
```

| Setting | Default | Rule |
|---|---|---|
| `backup_max_age_warning` / `_critical` | 26 h / 50 h | age of the newest good backup in any repository |
| `full_backup_max_age_warning` | disabled | age of the newest good full backup |
| `archive_failing_critical_after` | 15 min | archiver currently failing: CRITICAL once the last success is older than this |
| `archive_lag_segments_warning` / `_critical` | 8 / 64 | completed WAL segments the PostgreSQL archiver has not shipped |
| `archive_stale_warning` | 1 h | WAL waiting and last successful archive older than this |
| `archive_repo_gap_segments_warning` | 16 | repository archive max behind `pg_stat_archiver.last_archived_wal` |
| `repo_no_backups_severity` | WARNING | a repository reporting "no valid backups" |
| `collector_heartbeat_warning` / `_critical` | 10 / 30 min | collector heartbeat age |
| `data_stale_warning` / `_critical` | 15 min / 1 h | age of the last successful observation of the stanza |
| `retention_*` | 7 d runs, 2 d raw JSON, 30 d errors/operations, 7 d archiver samples, 365 d expired backups | purge |

An idle database is **not** flagged: when no completed WAL segment is waiting, an old
`last_archived_time` yields `OK` / `ARCHIVE_IDLE`.

### Disabling a stanza, pausing

```sql
UPDATE pgbackrest_monitor.stanza SET enabled = false WHERE stanza_name = 'old';   -- collector skips it, health shows UNKNOWN / MONITORING_DISABLED
```

## What the collector does each cycle

1. For every configured stanza: take a per-stanza advisory lock (so two collectors never overlap),
   run `pgbackrest [--config ...] --stanza=<name> [--repo=N] --output=json info` with a hard timeout
   and a fixed argument vector (no shell), parse and validate the JSON, and call `record_run()`.
   Failures (missing binary, permission denied, timeout, non-zero exit, unparsable or invalid JSON)
   are recorded as runs with an outcome and a redacted message; the previous good state is kept.
2. Sample `pg_stat_archiver` (and related facts) for the local instance via `sample_pg_archiver()`
   and for every `[instance:...]` referenced by a stanza over a read-only connection (standbys).
3. Heartbeat.  Every N cycles: `purge_history()`.

Stanza names come only from the collector's configuration file (validated against
`^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$`); nothing read from SQL ever becomes a command argument.

## Limitations (read these)

* **Operation visibility.** `info` exposes only whether the backup/expire lock and the restore lock are
  held (with progress on recent versions).  Other commands (`check`, `stanza-*`, `archive-push`,
  `verify`) are invisible; the `collector` rows in `operation_status` cover only the monitor's own
  `info` runs.  A backup started between two collections and finished before the next is only
  visible afterwards as a new row in `backup_history`.
* **Backup failures.** pgBackRest does not keep a record of failed backups in `info`; a failed
  backup simply produces no new backup.  The extension therefore detects failure as *age* of the
  latest good backup, plus `error: true` flags set by pgBackRest's own validation (2.36+).  Parse
  pgBackRest's logs separately if you need per-attempt failure details.
* **Repository reachability** is whatever `info` reports: an unreachable or unreadable repository
  shows as status 99 with the storage error, but a wrong path shows as "missing stanza path" (1),
  which pgBackRest cannot distinguish from a stanza that was never created.
* **Archive comparisons** are done only between WAL segment names on the same timeline; after a
  timeline switch lag is reported as unknown until both sides are on the new timeline.
  `pg_stat_archiver` and the repository scan are observed seconds apart, so a small
  `repo_segments_behind_pg` is normal; the threshold defaults to 16 segments.
* `pg_stat_archiver` is instance wide, so it is attached to stanzas through `pg_instance`, not
  derived from the stanza.  A stanza of another cluster must point at an `[instance:...]` or use
  `pg_instance = none`.
* The extension stores data, so it must live in a **primary**; standbys are sampled remotely.
* `DROP EXTENSION` removes the schema and all history; the two roles remain (cluster-wide objects).

## Troubleshooting

| Symptom | Look at |
|---|---|
| `health.collector_status = UNKNOWN / COLLECTOR_NEVER_SEEN` | collector not started, wrong `dsn`, or stanza name differs between config and `pgbackrest_monitor.stanza` |
| `COLLECTOR_HEARTBEAT_STALE` | `systemctl status pgbackrest-monitor-collector`, `journalctl -u pgbackrest-monitor-collector` |
| `COLLECTION_FAILING` / `NO_DATA` | `SELECT * FROM pgbackrest_monitor.collection_run ORDER BY run_id DESC LIMIT 5;` exit code 41 = cannot read pgBackRest config (run as the pgbackrest OS user or set `pgbackrest_config`), 127-style `binary_missing` = wrong `pgbackrest_binary` |
| `validation_failed` | `error_message` names the missing field; raw JSON is in `collection_run.raw_output` only for successful runs, so run `pgbackrest --stanza=X --output=json info` by hand |
| `REPO_STANZA_MISSING` | `pgbackrest --stanza=X info` as the collector's OS user: repo path, permissions, `stanza-create` |
| `ARCHIVE_FAILING` | PostgreSQL log for the `archive_command` error; `pgbackrest_monitor.error_history WHERE source = 'postgres_archiver'` |
| `ARCHIVE_REPO_BEHIND` | asynchronous archive-push spool, or `archive_command` not using pgBackRest for this stanza |
| `ARCHIVE_NO_PG_SAMPLE` | the stanza's `pg_instance` has no `[instance:...]` sample yet; check the collector log for connection errors |
| wrong ages in tests | `SET pgbackrest_monitor.clock_override` is set in your session (`RESET` it) |

## Development

```bash
make                       # nothing to compile
sudo make install
make unittest              # Python unit tests (34), no database needed
tests/integration/lab_setup.sh            # throwaway PG + pgBackRest lab under ~/pgbr_lab (port 5499)
PGHOST=~/pgbr_lab/run PGPORT=5499 make installcheck   # pg_regress (5 files, fixtures in tests/fixtures)
make integration           # 37 end-to-end checks: real pgbackrest, primary + standby, failures, SIGTERM
```

License: PostgreSQL License.
