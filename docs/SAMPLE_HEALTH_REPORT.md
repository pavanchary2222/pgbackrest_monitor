# Sample health report

Captured on 2026-10-26 from the integration lab (`tests/integration/lab_setup.sh`): PostgreSQL 18.6 primary
with a streaming standby, pgBackRest 2.59.3, two posix repositories.  All output below is unedited `psql` output
from the extension's views.

## Overview: one row per stanza

```
 stanza_name  | overall_status | backup_status | archive_status | repository_status | collector_status |      last_successful_backup       | backup_age 
--------------+----------------+---------------+----------------+-------------------+------------------+-----------------------------------+------------
 broken       | CRITICAL       | CRITICAL      | UNKNOWN        | CRITICAL          | OK               |                                   | 
 doesnotexist | CRITICAL       | CRITICAL      | UNKNOWN        | CRITICAL          | OK               |                                   | 
 empty        | CRITICAL       | CRITICAL      | OK             | WARNING           | OK               |                                   | 
 lab          | OK             | OK            | OK             | OK                | OK               | 20261026-110039F_20261026-110134I | 00:31:47
(4 rows)

```

## Component reasons (machine-readable code + diagnostic message)

```
 stanza_name  |    component     |  status  |       reason_code        |                                                                message                                                                 
--------------+------------------+----------+--------------------------+----------------------------------------------------------------------------------------------------------------------------------------
 broken       | archive/repo1    | UNKNOWN  | ARCHIVE_REPO_UNAVAILABLE | repo1 archive metadata unavailable: missing stanza path
 broken       | archive/repo2    | UNKNOWN  | ARCHIVE_REPO_UNAVAILABLE | repo2 archive metadata unavailable: missing stanza path
 broken       | backup           | CRITICAL | BACKUP_NONE              | no completed backup exists in any repository
 broken       | collector        | OK       | COLLECTOR_OK             | collector itcollector alive, data 0s old
 broken       | repository/repo1 | CRITICAL | REPO_STANZA_MISSING      | repo1: missing stanza path (stanza path missing: not created, wrong repo path, or repository unreachable)
 broken       | repository/repo2 | CRITICAL | REPO_STANZA_MISSING      | repo2: missing stanza path (stanza path missing: not created, wrong repo path, or repository unreachable)
 doesnotexist | archive/repo1    | UNKNOWN  | ARCHIVE_REPO_UNAVAILABLE | repo1 archive metadata unavailable: missing stanza path
 doesnotexist | archive/repo2    | UNKNOWN  | ARCHIVE_REPO_UNAVAILABLE | repo2 archive metadata unavailable: missing stanza path
 doesnotexist | backup           | CRITICAL | BACKUP_NONE              | no completed backup exists in any repository
 doesnotexist | collector        | OK       | COLLECTOR_OK             | collector itcollector alive, data 0s old
 doesnotexist | repository/repo1 | CRITICAL | REPO_STANZA_MISSING      | repo1: missing stanza path (stanza path missing: not created, wrong repo path, or repository unreachable)
 doesnotexist | repository/repo2 | CRITICAL | REPO_STANZA_MISSING      | repo2: missing stanza path (stanza path missing: not created, wrong repo path, or repository unreachable)
 empty        | archive/repo1    | OK       | ARCHIVE_NOT_EXPECTED     | this standby does not archive WAL (archive_mode=on); repo1 archive max none
 empty        | archive/repo2    | OK       | ARCHIVE_NOT_EXPECTED     | this standby does not archive WAL (archive_mode=on); repo2 archive max none
 empty        | backup           | CRITICAL | BACKUP_NONE              | no completed backup exists in any repository
 empty        | collector        | OK       | COLLECTOR_OK             | collector itcollector alive, data 0s old
 empty        | repository/repo1 | WARNING  | REPO_NO_BACKUPS          | repo1: no valid backups
 empty        | repository/repo2 | WARNING  | REPO_NO_BACKUPS          | repo2: no valid backups
 lab          | archive/repo1    | OK       | ARCHIVE_OK               | last archived 00000001000000000000004C 48s ago, 0 segment(s) waiting; repo1 archive 000000010000000000000001..00000001000000000000004C
 lab          | archive/repo2    | OK       | ARCHIVE_OK               | last archived 00000001000000000000004C 48s ago, 0 segment(s) waiting; repo2 archive 000000010000000000000001..00000001000000000000004C
 lab          | backup           | OK       | BACKUP_OK                | latest backup 20261026-110039F_20261026-110134I (incr, repo1) completed 31m 48s ago
 lab          | collector        | OK       | COLLECTOR_OK             | collector itcollector alive, data 0s old
 lab          | repository/repo1 | OK       | REPO_OK                  | repo1 ok
 lab          | repository/repo2 | OK       | REPO_OK                  | repo2 ok
(24 rows)

```

## Healthy stanza in full (`health` row)

