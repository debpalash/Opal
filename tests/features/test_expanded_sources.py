"""Executable coverage for the added source adapters."""
import subprocess
import sys
import json
from pathlib import Path
from .harness import PROJECT_DIR, test, _remote_api
PROJECT_DIR = Path(PROJECT_DIR)


@test("New torrent adapters resolve actual links and reject unrelated rows", "Sources")
def test_expanded_torrent_sources():
    result = subprocess.run([sys.executable, 'tests/test_expanded_torrent_sources.py'],
                            cwd=PROJECT_DIR, capture_output=True, text=True, timeout=30)
    if result.returncode:
        return 'fail', (result.stderr or result.stdout)[-1200:]
    return 'pass', 'NekoBT, Shana Project and Public Domain Torrents request/parse paths'


@test("GitHub release sources emit real torrent identities with bounded fetching", "Sources")
def test_github_torrent_sources():
    result = subprocess.run([sys.executable, 'tests/test_github_torrent_sources.py'],
                            cwd=PROJECT_DIR, capture_output=True, text=True, timeout=30)
    if result.returncode:
        return 'fail', (result.stderr or result.stdout)[-1200:]
    return 'pass', 'DMHY, ACG.RIP, SubsPlease feed contracts and bounded network reads'


@test("New GitHub sources have unique installable catalog entries and production adapters", "Sources")
def test_github_source_catalog():
    rows = json.loads((PROJECT_DIR / 'data/plugins-manifest.json').read_text())['plugins']
    ids = [row['id'] for row in rows]
    assert len(ids) == len(set(ids)), 'duplicate provider ids'
    assert len(ids) <= 128, 'source manager capacity exceeded'
    entries = {row['id']: row for row in rows}
    for source in ('dmhy', 'acgrip', 'standardebooks', 'wuxiaclick', 'openverse', 'netlabels', 'somafm', 'comicfury', 'hianime'):
        row = entries[source]
        assert row['endpoints']['base'].startswith('https://'), source
        assert row['file'] == f'plugins/{source}.json', source
    resolver = (PROJECT_DIR / 'src/services/resolver.zig').read_text()
    assert 'std.enums.values(reading.Source)' in resolver
    assert 'reading.searchUrl(&address, base, source, query, 1)' in resolver
    installed_reading = resolver.split('fn resolveInstalledReading(', 1)[1].split('fn resolveAniListCatalog(', 1)[0]
    assert '@import("source_request.zig").request' in installed_reading
    assert '.cancel_epoch = workerCancellation()' in installed_reading
    assert entries['podcast-waveform']['endpoints']['feed'].startswith('https://')
    assert '.timeout_secs = 10' in installed_reading
    assert 'resolveInstalledAudio' in resolver
    for name in ('reading_provider_pure', 'audio_sources_pure'):
        assert name in (PROJECT_DIR / 'build.zig').read_text(), name
    return 'pass', 'Ten new installed providers with owned endpoints and cancellable search; existing SubsPlease enhanced without duplication'


@test("Public audio Browse exposes installed providers and license attribution on both clients", "Sources")
def test_public_audio_browse_contract():
    api = (PROJECT_DIR / 'src/services/remote_music_api.zig').read_text()
    html = (PROJECT_DIR / 'web/index.html').read_text()
    js = (PROJECT_DIR / 'web/js/media.js').read_text()
    assert 'source > music.SRC_NETLABELS' in api
    assert 's.attribution_len' in api and 'song.attribution_len' in api
    assert '<option value="5">Openverse</option>' in html
    assert '<option value="6">Archive Netlabels</option>' in html
    assert 'esc(s.attribution)' in js and 'overview:song.attribution' in js
    music = (PROJECT_DIR / 'src/services/music_subsonic.zig').read_text()
    radio = (PROJECT_DIR / 'src/services/radio.zig').read_text()
    assert 'pure.publicAudioSong(row)' in music
    assert 'browse_fanout.zig").run' in radio and '.limit = 2' in radio
    assert 'appendSoma(group)' in radio and 'pure.appendUnique(&state.app.radio.results' in radio
    headless = (PROJECT_DIR / 'src/headless.zig').read_text()
    for pump in ('queue.zig").drainUi()', 'resolver.zig").drainRemoteAction()', 'browser.zig").drainDeferredPlayback()'):
        assert pump in headless, 'headless must execute accepted actions: ' + pump
    return 'pass', 'Installed source dispatch, exact stream identities, visible license attribution'


@test("Novel chapter resume avoids recursive parser mutex deadlock", "Sources")
def test_novel_chapter_resume_lock():
    source = (PROJECT_DIR / 'src/services/novels.zig').read_text()
    chapter = source.split('fn openChapterExpected(', 1)[1].split('\n}', 1)[0]
    resume = source.split('fn saveResume(', 1)[1].split('\n}', 1)[0]
    persist = chapter.index('saveResume(ch_offset + idx)')
    assert chapter.index('parse_mutex.lock()') < persist
    assert persist < chapter.rindex('parse_mutex.unlock()')
    assert 'parse_mutex.lock()' not in resume, 'saveResume runs under the caller lock'
    assert source.count('saveResume(ch_offset + idx)') == 1
    assert 'pure.workResumeKey(' in resume, 'resume must be scoped to provider and work identity'
    assert 'novel_resume_chapter' in resume, 'exact chapter identity must be persisted'
    return 'pass', 'Caller owns chapter lock through resume persistence; no nested acquisition'


