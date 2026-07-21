<div align="center">
  <img src="assets/logo.svg" alt="Opal logo" width="150" />

  # Opal

  ### Play everything. From one app.

  **A free, open-source, local-first media player + browser.** Search and stream
  movies, TV, anime, **live TV / IPTV**, YouTube, torrents, and manga — alongside
  your own **Jellyfin & Plex** — with a **private, on-device AI copilot**. One fast
  native binary. No accounts, no cloud, no subscription. The self-hosted
  alternative to Stremio, Kodi, and the whole streaming stack.

  <p>
    <a href="../../actions/workflows/ci.yml"><img src="https://github.com/debpalash/Opal/actions/workflows/ci.yml/badge.svg" alt="CI status" /></a>
    <a href="../../releases"><img src="https://img.shields.io/github/v/release/debpalash/Opal?include_prereleases&color=8b5cf6&label=release" alt="Latest release" /></a>
    <a href="../../releases"><img src="https://img.shields.io/github/downloads/debpalash/Opal/total?color=8b5cf6&label=downloads" alt="Total downloads" /></a>
    <a href="../../stargazers"><img src="https://img.shields.io/github/stars/debpalash/Opal?color=8b5cf6&label=stars" alt="GitHub stars" /></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="License: GPL-3.0" /></a>
    <img src="https://img.shields.io/badge/zig-0.16-f7a41d" alt="Written in Zig 0.16" />
    <img src="https://img.shields.io/badge/platforms-macOS%20%C2%B7%20Linux%20%C2%B7%20Windows-lightgrey" alt="Runs on macOS, Linux, and Windows" />
  </p>

  <p>
    <a href="#get-it"><b>Get it</b></a> ·
    <a href="#see-it"><b>See it</b></a> ·
    <a href="#the-ai"><b>The AI</b></a> ·
    <a href="#under-the-hood"><b>Under the hood</b></a> ·
    <a href="#support"><b>Support Development</b></a>
    (<a href="https://ko-fi.com/debpalash">Ko-fi</a>, <a href="https://paypal.me/palashCoder">PayPal</a>)
  </p>

  <img src="assets/screenshots/home.png" alt="Opal home screen — a time-aware greeting, an ask-anything search box, and tonight's trending row of movies and shows" width="100%" />
</div>

<br/>

> [!TIP]
> **🔮 New in [v0.5.0](../../releases/tag/v0.5.0)** — a **~18,000-channel Live TV / IPTV** catalog with instant, virtualized search · **Mihon / Tachiyomi manga extensions** (Opal runs the Suwayomi server *for* you — install, browse, and read in-app) · a refined YouTube with **AV1-safe playback**. &nbsp;[See the full release →](../../releases/tag/v0.5.0)

