import json
import unittest

import _paths
from pgbackrest_monitor_collector.parser import ParseError, ValidationError, parse_info_output, summarize, validate_info


class ParserTests(unittest.TestCase):
    def load(self, name, stanza):
        return validate_info(parse_info_output(_paths.fixture(name)), stanza)

    def test_real_fixtures_validate(self):
        for name, stanza in (("info_lab_healthy.json", "lab"), ("info_empty_no_backups.json", "empty"),
                             ("info_missing_stanza.json", "doesnotexist"), ("info_broken_repo.json", "broken"),
                             ("info_lab_repo_permission_denied.json", "lab"), ("info_lab_backup_running.json", "lab"),
                             ("info_lab_repo1_only.json", "lab"), ("info_lab_set_detail.json", "lab"),
                             ("info_all_stanzas.json", "lab"), ("info_all_stanzas.json", "empty")):
            elem = self.load(name, stanza)
            self.assertEqual(elem["name"], stanza)

    def test_synthetic_valid_fixtures(self):
        legacy = self.load("info_legacy_single_repo_synthetic.json", "lab")
        self.assertNotIn("repo", legacy)
        self.assertNotIn("repo-key", legacy["backup"][0]["database"])
        err = self.load("info_lab_backup_error_synthetic.json", "lab")
        self.assertTrue(any(b.get("error") is True for b in err["backup"]))
        prog = self.load("info_lab_backup_running_progress_synthetic.json", "lab")
        self.assertEqual(prog["status"]["lock"]["backup"]["pct-cplt"], 4200)

    def test_summary(self):
        s = summarize(self.load("info_lab_backup_running.json", "lab"))
        self.assertIn("backup/expire running", s)
        self.assertIn("backups=", s)

    def test_not_json(self):
        with self.assertRaises(ParseError) as cm:
            parse_info_output(_paths.fixture("info_not_json.txt"))
        self.assertIn("invalid JSON", str(cm.exception))
        with self.assertRaises(ParseError):
            parse_info_output("")
        with self.assertRaises(ParseError):
            parse_info_output(_paths.fixture("info_config_unreadable.stdout.txt"))

    def test_parse_error_redacts_snippet(self):
        with self.assertRaises(ParseError) as cm:
            parse_info_output("ERROR: --repo1-s3-key=SECRETVALUE bad")
        self.assertNotIn("SECRETVALUE", str(cm.exception))

    def test_missing_stanza(self):
        with self.assertRaises(ValidationError) as cm:
            self.load("info_lab_healthy.json", "other")
        self.assertIn("not present", str(cm.exception))
        self.assertIn("'lab'", str(cm.exception))

    def test_top_level_not_array(self):
        with self.assertRaises(ValidationError):
            validate_info({"name": "lab"}, "lab")

    def test_missing_fields(self):
        with self.assertRaises(ValidationError) as cm:
            self.load("info_invalid_missing_fields_synthetic.json", "lab")
        probs = cm.exception.problems
        self.assertTrue(any("backup[0].label" in p for p in probs), probs)
        self.assertTrue(any("backup[1].timestamp" in p for p in probs), probs)
        with self.assertRaises(ValidationError) as cm:
            self.load("info_invalid_no_status_code_synthetic.json", "lab")
        self.assertTrue(any("status.code" in p for p in cm.exception.problems))

    def test_wrong_types(self):
        doc = json.loads(_paths.fixture("info_lab_healthy.json"))
        doc[0]["backup"][0]["type"] = "weekly"
        doc[0]["repo"][0]["key"] = "1"
        doc[0]["status"]["lock"]["backup"]["held"] = "yes"
        doc[0]["archive"][0]["max"] = 7
        with self.assertRaises(ValidationError) as cm:
            validate_info(doc, "lab")
        probs = " ".join(cm.exception.problems)
        for frag in ("backup[0].type", "repo[0].key", "lock.backup.held", "archive[0].max"):
            self.assertIn(frag, probs)


if __name__ == "__main__":
    unittest.main()