```
-[ RECORD 1 ]---------------+-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
stanza_name                 | lab
overall_status              | OK
backup_status               | OK
archive_status              | OK
repository_status           | OK
collector_status            | OK
last_successful_backup      | 20261026-110039F_20261026-110134I
last_successful_backup_type | incr
last_successful_backup_at   | 2026-10-26 11:01:42+00
backup_age                  | 00:31:48.166591
backup_wal_start            | 000000010000000000000027
backup_wal_stop             | 000000010000000000000027
pg_last_archived_wal        | 00000001000000000000004C
pg_last_archived_time       | 2026-10-26 11:32:41.123362+00
pg_archive_failed_count     | 0
pg_last_failed_wal          | 
pg_last_failed_time         | 
repository_summary          | repo1=ok(0), repo2=ok(0)
repository_archive_summary  | repo1=000000010000000000000001..00000001000000000000004C, repo2=000000010000000000000001..00000001000000000000004C
backup_or_expire_running    | f
restore_running             | f
collector_id                | itcollector
last_heartbeat              | 2026-10-26 11:33:29.733622+00
heartbeat_age               | 00:00:00.432969
last_collected_at           | 2026-10-26 11:33:29.574105+00
data_age                    | 00:00:00.592486
last_attempt_outcome        | success
latest_collection_error     | pgbackrest info exited with code 31: ERROR: [031]: option 'repo1-s3-key' is not allowed on the command-line                                                                                                                                                                                                                                                                                                                               +
                            |        HINT: this option could expose secrets in the process list.                                                                                                                                                                                                                                                                                                                                                                        +
                            |        HINT: specify the option in a configuration file or an environment variable instead.
reason_codes                | {COLLECTOR_OK,BACKUP_OK,ARCHIVE_OK,ARCHIVE_OK,REPO_OK,REPO_OK}
messages                    | {"collector itcollector alive, data 0s old","latest backup 20261026-110039F_20261026-110134I (incr, repo1) completed 31m 48s ago","last archived 00000001000000000000004C 49s ago, 0 segment(s) waiting; repo1 archive 000000010000000000000001..00000001000000000000004C","last archived 00000001000000000000004C 49s ago, 0 segment(s) waiting; repo2 archive 000000010000000000000001..00000001000000000000004C","repo1 ok","repo2 ok"}
evaluated_at                | 2026-10-26 11:33:30.166591+00

```

## Unhealthy stanza: repository unreachable (`broken`)

```
 stanza_name | repo_key | status_code |   status_message    | reachable_at_observation | is_fresh | repo_health |     reason_code     
-------------+----------+-------------+---------------------+--------------------------+----------+-------------+---------------------
 broken      |        1 |           1 | missing stanza path | f                        | t        | CRITICAL    | REPO_STANZA_MISSING
 broken      |        2 |           1 | missing stanza path | f                        | t        | CRITICAL    | REPO_STANZA_MISSING
(2 rows)

```

## Unhealthy stanza: never backed up, archiver statistics taken from the standby (`empty`)

```
 stanza_name | repo_key | pg_instance | in_recovery | archive_mode | repo_archive_max | pg_last_archived_wal | archive_health |     reason_code      
-------------+----------+-------------+-------------+--------------+------------------+----------------------+----------------+----------------------
 empty       |        1 | standby1    | t           | on           |                  |                      | OK             | ARCHIVE_NOT_EXPECTED
 empty       |        2 | standby1    | t           | on           |                  |                      | OK             | ARCHIVE_NOT_EXPECTED
(2 rows)

 stanza_name | latest_backup_label | backup_health | reason_code |                   message                    
-------------+---------------------+---------------+-------------+----------------------------------------------
 empty       |                     | CRITICAL      | BACKUP_NONE | no completed backup exists in any repository
(1 row)

```

## Backup history

```
 repo_key |               label               | backup_type |       started_at       | duration | db_size | repo_delta |        wal_start         |         wal_stop         | backup_status 
----------+-----------------------------------+-------------+------------------------+----------+---------+------------+--------------------------+--------------------------+---------------
        1 | 20261026-110039F                  | full        | 2026-10-26 11:00:39+00 | 00:00:03 | 31 MB   | 6800 kB    | 000000010000000000000003 | 000000010000000000000003 | ok
        1 | 20261026-110039F_20261026-110042D | diff        | 2026-10-26 11:00:42+00 | 00:00:01 | 32 MB   | 1358 kB    | 000000010000000000000005 | 000000010000000000000005 | ok
        1 | 20261026-110039F_20261026-110043I | incr        | 2026-10-26 11:00:43+00 | 00:00:01 | 32 MB   | 1487 kB    | 000000010000000000000007 | 000000010000000000000007 | ok
        2 | 20261026-110125F                  | full        | 2026-10-26 11:01:25+00 | 00:00:03 | 32 MB   | 7436 kB    | 000000010000000000000009 | 000000010000000000000009 | ok
        1 | 20261026-110039F_20261026-110134I | incr        | 2026-10-26 11:01:34+00 | 00:00:08 | 467 MB  | 62 MB      | 000000010000000000000027 | 000000010000000000000027 | ok
(5 rows)

```

