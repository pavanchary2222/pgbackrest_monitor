-- Pure WAL name arithmetic used by the archive health rules.
\pset null '<null>'
SET timezone = 'UTC';
SELECT pgbackrest_monitor.wal_segment_name('000000010000000000000042') AS plain,
       pgbackrest_monitor.wal_segment_name('000000010000000000000042.partial') AS partial,
       pgbackrest_monitor.wal_segment_name('000000010000000000000003.00000028.backup') AS history,
       pgbackrest_monitor.wal_segment_name('not-a-wal') AS junk,
       pgbackrest_monitor.wal_segment_name(NULL) AS nul;

SELECT pgbackrest_monitor.wal_timeline('000000010000000000000042') AS tl1,
       pgbackrest_monitor.wal_timeline('0000000A00000001000000FF') AS tl10;

-- 16MB segments: 256 per logical log file
SELECT pgbackrest_monitor.wal_segno('000000010000000000000000', 16777216) AS first,
       pgbackrest_monitor.wal_segno('0000000100000000000000FF', 16777216) AS last_in_log0,
       pgbackrest_monitor.wal_segno('000000010000000100000000', 16777216) AS first_in_log1,
       pgbackrest_monitor.wal_segno('000000010000000000000042', 16777216) AS x42;
-- 64MB segments: 64 per logical log file
SELECT pgbackrest_monitor.wal_segno('00000001000000000000003F', 67108864) AS last_in_log0,
       pgbackrest_monitor.wal_segno('000000010000000100000000', 67108864) AS first_in_log1;

-- wal_file_name() must agree with pg_walfile_name() on this server (any wal_segment_size).
SELECT lsn,
       pgbackrest_monitor.wal_file_name(
            pgbackrest_monitor.wal_timeline(pg_walfile_name(lsn)), lsn,
            pg_size_bytes(current_setting('wal_segment_size'))) = pg_walfile_name(lsn) AS agrees
FROM unnest(ARRAY['0/0', '0/1', '0/3000028', '0/FFFFFFFF', '1/0', 'A/2FDAB000', 'FFFF/12345678']::pg_lsn[]) lsn;

SELECT pgbackrest_monitor.wal_file_name(1, '0/3000028', 16777216) AS tl1,
       pgbackrest_monitor.wal_file_name(23, '5/A0000000', 16777216) AS tl23,
       pgbackrest_monitor.wal_file_name(1, '0/3000028', 67108864) AS seg64mb;

-- health_rank / worst_status ordering
SELECT pgbackrest_monitor.worst_status(ARRAY['OK', 'OK']) AS ok,
       pgbackrest_monitor.worst_status(ARRAY['OK', 'UNKNOWN']) AS unknown,
       pgbackrest_monitor.worst_status(ARRAY['WARNING', 'UNKNOWN']) AS warning,
       pgbackrest_monitor.worst_status(ARRAY['WARNING', 'CRITICAL', 'OK']) AS critical,
       pgbackrest_monitor.worst_status(ARRAY[]::text[]) AS empty;
