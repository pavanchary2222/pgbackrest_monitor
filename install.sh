#!/usr/bin/env bash
# Installs the extension files into the PostgreSQL share directory and the collector into
# /usr/local.  Run as root.  Does NOT touch any database: afterwards run, as a superuser,
#   CREATE EXTENSION pgbackrest_monitor;
# in the database the collector will connect to, and follow README.md "Installation".
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PG_CONFIG=${PG_CONFIG:-pg_config}
PREFIX=${PREFIX:-/usr/local}
CONF_DIR=${CONF_DIR:-/etc/pgbackrest-monitor}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
MODE=${1:-all}   # all | extension | collector

if [[ $MODE == all || $MODE == extension ]]; then
    echo "==> installing extension via PGXS ($($PG_CONFIG --version))"
    make -C "$HERE" PG_CONFIG="$PG_CONFIG" install
fi

if [[ $MODE == all || $MODE == collector ]]; then
    echo "==> installing collector"
    python3 -c 'import psycopg2' 2>/dev/null || echo "WARNING: python3 psycopg2 is missing (apt install python3-psycopg2 / dnf install python3-psycopg2)"
    SITE=$PREFIX/lib/pgbackrest-monitor
    rm -rf "$SITE" && mkdir -p "$SITE"
    cp -r "$HERE/collector/pgbackrest_monitor_collector" "$SITE/"
    cat > "$PREFIX/bin/pgbackrest-monitor-collector" <<WRAP
#!/usr/bin/env python3
import sys
sys.path.insert(0, "$SITE")
from pgbackrest_monitor_collector.cli import main
sys.exit(main())
WRAP
    chmod 755 "$PREFIX/bin/pgbackrest-monitor-collector"
    mkdir -p "$CONF_DIR"
    if [[ ! -e $CONF_DIR/collector.conf ]]; then
        cp "$HERE/config/collector.conf.example" "$CONF_DIR/collector.conf"
        chown postgres:postgres "$CONF_DIR/collector.conf" 2>/dev/null || true
        chmod 640 "$CONF_DIR/collector.conf"
        echo "    created $CONF_DIR/collector.conf - edit dsn and [stanza:...] sections"
    fi
    for u in pgbackrest-monitor-collector.service pgbackrest-monitor-collector-once.service pgbackrest-monitor-collector.timer; do
        sed "s#/usr/local/bin/#$PREFIX/bin/#" "$HERE/systemd/$u" > "$UNIT_DIR/$u"
    done
    command -v systemctl >/dev/null && systemctl daemon-reload || true
    echo "    units installed; enable ONE of:"
    echo "      systemctl enable --now pgbackrest-monitor-collector.service   (daemon)"
    echo "      systemctl enable --now pgbackrest-monitor-collector.timer     (one cycle per minute)"
fi
echo "done"
