"""Torrent transfers: seek-aware piece deadlines and the typed transfer policy.
See tests/features/harness.py for the shared @test decorator and helpers."""
from .harness import *  # noqa: F401,F403
import re
import shutil
import sqlite3
import subprocess
import sys


@test("Seek deadlines: FFI against a real loopback seed", "Torrents")
def test_seek_deadline_ffi():
    if not shutil.which("pkg-config") or subprocess.run(
        ["pkg-config", "--exists", "libtorrent-rasterbar"]).returncode:
        return "skip", "libtorrent-rasterbar not installed"
    result = subprocess.run(
        [sys.executable, "tests/test_torrent_deadline.py"], cwd=PROJECT_DIR,
        capture_output=True, text=True, timeout=400,
    )
    if result.returncode or "ALL PASS" not in result.stdout:
        return "fail", (result.stdout + result.stderr)[-2000:]
    return "pass", "geometry, jump/slide deadlines, bounds, transfer facts, disk free, RAM fallback"


@test("Seek deadlines: every seek path plans in Zig", "Torrents")
def test_seek_deadline_wiring():
    header = _src("src/torrent_wrapper.h")
    cpp = _src("src/torrent_wrapper.cpp")
    for sym in ("torrent_get_piece_geometry", "torrent_apply_piece_deadlines",
                "torrent_get_transfer_facts", "torrent_disk_free_bytes"):
        if sym not in header or f'extern "C"' not in cpp or f" {sym}(" not in cpp:
            return "fail", f"{sym} missing from the wrapper ABI"
    proxy = _src("src/player/stream_proxy.zig")
    if "torrent_set_seek_hint" in proxy or "torrent_deadlines.zig\").seekToByte" not in proxy:
        return "fail", "stream proxy range requests must route through torrent_deadlines.seekToByte"
    if "torrent_deadlines.zig\").forget" not in proxy:
        return "fail", "closing a stream must forget its deadline window"
    footer = _src("src/ui/footer.zig")
    if "torrent_seek_prioritize" in footer or "seekToPercent" not in footer:
        return "fail", "seekbar must route through torrent_deadlines.seekToPercent"
    executor = _src("src/player/torrent_deadlines.zig")
    if "pure.plan(" not in executor:
        return "fail", "executor must use torrent_deadline_pure.plan"
    build = _src("build.zig")
    for mod in ("src/player/torrent_deadline_pure.zig", "src/services/transfer_policy_pure.zig"):
        if f'b.path("{mod}")' not in build:
            return "fail", f"{mod} not registered in the test step"
    return "pass", "proxy + seekbar -> deadline planner -> wrapper; pure modules tested"


def _migration_sql():
    """The CREATE (a Zig multiline string) and every ALTER for the intents table."""
    db = _src("src/core/db.zig")
    lines, collecting = [], False
    for line in db.splitlines():
        t = line.strip()
        if t.startswith("\\\\CREATE TABLE IF NOT EXISTS active_torrent_intents"):
            collecting = True
        if collecting:
            if not t.startswith("\\\\"):
                break
            lines.append(t[2:])
    alters = re.findall(r'exec\("(ALTER TABLE active_torrent_intents[^"]+)"\)', db)
    return "\n".join(lines), alters


