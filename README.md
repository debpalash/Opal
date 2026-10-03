<div align="center">
  <img src="assets/readme/hero.webp" alt="Opal — Play everything. From one app. The Movies & TV browser floats over an opalescent glass backdrop." width="100%" />

# Opal

### Your media, in one place.

A free, open-source **media player and browser** for movies, live TV, YouTube,
torrents, manga, and your **Jellyfin & Plex** libraries. Optional **AI runs locally**.

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

Search your enabled sources, play or read a result, and resume where you left off.
Connect a server to browse your Jellyfin or Plex library.

| Local history | No telemetry | Optional local AI | Free software |
|:---:|:---:|:---:|:---:|
| A SQLite file you own | No usage tracking | Models run on your machine | No subscription |

<a id="see-it"></a>

## See Opal in action

### Browse

Explore trending titles, genres, and sources.

<a href="assets/media/browse.mp4"><img src="assets/readme/browse.gif" width="100%" alt="Animated Opal demo: scroll the movie poster wall, then switch to the YouTube source, inside a framed window on an opalescent backdrop." /></a>

[Watch the browse recording →](assets/media/browse.mp4)

### Stream torrents

Play while a torrent downloads. Available peers are required.

<a href="assets/media/stream-a-torrent.mp4"><img src="assets/readme/torrent.gif" width="100%" alt="Animated Opal demo: start a Sintel torrent and watch playback while it downloads, framed against an opalescent backdrop." /></a>

[Watch the streaming recording →](assets/media/stream-a-torrent.mp4) ·
<sub>Sintel, © Blender Foundation, CC BY 3.0.</sub>

### Ask your local AI

Get playable recommendations from an optional local model. No API key needed.

<a href="assets/media/ask-the-ai.mp4"><img src="assets/readme/ai.gif" width="100%" alt="Animated Opal demo: a suggestion chip prompts the local AI, which responds with recommendations and a poster rail." /></a>

[Watch the AI recording →](assets/media/ask-the-ai.mp4)

<sub>GIFs show earlier recordings; stills show the current toolbar.</sub>

<table>
  <tr>
    <td width="50%" valign="top">
      <a href="assets/readme/search.webp"><img src="assets/readme/search.webp" width="100%" alt="Opal universal search with Sintel results and play or queue actions, presented in an opalescent screenshot card." /></a><br/>
      <b>One query. Every source.</b><br/>
      <sub>Find files, streams, reading results, and title details. Click to enlarge.</sub>
    </td>
    <td width="50%" valign="top">
      <a href="assets/readme/player.webp"><img src="assets/readme/player.webp" width="100%" alt="Big Buck Bunny playing in Opal, with quality, audio, subtitle, and translation controls, presented in an opalescent screenshot card." /></a><br/>
      <b>Press play. Settle in.</b><br/>
      <sub>Quality, audio, subtitles, and translation. Big Buck Bunny, © Blender Foundation, CC BY 3.0.</sub>
    </td>
  </tr>
</table>

<a id="get-it"></a>

## Get Opal

Install with one command. It detects your platform and verifies checksums;
Linux installs to `~/.local` without `sudo`.

```sh
curl -fsSL https://raw.githubusercontent.com/debpalash/Opal/main/scripts/install.sh | sh
```

Prefer a package? Download from [Releases](../../releases) or use a package manager:

| Platform | Install |
|---|---|
| **macOS · Apple silicon** | Open the `.dmg` and drag Opal to Applications |
| **Homebrew** | `brew install debpalash/tap/opal` |
| **Arch / Omarchy / AUR** | `yay -S opal-media-player-bin` or `paru -S opal-media-player-bin` |
| **Debian / Ubuntu** | `sudo apt install ./opal_<version>_amd64.deb` |
| **Fedora** | `sudo dnf install ./opal-*.x86_64.rpm` |
| **openSUSE** | `sudo zypper install ./opal-*.x86_64.rpm` |
| **Linux · AppImage** | `chmod +x Opal-*.AppImage`, then run it |
| **Windows · x64 alpha** | Install the `.msi` or extract the portable `.zip` |

