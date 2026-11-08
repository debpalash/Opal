//! Per-frame service ticks shared by the desktop (main.zig) and mobile
//! (ui/ios_frame.zig) hosts. Moved verbatim from main.zig's appFrame so both
//! hosts drain the same worker mailboxes in the same order.
const state = @import("core/state.zig");
const theme = @import("ui/theme.zig");
/// Phones/tablets cannot spawn the managed helper processes (Jackett, agents).
const mobile = @import("core/platform_pure.zig").mobile;

/// Theme reapply, credential publish and worker-mailbox drains.
pub fn tickEarly() void {
    // Apply any theme change requested off the UI thread (config.load runs
    // theme.setPreset on the background worker, which can't touch dvui directly).
    theme.reapplyIfPending();
    if (state.app.config_loaded.load(.acquire)) @import("services/search_preview.zig").publishCredentials(state.app.tmdb.api_key[0..state.app.tmdb.api_key_len]);

    // Queue producers include playlist/AI/remote worker threads. Drain their
    // bounded commands here so live queue and player state stay UI-thread-owned.
    @import("services/queue.zig").drainUi();
    if (!mobile and state.app.config_loaded.load(.acquire)) @import("services/jackett_server.zig").tick();
    @import("services/resolver.zig").drainRemoteAction();
    @import("services/search.zig").updateGalleryRoute();
    @import("services/search.zig").drainMemorySearch();
    @import("services/auto_subs.zig").pollAttach();
    @import("services/babel.zig").tick(); // live captions / translation / recaps
    @import("player/watch_history.zig").drainUi();
    @import("services/history.zig").drainDownloadHistoryUi();
}

/// Deferred playback handoff, widget-id reset, pending nav, torrent/download
/// ticks and staged catalog results.
pub fn tickServices() void {
    // A first Home/Recents/direct-play click can land while that worker is
    // still preparing libmpv. Complete its owned handoff without ever waiting
    // inside the input/render frame.
    @import("services/browser.zig").drainDeferredPlayback();
    // Reset the per-frame widget-id sequence counters (sectionHeader / divider /
    // statusPill). Without this every one of those widgets is a "first frame"
    // id for dvui, which force-refreshes — a permanent full-rate repaint while
    // Settings or any status pill is on screen.
    @import("ui/components.zig").beginFrame();
    @import("ui/settings.zig").beginFrame();

    // Consume a navigation queued from a worker thread (AI tools, resolver).
    state.applyPendingNav();

    // Honor a magnet/.torrent action made during delayed DHT startup. The
    // background initializer only publishes + wakes; the UI thread performs
    // the player and list mutation here.
    @import("services/search.zig").drainResolvedTorrentDetail();
    @import("services/search.zig").flushPendingTorrentOpen();

    // Rejoin saved active swarms only after DB + libtorrent are both ready.
    // This intentionally does not open a player or change the current route.
    @import("services/torrent_intents.zig").restoreIfReady();
    @import("services/downloads.zig").tick();
    @import("services/wanted.zig").tick();
    @import("services/library_sync.zig").tick();
    @import("services/recall_index.zig").tick();
    if (!mobile) {
        @import("services/agent_tasks.zig").tick();
        @import("services/operator.zig").tick();
    }

    // Swap in TMDB pages staged by fetch workers (UI thread owns `results`;
    // workers staging + this apply is what keeps the render loop's iteration
    // safe — see state.zig tmdb.results comment).
    @import("services/tmdb_api.zig").applyPendingResults();
    // Drama uses the same worker-stage/UI-publish pattern. Drain it globally so
    // the web browse page progresses even when the desktop is on another tab.
    @import("services/drama.zig").pumpPending();
}

