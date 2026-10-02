<div align="center">
  <img src="assets/readme/hero.webp" alt="Opal — Play everything. From one app. The Movies & TV browser floats over an opalescent glass backdrop." width="100%" />

# Opal

### Your media, in one place.

A free, open-source, local-first **media player and browser**. Movies, TV, anime,
**live TV / IPTV**, YouTube, torrents, and manga — plus your own **Jellyfin & Plex**
libraries and an optional **on-device AI copilot**.

  <p>
    <a href="../../actions/workflows/ci.yml"><img src="https://github.com/debpalash/Opal/actions/workflows/ci.yml/badge.svg" alt="CI status" /></a>
    <a href="../../releases"><img src="https://img.shields.io/github/v/release/debpalash/Opal?include_prereleases&color=8b5cf6&label=release" alt="Latest release" /></a>
    <a href="../../releases"><img src="https://img.shields.io/github/downloads/debpalash/Opal/total?color=8b5cf6&label=downloads" alt="Total downloads" /></a>
    <a href="../../stargazers"><img src="https://img.shields.io/github/stars/debpalash/Opal?color=8b5cf6&label=stars" alt="GitHub stars" /></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="License: GPL-3.0" /></a>
    <img src="https://img.shields.io/badge/zig-0.16-f7a41d" alt="Written in Zig 0.16" />
    <img src="https://img.shields.io/badge/platforms-macOS%20%C2%B7%20Linux%20%C2%B7%20Windows%20(alpha)-lightgrey" alt="Runs on macOS and Linux; Windows is alpha" />
  </p>

  <p>
    <a href="#get-it"><b>Download & install</b></a> &nbsp; · &nbsp;
    <a href="#see-it"><b>Watch the demos</b></a> &nbsp; · &nbsp;
    <a href="https://opal.palash.dev"><b>Visit the website ↗</b></a>
  </p>
  <p>
    <a href="#why">Features</a> ·
    <a href="#building-from-source">Build from source</a> ·
    <a href="#under-the-hood">Under the hood</a> ·
    <a href="#support">Support the project</a>
  </p>
</div>

