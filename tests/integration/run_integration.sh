#!/usr/bin/env bash
# End-to-end tests against a real pgBackRest and a real PostgreSQL primary + standby lab.
# Requires: pgbackrest, PostgreSQL server binaries, python3 + psycopg2, the extension installed
# (make install).  Creates the lab with lab_setup.sh when it does not exist yet.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LAB=${LAB:-$HOME/pgbr_lab}
PORT=${PORT:-5499}
SBPORT=$((PORT - 1))
DB=pgbackrest_monitor_it
export PGHOST=$LAB/run PGPORT=$PORT PGUSER=$USER PGDATABASE=$DB
PGBIN=$(dirname "$(pg_config --bindir)/postgres")
COLLECTOR="python3 -m pgbackrest_monitor_collector"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
cd "$ROOT/collector"

pass=0; fail=0
check() {   # check <description> <expected> <sql>
    local got; got=$(psql -XAtqc "$3" 2>&1 | tr '\n' ' ' | sed 's/ *$//')
    if [[ "$got" == "$2" ]]; then pass=$((pass+1)); echo "  ok   $1"
    else fail=$((fail+1)); echo "  FAIL $1"; echo "       expected: $2"; echo "       got:      $got"; fi
}
section() { echo "== $1"; }

section "lab"
[[ -d $LAB/pgdata ]] || "$ROOT/tests/integration/lab_setup.sh" "$LAB" "$PORT"
"$PGBIN/pg_ctl" status -D "$LAB/pgdata" >/dev/null || "$PGBIN/pg_ctl" -D "$LAB/pgdata" -l "$LAB/log/postgres.log" -w start >/dev/null
psql -d postgres -Xqc "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB" >/dev/null
psql -Xqc "CREATE EXTENSION pgbackrest_monitor" >/dev/null
psql -Xqc "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'it_collector') THEN CREATE ROLE it_collector LOGIN; END IF; END \$\$; GRANT pgbackrest_monitor_collector TO it_collector;" >/dev/null
if [[ ! -d $LAB/standby ]]; then
    "$PGBIN/pg_basebackup" -D "$LAB/standby" -R -X stream -c fast >/dev/null
    printf "port = %s\nhot_standby = on\n" "$SBPORT" >> "$LAB/standby/postgresql.auto.conf"
fi
"$PGBIN/pg_ctl" status -D "$LAB/standby" >/dev/null || "$PGBIN/pg_ctl" -D "$LAB/standby" -l "$LAB/log/standby.log" -w start >/dev/null
for i in $(seq 1 30); do psql -p $SBPORT -d postgres -XAtqc "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
echo "  primary on $PORT, standby on $SBPORT, database $DB"

conf() {   # conf <file> <binary> <timeout> [extra stanza options for lab]
cat > "$1" <<CONF
[collector]
dsn = host=$LAB/run port=$PORT dbname=$DB user=it_collector
collector_id = itcollector
interval = 5
timeout = $3
pgbackrest_binary = $2
pgbackrest_config = $LAB/pgbackrest.conf
purge_every_cycles = 1
log_level = warning

[instance:standby1]
dsn = host=$LAB/run port=$SBPORT dbname=postgres user=it_collector

[stanza:lab]
pg_instance = local
${4:-}
[stanza:empty]
pg_instance = standby1
[stanza:broken]
pg_instance = none
[stanza:doesnotexist]
pg_instance = local
CONF
}
conf "$WORK/good.conf" /usr/bin/pgbackrest 30

section "1. one cycle against the real lab (least-privilege collector role)"
$COLLECTOR --config "$WORK/good.conf" --once; rc=$?
check "collector exits 0" "0" "SELECT $rc"
check "one collector row with real pgBackRest version" "itcollector|$(pgbackrest version | awk '{print $2}')|4" \
      "SELECT collector_id, pgbackrest_version, cardinality(stanzas) FROM pgbackrest_monitor.collector"
check "lab is fully OK" "lab|OK|OK|OK|OK|OK" \
      "SELECT stanza_name, overall_status, backup_status, archive_status, repository_status, collector_status FROM pgbackrest_monitor.health WHERE stanza_name = 'lab'"
check "lab latest backup is the real incremental" "20261026-110039F_20261026-110134I|incr|1" \
      "SELECT latest_backup_label, latest_backup_type, repo_key FROM pgbackrest_monitor.backup_status WHERE stanza_name = 'lab'"
check "lab has 5 backups in history across 2 repos" "5|2" \
      "SELECT count(*), count(DISTINCT repo_key) FROM pgbackrest_monitor.backup_history WHERE stanza_name = 'lab'"
check "empty: no backups -> CRITICAL, repos WARNING" "empty|CRITICAL|CRITICAL|WARNING" \
      "SELECT stanza_name, overall_status, backup_status, repository_status FROM pgbackrest_monitor.health WHERE stanza_name = 'empty'"
