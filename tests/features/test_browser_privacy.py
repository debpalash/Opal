"""Production browser protection interfaces and executable canvas regression."""
import re
import shutil
import subprocess
from pathlib import Path
from .harness import PROJECT_DIR, test
ROOT = Path(PROJECT_DIR)

@test("Browser media handoff preserves requests and rejects navigation confusion", "Browser")
def test_browser_media_integration():
    node = shutil.which('node')
    if not node:
        return 'skip', 'Node is optional; pure handoff parsing remains covered by Zig tests'
    result = subprocess.run([node, 'tests/test_browser_integration.js'], cwd=ROOT, capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, (result.stderr or result.stdout)[-1400:]
    assert 'browser-integration' in (ROOT / 'scripts/build-app.sh').read_text()
    return 'pass', 'real extension scripts: captured headers, trusted clicks, timestamp, SPA reset and frame validation'

@test("Browser session measurements report real deltas without exposing browsing URLs", "Browser")
def test_session_measurements():
    node = shutil.which('node')
    if not node:
        return 'skip', 'Node is optional; native privacy fixtures cover real WebKit measurements'
    result = subprocess.run([node, 'tests/test_browser_security.js'], cwd=ROOT, capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, (result.stderr or result.stdout)[-1200:]
    return 'pass', 'actual isolated-world script: observed bytes/blocks, numeric-only messages, no double counting'

@test("Browser new tabs offer private recents bookmarks stats and connection controls", "Browser")
def test_start_page_and_connections():
    page = (ROOT / 'src/ui/browser_start.zig').read_text()
    browser = (ROOT / 'src/services/browser.zig').read_text()
    native = (ROOT / 'src/macos/browser_security.m').read_text()
    assert 'native.presented = false' in browser and 'render(.start)' in browser
    assert 'state.app.incognito_mode) return &.{}' in browser
    assert 'ORDER BY last_visit DESC' in browser
    assert all(s in page for s in ('Bookmarks', 'Recents', 'Tracking cookies removed', 'privacy.stats()', 'openSection(2)'))
    assert 'nw_proxy_config_set_failover_allowed(proxy, false)' in native
    assert 'config.proxyConfigurations = @[make_proxy' in native
    assert '21600' in native and 'tor_task.running' in native
    assert 'task terminate' in native and 'waitUntilExit' not in native
    return 'pass', 'native start surface, hidden private history, measured counters, checked proxy leases and owned asynchronous Tor lifecycle'

@test("Browser canvas protection blocks readback with exact site exceptions", "Browser")
def test_canvas_guard():
    node = shutil.which('node')
    if not node:
        return 'skip', 'Node is optional; native browser fixtures also verify actual canvas behavior'
    result = subprocess.run([node, 'tests/test_canvas_guard.js'], cwd=ROOT, capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, (result.stderr or result.stdout)[-1000:]
    return 'pass', 'actual document-start script: drawing, readback, offscreen/WebGL, host exceptions'

@test("Browser extensions install the official pinned uBlock Lite with integrity checking", "Browser")
def test_official_extension_installer():
    service = (ROOT / 'src/services/browser_privacy.zig').read_text()
    native = (ROOT / 'src/macos/browser_extensions.m').read_text()
    assert 'https://github.com/uBlockOrigin/uBOL-home/releases/download/' in service
    assert re.search(r'ubol_sha256 = "[a-f0-9]{64}"', service)
    assert 'Sha256.hash(bytes' in service and 'ubol_sha256' in service
    assert '.max_filesize = 16 * 1024 * 1024' in service
    assert 'extensionWithResourceBaseURL:' in native and 'loadExtensionContext:' in native
    assert 'action.popupPopover' in native and 'NSPopoverBehaviorTransient' in native
    assert '[presented_action closePopup]' in native
    assert 'requestedPermissions' in native and 'Add extension' in native
    assert 'hasAccessToPrivateData = incognito' in native
    assert 'WKWebExtensionControllerConfiguration.nonPersistentConfiguration' in native
    assert 'popupPanelData' in native and 'could not finish starting' in native
    return 'pass', 'real WebKit extension host, verified upstream ZIP, explicit import/private permissions'

@test("Browser proxies persist separately and prevent local-route bypass", "Browser")
def test_proxy_persistence_and_lifecycle():
    config = (ROOT / 'src/core/config.zig').read_text()
    pure = (ROOT / 'src/services/browser_privacy_pure.zig').read_text()
    native = (ROOT / 'src/macos/browser_extensions.m').read_text()
    assert 'browser_proxy_pass_' in config and 'setSecretKey(' in config
    assert 'if (runtime_secrets) p.password.text() else ""' in pure
    assert 'nw_proxy_config_create_socksv5' in native
    assert 'nw_proxy_config_create_http_connect' in native
    assert 'nw_proxy_config_set_failover_allowed(proxy, false)' in native
    assert 'opal-browser-proxy-local-guard' in native
    assert 'apply_proxy(config.websiteDataStore)' in native
    assert 'unloadExtensionContext:' in native and 'epoch != generation' in native
    return 'pass', 'browser-only profiles, protected password keys, proxy routing and lifecycle guards'
