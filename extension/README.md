# Opal Connector — browser extension

A cross-browser (Chrome / Edge / Firefox, **Manifest V3**) companion for the
[Opal](../README.md) desktop app. It hands any website's media, articles,
downloads and — its headline trick — whole manga/novel **sites** to your
locally-running Opal, so link-sending feels native to the app instead of a
generic "open URL".

## What it does

- **Add this site as an Opal source** — on a recognised manga/novel site the
  extension detects the framework it's built on (Madara, MangaThemesia, HeanCMS,
  LightNovel-WP, ReadWN) and installs it as an Opal source in one click. The site
  becomes searchable in Opal's Comics / Novels immediately.
- **Smart typed send** — the current page/link is classified (video / manga /
  novel / anime / magnet / direct-media / article) and sent with a type hint, so
  Opal routes it the right way. Right-click menus adapt ("Read chapter in Opal",
  "Play episode in Opal", …).
- **Rich metadata** — title, `og:image` cover, and the chapter/episode label are
  scraped and sent so Opal shows a proper now-playing card, not a bare URL.
- **Side-panel remote** — the toolbar icon opens a persistent side panel
  (Chrome/Edge) or sidebar (Firefox) with now-playing, play/pause, seek, volume,
  next audio/sub, a typed "send current tab", the add-source card, and a recent
  log.
- **Queue / Download / Read / Search** — queue a link, hand a URL to Opal's
  downloader, extract readable article text, or search selected text.

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

Copy its contents and paste it into the extension's **Settings** page, then hit
**Test connection**. The token is stored via `chrome.storage.sync`.

> The extension never fetches localhost from a web page. Every Opal request is
> made by the background service worker, which holds `host_permissions` for
> `127.0.0.1`/`localhost` — so it isn't subject to page CORS, and Opal needs no
> CORS change.

## Develop (load unpacked)

```sh
cd extension
npm install
npm run dev        # extension.js dev server + auto-reload (Chrome)
npm run build      # → dist/  (load unpacked, or zip for distribution)
npx tsc --noEmit   # typecheck only
```

Then load it:

- **Chrome / Edge**: `chrome://extensions` → *Developer mode* → *Load unpacked* →
  pick `extension/dist/chrome`. Click the toolbar icon to open the side panel.
- **Firefox**: `about:debugging` → *This Firefox* → *Load Temporary Add-on* →
  pick `manifest.json` in the Firefox bundle. The panel opens as a sidebar.

## Supported actions & endpoints

| Action                     | Endpoint (Opal, bearer-authed)                          |
| -------------------------- | ------------------------------------------------------- |
| Play / send tab (+ meta)   | `POST /api/open?url=&title=&art=&subtitle=`             |
| Typed send / queue         | `POST /api/ingest?type=&url=&title=&art=&subtitle=`     |
| Add site as source         | `POST /api/source/add?framework=&base=`                 |
| Download                   | `POST /api/download/url?url=<enc>`                      |
| Search selection           | `GET  /api/search?q=<enc>`                              |
| Now-playing / connection   | `GET  /api/status`                                      |
| Play/pause · seek · volume | `POST /api/playpause` · `/api/seek_pct?v=` · `/api/volume?v=` |
| Next audio / subtitle      | `POST /api/next_audio` · `/api/next_sub`               |

`type` for `/api/ingest` is one of
`video｜manga｜novel｜anime｜magnet｜media｜article｜chapters｜queue`.
`framework` for `/api/source/add` is one of
`madara｜mangathemesia｜heancms｜madara_novel｜lightnovelwp｜readwn`.

## Files

```
extension/
├── manifest.json          MV3 manifest (side_panel + sidebar_action, no popup)
├── src/
│   ├── background.ts       service worker — the only place that talks to Opal
│   ├── content.ts          framework detection + page classify + shadow-DOM button
│   ├── shared.ts           settings + types shared across contexts
│   ├── sidepanel/          persistent panel: remote + send + add-source + recent
│   └── options/            full-page settings (Connection / Behavior / About)
└── images/                 extension icons
```

## Caveats

- The floating **◆ Opal** button appears only when the content script finds
  something worth sending or a source to add; heavily-sandboxed pages block
  content scripts entirely.
- Madara serves both manga and novels; the extension guesses manga vs novel from
  the reading surface (image chapters vs prose). If it picks wrong, use the side
  panel's type to override.
- Token pairing is manual (copy/paste from `api.token`).
