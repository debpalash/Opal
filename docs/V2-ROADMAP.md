# Opal v2 — Roadmap

The 20-expert panel produced 20 directives. Four are landed on this branch. The other 16 are sequenced below by **risk × leverage** (small + load-bearing first, big rewrites last).

## Landed on `v2`

- ✅ Multi-tenant streaming proxy with per-stream auth tokens (`src/player/stream_proxy.zig`)
  - Closes the wildcard-CORS hole on `127.0.0.1:45678` at the protocol layer.
  - Unlocks real split-view: each player streams independently on its own port.
  - Constant-time token compare to avoid a timing oracle.
- ✅ Shared per-origin scraper rate limiter (`src/core/rate_limit.zig`)
  - Token-bucket registry; proof-of-life integration on `1337x`.
- ✅ Frame-time HUD overlay in Debug builds (`src/main.zig`)
  - Last / avg / peak ms in top-right; catches regressions at typing time.
- ✅ Session-restore skip-missing-files (was on `main` pre-branch).

## Wave 1 — security & correctness (next, ~1–2 days each)

1. **API token for `services/remote.zig`** — every JSON endpoint requires a per-launch bearer.
2. **Lua plugin sandbox** — deny `os.execute`, `io.popen`, `os.remove`, `package.loadlib` by default.
3. **Roll out `rate_limit.acquire` to every backend in `resolver.zig`** — one-line change per scraper.
4. **Bound thread spawns** — replace ad-hoc `spawn().catch{}` with a `core/sync.zig` worker pool.
5. **`docs/PRIVACY.md`** — enumerate every outbound endpoint; lock down the "no telemetry" claim.

## Wave 2 — UX & perf (~3–5 days each)

6. **Split `ui/settings.zig`** — `ui/settings/_root.zig` + per-tab module. Lazy-mount.
7. **MediaPlayer pixel-buffer pool** — return 8MB on player destroy, reuse on next init.
8. **Mpv hwdec failure toast** — surface fallback to software decoding.
9. **Subtitle cache by `imdb_id + lang`** — not by filename hash.
10. **Keyboard focus rings** — pass through every button in `ui/*`.

## Wave 3 — architecture (~1+ week each)

11. **Seek-aware piece deadlines** — FFI signature change in `torrent_wrapper.cpp`.
12. **Unified scrobble bus** — single tick in `watch_history.zig` fanning out to Trakt/AniList/SIMKL.
13. **LRU model unloader** — Whisper/llama/ONNX idle eviction.
14. **`MockIo` for cross-boundary tests** — bring back integration tests.
15. **One `build/deps.zig`** — kill duplicate logic across `build.zig` / `PKGBUILD` / `Formula/`.

## Wave 4 — long horizon

16. **i18n table** in `core/i18n.zig`.
17. **M3.3 smart media intelligence**: auto-skip intro, perceptual-hash dedup, smart collections — the README differentiator.

## Notes on what we DIDN'T do (and why)

- **No second allocator.** CLAUDE.md is explicit. Pixel-buffer pool will live inside the existing global allocator.
- **No rename to `opal`.** Project rules. `zigzag` stays in code/config paths forever.
- **No `Connection: keep-alive` in the proxy yet.** It would cut seek latency, but turning `streamReadAll` into a request loop is its own commit — left for Wave 2.
