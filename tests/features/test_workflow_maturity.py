"""Production wiring contracts; real offline workflows also run in CI."""
import subprocess
from pathlib import Path
import sys
from .harness import PROJECT_DIR, _src, test


@test("Workflow benchmark percentiles and owned process cleanup", "Performance")
def test_workflow_benchmark():
    result = subprocess.run([sys.executable, "tests/test_workflow_benchmark.py"],
                            cwd=PROJECT_DIR, capture_output=True, text=True, timeout=20)
    if result.returncode:
        return "fail", (result.stderr or result.stdout)[-1400:]
    return "pass", "Nearest-rank p95, sample counts, invalid CLI bounds, owned Windows process cleanup"


@test("Native HTTP guards connection establishment and resolver lifetime", "Network")
def test_native_http_lifetime():
    http = _src("src/core/http.zig")
    transport = _src("src/core/http_transport.zig")
    dns = _src("src/core/http_dns_native.zig")
    fixtures = _src("src/core/http_connection_native_test.zig")
    build = _src("build.zig")
    assert http.count("transport.nativeIo(") == 2
    assert "client.io.concurrent(fetchSignalled" in transport and "task.cancel(client.io)" in transport
    assert "task.await(client.io)" in transport and "req.sendBodyComplete" in transport
    for token in ("wrapped.netLookup = lookup", "CFHostCancelInfoResolution", "CFHostUnscheduleFromRunLoop",
                  "GetAddrInfoExCancel", "GetAddrInfoExOverlappedResult", "WaitForSingleObject"):
        assert token in dns, token
    for token in ("stalled TLS", "DNS pending", "empty POST", "next request succeeds", "concurrent native localhost"):
        assert token in fixtures, token
    assert 'b.step("test-native-http"' in build
    return "pass", "Scoped joined Io task; native DNS cancellation and resource teardown fixtures registered"


@test("Native desktop fixture and scroll matrix runs on all three platforms", "Performance")
def test_native_platform_matrix():
    workflow = _src(".github/workflows/ci.yml")
    build = _src("build.zig")
    gallery = _src("src/services/search_gallery_native_test.zig")
    # macOS runs the suite binary directly so a hang logs the stalled test.
    assert workflow.count("zig build test-native-ui") == 2
    assert "zig build build-native-ui" in workflow and "./zig-out/bin/opal-native-ui-tests" in workflow
    assert 'b.step("build-native-ui"' in build and '"opal-native-ui-tests"' in build
    assert workflow.count("zig build test-native-http") == 3
    assert workflow.count("zig build test-native-downloads") == 3
    assert workflow.count("python3 tests/test_media_servers_live.py") + workflow.count("python tests/test_media_servers_live.py") == 3
    assert workflow.count("python3 tests/test_webcomic_sources_live.py") + workflow.count("python tests/test_webcomic_sources_live.py") == 3
    # Virtual X11 supports both rendering and the system-cursor calls exercised
    # by DVUI; the offscreen backend cannot create cursors.
    assert "SDL_VIDEODRIVER: x11" in workflow and "LIBGL_ALWAYS_SOFTWARE" in workflow
    assert 'xvfb-run -a -s "-screen 0 1920x1200x24" zig build test-native-ui' in workflow
    assert "-fsys=sdl2" in workflow
    assert 'b.step("test-native-ui"' in build and "run_native_suite" in build
    assert "resolver.MAX_RESULTS" in gallery and "120 warmed frames" in gallery
    assert ".code = .tab" in gallery and "focused_widget_id != null" in gallery
    assert "search.galleryTextRowsForTest() < rows.len" in gallery
    assert 'test "Native Search performance"' in _src("src/main.zig"), "performance filter must reach the imported test module"
    return "pass", "Native 1360/640 layouts, keyboard focus, maximum gallery scroll, and HTTP fixtures in each OS CI"


