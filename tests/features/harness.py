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
import shutil
from pathlib import Path

# Windows consoles default to cp1252, which can't encode the ✅/❌ status glyphs
# this harness prints (UnicodeEncodeError mid-run). Force UTF-8 output so the
# suite runs on Windows too; CI's Linux/macOS already default to UTF-8.
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

# harness.py lives at tests/features/harness.py → three dirnames to the repo root.
def database_path():
    """Allow deterministic fixtures without reading a developer's library."""
    explicit = os.environ.get("OPAL_TEST_DB")
    if explicit:
        return os.path.abspath(os.path.expanduser(explicit))
    config = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(config, "opal", "opal.db")


DB_PATH = database_path()
PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RESULTS_FILE = os.environ.get("OPAL_TEST_RESULTS") or os.path.join(PROJECT_DIR, "tests", "results.json")


def _create_isolated_db_fixture():
    """Materialize a disposable DB when --database names a missing file.

    The feature suite must never open or seed a user's profile.  An explicit
    OPAL_TEST_DB is different: it is a caller-owned fixture, so derive its
    tables from the Zig schema and seed only deterministic test values.
    """
    if not os.environ.get("OPAL_TEST_DB") or os.path.exists(DB_PATH):
        return

    db_source = Path(PROJECT_DIR, "src", "core", "db.zig").read_text(encoding="utf-8")
    statements = []
    lines = db_source.splitlines()
    i = 0
    while i < len(lines):
        stripped = lines[i].strip()
        if stripped.startswith("\\\\CREATE TABLE IF NOT EXISTS") or stripped.startswith("\\\\CREATE VIRTUAL TABLE IF NOT EXISTS"):
            sql_lines = []
            while i < len(lines) and lines[i].strip().startswith("\\\\"):
                sql_lines.append(lines[i].strip()[2:])
                i += 1
            statements.append("\n".join(sql_lines))
            continue
        i += 1

    statements.extend(_re.findall(
        r'exec\("(CREATE TABLE IF NOT EXISTS [^"\\]+)"\)', db_source,
    ))
    if not statements:
        raise RuntimeError("could not derive isolated database fixture from db.zig")

    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    try:
        for sql in statements:
            # Python's stock SQLite does not load sqlite-vec.  Preserve the
            # virtual tables' externally queried shape with local test doubles.
            if sql.startswith("CREATE VIRTUAL TABLE IF NOT EXISTS vec_aimemory"):
                sql = "CREATE TABLE IF NOT EXISTS vec_aimemory (id INTEGER PRIMARY KEY, embedding BLOB)"
            elif sql.startswith("CREATE VIRTUAL TABLE IF NOT EXISTS vec_taste"):
                sql = "CREATE TABLE IF NOT EXISTS vec_taste (id INTEGER PRIMARY KEY, embedding BLOB)"
            conn.execute(sql)

        # Idempotent migrations that are intentionally separate from CREATE.
        columns = {
            "aimemory": (("position_secs", "REAL DEFAULT 0"),),
            "tv_watched": (
                ("position_secs", "REAL DEFAULT 0"),
                ("duration_secs", "REAL DEFAULT 0"),
                ("played_secs", "REAL DEFAULT 0"),
            ),
        }
        for table, additions in columns.items():
            present = {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
            for name, declaration in additions:
                if name not in present:
                    conn.execute(f"ALTER TABLE {table} ADD COLUMN {name} {declaration}")

        defaults = {
            "theme_preset": "Midnight",
            "ui_scale": "1.0",
            "tts_voice": "Bella",
            "tts_speed": "1.0",
            "win_x": "100", "win_y": "100", "win_w": "1440", "win_h": "800",
        }
        conn.executemany(
            "INSERT OR REPLACE INTO config(key, value) VALUES (?, ?)", defaults.items(),
        )
        conn.execute(
            "INSERT OR REPLACE INTO watch_history"
            "(name, percent, position_secs, duration_secs, file_key, link) "
            "VALUES ('fixture.mkv', 0.5, 60, 120, '/fixture/fixture.mkv', '')"
        )
        conn.execute("PRAGMA user_version=3")
        conn.commit()
    except Exception:
        conn.close()
        try:
            os.remove(DB_PATH)
        except OSError:
            pass
        raise
    conn.close()


_create_isolated_db_fixture()

__all__ = [
    "test", "TestResult", "results", "REGISTRY", "run_all",
    "get_db", "_src", "_web_app", "_web_js", "_remote_api", "_between", "_parse_catalog",
    "DB_PATH", "PROJECT_DIR", "RESULTS_FILE", "_EMOJI", "_re", "_posix_shell",
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
    # Diagnostics must never mutate the app's live database. as_uri escapes
    # spaces, '#' and '?' instead of treating a fixture path as URI options.
    return sqlite3.connect(Path(DB_PATH).resolve().as_uri() + "?mode=ro", uri=True)


def _src(rel):
    p = os.path.join(PROJECT_DIR, rel)
    return open(p, encoding="utf-8").read() if os.path.exists(p) else ""


def _posix_shell():
    """Return a working POSIX shell, including common Windows dev installs."""
    candidates = [os.environ.get("OPAL_TEST_SH"), shutil.which("sh")]
    if os.name == "nt":
        candidates.extend((
            r"C:\msys64\usr\bin\sh.exe",
            r"C:\Program Files\Git\bin\sh.exe",
            r"C:\Program Files\Git\usr\bin\sh.exe",
        ))
    for candidate in candidates:
        if not candidate or not os.path.isfile(candidate):
            continue
        try:
            probe = subprocess.run(
                [candidate, "-c", "exit 0"], capture_output=True, timeout=5,
            )
            if probe.returncode == 0:
                return candidate
        except (OSError, subprocess.SubprocessError):
            pass
    return None


def _web_js():
    """The ordered browser bundle as served by web/index.html."""
    names = (
        "core.js", "now-playing.js", "catalog.js", "playback.js", "integrations.js",
        "source-management.js", "media.js", "discovery.js", "boot.js",
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
        "remote_plex_api.zig",
        "remote_youtube_api.zig",
        "remote_anime_api.zig",
        "remote_custom_sources_api.zig",
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
    with open(src, encoding="utf-8") as f:
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
    # Repeated runs in one process must not retain the previous report.
    results.clear()
    test_fns = list(REGISTRY)

    print(f"\n{'='*60}")
    print(f"  Opal Feature Test Suite — {len(test_fns)} tests")
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

    with open(RESULTS_FILE, "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2)
    print(f"  Results written to {RESULTS_FILE}")

    return total_fail == 0
