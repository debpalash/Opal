#!/usr/bin/env python3
"""Deterministic checks for the measured workflow harness; no app launch."""
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch
import bench_media_workflows_live as benchmark
import test_setup_token_live as live


class WorkflowBenchmarkTest(unittest.TestCase):
    def test_percentiles_use_nearest_rank_and_keep_sample_count(self):
        self.assertEqual(benchmark.summarize(list(range(1, 21))),
                         {"samples": 20, "p50_ms": 10.5, "p95_ms": 19})
        self.assertEqual(benchmark.summarize([3, 1]),
                         {"samples": 2, "p50_ms": 2, "p95_ms": 3})

    def test_invalid_sample_counts_do_not_launch_or_write(self):
        result = subprocess.run([sys.executable, str(benchmark.Path(benchmark.__file__)),
            "--binary", "unused", "--repetitions", "1", "--results", "unused.json"],
            capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn("at least two repetitions", result.stderr)

    def test_windows_cleanup_targets_only_the_owned_process_tree(self):
        fixture = live.IsolatedOpal(self)
        self.addCleanup(fixture.stop)
        child = Mock(pid=123456)
        child.poll.return_value = None
        fixture.process = child
        with patch.object(live.os, "name", "nt"), patch.object(live.subprocess, "run") as run:
            fixture.stop_process()
        self.assertEqual(run.call_args.args[0], ["taskkill", "/PID", "123456", "/T", "/F"])
        child.wait.assert_called_once_with(timeout=3)
        self.assertIsNone(fixture.process)


if __name__ == "__main__":
    unittest.main(verbosity=2)
