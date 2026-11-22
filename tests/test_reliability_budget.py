#!/usr/bin/env python3
"""Deterministic checks for reliability percentiles, budgets and the baseline; no app launch."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import bench_media_workflows_live
import bench_reliability_live
import reliability_budget as budget

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / "docs/benchmarks/reliability-baseline.json"
SCRIPT = Path(bench_reliability_live.__file__)


def report(scale=1.0, **soak):
    latency = {step: {"samples": 20, "p50_ms": 100.0 * scale, "p95_ms": 200.0 * scale} for step in budget.REQUIRED_STEPS}
    resources = {phase: {"cpu_ms": 1000.0 * scale, "rss_kib": 80000 * scale, "workers": 20 * scale, "subprocesses": 0}
                 for phase in budget.REQUIRED_PHASES}
    base = {"cycles": 300, "failed_cycles": 0, "orphan_players": 0, "orphan_subprocesses": 0, "clean_exit": True}
    return {"schema": budget.SCHEMA, "latency_ms": latency, "resources": resources, "soak": {**base, **soak}}


class PercentileTest(unittest.TestCase):
    def test_nearest_rank_percentile(self):
        self.assertEqual(budget.percentile(list(range(1, 21)), 95), 19)
        self.assertEqual(budget.percentile([5], 95), 5)
        self.assertEqual(budget.percentile([3, 1, 2], 100), 3)
        self.assertEqual(budget.percentile([4, 1, 3, 2], 50), 2)

    def test_percentile_rejects_empty_and_out_of_range(self):
        with self.assertRaises(ValueError):
            budget.percentile([], 50)
        for q in (0, -1, 101):
            with self.assertRaises(ValueError):
                budget.percentile([1, 2], q)

    def test_summarize_is_shared_with_the_workflow_benchmark(self):
        self.assertIs(bench_media_workflows_live.summarize, budget.summarize)
        self.assertEqual(budget.summarize([3, 1]), {"samples": 2, "p50_ms": 2, "p95_ms": 3})


class BudgetTest(unittest.TestCase):
    def test_identical_report_passes(self):
        self.assertEqual(budget.compare(report(), report()), [])

    def test_within_relative_threshold_passes(self):
        self.assertEqual(budget.compare(report(), report(scale=1.45)), [])

    def test_relative_regression_beyond_threshold_fails(self):
        names = {r["metric"] for r in budget.compare(report(), report(scale=2.0))}
        self.assertIn("latency.stream_start.p95_ms", names)
        self.assertIn("resources.after_soak.rss_kib", names)
        self.assertIn("resources.ready.workers", names)

    def test_threshold_is_configurable(self):
        self.assertEqual(budget.compare(report(), report(scale=2.0), threshold=1.5), [])
        with self.assertRaises(ValueError):
            budget.compare(report(), report(), threshold=-0.1)

    def test_noise_floor_ignores_tiny_absolute_changes(self):
        base, cur = report(), report()
        base["latency_ms"]["art_repeat"] = {"samples": 20, "p50_ms": 0.7, "p95_ms": 0.9}
        cur["latency_ms"]["art_repeat"] = {"samples": 20, "p50_ms": 1.4, "p95_ms": 9.0}
        self.assertEqual(budget.compare(base, cur), [])
        cur["latency_ms"]["art_repeat"]["p95_ms"] = 40.0
        self.assertEqual([r["metric"] for r in budget.compare(base, cur)], ["latency.art_repeat.p95_ms"])

    def test_subprocess_growth_from_zero_fails_past_two(self):
        cur = report()
        cur["resources"]["after_soak"]["subprocesses"] = 2
        self.assertEqual(budget.compare(report(), cur), [])
        cur["resources"]["after_soak"]["subprocesses"] = 3
        self.assertEqual([r["metric"] for r in budget.compare(report(), cur)], ["resources.after_soak.subprocesses"])

    def test_dropped_measurement_is_a_regression(self):
        cur = report()
        del cur["latency_ms"]["reader_page_advance"]
        reasons = {r["metric"]: r["reason"] for r in budget.compare(report(), cur)}
        self.assertEqual(reasons["latency.reader_page_advance.p50_ms"], "missing")

    def test_invariants_fail_without_any_baseline(self):
        for field in ("failed_cycles", "orphan_players", "orphan_subprocesses"):
            names = [r["metric"] for r in budget.compare({}, report(**{field: 1}))]
            self.assertEqual(names, [f"soak.{field}"])
        self.assertEqual([r["metric"] for r in budget.compare({}, report(clean_exit=False))], ["soak.clean_exit"])

    def test_orphans_are_new_descendants_only(self):
        self.assertEqual(budget.orphans({10: "a", 11: "b"}, {11: "b", 12: "c", 9: "d"}), [9, 12])
        self.assertEqual(budget.orphans({10: "a"}, {}), [])


class ValidateTest(unittest.TestCase):
    def test_complete_report_validates(self):
        self.assertEqual(budget.validate(report()), [])

    def test_missing_steps_phases_and_short_soak_are_reported(self):
        bad = report(cycles=50)
        del bad["latency_ms"]["search_cancel"]
        del bad["resources"]["after_reader"]
        bad["latency_ms"]["seek"] = {"samples": 1, "p50_ms": 5, "p95_ms": 3}
        problems = budget.validate(bad)
        for needle in ("search_cancel", "after_reader", "seek needs at least two", "seek needs 0 <= p50", "100 cycles"):
            self.assertTrue(any(needle in p for p in problems), (needle, problems))


class BaselineTest(unittest.TestCase):
    def test_recorded_baseline_is_complete_and_clean(self):
        baseline = json.loads(BASELINE.read_text())
        self.assertEqual(budget.validate(baseline), [])
        self.assertEqual(budget.compare(baseline, baseline), [])
        self.assertGreaterEqual(baseline["soak"]["cycles"], 300)

    def test_check_mode_gates_a_regressed_report_without_launching(self):
        baseline = json.loads(BASELINE.read_text())
        regressed = copy.deepcopy(baseline)
        regressed["latency_ms"]["stream_start"]["p95_ms"] = baseline["latency_ms"]["stream_start"]["p95_ms"] * 3 + 100
        with tempfile.TemporaryDirectory() as temporary:
            same, worse = Path(temporary, "same.json"), Path(temporary, "worse.json")
            same.write_text(json.dumps(baseline))
            worse.write_text(json.dumps(regressed))
            run = lambda path: subprocess.run([sys.executable, str(SCRIPT), "--check", str(path), "--baseline", str(BASELINE)],
                                              capture_output=True, text=True, timeout=20)
            self.assertEqual(run(same).returncode, 0)
            result = run(worse)
            self.assertEqual(result.returncode, 1)
            self.assertIn("REGRESSION: latency.stream_start.p95_ms", result.stderr)

    def test_live_mode_rejects_short_runs_before_launching(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--binary", "unused", "--results", "unused.json",
                                 "--soak-cycles", "10"], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 2)
        self.assertIn("soak cycles", result.stderr)
        self.assertFalse(Path("unused.json").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