Opal replaces the stack of apps you'd otherwise juggle — a player, a site for
the show, a server front-end, a torrent client, a feed. You say what you want
(a title, a file, a magnet), and it searches every source, plays anything, and
remembers where you left off. A local-first app written in
[Zig](https://ziglang.org) with a [dvui](https://github.com/david-vanderson/dvui)
interface and an **mpv** core: one native binary, fast to open, quiet when idle.

<div align="center">

| 🙅 No accounts | 📡 No telemetry | ☁️ No cloud | 💳 No subscription |
|:---:|:---:|:---:|:---:|
| nothing to sign up for | nothing phones home | your history is a SQLite file **you own** | it's your computer |

</div>

<a id="get-it"></a>

## 🚀 Get it

One command. It figures out your platform, verifies checksums, and it's also
the updater (`… -s -- update`) and version manager (`OPAL_VERSION=v0.1.0 …`):

```sh
curl -fsSL https://raw.githubusercontent.com/debpalash/Opal/main/scripts/install.sh | sh
```

Prefer to do it yourself? Find your row — every file is on the
[Releases](../../releases) page:

|  | Platform | The move |
|---|---|---|
| 🍎 | **macOS** (Apple silicon) | open the `.dmg`, drag, done |
| 🍺 | **Homebrew** | `brew install debpalash/tap/opal` |
| 📦 | **Debian / Ubuntu** | `sudo apt install ./opal_*_amd64.deb` |
| 🎩 | **Fedora / openSUSE** | `sudo dnf install ./opal-*.x86_64.rpm` |
| 🏹 | **Arch** | `yay -S opal-bin` (or `opal` to build) |
| 🐧 | **Any Linux** | `chmod +x Opal-*.AppImage` and run it |
| 🪟 | **Windows** (x64) | run the `.msi` — or unzip the portable `.zip` anywhere |
| 🛠 | **From source** | `git clone` → `zig build run` (deps below) |

<sub>🍎 macOS calls the downloaded `.dmg` **"damaged"** — it isn't; that's
Gatekeeper's way of saying we haven't paid Apple $99/yr for notarization yet.
Either use the one-command installer above (no quarantine, no dialog), or run
`sudo xattr -cr /Applications/Opal.app` once after dragging. 🪟 Windows builds are
the newest of the family — treat the first releases as adventurous (SmartScreen
will also want a word). 🍎 Intel Macs: source build works
(`HOMEBREW_PREFIX=/usr/local`).</sub>

**First launch:** open **Settings** (<kbd>⌘</kbd><kbd>,</kbd>) and paste a free
**TMDB v4 token** to light up movie/TV browsing. Voice and AI models are
opt-in downloads — one button each, nothing installs itself.

<details>
<summary><b>🧱 Building from source</b></summary>

<br/>

Zig **0.16.x** plus a handful of native friends:

```sh
brew install zig mpv sqlite onnxruntime sdl2
# plus: libtorrent-rasterbar, g++ (torrent wrapper), ffmpeg/whisper-cpp for voice

git clone https://github.com/debpalash/Opal.git
cd Opal
zig build run        # first build is slow; incrementals are fast
```

**Linux/Wayland:** use `make run` (forces system SDL2 — the bundled one is
X11-only). macOS builds read `HOMEBREW_PREFIX` (default `/opt/homebrew`).

</details>

<details>
<summary><b>🔧 For hackers: dev loops, tests, and the contract</b></summary>

<br/>

- `./dev.sh` — hot-reload loop that survives C changes; `-r` for ReleaseFast.
- `just hot` — native `--watch -fincremental`, millisecond rebuilds.
- `just release` / `just app` — ReleaseFast / macOS `Opal.app` bundle.

```sh
just test-all       # the comprehensive gate — must stay 0 fail
zig build test      # pure-Zig unit tests only (fast)
```

`fail` = real regression. `skip` = optional component not installed. That's
the contract — and every PR reports its tally
(see [`CONTRIBUTING.md`](CONTRIBUTING.md)).

</details>

<details>
<summary><b>📁 Where your stuff lives</b></summary>

<br/>

XDG-compliant, no surprises:

- `~/.config/opal/` — config, tokens (`0600`), and `opal.db` (history, AI memory)
- `~/.cache/opal/` — caches
- `~/Downloads/opal` — default downloads
- `~/.config/opal/plugins/<name>/` — content plugins (`manifest.json` + a
  `search`/`resolve` executable that prints JSON; Lua runs sandboxed, native
  binaries don't — install only what you trust)

</details>

## 🎯 The goal

**Become the true alternative to the whole stack** — the streaming apps, the
server front-ends, the trackers, the recommendation feeds — by being
**self-sufficient**: one interface that understands what you need and quietly
takes care of it, powered by an AI that runs on *your* hardware and answers to
*you*.

A media system shouldn't need a corporation attached. Discovery, curation,
memory, playback — Opal's bet is that all of it can live on your machine,
learn your taste without reporting it, and get out of the way. Every release
walks further in that direction ([`ROADMAP.md`](ROADMAP.md)).

---

<a id="see-it"></a>

<details open>
<summary><b>✨ The tour, in motion</b></summary>
<br/>

<table>
  <tr>
    <td width="50%" valign="top">
      <img src="assets/media/stream-a-torrent.gif" width="100%" alt="Press play on a torrent result; playback starts while it downloads" /><br/>
      <b>🧲 Magnets behave like files</b><br/>
      <sub>Press play on a torrent — you're watching while it downloads. <em>(Sintel, © Blender Foundation, CC-BY 3.0)</em></sub>
    </td>
    <td width="50%" valign="top">
      <img src="assets/screenshots/search.png" width="100%" alt="One query fanned out across every source, ranked" /><br/>
      <b>🔭 One search, every source</b><br/>
      <sub>Disk, torrents, Jellyfin, Plex, Stremio, anime, YouTube, live TV, TMDB, manga — one ranked, playable list.</sub>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="assets/media/browse.gif" width="100%" alt="Scrolling the trending wall, then switching to the YouTube tab" /><br/>
      <b>🗺️ Browse like you own the place</b><br/>
      <sub>Trending walls, genres, episode drill-downs — one tab bar, zero franchises acquired.</sub>
    </td>
    <td width="50%" valign="top">
      <img src="assets/media/ask-the-ai.gif" width="100%" alt="A suggestion chip answered by the local AI with a poster rail" /><br/>
      <b>🤖 An AI that lives on your machine</b><br/>
      <sub>Local LLM with tool use answers with playable picks — no API key, no bill, no feed.</sub>
    </td>
  </tr>
</table>

</details>

<a id="the-ai"></a>

## Why it sticks

- 🔭 **Search once, everything answers** — disk, torrents, Jellyfin, Plex,
  Stremio, anime, YouTube, live TV, TMDB, comics & manga → one ranked list, a
  play button on every row.
- 🧲 **Magnets behave like files** — piece-prioritized torrent streaming: press
  play on a magnet and you're watching while it downloads.
- 📺 **Live TV without the box** — a **~18,000-channel IPTV** catalog (iptv-org +
  FAST/DTT sources) with virtualized scrolling and instant, as-you-type search.
- 📚 **Manga & comics, extended** — a built-in reader *plus* **Mihon / Tachiyomi
  extensions**: Opal downloads and runs an embedded **Suwayomi** server for you,
  so you install extensions and read their sources without leaving the app.
- 🤖 **A local AI copilot** — *"what should I watch if I loved Interstellar?"*
  answered with playable picks; hands-free voice (Whisper ears, Piper/Kokoro
  mouth, barge-in); taste memory in on-disk `sqlite-vec`. No API key, no bill,
  no "your data helps us improve."
- ▶️ **A player that sweats details** — subtitles embedded, fetched, or
  Whisper-generated on the spot · SponsorBlock · Chromecast · LAN watch-party ·
  phone web remote (`:3000`) · session restore mid-sentence.
- 🗺️ **Browse like you own the place** — trending walls, genres, episode
  drill-downs across every source, including your Jellyfin and Plex.
- 🧰 **…and the drawer** — live OCR on video frames · language-learning
  flashcards · recommendations · history & queue · RSS · incognito
  (<kbd>I</kbd>) · seven themes · JSON API (`:41595`) for your own automations.

## 🆚 One app instead of ten

Opal is a free, open-source alternative to a whole shelf of tools — running
locally, on your hardware, answering to you:

| Instead of… | Opal gives you |
|---|---|
| **Stremio / Kodi** + a pile of add-ons | one search across every source, a play button on each row |
| **an IPTV / live-TV app** | ~18,000 live channels, searchable as you type |
| **Jellyfin / Plex** web clients | your own media servers, browsed natively |
| **Tachiyomi / Mihon** stuck on your phone | manga extensions on the desktop — server bundled and self-managed |
| **a torrent client** + a player | magnet → instant streaming while it downloads |
| **ChatGPT** for *"what do I watch?"* | a local AI copilot — no key, no bill, no feed |
| **SponsorBlock · subtitle sites · Chromecast apps** | all built in |

## ⌨️ Keyboard-first, remote-friendly

| | | | |
|---|---|---|---|
| <kbd>S</kbd> search | <kbd>B</kbd> browser | <kbd>D</kbd> library | <kbd>H</kbd> history |
| <kbd>F</kbd> fullscreen | <kbd>P</kbd> playlist | <kbd>G</kbd> grid layout | <kbd>Z</kbd> fit/crop |
| <kbd>⌘</kbd><kbd>O</kbd> open file | <kbd>⌘</kbd><kbd>,</kbd> settings | <kbd>Esc</kbd> backs out of things, politely | <kbd>⇧</kbd><kbd>I</kbd> **the cheat sheet** |

---

<a id="under-the-hood"></a>

## ⚙️ Under the hood

```
src/
├── main.zig     # appFrame() — one function per frame, immediate mode
├── core/        # alloc, state, config, paths, io shim, sqlite (+sqlite-vec)
├── player/      # mpv wrapper, playlists, subtitles, watch history
├── services/    # search, AI, torrents, jellyfin, remote API, ...
└── ui/          # dvui widgets — theme tokens, shell, grid, player chrome
web/             # companion web UI (its own Zig project)
extension/       # Opal Connector — cross-browser MV3 extension (play/read/download/scrape → Opal); see extension/README.md
```

The parts we're quietly proud of: the whole system — player, search, torrent
streamer, AI — compiles to **one fast native binary**; **one** global
allocator with leak detection on every exit; fixed-size buffers instead of
heap churn; a single `state.app` hub with disciplined thread-safety rules; a
render loop that repaints **only when something changed** (your fans will
thank us); and a threaded-Io shim for Zig 0.16. House rules in
[`CONTRIBUTING.md`](CONTRIBUTING.md); where this is all going in
[`ROADMAP.md`](ROADMAP.md).

Content sources ship **off**: the core has no sources configured and nothing
enables itself — you explicitly install endpoints from the plugin registry,
and you can un-install them just as fast
([`CONTENT_POLICY.md`](CONTENT_POLICY.md)).

<a id="support"></a>

## 💜 Support development

Opal has no telemetry to monetize and no account system to upsell — it runs on
goodwill:

- ☕ **[Buy the maintainer a coffee on Ko-fi](https://ko-fi.com/debpalash)** or
  💸 **[chip in via PayPal](https://paypal.me/palashCoder)** — donations keep
  the release cadence honest and the coffee supply uninterrupted.
- ⭐ **Star the repo** — it's genuinely how people find it.
- 🐛 **File good bugs** ([how](SUPPORT.md)) · 🔧 **send PRs** ([how](CONTRIBUTING.md)).
- 📣 **Show someone.** This pitch lands best as a 30-second demo — the GIFs
  above are yours to share.

## 🤝 Contributing

Yes please — read [`CONTRIBUTING.md`](CONTRIBUTING.md) and the
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md), run `just test-all`, and report the
tally in your PR. Questions live in [Discussions](../../discussions);
the full help map is in [`SUPPORT.md`](SUPPORT.md).

## 📜 License

**GPL-3.0** (see [`LICENSE`](LICENSE), [`NOTICE.md`](NOTICE.md)) — the honest
choice for a program linked against libmpv. Bundled dependencies keep their own
licenses (libtorrent BSD, dvui/ONNX MIT, SDL2 zlib, SQLite public domain).

## The fine print

> **Opal is a player and an aggregator — it hosts, indexes, and distributes
> nothing.** It connects to sources *you* configure. Only access media you have
> the legal right to access in your jurisdiction; read
> [`CONTENT_POLICY.md`](CONTENT_POLICY.md) before enabling content plugins or
> torrent features. BitTorrent exposes your IP to the swarm — use a VPN if that
> matters to you. Rights holders: see [`DMCA.md`](DMCA.md) for the takedown
> process.

Provided "as is", no warranty. The authors are not responsible for how the
software is used or for content reached through third-party sources.

<br/>

<div align="center">
  <img src="assets/logo.svg" width="40" alt="" /><br/>
  <sub>Built with Zig, mpv, and an unreasonable number of late nights.<br/>
  <b>Now go watch something.</b></sub>

  <br/><br/>
  <sub>
  <b>Opal</b> — open-source media player · IPTV / live TV player · torrent streaming ·
  Jellyfin & Plex client · YouTube desktop app · manga reader (Mihon / Tachiyomi / Suwayomi) ·
  local AI copilot · self-hosted Stremio & Kodi alternative · for macOS, Linux, and Windows.
  </sub>
</div>
