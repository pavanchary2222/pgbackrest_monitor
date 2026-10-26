# Monitoring and alerting integration

All examples read the extension's views with a role that has `pgbackrest_monitor_reader`.

## Prometheus (postgres_exporter custom queries)

```yaml
# queries.yaml for prometheus-community/postgres_exporter
pgbackrest_monitor_health:
  query: |
    SELECT stanza_name,
           CASE overall_status    WHEN 'OK' THEN 0 WHEN 'WARNING' THEN 1 WHEN 'CRITICAL' THEN 2 ELSE 3 END AS overall,
           CASE backup_status     WHEN 'OK' THEN 0 WHEN 'WARNING' THEN 1 WHEN 'CRITICAL' THEN 2 ELSE 3 END AS backup,
           CASE archive_status    WHEN 'OK' THEN 0 WHEN 'WARNING' THEN 1 WHEN 'CRITICAL' THEN 2 ELSE 3 END AS archive,
           CASE repository_status WHEN 'OK' THEN 0 WHEN 'WARNING' THEN 1 WHEN 'CRITICAL' THEN 2 ELSE 3 END AS repository,
           CASE collector_status  WHEN 'OK' THEN 0 WHEN 'WARNING' THEN 1 WHEN 'CRITICAL' THEN 2 ELSE 3 END AS collector,
           COALESCE(extract(epoch FROM backup_age), -1)        AS backup_age_seconds,
           COALESCE(extract(epoch FROM data_age), -1)          AS data_age_seconds,
           COALESCE(extract(epoch FROM heartbeat_age), -1)     AS heartbeat_age_seconds,
           COALESCE(pg_archive_failed_count, 0)                AS pg_archive_failed_count
    FROM pgbackrest_monitor.health
  master: true
  metrics:
    - stanza_name:             {usage: LABEL}
    - overall:                 {usage: GAUGE, description: "0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN"}
    - backup:                  {usage: GAUGE}
    - archive:                 {usage: GAUGE}
    - repository:              {usage: GAUGE}
    - collector:               {usage: GAUGE}
    - backup_age_seconds:      {usage: GAUGE}
    - data_age_seconds:        {usage: GAUGE}
    - heartbeat_age_seconds:   {usage: GAUGE}
    - pg_archive_failed_count: {usage: GAUGE}

pgbackrest_monitor_archive:
  query: |
    SELECT stanza_name, repo_key::text AS repo,
           COALESCE(pg_segments_waiting, -1) AS pg_segments_waiting,
           COALESCE(repo_segments_behind_pg, 0) AS repo_segments_behind_pg,
           COALESCE(extract(epoch FROM time_since_last_archive), -1) AS seconds_since_last_archive
    FROM pgbackrest_monitor.archive_status
  master: true
  metrics:
    - stanza_name: {usage: LABEL}
    - repo:        {usage: LABEL}
    - pg_segments_waiting:        {usage: GAUGE}
    - repo_segments_behind_pg:    {usage: GAUGE}
    - seconds_since_last_archive: {usage: GAUGE}

pgbackrest_monitor_reasons:
  query: SELECT stanza_name, component, reason_code, 1 AS active FROM pgbackrest_monitor.health_components WHERE status <> 'OK'
  master: true
  metrics:
    - stanza_name: {usage: LABEL}
    - component:   {usage: LABEL}
    - reason_code: {usage: LABEL}
    - active:      {usage: GAUGE}
```

Alert rules:

```yaml
groups:
- name: pgbackrest
  rules:
  - alert: PgBackRestCritical
    expr: pgbackrest_monitor_health_overall == 2
    for: 5m
    labels: {severity: critical}
    annotations:
      summary: "pgBackRest stanza {{ $labels.stanza_name }} is CRITICAL"
      description: "See SELECT * FROM pgbackrest_monitor.health_components WHERE stanza_name = '{{ $labels.stanza_name }}'"
  - alert: PgBackRestWarning
    expr: pgbackrest_monitor_health_overall == 1
    for: 30m
    labels: {severity: warning}
  - alert: PgBackRestMonitoringUnknown
    expr: pgbackrest_monitor_health_overall == 3
    for: 15m
    labels: {severity: warning}
    annotations: {summary: "pgBackRest monitoring cannot determine the state of {{ $labels.stanza_name }}"}
```

