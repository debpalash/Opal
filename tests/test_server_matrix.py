#!/usr/bin/env python3
"""Deterministic checks for the independent-server matrix and doc claims; no app launch."""
import copy
import json
from pathlib import Path
import unittest

import server_matrix as sm

ROOT = Path(__file__).resolve().parents[1]
MATRIX = json.loads((ROOT / sm.MATRIX_PATH).read_text(encoding="utf-8"))


class MatrixShapeTest(unittest.TestCase):
    def test_shipped_matrix_validates(self):
        self.assertEqual(sm.validate(MATRIX), [])

    def test_every_capability_and_environment_is_required(self):
        broken = copy.deepcopy(MATRIX)
        broken["capabilities"] = [c for c in broken["capabilities"] if c["id"] != "backup_restore"]
        del broken["capabilities"][0]["cells"]["nas_class"]
        problems = sm.validate(broken)
        self.assertIn("capability backup_restore missing", problems)
        self.assertIn("library_imports.nas_class missing", problems)

    def test_verified_needs_evidence_and_unverified_cites_none(self):
        broken = copy.deepcopy(MATRIX)
        cells = broken["capabilities"][0]["cells"]
        cells["workstation"]["evidence"] = []
        cells["nas_class"]["evidence"] = [{"test": "tests/x.py::A::b", "suite": "ci"}]
        cells["nas_class"]["status"] = "unverified"
        broken["capabilities"][1]["cells"]["workstation"]["status"] = "works"
        problems = sm.validate(broken)
        self.assertIn("library_imports.workstation: verified needs evidence", problems)
        self.assertIn("library_imports.nas_class: unverified cannot cite evidence", problems)
        self.assertTrue(any("status 'works'" in p for p in problems))


class EvidenceTest(unittest.TestCase):
    def test_locators_by_kind(self):
        self.assertTrue(sm.locate("src/a.zig::adds", 'test "adds" {'))
        self.assertFalse(sm.locate("src/a.zig::adds", 'test "adds two" {'))
        self.assertTrue(sm.locate("tests/features/t.py::Name here", '@test("Name here", "Cat")'))
        self.assertTrue(sm.locate("tests/t.py::Case::test_x", "class Case(unittest.TestCase):\n    def test_x(self):"))
        self.assertFalse(sm.locate("tests/t.py::Case::test_x", "class Case(unittest.TestCase):\n    def test_y(self):"))
        self.assertFalse(sm.locate("tests/t.py::Case", "class Case(unittest.TestCase):"))

    def test_suite_labels_must_match_ci_reachability(self):
        build = 'b.path("src/a_pure.zig")'
        flows = "run: zig build test\nrun: python3 tests/test_features.py\nrun: python3 tests/test_live.py"
        self.assertIsNone(sm.suite_problem("src/a_pure.zig::t", "ci", build, flows))
        self.assertIn("no workflow", sm.suite_problem("src/b.zig::t", "ci", build, flows))
        self.assertIsNone(sm.suite_problem("tests/features/x.py::t", "ci", build, flows))
        self.assertIsNone(sm.suite_problem("tests/test_live.py::A::b", "ci", build, flows))
        self.assertIsNone(sm.suite_problem("tests/test_other_live.py::A::b", "opt-in", build, flows))
        self.assertIn("relabel", sm.suite_problem("tests/test_live.py::A::b", "real-provider", build, flows))


class DocClaimTest(unittest.TestCase):
    def test_rendered_table_reports_status_and_suite(self):
        table = sm.render(MATRIX)
        self.assertIn("| Backup/restore | unverified | unverified |", table)
        self.assertIn("| Multiple users | verified (ci) | unverified |", table)

    def test_doc_table_extraction(self):
        self.assertIsNone(sm.doc_table("no markers"))
        self.assertEqual(sm.doc_table(f"a\n{sm.BEGIN}\n| x |\n{sm.END}\nb"), "| x |")

    def test_replacement_claims_are_flagged_unless_scoped(self):
        text = ("Opal replaces Jellyfin on your NAS.\n"
                "A Plex/Jellyfin alternative in one binary.\n"
                "It connects to Plex and Jellyfin servers rather than replacing them.\n"
                "This is not a drop-in Plex replacement.\n"
                "Plays Jellyfin libraries.\n")
        self.assertEqual([n for n, _ in sm.overclaims(text, MATRIX)], [1, 2])

    def test_claims_allowed_once_every_workstation_cell_is_verified(self):
        upgraded = copy.deepcopy(MATRIX)
        for cap in upgraded["capabilities"]:
            cap["cells"]["workstation"]["status"] = "verified"
        self.assertEqual(sm.overclaims("Opal replaces Jellyfin.", upgraded), [])

    def test_repository_docs_match_the_matrix(self):
        self.assertEqual(sm.check_repo(ROOT), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
