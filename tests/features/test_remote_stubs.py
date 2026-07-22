"""Routes that used to return hard-coded placeholders, now backed by real state.

`/api/recommendations`, `/api/party/*`, `/api/cast/*` and comic page images all
shipped as literal stubs (`{"items":[]}`, `{"connected":false}`, …) so the web UI
could be built against them. These checks pin them to the actual services and
guard the thread-safety each one needed to become real.

See tests/features/harness.py for the shared @test decorator + _src()."""
from .harness import *  # noqa: F401,F403


@test("Recommendations route backed by the For You engine", "Remote API")
def test_recommendations_route():
    rm = _src("src/services/remote.zig")
    checks = {
        "calls the real engine": "fn apiRecommendations(" in rm
            and 'rec = @import("recommendations.zig")' in rm
            and "rec.generateRecommendations()" in rm,
        "no placeholder left": '"{\\"items\\":[]}"' not in rm,
        # generateRecommendations snapshots state.app.players on the CALLING thread.
        "kicks under players_mutex": "state.players_mutex.lock();\n        rec.generateRecommendations();" in rm,
        # Kicking on `rec_count == 0` would re-kick forever for a user whose
        # history legitimately yields no picks — the client would poll `loading`
        # for good. Once per process, or ?refresh=1.
        "kicks once, not per-poll": "rec_kicked" in rm and 'getQueryParam(query, "refresh")' in rm,
        "emits title/reason/id": '\\"title\\":\\"' in rm and '\\"reason\\":\\"' in rm,
        # The worker writes rec_count/recommendations[] with no lock.
        "clamps the unlocked array": "@min(rec.rec_count, rec.recommendations.len)" in rm,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "recommendations route incomplete: " + ", ".join(missing)
    return "pass", "/api/recommendations: async kick + poll over recommendations.zig"


@test("Watch party + cast routes backed by real services", "Remote API")
def test_party_cast_routes():
    rm = _src("src/services/remote.zig")
    wp = _src("src/services/watch_party.zig")
    cast = _src("src/services/cast.zig")
    checks = {
        "single dispatcher": "fn apiPartyCast(" in rm
            and 'startsWith(u8, api_path, "/party/")' in rm
            and 'startsWith(u8, api_path, "/cast/")' in rm,
        # Both must answer with NOTHING playing — the players_mutex tail would
        # have short-circuited them with {"error":"no player"}.
        "dispatched before the player tail": rm.index("fn apiPartyCast(")
            and rm.index('apiPartyCast(stream, api_path, query)') < rm.index("state.players_mutex.lock();\n    defer state.players_mutex.unlock();"),
        "party status is real": "wp.statusText(" in rm and "wp.peerCount()" in rm
            and '\\"role\\":\\"{s}\\"' in rm and '"{\\"connected\\":false}"' not in rm,
        "peer count exported": "pub fn peerCount()" in wp and "clients_mutex.lock()" in wp,
        "party host/join/leave/chat": all(f'"/party/{s}"' in rm for s in ("host", "join", "leave", "chat", "status")),
        "cast devices are real": "cast.scanDevices()" in rm and "cast.devices[0..n]" in rm
            and '"{\\"devices\\":[]}"' not in rm,
        "cast start/stop/scan": all(f'"/cast/{s}"' in rm for s in ("start", "stop", "scan", "devices")),
        # cast.zig used to reach into state.app.players itself, unlocked.
        "cast url passed by value": "pub fn castTo(device_idx: usize, url: []const u8)" in cast
            and "pub fn castActive(" in cast,
        "cast start holds players_mutex": "state.players_mutex.lock();\n        cast.castActive(idx);" in rm,
        # Worker threads write these; UI + connection threads poll them.
        "cast flags atomic": "pub var is_scanning: std.atomic.Value(bool)" in cast
            and "pub var is_casting: std.atomic.Value(bool)" in cast,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "party/cast routes incomplete: " + ", ".join(missing)
    return "pass", "/api/party/* + /api/cast/* backed by watch_party.zig + cast.zig"


@test("Comic page images served over HTTP", "Remote API")
def test_comic_page_route():
    rm = _src("src/services/remote.zig")
    rs = _src("src/services/remote_stream.zig")
    cm = _src("src/services/comics.zig")
    cp = _src("src/services/comics_pure.zig")
    checks = {
        # <img> can't send an Authorization header → ?t= token, same as /poster.
        "token-in-query media route": '"/api/comics/page"' in rm and "rs.handleComicPage(stream, i)" in rm,
        "handler serves the bytes": "pub fn handleComicPage(" in rs and "comics.copyPage(idx, alloc)" in rs,
        # page_pixels holds the ORIGINAL encoded bytes — sniff, don't guess.
        "mime sniffed": "imageMime(bytes)" in rs and "pub fn imageMime(" in cp,
        "mime unit-tested": cp.count('test "comic page mime') >= 2,
        # loadComic frees page_pixels on the UI thread while a connection thread
        # may be mid-copy — the dl_gen/dl_in_flight protocol only fences workers.
        "reader lock": "pub fn copyPage(" in cm and "pages_mutex.lock()" in cm
            and "UAF guard #3" in cm,
        "not-yet-downloaded is a 404": "orelse return send404(stream)" in rs,
        # The reader polls `downloaded` to know which indices answer 200.
        "status exposes progress": '\\"downloaded\\":{d}' in rm and '\\"title\\":\\"' in rm,
        # closeComic frees dvui textures → UI thread only.
        "close deferred to ui thread": '"/comics/close"' in rm and "pub fn requestClose()" in cm
            and "pending_close.swap(false, .acq_rel)" in cm,
        # The desktop drains from appFrame(); headless has no frame loop, so
        # without this the load/close routes answered {"ok":true} and the
        # pending flag was never acted on.
        "headless drains the deferral": "drainPendingLoad()" in _src("src/headless.zig"),
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "comic page serving incomplete: " + ", ".join(missing)
    return "pass", "/api/comics/page: mime-sniffed bytes under a reader lock + status progress"
