"""Household profiles (ROADMAP 7.3) — per-person data dirs, PIN, kid mode.

A profile is a data directory: the default keeps <config>/opal.db, others live
in <config>/profiles/<id>/ with their own opal.db + sync_device. The registry is
a global owner-only file; switching is a controlled restart. Pure rules (PIN
hashing/backoff, maturity, validation) are unit-tested in profiles_pure.zig.

See tests/features/harness.py for the shared @test decorator."""
import subprocess
from .harness import *  # noqa: F401,F403


@test("Profiles: child NSFW writes stay enabled before owner tick", "Profiles")
def test_profiles_nsfw_write_policy():
    result = subprocess.run(
        ["zig", "test", "src/services/profiles_pure.zig", "--test-filter", "child NSFW"],
        cwd=PROJECT_DIR, capture_output=True, text=True, timeout=120)
    if result.returncode:
        return "fail", result.stderr[-1500:]
    return "pass", "executed child/adult NSFW write-policy regression; live routes covered by test_horizon_device_live.py"


def _fail(checks, what):
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", what + " incomplete: " + ", ".join(missing)
    return None


@test("Profiles: pure rules (PIN hash, backoff, maturity) unit-tested", "Profiles")
def test_profiles_pure():
    pure = _src("src/services/profiles_pure.zig")
    svc = _src("src/services/profiles.zig")
    build = _src("build.zig")
    checks = {
        "pbkdf2-sha256 + per-PIN salt": "std.crypto.pwhash.pbkdf2(" in pure and "salt: [SALT_LEN]u8" in pure,
        "constant-time verify": "std.crypto.timing_safe.eql(" in _between(pure, "pub fn verifyPin", "\n}\n"),
        "random salt from CSPRNG": "io.randomSecure(&salt)" in svc,
        "attempt backoff": "pub const Backoff = struct" in pure and "pub fn lockMs(" in pure,
        "backoff applied on switch": "bo.recordFailure(now)" in svc and "retryAfterMs(now)" in svc,
        "certification table spans regions": all(c in pure for c in ('"PG-13"', '"TV-MA"', '"12A"', '"FSK 16"', '"-16"', '"UA"', '"R15+"')),
        "unknown rating denied for kids by default": "return allow_unrated" in _between(pure, "pub fn maturityAllows", "\n}\n")
            and "allow_unrated: bool = false" in pure,
        "tmdb certification parser": "pub fn tmdbAge(" in pure and "release_dates" in pure and '"rating"' in pure,
        "name/id/colour validation": "pub fn validateName(" in pure and "pub fn validId(" in pure and "pub fn parseColor(" in pure,
        "registered in build.zig test step": 'b.path("src/services/profiles_pure.zig")' in build,
        "tests present": pure.count('test "') >= 12,
    }
    r = _fail(checks, "profiles pure")
    return r or ("pass", "PBKDF2 PIN + constant-time verify + backoff + maturity table, registered")


@test("Profiles: registry stored globally, outside every profile db", "Profiles")
def test_profiles_registry():
    svc = _src("src/services/profiles.zig")
    pure = _src("src/services/profiles_pure.zig")
    checks = {
        "registry file in config dir": '"{s}/profiles.tsv"' in svc and "paths.configDir(" in _between(svc, "fn registryPath", "\n}\n"),
        "owner-only atomic write": "secret_file.zig\").write(tmp" in svc and "io.renameAbsolute(tmp, path)" in svc,
        "serialize/parse round trip": "pub fn serialize(" in pure and "pub fn parse(" in pure and "ensureDefault()" in pure,
        "default never deletable": "error.Default" in _between(pure, "pub fn remove", "\n    }\n"),
        "running profile never deletable": "return error.Running" in _between(svc, "pub fn delete(", "\n}\n"),
        "ids validated before building paths": "pure.validId(id)" in _between(svc, "fn profileDir", "\n}\n"),
        "no PIN hash in the API listing": "pinHash" not in _src("src/services/remote_profiles_api.zig")
            and "pin_hash" not in _src("src/services/remote_profiles_api.zig"),
    }
    r = _fail(checks, "profile registry")
    return r or ("pass", "<config>/profiles.tsv, owner-only + atomic, default/running protected")


@test("Profiles: per-profile data isolation (db dir, household tables shared)", "Profiles")
def test_profiles_isolation():
    paths = _src("src/core/paths.zig")
    main = _src("src/main.zig")
    hh = _src("src/core/household_db.zig")
    auth = _src("src/services/auth_store.zig")
    link = _src("src/services/browser_link.zig")
    dbz = _src("src/core/db.zig")
    core_init = _between(main, "pub fn coreInit", "\n}\n")
    checks = {
        "db path follows the profile dir": "profile_dir_buf[0..profile_dir_len]" in _between(paths, "pub fn zigzagDbFile", "\n}\n"),
        "default profile keeps today's path": "pub fn householdDbFile(" in paths and "opal/opal.db" in _between(paths, "pub fn householdDbFile", "\n}\n"),
        "profile resolved before the db worker": "profiles.zig\").initActive()" in core_init
            and core_init.index("initActive()") < core_init.index("database.init()"),
        "accounts + paired browsers stay household-wide": 'household_db.zig")' in auth and 'household_db.zig")' in link,
        "household conn targets the default db": "paths.householdDbFile(" in hh and "if (!paths.profileActive()) return db.get();" in hh,
        "household conn closed with the db": 'household_db.zig").deinit()' in dbz,
        "seed copies shared config only": "pure.seedsConfigKey(k)" in _src("src/services/profiles.zig"),
    }
    r = _fail(checks, "profile isolation")
    return r or ("pass", "own opal.db per profile; web accounts/paired browsers in the household db")


