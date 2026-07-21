"""Headless web-UI account auth — replaces the desktop-derived pairing code.

Same auth + same UI for headless AND desktop-remote. Passwords bcrypt-hashed
(auth_pure, unit-tested); users/sessions in SQLite (auth_store); the Bearer gate
accepts a live session token OR the static api.token. Grows phase by phase
(A1 core → A2 store → A3 routes → A4 web UI → A5 deploy).

See tests/features/harness.py for the shared @test decorator + _src()."""
from .harness import *  # noqa: F401,F403


@test("Auth core (bcrypt) present + tested", "Auth")
def test_auth_pure():
    ap = _src("src/services/auth_pure.zig")
    build = _src("build.zig")
    checks = {
        "bcrypt hashing": "std.crypto.pwhash.bcrypt" in ap and "pub fn hashWithSalt(" in ap,
        "verify": "pub fn verify(" in ap and "bcrypt.strVerify(" in ap,
        "validation": "pub fn validUsername(" in ap and "pub fn validPassword(" in ap,
        "salt-injectable (testable)": "salt: [SALT_LEN]u8" in ap,
        "unit tests": ap.count('test "') >= 3,
        "registered in test step": 'b.path("src/services/auth_pure.zig")' in build,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "auth core incomplete: " + ", ".join(missing)
    return "pass", "auth_pure: bcrypt hash/verify + validation, unit-tested + registered"


@test("Auth store (users/sessions) present + wired", "Auth")
def test_auth_store():
    st = _src("src/services/auth_store.zig")
    mn = _src("src/main.zig")
    checks = {
        "users table": "CREATE TABLE IF NOT EXISTS users" in st and "pw_hash" in st,
        "sessions table": "CREATE TABLE IF NOT EXISTS sessions" in st and "expires_at" in st,
        "store api": all(f"pub fn {fn}(" in st for fn in (
            "ensureTables", "userCount", "createUser", "authenticate",
            "issueSession", "validSession", "revokeSession", "pruneExpired")),
        "routes hashing through auth_pure": 'auth = @import("auth_pure.zig")' in st
            and "auth.hashWithSalt(" in st and "auth.verify(" in st,
        # CSPRNG salt + token from /dev/urandom, like remote.zig's api token.
        "csprng from urandom": "/dev/urandom" in st,
        # Wired into startup after db.init (kept out of db.zig for layering).
        "wired at startup": "auth_store.ensureTables()" in mn and "auth_store.pruneExpired()" in mn,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "auth store incomplete: " + ", ".join(missing)
    return "pass", "auth_store: users+sessions tables, bcrypt via auth_pure, wired at startup"


@test("Auth routes + session Bearer gate", "Auth")
def test_auth_routes():
    rm = _src("src/services/remote.zig")
    checks = {
        "auth route dispatch": '"/api/auth/"' in rm,
        "status/register/login/logout": all(f'"{s}"' in rm for s in ("status", "register", "login", "logout")),
        # First account = admin; registration then closes.
        "first-run gated register": "userCount() != 0" in rm and "registration closed" in rm,
        "issues session on success": "issueSession(uid" in rm and "TOKEN_HEX" in rm,
        # The Bearer gate accepts the static token OR a live session.
        "session-aware gate": "fn isAuthorized(" in rm and "validSession(token)" in rm
            and "if (!isAuthorized(presented))" in rm,
        # Credentials from the POST body, not the URL.
        "creds from body": "fn credParam(" in rm and "fn requestBody(" in rm,
        "typed error codes": "409 Conflict" in rm and "403 Forbidden" in rm,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "auth routes incomplete: " + ", ".join(missing)
    return "pass", "auth routes: status/register/login/logout + session-aware Bearer gate"


@test("Web UI account login/register (no pairing code)", "Auth")
def test_auth_web_ui():
    ui = _src("web/index.html")
    checks = {
        # Account screen replaces the pairing screen (same #pair-screen overlay).
        "account fields": 'id="auth-user"' in ui and 'id="auth-pass"' in ui and 'id="auth-pass2"' in ui,
        "status drives mode": "/api/auth/status" in ui and "needs_setup" in ui
            and "authMode" in ui,
        # routes are built as '/api/auth/' + (reg ? 'register' : 'login')
        "register + login POST": "'register' : 'login'" in ui and "function submitAuth(" in ui
            and "/api/auth/" in ui,
        "logout revokes session": "/api/auth/logout" in ui and "function unpair(" in ui,
        "boot shows auth": "if (TOKEN) paired(); else showAuth();" in ui,
        # The 6-digit pairing code is gone from the web UI.
        "no pairing code": "/pair?code=" not in ui and 'id="pair-code"' not in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "web auth UI incomplete: " + ", ".join(missing)
    return "pass", "web UI: account create/sign-in (status-driven), pairing code removed"
