# Security and permissions

## Principles

* The monitor is **read-only** towards pgBackRest: the only command ever executed is `info`
  (plus `version` at start-up).  No backup, restore, expire, stanza or repo command is reachable
  from the collector code, and `--stanza`, `--output`, `--set`, `--type`, `--cmd` cannot be supplied
  through the configuration.
* No shell.  The collector builds a fixed argument vector and calls `subprocess.run(..., shell=False)`.
  Stanza names and extra options are validated against strict regular expressions before use; they come
  from the collector's configuration file, never from the database or from SQL.
* Least privilege in the database: two NOLOGIN roles, SECURITY DEFINER functions with a fixed
  `search_path`, no direct table access for the collector.
* No secrets stored: the collector redacts pgBackRest secret options (`*-s3-key`, `*-s3-key-secret`,
  `*-s3-token`, `*-azure-key`, `*-gcs-key`, `*-cipher-pass`, `*-host-pass`, `*-sftp-private-key-passphrase`),
  `password=` / `secret=` / `token=` pairs, URL credentials, `PGPASSWORD` and AWS key ids from every
  message it logs or stores.  `archive_command` is never stored, only the boolean "is set".  Nothing is
  logged from the DSN.

## Roles

| Role | Granted | Purpose |
|---|---|---|
| `pgbackrest_monitor_reader` | USAGE on schema, SELECT on all tables and views, EXECUTE on pure helper and `evaluate_*` functions | dashboards, alerting, DBAs |
| `pgbackrest_monitor_collector` | reader privileges + EXECUTE on the collector API (`register_collector`, `heartbeat`, `register_stanza`, `stanza_enabled`, `try_lock_stanza`, `unlock_stanza`, `record_run`, `record_error`, `sample_pg_archiver`, `record_pg_archiver_sample`, `purge_history`) | the collector's login role |
| extension owner (superuser) | everything, including `set_setting` / `unset_setting`, `UPDATE pgbackrest_monitor.stanza` | configuration |

The roles are created by `CREATE EXTENSION` if they do not exist and are **not** dropped by
`DROP EXTENSION` (roles are cluster-wide).  Drop them manually when the last database using the
extension is cleaned up.

Grant a login role to the collector:

```sql
CREATE ROLE pgbrmon_collector LOGIN;              -- password in ~/.pgpass of the collector OS user, or peer auth
GRANT pgbackrest_monitor_collector TO pgbrmon_collector;
```

What the collector role **cannot** do (verified by `tests/sql/permissions.sql`): insert/update/delete
any table, change thresholds, read other schemas it was not granted.  What the reader **cannot** do:
call any writing function.  `PUBLIC` has no privileges on the schema at all.

### Why two roles instead of just using `postgres`

I was asked this more than once while building the tool, so here is my reasoning.

You *can* run the collector as `postgres`.  A superuser bypasses every GRANT, so if the `dsn` in
`collector.conf` says `user=postgres` everything works and the two roles simply sit unused.  Nothing in
the code checks for membership.  I still create them, and I use them myself, for three reasons.

1. **Blast radius of the collector's credentials.**  In the deployments I care about, the collector runs
   on the repository host and connects to the production primary over the network, with a password in
   `.pgpass` on that host.  With `pgbackrest_monitor_collector`, those credentials can call about ten
   functions that insert monitoring rows into one schema, and that is all.  With `postgres`, anyone who
   reads that file or compromises the backup server has a superuser login to production from a remote
   host, and I would also have to open `pg_hba.conf` to superuser logins from that host.  I am not willing
   to ship a monitoring tool that needs that.

2. **Readers.**  `pgbackrest_monitor_reader` exists so Grafana, Nagios, Zabbix or a DBA can see backup
   health without being a superuser.  Without it I would either hand them `postgres` or repeat the same
   dozen GRANT statements by hand on every install.

3. **Protecting the data from the collector itself.**  The API functions are SECURITY DEFINER, so the
   collector never gets direct INSERT, UPDATE or DELETE on the tables.  A bug in the collector cannot
   rewrite history, and a collector cannot flip `enabled` or change thresholds; those stay with the DBA.
   A superuser collector can do anything.

The cost of keeping the roles is close to zero: they are NOLOGIN, have no password, own nothing, are
created only if missing, and are shared by every database in the cluster.  The only visible effect is
two extra rows in `pg_roles`.

So: for production, create a LOGIN role, grant it `pgbackrest_monitor_collector`, and leave `postgres`
out of it.  For a lab or a single-host test, `user=postgres` in the `dsn` is fine and you can skip the
CREATE ROLE and GRANT steps.  Both work; only one of them is something I would sign off on.

### Remote instance sampling

For `[instance:...]` connections (standbys) the collector needs only `CONNECT` and the default
`pg_stat_archiver` visibility.  `archive_command` and `pg_control_checkpoint()` are superuser/
`pg_read_all_settings`-restricted; when they are not readable the sample records NULL for
`archive_command_set` and (on a standby) `timeline_id`, and the health rules degrade gracefully.
Grant `pg_read_all_settings` to the sampling role if you want `ARCHIVE_COMMAND_UNSET` detection there.

## SECURITY DEFINER functions

Every writing function is `SECURITY DEFINER` with `SET search_path = pg_catalog, pg_temp`, takes only
typed parameters, and writes only to the extension's own tables.  Inputs that end up in table columns are
length-limited (`left(..., 4000)`), constrained (`outcome` CHECK list, stanza name regex, instance name
regex) and never interpolated into dynamic SQL (there is no `EXECUTE` in the extension).

## Operating-system side

* Run the collector as the pgBackRest OS user (`postgres`).  It needs read access to the pgBackRest
  configuration and to the repository (local path or SSH/TLS credentials of that user); it needs **no**
  write access anywhere except the PostgreSQL connection.
* `/etc/pgbackrest-monitor/collector.conf` is mode 640, owned by that user.  It names the database user
  but should not contain a password: use `~/.pgpass`, peer authentication or a certificate.
* The systemd unit applies `NoNewPrivileges`, `ProtectSystem=full`, `ProtectHome=read-only`,
  `ProtectKernelTunables`, `RestrictSUIDSGID`.  Relax `ProtectHome` only if the repository or
  `.pgpass` live under a home directory the unit must read (the defaults allow read-only access).
* Timeouts: every pgBackRest invocation is killed after `timeout` seconds; connection attempts after
  10 s; the daemon never retries in a tight loop (one attempt per stanza per cycle, exponential backoff on
  database reconnects at start-up, bounded to 10 attempts).

## Data exposure

The monitoring tables reveal backup labels, sizes, WAL positions, repository status messages (which may
include repository paths and storage error texts) and the hostname/pid of the collector.  They do not
contain repository credentials, cipher passphrases or archive commands.  Grant
`pgbackrest_monitor_reader` accordingly.

`collection_run.raw_output` keeps the full `info` JSON for successful runs for `retention_raw_output`
(default 2 days).  It contains the same information as the normalised tables plus pgBackRest version
and format numbers; set the retention to `'0'` to drop it on the next purge if you do not want it.
