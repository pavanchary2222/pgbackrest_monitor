# Architecture

## Goals and constraints

* Monitor pgBackRest through SQL without modifying pgBackRest or reading repository internals.
* Distinguish, and never conflate: PostgreSQL's archiver state, the repository's archive range, the WAL
  range of the latest backup, the latest good backup, running operations, repository health, and the
  health of the monitoring itself.
* Keep the last known good observation when collection fails, while exposing the failure and data age.
* Read-only with respect to backups and repositories; least privilege; no secrets stored.

## Components

### Collector (`collector/pgbackrest_monitor_collector`)

Python 3 was chosen after inspecting the host: `python3` and `python3-psycopg2` are present on every
PostgreSQL host that uses distribution packages, the logic is I/O-bound, and the whole collector is
~600 lines readable by a DBA.  Dependencies: standard library + psycopg2.

| Module | Responsibility |
|---|---|
| `config.py` | INI parsing; stanza/instance name validation; option allow-list (`--name=value`, never `--stanza/--output/--set/--type`) |
| `runner.py` | `subprocess.run(argv, shell=False, timeout=...)`; maps `FileNotFoundError`, `PermissionError`, `TimeoutExpired`, non-zero exit into a `CommandResult` |
| `parser.py` | `json.loads` + structural validation of the stanza element (required: `name`, `status.code`; backups: `label`, `type`, `timestamp.start/stop`; repos: `key`, `status.code`) |
| `redact.py` | removes pgBackRest secret options, `password=`, URL credentials, `PGPASSWORD`, AWS key ids from anything logged or stored |
| `pgsample.py` | read-only `pg_stat_archiver` sample from a remote instance (standby) |
| `store.py` | one connection, one transaction per call, reconnect on `OperationalError`; only calls extension functions |
| `collector.py` | cycle orchestration: lock → run → record; instance samples; heartbeat; purge cadence; SIGTERM |
| `cli.py` | `--once` (timer/cron) or daemon; `--check-config`; exit 1 when a stanza failed |

Per-stanza isolation: each stanza is its own `info` invocation, its own advisory lock and its own
`record_run()` transaction, so one broken stanza never blocks the others.  One `info` without
`--stanza` would scan every stanza in the repository, including ones not being monitored, so it is
not used.

### Extension (`sql/pgbackrest_monitor--1.0.sql`)

Plain SQL and PL/pgSQL: no C was needed.  Three layers:

1. **Collector API** (SECURITY DEFINER, EXECUTE granted to role `pgbackrest_monitor_collector`):
   `register_collector`, `heartbeat`, `register_stanza`, `stanza_enabled`, `try_lock_stanza`,
   `unlock_stanza`, `record_run`, `record_error`, `sample_pg_archiver`, `record_pg_archiver_sample`,
   `purge_history`.  The collector has no table privileges beyond SELECT.
2. **Normalisation**: `ingest_info(stanza, jsonb, observed_at, run_id)` turns one `info` document into
   rows of `stanza_state`, `repo_state`, `archive_state`, `backup`, `operation_observation` and
   `error_history`.  It runs inside `record_run()`; any exception becomes outcome `validation_failed`
   and leaves the previous state intact.
3. **Health**: `evaluate_collector / evaluate_backup / evaluate_repo / evaluate_archive` return a
   `(status, reason_code, message)` composite; the views compose them.  All time arithmetic uses
   `clock()`, which honours `pgbackrest_monitor.clock_override` for deterministic tests.

## Data flow

```
pgbackrest info ─▶ collector.validate ─▶ record_run(outcome, raw jsonb)
                                            │ success ─▶ ingest_info ─▶ stanza_state (latest)
                                            │                           repo_state / archive_state (latest per repo)
                                            │                           backup (history, present flag)
                                            │                           operation_observation (lock transitions)
                                            │                           error_history (status transitions, error flags)
                                            └ failure ─▶ error_history
pg_stat_archiver ─▶ sample_pg_archiver / record_pg_archiver_sample ─▶ pg_archiver_sample (per instance)
heartbeat ─▶ collector.last_heartbeat
```

Latest state (`stanza_state`, `repo_state`, `archive_state`) is replaced only by a *successful*
ingest.  History (`collection_run`, `backup`, `pg_archiver_sample`, `error_history`,
`operation_observation`) is appended and bounded by `purge_history()`.

## Authoritative vs derived

