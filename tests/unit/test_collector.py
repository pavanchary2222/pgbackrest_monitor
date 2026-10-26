import os
import unittest

import _paths
from pgbackrest_monitor_collector.collector import Collector
from pgbackrest_monitor_collector.config import CollectorConfig, InstanceConfig, StanzaConfig
from pgbackrest_monitor_collector.store import StoreUnavailable

FAKE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fake_pgbackrest.py")


class FakeStore:
    """Records every extension call instead of talking to PostgreSQL."""

    def __init__(self):
        self.calls = []
        self.locked = set()
        self.disabled = set()
        self.connected = True
        self.fail_sample = False

    def _rec(self, *a):
        self.calls.append(a)

    def connect(self, **kw):
        self.connected = True

    def close(self):
        self.connected = False

    def register_collector(self, *a):
        self._rec("register_collector", *a)

    def register_stanza(self, *a):
        self._rec("register_stanza", *a)

    def heartbeat(self, cid):
        self._rec("heartbeat", cid)

    def stanza_enabled(self, s):
        return s not in self.disabled

    def try_lock_stanza(self, s):
        if s in self.locked:
            return False
        self.locked.add(s)
        return True

    def unlock_stanza(self, s):
        self.locked.discard(s)

    def record_run(self, cid, stanza, command, started, finished, exit_code, outcome, err, raw):
        self._rec("record_run", stanza, command, exit_code, outcome, err, raw)
        return len(self.calls)

    def record_error(self, *a):
        self._rec("record_error", *a)

    def sample_pg_archiver(self):
        if self.fail_sample:
            raise StoreUnavailable("db gone")
        self._rec("sample_pg_archiver")

    def record_pg_archiver_sample(self, inst, sample):
        self._rec("record_pg_archiver_sample", inst)

    def purge_history(self):
        self._rec("purge_history")
        return [("collection_run", 3)]

    def runs(self):
        return [c for c in self.calls if c[0] == "record_run"]


def make(stanzas=("lab",), binary=FAKE, **kw):
    cfg = CollectorConfig(dsn="dbname=x", collector_id="t", interval=60, timeout=kw.pop("timeout", 5),
                          pgbackrest_binary=binary, global_options=["--config=/tmp/pgbackrest.conf"],
                          purge_every_cycles=kw.pop("purge_every_cycles", 10))
    for s in stanzas:
        cfg.stanzas[s] = StanzaConfig(name=s, **kw)
    store = FakeStore()
    return Collector(cfg, store), store


