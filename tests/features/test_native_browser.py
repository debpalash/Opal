"""Native browser and macOS wallpaper lifecycle contracts (native gate tests DOM)."""
from pathlib import Path
from .harness import PROJECT_DIR, test

ROOT = Path(PROJECT_DIR)

@test("macOS browser uses a native view with platform and headless guards", "Browser")
def test_native_browser_route():
    service = (ROOT / 'src/services/browser.zig').read_text()
    owner = (ROOT / 'src/services/native_browser.zig').read_text()
    native = (ROOT / 'src/macos/native_browser.m').read_text()
    main = (ROOT / 'src/main.zig').read_text()
    assert 'native.navigate(b.url_buf[0..url.len])' in service
    assert 'native.present(@ptrCast(dvui.currentWindow().backend.impl.window)' in service
    assert 'if (comptime !supported) return' in owner
    assert 'headless' in owner and '.macos' in owner
    assert '[window.contentView addSubview:clip_host]' in native
    assert '[clip_host addSubview:view]' in native
    assert 'clip_host.layer.masksToBounds = YES' in native
    assert 'NSRect page_frame = NSMakeRect(-covered, 0, width * sx, height * sy)' in native
    assert 'if (!NSEqualRects(view.frame, page_frame))' in native
    assert 'WKWebsiteDataStore.nonPersistentDataStore' in native
    assert 'sw.modal or pure.intersects' in (ROOT / 'src/ui/native_browser.zig').read_text()
    assert 'native_browser.zig").beginFrame()' in main
    assert 'native_browser.zig").endFrame' in main
    assert 'native_browser.zig").deinit()' in main
    return 'pass', 'native view, private store, modal/route visibility, UI-thread cleanup'

@test("macOS live wallpapers use non-activating desktop surfaces on every display", "Wallpapers")
def test_native_wallpaper_route():
    native = (ROOT / 'src/macos/live_wallpaper.m').read_text()
    service = (ROOT / 'src/services/wallpaper_desktop.zig').read_text()
    main = (ROOT / 'src/main.zig').read_text()
    assert 'CGWindowLevelForKey(kCGDesktopWindowLevelKey) + 1' in native
    assert 'NSWindowCollectionBehaviorCanJoinAllSpaces' in native
    assert 'NSWindowCollectionBehaviorIgnoresCycle' in native
    assert 'window.ignoresMouseEvents = YES' in native
    assert 'canBecomeKeyWindow { return NO; }' in native
    assert 'for (NSScreen *screen in NSScreen.screens)' in native
    assert 'player.muted = YES' in native and 'AVPlayerLooper' in native
    assert 'NSApplicationDidChangeScreenParametersNotification' in native
    assert 'if (animated and native_mac)' in service
    assert 'pollNative()' in main and 'deinitNative()' in main
    assert 'result == 1 and snapshot() == .applying' in service
    return 'pass', 'native desktop layer, display changes, muted looping, readiness and cleanup'
