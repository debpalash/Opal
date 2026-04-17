# ZigZag ⚡ Roadmap

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

## 🔨 Milestone 2 — Media Center Essentials

### 2.1 — Subtitle Engine
- [ ] OpenSubtitles API integration (auto-search by filename hash)
- [ ] Subtitle track picker UI (embedded + external subs)
- [ ] Subtitle delay/sync adjustment
- [ ] Auto-download best match on play

### 2.2 — Metadata & Poster Art
- [ ] TMDB API integration (movies + TV shows)
- [ ] TVDB fallback for anime/obscure shows
- [ ] Poster grid view (Netflix-style browsable library)
- [ ] Metadata panel: synopsis, rating, cast, year, genre
- [ ] Auto-match filenames to TMDB IDs (fuzzy match)

### 2.3 — Series Tracking & Continue Watching
- [ ] Per-file watch progress persistence (resume points)
- [ ] "Continue Watching" row on home screen
- [ ] Season/episode navigation for series folders
- [ ] Auto-play next episode
- [ ] Watched/unwatched markers

### 2.4 — Player UX Polish
- [ ] Audio track picker UI
- [ ] Chapter navigation (if MKV has chapters)
- [ ] Keyboard shortcuts (space, arrows, F, S, M, etc.)
- [ ] Screenshot capture (save frame to disk)
- [ ] Playback speed controls in UI

---

## 🧠 Milestone 3 — AI Features (The Differentiator)

### 3.1 — Local LLM Integration (Bonsai-8B via llama.cpp)
- [ ] Bundle/link llama.cpp as C library (PrismML fork for 1-bit kernels)
- [ ] Model manager: download/load GGUF models from settings
- [ ] Natural language search: "find me something like Invincible"
- [ ] Smart recommendations based on watch history
- [ ] Chat assistant panel: ask questions about media, get suggestions
- [ ] Filename parser: intelligently extract show/season/episode from messy names

### 3.2 — Whisper Auto-Subtitles
- [ ] whisper.cpp integration (C library, runs on GPU)
- [ ] Generate subtitles for ANY local file with no internet
- [ ] Language detection + multi-language support
- [ ] Export generated subs as .srt files
- [ ] Real-time live transcription mode

### 3.3 — Smart Media Intelligence
- [ ] Auto-skip intro/outro detection (audio fingerprinting)
- [ ] Content tagging: auto-detect genre, quality, language from content
- [ ] Duplicate detection across library
- [ ] Smart collections: auto-group related media

---

## 🌐 Milestone 4 — Ecosystem & Connectivity

### 4.1 — External Service Sync
- [ ] Trakt.tv integration (scrobble watch progress)
- [ ] AniList sync (anime tracking)
- [ ] SIMKL integration
- [ ] Import/export watch history

### 4.2 — Remote Access & Casting
- [ ] Web remote control (extend existing web/ UI)
- [ ] DLNA/UPnP renderer discovery + casting
- [ ] Chromecast support
- [ ] Transcoding pipeline (FFmpeg → serve to other devices)

### 4.3 — Multi-User & Profiles
- [ ] User profile system (separate watch history, preferences)
- [ ] PIN-protected profiles
- [ ] Per-user recommendations

---

## 🔮 Milestone 5 — Future Vision

### 5.1 — Plugin System
- [ ] Lua/WASM plugin API for custom sources
- [ ] Community addon repository
- [ ] Custom UI panels via plugins

### 5.2 — Social Features
- [ ] Watch party (sync playback over network)
- [ ] Share clips/timestamps
- [ ] Activity feed

### 5.3 — Mobile Companion
- [ ] Android client (stream from ZigZag server)
- [ ] iOS client
- [ ] Offline sync (download for mobile playback)

---

## 📝 Technical Debt & Cleanup
- [ ] Fix `linker_options` lint in build.zig
- [ ] Clean up dvui deinit warnings
- [ ] Improve error handling across resolver backends
- [ ] Add test suite for resolver/search logic
- [ ] Documentation (README, build guide, architecture)