Opal searches your enabled providers, opens playable media and reading results,
and remembers where you left off. Personal libraries need a configured server;
catalog entries can lead to details or a source search. The player, browser,
torrent streamer, and AI live in one native app built with
[Zig](https://ziglang.org), [dvui](https://github.com/david-vanderson/dvui), and **mpv**.

| Local history | No telemetry | Optional local AI | Free software |
|:---:|:---:|:---:|:---:|
| A SQLite file you own | No usage tracking | Models run on your machine | No subscription |

<a id="see-it"></a>

## See Opal in action

### Browse without the tab overload

Explore trending titles, genres, and sources from one native window.

<a href="assets/media/browse.mp4"><img src="assets/readme/browse.gif" width="100%" alt="Animated Opal demo: scroll the movie poster wall, then switch to the YouTube source, inside a framed window on an opalescent backdrop." /></a>

[Watch the browse recording →](assets/media/browse.mp4)

### Start watching while it downloads

Play a torrent result directly. The stream downloads around playback;
available peers are required.

<a href="assets/media/stream-a-torrent.mp4"><img src="assets/readme/torrent.gif" width="100%" alt="Animated Opal demo: start a Sintel torrent and watch playback while it downloads, framed against an opalescent backdrop." /></a>

[Watch the streaming recording →](assets/media/stream-a-torrent.mp4) ·
<sub>Sintel, © Blender Foundation, CC BY 3.0.</sub>

### Let your own AI find the next watch

An optional local model answers with playable suggestions. Models are opt-in;
no API key or AI subscription is needed.

<a href="assets/media/ask-the-ai.mp4"><img src="assets/readme/ai.gif" width="100%" alt="Animated Opal demo: a suggestion chip prompts the local AI, which responds with recommendations and a poster rail." /></a>

[Watch the AI recording →](assets/media/ask-the-ai.mp4)

<sub>The GIFs use existing demo recordings; the stills below show the refreshed desktop toolbar.</sub>

<table>
  <tr>
    <td width="50%" valign="top">
      <a href="assets/readme/search.webp"><img src="assets/readme/search.webp" width="100%" alt="Opal universal search with Sintel results and play or queue actions, presented in an opalescent screenshot card." /></a><br/>
      <b>One query. Every source.</b><br/>
      <sub>Search supported, enabled providers for files, streams, reading results, and title details. Click the image for a closer look.</sub>
    </td>
    <td width="50%" valign="top">
      <a href="assets/readme/player.webp"><img src="assets/readme/player.webp" width="100%" alt="Big Buck Bunny playing in Opal, with quality, audio, subtitle, and translation controls, presented in an opalescent screenshot card." /></a><br/>
      <b>Press play. Settle in.</b><br/>
      <sub>Quality, audio tracks, subtitles, and live translation stay close at hand. Big Buck Bunny, © Blender Foundation, CC BY 3.0.</sub>
    </td>
  </tr>
</table>

<a id="get-it"></a>

## Get Opal

One command — detects your platform, verifies checksums, doubles as the updater
(`… -s -- update`) and version pin (`OPAL_VERSION=v0.1.0 …`). On Linux it
installs to `~/.local` and never needs `sudo`:

```sh
curl -fsSL https://raw.githubusercontent.com/debpalash/Opal/main/scripts/install.sh | sh
```

For a system-wide Linux install through `apt`, `dnf`, `zypper`, or an AUR
helper, opt in explicitly (root or `sudo` is required):

```sh
curl -fsSL https://raw.githubusercontent.com/debpalash/Opal/main/scripts/install.sh | OPAL_SYSTEM=1 sh
```

**Linux release requirements:** standard artifacts require **glibc 2.38+**.
For Ubuntu **20.04/22.04**, Debian **12** and Mint **21**, v0.8.8 adds
`opal_<version>_compat_amd64.deb` with a private media runtime and **glibc 2.31+**.
The installer chooses it automatically; `OPAL_SYSTEM=1` installs via apt, while
normal installation extracts it into your user prefix. Playback uses software
decoding and X11/XWayland. No system libraries are replaced. See the
[compatibility build](packaging/linux-compat/README.md) for details.
The standard `.deb` requires `libmpv2` and `libtorrent-rasterbar2.0` from your
repositories (Ubuntu **24.04+**, Debian **13+**). AppImage requires glibc 2.38+.

Or pick your row — every file is on [Releases](../../releases):

|  | Platform | Install |
|---|---|---|
| 🍎 | **macOS** (Apple silicon) | open the `.dmg`, drag, done |
| 🍺 | **Homebrew** | `brew install debpalash/tap/opal` |
| 📦 | **Debian / Ubuntu** | `sudo apt install ./opal_<version>_amd64.deb` (use `_compat_amd64.deb` on older hosts) |
| 🎩 | **Fedora / openSUSE** | `sudo dnf install ./opal-*.x86_64.rpm` |
| 🏹 | **Arch / Omarchy / Pacman** | `sudo pacman -U ./opal-*-x86_64.pkg.tar.zst` |
| 📚 | **AUR** | `yay -S opal-media-player-bin` · `paru -S opal-media-player-bin` (or `opal-media-player` to build) |
| 🐧 | **Linux (glibc 2.38+)** | `chmod +x Opal-*.AppImage` and run it |
| 🪟 | **Windows** (x64) — **alpha** | run the `.msi` — or unzip the portable `.zip` |
| 🛠 | **From source** | `git clone` → `zig build run` |

<details>
<summary><b>Platform notes, first launch, and playback options</b></summary>

**Arch Linux, Omarchy, Manjaro, EndeavourOS** — Opal is on the AUR as
[`opal-media-player-bin`](https://aur.archlinux.org/packages/opal-media-player-bin)
(the official release binary) and
[`opal-media-player`](https://aur.archlinux.org/packages/opal-media-player)
(builds from source with zig). The two conflict; install one.

```sh
yay -S opal-media-player-bin          # AUR helper (or: paru -S opal-media-player-bin)
yay -S opal-media-player              # build from source instead

# no AUR helper — let makepkg call pacman
git clone https://aur.archlinux.org/opal-media-player-bin.git
cd opal-media-player-bin && makepkg -si

# straight from the release, no AUR
sudo pacman -U ./opal-*-x86_64.pkg.tar.zst
```

Update later with `yay -Syu` or `sudo pacman -Syu`.

Homebrew installs the self-contained macOS `.app` bundle; `opal` launches that
app directly. No Homebrew mpv or FFmpeg dependency is needed to install it.

<sub>🍎 macOS may call the `.dmg` **"damaged"** — it isn't; we're not Apple-notarized
yet. The one-command installer skips the dialog, or run `sudo xattr -cr
/Applications/Opal.app` once. 🍎 Intel Macs: build from source
(`HOMEBREW_PREFIX=/usr/local`).</sub>

> [!WARNING]
> **Windows support is alpha.** It is the newest port and is not yet at parity
> with macOS and Linux — expect rough edges and bugs the other two do not have.
> SmartScreen will also want a word. Please do
> [file issues](https://github.com/debpalash/Opal/issues); they are what moves it
> forward. macOS (Apple silicon) and Linux x86_64 are the supported platforms.

Start on Home with **Search all sources** or **Browse movies & TV**. The
navigation bar's Search opens universal results from anywhere. On compact
windows, Search is also under **More**; playback controls are under
**More → Playback options**, and workspace, remote, theme and shortcut tools
are under **More → More tools**.

On smaller Windows displays, Opal fits its initial window inside the usable
desktop area. The bottom Now Playing bar stays visible while media plays;
use its **×** to stop and close it. Movies & TV keeps search and filters in one
icon toolbar:
hover an icon for its name, and scroll across the toolbar in a narrow window.
Poster cards keep list actions and **Details** available without hover; selected
lists stay highlighted. Universal search uses compact rows and groups YouTube
trailers and teasers separately; click a result row or its Play button to start
playback, or **+** to queue a torrent. Install sources from
**Settings → General → Install source plugins**; the source catalog reports
the last operation and links to redacted Logs.

For temporary torrent playback, enable **Settings → Network → Stream torrents in memory**.
Choose a **128, 256 (default), or 512 MiB** payload buffer per torrent. New torrents
keep media and torrent caches in RAM, download around the requested playback
position, and discard older pieces. Closing or replacing the stream releases its
buffer. Seeking into discarded data downloads it again. Existing transfers keep
their storage mode; playback still needs available peers. Player/decoder memory
is additional, and the operating system may swap RAM to disk.

Deleting a playing torrent stops its stream before removing the download, and
the empty player offers **Open file** or **Browse search**. To hand playback to
VLC, install VLC and choose **Settings → Playback → Open in VLC** while media
is playing; VLC is optional and Opal reports if it is not installed. Source
installation shows its current step and an error or success result; redacted
Logs include the failed step and a recovery procedure.

The Linux AppImage uses the system's OpenSSL 3 libraries alongside system
`libcurl` (rather than bundling an older OpenSSL that conflicts on rolling
distributions). The AppImage requires `libssl.so.3` and `libcrypto.so.3` on
the host.

**First launch:** The welcome screen offers keyless Movies & TV browsing and
optional one-click source installation for universal search. Choose **Home** to
open local files instead. Add a free **TMDB v4 token** in **Settings**
(<kbd>⌘</kbd><kbd>,</kbd>) for richer metadata. Voice and AI models remain
opt-in; nothing downloads itself. Reopen the welcome screen from
**Settings → About**.

</details>

<a id="building-from-source"></a>
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

On macOS 14, current Homebrew FFmpeg/mpv dependencies have no working bottle
closure. Instead of `brew install mpv ffmpeg`, install
`sqlite sdl2 libtorrent-rasterbar libass libplacebo meson ninja pkgconf`, then run
`./scripts/install-macos-ffmpeg.sh` and `./scripts/install-macos-mpv.sh`
before `zig build run`. These build shared libraries from checksum-pinned
source with macOS 13 as the minimum deployment target.

**Minimum versions (Linux source builds):** libtorrent-rasterbar **2.0** or
newer and libmpv **0.34** or newer (mpv 0.38+ recommended;
Ubuntu 22.04's 0.34 works — Opal picks the `loadfile` argument shape from the
library version at runtime), SDL **2.0.22** or newer when building against the
system SDL via `make run` (jammy's 2.0.20 lacks `SDL_PIXELFORMAT_RGBX32`).
Standard Linux artifacts need **glibc 2.38**; Debian 12 / Mint 21 can use the
compatibility package or build from source. Ubuntu 20.04's stock mpv and libtorrent are below the source-build
minimums; those libraries also need upgrading before compiling. A rejected
`loadfile` is now reported in the app's log and as a toast rather than hanging
on "Opening stream".

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

`fail` = real regression. `skip` = optional component not installed. That's the
contract — every PR reports its tally (see
[`CONTRIBUTING.md`](.github/CONTRIBUTING.md)).

</details>

<details>
<summary><b>📁 Where your stuff lives</b></summary>

<br/>

XDG-compliant:

- `~/.config/opal/` — config, tokens (`0600`), and `opal.db` (history, AI memory)
- `~/.cache/opal/` — caches
- `~/Downloads/opal` — default downloads
- `~/.config/opal/plugins/<name>/` — content plugins (`manifest.json` + a
  `search`/`resolve` executable that prints JSON; Lua runs sandboxed, native
  binaries don't — install only what you trust)

</details>

<a id="why"></a>

## One app instead of ten

| Instead of… | Opal gives you |
|---|---|
| **Stremio / Kodi** + a pile of add-ons | one search across supported, enabled providers, with playback, reading, and detail actions |
| **an IPTV / live-TV app** | ~40,000 live channels, searchable as you type |
| **Jellyfin / Plex** web clients | your own media servers, browsed natively |
| **Tachiyomi / Mihon** stuck on your phone | manga extensions on the desktop — server bundled, self-managed |
| **a torrent client** + a player | magnet → instant streaming while it downloads |
| **ChatGPT** for *"what do I watch?"* | a local AI copilot — no key, no bill, no feed |
| **SponsorBlock · subtitle sites · Chromecast apps** | all built in |

Plus a player that sweats the details — auto subtitles, watch-party, phone
remote (`:41595`), session restore — and a drawer full of extras: OCR on video
frames, language flashcards, RSS, incognito, seven themes, a JSON API (`:41595`).
Where it's all going: [`ROADMAP.md`](ROADMAP.md).

## ⌨️ Keyboard-first, remote-friendly

| | | | |
|---|---|---|---|
| <kbd>S</kbd> search | <kbd>B</kbd> browser | <kbd>D</kbd> library | <kbd>H</kbd> history |
| <kbd>F</kbd> fullscreen | <kbd>P</kbd> playlist | <kbd>G</kbd> grid layout | <kbd>Z</kbd> fit/crop |
| <kbd>⌘</kbd><kbd>O</kbd> open file | <kbd>⌘</kbd><kbd>,</kbd> settings | <kbd>Esc</kbd> back out | <kbd>⇧</kbd><kbd>I</kbd> **cheat sheet** |

**📱 From your phone:** Settings › Web UI → *Enable Web UI*, set *Network* to
**LAN**, then scan the QR code shown there (it carries the one-time setup code
on first use). That opens `http://<your-pc-ip>:41595` in the phone's browser —
plain HTTP on your own network, no account or cloud involved. Installing it as
a home-screen app needs a secure context (HTTPS); see
[docs/web-companion.md](docs/web-companion.md).

## 🧩 Browser extension

**Opal Connect** (Chrome / Edge / Firefox) turns any tab into an Opal action —
send or queue a video, add a manga/novel site as a source, or drive playback
from a side-panel remote.

<div align="center">
  <a href="assets/readme/connect.webp"><img src="assets/readme/connect.webp" alt="Opal Connect browser side panel with page actions, playback controls, and cross-source search, framed over an opalescent backdrop." width="100%" /></a>
</div>

**Install** — grab the Chrome/Edge or Firefox build from the
[latest release](../../releases/latest) (unzip → load unpacked), or build from
`extension/` (`npm install && npm run build`). Pair it with your Opal API token
and every action routes to the desktop app —
[`extension/README.md`](extension/README.md).

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
extension/       # Opal Connect — cross-browser MV3 extension
```

Player, search, torrent streamer, and AI compile to **one native binary**: a
single leak-checked allocator, fixed-size buffers over heap churn, one
`state.app` hub under strict thread-safety rules, and a render loop that
repaints only on change. House rules in
[`CONTRIBUTING.md`](.github/CONTRIBUTING.md).

Content sources ship **off** — nothing enables itself. You install endpoints
from the plugin registry, and un-install them just as fast
([`CONTENT_POLICY.md`](docs/CONTENT_POLICY.md)).

<a id="support"></a>

## 💜 Support

No telemetry to monetize, no accounts to upsell — Opal runs on goodwill:

- ☕ **[Ko-fi](https://ko-fi.com/debpalash)** or 💸 **[PayPal](https://paypal.me/palashCoder)** — keep the releases (and the coffee) coming.
- ⭐ **Star the repo** — it's how people find it.
- 🐛 **File good bugs** ([how](.github/SUPPORT.md)) · 🔧 **send PRs** ([how](.github/CONTRIBUTING.md)).
- 📣 **Show someone** — the GIFs above are yours to share.

## 🤝 Contributing

Yes please — read [`CONTRIBUTING.md`](.github/CONTRIBUTING.md), run
`just test-all`, and report the tally in your PR. Questions live in
[Discussions](../../discussions); the help map is in
[`SUPPORT.md`](.github/SUPPORT.md).

## 📜 License

**GPL-3.0** ([`LICENSE`](LICENSE), [`NOTICE.md`](docs/NOTICE.md)) — the honest
choice for a program linked against libmpv. Bundled dependencies keep their own
licenses (libtorrent BSD, dvui/ONNX MIT, SDL2 zlib, SQLite public domain).

## The fine print

> **Opal is a player and an aggregator — it hosts, indexes, and distributes
> nothing.** It connects to sources *you* configure; only access media you have
> the legal right to access in your jurisdiction
> ([`CONTENT_POLICY.md`](docs/CONTENT_POLICY.md)). BitTorrent exposes your IP to
> the swarm — use a VPN if that matters to you. Rights holders:
> [`docs/DMCA.md`](docs/DMCA.md). Provided "as is", no warranty.

<br/>

<div align="center">
  <img src="assets/logo.svg" width="40" alt="" /><br/>
  <sub>Built with Zig, mpv, and dvui. Yours since first launch.</sub>

  <br/><br/>
  <sub>
  <b>Opal</b> — open-source media player · IPTV / live TV player · torrent streaming ·
  Jellyfin & Plex client · YouTube desktop app · manga reader (Mihon / Tachiyomi / Suwayomi) ·
  local AI copilot · self-hosted Stremio & Kodi alternative · for macOS and Linux (Windows alpha).
  </sub>
</div>

Browse source details, supported discovery paths, and live-check limitations: [Browse sources](docs/browse-sources.md).
