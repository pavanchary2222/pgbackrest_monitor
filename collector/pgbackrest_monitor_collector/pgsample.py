"""Read-only sampling of pg_stat_archiver on a remote PostgreSQL instance (typically a standby).

Mirrors pgbackrest_monitor.sample_pg_archiver() but runs client side so the instance may be
read-only.  Needs no superuser: archive_command / pg_control_checkpoint() are optional and
recorded as NULL when the role may not read them.
"""
import logging
from typing import Dict, Optional

import psycopg2

from .redact import redact

log = logging.getLogger("pgbackrest_monitor.pgsample")

_BASE_SQL = """
SELECT current_setting('server_version_num')::int                 AS server_version_num,
       pg_is_in_recovery()                                         AS in_recovery,
       current_setting('archive_mode')                             AS archive_mode,
       pg_size_bytes(current_setting('wal_segment_size'))          AS wal_segment_size,
       a.archived_count, a.last_archived_wal, a.last_archived_time,
       a.failed_count, a.last_failed_wal, a.last_failed_time, a.stats_reset,
       CASE WHEN pg_is_in_recovery()
            THEN COALESCE(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())
            ELSE pg_current_wal_lsn() END                          AS current_wal_lsn,
       CASE WHEN pg_is_in_recovery() THEN NULL
            ELSE ('x' || substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8))::bit(32)::bigint END AS timeline_id
FROM pg_stat_archiver a
"""


def _optional(cur, sql: str, conn) -> Optional[object]:
    try:
        cur.execute("SAVEPOINT opt")
        cur.execute(sql)
        row = cur.fetchone()
        cur.execute("RELEASE SAVEPOINT opt")
        return row[0] if row else None
    except psycopg2.Error:
        cur.execute("ROLLBACK TO SAVEPOINT opt")
        return None


def sample_instance(dsn: str, connect_timeout: int = 10) -> Dict[str, object]:
    """Return a dict of pg_archiver_sample column values for the instance behind dsn."""
    conn = psycopg2.connect(dsn, application_name="pgbackrest_monitor_sampler", connect_timeout=connect_timeout)
    try:
        conn.set_session(readonly=True, autocommit=False)
        with conn.cursor() as cur:
            cur.execute(_BASE_SQL)
            cols = [d[0] for d in cur.description]
            sample = dict(zip(cols, cur.fetchone()))
            if sample["current_wal_lsn"] is not None:
                sample["current_wal_lsn"] = str(sample["current_wal_lsn"])
            cmd = _optional(cur, "SELECT current_setting('archive_command')", conn)
            sample["archive_command_set"] = None if cmd is None else (cmd.strip() != "" and cmd != "(disabled)")
            lib = None
            if sample["server_version_num"] >= 150000:
                lib = _optional(cur, "SELECT current_setting('archive_library')", conn)
            sample["archive_library_set"] = None if lib is None else lib.strip() != ""
            sample["wal_bytes"] = (_optional(cur, "SELECT wal_bytes FROM pg_stat_wal", conn)
                                   if sample["server_version_num"] >= 140000 else None)
            if sample["timeline_id"] is None:
                sample["timeline_id"] = _optional(cur, "SELECT timeline_id FROM pg_control_checkpoint()", conn)
        conn.rollback()
        return sample
    finally:
        conn.close()
