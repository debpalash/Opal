# Opal ⚡ Roadmap

> Local-first, AI-native media runtime — Jellyfin + Stremio + AI in one binary.

---

## ✅ Milestone 1 — Core Runtime (DONE)

- [x] MPV-based playback engine with hardware decoding (`hwdec=auto-safe`)
- [x] libtorrent streaming with piece prioritization + pause-on-starve
- [x] Universal search engine (Jellyfin, Torrents, Anime, YouTube)
- [x] RSS feed reader with magnet link routing
- [x] Local file browser with icons, sizes, delete management
- [x] Drag-and-drop media loading with toast feedback
- [x] Download manager (speed limits, pause/resume, file priorities, piece map)
- [x] Download history + watch history tracking
- [x] Settings system (save path, Jellyfin config, player options)
- [x] Multi-player support (split-view)
- [x] Premium dvui-based UI with dark theme
- [x] Animated loading overlay with progress bar

---

## ✅ Milestone 2 — Media Center Essentials (DONE)

### 2.1 — Subtitle Engine
- [x] OpenSubtitles API integration (v1 REST + legacy search)
- [x] Subtitle track picker UI (embedded + external subs)
- [x] Subtitle delay/sync adjustment (K/Shift+K)
- [x] Auto-download best match on play (Shift+J)

### 2.2 — Metadata & Poster Art
- [x] TMDB API integration (movies + TV shows)
- [ ] TVDB fallback for anime/obscure shows
- [x] Poster grid view (Netflix-style browsable library)
- [x] Metadata panel: synopsis, rating, cast, year, genre
- [x] Auto-match filenames to TMDB IDs (fuzzy match)

### 2.3 — Series Tracking & Continue Watching
- [x] Per-file watch progress persistence (SQLite-backed resume)
- [x] "Continue Watching" row on home screen
- [x] Season/episode navigation for series folders
- [x] Auto-play next episode
- [x] Watched/unwatched markers

### 2.4 — Player UX Polish
- [x] Audio track picker UI (footer dropdown + U key)
- [x] Chapter navigation (footer dropdown + PgUp/PgDn)
- [x] Keyboard shortcuts (40+ shortcuts, cheatsheet: Shift+I)
- [x] Screenshot capture (P key + Settings → Capture)
- [x] Playback speed controls in UI ([ ] keys + footer display)
- [x] Clip export (A-B loop → ffmpeg → file)
- [x] Video filters (brightness, contrast, saturation, gamma)
- [x] Audio equalizer presets

---

## 🧠 Milestone 3 — AI Features (The Differentiator)

### 3.1 — Local LLM Integration (Bonsai-8B via llama.cpp)
- [x] Bundle/link llama.cpp as C library (PrismML fork for 1-bit kernels)
- [x] Model manager: download/load GGUF models from settings
- [ ] Natural language search: "find me something like Invincible" (needs embedding model)
- [x] Smart recommendations based on watch history
- [x] Chat assistant panel: ask questions about media, get suggestions
- [x] Filename parser: intelligently extract show/season/episode from messy names

### 3.2 — Whisper Auto-Subtitles
- [x] whisper.cpp integration (C library, runs on GPU)
- [x] Generate subtitles for ANY local file with no internet
- [x] Language detection + multi-language support (configurable model + lang flag)
- [x] Export generated subs as .srt files (auto-saved, trackable path)
- [ ] Real-time live transcription mode (streaming pipeline needed)

### 3.3 — Smart Media Intelligence
- [ ] Auto-skip intro/outro detection (audio fingerprinting — future)
- [ ] Content tagging: auto-detect genre, quality, language from content (ML — future)
- [ ] Duplicate detection across library (perceptual hashing — future)
- [ ] Smart collections: auto-group related media (depends on tagging)

---

## 🌐 Milestone 4 — Ecosystem & Connectivity

### 4.1 — External Service Sync
- [x] Trakt.tv integration (OAuth device flow + scrobble API)
- [x] AniList sync (GraphQL mutations for anime progress)
- [x] SIMKL integration (REST API checkin + watchlist)
- [x] Import/export watch history (JSON export/import)

### 4.2 — Remote Access & Casting
- [x] Web remote control (extend existing web/ UI)
- [x] Chromecast/DLNA support (via catt)
- [ ] Transcoding pipeline (FFmpeg → serve to other devices — future)

### 4.3 — Multi-User & Profiles
- [ ] User profile system (separate watch history, preferences — future)
- [ ] PIN-protected profiles
- [ ] Per-user recommendations

---

## 🔮 Milestone 5 — Future Vision

### 5.1 — Plugin System
- [x] Lua plugin API for custom sources (43KB, full implementation)
- [ ] Community addon repository
- [ ] Custom UI panels via plugins

### 5.2 — Social Features
- [x] Watch party (sync playback over network)
- [ ] Share clips/timestamps
- [ ] Activity feed

### 5.3 — Voice Backends
- [x] whisper.cpp + macOS say (default, fully implemented)
- [x] sherpa-onnx (streaming STT + Kokoro/Piper TTS)
- [x] Apple native (SFSpeechRecognizer via xcrun swift)
- [x] speaches (OpenAI-compatible server at localhost:8000)

### 5.4 — Mobile Companion
- [ ] Android client (stream from Opal server)
- [ ] iOS client
- [ ] Offline sync (download for mobile playback)

---

## 🧭 Milestone 6 — Breadth, Reliability & Glue

> Capability-level only — Opal ships **no** source URLs. Every source is opt-in
> and configured locally (`~/.config/opal/`, source-neutral by design).

