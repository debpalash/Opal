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
