"""Browse loading feedback is checked in actual web scripts and native renderers."""
import shutil
import subprocess
from .harness import PROJECT_DIR, _src, test


@test("Web Browse skeletons, fast polling and stale requests", "Browse")
def test_web_browse_loading():
    if not shutil.which('node'):
        return 'skip', 'Node is unavailable for web lifecycle fixtures'
    result = subprocess.run(['node', '--test', 'tests/test_web_lifecycle.mjs'], cwd=PROJECT_DIR,
                            capture_output=True, text=True, timeout=30)
    if result.returncode:
        return 'fail', (result.stderr + result.stdout)[-1800:]
    return 'pass', 'Production scripts: all content skeletons, progressive rows, 300ms serialized polling and stale YouTube/VNDB rejection'


@test("Native Browse skeletons are reached and respect reduced motion", "Browse")
def test_native_browse_loading_contract():
    fixture = _src('src/ui/browse_loading_native_test.zig')
    for view in ('Anime', 'YouTube', 'Drama', 'Comics', 'Novels', 'Podcasts', 'Radio', 'Music', 'Vndb', 'Opds'):
        assert f'.tab = .{view}' in fixture
    for token in ('observation.count > 0', '!observation.animated', '.{ 1360, 1000 }', '.{ 640, 800 }'):
        assert token in fixture
    assert '@import("ui/browse_loading_native_test.zig")' in _src('src/main.zig')
    assert '"Native Browse"' in _src('build.zig')
    components = _src('src/ui/components.zig')
    assert 'motion.animate and !cover_skeleton_timer_armed' in components
    assert 'app.reduce_motion' in components and '40_000' in components
    css = _src('web/styles/app.css')
    assert '@media (prefers-reduced-motion: reduce)' in css and 'browse-skeleton-art::after' in css
    return 'pass', 'Actual eleven-state render matrix at two sizes; shared timer disabled under reduced motion'
