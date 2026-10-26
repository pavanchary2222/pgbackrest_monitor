import os
import unittest

import _paths
from pgbackrest_monitor_collector.runner import pgbackrest_version, run_command

FAKE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fake_pgbackrest.py")


class RunnerTests(unittest.TestCase):
    def setUp(self):
        for k in list(os.environ):
            if k.startswith("FAKE_PGBACKREST_"):
                del os.environ[k]

    def test_success(self):
        os.environ["FAKE_PGBACKREST_FIXTURE"] = os.path.join(_paths.FIXTURES, "info_lab_healthy.json")
        r = run_command([FAKE, "--stanza=lab", "--output=json", "info"], 10)
        self.assertTrue(r.ok)
        self.assertEqual(r.exit_code, 0)
        self.assertIn('"name":"lab"', r.stdout)
        self.assertIsNone(r.error)
        self.assertGreaterEqual(r.finished_at, r.started_at)

    def test_nonzero_exit_redacted(self):
        os.environ["FAKE_PGBACKREST_EXIT"] = "41"
        os.environ["FAKE_PGBACKREST_STDERR"] = "ERROR: [041]: option --repo1-s3-key=SECRET123 unable to open"
        r = run_command([FAKE, "info"], 10)
        self.assertEqual(r.status, "completed")
        self.assertEqual(r.exit_code, 41)
        self.assertIn("exited with code 41", r.error)
        self.assertNotIn("SECRET123", r.error)

    def test_timeout(self):
        os.environ["FAKE_PGBACKREST_SLEEP"] = "5"
        r = run_command([FAKE, "info"], 1)
        self.assertEqual(r.status, "timeout")
        self.assertIsNone(r.exit_code)
        self.assertIn("did not finish within 1s", r.error)

    def test_missing_binary(self):
        r = run_command(["/nonexistent/pgbackrest", "info"], 5)
        self.assertEqual(r.status, "binary_missing")
        self.assertIn("not found", r.error)

    def test_permission_denied(self):
        r = run_command(["/etc/hostname", "info"], 5)  # exists, not executable
        self.assertEqual(r.status, "permission_denied")

    def test_version(self):
        self.assertEqual(pgbackrest_version(FAKE), "9.99.0")
        self.assertIsNone(pgbackrest_version("/nonexistent/pgbackrest"))


if __name__ == "__main__":
    unittest.main()
