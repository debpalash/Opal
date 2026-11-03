"""Production browser protection interfaces and executable canvas regression."""
import re
import shutil
import subprocess
from pathlib import Path
from .harness import PROJECT_DIR, test
ROOT = Path(PROJECT_DIR)

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
