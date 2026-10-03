"""Production-used bounded worker and owned publication contracts."""
from .harness import _src, test


@test("Comics and Novels Browse fan out with bounded incremental publication", "Browse")
def test_reading_parallel_wiring():
    fanout = _src('src/services/browse_fanout.zig')
    assert 'children: [3]?std.Thread' in fanout
    assert 'workers.spawnLegacy(Wave.lane' in fanout and 'thread.join()' in fanout
    assert 'wave.next.fetchAdd' in fanout and 'cancelled(wave.epoch)' in fanout
    for category, provider, gate in [('comics', 'comicProvider', '&search_gen'), ('novels', 'novelProvider', '&search_request.generation')]:
        src = _src('src/services/'+category+'.zig')
        assert '@import("browse_fanout.zig").run(' in src and provider in src
        assert 'appendPosition(' in src and 'usefulPublication(' in src
        assert 'coverSkeletonGrid(' in src and 'setLoadingFixtureForTest' in src
        assert 'browse_generation = ' in src and '.cancel_epoch = browseEpoch()' in src
        assert gate in src and 'scrapeFetchWithCancellation' in src
    comics = _src('src/services/comics.zig')
    search = comics[comics.index('fn searchWorker(gen:'):comics.index('/// Infinite-scroll appender:')]
    assert 'seedDefaultFromCache(gen)' in search
    renderer = comics[comics.index('pub fn renderContent'):]
    assert 'seedDefaultFromCache();' not in renderer
    novels = _src('src/services/novels.zig')
    page = novels[novels.index('fn loadMoreWorker(job:'):novels.index('// ═', novels.index('fn loadMoreWorker(job:'))]
    assert page.index('parse_mutex.lock()') < page.index('beginAppendWave(search_request.current()') < page.index('_ = runNovelWave(')
    schedule = novels[novels.index('pub fn loadMore()'):novels.index('/// Append worker:')]
    assert schedule.index('parse_mutex.lock()') < schedule.index('reserveNextPage(&current_page)') < schedule.index('parse_mutex.unlock();', schedule.index('reserveNextPage(&current_page)')+120)
    assert 'rollbackPage(search_request.current(), my_gen, &current_page, next)' in schedule
    assert 'current_page = next' not in schedule
    comic_schedule = comics[comics.index('pub fn loadMoreResults()'):comics.index('fn loadMoreWorker(gen:')]
    assert comic_schedule.index('search_command_mutex.lock()') < comic_schedule.index('if (!more_available')
    fixture = _src('tests/test_browse_parallel_live.py')
    for token in ('test_comics_overlap', 'test_novels_overlap', 'test_comics_stale', 'test_novels_stale', 'test_partial_failure_keeps_successful_results', 'closed.wait(1)', "data['loading']"):
        assert token in fixture
    assert _src('.github/workflows/ci.yml').count('tests/test_browse_parallel_live.py') == 3
    return 'pass', 'Four joined lanes, generation-safe append, retained cards, skeletons and real local-provider overlap/cancellation fixtures'
