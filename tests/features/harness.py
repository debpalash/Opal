#!/usr/bin/env python3
"""
Shared test harness for the Opal feature suite.

Owns the @test decorator + registry, the TestResult record, the cross-module
helpers (get_db / _src / _between / _parse_catalog / _EMOJI), the shared
constants, and run_all() (console summary + tests/results.json writer).

Per-category test modules live alongside this file (test_*.py); each does
`from .harness import *` and defines its @test functions. The decorator appends
each test into REGISTRY, so discovery is module-independent (it does NOT rely on
globals() the way the pre-split single file did). run_all() iterates REGISTRY.

results.json path + schema are kept byte-for-byte compatible with the previous
single-file suite (tests/dashboard.html reads it).
"""

import sqlite3
import subprocess
import os
import json
import time
import socket
import sys
import re as _re

# Windows consoles default to cp1252, which can't encode the ✅/❌ status glyphs
# this harness prints (UnicodeEncodeError mid-run). Force UTF-8 output so the
# suite runs on Windows too; CI's Linux/macOS already default to UTF-8.
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

# harness.py lives at tests/features/harness.py → three dirnames to the repo root.
DB_PATH = os.path.expanduser("~/.config/opal/opal.db")
PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RESULTS_FILE = os.path.join(PROJECT_DIR, "tests", "results.json")

__all__ = [
    "test", "TestResult", "results", "REGISTRY", "run_all",
    "get_db", "_src", "_web_app", "_web_js", "_remote_api", "_between", "_parse_catalog",
    "DB_PATH", "PROJECT_DIR", "RESULTS_FILE", "_EMOJI", "_re",
]


class TestResult:
    def __init__(self, name, category, status, detail="", duration_ms=0):
        self.name = name
        self.category = category
        self.status = status  # "pass", "fail", "skip", "warn"
        self.detail = detail
        self.duration_ms = duration_ms

    def to_dict(self):
        return {
            "name": self.name,
            "category": self.category,
            "status": self.status,
            "detail": self.detail,
            "duration_ms": self.duration_ms
        }


results = []

# Every @test-decorated wrapper appends itself here at import time; run_all()
# runs them in registration order (was globals()-discovery in the single file).
REGISTRY = []


def test(name, category):
    """Decorator for test functions"""
    def decorator(fn):
        def wrapper():
            t0 = time.time()
            try:
                status, detail = fn()
                dt = int((time.time() - t0) * 1000)
                results.append(TestResult(name, category, status, detail, dt))
            except Exception as e:
                dt = int((time.time() - t0) * 1000)
                results.append(TestResult(name, category, "fail", str(e), dt))
        wrapper._test = True
        wrapper._name = name
        REGISTRY.append(wrapper)
        return wrapper
    return decorator


# ══════════════════════════════════════════════════════════
# Shared helpers (used across multiple category modules)
# ══════════════════════════════════════════════════════════

def get_db():
    if not os.path.exists(DB_PATH):
        return None
    return sqlite3.connect(DB_PATH)


def _src(rel):
    p = os.path.join(PROJECT_DIR, rel)
    return open(p).read() if os.path.exists(p) else ""


def _web_js():
    """The ordered browser bundle as served by web/index.html."""
    names = (
        "core.js", "now-playing.js", "catalog.js", "playback.js", "integrations.js",
        "media.js", "discovery.js", "boot.js",
    )
    return "\n".join(_src(f"web/js/{name}") for name in names)


def _web_app():
    """Web feature source across markup, styles, and ordered JS bundles."""
    return "\n".join((_src("web/index.html"), _src("web/styles/app.css"), _web_js()))


def _remote_api():
    """Remote HTTP subsystem across its feature-owned modules."""
    names = (
        "remote.zig", "remote_http.zig", "remote_static.zig",
        "remote_status.zig", "remote_library_api.zig", "remote_transfer_api.zig",
    )
    return "\n".join(_src(f"src/services/{name}") for name in names)


def _between(src, start, end):
    i = src.find(start)
    if i < 0:
        return ""
    j = src.find(end, i + len(start))
    return src[i:j if j > 0 else len(src)]


def _parse_catalog():
    """Extract MODEL_CATALOG entries from ai_server.zig as dicts."""
    import re
    src = os.path.join(PROJECT_DIR, "src/services/ai_server.zig")
    with open(src) as f:
        content = f.read()
    start = content.find("MODEL_CATALOG")
    if start < 0:
        return []
    block = content[start:content.find("};", start)]
    entries = []
    for m in re.finditer(r"\.\{(.*?)\}", block, re.DOTALL):
        body = m.group(1)
        fields = dict(re.findall(r'\.(\w+)\s*=\s*"([^"]*)"', body))
        if "id" in fields and "url" in fields:
            entries.append(fields)
    return entries


# Pictographic emoji + dingbats/symbols (NOT typographic arrows/middot/stars).
_EMOJI = _re.compile(
    "[\U0001F000-\U0001FAFF\U00002600-\U000027BF\U00002B00-\U00002BFF"
    "\U000023E9-\U000023FA\U0000FE0F]"
)


# ══════════════════════════════════════════════════════════
# Run All Tests
# ══════════════════════════════════════════════════════════

def run_all():
    test_fns = list(REGISTRY)

    print(f"\n{'='*60}")
    print(f"  ZigZag Feature Test Suite — {len(test_fns)} tests")
    print(f"{'='*60}\n")

    for fn in test_fns:
        fn()

    # Summary
    cats = {}
    for r in results:
        if r.category not in cats:
            cats[r.category] = {"pass": 0, "fail": 0, "warn": 0, "skip": 0}
        cats[r.category][r.status] += 1

    total_pass = sum(c["pass"] for c in cats.values())
    total_fail = sum(c["fail"] for c in cats.values())
    total_warn = sum(c["warn"] for c in cats.values())
    total_skip = sum(c["skip"] for c in cats.values())

    for r in results:
        icon = {"pass": "✅", "fail": "❌", "warn": "⚠️", "skip": "⏭️"}[r.status]
        print(f"  {icon} [{r.category:12s}] {r.name:35s} {r.detail[:50]:50s} {r.duration_ms:4d}ms")

    print(f"\n{'─'*60}")
    print(f"  ✅ {total_pass} passed  ❌ {total_fail} failed  ⚠️ {total_warn} warnings  ⏭️ {total_skip} skipped")
    print(f"{'─'*60}\n")

    # Write JSON for web dashboard
    output = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "total": len(results),
        "passed": total_pass,
        "failed": total_fail,
        "warnings": total_warn,
        "skipped": total_skip,
        "categories": {cat: counts for cat, counts in cats.items()},
        "tests": [r.to_dict() for r in results]
    }

    with open(RESULTS_FILE, "w") as f:
        json.dump(output, f, indent=2)
    print(f"  Results written to {RESULTS_FILE}")

    return total_fail == 0
