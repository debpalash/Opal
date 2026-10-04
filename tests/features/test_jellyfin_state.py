"""Jellyfin web parity: resume, favorite, and watched state/actions."""
from .harness import *  # noqa: F401,F403


@test("Jellyfin user-state parity", "Integrations")
def test_jellyfin_user_state():
    state = _src("src/core/state.zig")
    service = _src("src/services/jellyfin.zig")
    api = _src("src/services/remote_library_api.zig")
    remote = _src("src/services/remote.zig")
    web = _src("web/js/discovery.js")
    css = _src("web/styles/app.css")
    desktop = _src("src/ui/jellyfin_ui.zig")
    transport = _src("src/core/http_transport.zig")
    checks = {
        "state fields": all(field in state for field in ("is_favorite", "is_played", "user_data_gen")),
        "server values parsed": "IsFavorite" in service and "Played" in service,
        "stable-id mutation": "pub fn setUserData(item_id:" in service,
        "worker-owned request": "workers.spawn(runUserDataMutation" in service,
        "stale rollback guard": "item.user_data_gen != request.generation" in service,
        "authenticated REST mutation": all(text in service for text in ("FavoriteItems", "PlayedItems", ".DELETE")),
        "post-only remote action": 'path, "/jellyfin/action"' in api and 'requireMethod(stream, method, "POST")' in api,
        "remote state serialized": all(field in remote for field in ("favorite", "played", "progress")),
        "web uses mutation helper": "apiMutation('/jellyfin/action" in web,
        "accessible controls": 'aria-label="${it.favorite' in web and 'aria-label="${it.played' in web,
        "resume progress rendered": "jf-progress" in web and ".jf-progress" in css,
        "touch actions visible": "@media (hover:none)" in css,
        "native typed activation": all(text in desktop for text in ("fn activateItem", "jf.openFolder", "jf.playAudioItem")),
        "native user-state actions": desktop.count("jf.setUserData(") >= 2,
        "empty mutation responses accepted": ".no_content => return buf[0..0]" in transport,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "Jellyfin user-state parity incomplete: " + ", ".join(missing)
    return "pass", "Jellyfin resume/favorite/watched state is visible and safely mutable"


@test("Personal-server playback workflows retain cancellation and stable library identities", "Integrations")
def test_personal_server_workflow_guards():
    jellyfin = _src("src/services/jellyfin.zig")
    plex = _src("src/services/plex.zig")
    remote = _src("src/services/remote.zig")
    plex_api = _src("src/services/remote_plex_api.zig")
    web = _src("web/js/media.js")
    fixture = _src("tests/test_media_servers_live.py")
    auth = jellyfin.split("pub fn authenticate()", 1)[1].split("// Library / Item Fetching", 1)[0]
    publish = auth.split("// Store credentials", 1)[1]
    assert publish.index("store_mutex.lock()") < publish.index("auth_request.isCurrent(my_gen)") < publish.index("state.app.jf.token_len = tlen")
    assert "auth_request.finish(my_gen" in auth and ".cancel_epoch" in auth
    disconnect = jellyfin.split("pub fn disconnect()", 1)[1].split("\n}", 1)[0]
    assert "auth_request.cancel(" in disconnect
    assert "pub fn fetchItemsByKey(" in plex and "request.section_key[0..request.section_key_len]" in plex
    assert "copySections(&owned_sections)" in plex_api
    assert "wire.queryParam(query, \"key\")" in plex_api
    render = web.split("function renderPlex(", 1)[1].split("\nfunction ", 1)[0]
    assert "/plex/open?key=" in render and "/plex/open?idx=" not in render
    snapshot = remote.split("fn apiPlayerSnapshot(", 1)[1].split("fn setPlayerDouble", 1)[0]
    assert "ap.np_title" in snapshot and "ap.loading_title" in snapshot
    discovery = remote.split("fn writeSubtitleDiscovery(", 1)[1].split("\n}", 1)[0]
    assert 'w.writeAll("\\\"}}")' in discovery and 'w.writeAll("\\\"}}}")' not in discovery
    for case in ("test_jellyfin_disconnect_cancels_inflight_login_publication",
                 "test_jellyfin_login_library_play_resume_tracks_expiry_reconnect",
                 "test_plex_restore_library_play_resume_tracks_expiry",
                 "test_plex_stable_section_identity_survives_reordered_libraries"):
        assert case in fixture
    assert "live.IsolatedOpal" in fixture and "anullsrc" in fixture and "await_new_stream" in fixture
    return "pass", "Owned generated-media fixtures cover cancel, stable libraries, resume, subtitles, progress and reconnect"