### 6.1 — Content breadth (recent)
- [x] Live TV: thumbnails, filters (category / country / quality / sort),
      favorites & recents, live/dead stream health probing, per-stream headers
- [x] Music vertical — streaming **and** self-hosted library, source selector,
      cover art, direct-to-player audio
- [x] Manga/comics: client for a self-hosted extension server (reach the full
      community extension ecosystem), + more catalog engines
- [x] NSFW controls centralized to Settings (never per-tab)
- [x] Music local downloads, synced lyrics, and a data-driven source interface
- [ ] Music waveform seekbar and broader multi-region source coverage
- [x] Auto-managed extension server (spawned/health-checked in-app, so users
      don't run a second app)

### 6.2 — Reliability ("what you click actually plays")
- [x] Shared reliable-fetch interface with browser-grade TLS fingerprinting,
      DPI bypass, response status/headers/latency, and typed failures
- [x] Migrate remaining legacy curl/native HTTP callers onto reliable-fetch
      (secrets via stdin config, multipart, file bodies, atomic downloads;
      only the ai_context SSE stream and core/deps/updater remain)
- [ ] App-wide persisted live/dead probing (the shared, race-safe probe/cache
      seam exists; PlaybackRequest integration and remaining vertical coverage
      are still in progress)
- [x] Candidate groups with auto-skip to the next working stream (ranked
      2-deep fallback chain; player advances on load failure)
- [x] First-class per-request headers (Origin/Cookie) into the player, cleared
      between unrelated loads

### 6.3 — Glue (one app, not fifteen tabs)
- [x] Universal resolver fan-out across video, local, torrent, comics, live TV,
      music, radio, podcasts, and catalog sources
- [x] Logical result groups with posters, semantic dedup, and fallback candidates
      ("N sources" expander; pick any source, rest stay as fallbacks)
- [x] Unified "Continue / Your Library" home across all verticals
      (`library_items` read-model fed by every vertical)
- [x] Cross-device progress + favorites sync over the local API
      (`/api/library/sync` pull/push, tombstones, Settings → Device Sync;
      single peer for now)

### 6.4 — Reach
- [ ] Real casting pipeline (Chromecast/DLNA) + a phone "couch-mode" cast-picker
      on the existing remote API

---

## 🌌 Milestone 7 — Horizon (v10)

> The media runtime as it should feel in 2076: you never search, wait, buffer,
> or lose your place. Opal understands every file, knows who is watching and
> what language they speak, and follows you between screens — locally,
> privately, on your own hardware. Capability-level only; still no shipped
> source URLs.

**Wave 1 (review branch):** 7.1–7.5 · **Wave 2:** 7.6–7.8

Wave 1 verification (2026-10-28): isolated headless checks cover Recall results,
signed streaming/progress/stop, profile PIN/restart/account continuity/data
isolation, chapter skipping, local signed handoff, and real Whisper captions
across overlapping chunks. Browser behavior tests cover Recall, streaming
request ordering and profile PIN errors. Visual browser, physical casting,
embedding-model search, fingerprint duplicates, translation-model output and
recap-model output still need end-to-end verification; unchecked capabilities
below are not claims of complete verification.

### 7.1 — Recall (semantic memory)
- [ ] Natural-language search across library + catalog ("cozy 90s mystery
      under 2h", "something like Invincible"): FTS5 + sqlite-vec fusion with a
      tested constraint parser
- [ ] Moment search inside media ("the scene where they plan the heist") over
      subtitle/transcript cues → play at that second
- [ ] Assistant + voice tools for semantic search and moment jumps

### 7.2 — Perception (media understanding)
- [ ] Intro / credits detection for any series (cross-episode audio
      fingerprinting + chapter names) → Skip button or auto-skip
- [ ] Duplicate detection (perceptual hashing) and auto chapters

### 7.3 — Household
- [ ] Profiles with PIN and kids mode (maturity cap, NSFW forced off)
- [ ] Per-profile history, library, recommendations, and sync identity

### 7.4 — Continuum (play anywhere)
- [ ] On-demand direct-play / remux / HW transcode to browsers and phones
- [ ] One-tap handoff to a paired device at the exact second; "bring it here"
- [ ] Phone couch-mode cast picker over the real casting pipeline

### 7.5 — Babel (every language, every file)
- [ ] Live captions: ahead-of-playhead whisper transcription of anything playing
- [ ] On-device subtitle translation (any track → your language)
- [ ] Spoiler-safe "Previously on…" recaps built only from what you watched

### 7.6 — Resilience
- [ ] Persisted app-wide live/dead probing feeding ranking and fallback order
- [ ] Predictive pre-resolve of the next episode (zero-wait "next")

### 7.7 — Commons
- [ ] Addon repositories (user-added URLs only) with signed manifests and
      permission prompts; plugin UI panels
- [ ] Shareable moments (timestamped clips) to paired devices + household feed

### 7.8 — Craft
- [ ] Theming v2: refined tokens, interaction states, elevation (in progress)
- [ ] Architecture + build docs; `linker_options` lint; dvui deinit warnings

---

## 📝 Technical Debt & Cleanup
- [ ] Fix `linker_options` lint in build.zig
- [ ] Clean up dvui deinit warnings
- [x] Run-scoped resolver lifecycle with typed terminal source outcomes
- [x] Add test suite for resolver/search lifecycle and ranking logic
- [ ] Documentation (README, build guide, architecture)
- [x] Fix TemporaryUserAgent in OpenSubtitles requests
- [x] Clean sqlite-vec.h TODO
