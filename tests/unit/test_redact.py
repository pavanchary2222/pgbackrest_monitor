import unittest

import _paths  # noqa: F401
from pgbackrest_monitor_collector.redact import REDACTED, redact, redact_argv


class RedactTests(unittest.TestCase):
    def test_pgbackrest_secret_options(self):
        for opt in ("--repo1-s3-key=AKIAABCDEFGHIJKLMNOP", "--repo2-s3-key-secret=abc/def+ghi",
                    "--repo1-cipher-pass=hunter2", "--repo1-azure-key=xyz==", "--repo1-gcs-key=/path/key.json",
                    "--pg1-host-pass=secret", "--repo1-sftp-private-key-passphrase='p w'"):
            out = redact("cmd " + opt + " info")
            self.assertNotIn(opt.split("=", 1)[1], out, out)
            self.assertIn(REDACTED, out)

    def test_config_style_and_env(self):
        self.assertEqual(redact("repo1-cipher-pass = topsecret"), "repo1-cipher-pass = " + REDACTED)
        self.assertEqual(redact("PGPASSWORD=abc psql"), "PGPASSWORD=" + REDACTED + " psql")
        self.assertEqual(redact("host=x password=abc dbname=y"), "host=x password=" + REDACTED + " dbname=y")

    def test_url_credentials(self):
        self.assertEqual(redact("postgresql://bob:pw@db:5432/x"), "postgresql://bob:" + REDACTED + "@db:5432/x")

    def test_aws_key_ids(self):
        self.assertEqual(redact("key AKIAIOSFODNN7EXAMPLE used"), "key " + REDACTED + " used")

    def test_non_secrets_untouched(self):
        s = "ERROR: [041]: unable to open file '/etc/pgbackrest.conf' for read: [13] Permission denied"
        self.assertEqual(redact(s), s)
        self.assertIsNone(redact(None))
        self.assertEqual(redact(""), "")

    def test_argv(self):
        self.assertEqual(redact_argv(["pgbackrest", "--repo1-s3-key=K", "info"]),
                         ["pgbackrest", "--repo1-s3-key=" + REDACTED, "info"])


if __name__ == "__main__":
    unittest.main()
