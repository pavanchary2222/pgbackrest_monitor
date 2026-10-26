import os
import tempfile
import unittest

import _paths  # noqa: F401
from pgbackrest_monitor_collector.config import ConfigError, load_config

BASE = """
[collector]
dsn = dbname=postgres
interval = 30
timeout = 20
pgbackrest_binary = /usr/bin/pgbackrest
pgbackrest_config = /etc/pgbackrest/pgbackrest.conf
options = --log-level-console=warn
"""


class ConfigTests(unittest.TestCase):
    def write(self, text):
        fd, path = tempfile.mkstemp(suffix=".conf")
        with os.fdopen(fd, "w") as f:
            f.write(text)
        self.addCleanup(os.unlink, path)
        return path

    def test_full_config(self):
        cfg = load_config(self.write(BASE + """
[instance:standby1]
dsn = host=standby1 dbname=postgres
[stanza:main]
pg_instance = local
repo = 2
options = --repo2-host=backup
[stanza:dw]
pg_instance = standby1
[stanza:other]
pg_instance = none
"""))
        self.assertEqual(cfg.interval, 30)
        self.assertEqual(cfg.global_options, ["--config=/etc/pgbackrest/pgbackrest.conf", "--log-level-console=warn"])
        self.assertEqual(cfg.stanzas["main"].pgbackrest_args(), ["--stanza=main", "--repo=2", "--repo2-host=backup"])
        self.assertEqual(cfg.stanzas["dw"].pg_instance, "standby1")
        self.assertIsNone(cfg.stanzas["other"].pg_instance)
        self.assertTrue(cfg.sample_local())
        self.assertEqual([i.name for i in cfg.instances_in_use()], ["standby1"])

    def test_stanza_filter(self):
        cfg = load_config(self.write(BASE + "[stanza:a]\n[stanza:b]\n"), only_stanzas=["b"])
        self.assertEqual(list(cfg.stanzas), ["b"])

    def test_errors(self):
        cases = {
            "[collector]\ninterval=10\n[stanza:a]\n": "dsn is required",
            BASE: "no [stanza:",
            BASE + "[stanza:bad name]\n": "invalid stanza name",
            BASE + "[stanza:a]\noptions = --output=text\n": "may not be set",
            BASE + "[stanza:a]\noptions = --stanza=other\n": "may not be set",
            BASE + "[stanza:a]\noptions = -x\n": "not of the form",
            BASE + "[stanza:a]\noptions = --repo1-path=/a;rm\\ -rf\n": "not of the form",
            BASE + "[stanza:a]\npg_instance = nosuch\n": "has no [instance:nosuch]",
            BASE + "[instance:local]\ndsn=x\n[stanza:a]\n": "reserved",
            BASE + "[stanza:a]\nrepo = zero\n": "must be an integer",
            BASE.replace("interval = 30", "interval = 1") + "[stanza:a]\n": "must be >= 5",
        }
        for text, frag in cases.items():
            with self.assertRaises(ConfigError, msg=text) as cm:
                load_config(self.write(text))
            self.assertIn(frag, str(cm.exception), text)

    def test_missing_file(self):
        with self.assertRaises(ConfigError):
            load_config("/nonexistent/collector.conf")


if __name__ == "__main__":
    unittest.main()
