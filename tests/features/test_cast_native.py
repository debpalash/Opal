"""Native casting (Chromecast Cast v2, DLNA AVTransport) and the voice scene jump.

The integration checks drive the app's own network client (cast_net.zig,
through the `opal-cast-probe` tool) against fake receivers in tests/tools/
that bind 127.0.0.1 only. The probe refuses any non-loopback target, so no
check here can discover, cast to or command a real TV, speaker or Chromecast.
Real-device playback is UNVERIFIED by this suite.

The scene-jump check feeds transcript strings (not the microphone) through
scene_jump_pure.handleTranscript, the function the assistant runs.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

from .harness import *  # noqa: F401,F403

_PROBES = {}


def _probe(step, name):
    """Build a probe tool once per run; returns (path, None) or (None, reason)."""
    if name in _PROBES:
        return _PROBES[name]
    prefix = tempfile.mkdtemp(prefix="opal-probe-")
    r = subprocess.run(["zig", "build", step, "--prefix", prefix], cwd=PROJECT_DIR,
                       capture_output=True, text=True, timeout=600)
    exe = os.path.join(prefix, "bin", name + (".exe" if os.name == "nt" else ""))
    _PROBES[name] = (exe, None) if r.returncode == 0 and os.path.exists(exe) else (None, r.stderr[-1500:])
    return _PROBES[name]


def _start(argv):
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = proc.stdout.readline()
    if not line:
        proc.kill()
        raise RuntimeError("fake did not start: " + proc.stderr.read()[-500:])
    return proc, json.loads(line)


def _run(exe, *args, timeout=30):
    r = subprocess.run([exe, *[str(a) for a in args]], capture_output=True, text=True, timeout=timeout)
    lines = [json.loads(l) for l in r.stdout.splitlines() if l.strip()]
    return r.returncode, lines, r.stderr


def _log(path):
    with open(path) as f:
        return [json.loads(l) for l in f if l.strip()]


@test("Native Chromecast: mDNS + Cast v2 TLS load/pause/seek/status/stop on a loopback fake", "Casting")
def test_chromecast_fake_receiver():
    if os.name == "nt":
        return "skip", "fake receiver uses POSIX openssl"
    if not shutil.which("openssl"):
        return "skip", "openssl CLI needed to mint the fake receiver's certificate"
    exe, err = _probe("cast-probe", "opal-cast-probe")
    if not exe:
        return "fail", "cast-probe build failed: " + (err or "")
    with tempfile.TemporaryDirectory(prefix="opal-fake-cast-") as d:
        cert, key, log = (os.path.join(d, n) for n in ("cert.pem", "key.pem", "cast.log"))
        # RSA like a real Chromecast device certificate (and std's TLS 1.2 suites).
        mk = subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key,
                             "-out", cert, "-days", "1", "-subj", "/CN=fake-cast"], capture_output=True, timeout=60)
        if mk.returncode:
            return "skip", "openssl could not mint a certificate"
        proc, ports = _start([sys.executable, os.path.join(PROJECT_DIR, "tests/tools/fake_cast_receiver.py"),
                              "--cert", cert, "--key", key, "--log", log])
        try:
            tls, mdns = ports["tls_port"], ports["mdns_port"]
            rc, found, _ = _run(exe, "mdns", "127.0.0.1", mdns, 1200)
            if rc or len(found) != 1 or found[0]["name"] != "Fake Living Room" or found[0]["port"] != tls or found[0]["id"] != "fake01":
                return "fail", f"mDNS discovery: rc={rc} {found}"
            media = "http://192.168.1.5:50123/api/stream/abcd/tok/index.m3u8"
            steps = [
                (("load", media, 61, "application/x-mpegURL", "Heat"), True, "playing", 61),
                (("pause",), True, "paused", 61),
                (("seek", 754), True, "paused", 754),
                (("status",), True, "paused", 754),
                (("play",), True, "playing", 754),
                (("stop",), True, "idle", None),
                (("pause",), False, None, None),  # nothing loaded any more
            ]
            for args, ok, st, pos in steps:
                rc, out, errs = _run(exe, "cc", "127.0.0.1", tls, *args)
                if rc or len(out) != 1:
                    return "fail", f"{args[0]}: rc={rc} {errs[-300:]}"
                r = out[0]
                if r["ok"] != ok or (st and r["state"] != st) or (pos is not None and abs(r["position"] - pos) > 0.01):
                    return "fail", f"{args[0]}: {r}"
            for bad in (("cc", "192.168.1.20", 8009, "status"), ("mdns", "224.0.0.251", 5353)):
                rc, _, errs = _run(exe, *bad)
                if rc != 2 or "refusing non-loopback" not in errs:
                    return "fail", f"probe did not refuse {bad[1]}"
            entries = _log(log)
        finally:
            proc.kill()
            proc.wait(timeout=5)
    frames = [e for e in entries if "msg" in e]
    types = [(e["ns"].rsplit(".", 1)[-1], e["msg"].get("type")) for e in frames]
    load = next((e["msg"] for e in frames if e["msg"].get("type") == "LOAD"), None)
    seek = next((e["msg"] for e in frames if e["msg"].get("type") == "SEEK"), None)
    checks = {
        "TLS handshakes": not any("tls_error" in e for e in entries),
        "CONNECT before GET_STATUS": types[:2] == [("connection", "CONNECT"), ("receiver", "GET_STATUS")],
        "LAUNCH Default Media Receiver": any(e["msg"].get("type") == "LAUNCH" and e["msg"].get("appId") == "CC1AD845" for e in frames),
        "LOAD to the app transport": load is not None and any(e["dst"] == "web-7" and e["msg"].get("type") == "LOAD" for e in frames),
        "LOAD body": load is not None and load["media"]["contentId"] == media and load["media"]["contentType"] == "application/x-mpegURL"
            and load["media"]["hlsVideoSegmentFormat"] == "fmp4" and load["currentTime"] == 61 and load["media"]["metadata"]["title"] == "Heat",
        "SEEK carries mediaSessionId": seek is not None and seek["mediaSessionId"] == 1 and seek["currentTime"] == 754,
        "heartbeat PONG": ("heartbeat", "PONG") in types,
        "CLOSE on exit": ("connection", "CLOSE") in types,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "fake receiver saw: " + ", ".join(bad)
    # A receiver that rejects the media must surface as a failed cast.
    with tempfile.TemporaryDirectory(prefix="opal-fake-cast-") as d:
        cert, key, log = (os.path.join(d, n) for n in ("cert.pem", "key.pem", "cast.log"))
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key,
                        "-out", cert, "-days", "1", "-subj", "/CN=fake-cast"], capture_output=True, timeout=60)
        proc, ports = _start([sys.executable, os.path.join(PROJECT_DIR, "tests/tools/fake_cast_receiver.py"),
                              "--cert", cert, "--key", key, "--log", log, "--fail-load"])
        try:
            _, out, _ = _run(exe, "cc", "127.0.0.1", ports["tls_port"], "load", "http://192.168.1.5:1/x.mp4")
        finally:
            proc.kill()
            proc.wait(timeout=5)
    if not out or out[0]["ok"] or "could not load" not in out[0]["error"]:
        return "fail", f"LOAD_FAILED not reported: {out}"
    return "pass", f"discovery, {len(steps)} control steps, LOAD_FAILED; {len(frames)} frames checked (real devices UNVERIFIED)"


@test("Native DLNA: SSDP + description + AVTransport SOAP on a loopback fake renderer", "Casting")
def test_dlna_fake_renderer():
    exe, err = _probe("cast-probe", "opal-cast-probe")
    if not exe:
        return "fail", "cast-probe build failed: " + (err or "")
    with tempfile.TemporaryDirectory(prefix="opal-fake-dlna-") as d:
        log = os.path.join(d, "dlna.log")
        proc, ports = _start([sys.executable, os.path.join(PROJECT_DIR, "tests/tools/fake_dlna_renderer.py"), "--log", log])
        try:
            rc, found, _ = _run(exe, "ssdp", "127.0.0.1", ports["ssdp_port"], 1200)
            control = f"http://127.0.0.1:{ports['http_port']}/dev/control/AVTransport1"
            if rc or len(found) != 1 or found[0]["control"] != control or found[0]["name"] != "Fake Bedroom TV & Soundbar" \
                    or found[0]["id"] != "uuid:fake-renderer-0001":
                return "fail", f"SSDP discovery: rc={rc} {found}"
            media = "http://192.168.1.5:50123/api/stream/abcd/tok/direct?a=1&b=2"
            steps = [
                (("load", media, 754, "video/x-matroska", "A & B"), True, "playing"),
                (("pause",), True, "paused"),
                (("status",), True, "paused"),
                (("seek", 3723), True, None),
                (("play",), True, "playing"),
                (("stop",), True, "idle"),
                (("pause",), False, None),  # renderer refuses: not playing
            ]
            status_pos = None
            for args, ok, st in steps:
                rc, out, errs = _run(exe, "dlna", control, *args)
                if rc or len(out) != 1:
                    return "fail", f"{args[0]}: rc={rc} {errs[-300:]}"
                r = out[0]
                if r["ok"] != ok or (st and r["state"] != st):
                    return "fail", f"{args[0]}: {r}"
                if args[0] == "status":
                    status_pos = (r["position"], r["duration"])
            entries = _log(log)
        finally:
            proc.kill()
            proc.wait(timeout=5)
    acts = [e for e in entries if "action" in e]
    names = [a["action"] for a in acts]
    set_uri = next((a for a in acts if a["action"] == "SetAVTransportURI"), None)
    seeks = [a["args"]["Target"] for a in acts if a["action"] == "Seek"]
    checks = {
        "load = SetAVTransportURI, Play, Seek": names[:3] == ["SetAVTransportURI", "Play", "Seek"],
        "URI unescaped intact": set_uri is not None and set_uri["args"]["CurrentURI"] == media,
        "DIDL-Lite metadata": set_uri is not None and "<dc:title>A &amp; B</dc:title>" in set_uri["args"]["CurrentURIMetaData"]
            and "http-get:*:video/x-matroska:*" in set_uri["args"]["CurrentURIMetaData"],
        "REL_TIME targets": seeks == ["0:12:34", "1:02:03"],
        "GetPositionInfo parsed": status_pos == (754.0, 5400.0),
        "SOAP content type": all(a["content_type"].startswith("text/xml") for a in acts),
        "M-SEARCH for AVTransport": any("ST: urn:schemas-upnp-org:service:AVTransport:1" in e.get("ssdp", "") for e in entries),
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "fake renderer saw: " + ", ".join(bad)
    return "pass", f"discovery (chunked description, relative controlURL), {len(steps)} steps incl. a UPnP fault (real TVs UNVERIFIED)"


@test("Native casting wiring: pure wire formats, LAN listener, control/status API, couch-mode picker", "Casting")
def test_cast_native_wiring():
    cast, net, serve = _src("src/services/cast.zig"), _src("src/services/cast_net.zig"), _src("src/services/cast_serve.zig")
    pure, remote, build = _src("src/services/cast_pure.zig"), _src("src/services/remote.zig"), _src("build.zig")
    js, html, ops = _src("web/js/now-playing.js"), _src("web/index.html"), _src("src/services/ops_pure.zig")
    openapi, cast_api = _src("docs/openapi.json"), _src("src/services/remote_cast_api.zig")
    checks = {
        "pure modules in zig build test": all(f'"src/services/{m}_pure.zig"' in build for m in ("cast_v2", "dlna", "scene_jump")),
        "net routes through pure": all(f"cv2.{f}(" in net for f in ("encodeFrame", "decodeMessage", "parseInbound", "parseMdnsResponse", "buildMdnsQuery"))
            and all(f"dlna.{f}(" in net for f in ("buildMsearch", "parseSsdpResponse", "parseDescription", "soapEnvelope", "didlLite", "parseResponse")),
        "every exchange bounded": "fn bounded(" in net and "std.Io.Select" in net,
        "catt is gone": "catt" not in pure and '"catt"' not in cast,
        "multicast discovery in the app": "cv2.mdns_group" in cast and "dlna.ssdp_group" in cast,
        "local files via signed stream session": "session.create(" in cast and "pure.streamUrl(" in cast and "net.localAddressFor(" in cast,
        "LAN listener serves only signed paths": "pure.castServePath(path)" in serve and "handlePublic(" in serve and '"0.0.0.0"' in serve,
        "control + status routes": 'remote_cast_api.zig").handle(stream, api_path, query)' in remote
            and '"/cast/control"' in cast_api and '"/cast/status"' in cast_api
            and "cast.control(ctl, pos)" in cast_api and "cast.status(st)" in cast_api,
        "ops registry + openapi": '"cast_control"' in ops and '"cast_status"' in ops and '"/cast/control"' in openapi and '"/cast/status"' in openapi,
        "couch-mode picker": 'id="cast-remote"' in html and "/cast/control?action=" in js and "/cast/status" in js
            and "x.protocol === 'dlna'" in js,
    }
    bad = [k for k, v in checks.items() if not v]
    return ("fail", "missing: " + ", ".join(bad)) if bad else ("pass", f"{len(checks)} native casting wiring checks")


_SCENES = [
    {"moment_id": 11, "doc_id": 1, "start_secs": 754, "score": 0.9, "title": "Heat", "snippet": "Nobody move, this is a robbery",
     "keywords": ["rob", "bank"]},
    {"moment_id": 12, "doc_id": 1, "start_secs": 760, "score": 0.85, "title": "Heat", "snippet": "Get on the floor",
     "keywords": ["rob", "bank"]},  # same scene, overlapping window
    {"moment_id": 21, "doc_id": 1, "start_secs": 4210, "score": 0.8, "title": "Heat", "snippet": "the airport",
     "keywords": ["chase"]},
    {"moment_id": 22, "doc_id": 1, "start_secs": 5100, "score": 0.75, "title": "Heat", "snippet": "the chase ends",
     "keywords": ["chase"]},
    {"moment_id": 31, "doc_id": 2, "start_secs": 300, "score": 0.95, "title": "Ronin", "snippet": "car chase in Paris",
     "keywords": ["chase", "car"]},
]


@test("Voice scene jump: transcript string to seek target through the assistant path", "AI")
def test_scene_jump_transcript():
    exe, err = _probe("scene-jump-probe", "opal-scene-jump-probe")
    if not exe:
        return "fail", "scene-jump-probe build failed: " + (err or "")
    with tempfile.TemporaryDirectory(prefix="opal-scene-") as d:
        fx = os.path.join(d, "moments.json")
        with open(fx, "w") as f:
            json.dump(_SCENES, f)
        # Heat (doc 1) is playing.
        rc, out, errs = _run(exe, fx, 1,
                             "Hey Opal, jump to the scene where they rob the bank.",
                             "skip to the part where the chase starts",
                             "the second one",
                             "pause",
                             "take me to the moment when they hit the car chase")
        if rc or len(out) != 5:
            return "fail", f"rc={rc} {errs[-400:]}"
        rc2, other, _ = _run(exe, fx, 3, "go to the scene with the car in Paris")
    rob, ask, pick, pause, car = out
    checks = {
        "one scene: seek straight there": rob["action"] == "seek" and rob["start_secs"] == 754 and rob["moment_id"] == 11
            and rob["message"].startswith("Jumping to 12:34"),
        "several scenes: confirm first": ask["action"] == "ask" and ask["pending"] == 2 and "Which one?" in ask["message"]
            and "Ronin" not in ask["message"],  # the playing film's scenes win
        "answer picks without a new search": pick["action"] == "seek" and pick["start_secs"] == 5100 and not pick["searched"],
        "other commands untouched": pause["action"] == "ignore" and not pause["claimed"],
        "best in playing item": car["action"] in ("seek", "ask") and car.get("doc_id", 1) == 1,
        "not indexed here: open elsewhere": rc2 == 0 and other and other[0]["action"] == "open" and other[0]["doc_id"] == 2
            and other[0]["start_secs"] == 300,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "; ".join(bad) + " :: " + json.dumps(out)[:600]
    return "pass", "transcript to seek 12:34, confirm then pick 1:25:00, open elsewhere (microphone UNVERIFIED)"


@test("Voice scene jump wiring: assistant fast path, Recall search, active-player seek", "AI")
def test_scene_jump_wiring():
    ctx, sj, pure = _src("src/services/ai_context.zig"), _src("src/services/scene_jump.zig"), _src("src/services/scene_jump_pure.zig")
    fast = ctx[ctx.index("pub fn tryFastPath("):]
    checks = {
        "fast path claims before instant commands": 'scene_jump.zig").tryHandle(raw_input)' in fast
            and fast.index("tryHandle(raw_input)") < fast.index("tryInstantCommand(raw_input, fl)"),
        "production runs the pure turn": "pure.handleTranscript(" in sj and "pure.claims(" in sj,
        "Recall moment search is the searcher": "recall.search(query, results" in sj,
        "seek under players_mutex with index guard": "state.players_mutex.lock();" in sj
            and "state.app.active_player_idx >= state.app.players.items.len" in sj and "absolute+exact" in sj,
        "other item opens at the moment": "recall.target(0, o.cand.moment_id)" in sj and "recall.play(&t)" in sj,
        "pure tests": all(f'test "{t}' in pure for t in ("parseIntent", "decide", "parseReply", "handleTranscript")),
    }
    bad = [k for k, v in checks.items() if not v]
    return ("fail", "missing: " + ", ".join(bad)) if bad else ("pass", f"{len(checks)} scene-jump wiring checks")
