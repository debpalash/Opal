# Changelog

## 0.2.0

### New sources & media classes
- **Radio** — new media class: RadioBrowser internet radio (~50k stations, keyless, default-on).
- **Podcasts** — new media class: iTunes search → RSS → audio streaming (desktop + web).
- **Internet Archive** — public-domain video search, plus intent-aware **audio** (LibriVox / etree).
- **NASA** and **Wikimedia Commons** — legal, default-on direct-play video sources.
- **OMDb ratings** — IMDb / Rotten Tomatoes / Metacritic on the movie/TV detail view (free user key).
- **TVmaze** episode air-dates + next-episode countdown; **AniList** anime metadata enrichment.
- **Torznab / Prowlarr / Jackett** generic adapter — point at your own indexer aggregator (ships inert).
- **Knaben** aggregator engine + a curated **Stremio addon pack** (installable, inert until enabled).
- Subtitles: keyless **Stremio OpenSubtitles-v3** provider, and **Subdl** (keyed, with in-process ZIP extraction).
- Fixed a plugin-manifest cap that silently dropped sources past #32 (raised 32 → 128).

### Web companion
- Jellyfin / Anime / RSS / Podcasts tabs; SSE status push; queue reorder; poster cards + Jellyfin poster proxy.

### Performance & stability
- Poster/thumbnail failure-latches (stop dead URLs re-spawning workers every frame).
- Torrent chrome per-frame libtorrent/mpv polls cached; comics & YouTube grids virtualized.
- Web client: bounded polls, no-op DOM rebuilds skipped; language-learning health probe moved off the render thread.
- Torrent wrapper: fixed a data race (locked vector access), atomic session pointer, proxy-stop on delete, dead-slot growth.
- Comics download use-after-free, extractor player race, and player `@panic`s → graceful degrade.
- Fixed the first-launch "Nothing loaded" race in Movies & TV (config-ready barrier + bounded retry).

### Settings & polish
- Every persisted toggle now actually takes effect on startup (audio EQ, video filters, download limit, …).
- Video letterbox fix (aspect-preserving fullscreen); dev-binary macOS app identity.