@test("Profiles: per-profile sync identity (device id + clone file never re-rolled by switching)", "Profiles")
def test_profiles_sync_identity():
    dbz = _src("src/core/db.zig")
    pure = _src("src/services/profiles_pure.zig")
    bind = _between(dbz, "fn bindSyncIdentity", "\n}\n")
    checks = {
        "clone file lives in the profile dir": "sync_device" in bind and "paths.profileDataDir(" in bind,
        "new profile db never copies sync meta": "library_sync_meta" not in _src("src/services/profiles.zig"),
        "sync peers/cursors not seeded": '"lsync_"' in _between(pure, "pub fn seedsConfigKey", "\n}\n"),
    }
    r = _fail(checks, "per-profile sync identity")
    return r or ("pass", "sync_device + device_id + peers are per profile")


@test("Profiles: kid mode enforced (NSFW, maturity cap, locked settings/sources, PIN to leave)", "Profiles")
def test_profiles_kid_mode():
    svc = _src("src/services/profiles.zig")
    ui = _src("src/ui/profiles_ui.zig")
    drawer = _src("src/ui/drawer.zig")
    shell = _src("src/ui/shell.zig")
    tmdb = _src("src/services/tmdb.zig")
    mat = _src("src/services/profiles_maturity.zig")
    headless = _src("src/headless.zig")
    pure = _src("src/services/profiles_pure.zig")
    checks = {
        "nsfw filter pinned on": "state.app.nsfw_filter_enabled = true" in _between(svc, "pub fn enforce", "\n}\n"),
        "enforced every frame + headless tick": "profiles.enforce();" in _between(ui, "pub fn renderPicker", "\n}\n")
            and 'profiles.zig").enforce()' in headless,
        "settings/plugins/ai/logs locked": "blocksTab(tab)" in drawer and ".Settings, .Plugins, .AI, .Logs" in ui,
        "source management + agents locked": shell.count("blocksKid()") >= 2,
        "maturity gate on TMDB open": 'profiles_maturity.zig").allowTmdb(item)' in _between(tmdb, "pub fn openOrSearch", "\n}\n"),
        "certification fetched + mapped": "release_dates" in mat and "content_ratings" in mat and "pure.tmdbAge(" in mat,
        "leaving kid mode needs the owner PIN": "if (from_kid and !target.kid and owner_has_pin) return .owner;" in pure,
        "kid seed forces nsfw on": "'nsfw_filter', '1'" in svc,
    }
    r = _fail(checks, "kid mode")
    return r or ("pass", "kid: NSFW forced, age cap on TMDB titles, settings/sources/agents locked, owner PIN to leave")


@test("Profiles: switch is a controlled restart through session restore", "Profiles")
def test_profiles_switch_restart():
    main = _src("src/main.zig")
    svc = _src("src/services/profiles.zig")
    headless = _src("src/headless.zig")
    deinit = _between(main, "pub fn appDeinit", "\n}\n")
    checks = {
        "frame quits on a switch": 'profiles.zig").restartRequested()) return .close;' in main,
        "headless loop exits on a switch": 'profiles.zig").restartRequested()) break;' in headless,
        "re-exec after full teardown": "restartAfterShutdown()" in deinit
            and deinit.index("captureCloseSession()") < deinit.index("restartAfterShutdown()")
            and deinit.index("core/db.zig\").deinit()") < deinit.index("restartAfterShutdown()"),
        "exec path resolved at boot": "io.selfExePath(&exe_buf)" in svc,
        "one-shot unlock marker": ".switch_ok" in svc and "io.deleteFileAbsolute(marker)" in svc,
    }
    r = _fail(checks, "profile switch")
    return r or ("pass", "switch = save session, drain, close db, execve into the new profile")


@test("Profiles: UI themed (components.* only, lucide icons) + API routes gated", "Profiles")
def test_profiles_ui_and_api():
    ui = _src("src/ui/profiles_ui.zig")
    settings = _src("src/ui/settings.zig")
    shell = _src("src/ui/shell.zig")
    main = _src("src/main.zig")
    api = _src("src/services/remote_profiles_api.zig")
    remote = _src("src/services/remote.zig")
    access = _src("src/services/access_pure.zig")
    import re
    checks = {
        "no bare dvui.button": "dvui.button(" not in ui,
        "components helpers": all(h in ui for h in ("components.actionButton(", "components.toggleRow(", "components.segment(", "components.confirmDangerButton(")),
        "no colour literals": re.search(r"dvui\.Color\{\s*\.r", ui) is None,
        "lucide icons, no glyph labels": "icons.tvg.lucide." in ui and not any(g in ui for g in ("▶", "●", "←", "✓")),
        "settings tab": ".Profiles => @import(\"profiles_ui.zig\").renderSettingsTab()" in settings,
        "avatar menu in the top bar": 'profiles_ui.zig").avatarMenu()' in shell,
        "launch picker": 'profiles_ui.zig").renderPicker()' in main,
        "api routes": all(r in api for r in ('"/profiles"', '"/profiles/switch"', '"/profiles/create"', '"/profiles/delete"')),
        "api dispatched": 'remote_profiles_api.zig").handle(' in remote,
        "switch/create/delete admin-only": all(f'"/profiles/{r}"' in _between(access, "const host_routes", "};") for r in ("switch", "create", "delete")),
    }
    r = _fail(checks, "profiles UI/API")
    return r or ("pass", "picker + avatar menu + Settings > Profiles themed; /api/profiles + admin switch/create/delete")
