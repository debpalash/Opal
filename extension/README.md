# Opal Connector — browser extension

A cross-browser (Chrome / Edge / Firefox, **Manifest V3**) companion for the
[Opal](../README.md) desktop app. It adds universal, site-wide actions that hand
any website's media, articles, downloads and scraped page data to your
locally-running Opal:

- **▶ Play in Opal** — send a link, `magnet:`, or the current tab to Opal to play/route.
- **⬇ Download with Opal** — hand a URL to Opal's downloader.
- **📖 Read in Opal** — extract the page's readable article text and send it over.
- **Scrape page → Opal** — detect media / a chapter list / an article and ingest it.
- **Search in Opal** — right-click selected text to run a universal search.

Built with [extension.js](https://extension.js.org) (v3) + TypeScript.

## Requirements

- **Opal must be running locally** with the JSON API enabled
  (Opal → *Settings → Web Remote*). The extension talks to
  `http://127.0.0.1:41595` by default.
- Node 18+ to build (`npm install` pulls `extension` + `typescript`).

## Get your API token

Opal generates a bearer token on first launch and stores it (mode `0600`) at:

- macOS / Linux: `~/.config/opal/api.token`
- Windows: `%APPDATA%\opal\api.token`

Copy its contents and paste it into the extension's **Settings** (Options) page,
then hit **Test connection**. The token is stored via `chrome.storage.sync`.

> The extension never fetches localhost from a web page. Every Opal request is
> made by the background service worker, which holds `host_permissions` for
> `127.0.0.1`/`localhost` — so it isn't subject to page CORS, and Opal needs no
> CORS change.

## Develop (load unpacked)

```sh
cd extension
npm install
npm run dev        # extension.js dev server + auto-reload (Chrome)
# or build a static bundle:
npm run build      # → dist/  (load unpacked, or zip for distribution)
```

Then load it:

- **Chrome / Edge**: `chrome://extensions` → enable *Developer mode* → *Load
  unpacked* → pick `extension/dist/chrome` (or the project root in dev).
- **Firefox**: `about:debugging` → *This Firefox* → *Load Temporary Add-on* →
  pick `manifest.json` inside the built Firefox bundle.

`extension build` emits per-browser folders under `dist/` and can also produce a
distributable zip.

## Supported actions & endpoints

| Action                     | Endpoint (Opal, bearer-authed)         |
| -------------------------- | -------------------------------------- |
| Play / send link / tab     | `POST /api/open?url=<enc>`             |
| Download                   | `POST /api/download/url?url=<enc>`     |
| Search selection           | `GET  /api/search?q=<enc>`             |
| Read / Scrape → Opal       | `POST /api/ingest?type=&url=&title=`   |
| Connection indicator       | `GET  /api/status`                     |

`type` for `/api/ingest` is one of `article` \| `media` \| `chapters`.

## Files

```
extension/
├── manifest.json          MV3 manifest (permissions, host_permissions, SW, popup, options)
├── src/
│   ├── background.ts       service worker — the only place that talks to Opal
│   ├── content.ts          media detection + shadow-DOM "▶ Opal" button + scraper
│   ├── shared.ts           settings + types shared across contexts
│   ├── popup/              connection status + quick actions
│   └── options/            host / port / token + Test connection
└── images/                 extension icons
```

## Caveats

- The floating **▶ Opal** button appears only when the content script detects
  playable media; some heavily-sandboxed pages block content scripts entirely.
- Token pairing is manual (copy/paste from `api.token`) — Opal's 6-digit
  pairing-code flow is aimed at phones on the LAN, not this same-machine
  extension.
