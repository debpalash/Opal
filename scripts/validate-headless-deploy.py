#!/usr/bin/env python3
"""Scripted validation of a private Opal headless deployment.

Runs the headless server in a throwaway HOME/XDG layout that mirrors the
container (/config, /cache, /media) and checks, in order:

  startup      /health, owner-only setup.token, credential never logged
  bootstrap    first admin needs the setup.token header, local Host/Origin,
               and the token is single-use
  range        /stream Range/seek: 206 + exact Content-Range + exact bytes,
               served from the download mount (OPAL_DOWNLOAD_DIR)
  sse          /events: event-stream content type and a first data frame
  reconnect    a dropped SSE client reconnects; unauthenticated SSE is refused
  restart      SIGTERM exit, then the session, api.token and accounts survive
  https_proxy  Caddy (internal CA, no trust-store install) in front of a
               loopback OPAL_HTTPS_PROXY=1 server: verified TLS, Secure cookie,
               SSE and Range through the proxy
  expiry       an expired session and a logged-out session are both refused

Modes:
  --binary PATH   bare headless binary (default zig-out/bin/opal)
  --image IMAGE   the Docker image instead, when `docker` is available
                  (bind mounts the same three directories)

Never touches ~/.config/opal: every run uses a fresh temp root and a free
port. Secrets (setup.token, api.token, session cookies) are never printed.
Exit status is 0 only when every step passes (SKIP counts as non-failing).
No Tailscale actions: tailnet, Funnel, ACL and auth-key steps are manual only
(docs/headless-deploy.md).
"""
import argparse
import hashlib
import http.client
import json
import os
import shutil
import signal
import socket
import sqlite3
import ssl
import stat
import subprocess
import sys
import tempfile
import time
import urllib.parse

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = []
ADMIN_USER = "deployadmin"
ADMIN_PASS = "validate-" + os.urandom(6).hex()


