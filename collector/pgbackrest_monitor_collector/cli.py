"""Command line entry point."""
import argparse
import logging
import sys

from . import __version__
from .collector import Collector
from .config import ConfigError, load_config
from .redact import redact
from .store import StoreUnavailable

DEFAULT_CONFIG = "/etc/pgbackrest-monitor/collector.conf"


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="pgbackrest-monitor-collector",
                                description="Feeds pgBackRest info output to the pgbackrest_monitor extension.")
    p.add_argument("-c", "--config", default=DEFAULT_CONFIG, help="configuration file (default %s)" % DEFAULT_CONFIG)
    p.add_argument("--once", action="store_true", help="run a single collection cycle and exit (for systemd timers / cron)")
    p.add_argument("--stanza", action="append", help="restrict to this stanza (repeatable)")
    p.add_argument("--check-config", action="store_true", help="validate the configuration and exit")
    p.add_argument("--log-level", choices=("debug", "info", "warning", "error"), help="override log level")
    p.add_argument("--version", action="version", version=__version__)
    args = p.parse_args(argv)

    try:
        cfg = load_config(args.config, args.stanza)
    except ConfigError as e:
        print("configuration error: %s" % e, file=sys.stderr)
        return 2
    level = (args.log_level or cfg.log_level).upper()
    logging.basicConfig(level=level, format="%(asctime)s %(levelname)s %(name)s: %(message)s", stream=sys.stderr)

    if args.check_config:
        print("configuration OK: collector_id=%s interval=%ds timeout=%ds binary=%s stanzas=%s" % (
            cfg.collector_id, cfg.interval, cfg.timeout, cfg.pgbackrest_binary, ",".join(sorted(cfg.stanzas))))
        return 0

    collector = Collector(cfg)
    collector.install_signal_handlers()
    try:
        collector.start()
    except StoreUnavailable as e:
        logging.getLogger("pgbackrest_monitor").error("startup failed: %s", redact(str(e)))
        return 1
    if args.once:
        outcomes = collector.run_cycle()
        collector.store.close()
        bad = [s for s, o in outcomes.items() if o not in ("success", "disabled", "skipped_locked")]
        return 1 if bad else 0
    collector.run_forever()
    return 0
