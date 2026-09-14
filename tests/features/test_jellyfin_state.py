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
        "empty mutation responses accepted": ".no_content => return buf[0..0]" in transport,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "Jellyfin user-state parity incomplete: " + ", ".join(missing)
    return "pass", "Jellyfin resume/favorite/watched state is visible and safely mutable"
