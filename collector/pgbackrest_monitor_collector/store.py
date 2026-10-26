"""Database access: thin wrapper over the extension's collector API functions."""
import logging
import time
from typing import Any, Optional

import psycopg2
import psycopg2.extras

from .redact import redact

log = logging.getLogger("pgbackrest_monitor.store")


class StoreUnavailable(Exception):
    pass


class Store:
    """One connection; every call is its own transaction.  Reconnects on connection loss."""

    def __init__(self, dsn: str, application_name: str = "pgbackrest_monitor_collector"):
        self._dsn = dsn
        self._app = application_name
        self._conn = None

    # -- connection management ---------------------------------------------------------------
    def connect(self, attempts: int = 1, backoff: float = 2.0, max_backoff: float = 60.0) -> None:
        delay = backoff
        last = None
        for i in range(attempts):
            try:
                self._conn = psycopg2.connect(self._dsn, application_name=self._app, connect_timeout=10)
                self._conn.autocommit = False
                with self._conn.cursor() as cur:
                    cur.execute("SELECT 1 FROM pg_extension WHERE extname = 'pgbackrest_monitor'")
                    if cur.fetchone() is None:
                        raise StoreUnavailable("extension pgbackrest_monitor is not installed in the target database")
                self._conn.commit()
                return
            except StoreUnavailable:
                raise
            except psycopg2.Error as e:
                last = e
                log.warning("database connection failed (attempt %d/%d): %s", i + 1, attempts, redact(str(e)).strip())
                self._conn = None
                if i + 1 < attempts:
                    time.sleep(delay)
                    delay = min(delay * 2, max_backoff)
        raise StoreUnavailable("cannot connect to database: %s" % redact(str(last)).strip())

    def close(self) -> None:
        if self._conn is not None:
            try:
                self._conn.close()
            finally:
                self._conn = None

    @property
    def connected(self) -> bool:
        return self._conn is not None and self._conn.closed == 0

    def _call(self, sql: str, params=()) -> Any:
        if not self.connected:
            self.connect()
        try:
            with self._conn.cursor() as cur:
                cur.execute(sql, params)
                row = cur.fetchone()
            self._conn.commit()
            return row[0] if row else None
        except psycopg2.OperationalError as e:
            # connection lost (server restart, network); drop it so the next call reconnects
            log.warning("database connection lost: %s", redact(str(e)).strip())
            self.close()
            raise StoreUnavailable(redact(str(e)).strip())
        except psycopg2.Error as e:
            try:
                self._conn.rollback()
            except psycopg2.Error:
                self.close()
            raise

    # -- extension API -------------------------------------------------------------------------
    def register_collector(self, collector_id, hostname, pid, version, pgbackrest_version, interval_seconds, stanzas):
        return self._call(
            "SELECT pgbackrest_monitor.register_collector(%s, %s, %s, %s, %s, make_interval(secs => %s), %s)",
            (collector_id, hostname, pid, version, pgbackrest_version, interval_seconds, list(stanzas)))

    def heartbeat(self, collector_id):
        return self._call("SELECT pgbackrest_monitor.heartbeat(%s)", (collector_id,))

    def register_stanza(self, stanza, pg_instance, interval_seconds):
        return self._call("SELECT pgbackrest_monitor.register_stanza(%s, %s, make_interval(secs => %s))",
                          (stanza, pg_instance, interval_seconds))

    def stanza_enabled(self, stanza) -> bool:
        return bool(self._call("SELECT pgbackrest_monitor.stanza_enabled(%s)", (stanza,)))

    def try_lock_stanza(self, stanza) -> bool:
        return bool(self._call("SELECT pgbackrest_monitor.try_lock_stanza(%s)", (stanza,)))

    def unlock_stanza(self, stanza) -> None:
        if self.connected:
            try:
                self._call("SELECT pgbackrest_monitor.unlock_stanza(%s)", (stanza,))
            except (StoreUnavailable, psycopg2.Error):
                pass  # the lock dies with the session anyway

    def record_run(self, collector_id, stanza, command, started_at, finished_at, exit_code, outcome,
                   error_message: Optional[str], raw_output) -> int:
        raw = psycopg2.extras.Json(raw_output) if raw_output is not None else None
        return self._call(
            "SELECT pgbackrest_monitor.record_run(%s, %s, %s, %s, %s, %s, %s, %s, %s)",
            (collector_id, stanza, command, started_at, finished_at, exit_code, outcome,
             redact(error_message) if error_message else None, raw))

    def record_error(self, stanza, category, message, operation=None, details=None) -> int:
        return self._call(
            "SELECT pgbackrest_monitor.record_error(%s, %s, %s, %s, %s)",
            (stanza, category, redact(message), operation,
             psycopg2.extras.Json(details) if details is not None else None))

    def sample_pg_archiver(self) -> int:
        return self._call("SELECT pgbackrest_monitor.sample_pg_archiver()")

    def record_pg_archiver_sample(self, instance: str, sample: dict) -> int:
        cols = ("server_version_num", "in_recovery", "archive_mode", "archive_command_set", "archive_library_set",
                "wal_segment_size", "archived_count", "last_archived_wal", "last_archived_time",
                "failed_count", "last_failed_wal", "last_failed_time", "stats_reset",
                "current_wal_lsn", "timeline_id", "wal_bytes")
        return self._call(
            "SELECT pgbackrest_monitor.record_pg_archiver_sample(%s, " + ", ".join(["%s"] * len(cols)) + ")",
            (instance,) + tuple(sample.get(c) for c in cols))

    def purge_history(self):
        if not self.connected:
            self.connect()
        try:
            with self._conn.cursor() as cur:
                cur.execute("SELECT table_name, rows_removed FROM pgbackrest_monitor.purge_history()")
                rows = cur.fetchall()
            self._conn.commit()
            return rows
        except psycopg2.OperationalError as e:
            self.close()
            raise StoreUnavailable(redact(str(e)).strip())
        except psycopg2.Error:
            self._conn.rollback()
            raise
