<div align="center">

<img src="assets/logo.svg" width="64" alt="Opal" />

# Opal — Your entertainment. Your sources. Your rules.

**The open-source everything media player & browser.**

Movies & TV · Torrents · YouTube · Live TV · Music · Podcasts · Radio<br>
Manga & Comics · Books & Novels · Audiobooks · Web · Local AI

A personal alternative to the Netflix-style streaming experience, a companion to
Plex and Jellyfin, and a home for the things you watch, listen to, read, and browse.
Bring your files, connect your servers, and install the sources you want.

Free and open source. No telemetry. No Opal subscription. Optional AI runs locally.

**[Download Opal](https://github.com/debpalash/Opal/releases/latest)** · [Explore features](#why) · [See it in action](#see-it) · [Website](https://opal.palash.dev)

macOS · Linux · Windows alpha · iOS preview

</div>

![Sintel playing in Opal’s native macOS app, with the media navigation and playback controls visible.](assets/readme/sintel-player.webp)

<sub>Native macOS UI preview with a paused film frame. Sintel © Blender Foundation, [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/). [Artwork credits](assets/readme/CREDITS.md).</sub>

- **Make it your movie night.** Play local files, stream torrents while they download, browse movies and TV, or connect your Plex and Jellyfin libraries.
- **Go beyond video.** Listen to music, podcasts, radio, and audiobooks. Read manga, comics, books, and novels. Browse the web inside Opal on macOS.
- **Build your own setup.** Add source plugins, cast to another screen, watch together, control playback from your phone, or let a local AI or coding agent help.

Opal is a player and source hub; it does not include a paid streaming catalog or
access to Netflix titles. Connected services and sources may require their own accounts.

[Quick install](#get-it) · [Demos](#see-it) · [Features](#why) · [Build from source](#building-from-source)

<a id="get-it"></a>

## Get Opal

One command detects your platform and verifies the download. Linux installs to
`~/.local` without `sudo`.

```sh
curl -fsSL https://raw.githubusercontent.com/debpalash/Opal/main/scripts/install.sh | sh
```

[Download a release instead →](../../releases/latest)

<details>
<summary><b>macOS</b> — Apple silicon, Homebrew, Intel builds</summary>

Open the `.dmg` and drag Opal to Applications, or install the self-contained app:

```sh
brew install debpalash/tap/opal
```

For an unnotarized DMG showing “damaged,” use the installer or run:

```sh
sudo xattr -cr /Applications/Opal.app
```

Intel Macs require a source build with `HOMEBREW_PREFIX=/usr/local`.

</details>

<details>
<summary><b>Linux</b> — AppImage, Debian, RPM, Arch</summary>

Standard builds require **glibc 2.38+**. Ubuntu 20.04/22.04, Debian 12, and Mint 21
should use `_compat_amd64.deb` (**glibc 2.31+**); the installer selects it automatically.
Compatibility builds use software decoding and X11/XWayland.
[Compatibility details](packaging/linux-compat/README.md).

**AppImage** also needs system OpenSSL 3 (`libssl.so.3`, `libcrypto.so.3`):

```sh
chmod +x Opal-*.AppImage
./Opal-*.AppImage
```

**Debian / Ubuntu:** use `_compat_amd64.deb` on older hosts. Standard packages
need `libmpv2` and `libtorrent-rasterbar2.0` (Ubuntu 24.04+ / Debian 13+).

```sh
sudo apt install ./opal_<version>_amd64.deb
```

**Fedora:**

```sh
sudo dnf install ./opal-*.x86_64.rpm
```

**openSUSE:**

```sh
sudo zypper install ./opal-*.x86_64.rpm
```

**Arch / Omarchy:** [AUR package](https://aur.archlinux.org/packages/opal-media-player-bin).

```sh
yay -S opal-media-player-bin
# or: paru -S opal-media-player-bin
```

Without a helper:

```sh
git clone https://aur.archlinux.org/opal-media-player-bin.git
cd opal-media-player-bin && makepkg -si
```

Release packages also install with `sudo pacman -U ./opal-*-x86_64.pkg.tar.zst`.

</details>

<details>
<summary><b>Windows</b> — x64 alpha</summary>

Install the `.msi` or extract the portable `.zip` from [Releases](../../releases/latest).
Expect bugs and SmartScreen prompts. [Report an issue](../../issues).

</details>

<details>
<summary><b>First launch and updates</b></summary>

Browse **Movies & TV** without a key, or choose **Home** to open a file.
Install search sources in **Settings → General → Install source plugins**.
A **TMDB v4 token** adds richer metadata. AI and voice models are opt-in.
Reopen onboarding in **Settings → About**.

**Updates from v0.9.3:** Opal checks automatically and offers a small corner prompt.
On a writable macOS app installation, choose **Update**, keep using the app while
it downloads, then **Restart** to install and reopen. A failed launch restores the
previous version. Control checks in **Settings → About**. Older versions need one
manual update first.

Windows opens its installer after the download. Linux and package-managed installs
use their package manager or the release page. You can also rerun the installer
with `sh -s -- update`, or set `OPAL_VERSION=vX.Y.Z` to pin a release. Update AUR
packages with `yay -Syu` or `paru -Syu`.

**System-wide Linux install** requires root or `sudo`:

```sh
curl -fsSL https://raw.githubusercontent.com/debpalash/Opal/main/scripts/install.sh | OPAL_SYSTEM=1 sh
```

</details>

<a id="see-it"></a>

## See it in action

**One native app, from finding something to pressing play.** These new macOS
UI previews use openly licensed Blender films, paused frames, and isolated demo data.

![Big Buck Bunny playing in Opal’s native player.](assets/readme/bunny-player.webp)

<sub>Big Buck Bunny © 2008 Blender Foundation / [www.bigbuckbunny.org](https://peach.blender.org/), [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/).</sub>

![Opal’s connection screen for bringing your own media services into the app.](assets/readme/connections.webp)

<sub>Connect your own services. Availability and setup depend on the source. The embedded browser is currently a macOS feature.</sub>

<details>
<summary><b>Watch torrent streaming in action</b></summary>

Open a magnet and watch while it downloads; available peers are required.
This earlier recording shows Sintel and predates the current navigation.

[![Sintel streaming from a torrent in Opal.](assets/readme/torrent.webp)](assets/media/stream-a-torrent.mp4)

[Watch the recording →](assets/media/stream-a-torrent.mp4)

<sub>Sintel © Blender Foundation / [www.sintel.org](https://durian.blender.org/), [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/).</sub>

</details>

<details>
<summary><b>Browse inside Opal on macOS</b></summary>

Tabs, pinned extensions, a native new-tab page, YouTube handoff, and comic
discovery bring the web closer to your player and reading library.

![Opal’s native macOS browser with tabs, extensions, a themed new-tab page, and connection controls.](assets/releases/v0.9.3/browser.png)

<sub>Native UI preview with public demo recents.</sub>

</details>

<a id="why"></a>

## Your entertainment stack, in one app

| If you want… | Use Opal for… |
| --- | --- |
| A Netflix-style home for your own sources | Movie and TV discovery, title details, watchlists, and playback from your files, servers, and installed sources. |
| A Plex or Jellyfin desktop client | Connect to your existing server and browse and play its library inside Opal. |
| A Stremio or Kodi alternative | An extensible media hub with source plugins, torrents, live TV, and local playback. |
| A VLC-style player with more around it | Local files and streams, subtitles, audio tracks, playlists, and session restore alongside discovery and reading. |
| Video, audio, and reading together | YouTube, music, podcasts, radio, audiobooks, manga, comics, books, and novels. |

These comparisons describe how you can use Opal; feature coverage varies by
platform and source. Opal connects to Plex and Jellyfin servers rather than
replacing their server software.

| Feature | What you can do |
| --- | --- |
| **Movies, TV & anime** | Discover titles, open details, and play from enabled sources. |
| **Local media** | Open your files, organize a local library, and resume where you left off. |
| **Torrents & downloads** | Stream magnets while they download, manage transfers and queues, or use an optional memory buffer for temporary torrents. |
| **YouTube** | Search and play videos, hand off from the browser, and use SponsorBlock. |
| **Live TV & IPTV** | Browse and play channels from enabled live TV sources. |
| **Music, podcasts & radio** | Connect a Subsonic/OpenSubsonic music library, follow podcast episodes, and tune into radio. |
| **Manga & comics** | Read with managed Suwayomi and Mihon/Tachiyomi extensions. |
| **Books & novels** | Browse OPDS libraries and installed reading sources; discover visual novels through VNDB. |
| **Audiobooks** | Connect your Audiobookshelf server. |
| **Web browser** | Browse with tabs and extensions, send videos to playback, and discover reading sources on macOS. |
| **Connected libraries** | Bring Plex, Jellyfin, and other supported services into one interface. |
| **Playback tools** | Choose subtitles and audio tracks, translate subtitles, cast, and join watch parties. |
| **Personal library** | Keep history, collections, watchlists, and restored sessions; use incognito when you want it. |
| **Sources & customization** | Install source plugins, follow RSS, choose themes, and browse wallpapers. |
| **Local AI, voice & OCR** | Enable optional on-device tools for recommendations, voice interaction, and text recognition. |
| **Remote & browser controls** | Use the phone companion or the Opal Connect browser extension. |
| **Agent automation** | Search, play, queue, manage a Wanted list, and schedule optional tasks through MCP. |

Sources start disabled; install the ones you want. [Source coverage](docs/browse-sources.md) ·
[Roadmap](ROADMAP.md) · [What’s new](CHANGELOG.md).

**Platform availability:** macOS and Linux desktop builds, Windows x64 alpha,
and an iOS preview. Desktop feature parity on iOS is still in progress.
[Sideload the latest IPA](https://github.com/debpalash/Opal/releases/latest) or
[build for a physical iPhone/iPad](docs/ios.md).

<details>
<summary><b>Source setup and playback tips</b></summary>

Install search sources in **Settings → General → Install source plugins**.
For Jackett, open **Connect → Torrent indexers → Start Jackett**.
Opal downloads the official binary, runs it locally, and opens tracker management
inside its browser. [Managed Jackett setup](docs/jackett.md).

**Search** works from any page; compact windows also offer it under **More**.
Click a result or **Play** to watch; **+** queues a torrent and **Details** opens title info.
Find additional controls in **More → Playback options**.

For temporary torrents, enable **Settings → Network → Stream torrents in memory**.
Choose 128, 256 (default), or 512 MiB per new torrent. Seeking may redownload pieces;
closing releases the buffer. Existing transfers keep their storage mode.
Decoder memory is extra, and the OS may swap RAM to disk.

Source installation errors include recovery steps in redacted **Logs**.

</details>

## Control it from anywhere

**Opal Connect** for Chrome, Edge, and Firefox sends videos to Opal, adds reading
sources, and controls playback from a side panel.

[Install the extension →](extension/README.md) · [Download builds](../../releases/latest)

**From your phone:** enable **Settings → Web UI**, set **Network** to **LAN**,
then scan the QR code. It includes a setup code on first use and opens
`http://<your-pc-ip>:41595`. Home-screen installation requires HTTPS.
[Phone setup guide](docs/web-companion.md).

## Let an AI agent run it

Opal ships `opal-mcp`, an [MCP](https://modelcontextprotocol.io) server that gives
Claude Code, Codex, Gemini CLI or any MCP client more than 100 typed tools: search and
play, queue, downloads, library, collections, discovery, and a **Wanted list** that
finds and downloads releases on its own. Turn on **Settings → Agent Access**, then
copy the one-line setup for your agent, or press **Launch** to open one already
connected.

- Safe by default: tools carry a permission tier, destructive ones are off until you
  opt in, and an agent cannot change your proxy, download folder or plugin approvals.
- Optional **scheduled agent tasks** run a prompt on a timer, with a daily cap and a
  spending limit, and stay off until you enable them.
- Everything is also an [OpenAPI](docs/openapi.json) description of the local API.

[Agent guide](docs/mcp.md) · [How it fits together](docs/agent-native.md)

<details>
<summary><b>Keyboard shortcuts</b></summary>

| Action | Key | Action | Key |
|---|---|---|---|
| Search | <kbd>S</kbd> | Browser | <kbd>B</kbd> |
| Library | <kbd>D</kbd> | History | <kbd>H</kbd> |
| Fullscreen | <kbd>F</kbd> | Playlist | <kbd>P</kbd> |
| Grid | <kbd>G</kbd> | Fit / crop | <kbd>Z</kbd> |
| Open file | <kbd>⌘</kbd><kbd>O</kbd> | Settings | <kbd>⌘</kbd><kbd>,</kbd> |
| Back | <kbd>Esc</kbd> | All shortcuts | <kbd>⇧</kbd><kbd>I</kbd> |

</details>

<a id="building-from-source"></a>
<a id="under-the-hood"></a>

## Built in the open

**Zig 0.17.x · dvui · mpv.** One native binary, shared application state, and a UI
that repaints on change. [Architecture](docs/architecture.md) ·
[Contributing](.github/CONTRIBUTING.md) · [CI](../../actions/workflows/ci.yml).

<details>
<summary><b>Build from source</b></summary>

Use **Zig 0.17.x**; DVUI 0.6.0-dev is pinned alongside the compiler. On macOS:

```sh
brew install mpv sqlite sdl2 libtorrent-rasterbar webp
git clone https://github.com/debpalash/Opal.git
cd Opal
brew install mise
mise install
mise exec -- zig build run
```

`mise.toml` pins Zig 0.17.0. If you already have Zig 0.17.x on `PATH`, run:

```sh
zig build run
```

**WebP:** the build links a static `libwebp.a`, found automatically under
`~/.local/opal-webp` or Homebrew (`$HOMEBREW_PREFIX`, `/opt/homebrew`, `/usr/local`).
Point elsewhere with `-Dwebp-prefix=<dir>` or `OPAL_WEBP_PREFIX=<dir>`.

**Linux / Wayland:** run `./scripts/install-deps.sh`, then `make run` for system SDL2.
Minimums: libmpv **0.34** (0.38+ recommended), libtorrent-rasterbar **2.0**, and
SDL **2.0.22**. Ubuntu 20.04 needs newer mpv and libtorrent than its stock packages.

**macOS 14:** if Homebrew cannot provide FFmpeg/mpv, install
`sqlite sdl2 libtorrent-rasterbar libass libplacebo meson ninja pkgconf`, then run
`./scripts/install-macos-ffmpeg.sh` and `./scripts/install-macos-mpv.sh`.
These target macOS 13+. `HOMEBREW_PREFIX` defaults to `/opt/homebrew`.

**Optional:** ONNX Runtime with `zig build -Docr=true` for OCR;
FFmpeg and whisper-cpp for voice.

</details>

<details>
<summary><b>Development and tests</b></summary>

| Command | Purpose |
|---|---|
| `./dev.sh` | Hot reload; `-r` for ReleaseFast |
| `just hot` | Native incremental rebuilds |
| `just release` / `just app` | Release binary / macOS bundle |
| `zig build test` | Zig unit tests |
| `just test-all` | Full feature suite |

Both test suites must have **0 failures** before committing. Optional-component
skips are allowed. Include the tally in your PR. [Contribution guide](.github/CONTRIBUTING.md).

</details>

<details>
<summary><b>Source map and local data</b></summary>

```text
src/
├── main.zig     # app entry and frame loop
├── core/        # state, config, storage, I/O
├── player/      # mpv, playlists, subtitles
├── services/    # search, AI, torrents, remote API
└── ui/          # native dvui interface
web/             # companion web UI
extension/       # Opal Connect
```

Config, tokens (`0600`), history, and AI memory live in `~/.config/opal/`.
Caches use `~/.cache/opal/`; downloads default to `~/Downloads/opal`.

Plugins live in `~/.config/opal/plugins/<name>/`, with `manifest.json` and
JSON-emitting `search`/`resolve` executables. Lua is sandboxed; native binaries
are not. Install trusted plugins.

</details>

<a id="support"></a>

## Keep Opal going

If Opal is useful to you, [star the repo](../../stargazers) to help others find it.

[Report a bug](.github/SUPPORT.md) · [Discussions](../../discussions) ·
[Ko-fi](https://ko-fi.com/debpalash) · [PayPal](https://paypal.me/palashCoder).

**GPL-3.0.** [License](LICENSE) · [Dependency notices](docs/NOTICE.md).
Opal connects to sources you configure; it does not host or distribute media.
Only access content you have the right to use. BitTorrent shares your IP with peers.
[Content policy](docs/CONTENT_POLICY.md) · [Privacy](docs/PRIVACY.md) ·
[Rights-holder contact](docs/DMCA.md). Provided as is, without warranty.
