"""Parity tier 2 — the last seven desktop verticals reach the web UI.

Comics, Novels, Drama, VNDB, Audiobookshelf, OPDS, Plex and Logs. Two of these
needed the service to grow a public read API (their results were private module
vars), and two needed headless to pump a worker→UI publish seam it had no render
thread to drive — those are the checks worth keeping, not the route strings.

See tests/features/harness.py for the shared @test decorator + _src()."""
from .harness import *  # noqa: F401,F403


@test("Server logs exposed over HTTP", "Web UI")
def test_logs_route():
    rm = _src("src/services/remote.zig")
    ui = _src("web/index.html")
    checks = {
        "route + clear": "fn apiLogs(" in rm and '"/logs/clear"' in rm,
        # logCount()/getLog() are UNLOCKED accessors — a worker's pushLog evicts
        # and frees the oldest entry's slices mid-read without this.
        "serialized under lockRead": "logs.lockRead();" in rm and "logs.unlockRead();" in rm
            and rm.index("logs.lockRead();") < rm.index("logs.getLog(idx)")
            and rm.index("logs.getLog(idx)") < rm.index("logs.unlockRead();"),
        # mpv stderr / scraper output is untrusted bytes.
        "text sanitised": "escJsonWrite(&w, txt.safeUtf8(e.text));" in rm,
        "errors + limit filters": 'getQueryParam(query, "errors")' in rm
            and 'getQueryParam(query, "limit")' in rm,
        # 1024 entries can exceed 256KB of text.
        "response heap-allocated": "a.alloc(u8, 512 * 1024)" in rm,
        "tab wired": 'data-page="logs"' in ui and 'id="page-logs"' in ui
            and "async function loadLogs(" in ui and "logErrorsOnly" in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "logs route incomplete: " + ", ".join(missing)
    return "pass", "/api/logs: ring serialized under lockRead, level/error filters + tab"


@test("Headless pumps worker→UI publish seams", "Headless")
def test_headless_pumps_seams():
    hl = _src("src/headless.zig")
    dr = _src("src/services/drama.zig")
    cm = _src("src/services/comics.zig")
    # The recurring headless bug: a service's fetch worker stages results and the
    # RENDER path commits them. Headless has no render path, so the fetch
    # succeeded and the results never appeared. Each seam needs an explicit pump.
    checks = {
        "comics load drained": "comics.zig\").drainPendingLoad();" in hl
            and "pub fn drainPendingLoad()" in cm,
        "drama results drained": "drama.zig\").pumpPending();" in hl
            and "pub fn pumpPending()" in dr,
        # Every 100ms, not on the 2s bookkeeping tick — it's an atomic swap when
        # idle and a reader waiting on a comic page shouldn't eat 2s.
        "pumped every poll, not the slow tick": hl.index("drainPendingLoad();") < hl.index("const now_ms = io.milliTimestamp();"),
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "unpumped headless seams: " + ", ".join(missing)
    return "pass", "headless serve loop drains comics + drama publish seams"


@test("Private service results exposed through read APIs", "Web UI")
def test_service_read_apis():
    cm = _src("src/services/comics.zig")
    nv = _src("src/services/novels.zig")
    rm = _src("src/services/remote.zig")
    checks = {
        # comics: sr_* stay private (they also own cover pixels + GPU textures).
        "comics search accessors": "pub fn searchRow(" in cm and "pub fn searchCount(" in cm
            and "pub fn searching()" in cm,
        # sr_searching was a plain bool written by a worker; connection threads
        # poll it now too.
        "comics search flag atomic": "var sr_searching_v: std.atomic.Value(bool)" in cm,
        # novels: nr_*/ch_* are rewritten in place under parse_mutex, so the
        # accessors copy OUT under the same lock rather than handing back slices.
        "novels accessors copy under mutex": "pub fn resultRow(" in nv and "pub fn chapterRow(" in nv
            and nv.count("parse_mutex.lock();\n    defer parse_mutex.unlock();") >= 4,
        "novels rows are copies": "pub const ListRow = struct" in nv and "title_buf: [256]u8" in nv,
        "routes use them": "comics_svc.searchRow(i)" in rm and "nov.resultRow(i)" in rm,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "service read APIs incomplete: " + ", ".join(missing)
    return "pass", "comics + novels listings readable off-thread without exposing internals"


@test("Self-hosted server verticals (ABS, OPDS, Plex)", "Web UI")
def test_server_verticals():
    rm = _src("src/services/remote.zig")
    ui = _src("web/index.html")
    checks = {
        "routes exist": all(f"fn api{n}(" in rm for n in ("Abs", "Opds", "Plex")),
        "abs flow": all(f'"/abs/{s}"' in rm for s in ("login", "logout", "libraries", "open", "back", "play")),
        "opds flow": all(f'"/opds/{s}"' in rm for s in ("connect", "disconnect", "open", "back", "more")),
        # Plex sign-in is the PIN flow — there is no username/password route
        # because plex.zig has none.
        "plex pin flow": '"/plex/connect"' in rm and '\\"pin\\":\\"' in rm
            and "plex.tv/link" in ui,
        # opds user_buf/pass_buf are NUL-terminated with no _len companion.
        "opds creds nul-terminated": "o.user_buf[n] = 0;" in rm and "o.pass_buf[n] = 0;" in rm,
        "bad index is a 404": rm.count('sendJsonStatus(stream, "404 Not Found"') >= 5,
        "tabs render sign-in": all(f'id="page-{t}"' in ui for t in ("abs", "opds", "plex"))
            and 'id="abs-login"' in ui and 'id="opds-login"' in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "server verticals incomplete: " + ", ".join(missing)
    return "pass", "ABS/OPDS/Plex: browse+play routes and sign-in forms (server-gated)"


@test("Comics reader + Drama/VNDB/Novels tabs", "Web UI")
def test_reader_tabs():
    rm = _src("src/services/remote.zig")
    ui = _src("web/index.html")
    checks = {
        # Page <img> must carry the token in the query — it can't set a header.
        "reader uses token-in-query": "/api/comics/page?i=${i}&t=${encodeURIComponent(TOKEN)}" in ui,
        # Pages land out of order across 8 download workers, so only the
        # contiguous downloaded prefix is safe to render.
        "renders downloaded prefix": "length: d.downloaded" in ui,
        "reader closes server-side": "api('/comics/close')" in ui,
        # drama.zig has no search entry point — don't ship a box that can't work.
        "drama is browse-only": "fn apiDrama(" in rm and '"/drama/search"' not in rm
            and 'id="dr-q"' not in ui,
        # Every drama entry point no-ops without a TMDB key; say so.
        "drama explains a missing key": '\\"needs_tmdb_key\\":true' in rm
            and "needs_tmdb_key" in ui,
        # playSelected() takes no index.
        "drama play sets selected_idx": "d.selected_idx = idx;" in rm,
        # VNs aren't launchable — catalog only, no play route.
        "vndb has no play route": "fn apiVndb(" in rm and '"/vndb/play"' not in rm,
        "novels drill-down": all(f'"/novels/{s}"' in rm for s in ("search", "open", "chapter", "next", "prev")),
        "watchers cleaned": all(f"clearInterval({w})" in ui for w in
                                ("cxWatch", "cxPages", "nvWatch", "drWatch", "vnWatch", "absWatch", "opWatch", "plWatch")),
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "reader tabs incomplete: " + ", ".join(missing)
    return "pass", "Comics reader + Novels drill-down + Drama/VNDB catalogs"


@test("OPDS fetches through curl, not std.http", "Web UI")
def test_opds_curl_fetch():
    op = _src("src/services/opds.zig")
    checks = {
        # Measured against Project Gutenberg's live catalog: curl gets 200 over
        # BOTH https and http, while std.http's client.request failed at connect
        # for either scheme — so OPDS could not reach a server the rest of the
        # app talks to fine. tmdb_api.zig documents the same workaround.
        "fetches via curl": '"curl"' in op and '"-sL"' in op,
        "no std.http left": "http.fetch(" not in op and 'const http = @import("../core/http.zig")' not in op,
        # OPDS catalogs redirect constantly (Komga /opds → /opds/v1.2, http→https).
        "follows redirects": '"-sL"' in op,
        "request is bounded": '"--max-time"' in op,
        # basicAuthHeader yields a whole header line, which is what curl -H takes.
        "basic auth preserved": "pure.basicAuthHeader(user, pass, &auth_buf)" in op
            and '"-H",         a,' in op,
        "atom accept header": "Accept: application/atom+xml" in op,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "opds fetch incomplete: " + ", ".join(missing)
    return "pass", "OPDS over curl (-sL, bounded, Basic auth) — verified live against Gutenberg"


@test("Web UI consolidated to one file on one port", "Web UI")
def test_web_consolidation():
    import os as _os
    checks = {
        # The vestigial :3000 Zig web project is gone.
        "web/app deleted": not _os.path.exists(_os.path.join(PROJECT_DIR, "web/app")),
        "web build files deleted": not _os.path.exists(_os.path.join(PROJECT_DIR, "web/build.zig")),
        "index.html kept": _os.path.exists(_os.path.join(PROJECT_DIR, "web/index.html")),
        # remote.zig's header used to claim ":9876 + :3000" while listening on 41595.
        "remote header truthful": ":9876" not in _src("src/services/remote.zig"),
        "claude.md updated": ":3000" not in open(_os.path.join(PROJECT_DIR, "CLAUDE.md")).read(),
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "web consolidation incomplete: " + ", ".join(missing)
    return "pass", "one file (web/index.html), one port (:41595), no :3000 project"


@test("Container runs as a pinned non-root UID", "Headless")
def test_docker_numeric_uid():
    import os as _os
    df = open(_os.path.join(PROJECT_DIR, "Dockerfile")).read()
    checks = {
        # k8s runAsNonRoot inspects USER and cannot prove a NAME is non-root, so
        # a name-only USER makes the pod fail to schedule.
        "numeric USER": "USER 10001:10001" in df and "USER opal" not in df,
        "uid+gid pinned": "-u 10001" in df and "groupadd -g 10001" in df,
        "volumes owned numerically": "chown -R 10001:10001" in df,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "container user incomplete: " + ", ".join(missing)
    return "pass", "runs as uid/gid 10001 — satisfies k8s runAsNonRoot"


@test("Calendar fetches honour the DPI-bypass setting", "Page Shell")
def test_calendar_proxy_routing():
    ez = _src("src/services/eztv_calendar.zig")
    tv = _src("src/services/tv_calendar.zig")
    lh = _src("src/services/link_health.zig")
    # Both calendar fetchers hit eztv, which is exactly the kind of host ISP DPI
    # resets (curl exit 35 / http_code 000). Both hand-rolled their curl argv and
    # skipped proxyArgs(), so the user's "Bypass ISP blocking" toggle did nothing
    # for these rails. Measured after the fix on a throttled link: 9/15 requests
    # succeeded direct, 15/15 through the sidecar.
    checks = {
        "eztv calendar proxies": '@import("dpi_bypass.zig").proxyArgs()' in ez,
        "tv calendar proxies": '@import("dpi_bypass.zig").proxyArgs()' in tv,
        # URL must stay LAST in the argv, after any injected proxy flags.
        "url appended last": ez.count("argv[argc] = url;") == 1 and tv.count("argv[argc] = url;") == 1,
        # Same shape as the module that already did this correctly.
        "matches link_health pattern": '@import("dpi_bypass.zig").proxyArgs()' in lh,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "calendar proxy routing incomplete: " + ", ".join(missing)
    return "pass", "eztv + tv calendars route through the DPI-bypass sidecar when enabled"