/// Deferred comic load plus deferred player removal and the single-media
/// invariant. Runs before rendering: mpv deinit must not race the render pass.
pub fn tickPlayers() void {
    // Drain a deferred comic-load requested by the remote API thread (loadComic
    // frees textures via dvui, which is UI-thread-only).
    @import("services/comics.zig").drainPendingLoad();

    // Process deferred player removal (safe: before any rendering)
    if (state.app.pending_remove_player_idx >= 0) {
        const idx = @as(usize, @intCast(state.app.pending_remove_player_idx));
        if (idx < state.app.players.items.len) {
            // Lock against the remote API thread, which may be driving mpv on a
            // captured *MediaPlayer right now (use-after-free otherwise).
            state.players_mutex.lock();
            defer state.players_mutex.unlock();
            @import("services/auto_subs.zig").cancelForMediaChange();
            var p_rem = state.app.players.orderedRemove(idx);
            // Save URL for Ctrl+Shift+T undo
            if (p_rem.current_url_len > 0 and p_rem.current_url_len <= 2048) {
                state.pushClosedUrl(p_rem.current_url[0..p_rem.current_url_len]);
            }
            p_rem.deinit(@import("core/alloc.zig").allocator);
            if (state.app.active_player_idx >= state.app.players.items.len and state.app.players.items.len > 0) {
                state.app.active_player_idx = state.app.players.items.len - 1;
            } else if (state.app.active_player_idx > idx and state.app.active_player_idx > 0) {
                state.app.active_player_idx -= 1;
            }
            if (state.app.players.items.len == 0) {
                state.app.active_player_idx = 0;
                // Page shell: the Player route now has nothing to render — leave
                // it for the last non-player page (or Home) so closing the player
                // doesn't drop the user on an empty grid.
                if (state.app.page_shell_enabled) state.app.router.leavePlayer();
            }
        }
        state.app.pending_remove_player_idx = -1;
    }

    // Single-media invariant — the multi-stream / "add screen" grid feature is
    // retired: only one player may exist at a time. If extras slipped in (an
    // append-based open path, session restore), keep the active one and tear the
    // rest down HERE, at the safe pre-render point — mpv deinit must not race the
    // render thread, which is why removal is deferred to the frame top.
    if (state.app.players.items.len > 1) {
        // Lock against the remote API thread (see the deferred-removal block above).
        state.players_mutex.lock();
        defer state.players_mutex.unlock();
        @import("services/auto_subs.zig").cancelForMediaChange();
        const keep = @min(state.app.active_player_idx, state.app.players.items.len - 1);
        var i: usize = state.app.players.items.len;
        while (i > 0) {
            i -= 1;
            if (i == keep) continue;
            var p_rem = state.app.players.orderedRemove(i);
            p_rem.deinit(@import("core/alloc.zig").allocator);
        }
        state.app.active_player_idx = 0;
    }
}

/// Owner-thread playback progression, tracker/stall drains, screen-saver
/// inhibit while media plays (iOS: idle timer) and wallpaper ticks.
pub fn tickPlayback() void {
    @import("application/playback_update.zig").tick();

    // Native macOS Now Playing + hardware media keys: drain pending remote
    // commands (play/pause/seek from media keys, AirPods, Control Center)
    // onto the active player and refresh the system Now Playing card.
    // Compiles to a no-op on non-macOS.

    // Live public tracker list: load the cache on the first tick, re-fetch once
    // a day on a worker. What gets injected into every magnet/.torrent on add,
    // which is what time-to-first-piece hangs on. Self-throttled to 5 min.
    @import("services/trackers.zig").tick();

    // Stall watchdog: a torrent with no new bytes and no peers gets a forced
    // tracker + DHT reannounce (rate-limited, backed off, capped). It runs on
    // its OWN thread (started in background init) — driving it from here meant
    // it only ran while dvui was drawing, and dvui idles when the window has no
    // events, so a torrent wedged in the background was never rescued. All that
    // is left on the UI thread is showing a toast the watchdog queued.
    @import("services/torrent_stall.zig").drainToast();

    // Screensaver inhibit: mpv's stop-screensaver requires a VO; we use SW
    // render, so SDL handles it. cached_paused is event-driven, which removes a
    // synchronous mpv property query and a repaint-count throttle from this hot
    // path. Pause/play changes now take effect on their very next UI wake.
    {
        const S = struct {
            var disabled: bool = false;
        };
        var any_playing = false;
        for (state.app.players.items) |p| {
            if (p.current_url_len > 0 and !p.cached_paused) {
                any_playing = true;
                break;
            }
        }
        if (any_playing and !S.disabled) {
            _ = @import("core/c.zig").sdl.SDL_DisableScreenSaver(); // SDL3 returns bool
            S.disabled = true;
        } else if (!any_playing and S.disabled) {
            _ = @import("core/c.zig").sdl.SDL_EnableScreenSaver();
            S.disabled = false;
        }
    }

    if (!mobile) @import("services/wallpapers.zig").tick(); // sets the OS desktop wallpaper
}