## Archive status of the healthy stanza

```
 repo_key |     repo_archive_min     |     repo_archive_max     |   pg_last_archived_wal   |   pg_current_wal_file    | pg_segments_waiting | repo_segments_behind_pg | pg_failed_count | archive_health | reason_code 
----------+--------------------------+--------------------------+--------------------------+--------------------------+---------------------+-------------------------+-----------------+----------------+-------------
        1 | 000000010000000000000001 | 00000001000000000000004C | 00000001000000000000004C | 00000001000000000000004D |                   0 |                       0 |               0 | OK             | ARCHIVE_OK
        2 | 000000010000000000000001 | 00000001000000000000004C | 00000001000000000000004C | 00000001000000000000004D |                   0 |                       0 |               0 | OK             | ARCHIVE_OK
(2 rows)

```

## Error history (most recent first)

```
     occurred_at     | stanza_name  | repo_key |   source   |    category    | exit_code |                                             message                                             
---------------------+--------------+----------+------------+----------------+-----------+-------------------------------------------------------------------------------------------------
 2026-10-26 11:32:41 | lab          |          | pgbackrest | command_failed |        31 | pgbackrest info exited with code 31: ERROR: [031]: option 'repo1-s3-key' is not allowed on the 
 2026-10-26 11:32:32 | lab          |          | collector  | timeout        |           | pgbackrest info did not finish within 1s and was killed
 2026-10-26 11:32:32 | lab          |          | pgbackrest | command_failed |        41 | pgbackrest info exited with code 41: P00  ERROR: [041]: unable to open file '/etc/pgbackrest.co
 2026-10-26 11:32:30 | empty        |          | collector  | binary_missing |           | pgbackrest executable not found: /nonexistent/pgbackrest
 2026-10-26 11:32:30 | lab          |          | collector  | binary_missing |           | pgbackrest executable not found: /nonexistent/pgbackrest
 2026-10-26 11:32:30 | broken       |          | collector  | binary_missing |           | pgbackrest executable not found: /nonexistent/pgbackrest
 2026-10-26 11:32:30 | doesnotexist |          | collector  | binary_missing |           | pgbackrest executable not found: /nonexistent/pgbackrest
 2026-10-26 11:32:26 | broken       |        2 | pgbackrest | repo_status    |         1 | repo2 status 1: missing stanza path
 2026-10-26 11:32:26 | doesnotexist |        2 | pgbackrest | repo_status    |         1 | repo2 status 1: missing stanza path
 2026-10-26 11:32:26 | broken       |        1 | pgbackrest | repo_status    |         1 | repo1 status 1: missing stanza path
 2026-10-26 11:32:26 | doesnotexist |        1 | pgbackrest | repo_status    |         1 | repo1 status 1: missing stanza path
(11 rows)

```

## Operations (lock state from `info` plus the collector's own runs)

```
     source      |    operation    |    state    |     observed_at     | exit_code | detail  
-----------------+-----------------+-------------+---------------------+-----------+---------
 pgbackrest_lock | backup/expire   | not running | 2026-10-26 11:33:30 |           | 
 pgbackrest_lock | restore         | not running | 2026-10-26 11:33:30 |           | 
 collector       | pgbackrest info | completed   | 2026-10-26 11:33:30 |         0 | success
 collector       | pgbackrest info | completed   | 2026-10-26 11:32:55 |         0 | success
 collector       | pgbackrest info | completed   | 2026-10-26 11:32:52 |         0 | success
 collector       | pgbackrest info | completed   | 2026-10-26 11:32:47 |         0 | success
 collector       | pgbackrest info | completed   | 2026-10-26 11:32:42 |         0 | success
 collector       | pgbackrest info | completed   | 2026-10-26 11:32:42 |         0 | success
(8 rows)

```

## Collector failure case (captured during the integration test: pgBackRest binary missing)

The previous good observation is kept and the collector component carries the failure:

```
     started_at      |    outcome     | exit_code |                             error_message                              
---------------------+----------------+-----------+------------------------------------------------------------------------
 2026-10-26 11:32:41 | command_failed |        31 | pgbackrest info exited with code 31: ERROR: [031]: option 'repo1-s3-ke
 2026-10-26 11:32:34 | skipped_locked |           | another collector holds the lock for this stanza
 2026-10-26 11:32:32 | command_failed |        41 | pgbackrest info exited with code 41: P00  ERROR: [041]: unable to open
 2026-10-26 11:32:31 | timeout        |           | pgbackrest info did not finish within 1s and was killed
 2026-10-26 11:32:30 | binary_missing |           | pgbackrest executable not found: /nonexistent/pgbackrest
(5 rows)

```

During that failure the `health` row read: overall `WARNING`, backup `OK` (last known good), collector `WARNING` with reason `COLLECTION_FAILING` and message
`latest collection attempt failed (binary_missing): pgbackrest executable not found: /nonexistent/pgbackrest; showing data from 2s ago`.
