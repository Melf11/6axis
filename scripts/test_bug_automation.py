"""Tests for scripts/bug_automation.py:  python3 -m unittest discover -s scripts -p 'test_*.py'"""
import unittest

from bug_automation import decide, load_config

CONFIG = load_config("""
# comment
reporters:
  - Melf11
  - freund-a   # trailing comment
autofix:
  - Melf11
max_fixes_per_night: 3
""")


def issue(author, labels=(), pr=False):
    d = {"user": {"login": author}, "labels": [{"name": l} for l in labels]}
    if pr:
        d["pull_request"] = {}
    return d


def labeled(by, name="freigegeben"):
    return {"event": "labeled", "actor": {"login": by}, "label": {"name": name}}


class Decide(unittest.TestCase):
    def test_config(self):
        self.assertEqual(CONFIG["reporters"], ["Melf11", "freund-a"])
        self.assertEqual(CONFIG["autofix"], ["Melf11"])
        self.assertEqual(CONFIG["max_fixes_per_night"], 3)

    def test_owner_in_autofix(self):
        r = decide(issue("melf11"), [], CONFIG, "Melf11")
        self.assertTrue(r["autofix"])
        self.assertTrue(r["reporter"])

    def test_reporter_without_autofix_waits(self):
        r = decide(issue("freund-a"), [], CONFIG, "Melf11")
        self.assertTrue(r["reporter"])
        self.assertFalse(r["autofix"])

    def test_approval_only_by_owner(self):
        self.assertTrue(decide(issue("stranger", ["freigegeben"]), [labeled("Melf11")], CONFIG, "Melf11")["autofix"])
        self.assertFalse(decide(issue("stranger", ["freigegeben"]), [labeled("stranger")], CONFIG, "Melf11")["autofix"])
        self.assertFalse(decide(issue("stranger", ["freigegeben"]), [], CONFIG, "Melf11")["autofix"])

    def test_stranger_and_pull_requests(self):
        self.assertFalse(decide(issue("stranger"), [], CONFIG, "Melf11")["autofix"])
        self.assertFalse(decide(issue("Melf11", pr=True), [], CONFIG, "Melf11")["autofix"])

    def test_label_name_must_match(self):
        self.assertFalse(decide(issue("x", ["freigegeben"]), [labeled("Melf11", "bereit")], CONFIG, "Melf11")["autofix"])


if __name__ == "__main__":
    unittest.main()