| Field(s) | Source |
|---|---|
| `stanza_state.status_code/message`, `*_lock_*`, `repo_state.status_*`, `archive_state.wal_min/max`, every `backup` column except `first_seen_at/last_seen_at/present/expired_detected_at`, `collection_run.raw_output` | **authoritative pgBackRest output** (`info --output=json`) |
| `pg_archiver_sample.*` except `current_wal_file` | **authoritative PostgreSQL** (`pg_stat_archiver`, `pg_stat_wal`, GUCs, `pg_current_wal_lsn()` / `pg_last_wal_receive_lsn()`) |
| `current_wal_file` | derived from LSN + timeline + `wal_segment_size` (`wal_file_name()`, verified equal to `pg_walfile_name()`) |
| `backup.present`, `expired_detected_at`, `backup_history.backup_status = 'expired'` | derived: a backup missing from a *readable* repository that listed it before |
| `pg_segments_waiting`, `repo_segments_behind_pg`, `backup_age`, `data_age`, `heartbeat_age`, `time_since_last_archive` | derived arithmetic (segment numbers on the same timeline only; `clock()` differences) |
| every `*_status`, `reason_code`, `message` | derived by the health rules with the effective thresholds |
| `collection_run` (except `raw_output`), `collector`, `error_history` rows with `source = 'collector'` | the collector's own execution records |

## Health model

Four components per stanza, each `OK | WARNING | CRITICAL | UNKNOWN` with a reason code and a message:

* **collector**: heartbeat age, data age, last attempt outcome, disabled, never seen.
* **backup**: newest good (`present AND NOT has_error`) backup across all repositories vs thresholds;
  `error: true` backups; database mismatch across repos (status 5).
* **archive** (per repository, worst wins): archiving expected? (`archive_mode`, recovery state) →
  archiver currently failing? → completed segments waiting → waiting for too long → repository archive
  trailing the archiver → idle vs OK.
* **repository** (per repository, worst wins): pgBackRest repo status code mapping.

Overall = worst of the four with `CRITICAL > WARNING > UNKNOWN > OK`; a disabled stanza is
`UNKNOWN / MONITORING_DISABLED`.  `health.reason_codes` and `health.messages` keep every component's
verdict, in the order collector, backup, archive per repo, repository per repo.

## Concurrency, restarts, idempotency

* Session-level advisory lock per stanza (`try_lock_stanza`): a second collector working the same
  stanza records `skipped_locked` and moves on.  The lock dies with the session, so a crashed collector
  never leaves a stale lock.
* Collector restart: `register_collector` upserts by `collector_id` (default: hostname), so there is
  one row per collector; PostgreSQL restart: the store reconnects on the next cycle and re-registers.
* Every ingest is an upsert keyed on `(stanza, repo, label)` / `(stanza, repo)` / `(stanza)`;
  replaying the same JSON changes nothing except `last_seen_at`.
* Errors are recorded on *transitions* (repo status changed, backup newly flagged, archiver failure
  count increased), not on every cycle, so `error_history` does not flood.

## Why the archiver sample is per instance

`pg_stat_archiver` describes one PostgreSQL instance, while a stanza describes one backed-up cluster
whose WAL may be archived by the primary (`archive_mode = on`) or by a standby (`always`).  The
extension must live in a writable database, so standbys cannot host it; the collector samples them
over a read-only connection and stores the sample under an instance name that stanzas reference
through `stanza.pg_instance`.

## Testing strategy

| Layer | Tool | What |
|---|---|---|
| collector | `unittest` (34 tests) | redaction, parser/validation against every fixture, config errors, runner (timeout, missing binary, permission denied, exit codes), cycle logic with a fake store |
| extension | `pg_regress` (5 files) | WAL arithmetic vs `pg_walfile_name()`, ingestion of all fixtures (multi-repo, legacy, expiry, error flags, running progress, invalid docs), every health rule with a pinned clock, retention, privileges |
| system | `tests/integration/run_integration.sh` (37 checks) | real pgBackRest + PostgreSQL primary and standby: healthy / no backups / unreachable repo / missing stanza, missing binary, timeout, permission error, lock contention, secret redaction, PostgreSQL restart, collector restart, daemon + SIGTERM, disabled stanza, retention |

Fixtures: see `tests/fixtures/README.md` (verbatim 2.59.3 output plus documented synthetic variants).