@test("Remaining native metadata requests use bounded transport and owned thumbnail jobs", "Network")
def test_remaining_metadata_transport():
    search = _src("src/services/search.zig").split("fn queryEztvApi(", 1)[1].split("pub fn submitQuery(", 1)[0]
    queue = _src("src/services/queue.zig").split("fn thumbWorker(", 1)[1].split("fn fetchQueueThumb(", 1)[0]
    youtube = _src("src/services/youtube.zig")
    piped = youtube.split("fn fetchViaPiped(", 1)[1].split("fn parsePipedResults(", 1)[0]
    thumb = youtube.split("pub fn fetchThumb(", 1)[1].split("// UI Rendering", 1)[0]
    suggestions = youtube.split("fn fireSuggest(", 1)[1].split("fn renderCatChip(", 1)[0]
    for name, body, seconds, size in (("EZTV", search, 5, "512 * 1024"),
                                     ("Queue artwork", queue, 8, "2 * 1024 * 1024"),
                                     ("Piped", piped, 5, "512 * 1024"),
                                     ("Suggestions", suggestions, 3, "64 * 1024")):
        assert 'http.zig").fetch(' in body, name
        assert ".request(" not in body and "allocRemaining(" not in body, name
        assert f".timeout_secs = {seconds}" in body, name
        assert ".max_response = buffer.len" in body and size in body, name
    transport = youtube.split("fn fetchThumbnailBody(", 1)[1].split("pub fn fetchThumb(", 1)[0]
    assert 'http.zig").fetchDirect(' in transport and '.timeout_secs = 3' in transport
    assert 'reliable_fetch.zig").fetch(' in transport and '.timeout_secs = 5' in transport
    assert '.connect_timeout_secs = 2' in transport and transport.count('.cancel_epoch = cancel') == 2
    assert 'fetchThumbnailBody(turl, buffer,' in thumb and 'alloc.alloc(u8, 1024 * 1024)' in thumb
    assert "copyValue(\"eztv\"" in search and "&search_generation" in search
    assert "&search_request.generation" in piped and "&sugg_gen" in suggestions
    assert "fn worker(request: ThumbRequest)" in thumb and ".{job}" in thumb
    assert "thumbnailCanPublish" in thumb and "thumbnailOwnerMatches" in thumb
    assert "&search_request.generation" in thumb and "row.thumb_request_id" in thumb
    assert "ptr: *state.YtItem" not in thumb, "workers must not retain mutable result pointers"
    assert "yt_mutex.lock()" in thumb and "releaseSlot()" in thumb
    pure = _src("src/services/youtube_pure.zig")
    assert "current_generation == generation and thumbnailOwnerMatches" in pure
    assert "request != 0 and row_request == request" in pure
    return "pass", "Five bounded heap-backed requests; search/suggestion epochs and exact owned thumbnail publication"


@test("Native Browse requests avoid render-thread HTTP and repeated local SQL", "Performance")
def test_native_browse_responsiveness():
    plugins = _src("src/services/plugins.zig")
    submit = plugins.split("fn suwaTest() void {", 1)[1].split("fn suwaTestWorker", 1)[0]
    worker = plugins.split("fn suwaTestWorker", 1)[1].split("fn setSuwaMsg", 1)[0]
    assert 'copyValue("suwayomi", "base", &job.base)' in submit
    assert "spawnLegacy(suwaTestWorker" in submit and "fetch(" not in submit
    assert 'http.zig").fetch' in worker and "status_out" in worker
    assert "child.wait" not in worker and "Child.init" not in worker
    assert "generation != suwa_message_generation" in plugins
    assert "verifySuwaNonblockingForTest" in plugins
    assert '"Native Browse"' in _src("build.zig")
    assert 'try @import("services/plugins.zig").verifySuwaNonblockingForTest();' in _src("src/main.zig")
    native = _src("src/ui/local_library_ui.zig")
    snapshot = native.split("fn snapshotWorker", 1)[1].split("pub fn deinit", 1)[0]
    assert "allocator.create(Snapshot)" in snapshot
    assert "library.listRoots" in snapshot and "library.search" in snapshot
    assert "layout.acceptsSnapshot(requested_key, key, library.revision())" in snapshot
    assert "spawnLegacy(snapshotWorker" in native and "snapshot.?.key.eql(key)" in native
    assert "Loading indexed files" in native
    pure = _src("src/ui/local_library_layout_pure.zig")
    assert "for (0..120)" in pure and "current_revision == completed.revision" in pure
    service = _src("src/services/local_library.zig")
    assert "data_revision.fetchAdd" in service and "if (batch_count == 0) changed()" in service
    main = _src("src/main.zig")
    assert "local_library_ui.zig" in main and ".deinit()" in main
    return "pass", "Owned cancellable server test and revision-keyed heap local snapshots; stale publication rejected"