@test("Transfer policy: state persists through the real schema", "Torrents")
def test_transfer_state_schema():
    create_sql, alters = _migration_sql()
    if not create_sql or not any("ADD COLUMN state" in a for a in alters):
        return "fail", "active_torrent_intents migration lacks the typed state column"
    policy = _src("src/services/transfer_policy.zig")
    select = re.search(r'"(SELECT state, seed_seconds, uploaded, goal_waived FROM active_torrent_intents[^"]*)"', policy)
    update = re.search(r'"(UPDATE active_torrent_intents SET state[^"]*)"', policy)
    if not select or not update:
        return "fail", "executor load/persist SQL not found"
    if "INSERT" in _between(policy, "fn persist(", "\n}\n"):
        return "fail", "persist must UPDATE only (a late write must not resurrect a removed transfer)"
    conn = sqlite3.connect(":memory:")
    conn.execute(create_sql)
    conn.execute("INSERT INTO active_torrent_intents(identity, paused) VALUES ('magnet:?xt=urn:btih:aa', 1)")
    for _ in range(2):  # migrations re-run every launch; duplicates are benign
        for a in alters:
            try:
                conn.execute(a)
            except sqlite3.OperationalError as e:
                if "duplicate column" not in str(e):
                    return "fail", f"{a}: {e}"
    if conn.execute("SELECT state FROM active_torrent_intents").fetchone()[0] != "":
        return "fail", "pre-existing rows must read as 'no persisted state'"
    sql_update = update.group(1)
    conn.execute(sql_update, ("completed", 3600, 123456, 1, "magnet:?xt=urn:btih:aa"))
    conn.execute(sql_update, ("seeding", 1, 1, 0, "magnet:?xt=urn:btih:missing"))
    row = conn.execute(select.group(1), ("magnet:?xt=urn:btih:aa",)).fetchone()
    if row != ("completed", 3600, 123456, 1):
        return "fail", f"round-trip mismatch: {row}"
    if conn.execute("SELECT COUNT(*) FROM active_torrent_intents").fetchone()[0] != 1:
        return "fail", "UPDATE created a row for an unknown identity"
    return "pass", "migration idempotent; state/seed time/upload/waiver round-trip; no resurrecting writes"


@test("Transfer policy: config, watchdog, playback and API wiring", "Torrents")
def test_transfer_policy_wiring():
    config = _src("src/core/config.zig")
    for key in ("torrent_max_active", "torrent_reserve_mb", "torrent_seed_ratio_x100", "torrent_seed_minutes"):
        if config.count(f'"{key}"') < 2:
            return "fail", f"config key {key} must be both saved and loaded"
    if "transfer_policy.zig\").tick(ses" not in _src("src/services/torrent_stall.zig"):
        return "fail", "watchdog must run the transfer policy"
    for f in ("src/app_services.zig", "src/headless.zig"):
        if "transfer_policy.zig\").publishConfig()" not in _src(f):
            return "fail", f"{f} must publish policy config"
    if "markInteractive(id)" not in _between(_src("src/player/player.zig"), "pub fn attachTorrent", "\n    }"):
        return "fail", "a torrent opened for playback must never be queued"
    if '\\"state\\"' not in _src("src/services/remote_transfer_api.zig"):
        return "fail", "/torrents must expose the typed state"
    pure = _src("src/services/transfer_policy_pure.zig")
    if "pub fn transition(" not in pure or "error.InvalidTransition" not in pure:
        return "fail", "state transitions must be explicit and typed"
    return "pass", "settings -> watchdog policy -> libtorrent; playback exempt from queue; API state"


@test("Settings expose the transfer policy and TVDB key", "Settings")
def test_settings_v2_controls():
    net = _src("src/ui/settings/network.zig")
    gen = _src("src/ui/settings/general.zig")
    pure = _src("src/services/transfer_policy_pure.zig")
    checks = {
        "presets are pure and tested": "pub fn presetIndex(" in pure and 'test "settings presets select exact or nearest value"' in pure,
        "all four policy keys have a themed segment": all(
            f"tp.presetIndex(state.app.{k}, &tp.{p})" in net for k, p in (
                ("torrent_max_active", "max_active_presets"), ("torrent_reserve_mb", "reserve_mb_presets"),
                ("torrent_seed_ratio_x100", "seed_ratio_presets"), ("torrent_seed_minutes", "seed_minutes_presets"))),
        "policy edits persist": net.count("state.markConfigDirty();") >= 6,
        "TVDB key field is masked and saved": "&state.app.tvdb_api_key" in gen and '.password_char = "•"' in gen
                                             and "state.app.tvdb_api_key_len = std.mem.indexOfScalar" in gen,
    }
    bad = [k for k, ok in checks.items() if not ok]
    return ("fail", ", ".join(bad)) if bad else ("pass", "4 policy segments (pure presets) + masked TVDB key in Settings")
