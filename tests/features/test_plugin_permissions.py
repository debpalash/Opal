"""Plugin `require` allow-list + one-time permission grant.
See tests/features/harness.py for the shared @test decorator, helpers, and
run_all()."""
from .harness import *  # noqa: F401,F403
import os
import shutil
import subprocess
import sys


@test("Plugin require allow-list and one-time permission grant are wired", "Plugins")
def test_plugin_permission_wiring():
    pure = _src("src/services/plugin_permissions_pure.zig")
    plugins = _src("src/services/plugins.zig")
    pp = _src("src/services/plugins_pure.zig")
    api = _src("src/services/remote_plugins_api.zig")
    rm = _src("src/services/remote.zig")
    access = _src("src/services/access_pure.zig")
    build = _src("build.zig")
    checks = {
        "pure module registered": 'b.path("src/services/plugin_permissions_pure.zig")' in build,
        "manifest require parsed at load": "parseRequires(c_alloc, json) catch" in plugins,
        "disabled until granted": "plugin.enabled = @import(\"plugin_permissions_pure.zig\").permitted(" in plugins,
        "runMode takes the grant": "permissions_ok: bool) RunMode" in pp
            and "!permissions_ok) return .deny" in pp,
        "every launch goes through launchGate": plugins.count("launchGate(&p") + plugins.count("launchGate(&plugin") >= 4
            and "pp.runMode(" not in plugins,
        "prelude built per plugin": "perms.buildPrelude(" in plugins and "LUA_SANDBOX_PRELUDE" not in plugins,
        "grant stored outside plugin dir": "plugin-trust/{s}.grant" in plugins and "grantDigest(" in plugins,
        "grant bound to permission set": 'hash.update("opal-plugin-grant-v1\\x00")' in pure,
        "host-only grant route": '"grant-perms"' in rm and '"revoke-perms"' in rm
            and '"grant-perms"' in access and "setPermissionGrant" in api,
        "inventory exposes requests": "needs_permission" in api and "needs-permission" in api,
        "TODO resolved": "TODO(security): manifest `require` allow-list" not in plugins,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "plugin permissions incomplete: " + ", ".join(missing)
    return "pass", "require allow-list enforced at load + launch; grant is host-only and permission-bound"


@test("Plugin Lua prelude enforces the require allow-list (real interpreter)", "Plugins")
def test_plugin_prelude_runtime():
    if not (shutil.which("lua") or shutil.which("luajit")):
        return "skip", "no lua/luajit interpreter"
    script = os.path.join(PROJECT_DIR, "tests", "test_lua_execution_policy.py")
    r = subprocess.run([sys.executable, script], capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        return "fail", (r.stderr or r.stdout)[-400:]
    return "pass", "listed plugin modules load; unlisted, reserved and native modules are denied"