@test("Audio Browse publishes independent directories and albums progressively", "Performance")
def test_audio_browse_progressive():
    podcasts = _src("src/services/podcasts.zig")
    assert 'browse_fanout.zig").run' in podcasts and ".limit = 4" in podcasts
    assert "copyFields(\"feed\", &group.feeds)" in podcasts
    assert "group.next_feed.fetchAdd" in podcasts and "publishDirectoryPart(group" in podcasts
    assert "search_request.isCurrent(group.job.generation)" in podcasts
    assert "group.progress.clearOnFinish()" in podcasts and "group.progress.accept" in podcasts
    radio = _src("src/services/radio.zig")
    assert 'browse_fanout.zig").run' in radio and ".limit = 3" in radio
    assert "pure.appendUnique(&state.app.radio.results" in radio
    assert "defer appendSoma" not in radio
    assert "fetchBodyForGeneration" in radio and ".cancel_epoch" in radio
    music = _src("src/services/music_discovery.zig")
    assert 'browse_fanout.zig").run' in music and ".limit = 4" in music
    worker = music.split("fn fetchArtistAlbums", 1)[1].split("// ═", 1)[0]
    assert "pub_mutex.lock()" in worker and "state.wakeUi()" in worker
    for path in ("src/ui/podcasts_ui.zig", "src/services/radio.zig", "src/services/music_subsonic.zig"):
        assert "components.coverSkeletonGrid" in _src(path)
    assert (Path(PROJECT_DIR) / "tests/test_audio_browse_progressive_live.py").exists()
    return "pass", "Bounded shared fanout, independent incremental publication, retained refresh data and common skeleton grids"


@test("Gutenberg categories merge into progressive typed-reader discovery", "Performance")
def test_gutenberg_discover_feed():
    opds = _src("src/services/opds.zig")
    pure = _src("src/services/opds_pure.zig")
    assert "pure.gutenbergSections(body, url, sections)" in opds
    assert "runGutenbergDiscovery" in opds and ".limit = 3" in opds
    assert "pure.mergeGutenbergWorks" in opds and "state.wakeUi()" in opds
    assert "discovery_next_len" in opds and "discoveryMoreWorker" in opds
    assert "openDiscoveryCategory" in opds and "discoverySnapshot" in opds
    assert "pure.gutenbergWorkId(href)" in opds and 'novels.zig").openCatalogResult' in opds
    assert "media_card.skeletonGrid(@src(), 88000" in opds
    # curl fallback = reliable-fetch seam; Basic auth over stdin config.
    assert "opdsGetCancelled" in opds and 'reliable_fetch.zig").fetch(' in opds
    assert ".secret_headers = secret[0..secret_n]" in opds and ".cancel_epoch = cancellation" in opds
    assert "verifyGutenbergProgressiveForTest" in opds
    assert "isGutenbergCatalogRoot" in pure and "www.gutenberg.org.evil.test" in pure
    assert "mergeGutenbergWorks" in pure and "gutenbergWorkId" in pure
    return "pass", "Official advertised Popular/Latest/Random, progressive deduped works, scoped filters/cursors and native reader"


@test("Audio cache snapshots release publication locks before disk and serialize wave starts", "Performance")
def test_audio_browse_cache_lock_scope():
    for kind in ("podcasts", "radio"):
        service = _src(f"src/services/{kind}.zig")
        writer = service.split("fn putPopularCache(", 1)[1].split("/// SWR read", 1)[0]
        assert "defer parse_mutex.unlock()" in writer
        assert writer.index("}\n    const blob") < writer.index("content_cache.put"), kind
        popular = service.split("pub fn loadPopularOnce", 1)[1].split("fn popularWorker", 1)[0]
        assert "seedPopularFromCache();" not in popular, kind
        assert popular.index("parse_mutex.lock()") < popular.index("search_request.begin"), kind
        assert "seedPopularFromCache(job.generation)" in service, kind
        search = service.split("pub fn search" + ("Podcasts" if kind == "podcasts" else "Radio"), 1)[1]
        search = search.split("fn searchWorker", 1)[0]
        assert search.index("parse_mutex.lock()") < search.index("search_request.begin"), kind
    opds = _src("src/services/opds.zig")
    assert "if (append) for (categories" in opds
    assert "group.next_len[index] = category.href_len" in opds
    assert "group.next_len[index] = 0" in opds
    return "pass", "Cache file reads/writes are worker-only outside publication locks; stale starts/cursors guarded"


