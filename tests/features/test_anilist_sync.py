"""AniList account lifecycle and durable progress delivery."""
from .harness import *  # noqa: F401,F403


@test("AniList OAuth token lifecycle and durable progress sync", "Integration")
def test_anilist_sync_lifecycle():
    service = _src("src/services/anilist.zig")
    anime = _src("src/services/anime.zig")
    state = _src("src/core/state.zig")
    api = _src("src/services/remote_sync_api.zig")
    remote = _src("src/services/remote.zig")
    ui = _web_app()
    checks = {
        "initialized": 'anilist.zig").init()' in _src("src/main.zig"),
        "official oauth flow": "https://anilist.co/api/v2/oauth/authorize" in service
            and "response_type=token" in service,
        "secret storage": "secret_store.seal" in service
            and "secret_store.reveal" in service and "secret_file.zig" in service,
        "token is write-only": "has_client_id" in api and "access_token[0.." not in api,
        "bounded token": "[2048]u8" in service and 'maxlength="2048"' in ui,
        "provider api": 'api_path, "/sync-accounts"' in remote
            and "remote_sync_api.zig" in remote and 'std.mem.eql(u8, method, "POST")' in api,
        "stable media identity": "anilist_id: i64" in state
            and "r.anilist_id = m.id" in anime and "anilist.updateProgress(r.anilist_id" in anime,
        "durable outbox": 'outbox.enqueue("anilist", "progress"' in service
            and "outbox.nextDue" in service and "outbox.deferFailure" in service,
        "owned bounded delivery": "workers.spawn(drainOutbox" in service
            and '"--connect-timeout"' in service and '"--max-time"' in service,
        "web lifecycle": 'id="anilist-authorize"' in ui
            and "loadSyncAccounts" in ui and "anilist-disconnect" in ui
            and "anilist-retry" in ui,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "AniList sync incomplete: " + ", ".join(missing)
    return "pass", "Encrypted write-only OAuth token + stable ID progress + durable retry queue"
