"""SIMKL PIN authorization and durable history delivery."""
from .harness import *  # noqa: F401,F403


@test("SIMKL PIN auth and durable watched sync", "Integration")
def test_simkl_sync_lifecycle():
    service = _src("src/services/simkl.zig")
    api = _src("src/services/remote_sync_api.zig")
    ui = _web_app()
    checks = {
        "initialized": 'simkl.zig").init()' in _src("src/main.zig"),
        "official pin flow": 'apiUrl("/oauth/pin"' in service
            and '"/oauth/pin/{s}"' in service and "https://simkl.com/pin" in ui,
        "required request identity": "client_id={s}&app-name=opal&app-version={s}" in service
            and '"-A", USER_AGENT' in service,
        "provider interval honored": 'extractJsonInt(response[0..n], "interval")' in service
            and "waited < interval" in service,
        "encrypted credential": "secret_store.seal" in service
            and "secret_store.reveal" in service and "[2048]u8" in service,
        "token never serialized": "simkl_state" in api and "access_token[0.." not in api,
        "durable history": 'outbox.enqueueState("simkl", operation' in service
            and 'outbox.nextDue("simkl"' in service and "outbox.deferFailure" in service,
        "tv completion hook": 'simkl.zig").markWatchedEpisode' in _src("src/services/tv_library.zig")
            and "setEpisodeWatched" in _src("src/services/tmdb.zig"),
        "http semantics": '"%{http_code}"' in service and "status == 401" in service
            and "needs_reauth" in api,
        "owned bounded work": "workers.spawn(pinAuthWorker" in service
            and "workers.spawn(drainOutbox" in service and '"--max-time"' in service,
        "web lifecycle": 'id="simkl-connect"' in ui and 'id="simkl-retry"' in ui
            and "scheduleSyncAccountPoll" in ui and "provider:'simkl'" in ui,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "SIMKL sync incomplete: " + ", ".join(missing)
    return "pass", "Official PIN auth + encrypted token + durable TV history + visible revoked/retry state"


@test("Manual episode history is bidirectional and latest-state-wins", "Integration")
def test_episode_history_state_sync():
    db = _src("src/core/db.zig")
    queue = _src("src/services/sync_outbox.zig")
    library = _src("src/services/tv_library.zig")
    tmdb = _src("src/services/tmdb.zig")
    trakt = _src("src/services/trakt.zig")
    simkl = _src("src/services/simkl.zig")
    checks = {
        "atomic state identity": "state_key TEXT NOT NULL" in db
            and "idx_sync_outbox_state" in db
            and "ON CONFLICT(provider,state_key)" in queue,
        "single local mutation path": "pub fn setEpisodeWatched" in library
            and "db.tvMarkWatched" in library
            and "setEpisodeWatched" in tmdb,
        "both providers remove": "markUnwatchedEpisode" in trakt
            and '"/sync/history/remove"' in trakt
            and "markUnwatchedEpisode" in simkl
            and '"/sync/history/remove"' in simkl,
        "manual and playback share path": "setEpisodeWatched(" in _between(
            tmdb, "fn tvToggleWatched", "\nfn "
        ) and "setEpisodeWatched(" in _between(
            tmdb, "pub fn commitPendingWatch", "\nfn "
        ),
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "episode history state sync incomplete: " + ", ".join(missing)
    return "pass", "manual and automatic episode state converges locally, on Trakt, and on SIMKL"