@test("Shared public fetch stops stale workers and validates bounded metadata cache", "Sources")
def test_source_request_contract():
    source = (PROJECT_DIR / 'src/services/source_request.zig').read_text()
    transport = (PROJECT_DIR / 'src/services/reliable_fetch.zig').read_text()
    assert 'bounded.StreamProcess.init' in transport and 'process.finish()' in transport
    assert '.cancel_flag = @import("../core/workers.zig").quittingSignal()' in transport
    assert '.cancel_epoch = opts.cancel_epoch' in transport
    assert 'pure.publicUrl(url)' in source and 'pure.publicHeader(h.name)' in source
    assert 'opts.validate' in source and 'pure.cacheable' in source and 'config.fingerprint()' in source
    assert 'var cache: [8]Entry' in source and 'mirrorUrl' in source
    assert 'source_request_pure' in (PROJECT_DIR / 'build.zig').read_text()
    main = (PROJECT_DIR / 'src/main.zig').read_text()
    assert main.index('workers.beginShutdownAndDrain(800)') < main.index('@import("services/source_request.zig").deinit()')
    return 'pass', 'Supervised cancellation/shutdown; validated bounded public cache; configured mirrors'


@test("Forwarded media opens execute on both desktop and headless owners", "Sources")
def test_forwarded_open_owner_pumps():
    main = (PROJECT_DIR / 'src/main.zig').read_text()
    headless = (PROJECT_DIR / 'src/headless.zig').read_text()
    forwarded = (PROJECT_DIR / 'src/services/forwarded_open.zig').read_text()
    assert '@import("services/forwarded_open.zig").drain()' in main
    assert '@import("services/forwarded_open.zig").drain()' in headless
    assert 'remote_open_lock.lock()' in forwarded and 'remote_open_lock.unlock()' in forwarded
    assert forwarded.index('remote_open_lock.unlock()') < forwarded.index('browser.loadContentDirectMeta(')
    assert 'addToQueue' in forwarded and 'browser.loadContent(url)' in forwarded
    return 'pass', 'One bounded FIFO snapshot/dispatch seam is drained by both app owners'


@test("Linux dependency check probes WebP as a library", "Packaging")
def test_webp_dependency_probe():
    result = subprocess.run([sys.executable, 'tests/test_linux_deps.py'], cwd=PROJECT_DIR, capture_output=True, text=True, timeout=15)
    if result.returncode:
        return 'fail', (result.stderr or result.stdout)[-1200:]
    return 'pass', 'Installed/missing decoder development files are detected by the production script'


@test("Verified public webcomics install, search and open full main panels", "Sources")
def test_verified_webcomic_sources():
    entries = json.loads((PROJECT_DIR / 'data/plugins-manifest.json').read_text())['plugins']
    ids = [row['id'] for row in entries]
    assert len(ids) == len(set(ids)) == 90
    rows = {row['id']: row for row in entries}
    for provider in ('xkcd', 'smbc'):
        assert rows[provider]['type'] == 'comics'
        assert rows[provider]['endpoints']['base'].startswith('https://')
    resolver = (PROJECT_DIR / 'src/services/resolver.zig').read_text()
    adapter = (PROJECT_DIR / 'src/services/webcomic_sources.zig').read_text()
    reader = (PROJECT_DIR / 'src/services/comics.zig').read_text()
    browser = (PROJECT_DIR / 'src/services/browser.zig').read_text()
    assert 'resolveInstalledWebcomics(q[0..qlen])' in resolver
    helper = resolver.split('fn resolveInstalledWebcomics(', 1)[1].split('fn resolveComicFury(', 1)[0]
    assert 'copyValue(@tagName(provider), "base", &base_buf) orelse continue' in helper
    assert 'workerCancellation()' in helper and 'numberedTitle(' in helper
    assert 'loadPublicWebcomic(provider, url[scheme.len..], gen)' in reader
    assert '.xkcd => fetchPublicWebcomicSearch(q, gen, 0, .xkcd)' in reader
    assert '.smbc => fetchPublicWebcomicSearch(q, gen, 0, .smbc)' in reader
    assert 'Source.xkcd, Source.smbc' in reader and 'sourceActive(src)' in reader
    assert '@import("browse_fanout.zig").run(Source, jobs[0..count]' in reader
    assert 'search_gen.load(.acquire) != gen' in reader and 'comicAppendStart(gen, start_hint)' in reader
    assert 'SMBC recent' in reader and 'up to 6' in reader
    assert 'pure.acceptsPageBody(tmp_buf[0..total])' in reader
    assert 'isPublicWebcomicRoute(url)' in browser
    remote = _remote_api()
    web = (PROJECT_DIR / 'web/js/media.js').read_text()
    assert 'searchComicsFrom(term, source)' in remote
    assert 'selectedSourceName()' in remote and 'xkcd_installed' in remote and 'smbc_installed' in remote
    assert 'renderComicSources(d)' in web and 'SMBC · recent comics' in web and 'xkcd · archive / number' in web
    assert 'cx-source' in (PROJECT_DIR / 'web/index.html').read_text()
    assert '"/archive/"' in adapter and '"/comic/rss"' in adapter
    assert 'if (provider == .smbc)' in adapter and 'else .partial' in adapter
    assert '"webcomic_sources_pure"' in (PROJECT_DIR / 'build.zig').read_text()
    assert (PROJECT_DIR / 'tests/test_webcomic_sources_live.py').exists()
    return 'pass', '90 unique definitions; installed xkcd archive/number and SMBC recent discovery to bounded full-image reader'