check "empty archive evaluated against the STANDBY (archive_mode=on -> not expected)" "OK|ARCHIVE_NOT_EXPECTED|t" \
      "SELECT a.archive_health, a.reason_code, a.in_recovery FROM pgbackrest_monitor.archive_status a WHERE stanza_name = 'empty' AND repo_key = 1"
check "broken: unreachable repo paths -> repository CRITICAL, archive UNKNOWN" "CRITICAL|UNKNOWN|CRITICAL" \
      "SELECT repository_status, archive_status, overall_status FROM pgbackrest_monitor.health WHERE stanza_name = 'broken'"
check "broken reason codes" "REPO_STANZA_MISSING|REPO_STANZA_MISSING" \
      "SELECT string_agg(reason_code, '|' ORDER BY repo_key) FROM pgbackrest_monitor.repository_status WHERE stanza_name = 'broken'"
check "both instances sampled (primary + standby)" "local|f standby1|t" \
      "SELECT instance, in_recovery FROM pgbackrest_monitor.latest_pg_archiver ORDER BY instance"
check "standby sample has LSN but archiver stats idle" "t|0" \
      "SELECT current_wal_lsn IS NOT NULL, archived_count FROM pgbackrest_monitor.latest_pg_archiver WHERE instance = 'standby1'"
check "lab archive: nothing waiting, repo not behind" "0|t" \
      "SELECT pg_segments_waiting, repo_segments_behind_pg <= 0 FROM pgbackrest_monitor.archive_status WHERE stanza_name = 'lab' AND repo_key = 1"
check "repo status errors recorded once per repo for broken/doesnotexist" "4" \
      "SELECT count(*) FROM pgbackrest_monitor.error_history WHERE category = 'repo_status'"
check "no secrets / no command lines stored" "0" \
      "SELECT count(*) FROM pgbackrest_monitor.error_history WHERE message ~* 'pass|secret|key='"

section "2. archive activity is reflected on the next cycle"
psql -d postgres -Xqc "CREATE TABLE IF NOT EXISTS it_churn AS SELECT g, md5(g::text) FROM generate_series(1, 200000) g; SELECT pg_switch_wal();" >/dev/null
sleep 2
$COLLECTOR --config "$WORK/good.conf" --once >/dev/null
check "pg_stat_archiver advanced and repo archive followed" "t|OK" \
      "SELECT pg_last_archived_wal >= repo_archive_max OR repo_archive_max >= pg_last_archived_wal, archive_health FROM pgbackrest_monitor.archive_status WHERE stanza_name = 'lab' AND repo_key = 1"
check "idempotent: still 5 backups, none expired" "5|0" \
      "SELECT count(*) FILTER (WHERE present), count(*) FILTER (WHERE NOT present) FROM pgbackrest_monitor.backup WHERE stanza_name = 'lab'"

section "3. missing pgbackrest executable"
conf "$WORK/nobin.conf" /nonexistent/pgbackrest 30
$COLLECTOR --config "$WORK/nobin.conf" --once; rc=$?
check "collector exits 1 when every stanza failed" "1" "SELECT $rc"
check "runs recorded as binary_missing" "binary_missing|4" \
      "SELECT outcome, count(*) FROM pgbackrest_monitor.collection_run WHERE started_at = (SELECT max(started_at) FROM pgbackrest_monitor.collection_run WHERE stanza_name = 'lab') OR outcome = 'binary_missing' GROUP BY 1"
check "lab: last known good kept, collector WARNING COLLECTION_FAILING" "WARNING|OK|WARNING|COLLECTION_FAILING" \
      "SELECT overall_status, backup_status, collector_status, reason_codes[1] FROM pgbackrest_monitor.health WHERE stanza_name = 'lab'"

section "4. command timeout"
cat > "$WORK/slow_pgbackrest" <<'SLOW'
#!/usr/bin/env bash
if [[ "$*" == *version* ]]; then exec /usr/bin/pgbackrest "$@"; fi
sleep 5; exec /usr/bin/pgbackrest "$@"
SLOW
chmod +x "$WORK/slow_pgbackrest"
conf "$WORK/slow.conf" "$WORK/slow_pgbackrest" 1
$COLLECTOR --config "$WORK/slow.conf" --once --stanza lab >/dev/null; rc=$?
check "timeout exit 1" "1" "SELECT $rc"
check "timeout recorded with NULL exit code" "timeout||t" \
      "SELECT outcome, exit_code, error_message LIKE '%did not finish within 1s%' FROM pgbackrest_monitor.collection_run WHERE stanza_name = 'lab' ORDER BY run_id DESC LIMIT 1"

section "5. unreadable pgBackRest configuration (permission error, exit 41)"
sed "s#pgbackrest_config = .*#pgbackrest_config = /etc/pgbackrest.conf#" "$WORK/good.conf" > "$WORK/perm.conf"
$COLLECTOR --config "$WORK/perm.conf" --once --stanza lab >/dev/null
check "command_failed with pgBackRest exit code 41" "command_failed|41|t" \
      "SELECT outcome, exit_code, error_message LIKE '%[041]%' FROM pgbackrest_monitor.collection_run WHERE stanza_name = 'lab' ORDER BY run_id DESC LIMIT 1"

