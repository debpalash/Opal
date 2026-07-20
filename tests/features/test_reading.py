"""Reading server (OPDS) client tests — Komga / Kavita / Calibre-Web / LANraragi.
See tests/features/harness.py for the shared @test decorator + helpers."""
from .harness import *  # noqa: F401,F403

# A captured Komga OPDS 1.2 (Atom/XML) acquisition feed — the shape the pure
# parser (src/services/opds_pure.zig) is exercised against in `zig build test`
# (test_opds_pure). Kept here as the documented sample; live-server connection
# still needs manual verification (no live OPDS server in CI).
SAMPLE_OPDS_FEED = """<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"
      xmlns:pse="http://vaemendis.net/opds-pse/ns">
  <title>Komga OPDS</title>
  <entry>
    <title>All series</title>
    <link rel="subsection" href="/opds/v1.2/series"
          type="application/atom+xml;profile=opds-catalog;kind=navigation"/>
  </entry>
  <entry>
    <title>Berserk Vol.1</title>
    <link rel="http://opds-spec.org/image/thumbnail" href="/covers/1/thumb.jpg" type="image/jpeg"/>
    <link rel="http://opds-spec.org/acquisition" href="/books/1/file"
          type="application/vnd.comicbook+zip"/>
    <!-- OPDS-PSE page stream: per-page images, Basic-auth on each fetch. -->
    <link rel="http://vaemendis.net/opds-pse/stream"
          href="/api/v1/books/1/pages/{pageNumber}?zero_based=true"
          type="image/jpeg" pse:count="24"/>
  </entry>
</feed>"""


@test("OPDS reading server client", "Reading")
def test_opds_reading_client():
    build = _src("build.zig")
    pure = _src("src/services/opds_pure.zig")
    svc = _src("src/services/opds.zig")
    st = _src("src/core/state.zig")
    cfg = _src("src/core/config.zig")
    drawer = _src("src/ui/drawer.zig")
    shell = _src("src/ui/shell.zig")
    settings = _src("src/ui/settings.zig")

    problems = []

    # 1) Pure module registered in the build.zig test step.
    if "opds_pure.zig" not in build or "test_opds_pure" not in build:
        problems.append("opds_pure not registered in build.zig test step")

    # 2) Pure module actually parses OPDS Atom feeds + classifies + routes.
    if not ("pub fn parseFeed" in pure and "pub fn classifyRel" in pure
            and "pub fn readerRoute" in pure and "pub fn basicAuthHeader" in pure
            and "pub fn resolveHref" in pure):
        problems.append("opds_pure missing parse/classify/route/auth/resolve helpers")

    # 3) Service routes THROUGH the pure module (no drift) — the shipped parse is
    #    the tested parse.
    if not ('@import("opds_pure.zig")' in svc and "pure.parseFeed" in svc
            and "pure.readerRoute" in svc and "pure.basicAuthHeader" in svc):
        problems.append("opds.zig does not route through opds_pure")

    # 4) Config keys for server / user / pass (persisted like the jf creds).
    for key in ("opds_url", "opds_user", "opds_pass"):
        if key not in cfg:
            problems.append(f"config key {key} missing")
    if "opds: struct" not in st or "opds_pure" not in st:
        problems.append("opds state struct missing")

    # 5) DrawerTab entry + render dispatch wired.
    if "pub const DrawerTab" not in st or "Opds" not in st:
        problems.append("DrawerTab.Opds not added to the enum")
    if ".Opds =>" not in drawer or "opds.zig" not in drawer:
        problems.append("drawer render dispatch for .Opds missing")
    if ".Opds =>" not in shell:
        problems.append("shell tabLabel/iconForTab arms for .Opds missing")

    # 6) Comics-reader reuse for image/comic books.
    if not ('@import("comics.zig").requestLoad' in svc and "navigateToTab(.Comics)" in svc):
        problems.append("image-book route does not reuse the comics reader")

    # 7) Settings connection section present (URL/user/pass + Test Connection).
    if "Reading server (OPDS)" not in settings or "Test Connection" not in settings:
        problems.append("Settings OPDS connection section missing")

    # 8) OPDS-PSE (Komga/Kavita) page streaming: the pure module parses the PSE
    #    link + count and builds per-page URLs; the sample feed carries one.
    if not ("pub fn parsePseCount" in pure and "pub fn pageUrl" in pure
            and "pub fn isPseStreamable" in pure and "opds-pse/stream" in pure):
        problems.append("opds_pure missing PSE parse/pageUrl/isPseStreamable helpers")
    if "opds-pse/stream" not in SAMPLE_OPDS_FEED or "{pageNumber}" not in SAMPLE_OPDS_FEED:
        problems.append("sample feed lost its OPDS-PSE stream link")

    # 9) opds.zig drives the PSE reader path THROUGH the pure fns, forwarding a
    #    Basic-auth header built via opds_pure.basicAuthHeader.
    if not ("isPseStreamable()" in svc and "loadPseBook" in svc
            and "opdsAuthHeader" in svc and "pure.basicAuthHeader" in svc):
        problems.append("opds.zig PSE route (isPseStreamable → loadPseBook + auth) not wired")

    # 10) comics.zig gained the localized auth hook + builds page URLs via the
    #     tested opds_pure.pageUrl, and forwards the header on the page fetch.
    comics = _src("src/services/comics.zig")
    if not ("pub fn loadPseBook" in comics and "opds_pure.pageUrl" in comics
            and "auth_header" in comics):
        problems.append("comics.zig missing loadPseBook / opds_pure.pageUrl / auth_header hook")
    # The page-fetch worker must actually add the auth header to its curl argv.
    if "state.app.comic.auth_header[0..state.app.comic.auth_header_len]" not in comics:
        problems.append("comics page fetch does not read the per-session auth header")
    if "auth_header" not in st:
        problems.append("comic state struct missing auth_header field")

    if problems:
        return "fail", "; ".join(problems)
    return ("pass", "OPDS client wired: pure parser routed, config keys, tab + dispatch, "
            "comics reuse, settings section, OPDS-PSE page streaming (parse + pageUrl + Basic-auth forwarded)")