@test("OPDS reader actions use copied identity and publication revision", "Performance")
def test_opds_action_publication_identity():
    opds = _src("src/services/opds.zig")
    assert "var catalog_revision: u32" in opds and "pub fn catalogGeneration() u32" in opds
    snapshot = opds.split("fn copiedEntryAction", 1)[1].split("pub fn openEntryExpected", 1)[0]
    assert "parse_mutex.lock()" in snapshot and "generation != catalog_revision" in snapshot
    assert "configured_connection.identity" in snapshot
    card = opds.split("fn renderEntryCard", 1)[1].split("/// Real local HTTP fixture", 1)[0]
    assert "copiedEntryAction(idx, null)" in card
    assert "openCatalogEntry(action.row, action.connection_identity)" in card
    assert "openEntry(idx)" not in card
    assert 'else "Project Gutenberg"' in card
    return "pass", "Rendered immutable work and matching credential identity; replacement invalidates stale reader index"


@test("Torrent worker handoff retires GPU state on owner frame", "Performance")
def test_torrent_gpu_owner_handoff():
    state = _src("src/core/state.zig")
    search = _src("src/services/search.zig")
    browser = _src("src/services/browser.zig")
    fixture = _src("src/services/torrent_handoff_native_test.zig")
    consume = state.split("pub fn consumePendingPlay", 1)[1].split("pub fn drainPendingPlay", 1)[0]
    assert "takePendingPlay()" in consume and "onPlayOwnerThread()" in consume
    assert "pending_metadata" in consume and "deinitPoster" not in consume
    drain = state.split("pub fn drainPendingPlay", 1)[1].split("pub fn applyPendingPlay", 1)[0]
    assert "p.lifetime_id == entry.lifetime" in drain and "p.load_serial == entry.serial" in drain
    stage = search.split("fn attachTorrentToPlayer(tid", 1)[1].split("fn attachTorrentToPlayerOwned", 1)[0]
    assert "!state.onPlayOwnerThread()" in stage and "takeTorrentMetadata()" in stage
    assert "p.attachTorrent" not in stage and "mpv_command_string" not in stage
    assert "pending_torrent_metadata[slot] = takeTorrentMetadata()" in search
    assert "owned_torrent_metadata = pending.metadata" in search
    for entrypoint in ("pub fn loadTorrentToPlayer", "fn addMagnetToEngine", "pub fn addTorrentFileToEngine"):
        entry = search.split(entrypoint, 1)[1]
        assert entry.index("!state.onPlayOwnerThread()") < entry.index("state.app.players")
    assert "metadata: ?state.PendingPlay" in browser
    assert "owned_direct_metadata = owned.metadata" in browser
    direct = browser.split("pub fn playDirect", 1)[1].split("// Start the end-to-end", 1)[0]
    assert "!state.onPlayOwnerThread()" in direct and "deferPlayback(request)" in direct
    for token in ("textureCreate", "std.Thread.spawn", "fixture.load_serial += 1", "fixture.lifetime_id += 1", "https://fixture.invalid/poster.jpg"):
        assert token in fixture, token
    return "pass", "Real GPU worker regression; queued immutable metadata with lifetime/serial validation and owner drain"


