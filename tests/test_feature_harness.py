#!/usr/bin/env python3
"""Behavioral tests for safe, repeatable feature-suite execution."""
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from features import harness


class FeatureHarnessTest(unittest.TestCase):
    def test_help_does_not_run_checks_or_write_report(self):
        with tempfile.TemporaryDirectory(prefix="opal-harness-") as root:
            report = Path(root) / "report.json"
            proc = subprocess.run(
                [sys.executable, str(Path(__file__).with_name("test_features.py")), "--help"],
                env={**os.environ, "OPAL_TEST_RESULTS": str(report)},
                capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("--database", proc.stdout)
            self.assertNotIn("Results written", proc.stdout)
            self.assertFalse(report.exists())

    def test_explicit_database_and_xdg_paths(self):
        with patch.dict(os.environ, {"OPAL_TEST_DB": "/tmp/fixture.db", "XDG_CONFIG_HOME": "/tmp/other"}):
            self.assertEqual(harness.database_path(), os.path.abspath("/tmp/fixture.db"))
        with patch.dict(os.environ, {"OPAL_TEST_DB": "", "XDG_CONFIG_HOME": "/tmp/fixture-config"}):
            self.assertEqual(harness.database_path(), os.path.join("/tmp/fixture-config", "opal", "opal.db"))

    def test_database_is_read_only_and_uri_path_is_escaped(self):
        with tempfile.TemporaryDirectory(prefix="opal-harness-") as root:
            # `?` is a useful URI edge on POSIX but is not a legal Windows
            # filename. Space + `#` still prove path-to-URI escaping on every OS.
            db_path = Path(root) / "fixture # library.db"
            db = sqlite3.connect(db_path)
            try:
                db.execute("CREATE TABLE marker(value TEXT)")
                db.execute("INSERT INTO marker VALUES ('unchanged')")
                db.commit()
            finally:
                db.close()
            with patch.object(harness, "DB_PATH", str(db_path)):
                db = harness.get_db()
                try:
                    self.assertEqual(db.execute("SELECT value FROM marker").fetchone(), ("unchanged",))
                    with self.assertRaises(sqlite3.OperationalError):
                        db.execute("DELETE FROM marker")
                    with self.assertRaises(sqlite3.OperationalError):
                        db.execute("CREATE TABLE injected(value TEXT)")
                finally:
                    db.close()

    def test_missing_database_is_not_created(self):
        with tempfile.TemporaryDirectory(prefix="opal-harness-") as root:
            db_path = Path(root) / "missing.db"
            with patch.object(harness, "DB_PATH", str(db_path)):
                self.assertIsNone(harness.get_db())
            self.assertFalse(db_path.exists())

    def test_repeated_runs_have_fresh_results_and_failure_exit_status(self):
        with tempfile.TemporaryDirectory(prefix="opal-harness-") as root:
            report = Path(root) / "report.json"
            def passing():
                harness.results.append(harness.TestResult("fixture", "Harness", "pass"))
            def failing():
                harness.results.append(harness.TestResult("fixture", "Harness", "fail"))
            with patch.object(harness, "REGISTRY", [passing]), patch.object(harness, "results", []), \
                    patch.object(harness, "RESULTS_FILE", str(report)), redirect_stdout(io.StringIO()):
                self.assertTrue(harness.run_all())
                self.assertTrue(harness.run_all())
                self.assertEqual(json.loads(report.read_text())["total"], 1)
                harness.REGISTRY[:] = [failing]
                self.assertFalse(harness.run_all())
                data = json.loads(report.read_text())
                self.assertEqual((data["total"], data["passed"], data["failed"]), (1, 0, 1))


if __name__ == "__main__":
    unittest.main(verbosity=2)