@test("Comic reading position persists", "Reading")
def test_comic_resume():
    """A comic's last-read page must survive a restart, and reach home's
    Continue rail with a deep link that reopens the issue at that page.

    Mirrors the novels vertical: library_status ("comic_resume") is
    authoritative, library_items is the denormalized read-model cache."""
    comics = _src("src/services/comics.zig")
    pure = _src("src/services/comics_pure.zig")
    st = _src("src/core/state.zig")
    home = _src("src/ui/home.zig")
    build = _src("build.zig")

    checks = {
        # Pure, tested format/parse (no ad-hoc string surgery in the service).
        "pure deep link": "pub fn formatDeepLink" in pure and "pub fn parseDeepLink" in pure,
        "pure resume value": "pub fn formatResumePage" in pure and "pub fn parseResumePage" in pure,
        "pure resume key": "pub fn resumeKey" in pure,
        # Page 1 sits AT library_pure.CONTINUE_MIN_PCT (0.5, strict >), so the
        # floor decision is a tested pure function rather than an inline guess.
        "pure continue floor": "pub fn shouldRecordProgress" in pure,
        "pure tests registered": 'b.path("src/services/comics_pure.zig")' in build,
        # Authoritative store + read-model mirror, both routed through the pure fns.
        "authoritative store": 'librarySetStatus(RESUME_KIND' in comics,
        "resume kind": '"comic_resume"' in comics,
        "read-model mirror": '"comics",' in comics and "library_store" in comics,
        "routes through pure": "pure.formatDeepLink" in comics and "pure.resumeKey" in comics,
        # Page turns must not hit sqlite once per page.
        "debounced write": "RESUME_DEBOUNCE_MS" in comics,
        # The write path runs on the reader render path (no opt-in flag), and the
        # close path force-flushes so the final page always lands.
        "tick on render path": "tickResume(false)" in comics,
        "flush on close": "tickResume(true)" in comics,
        # Restore: armed on load, applied once pages stage.
        "arm on load": "armPendingResume(" in comics,
        "pending state field": "pending_resume_page" in st,
        "applies pending page": "fn applyPendingResume" in comics,
        # Reopen from home.
        "deep link opener": "pub fn openDeepLink" in comics,
        "home dispatch": '"comics"' in home and "services/comics.zig" in home,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "comic resume incomplete: " + ", ".join(missing)
    return "pass", "comic last-read page: library_status + debounced write + library_items mirror + deep-link reopen"


@test("Podcast listening position persists", "Reading")
def test_podcast_resume():
    """Episode POSITION is already owned by the generic mpv path
    (player.saveCurrentPosition -> history.savePlaybackPosition -> watch_history,
    keyed by the enclosure URL; player.tryResumePosition seeks back on reload).

    So the work here is IDENTITY: a real `podcast` library_items row (show +
    episode + artwork + a deep link that replays and resumes), reading the
    position back out of the authoritative store instead of duplicating it."""
    podcasts = _src("src/services/podcasts.zig")
    pure = _src("src/services/podcasts_pure.zig")
    st = _src("src/core/state.zig")
    dbz = _src("src/core/db.zig")
    home = _src("src/ui/home.zig")
    main = _src("src/main.zig")
    build = _src("build.zig")
    player = _src("src/player/player.zig")
    history = _src("src/services/history.zig")

    checks = {
        # The pre-existing position store this feature deliberately reuses.
        "mpv persists position": "saveCurrentPosition" in player and "savePlaybackPosition" in history,
        "mpv resumes position": "tryResumePosition" in player,
        "position read back, not duplicated": "watchGetProgress" in dbz and "watchGetProgress" in podcasts,
        "no second position store": "savePosition" not in podcasts,
        # Pure, tested deep link.
        "pure deep link": "pub fn formatDeepLink" in pure and "pub fn parseDeepLink" in pure,
        "pure tests registered": 'b.path("src/services/podcasts_pure.zig")' in build,
        # A real podcast row, not an anonymous playback entry.
        "read-model mirror": '"podcast",' in podcasts and "library_store" in podcasts,
        "carries show + artwork": "np_show" in podcasts and "np_art" in podcasts,
        "now-playing state": "np_url" in st and "np_active" in st,
        # The mirror runs on a path that actually executes every frame.
        "armed on play": "armNowPlaying(" in podcasts,
        "ticked from appFrame": "tickNowPlaying()" in main,
        "throttled": "NP_INTERVAL_MS" in podcasts,
        # Reopen from home.
        "deep link opener": "pub fn openDeepLink" in podcasts,
        "home dispatch": '"podcast"' in home and "services/podcasts.zig" in home,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "podcast resume incomplete: " + ", ".join(missing)
    return "pass", "podcast episode: reuses watch_history position + library_items podcast row + deep-link replay"
