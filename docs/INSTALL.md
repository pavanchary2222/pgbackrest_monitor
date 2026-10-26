# Installing pgbackrest_monitor on a PostgreSQL server

This guide takes an existing PostgreSQL server that is already backed up by pgBackRest and adds the
monitoring extension plus its collector.  Nothing in it changes pgBackRest, its configuration or a
repository.  Allow about 20 minutes.

## 0. Before you start

| Check | Command | Need |
|---|---|---|
| PostgreSQL version | `psql -c "SHOW server_version"` | 13 or later (tested on 18) |
| `pg_config` for that version | `pg_config --version` | must print the same major version as the server |
| pgBackRest | `pgbackrest version` | 2.33 or later (tested on 2.59.3) |
| a working stanza | `sudo -u postgres pgbackrest --stanza=<name> info` | prints backups / "no valid backups" |
| Python | `python3 --version` | 3.8+ |
| psycopg2 | `python3 -c "import psycopg2"` | any 2.8+ |
| build tools | `make --version && gcc --version` | only `make` is used (no compilation) |

Install what is missing:

```bash
# Debian / Ubuntu (PGDG repository)          # RHEL / Rocky / Alma (PGDG repository)
sudo apt install postgresql-server-dev-18 \   sudo dnf install postgresql18-devel \
     pgbackrest python3 python3-psycopg2 make        pgbackrest python3 python3-psycopg2 make
```

Replace `18` with your major version.  On RHEL `pg_config` lives in `/usr/pgsql-18/bin/`; export
`PG_CONFIG=/usr/pgsql-18/bin/pg_config` for the `make` steps below.

Decide where the extension lives.  It stores data, so it needs a **primary**.  Normally that is the
database server the stanza backs up (`postgres` database is fine).  If pgBackRest runs from a separate
repository host, see "Repository host" below.

## 1. Install the files

```bash
git clone https://github.com/<you>/pgbackrest_monitor.git     # see docs/PUBLISHING.md
cd pgbackrest_monitor

sudo make install                          # copies .control and .sql into $(pg_config --sharedir)/extension
# RHEL: sudo make PG_CONFIG=/usr/pgsql-18/bin/pg_config install

sudo ./install.sh collector                # collector → /usr/local/lib/pgbackrest-monitor and /usr/local/bin,
                                           # config → /etc/pgbackrest-monitor/collector.conf, systemd units
```

`sudo ./install.sh` without an argument does both steps.  Check:

```bash
ls $(pg_config --sharedir)/extension/pgbackrest_monitor*
pgbackrest-monitor-collector --version
```

## 2. Create the extension and the roles

As a PostgreSQL superuser, in the database the collector will connect to:

```sql
CREATE EXTENSION pgbackrest_monitor;

-- login role for the collector (NOLOGIN group roles were created by the extension)
CREATE ROLE pgbrmon_collector LOGIN;
GRANT pgbackrest_monitor_collector TO pgbrmon_collector;

-- anyone who should read the views (Grafana, Nagios, DBAs)
GRANT pgbackrest_monitor_reader TO monitoring_user;
```

Authentication for `pgbrmon_collector`: the collector runs as the `postgres` OS user, so the simplest
is a `pg_hba.conf` line with peer authentication mapped to that role, or a password kept in
`/var/lib/postgresql/.pgpass` (mode 600):

```
# ~postgres/.pgpass
localhost:5432:postgres:pgbrmon_collector:<password>
```

Verify: `sudo -u postgres psql -U pgbrmon_collector -d postgres -c "SELECT pgbackrest_monitor.heartbeat('test')"`.

## 3. Configure the collector

Edit `/etc/pgbackrest-monitor/collector.conf` (owned by `postgres`, mode 640):

```ini
[collector]
dsn = host=localhost port=5432 dbname=postgres user=pgbrmon_collector
interval = 60
timeout = 60
pgbackrest_binary = /usr/bin/pgbackrest
# pgbackrest_config = /etc/pgbackrest/pgbackrest.conf      # only if not the default location

[stanza:main]            # one section per stanza, name exactly as in pgbackrest.conf
pg_instance = local      # this server's pg_stat_archiver is comparable with the stanza
```

Then, as the pgBackRest OS user:

```bash
sudo -u postgres pgbackrest-monitor-collector --check-config
sudo -u postgres pgbackrest-monitor-collector --once --log-level debug
```

The debug output shows the exact `pgbackrest ... --output=json info` command line and a one-line summary
per stanza (`status=0(ok) backups=5 repos=1:0`).  Exit code 0 means every stanza was collected.

## 4. Start it

Pick one:

```bash
sudo systemctl enable --now pgbackrest-monitor-collector.service      # daemon, loops every `interval`
sudo systemctl enable --now pgbackrest-monitor-collector.timer        # one cycle per minute via systemd timer
# or cron, see systemd/pgbackrest-monitor-collector.cron.example
sudo journalctl -u pgbackrest-monitor-collector -f
```

## 5. Verify

```sql
SELECT * FROM pgbackrest_monitor.health;
SELECT * FROM pgbackrest_monitor.health_components WHERE status <> 'OK';
```

A freshly installed stanza with a recent backup shows `OK` everywhere within one cycle.  Common first
results and what they mean:

| Result | Meaning / fix |
|---|---|
| `collector_status = UNKNOWN / COLLECTOR_NEVER_SEEN` | collector not running, or stanza name in `[stanza:...]` differs from the one in the `stanza` table |
| `COLLECTION_FAILING`, exit code 41 | collector cannot read `pgbackrest.conf`: run as the pgBackRest OS user or set `pgbackrest_config` |
| `BACKUP_TOO_OLD` right after install | expected if the last backup is older than 26 h; tune `backup_max_age_warning` |
| `ARCHIVE_REPO_BEHIND` | normal transiently when `archive-async=y`; persistent means `archive_command` does not push to this stanza |
| `REPO_NO_BACKUPS` on a second repository | the repo is configured but has never received a backup |

## 6. Tune thresholds

```sql
SELECT * FROM pgbackrest_monitor.effective_settings WHERE stanza_name = 'main';
SELECT pgbackrest_monitor.set_setting('backup_max_age_warning',  '30 hours');          -- global
SELECT pgbackrest_monitor.set_setting('backup_max_age_critical', '3 days', 'main');    -- per stanza
SELECT pgbackrest_monitor.set_setting('full_backup_max_age_warning', '8 days');        -- enable the full-backup rule
```

Defaults and every rule are listed in README "Thresholds".

## Deployment variants

### Several stanzas on one server
Add one `[stanza:<name>]` section per stanza.  All of them use `pg_instance = local` when they back up
this server.  Thresholds can differ per stanza.

### Streaming standby (archive_mode = always)
Install the extension on the primary only.  On the primary's collector configuration add a read-only
connection to the standby and attach the stanza to it:

```ini
[instance:standby1]
dsn = host=standby1 port=5432 dbname=postgres user=pgbrmon_collector

[stanza:main_standby_archiving]   # or reuse 'main' with pg_instance = standby1 if the standby does the archiving
pg_instance = standby1
```

The standby needs the `pgbrmon_collector` role (it replicates from the primary) and a `pg_hba.conf` entry;
no superuser.  With `archive_mode = on` the standby does not archive and the extension reports
`ARCHIVE_NOT_EXPECTED`; with `always` its archiver statistics are evaluated like a primary's.

### Repository host (pgBackRest runs on a dedicated backup server)
Run the collector on the repository host, where `pgbackrest info` works, and point its `dsn` at the
database server that holds the extension.  For stanzas whose PostgreSQL archiver statistics are on another
server, declare an `[instance:...]` for that server, or use `pg_instance = none` to monitor the repository
side only.

### Multiple repositories (repo1 + repo2)
Nothing to configure: `info` reports every repository and the views have one row per `repo_key`.
Backup health considers the newest good backup in *any* repository; repository health is per repo.

### Several PostgreSQL major versions on one host
Run `sudo make PG_CONFIG=/usr/lib/postgresql/<ver>/bin/pg_config install` once per version that should
host the extension.  The collector is version-independent.

## Upgrading

```bash
git pull
sudo make install
psql -d postgres -c "ALTER EXTENSION pgbackrest_monitor UPDATE;"   # when a new version ships an upgrade script
sudo ./install.sh collector && sudo systemctl restart pgbackrest-monitor-collector
```

## Uninstalling

```bash
sudo systemctl disable --now pgbackrest-monitor-collector.service pgbackrest-monitor-collector.timer
psql -d postgres -c "DROP EXTENSION pgbackrest_monitor CASCADE;"          # removes schema and all monitoring data
psql -d postgres -c "DROP ROLE pgbrmon_collector; DROP ROLE pgbackrest_monitor_collector, pgbackrest_monitor_reader;"
sudo rm -rf /usr/local/lib/pgbackrest-monitor /usr/local/bin/pgbackrest-monitor-collector \
            /etc/pgbackrest-monitor /etc/systemd/system/pgbackrest-monitor-collector*
sudo make uninstall
```

## Testing an installation without touching production

`tests/integration/lab_setup.sh` builds a throwaway PostgreSQL instance and pgBackRest repository under
`~/pgbr_lab` (port 5499) as your own user; `make integration` then exercises the whole stack against it.
Nothing in it reads `/etc/pgbackrest.conf` or the system cluster.