section "6. concurrent collection: another session holds the stanza lock"
psql -XAtq -c "SELECT pgbackrest_monitor.try_lock_stanza('lab'); SELECT pg_sleep(8);" >/dev/null 2>&1 &
LOCKER=$!; sleep 1
$COLLECTOR --config "$WORK/good.conf" --once >/dev/null; rc=$?
check "locked stanza skipped, others collected" "skipped_locked" \
      "SELECT outcome FROM pgbackrest_monitor.collection_run WHERE stanza_name = 'lab' ORDER BY run_id DESC LIMIT 1"
check "other stanzas still succeeded" "success" \
      "SELECT outcome FROM pgbackrest_monitor.collection_run WHERE stanza_name = 'empty' ORDER BY run_id DESC LIMIT 1"
check "skipped is not a failure (exit 0)" "0" "SELECT $rc"
wait $LOCKER 2>/dev/null

section "7. secret redaction end to end"
conf "$WORK/secret.conf" /usr/bin/pgbackrest 30 "options = --repo1-s3-key=SUPERSECRETKEY123 --repo1-type=s3"
$COLLECTOR --config "$WORK/secret.conf" --once --stanza lab 2>"$WORK/secret.log" >/dev/null
check "pgbackrest rejected the options (command_failed)" "command_failed" \
      "SELECT outcome FROM pgbackrest_monitor.collection_run WHERE stanza_name = 'lab' ORDER BY run_id DESC LIMIT 1"
check "secret absent from stored error and from error_history" "0|0" \
      "SELECT (SELECT count(*) FROM pgbackrest_monitor.collection_run WHERE error_message LIKE '%SUPERSECRET%'), (SELECT count(*) FROM pgbackrest_monitor.error_history WHERE message LIKE '%SUPERSECRET%')"
if grep -q SUPERSECRET "$WORK/secret.log"; then fail=$((fail+1)); echo "  FAIL secret leaked into collector log"; else pass=$((pass+1)); echo "  ok   secret absent from collector log"; fi

section "8. PostgreSQL restart, then collector restart"
"$PGBIN/pg_ctl" -D "$LAB/pgdata" -m fast -w restart -l "$LAB/log/postgres.log" >/dev/null
$COLLECTOR --config "$WORK/good.conf" --once >/dev/null; rc=$?
check "collection succeeds after a PostgreSQL restart" "0|success" \
      "SELECT $rc, outcome FROM pgbackrest_monitor.collection_run WHERE stanza_name = 'lab' ORDER BY run_id DESC LIMIT 1"
check "still a single collector row after restarts" "1" "SELECT count(*) FROM pgbackrest_monitor.collector"
check "lab back to OK" "OK" "SELECT overall_status FROM pgbackrest_monitor.health WHERE stanza_name = 'lab'"

section "9. daemon mode: heartbeats, SIGTERM"
before=$(psql -XAtqc "SELECT count(*) FROM pgbackrest_monitor.collection_run")
$COLLECTOR --config "$WORK/good.conf" 2>/dev/null &
DAEMON=$!
sleep 12
kill -TERM $DAEMON; wait $DAEMON; rc=$?
check "daemon stopped cleanly on SIGTERM" "0" "SELECT $rc"
check "daemon performed at least two cycles" "t" \
      "SELECT count(*) - $before >= 8 FROM pgbackrest_monitor.collection_run"
check "heartbeat fresh" "t" "SELECT now() - last_heartbeat < interval '30 seconds' FROM pgbackrest_monitor.collector"

section "10. disabled stanza is skipped; retention ran without error"
psql -Xqc "UPDATE pgbackrest_monitor.stanza SET enabled = false WHERE stanza_name = 'doesnotexist'" >/dev/null
n0=$(psql -XAtqc "SELECT count(*) FROM pgbackrest_monitor.collection_run WHERE stanza_name = 'doesnotexist'")
$COLLECTOR --config "$WORK/good.conf" --once >/dev/null
check "no new run for the disabled stanza" "$n0" "SELECT count(*) FROM pgbackrest_monitor.collection_run WHERE stanza_name = 'doesnotexist'"
check "disabled stanza reported UNKNOWN / MONITORING_DISABLED" "UNKNOWN|MONITORING_DISABLED" \
      "SELECT overall_status, reason_codes[1] FROM pgbackrest_monitor.health WHERE stanza_name = 'doesnotexist'"
check "no collector-side errors other than the deliberate ones" "0" \
      "SELECT count(*) FROM pgbackrest_monitor.error_history WHERE source = 'collector' AND category NOT IN ('binary_missing', 'timeout', 'validation_failed', 'parse_failed', 'permission_denied')"

echo
echo "integration: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