@test("Coming-up sync fans out per show and commits cards in library order", "Performance")
def test_tv_sync_fanout():
    # The /3/tv/{id} pass ran one show at a time: 36 tracked shows took ~35s
    # before Home's Coming-up rail published. Shows now sync on bounded lanes,
    # but cards still commit in tvGetShows order so the 12 rail slots go to the
    # same shows a sequential pass picked.
    lib = _src("src/services/tv_library.zig")
    cal = _src("src/services/tv_calendar.zig")
    worker = lib.split("fn syncWorker() void {", 1)[1].split("fn syncShow(", 1)[0]
    run = 'browse_fanout.zig").run(SyncJob'
    checks = {
        "bounded fan-out": run in worker and "SYNC_LANES" in worker,
        "ordered commit after join": run in worker and "cal.commitOrdered(cards" in worker
            and worker.index(run) < worker.index("cal.commitOrdered(cards"),
        "heap rows, not thread stack": "alloc.alloc(db.TvShowRow, MAX_SHOWS)" in worker,
        "atomic tallies": "updated.fetchAdd" in lib and "learned_imdb.store(true, .release)" in lib,
        # stage/stageFacts build a card; only commitOrdered touches the projection,
        # through the unit-tested CalendarProjection.stageOrdered (order, slots,
        # EZTV selection are covered in tv_calendar_pure.zig).
        "cards built off the projection": "pub fn stage(" in cal and "pub fn stageFacts(" in cal
            and "projection.add(" not in cal
            and "projection.stageOrdered(" in cal.split("pub fn commitOrdered(", 1)[1],
        "eztv only for slotted cards": "pub fn stageOrdered(" in _src("src/services/tv_calendar_pure.zig"),
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "tv sync fan-out incomplete: " + ", ".join(missing)
    return "pass", "shows sync on 4 lanes; cards commit in library order; EZTV only for rail slots"


@test("Poster cache reads use parallel read-only connections", "Performance")
def test_poster_cache_readers():
    # Cold-start profile: poster workers spent ~4x longer waiting on cache_lock
    # (and the FULLMUTEX shared connection the UI thread also uses) than reading
    # the blob. WAL lets read-only side connections run in parallel.
    dbz = _src("src/core/db.zig")
    poster = _src("src/core/poster.zig")
    load = poster.split("fn cacheLoad(key: i64) ?[]u8 {", 1)[1].split("const CACHE_SELECT", 1)[0]
    deinit = dbz.split("pub fn deinit() void {", 1)[1].split("\n}\n", 1)[0]
    checks = {
        "read-only nomutex slots": "SQLITE_OPEN_READONLY | c.SQLITE_OPEN_NOMUTEX" in dbz,
        "atomic slot claim": "reader_claimed[i].swap(true, .acq_rel)" in dbz,
        "gated on schema ready": "readers_ready.store(true, .release)" in dbz,
        "closed on shutdown": "sqlite3_close_v2(h)" in deinit and "readers_ready.store(false" in deinit,
        "poster reads via reader": load.index("db.acquireReader()") < load.index("cache_lock.lock()"),
        "reader released": "db.releaseReader(reader)" in load,
        "shared fallback kept": "db.prepare(CACHE_SELECT)" in load,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "poster cache reader pool incomplete: " + ", ".join(missing)
    return "pass", "cache hits read on up to 8 read-only WAL connections; shared connection is the fallback"


@test("Release jobs vendor ONNX Runtime from Microsoft's NuGet package, hash-pinned", "Build")
def test_release_onnxruntime_vendor():
    # Regression: github.com/microsoft/onnxruntime stopped serving release
    # archives (Nov 2026) and the v0.9.7 Linux and Windows builds hit 404.
    wf = _src(".github/workflows/release.yml")
    sh = _src("scripts/vendor-onnxruntime.sh")
    checks = {
        "no GitHub release archive URL": "microsoft/onnxruntime/releases/download" not in wf,
        "linux job uses the script": "scripts/vendor-onnxruntime.sh linux 1.20.1" in wf,
        "windows job uses the script": 'scripts/vendor-onnxruntime.sh windows "$ORT_VER"' in wf and "ORT_VER=1.24.4" in wf,
        "nuget source": "api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime" in sh,
        "sha256 enforced": 'if [ "$got" != "$want" ]' in sh,
        "https only": "--proto '=https'" in sh,
        "linux soname recreated": "SONAME" in sh,
        "windows import library": "onnxruntime.lib" in sh,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "ONNX Runtime vendoring incomplete: " + ", ".join(missing)
    return "pass", "both release jobs fetch Microsoft's NuGet build, SHA-256 pinned"


@test("Release builds prefetch Zig packages with retries", "Build")
def test_release_zig_fetch_retry():
    # Regression: codeberg.org intermittently refused GitHub runners while
    # fetching translate-c/arocc; v0.9.7 lost macOS twice and Android once.
    rel = _src(".github/workflows/release.yml")
    apk = _src(".github/workflows/android-apk.yml")
    ipa = _src(".github/workflows/ios-ipa.yml")
    sh = _src("scripts/zig-fetch-retry.sh")

    def before(text, step):
        at = text.find(step)
        return at > 0 and "scripts/zig-fetch-retry.sh" in text[max(0, at - 200):at]

    checks = {
        "macOS before build": before(rel, "- name: Build .app bundle (ReleaseFast)"),
        "linux and windows before build": rel.count("scripts/zig-fetch-retry.sh\n      - name: Build (ReleaseSafe)") == 2,
        "android uses its build file": before(apk, "- name: Build APK") and "zig-fetch-retry.sh --build-file build-android.zig" in apk,
        "ios uses its build file": before(ipa, "- name: Build unsigned IPA") and "zig-fetch-retry.sh --build-file build-ios.zig" in ipa,
        "retries then fails": 'zig build --fetch "$@"' in sh and "exit 1" in sh and "ZIG_FETCH_ATTEMPTS" in sh,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "Zig package prefetch incomplete: " + ", ".join(missing)
    return "pass", "every release build fetches Zig packages up to 5 times before compiling"


@test("Every build file declares the build_options the source reads", "Build")
def test_build_options_parity():
    # Regression: #201 added build_options.fixture_seams to build.zig only, so
    # the v0.9.8 iOS and Android release builds failed to compile.
    import re
    used = set()
    for path in Path(PROJECT_DIR, "src").rglob("*.zig"):
        text = path.read_text(errors="ignore")
        used |= set(re.findall(r'(?<![\w.])build_options\.([a-z_]+)', text))
        used |= set(re.findall(r'@import\("build_options"\)\.([a-z_]+)', text))
    missing = []
    for build in ("build.zig", "build-ios.zig", "build-android.zig"):
        declared = set(re.findall(r'addOption\([^,]+,\s*"([a-z_]+)"', _src(build)))
        missing += [f"{build}:{k}" for k in sorted(used - declared)]
    if not used:
        return "fail", "found no build_options reads under src/"
    if missing:
        return "fail", "undeclared build options: " + ", ".join(missing)
    return "pass", f"{len(used)} build options declared by desktop, iOS and Android builds"


@test("Mobile re-attach runs can build a fixed commit for an existing tag", "Build")
def test_mobile_reattach_ref():
    # v0.9.8's tag could not build iOS/Android; tags are never moved, so the
    # re-attach dispatch takes an optional ref to build and uploads under the tag.
    for wf in ("ios-ipa.yml", "android-apk.yml"):
        text = _src(".github/workflows/" + wf)
        if "ref: ${{ inputs.ref || inputs.tag || github.ref }}" not in text or "      ref:\n" not in text:
            return "fail", wf + " has no optional ref input for re-attach builds"
    return "pass", "iOS and Android dispatches build inputs.ref, else the tag"


@test("Every referenced docs/ file exists and no stale plan docs return", "Docs")
def test_docs_references_resolve():
    import re
    root = Path(PROJECT_DIR)
    tracked = subprocess.run(["git", "ls-files"], cwd=PROJECT_DIR, capture_output=True,
                             text=True, check=True).stdout.split()
    scan = [p for p in tracked if p.endswith((".zig", ".md", ".py", ".yml", ".sh", ".ts", ".tsx", ".astro"))
            and not p.startswith(("zig-pkg/", "site/node_modules/"))
            and p not in ("CHANGELOG.md", "tests/features/test_workflow_maturity.py")]
    ref = re.compile(r"(?<![\w/.-])docs/([A-Za-z0-9_./-]+\.(?:md|json))")
    missing = set()
    for rel in scan:
        try:
            text = (root / rel).read_text(errors="ignore")
        except OSError:
            continue
        for m in ref.finditer(text):
            if "X.Y.Z" not in m.group(1) and not (root / "docs" / m.group(1)).exists():
                missing.add(f"{rel} -> docs/{m.group(1)}")
    stale = [p for p in ("docs/V2-ROADMAP.md", "docs/V2-PANEL.md", "docs/superpowers",
                         "docs/next-level-research.md", "docs/CHANGELOG.md") if (root / p).exists()]
    if missing or stale:
        return "fail", f"missing={sorted(missing)[:8]} stale={stale}"
    assert "## 🚀 v2 — active plan" in _src("ROADMAP.md")
    return "pass", f"{len(scan)} files scanned; docs/ references resolve; v2 plan lives in ROADMAP.md"


@test("Build timeouts stretch with machine load instead of failing busy boxes", "Build")
def test_load_scaled_timeout():
    from .harness import load_scaled_timeout as f
    cases = {
        "idle keeps base": f(300, load=0.5, cpus=8) == 300,
        "exactly saturated keeps base": f(300, load=8, cpus=8) == 300,
        "2x oversubscribed doubles": f(300, load=16, cpus=8) == 600,
        "capped at 4x so hangs still fail": f(300, load=700, cpus=8) == 1200,
        "build checks use it": "load_scaled_timeout(300)" in _src("tests/features/test_build.py")
                               and "BUILD_TIMEOUT = load_scaled_timeout(" in _src("tests/features/test_build.py"),
        "pixel probe uses it": _src("tests/features/test_player.py").count("load_scaled_timeout(") >= 3,
    }
    bad = [k for k, ok in cases.items() if not ok]
    return ("fail", ", ".join(bad)) if bad else ("pass", "300s budget -> up to 1200s at load/core >= 4")
