"""Collector configuration (INI file).  See config/collector.conf.example."""
import configparser
import re
import socket
from dataclasses import dataclass, field
from typing import Dict, List, Optional

STANZA_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
# Extra pgBackRest options accepted from the config file: `--name=value` with a conservative
# character set.  Options that would change what command runs or how output is produced are refused.
OPTION_RE = re.compile(r"^--([a-z][a-z0-9-]*)(?:=([^\s\x00-\x1f]*))?$")
FORBIDDEN_OPTIONS = {"stanza", "output", "set", "type", "cmd", "command", "exec-id"}


class ConfigError(Exception):
    pass


INSTANCE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")


@dataclass
class InstanceConfig:
    """A PostgreSQL instance whose pg_stat_archiver the collector samples over a read-only connection."""
    name: str
    dsn: str


@dataclass
class StanzaConfig:
    name: str
    pg_instance: Optional[str] = "local"   # 'local', a [instance:<name>] name, or None (no comparison)
    repo: Optional[int] = None
    options: List[str] = field(default_factory=list)

    def pgbackrest_args(self) -> List[str]:
        args = ["--stanza=" + self.name]
        if self.repo is not None:
            args.append("--repo=%d" % self.repo)
        args.extend(self.options)
        return args


@dataclass
class CollectorConfig:
    dsn: str
    collector_id: str
    interval: int = 60
    timeout: int = 60
    pgbackrest_binary: str = "/usr/bin/pgbackrest"
    global_options: List[str] = field(default_factory=list)
    log_level: str = "info"
    purge_every_cycles: int = 10
    stanzas: Dict[str, StanzaConfig] = field(default_factory=dict)
    instances: Dict[str, InstanceConfig] = field(default_factory=dict)

    def sample_local(self) -> bool:
        return any(s.pg_instance == "local" for s in self.stanzas.values())

    def instances_in_use(self) -> List[InstanceConfig]:
        used = {s.pg_instance for s in self.stanzas.values()} - {None, "local"}
        return [self.instances[n] for n in sorted(used)]


def _parse_options(raw: str, where: str) -> List[str]:
    out = []
    for tok in raw.split():
        m = OPTION_RE.match(tok)
        if not m:
            raise ConfigError("%s: option %r is not of the form --name=value" % (where, tok))
        if m.group(1) in FORBIDDEN_OPTIONS:
            raise ConfigError("%s: option --%s may not be set by the collector configuration" % (where, m.group(1)))
        out.append(tok)
    return out


def _getint(sec, key, default, where, minimum=1):
    try:
        v = sec.getint(key, fallback=default)
    except ValueError:
        raise ConfigError("%s: %s must be an integer" % (where, key))
    if v < minimum:
        raise ConfigError("%s: %s must be >= %d" % (where, key, minimum))
    return v


def load_config(path: str, only_stanzas: Optional[List[str]] = None) -> CollectorConfig:
    cp = configparser.ConfigParser(interpolation=None)
    read = cp.read(path, encoding="utf-8")
    if not read:
        raise ConfigError("cannot read configuration file %s" % path)
    if "collector" not in cp:
        raise ConfigError("%s: missing [collector] section" % path)
    sec = cp["collector"]
    dsn = sec.get("dsn", fallback="").strip()
    if not dsn:
        raise ConfigError("%s: [collector] dsn is required (libpq conninfo or URI; keep passwords in ~/.pgpass)" % path)

    cfg = CollectorConfig(
        dsn=dsn,
        collector_id=sec.get("collector_id", fallback="").strip() or socket.gethostname(),
        interval=_getint(sec, "interval", 60, "[collector]", minimum=5),
        timeout=_getint(sec, "timeout", 60, "[collector]"),
        pgbackrest_binary=sec.get("pgbackrest_binary", fallback="/usr/bin/pgbackrest").strip(),
        log_level=sec.get("log_level", fallback="info").strip().lower(),
        purge_every_cycles=_getint(sec, "purge_every_cycles", 10, "[collector]"),
    )
    if cfg.log_level not in ("debug", "info", "warning", "error"):
        raise ConfigError("[collector] log_level must be debug, info, warning or error")
    gopts = []
    for key, opt in (("pgbackrest_config", "--config"), ("pgbackrest_config_include_path", "--config-include-path"),
                     ("pgbackrest_config_path", "--config-path")):
        v = sec.get(key, fallback="").strip()
        if v:
            gopts.append("%s=%s" % (opt, v))
    gopts.extend(_parse_options(sec.get("options", fallback=""), "[collector] options"))
    cfg.global_options = gopts

    for name in cp.sections():
        if name.startswith("instance:"):
            inst = name[len("instance:"):].strip()
            if inst == "local" or not INSTANCE_NAME_RE.match(inst):
                raise ConfigError("invalid instance name %r in section [%s] ('local' is reserved)" % (inst, name))
            idsn = cp[name].get("dsn", fallback="").strip()
            if not idsn:
                raise ConfigError("[%s]: dsn is required" % name)
            cfg.instances[inst] = InstanceConfig(name=inst, dsn=idsn)

    for name in cp.sections():
        if not name.startswith("stanza:"):
            continue
        stanza = name[len("stanza:"):].strip()
        if not STANZA_NAME_RE.match(stanza):
            raise ConfigError("invalid stanza name %r in section [%s]" % (stanza, name))
        if only_stanzas and stanza not in only_stanzas:
            continue
        s = cp[name]
        repo = None
        if s.get("repo", fallback="").strip():
            repo = _getint(s, "repo", None, "[%s]" % name, minimum=1)
        pg_instance = s.get("pg_instance", fallback="local").strip() or "local"
        if pg_instance.lower() == "none":
            pg_instance = None
        elif pg_instance != "local" and pg_instance not in cfg.instances:
            raise ConfigError("[%s]: pg_instance %r has no [instance:%s] section" % (name, pg_instance, pg_instance))
        cfg.stanzas[stanza] = StanzaConfig(
            name=stanza,
            pg_instance=pg_instance,
            repo=repo,
            options=_parse_options(s.get("options", fallback=""), "[%s] options" % name),
        )
    if not cfg.stanzas:
        raise ConfigError("%s: no [stanza:<name>] sections (or none matching --stanza)" % path)
    return cfg
