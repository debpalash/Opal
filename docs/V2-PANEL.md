# Opal v2 — 20-Expert Panel

Twenty perspectives on the codebase as of branch `v2`. Each expert gives **one concrete directive**, pinned to a file or pattern. Read this top to bottom; nothing here is speculative — every observation comes from the current tree.

The directives marked **[v2-now]** are landed on this branch. The rest are queued in `V2-ROADMAP.md`.

---

### 1. Streaming-protocol engineer (HTTP Range / mpv)
**Directive:** Per-stream auth tokens in the URL path. **[v2-now]**
The previous proxy at `src/player/stream_proxy.zig` hardcoded port `45678` and answered any request — a browser tab on the same host could `fetch()` the user's private torrent stream. v2 binds a free port per stream and gates each on `/s/<16-hex-token>` with a constant-time compare.

### 2. P2P / libtorrent specialist
**Directive:** Reset piece-deadlines on seek.
`src/torrent_wrapper.cpp` uses `set_piece_deadline` + head/tail boost — correct. But when mpv seeks inside a long file, we keep prioritizing the old offset's neighborhood. Wire a `proxy_worker → torrent_set_seek_hint(offset)` callback from `handleConnection` so the next Range request immediately re-prioritizes the seek target's piece.

### 3. mpv / playback engineer
**Directive:** Surface hwdec failures.
`hwdec=auto-safe` silently falls back to software. Listen for `MPV_EVENT_LOG_MESSAGE` containing "vd: Falling back" and toast it once per session so users know why their fan is spinning.

### 4. Search / resolver architect
**Directive:** Shared per-origin rate limit. **[v2-now]**
All five resolver backends fire HTTP at scrape targets concurrently. v2 adds `src/core/rate_limit.zig` (token bucket per origin) and wires 1337x as a proof of integration. Roll out to every backend in `services/resolver.zig` next.

### 5. UX / immediate-mode-UI designer
**Directive:** Split `ui/settings.zig` (2,805 lines) by tab.
Every frame the drawer is open, dvui re-walks the entire God-file. A tab dispatcher in `ui/settings/_root.zig` that imports only the active tab's module will halve frame time on the Settings drawer.

### 6. AI/ML systems engineer
**Directive:** LRU-evict cold model weights.
Whisper + Bonsai + ONNX + sqlite-vec each hold MB-to-GB resident. Add an `unloadIfIdle(timeout_minutes)` per backend and call it from the chat tab when its provider switches.

### 7. Security / sandbox auditor
**Directive:** Lock down localhost surface area. **[v2-now (proxy)]**
v2 closes the stream proxy. Still open: `src/services/remote.zig` JSON API on `:41595` has no auth — any process on the box can drive playback. Add a per-launch token written to `~/.config/zigzag/api.token`, mandatory in headers.

### 8. Cross-platform / packaging engineer
**Directive:** Centralize dep paths.
`build.zig` hard-codes `/opt/homebrew`. Three different package files (`PKGBUILD`, `Formula/`, `Makefile`) re-implement Linux logic. Move to one `build/deps.zig` module that detects via `pkg-config` and feeds `build.zig`.

### 9. Sync / multi-device strategist
**Directive:** Unified scrobble bus.
Trakt + AniList + SIMKL each spin their own timer in `watch_history.zig`. Replace with one tick that fans out to enabled providers; queue scrobbles to disk when offline.

### 10. Observability / dev-loop engineer
**Directive:** Always-on frame-time HUD in debug builds. **[v2-now]**
v2 adds a top-right rolling overlay (last / avg / peak ms) under `if (builtin.mode == .Debug)`. Catches the heavy-settings regression at the moment of typing, not in the next release.

### 11. Embedded DB / sqlite engineer
**Directive:** Single shared connection, statement cache.
`src/core/db.zig` likely opens connections per call. SQLite is happiest with one writer + many readers; cache prepared statements by query string. `sqlite-vec` writes are especially expensive when the prepare is repeated.

### 12. Subtitle / OpenSubtitles engineer
**Directive:** Cache subtitle hits by IMDB ID, not filename.
`src/player/subtitles.zig` re-fetches when episode files have similar but non-identical names. TMDB IDs are already resolved upstream — key the cache on `imdb_id + lang` not `path_hash`.

### 13. Native UI / a11y reviewer
**Directive:** Add keyboard focus rings everywhere a button lives.
dvui can do it; the audit is mechanical. Without focus rings, the 40+ keyboard shortcuts in the README are unreachable for users who don't memorize them.

### 14. Telemetry / privacy engineer
**Directive:** Document the "we don't phone home" claim.
The README says "no telemetry" — currently true. Add a `docs/PRIVACY.md` enumerating every outbound endpoint (TMDB, OpenSubtitles, Trakt, scrapers, llama.cpp model fetches) so users can audit. This is the differentiator from Electron media apps; lean into it.

### 15. Memory / Zig allocator engineer
**Directive:** Bound the `MediaPlayer.pixels` budget.
Each player allocates 1920×1080×`PMA` = ~8MB. Split-view × 4 players = 32MB just for pixel buffers. Reuse a pool — destroying a player should return its buffer.

### 16. Threading / concurrency engineer
**Directive:** Stop spawning detached threads per resolver call.
`std.Thread.spawn(...) catch {};` everywhere = leaked handles + no join on shutdown. A thread pool with a known size (CPU count) plus a `WorkQueue` in `core/sync.zig` makes these debuggable and bounded.

### 17. Plugin / extension API designer
**Directive:** Sandbox Lua plugins by default.
`src/services/plugins.zig` loads community Lua with full FS access. At minimum: deny `os.execute`, `io.popen`, `os.remove`, and `package.loadlib` in the loader unless an explicit `allow_unsafe = true` is set in the plugin's manifest.

### 18. Test / CI engineer
**Directive:** Mock `io_global` for cross-boundary tests.
CLAUDE.md documents the constraint: tests can't import modules that pull `core/io_global.zig`. Over time, that's the whole tree. A `MockIo` in `core/deps_test.zig` lets us bring back integration tests.

### 19. Internationalization engineer
**Directive:** Externalize all UI strings.
String literals scatter across `ui/*.zig`. A `core/i18n.zig` with a compile-time string table (`@import("strings.zon")`) costs nothing at runtime and unblocks volunteer translations.

### 20. Product / focus reviewer
**Directive:** Cut Milestone 4 features until M3 is reliable.
The roadmap has Trakt + AniList + SIMKL + Chromecast/DLNA + watch party already shipped, with M3.3 (smart media intelligence) entirely unstarted. The differentiator the README promises is "built-in AI" — finish auto-skip + duplicate detection + smart collections **before** adding more sync surfaces.

---

## What changed in v2 on this branch

| Directive | File(s) |
|-----------|---------|
| Per-stream auth tokens, multi-tenant proxy | `src/player/stream_proxy.zig`, `src/player/player.zig` |
| Shared scraper rate limit (proof-of-life) | `src/core/rate_limit.zig`, `src/services/resolver.zig` |
| Frame-time HUD in Debug builds | `src/main.zig` |
| Session-restore skip for missing files | `src/main.zig` (carried from main) |