class CollectorTests(unittest.TestCase):
    def setUp(self):
        for k in list(os.environ):
            if k.startswith("FAKE_PGBACKREST_"):
                del os.environ[k]

    def test_argv_is_fixed_and_shell_free(self):
        c, _ = make(repo=2, options=["--log-level-console=warn"])
        self.assertEqual(c.build_argv(c.cfg.stanzas["lab"]),
                         [FAKE, "--config=/tmp/pgbackrest.conf", "--stanza=lab", "--repo=2", "--log-level-console=warn", "--output=json", "info"])

    def test_success_cycle(self):
        os.environ["FAKE_PGBACKREST_FIXTURE"] = os.path.join(_paths.FIXTURES, "info_lab_healthy.json")
        c, st = make()
        out = c.run_cycle()
        self.assertEqual(out, {"lab": "success"})
        run = st.runs()[0]
        self.assertEqual((run[1], run[2], run[3], run[4], run[5]), ("lab", "info", 0, "success", None))
        self.assertEqual(run[6][0]["name"], "lab")
        self.assertIn(("sample_pg_archiver",), st.calls)
        self.assertIn(("heartbeat", "t"), st.calls)
        self.assertNotIn(("purge_history",), st.calls)
        self.assertEqual(st.locked, set())  # lock released

    def test_outcomes(self):
        cases = [
            ({"FAKE_PGBACKREST_EXIT": "41", "FAKE_PGBACKREST_STDERR": "ERROR: [041]: unable to open file"}, "command_failed", 41, "unable to open file"),
            ({"FAKE_PGBACKREST_FIXTURE": os.path.join(_paths.FIXTURES, "info_not_json.txt")}, "parse_failed", 0, "cannot parse"),
            ({"FAKE_PGBACKREST_FIXTURE": os.path.join(_paths.FIXTURES, "info_invalid_missing_fields_synthetic.json")}, "validation_failed", 0, "backup[0].label"),
            ({"FAKE_PGBACKREST_FIXTURE": os.path.join(_paths.FIXTURES, "info_empty_no_backups.json")}, "validation_failed", 0, "not present"),
            ({"FAKE_PGBACKREST_SLEEP": "5"}, "timeout", None, "did not finish"),
        ]
        for env, outcome, code, frag in cases:
            self.setUp()
            os.environ.update(env)
            c, st = make(timeout=1)
            c.run_cycle()
            run = st.runs()[0]
            self.assertEqual(run[4], outcome, env)
            self.assertEqual(run[3], code, env)
            self.assertIn(frag, run[5] or "", env)
            self.assertIsNone(run[6])

    def test_missing_binary(self):
        c, st = make(binary="/nonexistent/pgbackrest")
        c.run_cycle()
        self.assertEqual(st.runs()[0][4], "binary_missing")

    def test_locked_and_disabled(self):
        os.environ["FAKE_PGBACKREST_FIXTURE"] = os.path.join(_paths.FIXTURES, "info_lab_healthy.json")
        c, st = make(stanzas=("lab", "empty"))
        st.locked.add("lab")
        st.disabled.add("empty")
        out = c.run_cycle()
        self.assertEqual(out, {"lab": "skipped_locked", "empty": "disabled"})
        self.assertEqual([r[4] for r in st.runs()], ["skipped_locked"])
        self.assertIn("lab", st.locked)  # we never released a lock we did not take

    def test_one_failing_stanza_does_not_stop_others(self):
        os.environ["FAKE_PGBACKREST_FIXTURE"] = os.path.join(_paths.FIXTURES, "info_all_stanzas.json")
        c, st = make(stanzas=("lab", "nosuch", "empty"))
        out = c.run_cycle()
        self.assertEqual(out, {"lab": "success", "nosuch": "validation_failed", "empty": "success"})

    def test_db_unavailable_is_survived(self):
        os.environ["FAKE_PGBACKREST_FIXTURE"] = os.path.join(_paths.FIXTURES, "info_lab_healthy.json")
        c, st = make()
        st.fail_sample = True
        out = c.run_cycle()
        self.assertEqual(out["lab"], "success")
        self.assertTrue(any(c[0] == "record_error" and c[2] == "pg_sample_failed" for c in st.calls))

    def test_purge_cadence_and_instances(self):
        os.environ["FAKE_PGBACKREST_FIXTURE"] = os.path.join(_paths.FIXTURES, "info_lab_healthy.json")
        c, st = make(purge_every_cycles=2, pg_instance=None)
        c.run_cycle()
        self.assertNotIn(("purge_history",), st.calls)
        self.assertNotIn(("sample_pg_archiver",), st.calls)  # no stanza uses the local instance
        c.run_cycle()
        self.assertIn(("purge_history",), st.calls)

    def test_remote_instance_failure_recorded(self):
        os.environ["FAKE_PGBACKREST_FIXTURE"] = os.path.join(_paths.FIXTURES, "info_lab_healthy.json")
        c, st = make(pg_instance="sb")
        c.cfg.instances["sb"] = InstanceConfig("sb", "host=127.0.0.1 port=1 dbname=x connect_timeout=1")
        c.run_cycle()
        errs = [x for x in st.calls if x[0] == "record_error"]
        self.assertEqual(len(errs), 1)
        self.assertIn("instance sb", errs[0][3])


if __name__ == "__main__":
    unittest.main()