## Nagios / Icinga check

```bash
#!/usr/bin/env bash
# check_pgbackrest_monitor <stanza>   (connection via PG* environment / .pgpass)
stanza=$1
row=$(psql -XAtq -F '|' -c "SELECT overall_status, array_to_string(reason_codes, ','), messages[1]
                            FROM pgbackrest_monitor.health WHERE stanza_name = '${stanza//\'/\'\'}'") || { echo "UNKNOWN - query failed"; exit 3; }
[[ -z $row ]] && { echo "UNKNOWN - stanza $stanza not registered"; exit 3; }
IFS='|' read -r status reasons msg <<< "$row"
detail=$(psql -XAtq -c "SELECT string_agg(component || ': ' || message, '; ' ORDER BY component)
                        FROM pgbackrest_monitor.health_components WHERE stanza_name = '${stanza//\'/\'\'}' AND status <> 'OK'")
case $status in
  OK)       echo "OK - $stanza: $msg";                    exit 0 ;;
  WARNING)  echo "WARNING - $stanza [$reasons] $detail";  exit 1 ;;
  CRITICAL) echo "CRITICAL - $stanza [$reasons] $detail"; exit 2 ;;
  *)        echo "UNKNOWN - $stanza [$reasons] $detail";  exit 3 ;;
esac
```

## Zabbix (low-level discovery)

```sql
-- discovery
SELECT json_agg(json_build_object('{#STANZA}', stanza_name)) FROM pgbackrest_monitor.stanza WHERE enabled;
-- item per stanza
SELECT overall_status FROM pgbackrest_monitor.health WHERE stanza_name = '{#STANZA}';
```

## Grafana

Table panel: `SELECT * FROM pgbackrest_monitor.health_components ORDER BY stanza_name, component`.
Time series of backup age: `SELECT stopped_at AS time, stanza_name, extract(epoch FROM duration) FROM pgbackrest_monitor.backup_history WHERE $__timeFilter(stopped_at)`.

## Reason codes to route on

| Component | Codes |
|---|---|
| collector | `COLLECTOR_OK`, `COLLECTOR_NEVER_SEEN`, `COLLECTOR_NO_HEARTBEAT`, `COLLECTOR_HEARTBEAT_STALE`, `NO_DATA`, `DATA_STALE`, `COLLECTION_FAILING`, `MONITORING_DISABLED`, `STANZA_NOT_REGISTERED` |
| backup | `BACKUP_OK`, `BACKUP_NO_DATA`, `BACKUP_NONE`, `BACKUP_NONE_VALID`, `BACKUP_TOO_OLD`, `BACKUP_FULL_TOO_OLD`, `BACKUP_HAS_ERROR`, `STANZA_DB_MISMATCH` |
| archive | `ARCHIVE_OK`, `ARCHIVE_IDLE`, `ARCHIVE_NOT_EXPECTED`, `ARCHIVE_NO_PG_COMPARISON`, `ARCHIVE_NO_REPO_DATA`, `ARCHIVE_REPO_UNAVAILABLE`, `ARCHIVE_NO_PG_SAMPLE`, `ARCHIVE_PG_SAMPLE_STALE`, `ARCHIVE_MODE_OFF`, `ARCHIVE_COMMAND_UNSET`, `ARCHIVE_FAILING`, `ARCHIVE_NEVER`, `ARCHIVE_LAG`, `ARCHIVE_STALE`, `ARCHIVE_REPO_EMPTY`, `ARCHIVE_REPO_BEHIND` |
| repository | `REPO_OK`, `REPO_NO_DATA`, `REPO_NO_BACKUPS`, `REPO_STANZA_MISSING`, `REPO_STANZA_DATA_MISSING`, `REPO_DB_MISMATCH`, `REPO_BACKUP_NOT_FOUND`, `REPO_ERROR`, `REPO_STATUS_UNRECOGNIZED` |