**Linux:** standard packages need glibc 2.38+. Ubuntu 20.04/22.04, Debian 12,
and Mint 21 should use `_compat_amd64.deb` (glibc 2.31+). The installer selects
it automatically. [Compatibility details](packaging/linux-compat/README.md).

**Arch:** the v0.8.8 AUR binary requires libtorrent 2.0; current Arch ships 2.1.
Use the AppImage until the binary package is updated.

**Windows is alpha:** expect bugs and SmartScreen prompts.
[Report an issue](https://github.com/debpalash/Opal/issues).

### First launch

Browse **Movies & TV** without a key, or choose **Home** to open a file.
Install search sources in **Settings → General → Install source plugins**.
A **TMDB v4 token** adds richer metadata. AI and voice models are opt-in.

<details>
<summary><b>Updates and platform notes</b></summary>

**Update:** rerun the installer with `sh -s -- update`. Set `OPAL_VERSION=vX.Y.Z`
to pin a release.

**System-wide Linux install** (requires root or `sudo`):

```sh
curl -fsSL https://raw.githubusercontent.com/debpalash/Opal/main/scripts/install.sh | OPAL_SYSTEM=1 sh
```

**Arch:** [binary package](https://aur.archlinux.org/packages/opal-media-player-bin)
or [source package](https://aur.archlinux.org/packages/opal-media-player); install one.
Update AUR packages with `yay -Syu` or `paru -Syu`.
Without a helper:

```sh
git clone https://aur.archlinux.org/opal-media-player-bin.git
cd opal-media-player-bin && makepkg -si
```

The release `.pkg.tar.zst` also installs with `sudo pacman -U ./opal-*-x86_64.pkg.tar.zst`.

**macOS:** Homebrew includes the app's media libraries. If an unnotarized DMG
shows “damaged,” use the installer or run `sudo xattr -cr /Applications/Opal.app`.
Intel Macs require a source build with `HOMEBREW_PREFIX=/usr/local`.

**Linux:** standard `.deb` packages need `libmpv2` and `libtorrent-rasterbar2.0`
(Ubuntu 24.04+ / Debian 13+). Compatibility builds use software decoding and
X11/XWayland. AppImage needs glibc 2.38+ and system OpenSSL 3
(`libssl.so.3`, `libcrypto.so.3`).

</details>

<details>
<summary><b>Playback and navigation tips</b></summary>

- **Search** works from any page; compact windows also offer it under **More**.
- Hover toolbar icons for labels; scroll the toolbar in narrow windows.
- Click a result or **Play** to watch; **+** queues a torrent. **Details** opens title info.
- **×** on Now Playing stops playback. More controls: **More → Playback options**.
- Source installation errors include recovery steps in redacted **Logs**.

**Temporary torrents:** enable **Settings → Network → Stream torrents in memory**.
Choose 128, 256 (default), or 512 MiB per new torrent. Seeking may redownload
pieces; closing releases the buffer. Existing transfers keep their storage mode.
Decoder memory is extra, and the OS may swap RAM to disk.

Reopen onboarding in **Settings → About**.

</details>

<a id="building-from-source"></a>
<details>
<summary><b>Build from source</b></summary>

Use **Zig 0.16.x**; 0.17 requires a migration. On macOS:

```sh
brew install mpv sqlite sdl2 libtorrent-rasterbar
# Install Zig 0.16.x separately if your package manager offers a newer version.
git clone https://github.com/debpalash/Opal.git
cd Opal
zig build run
```

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
skips are allowed. Include the tally in your PR.
[Contribution guide](.github/CONTRIBUTING.md).

</details>

<details>
<summary><b>Files and data</b></summary>

| Path | Contents |
|---|---|
| `~/.config/opal/` | Config, tokens (`0600`), history and AI memory (`opal.db`) |
| `~/.cache/opal/` | Caches |
| `~/Downloads/opal` | Default downloads |
| `~/.config/opal/plugins/<name>/` | Source plugins |

Plugins use `manifest.json` and JSON-emitting `search`/`resolve` executables.
Lua is sandboxed; native binaries are not. Install trusted plugins.

</details>

<a id="why"></a>

## Features

| Media | What you can do |
|---|---|
| **Movies, TV, anime & YouTube** | Browse titles and search enabled sources |
| **Live TV / IPTV** | Search ~40,000 channels |
| **Jellyfin & Plex** | Connect and browse your servers |
| **Manga** | Use Mihon / Tachiyomi extensions through managed Suwayomi |
| **Torrents** | Stream magnets while they download |
| **Local AI** | Ask for playable recommendations |

Also: subtitles, translation, SponsorBlock, casting, watch parties, session restore,
RSS, themes, incognito, and optional OCR. [Roadmap](ROADMAP.md) ·
[Source coverage](docs/browse-sources.md).

## Keyboard and phone remote

| | | | |
|---|---|---|---|
| <kbd>S</kbd> search | <kbd>B</kbd> browser | <kbd>D</kbd> library | <kbd>H</kbd> history |
| <kbd>F</kbd> fullscreen | <kbd>P</kbd> playlist | <kbd>G</kbd> grid layout | <kbd>Z</kbd> fit/crop |
| <kbd>⌘</kbd><kbd>O</kbd> open file | <kbd>⌘</kbd><kbd>,</kbd> settings | <kbd>Esc</kbd> back | <kbd>⇧</kbd><kbd>I</kbd> shortcuts |

**From your phone:** open **Settings → Web UI**, enable it, set **Network** to
**LAN**, then scan the QR code. It includes a setup code on first use and opens
`http://<your-pc-ip>:41595`. Home-screen installation requires HTTPS.
[Phone setup guide](docs/web-companion.md).

## Browser extension

**Opal Connect** for Chrome, Edge, and Firefox sends videos to Opal, adds reading
sources, and controls playback from a side panel.

<div align="center">
  <a href="assets/readme/connect.webp"><img src="assets/readme/connect.webp" alt="Opal Connect browser side panel with page actions, playback controls, and cross-source search, framed over an opalescent backdrop." width="100%" /></a>
</div>

Download the extension from [Releases](../../releases/latest), unzip and load it,
then pair with your Opal API token. [Install and build instructions](extension/README.md).

<a id="under-the-hood"></a>

## Under the hood

```
src/
├── main.zig     # app entry and frame loop
├── core/        # state, config, storage, I/O
├── player/      # mpv, playlists, subtitles
├── services/    # search, AI, torrents, remote API
└── ui/          # native dvui interface
web/             # companion web UI
extension/       # Opal Connect
```

Built with **Zig, dvui, and mpv**. One native binary, shared application state,
and a UI that repaints on change. [Architecture](docs/architecture.md).

Sources start disabled. Install and manage them from the plugin registry.
[Content policy](docs/CONTENT_POLICY.md).

<a id="support"></a>

## Support

[Ko-fi](https://ko-fi.com/debpalash) · [PayPal](https://paypal.me/palashCoder) ·
[Star the repo](../../stargazers) · [Report a bug](.github/SUPPORT.md).

## Contributing

Read the [contribution guide](.github/CONTRIBUTING.md), run both test suites,
and include results in your PR. [Discussions](../../discussions) ·
[Help](.github/SUPPORT.md).

## License

**GPL-3.0**. [License](LICENSE) · [Dependency notices](docs/NOTICE.md).

## Content and privacy

Opal connects to sources you configure; it does not host or distribute media.
Only access content you have the right to use. BitTorrent shares your IP with
peers. [Content policy](docs/CONTENT_POLICY.md) · [Privacy](docs/PRIVACY.md) ·
[Rights-holder contact](docs/DMCA.md). Provided as is, without warranty.

<div align="center">
  <img src="assets/logo.svg" width="40" alt="" /><br/>
  <sub>Built with Zig, mpv, and dvui. Yours since first launch.</sub>

</div>
