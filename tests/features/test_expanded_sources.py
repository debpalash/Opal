"""Executable coverage for the added source adapters."""
import subprocess
import sys
import json
from pathlib import Path
from .harness import PROJECT_DIR, test
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
    for source in ('dmhy', 'acgrip', 'standardebooks', 'wuxiaclick', 'openverse', 'netlabels', 'somafm'):
        row = entries[source]
        assert row['endpoints']['base'].startswith('https://'), source
        assert row['file'] == f'plugins/{source}.json', source
    resolver = (PROJECT_DIR / 'src/services/resolver.zig').read_text()
    assert 'std.enums.values(reading.Source)' in resolver
    assert 'reading.searchUrl(&address, base, source, query, 1)' in resolver
    installed_reading = resolver.split('fn resolveInstalledReading(', 1)[1].split('fn resolveAniListCatalog(', 1)[0]
    assert '@import("reliable_fetch.zig").fetch' in installed_reading
    assert '.timeout_secs = 10' in installed_reading
    assert 'resolveInstalledAudio' in resolver
    for name in ('reading_provider_pure', 'audio_sources_pure'):
        assert name in (PROJECT_DIR / 'build.zig').read_text(), name
    return 'pass', 'Seven distinct installed providers; existing SubsPlease enhanced without duplication'


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
    assert 'defer appendSoma(my_gen' in radio
    headless = (PROJECT_DIR / 'src/headless.zig').read_text()
    for pump in ('queue.zig").drainUi()', 'resolver.zig").drainRemoteAction()', 'browser.zig").drainDeferredPlayback()'):
        assert pump in headless, 'headless must execute accepted actions: ' + pump
    return 'pass', 'Installed source dispatch, exact stream identities, visible license attribution'


@test("Novel chapter resume avoids recursive parser mutex deadlock", "Sources")
def test_novel_chapter_resume_lock():
    source = (PROJECT_DIR / 'src/services/novels.zig').read_text()
    chapter = source.split('pub fn openChapter(', 1)[1].split('\n}', 1)[0]
    resume = source.split('fn saveResume(', 1)[1].split('\n}', 1)[0]
    assert chapter.index('parse_mutex.lock()') < chapter.index('saveResume(idx)')
    assert chapter.index('saveResume(idx)') < chapter.index('parse_mutex.unlock()')
    assert 'parse_mutex.lock()' not in resume, 'saveResume runs under the caller lock'
    assert source.count('saveResume(idx)') == 1
    return 'pass', 'Caller owns chapter lock through resume persistence; no nested acquisition'
