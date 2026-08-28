"""Fast architecture and documentation wiring checks.

These checks are deliberately labelled as source-wiring tests. Runtime and
socket behavior belongs to the opt-in live test tier.
"""
from .harness import *  # noqa: F401,F403


@test("Architecture boundaries are documented and enforced", "Architecture")
def test_architecture_boundaries():
    doc = _src("docs/architecture.md")
    checks = {
        "dependency direction": all(term in doc.lower() for term in (
            "domain", "store", "adapters", "application", "presentation",
        )),
        "headless boundary": "dvui" in doc.lower() and "headless" in doc.lower(),
        "lock order": "feature lock" in doc.lower() and "socket" in doc.lower(),
        "reference vertical": "Podcasts" in doc,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "architecture documentation missing: " + ", ".join(missing)
    return "pass", "dependency direction, headless seam, reference vertical, and lock order documented"


@test("Task navigation and documentation stay current", "Architecture")
def test_navigation_and_docs_freshness():
    import re

    zon = _src("build.zig.zon")
    analysis = _src("docs/analysis.md")
    navigation = _src("docs/navigation.md")
    shell = _src("src/ui/shell.zig")
    router = _src("src/core/router.zig")
    version_match = re.search(r'\.version\s*=\s*"([^"]+)"', zon)
    route_match = re.search(r"pub const Route = enum\s*\{([^}]+)\}", router, re.S)
    route_count = len(re.findall(r"^\s{4}[a-z_]+,\s*$", route_match.group(1), re.M)) if route_match else 0
    checks = {
        "canonical version named": bool(version_match and version_match.group(1) in analysis),
        "route count current": f"{route_count} routes" in analysis,
        "task map": all(name in navigation for name in (
            "Home", "Search", "Watching", "Downloads", "Playing",
        )),
        "browse source filter": "browseSourcePicker()" in shell
            and "subTabs(&.{ .TMDB" not in shell,
        "power-user access": "command-palette" in navigation.lower(),
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "navigation/docs drift: " + ", ".join(missing)
    return "pass", f"task map and docs match version {version_match.group(1)} and {route_count} routes"


@test("Critical background work uses the owned supervisor", "Architecture")
def test_owned_worker_supervisor():
    workers = _src("src/core/workers.zig")
    main = _src("src/main.zig")
    verticals = {
        name: _src(f"src/services/{name}.zig")
        for name in ("podcasts", "jellyfin", "anime", "comics", "youtube")
    }
    checks = {
        "initialized before services": 'workers.zig").init()' in main,
        "admission is bounded": "MAX_OWNED_THREADS" in workers and "error.WorkQueueFull" in workers,
        "shutdown stops admission": "error.ShuttingDown" in workers and "markQuitting();" in workers,
        "shutdown joins": ".join();" in workers and "beginShutdownAndDrain" in main,
        "slow diagnostic": "waiting for {d} owned" in workers,
        "critical verticals migrated": all(".detach()" not in source for source in verticals.values()),
        "startup migrated": ")) |t| t.detach()" not in main,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "worker ownership regression(s): " + ", ".join(missing)
    return "pass", "bounded owned supervisor covers startup and five critical verticals"
