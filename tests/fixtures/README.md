# Test fixtures

All `*.json` files without the `_synthetic` suffix are **verbatim output** of
`pgbackrest 2.59.3 --output=json info` captured on 2026-10-26 against a PostgreSQL 18.6 lab
(`tests/integration/lab_setup.sh`).  Non-zero exits print the error text to stdout (no JSON).

| File | How it was produced | Exit code |
|---|---|---|
| `info_all_stanzas.json` | `info` without `--stanza` (lab, empty, and the never-created stanzas are absent) | 0 |
| `info_lab_healthy.json` | stanza `lab`: full + diff + 2 incr in repo1, full in repo2, both repos ok | 0 |
| `info_lab_repo1_only.json` | `--stanza=lab --repo=1` | 0 |
| `info_lab_set_detail.json` | `--stanza=lab --repo=1 --set=<full label>` (per-backup detail, `--set` JSON since 2.41) | 0 |
| `info_lab_backup_running.json` | captured while an incremental backup was running: `status.lock.backup.held = true` | 0 |
| `info_empty_no_backups.json` | stanza created, never backed up: status 2 "no valid backups", archive min/max null | 0 |
| `info_missing_stanza.json` | `--stanza=doesnotexist`: status 1 "missing stanza path" | 0 |
| `info_broken_repo.json` | stanza whose repo paths do not exist: status 1 "missing stanza path" (pgBackRest cannot tell a missing path from a missing stanza) | 0 |
| `info_lab_repo_permission_denied.json` | repo1 path with mode 000: repo1 status 99 `[PathOpenError] ... Permission denied`, repo2 ok, stanza status 4 "different across repos" | 0 |
| `info_config_unreadable.stdout.txt` | `--config=/etc/pgbackrest.conf` not readable by the collector user: the error text is printed instead of JSON | 41 |

Synthetic fixtures are derived from `info_lab_healthy.json` by `tests/fixtures/make_synthetic.py`-equivalent
edits documented here; they represent shapes we could not produce on this host:

| File | Represents |
|---|---|
| `info_legacy_single_repo_synthetic.json` | pre-2.33 single-repository output: no `repo` array, no `repo-key`, no `lsn`/`error` fields |
| `info_lab_backup_error_synthetic.json` | newest repo1 backup with `error: true` (reported since 2.36 after `verify`/backup validation) |
| `info_lab_after_expire_synthetic.json` | repo1 after expiry removed the older diff/incr backups |
| `info_lab_backup_running_progress_synthetic.json` | running backup with `size`/`size-cplt`/`pct-cplt` and per-repo progress (2.48 / 2.59 field names from `src/command/info/info.c`) |
| `info_invalid_missing_fields_synthetic.json` | backups lacking `label` / `timestamp` (must be rejected) |
| `info_invalid_no_status_code_synthetic.json` | stanza without `status.code` (must be rejected) |
| `info_not_json.txt` | non-JSON stdout (must be rejected as parse failure) |

Status codes (from `src/command/info/info.c`): 0 ok, 1 missing stanza path, 2 no valid backups,
3 missing stanza data, 4 different across repos, 5 database mismatch across repos,
6 requested backup not found, 99 other (message carries the error text).
