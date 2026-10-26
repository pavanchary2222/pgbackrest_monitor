"""Collection cycle: one `info` per stanza, archiver sample, heartbeat, retention."""
import logging
import os
import signal
import socket
import time
from typing import Optional

import psycopg2

from . import __version__
from .config import CollectorConfig, StanzaConfig
from .parser import ParseError, ValidationError, parse_info_output, summarize, validate_info
from .pgsample import sample_instance
from .redact import redact, redact_argv
from .runner import pgbackrest_version, run_command
from .store import Store, StoreUnavailable

log = logging.getLogger("pgbackrest_monitor.collector")


class Collector:
    def __init__(self, cfg: CollectorConfig, store: Optional[Store] = None):
        self.cfg = cfg
        self.store = store or Store(cfg.dsn)
        self._stop = False
        self._cycles = 0
        self.pgbackrest_version: Optional[str] = None

    # -- lifecycle ----------------------------------------------------------------------------
    def install_signal_handlers(self):
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, self._on_signal)

    def _on_signal(self, signum, frame):
        log.info("received signal %d, stopping after the current stanza", signum)
        self._stop = True

    def start(self):
        """Connect (retrying), register collector and stanzas."""
        self.store.connect(attempts=10)
        self.pgbackrest_version = pgbackrest_version(self.cfg.pgbackrest_binary, min(self.cfg.timeout, 15))
        if self.pgbackrest_version is None:
            log.warning("could not determine pgBackRest version from %s", self.cfg.pgbackrest_binary)
        self.store.register_collector(
            self.cfg.collector_id, socket.gethostname(), os.getpid(), __version__,
            self.pgbackrest_version, self.cfg.interval, sorted(self.cfg.stanzas))
        for s in self.cfg.stanzas.values():
            self.store.register_stanza(s.name, s.pg_instance, self.cfg.interval)
        log.info("collector %s registered: %d stanza(s), interval %ds, pgBackRest %s",
                 self.cfg.collector_id, len(self.cfg.stanzas), self.cfg.interval, self.pgbackrest_version or "unknown")

    # -- one stanza ---------------------------------------------------------------------------
    def build_argv(self, stanza: StanzaConfig):
        return [self.cfg.pgbackrest_binary] + self.cfg.global_options + stanza.pgbackrest_args() + ["--output=json", "info"]

    def collect_stanza(self, stanza: StanzaConfig) -> str:
        """Run info for one stanza and record the outcome.  Returns the outcome string."""
        if not self.store.stanza_enabled(stanza.name):
            log.debug("stanza %s disabled in pgbackrest_monitor.stanza, skipping", stanza.name)
            return "disabled"
        if not self.store.try_lock_stanza(stanza.name):
            log.warning("stanza %s is being collected by another collector, skipping", stanza.name)
            now = _now()
            self.store.record_run(self.cfg.collector_id, stanza.name, "info", now, now, None, "skipped_locked",
                                  "another collector holds the lock for this stanza", None)
            return "skipped_locked"
        try:
            argv = self.build_argv(stanza)
            log.debug("running %s", " ".join(redact_argv(argv)))
            res = run_command(argv, self.cfg.timeout)

            if res.status in ("binary_missing", "permission_denied"):
                outcome, err, raw = res.status, res.error, None
            elif res.status in ("timeout", "spawn_failed"):
                outcome, err, raw = ("timeout" if res.status == "timeout" else "command_failed"), res.error, None
            elif res.exit_code != 0:
                outcome, err, raw = "command_failed", res.error, None
            else:
                try:
                    doc = parse_info_output(res.stdout)
                    elem = validate_info(doc, stanza.name)
                    outcome, err, raw = "success", None, doc
                    log.info("stanza %s: %s", stanza.name, summarize(elem))
                except ParseError as e:
                    outcome, err, raw = "parse_failed", "cannot parse info output: %s" % e, None
                except ValidationError as e:
                    outcome, err, raw = "validation_failed", "info output failed validation: %s" % e, None
            if err:
                log.warning("stanza %s: %s", stanza.name, redact(err))
            self.store.record_run(self.cfg.collector_id, stanza.name, "info", res.started_at, res.finished_at,
                                  res.exit_code, outcome, err, raw)
            return outcome
        finally:
            self.store.unlock_stanza(stanza.name)

    # -- one cycle ----------------------------------------------------------------------------
    def run_cycle(self):
        self._cycles += 1
        outcomes = {}
        for stanza in self.cfg.stanzas.values():
            if self._stop:
                break
            try:
                outcomes[stanza.name] = self.collect_stanza(stanza)
            except StoreUnavailable as e:
                log.error("stanza %s: database unavailable, result not recorded: %s", stanza.name, e)
                outcomes[stanza.name] = "db_unavailable"
            except psycopg2.Error as e:
                log.error("stanza %s: database error: %s", stanza.name, redact(str(e)).strip())
                outcomes[stanza.name] = "db_error"
                self._try_record_error(stanza.name, "db_error", "database error while recording run: %s" % e)
        self.sample_instances()
        try:
            self.store.heartbeat(self.cfg.collector_id)
        except (StoreUnavailable, psycopg2.Error) as e:
            log.error("heartbeat failed: %s", redact(str(e)).strip())
        if self._cycles % self.cfg.purge_every_cycles == 0:
            try:
                removed = [(t, n) for t, n in self.store.purge_history() if n]
                if removed:
                    log.info("retention: %s", ", ".join("%s=%d" % r for r in removed))
            except (StoreUnavailable, psycopg2.Error) as e:
                log.error("retention purge failed: %s", redact(str(e)).strip())
        return outcomes

    def sample_instances(self):
        """pg_stat_archiver samples: the local instance via the extension, others over read-only connections."""
        if self.cfg.sample_local():
            try:
                self.store.sample_pg_archiver()
            except (StoreUnavailable, psycopg2.Error) as e:
                log.error("pg_stat_archiver sample (local) failed: %s", redact(str(e)).strip())
                self._try_record_error(None, "pg_sample_failed", "pg_stat_archiver sample failed for instance local: %s" % e, "sample_pg_archiver")
        for inst in self.cfg.instances_in_use():
            try:
                sample = sample_instance(inst.dsn, connect_timeout=min(self.cfg.timeout, 10))
                self.store.record_pg_archiver_sample(inst.name, sample)
                log.debug("instance %s sampled: in_recovery=%s archive_mode=%s last_archived=%s",
                          inst.name, sample.get("in_recovery"), sample.get("archive_mode"), sample.get("last_archived_wal"))
            except (StoreUnavailable, psycopg2.Error) as e:
                log.error("pg_stat_archiver sample for instance %s failed: %s", inst.name, redact(str(e)).strip())
                self._try_record_error(None, "pg_sample_failed",
                                       "pg_stat_archiver sample failed for instance %s: %s" % (inst.name, e), "sample_instance")

    def _try_record_error(self, stanza, category, message, operation=None):
        try:
            self.store.record_error(stanza, category, message, operation)
        except (StoreUnavailable, psycopg2.Error):
            pass

    # -- daemon loop --------------------------------------------------------------------------
    def run_forever(self):
        while not self._stop:
            started = time.monotonic()
            try:
                if not self.store.connected:
                    self.store.connect(attempts=1)
                    # a reconnect after a server restart must re-register (cheap, idempotent)
                    self.store.register_collector(
                        self.cfg.collector_id, socket.gethostname(), os.getpid(), __version__,
                        self.pgbackrest_version, self.cfg.interval, sorted(self.cfg.stanzas))
                self.run_cycle()
            except StoreUnavailable as e:
                log.error("database unavailable, will retry next cycle: %s", e)
            except Exception:  # keep the daemon alive; systemd restarts on a crash anyway
                log.exception("unexpected error in collection cycle")
            elapsed = time.monotonic() - started
            delay = max(1.0, self.cfg.interval - elapsed)
            if elapsed > self.cfg.interval:
                log.warning("cycle took %.1fs, longer than the %ds interval", elapsed, self.cfg.interval)
            end = time.monotonic() + delay
            while not self._stop and time.monotonic() < end:
                time.sleep(min(1.0, end - time.monotonic()))
        self.store.close()
        log.info("collector stopped")


def _now():
    from datetime import datetime, timezone
    return datetime.now(timezone.utc)
