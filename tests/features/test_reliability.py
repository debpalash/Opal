"""Reliability budgets and the independent-server matrix (deterministic; no app launch)."""
import subprocess
import sys
from .harness import PROJECT_DIR, _src, test


def _unit(script):
    result = subprocess.run([sys.executable, script], cwd=PROJECT_DIR, capture_output=True, text=True, timeout=60)
    return result.returncode, (result.stderr or result.stdout)[-1400:]


@test("Reliability budgets: percentiles, relative gate, recorded 300-cycle baseline", "Performance")
def test_reliability_budgets():
    code, output = _unit("tests/test_reliability_budget.py")
    if code:
        return "fail", output
    return "pass", "Nearest-rank p95, relative+noise-floor gate, zero-orphan invariants, baseline complete, --check exits 1 on regression"


@test("Headless owner loop drains player close (no orphan playback)", "Performance")
def test_headless_player_close():
    headless = _src("src/headless.zig")
    services = _src("src/app_services.zig")
    tick = services[services.index("pub fn tickPlayers"):]
    if headless.count('@import("app_services.zig").tickPlayers();') != 1:
        return "fail", "headless loop must run the shared player tick exactly once"
    if "pending_remove_player_idx" not in tick or "drainPendingLoad" not in tick:
        return "fail", "tickPlayers must drain deferred player removal and comic loads"
    if '@import("services/comics.zig").drainPendingLoad();' in headless:
        return "fail", "comic loads would drain twice per headless tick"
    return "pass", "/api/player/action?action=close removes the player on headless; the live soak asserts it"


@test("Independent-server matrix: evidence exists and docs claim no more", "Docs")
def test_server_matrix():
    code, output = _unit("tests/test_server_matrix.py")
    if code:
        return "fail", output
    return "pass", "8 capabilities x workstation/NAS; verified cells cite existing tests with accurate CI labels; doc table and claims match"
