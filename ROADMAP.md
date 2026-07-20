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
- [ ] Music maturity — **local downloads** to a music dir, **synced lyrics**,
      **waveform seekbar**, and **multi-region** sources via a data-driven
      (pluggable) source interface, not a tab per source
- [ ] Auto-managed extension server (spawned/health-checked in-app, so users
      don't run a second app)

### 6.2 — Reliability ("what you click actually plays")
- [ ] One unified fetch path with browser-grade TLS fingerprinting + on-path
      DPI bypass, so anti-bot walls stop silently breaking playback
- [ ] App-wide live/dead surfacing (status dots + auto-skip to the next working
      candidate), generalized from the Live TV health model
- [ ] First-class per-request headers (Origin/Cookie) into the player

### 6.3 — Glue (one app, not fifteen tabs)
- [ ] Universal search that spans **every** vertical at once (finish the
      resolver fan-out; unified result model + posters + dedup)
- [ ] Unified "Continue / Your Library" home across all verticals
- [ ] Cross-device progress + favorites sync over the local API

### 6.4 — Reach
- [ ] Real casting pipeline (Chromecast/DLNA) + a phone "couch-mode" cast-picker
      on the existing remote API

---

## 📝 Technical Debt & Cleanup
- [ ] Fix `linker_options` lint in build.zig
- [ ] Clean up dvui deinit warnings
- [ ] Improve error handling across resolver backends
- [ ] Add test suite for resolver/search logic
- [ ] Documentation (README, build guide, architecture)
- [x] Fix TemporaryUserAgent in OpenSubtitles requests
- [x] Clean sqlite-vec.h TODO
