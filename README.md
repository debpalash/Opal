<div align="center">

<img src="assets/logo.svg" width="64" alt="Opal" />

# Opal

**The open-source Netflix, Plex & Jellyfin alternative — in one native binary.**

Web browser · Torrent streamer · Movie & TV hub · Anime player · YouTube client · Live TV<br>
Manga & comic reader · Jellyfin & Plex client · Casting · Watch parties · Subtitles · Translation<br>
Downloads · RSS · Plugins · Local AI · Voice control · Agent automation

macOS · Linux · Windows · iOS · Android (planned)

**[Download](https://github.com/debpalash/Opal/releases/latest)** · [Website](https://opal.palash.dev) · [What’s new](CHANGELOG.md)

</div>

![Opal’s native player.](assets/readme/sintel-player.webp)

<sub>Sintel © Blender Foundation, [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/). [Credits](assets/readme/CREDITS.md).</sub>

<a id="get-it"></a>

```sh
curl -fsSL https://raw.githubusercontent.com/debpalash/Opal/main/scripts/install.sh | sh
```

Free, open source, no telemetry, no subscription. From your phone: enable **Settings → Web UI**, set **Network** to **LAN**, and scan the QR code.

<a id="building-from-source"></a>

**Build:** Zig 0.17 · dvui · mpv — `zig build run`. Linux needs glibc 2.38+ (compat `.deb` for older), libmpv **0.34**+, SDL 2.0.22+. [Architecture](docs/architecture.md) · [Contributing](.github/CONTRIBUTING.md)

<sub>**GPL-3.0.** Opal plays sources you configure; it hosts no media and provides no Netflix titles. Not affiliated with Netflix, Plex, or Jellyfin. Only access content you have the right to use. [Content policy](docs/CONTENT_POLICY.md) · [Privacy](docs/PRIVACY.md) · [DMCA](docs/DMCA.md)</sub>