def record(step, status, detail):
    RESULTS.append((step, status, detail))
    print(f"[{status}] {step}: {detail}", flush=True)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Fail(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise Fail(msg)


# ── HTTP helpers ──

class Client:
    def __init__(self, host, port, tls_ctx=None, server_name=None):
        self.host, self.port, self.tls_ctx = host, port, tls_ctx
        self.server_name = server_name or host

    def conn(self, timeout=10):
        if self.tls_ctx:
            return http.client.HTTPSConnection(self.host, self.port, timeout=timeout, context=self.tls_ctx)
        return http.client.HTTPConnection(self.host, self.port, timeout=timeout)

    def request(self, method, path, body=None, headers=None, timeout=10):
        h = {"Host": f"{self.server_name}:{self.port}"}
        h.update(headers or {})
        c = self.conn(timeout)
        try:
            c.request(method, path, body=body, headers=h)
            r = c.getresponse()
            data = r.read()
            return r.status, {k.lower(): v for k, v in r.getheaders()}, data
        finally:
            c.close()

    def sse_first_frame(self, cookie, timeout=12):
        c = self.conn(timeout)
        try:
            c.request("GET", "/events", headers={"Host": f"{self.server_name}:{self.port}", "Cookie": cookie})
            r = c.getresponse()
            ctype = r.getheader("Content-Type") or ""
            if r.status != 200:
                r.read()
                return r.status, ctype, b""
            deadline = time.time() + timeout
            buf = b""
            while time.time() < deadline and b"\n\n" not in buf:
                chunk = r.fp.readline()
                if not chunk:
                    break
                buf += chunk
            return r.status, ctype, buf
        finally:
            c.close()


def form(**kw):
    return urllib.parse.urlencode(kw).encode()


def session_cookie(headers):
    raw = headers.get("set-cookie", "")
    first = raw.split(";", 1)[0]
    return (first if first.startswith("opal_session=") else ""), raw


# ── Server runners ──

class BareRunner:
    """The headless binary with a container-shaped XDG layout."""

    def __init__(self, binary, root, port):
        self.binary, self.root, self.port = binary, root, port
        self.proc = None
        self.log_path = os.path.join(root, "server.log")

    def env(self, https_proxy):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("OPAL_", "XDG_"))}
        env.update({
            "HOME": os.path.join(self.root, "config"),
            "XDG_CONFIG_HOME": os.path.join(self.root, "config"),
            "XDG_CACHE_HOME": os.path.join(self.root, "cache"),
            "OPAL_HEADLESS": "1",
            "OPAL_DOWNLOAD_DIR": os.path.join(self.root, "media"),
        })
        if https_proxy:
            env["OPAL_HTTPS_PROXY"] = "1"
        return env

    def seed_port(self):
        # web_port lives in the config table; the schema uses IF NOT EXISTS.
        db = self.db_path()
        os.makedirs(os.path.dirname(db), exist_ok=True)
        con = sqlite3.connect(db)
        con.execute("CREATE TABLE IF NOT EXISTS config (key TEXT PRIMARY KEY, value TEXT NOT NULL DEFAULT '')")
        con.execute("INSERT OR REPLACE INTO config(key, value) VALUES('web_port', ?)", (str(self.port),))
        con.commit()
        con.close()

    def config_dir(self):
        return os.path.join(self.root, "config", "opal")

    def db_path(self):
        return os.path.join(self.config_dir(), "opal.db")

    def start(self, https_proxy=False):
        log = open(self.log_path, "ab")
        self.proc = subprocess.Popen([self.binary], cwd=REPO, env=self.env(https_proxy),
                                     stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        log.close()

    def stop(self, timeout=30):
        if not self.proc:
            return None
        t0 = time.time()
        try:
            os.killpg(self.proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            self.proc.wait(timeout)
            code = self.proc.returncode
        except subprocess.TimeoutExpired:
            os.killpg(self.proc.pid, signal.SIGKILL)
            self.proc.wait()
            code = None
        # Sidecars spawned into the same session.
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        self.proc = None
        return code, time.time() - t0

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def log_text(self):
        try:
            with open(self.log_path, "rb") as f:
                return f.read().decode("utf-8", "replace")
        except OSError:
            return ""


class DockerRunner(BareRunner):
    """Same checks against the image, bind-mounting the same directories."""

    def __init__(self, image, root, port):
        super().__init__("docker", root, port)
        self.image, self.name = image, "opal-validate-" + os.urandom(4).hex()

    def seed_port(self):
        pass  # the container listens on 41595; the host port is published

    def start(self, https_proxy=False):
        args = ["docker", "run", "-d", "--name", self.name, "--user", f"{os.getuid()}:{os.getgid()}",
                "-p", f"127.0.0.1:{self.port}:41595",
                "-v", f"{self.root}/config:/config", "-v", f"{self.root}/cache:/cache",
                "-v", f"{self.root}/media:/media"]
        # The proxy-mode container would force loopback inside its own netns;
        # the host-side Caddy cannot reach that, so Docker mode keeps the
        # basic profile and proxies to the published loopback port.
        args.append(self.image)
        subprocess.run(args, check=True, stdout=subprocess.DEVNULL)
        self.proc = True

    def stop(self, timeout=30):
        if not self.proc:
            return None
        t0 = time.time()
        r = subprocess.run(["docker", "stop", "-t", str(timeout), self.name], stdout=subprocess.DEVNULL)
        code = subprocess.run(["docker", "inspect", "-f", "{{.State.ExitCode}}", self.name],
                              capture_output=True, text=True).stdout.strip()
        with open(self.log_path, "ab") as log:
            subprocess.run(["docker", "logs", self.name], stdout=log, stderr=subprocess.STDOUT)
        subprocess.run(["docker", "rm", "-f", self.name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.proc = None
        return (int(code) if code.isdigit() and r.returncode == 0 else None), time.time() - t0

    def alive(self):
        return self.proc is not None

    def log_text(self):
        out = subprocess.run(["docker", "logs", self.name], capture_output=True, text=True)
        return out.stdout + out.stderr + super().log_text()


def wait_health(client, runner, timeout=90):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not runner.alive():
            raise Fail("server exited during startup")
        try:
            status, _, body = client.request("GET", "/health", timeout=3)
            if status == 200 and b'"ok":true' in body:
                return
        except OSError:
            pass
        time.sleep(0.5)
    raise Fail(f"/health not ready within {timeout}s")


def digest(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


# ── Steps ──

def step_startup(runner, client):
    runner.seed_port()
    runner.start()
    wait_health(client, runner)
    token_path = os.path.join(runner.config_dir(), "setup.token")
    check(os.path.exists(token_path), "setup.token missing on a fresh install")
    mode = stat.S_IMODE(os.stat(token_path).st_mode)
    check(mode == 0o600, f"setup.token mode is {oct(mode)}, want 0600")
    with open(token_path) as f:
        token = f.read().strip()
    check(len(token) == 64 and all(c in "0123456789abcdef" for c in token), "setup.token has the wrong shape")
    check(token not in runner.log_text(), "setup.token value appeared in the server log")
    status, _, body = client.request("GET", "/api/auth/status")
    check(status == 200 and json.loads(body).get("needs_setup") is True, "auth status does not report needs_setup")
    return token


def step_bootstrap(client, runner, token):
    creds = form(username=ADMIN_USER, password=ADMIN_PASS)
    ctype = {"Content-Type": "application/x-www-form-urlencoded"}
    status, _, _ = client.request("POST", "/api/auth/register", creds, ctype)
    check(status == 403, f"register without setup token returned {status}, want 403")
    status, _, _ = client.request("POST", "/api/auth/register", creds,
                                  dict(ctype, **{"X-Opal-Setup-Token": "0" * 64}))
    check(status == 403, f"register with a wrong setup token returned {status}, want 403")
    status, _, _ = client.request("POST", "/api/auth/register", creds,
                                  dict(ctype, **{"X-Opal-Setup-Token": token, "Origin": "https://evil.example"}))
    check(status == 403, f"cross-origin register returned {status}, want 403")
    status, headers, _ = client.request("POST", "/api/auth/register", creds,
                                        dict(ctype, **{"X-Opal-Setup-Token": token}))
    check(status == 200, f"register with the setup token returned {status}")
    cookie, raw = session_cookie(headers)
    check(cookie, "register did not issue a session cookie")
    check("HttpOnly" in raw and "SameSite=Strict" in raw, "session cookie lacks HttpOnly/SameSite")
    check(not os.path.exists(os.path.join(runner.config_dir(), "setup.token")), "setup.token not deleted after bootstrap")
    status, _, _ = client.request("POST", "/api/auth/register", form(username="second", password=ADMIN_PASS),
                                  dict(ctype, **{"X-Opal-Setup-Token": token}))
    check(status == 403, f"second register returned {status}, want 403 (single-use)")
    status, _, body = client.request("GET", "/api/auth/status", headers={"Cookie": cookie})
    check(json.loads(body).get("authed") is True, "fresh admin session not accepted")
    return cookie


def login(client):
    status, headers, _ = client.request("POST", "/api/auth/login", form(username=ADMIN_USER, password=ADMIN_PASS),
                                        {"Content-Type": "application/x-www-form-urlencoded"})
    check(status == 200, f"login returned {status}")
    cookie, raw = session_cookie(headers)
    check(cookie, "login did not issue a session cookie")
    return cookie, raw


def make_media(runner):
    data = os.urandom(65536)
    with open(os.path.join(runner.root, "media", "sample.mp4"), "wb") as f:
        f.write(data)
    return data


def step_range(client, cookie, data, label):
    size = len(data)
    path = "/stream?file=sample.mp4"
    status, _, _ = client.request("GET", path)
    check(status == 401, f"{label}: unauthenticated /stream returned {status}, want 401")
    status, headers, body = client.request("GET", path, headers={"Cookie": cookie})
    check(status == 200 and body == data, f"{label}: full GET returned {status}/{len(body)} bytes")
    check(headers.get("accept-ranges") == "bytes", f"{label}: no Accept-Ranges: bytes")
    cases = [("bytes=1000-1999", 1000, 1999), (f"bytes={size - 536}-", size - 536, size - 1),
             ("bytes=-100", size - 100, size - 1), ("bytes=0-0", 0, 0)]
    for rng, start, end in cases:
        status, headers, body = client.request("GET", path, headers={"Cookie": cookie, "Range": rng})
        check(status == 206, f"{label}: {rng} returned {status}, want 206")
        want = f"bytes {start}-{end}/{size}"
        check(headers.get("content-range") == want, f"{label}: {rng} Content-Range {headers.get('content-range')!r}, want {want!r}")
        check(body == data[start:end + 1], f"{label}: {rng} body bytes differ")
    status, _, _ = client.request("GET", "/stream?file=" + urllib.parse.quote("../config/opal/api.token"),
                                  headers={"Cookie": cookie})
    check(status != 200, f"{label}: traversal out of the media mount was served")


def step_identity(client, cookie):
    """The shared media identity on a hosted file: headless means the browser
    is the only target, so the card must offer "Play here" and never "Play on
    Opal" (there is no desktop player to send it to)."""
    status, _, body = client.request("GET", "/api/downloads", headers={"Cookie": cookie})
    check(status == 200, f"/api/downloads returned {status}")
    files = json.loads(body).get("files", [])
    sample = next((f for f in files if f.get("name") == "sample.mp4"), None)
    check(sample is not None, "sample.mp4 missing from /api/downloads")
    ident = sample.get("identity") or {}
    targets = ident.get("targets") or {}
    check(targets.get("here") == "direct" and targets.get("opal") is False,
          f"headless file targets {targets!r}, want here=direct opal=false")
    ids = [a.get("id") for a in ident.get("actions", [])]
    check(ids == ["play_here"], f"headless file actions {ids!r}, want ['play_here']")
    check(str(ident.get("key", "")).startswith("other:local:"), f"file identity key {ident.get('key')!r}")
    return "file identity: here=direct, opal=false, actions=[Play here]"


def step_sse(client, cookie, label):
    status, ctype, frame = client.sse_first_frame(cookie)
    check(status == 200, f"{label}: /events returned {status}")
    check(ctype.startswith("text/event-stream"), f"{label}: /events content-type {ctype!r}")
    check(b"data:" in frame, f"{label}: no SSE data frame within the timeout")


def step_reconnect(client, cookie):
    for _ in range(3):
        step_sse(client, cookie, "reconnect")
    status, _, _ = client.sse_first_frame("opal_session=" + "0" * 64)
    check(status == 401, f"SSE with a bogus session returned {status}, want 401")


def step_restart(runner, client, cookie):
    api_token = os.path.join(runner.config_dir(), "api.token")
    check(os.path.exists(api_token), "api.token not created")
    before = digest(api_token)
    with open(api_token) as f:
        bearer = f.read().strip()
    status, _, _ = client.request("GET", "/api/status", headers={"Authorization": "Bearer " + bearer})
    check(status == 200, f"api.token Bearer returned {status}")
    result = runner.stop()
    check(result is not None, "server was not running")
    code, secs = result
    check(code == 0 or code == -signal.SIGTERM, f"SIGTERM exit code {code}")
    runner.start()
    wait_health(client, runner)
    check(digest(api_token) == before, "api.token changed across restart")
    check(not os.path.exists(os.path.join(runner.config_dir(), "setup.token")), "setup.token recreated after restart")
    status, _, body = client.request("GET", "/api/auth/status", headers={"Cookie": cookie})
    state = json.loads(body)
    check(state.get("needs_setup") is False, "accounts lost across restart")
    check(state.get("authed") is True, "session lost across restart")
    return f"clean SIGTERM exit in {secs:.1f}s; session, account and api.token survived"


def caddy_ctx(storage):
    root = os.path.join(storage, "pki", "authorities", "local", "root.crt")
    deadline = time.time() + 20
    while time.time() < deadline and not os.path.exists(root):
        time.sleep(0.25)
    check(os.path.exists(root), "Caddy internal CA root not created")
    ctx = ssl.create_default_context(cafile=root)
    return ctx


def step_https_proxy(runner, plain, caddy_bin, docker_mode):
    if not caddy_bin:
        return "SKIP", "caddy not installed"
    https_port, http_port = free_port(), free_port()
    storage = os.path.join(runner.root, "caddy")
    caddyfile = os.path.join(runner.root, "Caddyfile")
    with open(caddyfile, "w") as f:
        f.write("{\n\tadmin off\n\tskip_install_trust\n\tauto_https disable_redirects\n"
                f"\thttp_port {http_port}\n\thttps_port {https_port}\n"
                f"\tstorage file_system {storage}\n}}\n"
                f"https://127.0.0.1:{https_port} {{\n\ttls internal\n"
                f"\treverse_proxy 127.0.0.1:{runner.port}\n}}\n")
    # Proxy mode: the same server restarted behind Caddy (Secure cookies,
    # loopback-only listener) exactly like the Caddy compose profile.
    if not docker_mode:
        runner.stop()
        runner.start(https_proxy=True)
        wait_health(plain, runner)
    env = dict(os.environ, XDG_DATA_HOME=storage, XDG_CONFIG_HOME=storage, HOME=storage)
    log = open(os.path.join(runner.root, "caddy.log"), "wb")
    caddy = subprocess.Popen([caddy_bin, "run", "--config", caddyfile, "--adapter", "caddyfile"],
                             env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    log.close()
    try:
        ctx = caddy_ctx(storage)
        tls = Client("127.0.0.1", https_port, tls_ctx=ctx)
        deadline = time.time() + 20
        while True:
            try:
                status, _, _ = tls.request("GET", "/health", timeout=3)
                if status == 200:
                    break
            except (OSError, ssl.SSLError):
                pass
            check(time.time() < deadline, "HTTPS /health not reachable through Caddy")
            time.sleep(0.3)
        # Verified TLS: an unverified context must not be needed.
        check(ctx.verify_mode == ssl.CERT_REQUIRED, "TLS verification disabled")
        cookie, raw = login(tls)
        if not docker_mode:
            check("Secure" in raw, "proxy-mode session cookie lacks Secure")
        step_sse(tls, cookie, "https")
        data = open(os.path.join(runner.root, "media", "sample.mp4"), "rb").read()
        step_range(tls, cookie, data, "https")
        return "PASS", ("verified TLS via Caddy internal CA; Secure cookie; SSE and Range through the proxy"
                        if not docker_mode else "verified TLS via Caddy; SSE and Range through the proxy")
    finally:
        os.killpg(caddy.pid, signal.SIGTERM)
        try:
            caddy.wait(10)
        except subprocess.TimeoutExpired:
            os.killpg(caddy.pid, signal.SIGKILL)


def step_expiry(runner, client):
    stale, _ = login(client)
    live, _ = login(client)
    revoked, _ = login(client)
    status, _, _ = client.request("POST", "/api/auth/logout", headers={"Cookie": revoked})
    check(status == 200, f"logout returned {status}")
    runner.stop()
    con = sqlite3.connect(runner.db_path())
    n = con.execute("UPDATE sessions SET expires_at=? WHERE token=?",
                    (int(time.time()) - 60, stale.split("=", 1)[1])).rowcount
    con.commit()
    con.close()
    check(n == 1, "could not locate the session row to expire")
    runner.start()
    wait_health(client, runner)
    for name, cookie, want in (("expired", stale, 401), ("logged-out", revoked, 401), ("live", live, 200)):
        status, _, _ = client.request("GET", "/api/status", headers={"Cookie": cookie})
        check(status == want, f"{name} session: /api/status {status}, want {want}")
        status, _, _ = client.request("GET", "/stream?file=sample.mp4", headers={"Cookie": cookie, "Range": "bytes=0-0"})
        check(status == (206 if want == 200 else 401), f"{name} session: /stream {status}")
    status, _, body = client.request("GET", "/api/auth/status", headers={"Cookie": stale})
    check(json.loads(body).get("authed") is False, "expired session still reported as authed")
    login(client)
    return "expired and logged-out sessions refused (API + /stream); live session kept; re-login works"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--binary", default=os.path.join(REPO, "zig-out", "bin", "opal"))
    ap.add_argument("--image", help="validate this Docker image instead of the bare binary")
    ap.add_argument("--caddy", default=shutil.which("caddy"))
    ap.add_argument("--keep", action="store_true", help="keep the temp root for inspection")
    ap.add_argument("--json", help="write step results to this file")
    args = ap.parse_args()

    docker_mode = bool(args.image)
    if docker_mode and not shutil.which("docker"):
        print("docker not available", file=sys.stderr)
        return 2
    if not docker_mode and not os.access(args.binary, os.X_OK):
        print(f"headless binary not found: {args.binary} (zig build -Dheadless=true)", file=sys.stderr)
        return 2

    root = tempfile.mkdtemp(prefix="opal-deploy-")
    for d in ("config", "cache", "media"):
        os.makedirs(os.path.join(root, d))
    port = free_port()
    runner = DockerRunner(args.image, root, port) if docker_mode else BareRunner(args.binary, root, port)
    client = Client("127.0.0.1", port)
    print(f"mode={'docker' if docker_mode else 'bare'} port={port} root={root}", flush=True)

    steps_ok = True
    cookie = None
    data = None
    try:
        def run(name, fn):
            nonlocal steps_ok
            try:
                out = fn()
                status, detail = out if isinstance(out, tuple) else ("PASS", out or "ok")
                record(name, status, detail)
                return status != "FAIL"
            except (Fail, OSError, ValueError, sqlite3.Error, subprocess.SubprocessError) as e:
                record(name, "FAIL", str(e))
                steps_ok = False
                return False

        token_box = {}
        if not run("startup", lambda: (token_box.setdefault("t", step_startup(runner, client)), "health 200; setup.token 0600, 64 hex, not logged")[1]):
            return 1
        box = {}
        if not run("bootstrap", lambda: (box.setdefault("c", step_bootstrap(client, runner, token_box.pop("t"))), "header-gated, origin-checked, single-use; token file removed")[1]):
            return 1
        cookie = box["c"]
        data = make_media(runner)
        run("range", lambda: (step_range(client, cookie, data, "direct"), "206 + exact Content-Range/bytes for 4 ranges from the download mount; 401 unauthenticated; traversal refused")[1])
        run("identity", lambda: step_identity(client, cookie))
        run("sse", lambda: (step_sse(client, cookie, "direct"), "text/event-stream with a data frame")[1])
        run("reconnect", lambda: (step_reconnect(client, cookie), "3 reconnects each get a frame; bogus session 401")[1])
        run("restart", lambda: step_restart(runner, client, cookie))
        run("https_proxy", lambda: step_https_proxy(runner, client, args.caddy, docker_mode))
        run("expiry", lambda: step_expiry(runner, client))
    finally:
        runner.stop()
        if args.json:
            with open(args.json, "w") as f:
                json.dump([{"step": s, "status": st, "detail": d} for s, st, d in RESULTS], f, indent=2)
        if args.keep:
            print(f"kept {root}")
        else:
            shutil.rmtree(root, ignore_errors=True)
    failed = [s for s, st, _ in RESULTS if st == "FAIL"]
    print(f"{len(RESULTS) - len(failed)}/{len(RESULTS)} steps non-failing" + (f"; failed: {', '.join(failed)}" if failed else ""))
    return 0 if steps_ok and not failed else 1


if __name__ == "__main__":
    sys.exit(main())
