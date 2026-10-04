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
    assert workflow.count("zig build test-native-ui") == 3
    assert workflow.count("zig build test-native-http") == 3
    assert workflow.count("zig build test-native-downloads") == 3
    assert workflow.count("python3 tests/test_media_servers_live.py") + workflow.count("python tests/test_media_servers_live.py") == 3
    assert workflow.count("python3 tests/test_webcomic_sources_live.py") + workflow.count("python tests/test_webcomic_sources_live.py") == 3
    assert "xvfb-run" in workflow and "SDL_RENDER_DRIVER: software" in workflow
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
                                     ("YouTube artwork", thumb, 8, "5 * 1024 * 1024"),
                                     ("Suggestions", suggestions, 3, "64 * 1024")):
        assert 'http.zig").fetch(' in body, name
        assert ".request(" not in body and "allocRemaining(" not in body, name
        assert f".timeout_secs = {seconds}" in body, name
        assert ".max_response = buffer.len" in body and size in body, name
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
    assert 'browse_fanout.zig").run' in radio and ".limit = 2" in radio
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
    assert "components.coverSkeletonGrid" in opds
    assert "opdsGetCancelled" in opds and "StreamProcess.init" in opds
    assert 'curl_secret.zig").configLine' in opds and "process.child.closeStdin()" in opds
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
        assert "seedPopularFromCache(my_gen)" in service, kind
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
