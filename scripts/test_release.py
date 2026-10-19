"""Tests for scripts/release.py (versions, linked issues, merge rules):  python3 -m unittest discover -s scripts -p 'test_*.py'"""
import unittest

from release import ci_state, latest_version, linked_issues, next_version, parse_version, review_notes, tag_name


def pr(**kw):
    base = {"number": 7, "author": {"login": "Melf11"}, "isDraft": False, "mergeable": "MERGEABLE",
            "isCrossRepository": False, "files": [{"path": "Sources/SixAxis/App.swift"}],
            "statusCheckRollup": [{"status": "COMPLETED", "conclusion": "SUCCESS"}]}
    base.update(kw)
    return base


class Versions(unittest.TestCase):
    def test_next_version(self):
        tags = ["v1.2.0", "v2.0.2", "v2.0.10-beta.1", "v2.0.1", "nonsense"]
        current = latest_version(tags)
        self.assertEqual(current, (2, 0, 2))
        self.assertEqual(tag_name(next_version(current, "patch")), "v2.0.3")
        self.assertEqual(tag_name(next_version(current, "minor")), "v2.1.0")
        self.assertEqual(tag_name(next_version(current, "major")), "v3.0.0")
        self.assertIsNone(parse_version("2.0.3"))
        self.assertIsNone(parse_version("v2.0"))

    def test_linked_issues(self):
        self.assertEqual(linked_issues("Fixes #12\n", "closes #3, see #99", "Resolved #12"), [3, 12])


class MergeRules(unittest.TestCase):
    def test_green_pr_from_owner_has_no_notes(self):
        self.assertEqual(review_notes(pr(), "Melf11"), ([], []))

    def test_blockers(self):
        red = [{"status": "COMPLETED", "conclusion": "FAILURE"}]
        self.assertIn("CI ist rot", review_notes(pr(statusCheckRollup=red), "Melf11")[0])
        self.assertTrue(review_notes(pr(mergeable="CONFLICTING"), "Melf11")[0])
        self.assertTrue(review_notes(pr(isDraft=True), "Melf11")[0])

    def test_warnings(self):
        _, w = review_notes(pr(author={"login": "fremd"}, isCrossRepository=True,
                               files=[{"path": ".github/workflows/release.yml"}]), "Melf11")
        self.assertEqual(len(w), 3)

    def test_ci_state(self):
        self.assertEqual(ci_state([]), "keine")
        self.assertEqual(ci_state([{"status": "IN_PROGRESS", "conclusion": ""}]), "läuft")
        self.assertEqual(ci_state([{"state": "PENDING"}]), "läuft")
        self.assertEqual(ci_state([{"status": "COMPLETED", "conclusion": "SKIPPED"}, {"state": "SUCCESS"}]), "ok")


if __name__ == "__main__":
    unittest.main()
