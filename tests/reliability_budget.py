"""Pure percentile and regression-budget logic for the reliability workload.

No I/O, no process control: `bench_reliability_live.py` measures, this module
decides. Budgets are relative to a recorded baseline, never absolute numbers,
because timings do not transfer between machines.
"""
from __future__ import annotations

import math
import statistics

SCHEMA = 1

# Every report must measure each of these user-visible steps.
REQUIRED_STEPS = (
    "launch", "navigate", "search_cancel", "art_first", "art_repeat",
    "stream_start", "seek", "reader_page_advance", "close",
)
# Resource snapshots taken at the end of each workload phase.
REQUIRED_PHASES = ("ready", "after_navigate", "after_search", "after_stream", "after_reader", "after_soak")
RESOURCE_FIELDS = ("cpu_ms", "rss_kib", "workers", "subprocesses")
# Machine-independent invariants: any nonzero value fails, baseline or not.
INVARIANTS = ("failed_cycles", "orphan_players", "orphan_subprocesses")
MIN_SOAK_CYCLES = 100

DEFAULT_THRESHOLD = 0.5
# A regression must also exceed an absolute noise floor for its unit, so a
# 0.7 ms art hit becoming 1.2 ms does not fail a run.
NOISE_FLOORS = {"ms": 25.0, "cpu_ms": 250.0, "rss_kib": 16384.0, "workers": 4.0, "subprocesses": 2.0}


def percentile(values, q):
    """Nearest-rank percentile (q in (0, 100]); the sample is always observed."""
    if not values:
        raise ValueError("percentile of an empty sample")
    if not 0 < q <= 100:
        raise ValueError("percentile must be in (0, 100]")
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * q / 100) - 1)]


def summarize(values):
    """p50 is the median (interpolated for even counts); p95 is nearest-rank."""
    return {"samples": len(values), "p50_ms": round(statistics.median(values), 3),
            "p95_ms": round(percentile(values, 95), 3)}


def metrics(report):
    """Flatten a report into {name: (value, unit)} for budget comparison."""
    out = {}
    for step, summary in report.get("latency_ms", {}).items():
        for key in ("p50_ms", "p95_ms"):
            if key in summary:
                out[f"latency.{step}.{key}"] = (float(summary[key]), "ms")
    for phase, snapshot in report.get("resources", {}).items():
        for field in RESOURCE_FIELDS:
            if snapshot.get(field) is not None:
                out[f"resources.{phase}.{field}"] = (float(snapshot[field]), field)
    return out


def compare(baseline, current, threshold=DEFAULT_THRESHOLD, floors=None):
    """Return regressions of `current` against `baseline`; lower is better.

    A metric regresses when it exceeds baseline * (1 + threshold) AND the
    increase exceeds the unit's noise floor. A metric present in the baseline
    but missing from the current report is a regression: dropping a
    measurement must not pass the gate. Invariants fail on any nonzero value.
    """
    if threshold < 0:
        raise ValueError("threshold must be non-negative")
    floors = {**NOISE_FLOORS, **(floors or {})}
    base, cur = metrics(baseline), metrics(current)
    regressions = []
    for name, (before, unit) in sorted(base.items()):
        if name not in cur:
            regressions.append({"metric": name, "baseline": before, "current": None, "reason": "missing"})
            continue
        after = cur[name][0]
        if after > before * (1 + threshold) and after - before > floors.get(unit, 0.0):
            regressions.append({"metric": name, "baseline": before, "current": after,
                                "reason": f"+{(after - before):.3f} {unit} exceeds {threshold:.0%} budget"})
    soak = current.get("soak", {})
    for name in INVARIANTS:
        value = soak.get(name)
        if value is None:
            regressions.append({"metric": f"soak.{name}", "baseline": 0, "current": None, "reason": "missing"})
        elif value:
            regressions.append({"metric": f"soak.{name}", "baseline": 0, "current": value, "reason": "invariant must be 0"})
    if soak.get("clean_exit") is not True:
        regressions.append({"metric": "soak.clean_exit", "baseline": True, "current": soak.get("clean_exit"),
                            "reason": "Opal must exit on SIGTERM without a kill"})
    return regressions


def validate(report):
    """Return a list of schema problems; empty means the report is complete."""
    problems = []
    if report.get("schema") != SCHEMA:
        problems.append(f"schema must be {SCHEMA}")
    latency = report.get("latency_ms", {})
    for step in REQUIRED_STEPS:
        summary = latency.get(step)
        if not summary:
            problems.append(f"missing latency step {step}")
            continue
        if summary.get("samples", 0) < 2:
            problems.append(f"{step} needs at least two samples")
        if not 0 <= summary.get("p50_ms", -1) <= summary.get("p95_ms", -1):
            problems.append(f"{step} needs 0 <= p50 <= p95")
    resources = report.get("resources", {})
    for phase in REQUIRED_PHASES:
        snapshot = resources.get(phase)
        if snapshot is None:
            problems.append(f"missing resource phase {phase}")
            continue
        for field in RESOURCE_FIELDS:
            if not isinstance(snapshot.get(field), (int, float)):
                problems.append(f"{phase}.{field} must be numeric")
    soak = report.get("soak", {})
    if soak.get("cycles", 0) < MIN_SOAK_CYCLES:
        problems.append(f"soak needs at least {MIN_SOAK_CYCLES} cycles")
    for name in (*INVARIANTS, "clean_exit"):
        if name not in soak:
            problems.append(f"soak.{name} missing")
    return problems


def orphans(before, after):
    """Descendant PIDs present after close that were not present before play."""
    return sorted(set(after) - set(before))
