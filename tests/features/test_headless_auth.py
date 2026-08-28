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
    rm = _remote_api()
    st = _src("src/services/auth_store.zig")
    policy = _src("src/services/access_pure.zig")
    checks = {
        "auth route dispatch": '"/api/auth/"' in rm,
        "status/register/login/logout": all(f'"{s}"' in rm for s in ("status", "register", "login", "logout")),
        # First account = admin; the empty-check and insert must be one DB
        # statement, not a request-racy userCount() followed by createUser().
        "atomic first-admin claim": (
            "createFirstAdmin(username, password)" in rm
            and "WHERE NOT EXISTS (SELECT 1 FROM users)" in st
            and "error.SetupClosed" in rm
        ),
        "issues session on success": "issueSession(uid" in rm and "TOKEN_HEX" in rm,
        # The Bearer gate accepts the static token OR a live session.
        "session-aware gate": "fn principalForBearer(" in rm and "validSession(token)" in rm
            and "const principal = principalForBearer(presented)" in rm,
        # Machine recovery authority is explicit and tested, rather than being
        # inferred from a failed session lookup.
        "separate machine capability": (
            "pub const Principal" in policy and "pub fn allows(" in policy
            and "access_pure.allows(principal, .reveal_machine_token)" in rm
            and "access_pure.allows(principal, .change_binding)" in rm
        ),
        # Credentials come from POST bodies only on authentication routes.
        "post-only body credentials": (
            'requireMethod(stream, method, "POST")' in rm
            and 'credParam(body, "", "password"' in rm
        ),
        "typed error codes": "405 Method Not Allowed" in rm and "403 Forbidden" in rm,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "auth routes incomplete: " + ", ".join(missing)
    return "pass", "auth routes: status/register/login/logout + session-aware Bearer gate"


@test("Container first-admin credential lifecycle", "Auth")
def test_container_first_admin_credential():
    smoke = _src("scripts/docker-smoke.sh")
    dockerfile = _src("Dockerfile")
    remote = _remote_api()
    compose = _src("deploy/docker-compose.yml")
    deploy_doc = _src("docs/headless-deploy.md")
    checks = {
        "persistent config volume": '-v "$config_volume:/config"' in smoke,
        "owner-only mounted credential": (
            "/config/opal/setup.token" in smoke
            and "setup_mode" in smoke and '"$setup_mode" != 600' in smoke
            and "setup_owner" in smoke and '"$setup_owner" != 10001' in smoke
        ),
        "credential shape checked": "^[0-9a-f]{64}$" in smoke,
        "registration rejects omission": (
            "register-without-setup.json" in smoke and '"$code" != 403' in smoke
        ),
        "registration enforces local authority": (
            "register-cross-origin.json" in smoke
            and "register-dns-host.json" in smoke
            and "rejected registration consumed" in smoke
        ),
        "credential sent in dedicated header": (
            "X-Opal-Setup-Token" in smoke and '"@$smoke_dir/setup-header"' in smoke
        ),
        "one-time file removed": 'test -e "$setup_path"' in smoke
            and "still exists after successful registration" in smoke,
        "credential cannot be replayed": (
            "register-replay.json" in smoke and "replayed first-admin credential" in smoke
        ),
        "logs disclose path only": (
            'grep -Fq "$setup_path"' in smoke
            and 'grep -Fq "$setup_token"' in smoke
            and "credential leaked to container logs" in smoke
        ),
        "image documents mounted path": "/config/opal/setup.token" in dockerfile,
        "headless stdout announces path only": (
            "first-admin setup credential:" in remote
            and "owner-only; value not logged" in remote
            and "setupTokenPath" in remote
        ),
        "basic deployment is host-loopback only": "127.0.0.1:41595:41595" in compose,
        "compose explains non-root config ownership": (
            "10001:10001" in compose and "/config/opal/setup.token" in compose
        ),
        "operator bootstrap documented": (
            "X-Opal-Setup-Token" in deploy_doc
            and "deleted immediately" in deploy_doc
            and "cross-authority browser Origin" in deploy_doc
            and "Startup logs announce this" in deploy_doc and "path only" in deploy_doc
        ),
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "container onboarding incomplete: " + ", ".join(missing)
    return "pass", "mounted 0600 setup token is required, consumed once, and never logged"


@test("Web UI account login/register (no pairing code)", "Auth")
def test_auth_web_ui():
    ui = _web_app()
    checks = {
        # Account screen replaces the pairing screen (same #pair-screen overlay).
        "account fields": all(f'id="{field}"' in ui for field in (
            "auth-user", "auth-pass", "auth-pass2", "auth-setup",
        )),
        "status drives mode": "/api/auth/status" in ui and "needs_setup" in ui
            and "authMode" in ui,
        # routes are built as '/api/auth/' + (reg ? 'register' : 'login')
        "register + login POST": "'register' : 'login'" in ui and "function submitAuth(" in ui
            and "/api/auth/" in ui,
        "one-time setup capability": (
            "#setup=" in ui and "history.replaceState" in ui
            and "X-Opal-Setup-Token" in ui and "/^[0-9a-f]{64}$/" in ui
        ),
        "logout revokes session": "/api/auth/logout" in ui and "function unpair(" in ui,
        "sign-out button": 'id="signout"' in ui and "$('signout').onclick" in ui,
        "boot checks cookie session": "d.authed ? paired() : showAuth()" in ui,
        # The 6-digit pairing code is gone from the web UI.
        "no pairing code": "/pair?code=" not in ui and 'id="pair-code"' not in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "web auth UI incomplete: " + ", ".join(missing)
    return "pass", "web UI: account create/sign-in (status-driven), pairing code removed"


@test("Deploy profiles: TLS (Caddy) + Tailscale", "Auth")
def test_deploy_profiles():
    import os as _os
    def rd(p):
        fp = _os.path.join(PROJECT_DIR, p)
        return open(fp).read() if _os.path.exists(fp) else ""
    tls = rd("deploy/docker-compose.tls.yml")
    caddy = rd("deploy/Caddyfile")
    ts = rd("deploy/docker-compose.tailscale.yml")
    serve = rd("deploy/tailscale-serve.json")
    doc = rd("docs/headless-deploy.md")
    checks = {
        "caddy compose": "caddy:2" in tls and "opal" in tls and "443:443" in tls,
        "caddyfile proxies opal": "reverse_proxy opal:41595" in caddy and "{$DOMAIN}" in caddy,
        "tailscale sidecar": "tailscale/tailscale" in ts and "network_mode: service:tailscale" in ts
            and "TS_AUTHKEY" in ts,
        "tailscale serve → opal": "127.0.0.1:41595" in serve and "TS_CERT_DOMAIN" in serve,
        # Opal not directly published in the TLS profile (Caddy is the face).
        "opal internal in tls": "expose:" in tls,
        "docs cover access": "docker-compose.tls.yml" in doc and "docker-compose.tailscale.yml" in doc
            and "First-admin bootstrap" in doc and "X-Opal-Setup-Token" in doc,
        "proxy profiles require local bootstrap": (
            "local first-admin bootstrap with docker-compose.yml" in tls
            and "local first-admin bootstrap with docker-compose.yml" in ts
            and "Never send the setup credential through the proxy" in tls
            and "Never send the setup" in ts
        ),
        "proxy docs reuse bootstrapped config": (
            doc.count("Both profiles reuse data/config") == 2
            and doc.count("docker compose -f deploy/docker-compose.yml down") >= 2
        ),
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "deploy profiles incomplete: " + ", ".join(missing)
    return "pass", "deploy: Caddy TLS + Tailscale sidecar profiles + docs"
