#!/usr/bin/env bash
# Creates a throwaway PostgreSQL + pgBackRest lab owned by the current OS user.
# Nothing here touches system clusters or /etc/pgbackrest.conf.
#
# Usage: lab_setup.sh [LAB_DIR] [PORT]
set -euo pipefail

LAB=${1:-$HOME/pgbr_lab}
PORT=${2:-5499}
PGBIN=${PGBIN:-$(dirname "$(pg_config --bindir)/postgres")}
export PGHOST=$LAB/run PGPORT=$PORT PGUSER=${USER}
PGBR_CONF=$LAB/pgbackrest.conf
PGBR="pgbackrest --config=$PGBR_CONF"

if [ -d "$LAB/pgdata" ]; then
  echo "lab already exists at $LAB (remove it to recreate)"; exit 0
fi
mkdir -p "$LAB"/{run,repo1,repo2,lock,log,spool}

cat > "$PGBR_CONF" <<CONF
[global]
repo1-path=$LAB/repo1
repo1-retention-full=4
repo2-path=$LAB/repo2
repo2-retention-full=4
lock-path=$LAB/lock
log-path=$LAB/log
log-level-console=warn
log-level-file=detail
start-fast=y
compress-type=lz4

# healthy stanza: full/diff/incr backups in two repositories
[lab]
pg1-path=$LAB/pgdata
pg1-port=$PORT
pg1-socket-path=$LAB/run

# stanza created but never backed up
[empty]
pg1-path=$LAB/pgdata
pg1-port=$PORT
pg1-socket-path=$LAB/run

# stanza whose repository path does not exist / is unreadable
[broken]
pg1-path=$LAB/pgdata
repo1-path=/nonexistent/pgbackrest-repo
repo2-path=/nonexistent/pgbackrest-repo
CONF

"$PGBIN/initdb" -D "$LAB/pgdata" -U "$USER" --auth=trust >/dev/null
cat >> "$LAB/pgdata/postgresql.conf" <<PGCONF
port = $PORT
listen_addresses = ''
unix_socket_directories = '$LAB/run'
archive_mode = on
archive_command = 'pgbackrest --config=$PGBR_CONF --stanza=lab archive-push %p'
wal_level = replica
max_wal_senders = 3
log_min_messages = warning
PGCONF

"$PGBIN/pg_ctl" -D "$LAB/pgdata" -l "$LAB/log/postgres.log" -w start >/dev/null
psql -d postgres -qc "CREATE DATABASE labdb" 

$PGBR --stanza=lab stanza-create
$PGBR --stanza=empty stanza-create
$PGBR --stanza=lab check

psql -d labdb -qc "CREATE TABLE t AS SELECT g, md5(g::text) FROM generate_series(1,20000) g"
$PGBR --stanza=lab --type=full backup
psql -d labdb -qc "INSERT INTO t SELECT g, md5(g::text) FROM generate_series(20001,30000) g"
$PGBR --stanza=lab --type=diff backup
psql -d labdb -qc "INSERT INTO t SELECT g, md5(g::text) FROM generate_series(30001,35000) g"
$PGBR --stanza=lab --type=incr backup
psql -d labdb -qc "SELECT pg_switch_wal()" >/dev/null

echo "lab ready: PGHOST=$LAB/run PGPORT=$PORT  pgbackrest --config=$PGBR_CONF"
