<div align="center">
  <img src="assets/opal_logo.png" alt="Opal logo" width="220" />

  # Opal

  **Play everything.**

  _One fast native binary. Every screen you'd otherwise open to watch something._
</div>

---

Opal is a local-first media app written in **Zig**, with an immediate-mode
[dvui](https://github.com/david-vanderson/dvui) interface and an **mpv** heart.
It plays your files, streams magnets while they download, browses movies, TV,
anime, comics, YouTube, and your Jellyfin server — and answers one search across
all of them at once. There's a local AI on board that talks, listens, and
remembers. None of it leaves your machine.

No accounts. No telemetry. No cloud. Your watch history is a SQLite file you own.

---

## Why you'll like it

- **One binary does the whole job.** Player, browser, universal search, torrent
  streamer, AI assistant — a single fast executable that opens instantly and
  stays quiet when idle.
- **Search once, get everything.** A query fans out across Jellyfin → Stremio
  add-ons → torrents → anime → YouTube → local files → TMDB → comics, and comes
  back ranked.
- **Magnets behave like files.** libtorrent piece-prioritization means you press
  play on a magnet link and you're watching in seconds, not after the download.
- **The AI is *yours*.** Local LLM chat with tool use, Whisper speech-to-text,
  Piper/Kokoro voices, hands-free conversation with barge-in, and vector memory
  in sqlite-vec. No API bill, no "your data helps us improve."
- **It ships clean.** The core app contains zero scraping code. Content sources
  are external plugins that *you* choose to install — see
  [`CONTENT_POLICY.md`](CONTENT_POLICY.md).
- **It sweats the details.** Design tokens, a compact type ramp, animated
  everything, confirm-gated destructive actions, and a render loop that only
  repaints when something actually changed.

## The tour

| | |
|---|---|
| ▶️ **Play** | mpv playback with subtitles, auto-subs & whisper-generated subs, SponsorBlock, Chromecast, LAN watch-party, session restore |
| 🔭 **Discover** | TMDB, anime (Jikan/AniList/allanime), comics & manga reader, Jellyfin, YouTube (Piped + yt-dlp), Stremio add-ons, RSS, taste-based recommendations |
| 🗂️ **Organize** | Watch/search/download history, continue-watching, queue — all in one local SQLite DB |
| 🤖 **AI & Voice** | Local LLM (llama-server/Gemma) with tools, STT/TTS, live OCR (ONNX PP-OCR), language-learning mode with flashcards |
| 🌐 **Remote** | JSON API on `:41595` (bearer auth) + a companion web UI on `:3000` |

---

## Build it

**Requirements:** Zig **0.16.x** and a handful of native friends:

```sh
brew install zig mpv sqlite onnxruntime sdl2
# plus: libtorrent-rasterbar, g++ (torrent wrapper), ffmpeg/whisper-cpp for voice
```

```sh
git clone https://github.com/debpalash/Opal.git
cd Opal
zig build run        # first build is slow; incrementals are fast
```

For hacking: `./dev.sh` (hot-reload loop that survives C changes), `just hot`
(millisecond incremental rebuilds), `just release` (ReleaseFast),
`just app` (macOS `Opal.app` bundle).

**Platform notes:** macOS hard-codes `/opt/homebrew/{lib,include}`. On
Linux/Wayland use `make run` (the bundled SDL2 is X11-only).

First launch: open **Settings** and paste your **TMDB v4 token** to light up
movie/TV browsing. Voice/AI models are opt-in downloads, one button each.

## Test it

```sh
just test-all       # the comprehensive gate — must stay 0 fail
zig build test      # pure-Zig unit tests only (fast)
```

`fail` = real regression. `skip` = optional component not installed. That's the
contract.

---

## Where your stuff lives

XDG-compliant, no surprises:

- `~/.config/opal/` — config, tokens (`0600`), and `opal.db` (history, AI memory)
- `~/.cache/opal/` — caches
- `~/Downloads/opal` — default downloads
- `~/.config/opal/plugins/<name>/` — content plugins (`manifest.json` + a
  `search`/`resolve` executable that prints JSON; Lua runs sandboxed, native
  binaries don't — install only what you trust)

## How it's built

```
src/
├── main.zig     # appFrame() — one function per frame, immediate mode
├── core/        # alloc, state, config, paths, io shim, sqlite (+sqlite-vec)
├── player/      # mpv wrapper, playlists, subtitles, watch history
├── services/    # search, AI, torrents, jellyfin, remote API, ...
└── ui/          # dvui widgets — theme tokens, shell, grid, player chrome
web/             # companion web UI (its own Zig project)
```

One global allocator, fixed-size buffers over heap churn, a single `state.app`
hub, and a threaded-Io shim for Zig 0.16. The full house rules live in
[`CLAUDE.md`](CLAUDE.md).

## Contributing

Yes please — read [`CONTRIBUTING.md`](CONTRIBUTING.md) and the
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md), run `just test-all`, and report the
tally in your PR.

## License

**GPL-3.0** (see [`LICENSE`](LICENSE), [`NOTICE.md`](NOTICE.md)) — the honest
choice for a program linked against libmpv. Bundled dependencies keep their own
licenses (libtorrent BSD, dvui/ONNX MIT, SDL2 zlib, SQLite public domain).

## The fine print

> **Opal is a player and an aggregator — it hosts, indexes, and distributes
> nothing.** It connects to sources *you* configure. Only access media you have
> the legal right to access in your jurisdiction; read
> [`CONTENT_POLICY.md`](CONTENT_POLICY.md) before enabling content plugins or
> torrent features. BitTorrent exposes your IP to the swarm — use a VPN if that
> matters to you.

Provided "as is", no warranty. The authors are not responsible for how the
software is used or for content reached through third-party sources.
