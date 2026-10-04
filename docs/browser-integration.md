# Direct browser integration: design

Status: proposal. Written against `v2/agent-os` at dd5f393. Nothing here is implemented. Facts are marked **verified** (read in this tree, measured on this machine, or confirmed against a cited source) or **unverified** (recalled, or depends on a platform I could not test here). Section 11 lists every unverified item.

## 1. Summary

Opal's in-app Web page is a remote desktop: a Python Playwright bridge screenshots a headless browser as JPEG and Opal paints the pictures and synthesizes input back. Every realistic engine-embedding option either does not work on Linux/Wayland (native web views), is a large per-OS project that still ends in a pixel buffer (CEF off-screen rendering), or is not ready (Servo, Ladybird). None of them gives Opal the thing it is missing: the user's real browser, with their logins, cookies, extensions and DRM.

Recommendation:

1. **Stop trying to draw web pages inside Opal.** Make the user's own browser a peer of Opal. Opal Connect (the existing extension) gains a paired, scoped, revocable channel to Opal and becomes the integration point: it finds the real stream behind a page and Opal plays it in mpv, sends pages with metadata, and (later) acts as a fetch backend that carries the user's real cookies and bot clearance.
2. **Browse > Web becomes a Browser Hub**, not a pixel pane: connected browsers, the pages the user has shared, detected media per page, and one-click actions. Sign-in flows that need a page open in the user's real browser window instead of a streamed one.
3. **Keep Camoufox/CloakBrowser only as an optional "hardened fetch" engine** for sources that fight real browsers, and stop making it the default path. Later, replace the Python layer with a small Zig CDP client driving an installed Chromium-family browser with an Opal-owned profile.
4. **Defer CEF off-screen rendering** until the product owner confirms that an in-app rendered page is a hard requirement. It is the only engine option that stays inside Opal and works on all three OSes, and section 4.2 says what it costs.

First milestone (about one week, verifiable on this Linux machine with the installed Chromium 152, no new browser permissions): **page-media sniffing in the extension plus a `/api/browser/media` route**, so "Send to Opal" on a page with an embedded HLS/DASH/MP4 stream plays that stream in mpv with the right Referer and User-Agent, instead of handing mpv a page URL it cannot resolve.

## 2. What exists today

### 2.1 The in-app browser (verified, read from source)

| Piece | Where | Notes |
| --- | --- | --- |
| Bridge process | `scripts/camoufox_bridge.py` (872 lines) | One persistent Python daemon. Engines: `camoufox` (Firefox-based anti-detect) or `cloakbrowser` (Chromium-based). Both through Playwright's sync API. |
| Transport | stdin: JSON lines. stdout: tag byte `J` (JSON line), `F` (4-byte length + JPEG), `H` (4-byte length + scraped HTML, cap 2 MB) | Reader thread `bridgeReaderThread` in `src/services/browser.zig:509`. |
| Frame pump | `Pump` in the bridge | Playwright `page.screenshot(type="jpeg")`, quality 70 active / 82 settled. 12 fps for 1.5 s after input, 2 fps until 10 s, then a 2 s heartbeat, stops after 120 s idle. Identical frames deduped by hash. |
| Frame display | `browser.zig` `updateFrameTexture` (line 1404) | JPEG decoded on the reader thread (`image_decode.browserFrame`), copied to a heap RGBA buffer, uploaded with `dvui.textureCreate` / `Texture.update`. |
| Input | `sendClickButton`, `sendMouseMove`, `sendScroll`, `sendKeypress`, `sendType`, `mapKeyToPlaywright` | dvui events are mapped to Playwright calls at pixel coordinates. Scrolls coalesced, hover moves rate-gated. |
| Viewport | `maybeSyncViewport` | 300 ms debounce, clamped 320x240 to 2560x1600. |
| Pages | one interactive page, one dedicated scrape page in a separate context | Popups (`target=_blank`) are folded back into the single page. There are no tabs. |
| Downloads | `download` event | Cancelled in the browser, URL handed to Opal's downloader (`enqueueBrowserDownload`). |
| Installer | `installWorker` (line 216), `getVenvPython`, `getBundledUv` | Creates `<config>/venv`, pip-installs the engine, runs `camoufox fetch` (about 200 MB). CloakBrowser downloads about 200 MB on first launch. Windows bundles `uv.exe`; Linux/macOS need a system Python. |
| Chrome around it | `renderContent` (line 1489), `browser_pure.zig` (720 lines) | URL bar, bookmarks, history, per-host zoom, find, reader overlay, omnibox routing, `routeContent` (mpv / comic viewer / web / torrent). Pure logic is unit tested. |

### 2.2 Where the bridge is used

| Use | Path | Notes |
| --- | --- | --- |
| Anti-bot fetch fallback | `scrape_fetch.zig` calls `browser.fetchHtmlWithCancellation` when `scrape_fetch_pure.needsBrowser` says a plain curl fetch hit Cloudflare / DDoS-Guard / captcha | Callers: `anime.zig`, `anime_extractors.zig`, `novels.zig`, `comics.zig`, `remote.zig` `/api/scrape`. GET and form POST (EZTV needs POST for magnet links). Serialized on one scrape page, 45 s ceiling, 2 MB cap. |
| Search pre-warm | `search.zig:1089` | Starts the bridge during a search because boot takes about 20 s and a warm scrape takes about 2 s (comment in source). |
| Web page | `browser.renderContent`, `routeContent` falls through to `.web` | The remote-desktop pane described above. |
| Agent access | `/api/scrape?url=` | Bearer-authed, 2 MB, returned as `text/plain`. Not exposed as an MCP tool. I did not find a private-address (SSRF) guard in `handleScrapeBody`; see section 9. |

The bridge has no media sniffing, no cookie export, no tab model and no way for an agent to read the page the user is on. Playback of page content never goes through it: `loadContent` / `playDirect` hand URLs to libmpv.

### 2.3 The extension and the HTTP API (verified)

`extension/` is Opal Connect 0.4.0: WXT/extension.js + TypeScript, MV3 (Chrome, Edge) with `sidebar_action` for Firefox. About 3,500 lines.

- `background.ts` is the only code that talks to Opal. It `fetch`es `http://127.0.0.1:41595` with `Authorization: Bearer <token>`; `host_permissions` cover loopback only; broader hosts are `optional_host_permissions`.
- `content.ts` runs on `<all_urls>` at `document_idle`, top frame only. It classifies the page (video / manga / novel / anime / magnet / media / article), detects manga/novel frameworks, and finds media only from DOM: `og:video*`, `video[src]`, `video > source[src]`, and a `MEDIA_EXT` regex. There is no network observation (no `webRequest`, no `performance` entries) and no iframe coverage, so a player inside a cross-origin iframe, or a stream fetched by script (the common case), is invisible.
- Token: `chrome.storage.local`, never sync. Setup is either account sign-in (`/api/auth/login`, a session token) or pasting the machine token from `<config>/opal/api.token`.
- Routes it uses: `POST /api/open` (`url`, `title`, `art`, `subtitle` as query parameters), `/api/ingest` (adds `type`), `/api/load`, `/api/download/url`, `/api/source/add` (framework whitelist), search, transport, queue, torrents, cast, party, `/health`, `/api/auth/*`.
- `/api/open` and `/api/ingest` call `stashRemoteOpen` (`remote.zig:1081`), a bounded FIFO (8 entries, `state.REMOTE_OPEN_QUEUE_CAP`) drained on the UI thread by `forwarded_open.zig`. The slot has url/kind/title/art/subtitle only: **no headers**, although `player.playDirect` already accepts `user_agent` and `headers` (`loadContentDirectMetaHeaders`).
- Server limits that matter here: the whole request (line, headers and body) must fit a 4096-byte buffer (`remote_http.readRequest`), `/api/open` decodes the URL into 2048 bytes, and responses carry `Access-Control-Allow-Origin: *`. `remote.zig:780` documents that the DNS-rebinding Host gate was removed because LAN clients send arbitrary Host headers. Bearer is required for everything except static assets, `/health` and `/api/auth/*`.
- Agent side: `opal-mcp` (`docs/mcp.md`) generated from `ops_pure.zig`; tiers `read < playback < write < spend < destructive`; `docs/agent-native.md` lists phase 5 "Extension loop" as not started. The operator (`src/services/operator*.zig`) hands bounded context to a headless agent with no tools and applies schema-validated answers behind human approval.

### 2.4 What the current approach costs and what it is good at

Measured where noted; everything else is from source.

| Dimension | Current behaviour |
| --- | --- |
| Latency | Playwright screenshot per frame. Measured on this machine, headless Chromium 152 via CDP, trivial page: `Page.captureScreenshot` jpeg q70 averages 67 ms, which caps a screenshot-polling pump near 12 fps (what the bridge targets). Add pipe copy, JPEG decode, RGBA copy, texture upload. Input travels the same way back; hover is rate-gated. Cold start: up to 15 s wait in `startBridgeThread`, about 20 s per the search.zig comment. |
| CPU / memory | A full browser plus a Python process, plus a JPEG decode and an RGBA allocation per frame in Opal (`frame_alloc.alloc` per frame). The pump stops after 120 s idle, so cost is paid only while interacting. |
| Fidelity | The page is a picture. No text selection, no native scrolling feel (wheel is coalesced into discrete scrolls), no IME, no native context menus, no accessibility, fixed viewport clamp, resize debounced 300 ms. No tabs. Audio and video inside the page are not routed through Opal (video is shown as sampled screenshots). Page audio output: unverified. |
| DRM | None expected. Camoufox/CloakBrowser are not Widevine builds (unverified for CloakBrowser; Camoufox is a patched Firefox, which ships no CDM without Mozilla's download). Opal's mpv cannot decrypt DRM either. |
| Identity | A fresh, Opal-owned profile. No user logins, no password manager, no extensions (only the optional CaptchaSonic add-on), so every site needing a login means typing credentials into a streamed page. |
| Install weight | Python venv with pip packages, plus about 200 MB browser download (Camoufox) or about 200 MB on first launch (CloakBrowser). Linux/macOS need a system Python; Windows bundles uv. The installer streams progress in Settings. |
| Per-OS | Python availability and venv layout differ per OS (`getVenvPython`, `getBundledUv`); issue #21 in the source comments was a Windows path bug; macOS app bundles have a CWD that reaches neither repo nor config (`getBridgePath` has three lookup tiers because of this). |
| Maintenance | Camoufox's original maintainer stepped down and 2026 releases are described as experimental with breaking changes ([camoufox.com via scour.ing](https://scour.ing/@abnv/p/https://camoufox.com), [release v152.0.4-beta.27](https://newreleases.io/project/github/daijro/camoufox/release/v152.0.4-beta.27)). Opal depends on an anti-detect patch set it does not control. |
| Good at | Passing Cloudflare/DDoS-Guard interstitials for scrapers (the stated reason it exists), POSTing from inside a cookie-bearing context (EZTV), isolation from the user's profile (nothing of the user's leaks to it, and nothing of theirs is at risk). These are real strengths and the plan keeps them as an option. |

## 3. Constraints from Opal's rendering stack (verified)

- dvui's SDL backend (`dvui .../src/backends/sdl.zig`) creates the window with `SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI` (SDL2 path), no `SDL_WINDOW_OPENGL`, then `SDL_CreateRenderer(..., SDL_RENDERER_TARGETTEXTURE)`. Everything is `SDL_Texture` through the renderer. Opal does not own a GL context it could share with another library, so GPU texture import (dmabuf/EGLImage, IOSurface, D3D11 shared handle) has no ready path. The only texture entry points are CPU buffers (`dvui.textureCreate`, `Texture.update`).
- mpv is rendered with `vo=libmpv` and `MPV_RENDER_API_TYPE_SW` (`player.zig:956,1161`; `av_pure.zig:37`): mpv rasterizes into a CPU buffer that is blitted. Opal already moves a CPU frame to a texture every video frame, so a CPU `OnPaint` buffer is the same cost class as playback, not a new one.
- Linux uses the system SDL2. On this machine that is `sdl2-compat 2.32.72` (pacman, verified), i.e. SDL3 underneath, and the session is Wayland (`WAYLAND_DISPLAY=wayland-1`, `DISPLAY=:0` for XWayland). macOS bundles SDL2 through dvui. Windows uses dvui's bundled SDL2.
- The build (`build.zig`) has a headless variant with no SDL. Anything new must live behind the same split: pure logic in `*_pure.zig` with tests, UI in `src/ui/`, no new link-time dependency on the default build unless the milestone says so.

## 4. Options for a real, non-VNC experience

### 4.1 (a) Native web view as a child window or overlay

| Platform | Mechanism | Composites into SDL window? | Verdict |
| --- | --- | --- | --- |
| macOS | `WKWebView` as a subview of the NSWindow content view, handle from `SDL_GetWindowWMInfo` | Yes, as an overlay above the SDL view. dvui cannot draw over it: popups, toasts and menus that overlap the pane are hidden beneath it. | Workable, per-OS code, Objective-C interop from Zig. Cookies/DRM: WKWebView has its own store; third-party-app FairPlay is unverified. |
| Windows | WebView2 controller on a child `HWND` of the SDL window (`SDL_GetWindowWMInfo`) | Yes as a child window; composition-controller mode renders to a DirectComposition visual, which an `SDL_Renderer` swapchain cannot consume. Same overlay limits. Requires the WebView2 runtime (preinstalled on current Windows 11, Evergreen installer otherwise). | Workable, per-OS code, COM from Zig. |
| Linux X11 | WebKitGTK (`webkit2gtk-4.1` is installed here, GTK3, headers verified) in a GTK window reparented into the SDL X11 window | Only through XEmbed/reparenting, and it needs a GTK main loop beside the SDL loop. | Fragile. |
| Linux Wayland | Same libraries | **No.** A client cannot embed another toplevel into its surface. A `wl_subsurface` must come from the same client and toolkit; GTK does not accept a foreign `wl_surface` parent and SDL offers no API to create a subsurface for a third-party renderer. The only workaround is forcing XWayland (`SDL_VIDEODRIVER=x11`), which throws away Wayland support (fractional scaling, native input). | Not viable as the Linux path. |

WebKitGTK 2.52.6 headers (verified) expose `webkit_web_view_get_snapshot` and a GtkOffscreenWindow exists in GTK3, so a snapshot-polling "offscreen" design is possible, but that is the current design with a different engine and slower snapshots.

Three engines (WKWebView, WebView2, WebKitGTK) mean three behaviours, three cookie stores, three DRM stories, three automation APIs, and a hole on Wayland. **Rejected.**

### 4.2 (b) CEF with off-screen rendering (OSR)

Facts:

- Arch has `extra/cef 151.3.24-1`, BSD-3-Clause, 115.6 MiB download, 363 MiB installed, built against system libs including `openh264` (verified from `pacman -Si`). Upstream Windows/macOS distributions are separate downloads; their size is unverified here.
- CEF's C API (`cef_capi.h`) is plain C with reference-counted vtable structs, so Zig can bind it with `@cImport`. The boilerplate is large: `cef_app_t`, `cef_client_t`, `cef_render_handler_t`, `cef_life_span_handler_t`, `cef_load_handler_t`, `cef_request_handler_t`, `cef_cookie_manager_t`, each with ref-count callbacks. Nothing in the tree uses it. Estimated 2,500 to 4,000 lines of Zig plus a helper subprocess executable. Unverified: how much of this community Zig bindings already cover.
- Windowless rendering gives `OnPaint(buffer BGRA, w, h, dirty_rects)` on the UI thread, with `SendMouseMoveEvent`/`SendKeyEvent`/`SendMouseWheelEvent` for input, so input is real events, not synthesized screenshots. There is also accelerated paint (shared textures): on Linux that is dmabuf and a Wayland-only GTK4 widget bridge exists ([purego-cef2gtk](https://pkg.go.dev/github.com/bnema/purego-cef2gtk)), which confirms the GPU path is real but tied to a GL/GTK/Vulkan consumer. Opal's `SDL_Renderer` cannot import it (section 3), so the usable path is the CPU `OnPaint` buffer, the same cost class as mpv's SW render.
- Process model: browser process plus renderer/GPU/network helpers, so a separate helper binary and, on macOS, a specific `.app` helper layout. CEF wants to own the platform message loop; `external_message_pump` plus `CefDoMessageLoopWork` lets SDL keep it. On macOS CEF requires an `NSApplication` subclass implementing `CefAppProtocol`, which collides with SDL owning `NSApplication` (known pain, unverified in detail).
- Media: by default Chromium/CEF builds ship with proprietary codecs (H.264/AAC) off because of patent licensing for the FFmpeg software path ([CEF issue 3559 and related discussion](https://github.com/chromiumembedded/cef/issues/3559)); a distributor must self-build or rely on OS decoders. Widevine needs the CDM component and a licence agreement with Google ([Widevine overview](https://developers.google.com/widevine/drm/overview)); Opal cannot ship that. So CEF is a good renderer for pages, a poor player for protected or H.264-only media.
- Better division of labour inside CEF: watch media requests (`cef_resource_request_handler_t`) and hand HLS/MP4 URLs to libmpv, which already plays them with hardware decode, instead of using CEF's `<video>`.
- Distribution cost: about 115 to 250 MB per OS added to installers or a first-run download, a helper binary to sign and notarize on macOS, and a Chromium security-update cadence Opal would own (CEF tracks Chromium majors; Arch is at 151 now).

Verdict: the only in-process, cross-platform, non-VNC engine, and a single code path. Costs 4 to 8 engineer-weeks to reach input, IME, popups, downloads, cookies and clean shutdown parity on three OSes, plus a permanent security-update obligation. It still does not give the user's logins, extensions or DRM. **Deferred, behind an explicit product decision** (section 6, phase 4).

### 4.3 (c) Drive the user's own browser

Three transports, which compose.

**c1. Extension channel (Opal Connect).** Exists today for one-way sends. Extending it gives, with the extension APIs:

| Capability | API | Permission / consent |
| --- | --- | --- |
| Tabs: list, URL, title, favicon, audible, activate | `chrome.tabs` / `browser.tabs` | `tabs` for URL/title of all tabs (new permission warning); `activeTab` alone only covers the tab the user invoked it on. |
| Page text, DOM, metadata (og, JSON-LD) | content script or `chrome.scripting.executeScript` | host permission for the origin, or `activeTab` after a user gesture. |
| Media URLs (HLS/DASH/MP4) | (1) `performance.getEntriesByType("resource")` in content script, no extra permission, names cross-origin resources, no headers; (2) page-world hooks on `fetch`/`XHR`/`MediaSource`; (3) `chrome.webRequest` observers (non-blocking is allowed in MV3) with request headers | (1) none beyond the existing `<all_urls>` content script, plus `all_frames`. (3) `webRequest` plus host permission; Chrome Web Store review of `webRequest` with broad hosts is stricter (unverified how strict). |
| Cookies for a host | `chrome.cookies` | `cookies` plus host permission. Optional permissions can be requested at the moment of use. |
| Fetch with the user's session | `fetch(url, {credentials: "include"})` from the service worker | host permission for that origin. The request carries the real browser TLS and HTTP/2 fingerprint and the user's `cf_clearance` if one exists. Where no clearance exists the page must be loaded in a tab (background tab or small window) so the challenge can run, then read with a content script. |
| Downloads, cast, side panel UI | already used | no change |

MV3 lifetime: a service worker dies after about 30 s idle; an active WebSocket extends it since Chrome 116 and each sent or received message resets the timer ([Chrome docs](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle)). A 20 s ping keeps a WebSocket alive. Firefox MV3 background pages are event pages with different timing (unverified).

Local-network protection: Chrome 142 shipped a Local Network Access permission prompt for web pages that reach private/loopback addresses; service workers need the parent origin's grant ([Chrome blog](https://developer.chrome.com/blog/local-network-access)). Whether an extension service worker with loopback `host_permissions` is exempt is unverified; the existing extension already works against loopback on current Chrome, which suggests it is, but the M1 acceptance test must run on a current Chrome to confirm. It also means a hostile web page has a harder time reaching Opal, which helps.

**c2. Native messaging host.** The browser launches a local executable and talks length-prefixed JSON over stdio. Opal's own binary can be the host (`opal --native-host`), reading `<config>/opal/api.token` itself, so no credential is stored in the browser. Chrome checks `allowed_origins` (extension IDs) and Firefox `allowed_extensions` in the host manifest, so a web page cannot reach it. Cost: a host manifest per browser per OS (Linux `~/.config/<browser>/NativeMessagingHosts/` and `~/.mozilla/native-messaging-hosts/`, macOS `~/Library/Application Support/...`, Windows registry keys under HKCU), written only with consent. Snap and Flatpak browsers sandbox the host path (unverified how far current portals fix this), which is a real share of Linux users. Strongest identity story, worst install story. **Phase 3 hardening option, not the first transport.**

**c3. CDP / WebDriver BiDi against a running user browser.**
- Chromium-family: `--remote-debugging-port` is refused with the default profile. Verified in the installed Chromium 152 binary: it contains the message "DevTools remote debugging requires a non-default data directory. Specify this using --user-data-dir." So the user's real profile cannot be driven by CDP; only an Opal-owned profile can. Also, `--load-extension` was removed from branded Chrome from version 137 (works in Chromium and Chrome for Testing) ([chromium-extensions PSA](https://groups.google.com/a/chromium.org/g/chromium-extensions/c/1-g8EFx2BBY/m/S0ET5wPjCAAJ)), so Opal cannot silently preload Opal Connect into a branded Chrome.
- Spike on this machine (headless Chromium 152, temp profile, port 9333, local HTTP page fetching `/stream/master.m3u8?token=abc`): `Network.requestWillBeSent` listed the playlist URL and the segment URL, so a CDP client sniffs media with no extension. `Page.startScreencast` delivered 60 fps at 383 KB/s for a trivial page, versus 67 ms per `captureScreenshot`. Screencast is much better than polling and is still pixels.
- Firefox: CDP was removed in Firefox 141; automation is WebDriver BiDi only ([Mozilla](https://fxdx.dev/cdp-retirement-in-firefox/)). Equivalent coverage (network events, cookies) exists but less tooling. Same profile restrictions in practice (a debugging port requires a launch flag, so it cannot attach to an already running Firefox).
- Cookies via CDP/DB: reading the profile cookie database directly is increasingly unreliable. On Windows, Chrome's App-Bound Encryption stops external tools from decrypting cookies, which is why `yt-dlp --cookies-from-browser` fails for Chromium-family browsers there ([summary](https://www.cyberark.com/resources/threat-research-blog/c4-bomb-blowing-up-chromes-appbound-cookie-encryption)). The extension's `chrome.cookies` API is the supported way out, and it is per host with a permission prompt.

Conclusion for (c): the extension channel is the only way to reach the user's real, running profile on all three browsers. CDP is useful only for an Opal-owned profile, which is option (e).

### 4.4 (d) Servo, Ladybird, others

| Engine | Status | Verdict |
| --- | --- | --- |
| Servo | `servo` 0.1.0 published to crates.io on 2026-04-13 with `ServoBuilder`, `WebView` and pixel readback for headless use; monthly releases with breaking changes, plus an LTS line ([servo.org](https://servo.org/blog/2026/04/13/servo-0.1.0-release/)). Rust API only, no C API: Zig would need a Rust shim crate and a Cargo build step in `build.zig`. No Widevine. Web compatibility is far below Chromium/WebKit/Gecko (general knowledge, not measured here). | Not for real-world sites yet. Re-evaluate in 2027 as an in-process OSR engine. |
| Ladybird | Pre-alpha, alpha planned for 2026 on Linux and macOS, no Windows, no public embedding API found ([Wikipedia](https://en.wikipedia.org/wiki/Ladybird_(web_browser))). | Not embeddable. |
| WPE WebKit | `wpewebkit 2.52.6` and `wpebackend-fdo` are in Arch `extra` (verified in the package database; headers not installed here). Designed for embedding without a toolkit: fdo exports buffers (EGL images or shared memory) that the embedder composites. Linux-only (no maintained Windows or macOS port), no Widevine. | Technically the cleanest Linux OSR, but a Linux-only fork in the road. Not recommended alone. |
| Qt WebEngine | `qt6-webengine` installed here (282 MiB, Chromium based) | Drags in Qt and its event loop; no. |
| Electron | Installed here, not embeddable in a Zig/SDL process. | No. |

### 4.5 (e) Improve the current bridge

| Step | Effect | Still VNC? |
| --- | --- | --- |
| Replace `page.screenshot` polling with CDP `Page.startScreencast` | Measured 60 fps vs about 15 fps ceiling; lower latency; frames only on change | Yes, pixels over a pipe |
| Replace JPEG with shared memory or a WebRTC/H.264 stream | Less copy and CPU for large viewports | Yes |
| Replace Python/Playwright with a Zig CDP client over a WebSocket (`--remote-debugging-pipe` or port) driving an installed Chromium/Chrome/Edge with an Opal-owned `--user-data-dir` | Removes Python, venv and the 200 MB download for anyone with a Chromium-family browser; persistent profile so logins survive; real Chrome includes Widevine; media sniffing for free (`Network.*`) | Only if frames are still drawn in Opal. As a headless sniffer/fetch backend (no frames) it is not VNC at all |
| Keep Camoufox as "hardened engine" | Retains the anti-detect path for hostile sources; CDP-driven vanilla Chromium is easier to fingerprint (`navigator.webdriver`, `Runtime.enable` side effects; unverified how many target sources detect it) | n/a |

Improving the bridge fixes the feel at best. It does not change that the user's identity, extensions and DRM are not in it, so it is a supporting piece (headless CDP fetch/sniff engine), not the answer.

### 4.6 Comparison

| Option | In-Opal render | Real user profile | DRM | Linux Wayland | macOS | Windows | Python removed | Effort | Security surface added |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| (a) native views | overlay | no | per engine | **no** | yes | yes | yes | 6 to 10 wk (3 backends) | 3 engine stacks |
| (b) CEF OSR | yes (pixels) | no | no (no CDM) | yes (CPU path) | yes, hard | yes | yes | 4 to 8 wk plus upkeep | Chromium updates, helper process |
| (c1) extension channel | no (user's window) | **yes** | **yes (in browser)** | yes | yes | yes | n/a | 1 wk (M1), 2 to 3 wk (M2) | new authenticated channel |
| (c2) native messaging | no | yes | yes | Snap/Flatpak issues | yes | yes | n/a | +1 wk | per-OS manifests |
| (c3) CDP on user browser | no | **no (blocked)** | n/a | n/a | n/a | n/a | n/a | not possible | n/a |
| (d) Servo | yes | no | no | yes | yes | yes | yes | 4+ wk, immature | Rust toolchain in build |
| (e) CDP bridge in Zig | optional | Opal-owned only | via Chrome | yes | yes | yes | **yes** | 2 to 3 wk | local debugging port/pipe |

## 5. What "extends the power of Opal" means, concretely

Safe automatic means: runs without an extra prompt once the user has paired a browser and left the feature on. Consent means a user decision in the extension or in Opal, scoped to an origin or one action, which an agent can never grant.

| # | Capability | Delivered by | Needs | Automatic or consent |
| --- | --- | --- | --- | --- |
| 1 | **Media sniffer.** Find the real stream behind a page (HLS/DASH/MP4, captions) and play it in mpv with Referer, Origin and User-Agent set. | c1 (M1: Resource Timing + DOM + iframes; M2: `webRequest`) | content script only (M1) | Detection is local to the browser and automatic (icon badge). Sending to Opal needs the user's click (or a per-site "auto-send" the user turns on). |
| 2 | **Send page or series with metadata.** JSON-LD / og: tags give title, year, season/episode, poster; Opal matches via its existing search (`unified_search`, TMDB) and offers Play, Queue, Add to Wanted. | c1 | content script | Click to send. Matching is automatic after that. |
| 3 | **Real-browser fetch backend** for anti-bot sources, replacing Camoufox for users who have a browser and no Python. | c1 over WebSocket (M2) | `host_permissions` per origin, a background tab for challenges | Consent per origin (once, always for this site, deny). Never automatic for a new origin. |
| 4 | **Cookie handoff** for yt-dlp / mpv on sites that need the user's login (members-only video). | c1 `chrome.cookies` | optional `cookies` permission requested at use, plus host permission | Always consent, per host, with an expiry. Written to a 0600 temp Netscape jar for that job only, deleted when the job ends. Never exposed to agents. |
| 5 | **Agents read the page the user is on** to enrich titles, find alternative sources, add to the Wanted list. | c1 + MCP `browser_page`, operator `page_match` job | the user's "Share this page with Opal agents" action; a global "Browser sharing" switch in Opal that only the UI can flip | Consent per page. Content is untrusted data to the agent (prompt-injection risk, section 9). |
| 6 | **Sign-in surfaces** (Plex, debrid, Trakt, Jellyfin web auth). | Open the system browser to the provider's page; the user's own password manager and 2FA apply. Plex uses a PIN link flow already (`plex.zig` mentions pins); provider flows that return a code or redirect need only the extension or a loopback redirect to report completion. I did not audit each connector. | none new | Opening a URL in the system browser is automatic and safe; completing the link is the user's act. No embedded page. |
| 7 | **Tabs view.** Hub lists the user's tabs with title, URL, audible, detected media. | c1 + `tabs` | `tabs` permission | Off by default; a one-time opt-in; URL list visible to agents only if "Share tab list with agents" is also on. |
| 8 | **DRM sites** (Netflix, Disney+). | none: mpv cannot decrypt | | Hub shows "protected, open in your browser". Out of scope; do not promise it. |

Per option (what each would unlock): (a) and (b) would add only an in-Opal render of pages without 1 to 7 improving; (c) delivers 1 to 7; (e) delivers 1 and 3 for Opal-owned profiles, and 6 poorly (a login window the user cannot trust with passwords, same as today).

## 6. Recommended plan

One plan, in order. Effort is one engineer who knows the tree.

### Phase 1 (M1): Browser Link, media sniffer to mpv. About 1 week, no new browser permission warnings.

Goal: the smallest slice that removes the "I send a page URL and mpv fails or I need the VNC browser" case, verifiable here.

Extension (`extension/`):
- `content.ts`: set `all_frames: true`; add a sniffer that collects media URLs from `performance.getEntriesByType("resource")` (poll on `PerformanceObserver` for `resource` entries), `<video>`/`<source>`/`<track>` elements, and `MediaSource` page hooks later. Classify by extension and, where available, `initiatorType`; keep master playlists (`.m3u8` containing `#EXT-X-STREAM-INF`) over variants, `.mpd`, progressive `.mp4/.webm/.mkv`, drop `.ts/.m4s` segments and known ad/tracker hosts. For each candidate record `page_url` of the frame it was seen in (the iframe URL becomes the Referer, not the top page).
- `background.ts`: keep a per-tab candidate list (in `chrome.storage.session`), badge count on the action icon, and a new `sendMedia` action calling `POST /api/browser/media`.
- `sidepanel/`: list candidates per tab with a Play / Queue button each.
- No new permissions; `webRequest` waits for M2 (headers, requests the page never exposes).

Opal (Zig):
- New `src/services/browser_link_pure.zig`: payload parsing and validation (https/http only, length caps, header allowlist `Referer`, `Origin`, `User-Agent` only; no `Cookie`, no `Authorization` in M1), candidate ranking, and tests.
- New `src/services/remote_browser_api.zig`: `POST /browser/media`. Registered next to the other `remote_*_api.zig` in `remote.zig` `handleApi`.
- Extend `state.RemoteOpenEntry` and `stashRemoteOpen` with `referer` and `user_agent` fields; `forwarded_open.zig` passes them to `browser.loadContentDirectMetaHeaders`, which `playDirect` already supports.
- Raise the request cap for `/api/browser/*` to 16 KB (the current 4096-byte total cap and 2048-byte URL decode buffer would truncate tokenized HLS URLs; this is the single most likely M1 bug).
- Principal and pairing are introduced in M1 even though the first route is small, so that nothing in M1 needs the machine token (section 8).

Opal UI: Settings > Browser link section: "Pair a browser" shows a 6-digit code valid 2 minutes; list of paired browsers with last-seen and Revoke. Browse > Web gets a banner "Use your own browser: pair Opal Connect" above the legacy pane.

### Phase 2 (M2): Browser Hub and fetch backend. About 2 to 3 weeks.

- WebSocket `GET /api/browser/ws` (Opal-side handshake and frame parser in `browser_ws_pure.zig`, about 250 lines, SHA-1 and base64 from `std.crypto`; whether `std.http.Server.WebSocket` exists and works with Opal's hand-rolled server on Zig 0.16 is unverified, so plan for our own). Extension keeps it alive with a 20 s ping from the service worker.
- Opal-to-browser commands: `tabs`, `fetch {url, method, body?, wait_for_challenge}`, `page {tab}`, `sniff {tab}`. The extension answers only after its own consent check; replies are size-capped (2 MB, same as `SCRAPE_BUF_CAP`).
- `scrape_fetch.zig`: new tier between plain curl and the bridge. Order: plain, then connected real browser (if the origin is allowed), then Camoufox/CloakBrowser if installed. `scrape_fetch_pure.zig` gets the order logic and tests. This removes the Python requirement for users with a browser; it does not remove it for users who rely on the anti-detect engine.
- `webRequest` observation as an optional permission for header-accurate sniffing and requests the page never exposes.
- `src/ui/browser_hub.zig`: replaces `browser.renderContent` as the Browse > Web landing; the old pane stays behind "Legacy embedded browser" until phase 4's decision. Shows connected browsers, shared pages, per-page candidates, Play / Queue / Add to Wanted / Add as source.
- Cookie handoff (capability 4): `ytdlp_argv_pure.zig` gets a distinct operation `with_cookie_jar` (the existing test asserting no `--cookies` stays true for every other operation), a jar writer with 0600 and delete-on-exit, and an extension-side prompt.
- Operator job `page_match` in `operator_pure.zig` (job kinds are `endpoint_repair`, `local_names`, `match_help`): context is the user-shared page title, URL host, and at most 2 KB of text; answer is `{title, year, kind}`; proposal only, never auto-applied.

### Phase 3 (optional): native messaging host and Opal-owned CDP engine. About 2 weeks each, only on demand.

- `opal --native-host` and consented manifest install per browser, for users whose threat model dislikes a loopback listener, and for Snap/Flatpak if portals allow.
- Zig CDP client (`src/services/cdp_client.zig`) driving an installed Chromium-family browser, headless, Opal-owned profile, as a fetch/sniff engine selectable beside Camoufox. Removes Python for users without the extension. Screencast frames are not drawn in Opal.

### Phase 4 (deferred): in-Opal rendered page.

Only if the product owner decides that rendering a page inside Opal is a requirement after phases 1 and 2 ship. Then: CEF OSR with CPU `OnPaint` into the existing `updateFrameTexture` texture path, CEF's media requests handed to mpv, no Widevine. Spike first: Zig `@cImport` of `cef_capi.h`, one windowless browser, 60 fps scroll on Linux Wayland and macOS, then decide. Servo is the alternative to revisit in 2027.

### What the plan removes

The VNC feel for the cases that matter (media, login, sources) is removed in phases 1 and 2 by not rendering pages at all. The Python dependency is removed from the common path in phase 2 and from the uncommon path in phase 3. The legacy pane is retired once usage data shows nobody opens it; that needs a counter, which does not exist today.

## 7. New API and MCP surface

HTTP routes (all under `/api/browser/`, all require the `.browser` principal or `.machine`/`.admin_session` where noted):

| Route | Method | Who | Purpose |
| --- | --- | --- | --- |
| `/browser/pair` | POST | unauthenticated, code-gated | Body `{code, label, browser, extension_id}`; returns `{id, token}` once. 5 failed attempts burns the code. Added to the unauthenticated list with `/health` and `/api/auth/*`. |
| `/browser/links` | GET | `.machine`, `.admin_session` | Paired browsers: id, label, browser, created, last seen, connected, sharing flags. |
| `/browser/revoke` | POST | `.machine`, `.admin_session` | Revoke one link (`id`). |
| `/browser/media` | POST | `.browser` | `{page_url, title, art, candidates[{url, kind, referer, origin, ua, duration?}], action: play|queue|add_to_wanted}`; returns `{ok, candidate_id}`. |
| `/browser/page` | POST | `.browser` | User-shared page: `{url, title, og, jsonld, text<=8 KB, shared_with_agents: bool}`. |
| `/browser/context` | GET | any authed | The last shared page and its candidates (what `browser_page` reads). Empty unless the user shared with agents. |
| `/browser/ws` | GET (upgrade) | `.browser` | M2 command channel. |
| `/browser/fetch` | POST | any authed with `spend` policy | Queue a fetch through the browser; returns after user consent or a denial (`403 {"error":"origin not allowed"}`). |

MCP tools (names and tiers follow `docs/mcp.md`: every tool has a tier, `ops_pure.zig` is the single source, OpenAPI is regenerated and `zig build test-ops` checks drift):

| Tool | Tier | What | Extra gate beyond the tier |
| --- | --- | --- | --- |
| `browser_status` | read | Paired browsers, connected or not, whether a page is shared. No page content. | none |
| `browser_page` | read | The page the user shared: title, URL, og fields, up to 8 KB text, candidate ids. | Only populated for pages shared with agents; global "Browser sharing" switch must be on. Output is wrapped and labelled untrusted. |
| `browser_media_candidates` | read | Candidate ids, kind, host, duration for the shared page. URLs are not returned in full (host and path only), so an agent cannot launder credentials. | same as `browser_page` |
| `browser_play_candidate` | spend | Play or queue a candidate by id (never by arbitrary URL). | same switch. Same tier as `play_url` since it streams. |
| `browser_tabs` | read | Titles and hosts of open tabs. | Off unless the user enabled "Share tab list with agents"; full URLs withheld. |
| `browser_fetch` | spend | Fetch a URL through the user's browser, 2 MB cap, text only. | Per-origin user consent in the extension. Denied origins fail closed. |

Not exposed as tools, ever: cookie export, cookie jars, pairing, revocation, enabling sharing, raw tab control, script evaluation. The agent cannot grant consent; matching the rule already in `docs/mcp.md` for scheduled tasks ("Agents cannot flip that switch").

`opal-mcp --deny-prefix browser` removes the whole family. `docs/mcp.md` gets a "Browser" section; `skills/opal-media/SKILL.md` gets a "play what is on my screen" workflow. The audit log (`mcp-audit.jsonl`) already drops query strings; `browser_*` calls log tool name and outcome only, never page text.

## 8. Integration points (files)

| Area | File | Change |
| --- | --- | --- |
| Pure logic | `src/services/browser_link_pure.zig` (new) | Payload validation, header allowlist, candidate ranking, pairing code and token rules. Tests in `build.zig` like the other `*_pure.zig`. |
| Route | `src/services/remote_browser_api.zig` (new); hook in `remote.zig` `handleApi` | Routes above. Per-route request cap 16 KB in `remote_http.readRequest` callers. |
| Auth | `src/services/access_pure.zig`, `remote.zig` `principalForBearer`, `src/services/auth_store.zig` | Add `Principal.browser` and `Capability.browser_link`. **`allowsRoute` currently returns true for any route with no listed capability** (`routeCapability` returns null), so a new principal would inherit every unlisted route. Add a deny-by-default branch for `.browser` with an explicit allowlist (`/browser/*`, `/status`, `/health`) and a test that enumerates every route in `openapi.json` against it. |
| Open queue | `state.zig` `RemoteOpenEntry`, `remote.zig` `stashRemoteOpen`, `forwarded_open.zig` | `referer`, `user_agent` fields; pass to `loadContentDirectMetaHeaders`. |
| Scrape order | `scrape_fetch.zig`, `scrape_fetch_pure.zig` | Real-browser tier (M2). |
| Cookies | `ytdlp_argv_pure.zig`, `player/ytdl_opts_pure.zig` | A distinct opt-in operation; keep the existing "no cookies" tests for all others. |
| Hub UI | `src/ui/browser_hub.zig` (new), call site where `browser.renderContent` is invoked from Browse | Replaces the landing; legacy pane behind a setting. |
| Settings | `src/ui/settings.zig` (Network > Browser section near line 2141) | Pairing, list, revoke, sharing switches. |
| Operator | `operator_pure.zig`, `operator.zig` | `page_match` job (M2). |
| Registry | `ops_pure.zig`, `docs/openapi.json` | New ops; run `opal-mcp --openapi`. |
| Extension | `content.ts`, `background.ts`, `shared.ts`, `sidepanel/`, `options/` | Sniffer, pairing UI (replaces pasting the machine token), WebSocket client (M2), per-origin consent store. |

dvui: the Hub is ordinary dvui widgets (boxes, labels, buttons), no texture work. The legacy pane keeps `frame_texture` as is. Nothing in phases 1 and 2 touches the SDL window or renderer.

## 9. Threat model

New channel: browser extension (or a page, if it can reach it) to Opal on loopback, and Opal to the extension (M2).

Assets: the machine bearer token and sessions, the user's cookies, the user's browsing history and open tabs, Opal's ability to fetch, download and spend (torrents, agent runs), local files.

| Threat | Today | Mitigation in this design |
| --- | --- | --- |
| A web page calls Opal's API from the user's browser | Needs a bearer token; CORS preflight with `Authorization` fails because the server sets no `Access-Control-Allow-Headers`. `Access-Control-Allow-Origin: *` is set on responses. Chrome 142+ also prompts web pages for loopback access ([LNA](https://developer.chrome.com/blog/local-network-access)). | Keep. New unauthenticated route `/browser/pair` is code-gated, rate-limited, one-shot. New `/browser/ws` requires `Origin` to be `chrome-extension://<paired id>` or `moz-extension://<uuid>`, checked at upgrade. WebSocket handshakes are not subject to CORS, so the Origin check and a token in the first frame (never in the URL) are the control. |
| DNS rebinding to `127.0.0.1:41595` | The Host gate was deliberately removed (`remote.zig:780`). Mitigated only by bearer auth. | `/browser/ws` and `/browser/pair` enforce `Host` in `{127.0.0.1:<port>, localhost:<port>, [::1]:<port>}` when bound to loopback. When bound to LAN, `/browser/pair` and `/browser/ws` are refused unless the user turns on a "Allow browser pairing over LAN" switch. |
| Extension token theft or over-privilege | Extension holds the machine token if the user pasted it. | Pairing issues a per-browser `.browser` token: stored in `chrome.storage.local`, stored hashed in Opal, scoped to `/browser/*`, listable and revocable in Opal. The extension setup stops asking for the machine token (the "API token" path stays for scripts). |
| A page controls what the extension sends (the channel is page-influenced) | Content script sends DOM-derived titles and URLs. | Treat all page-derived fields as untrusted data: length caps, control-character rejection, scheme whitelist (http/https only), header allowlist, no page-derived value ever becomes a command, argv element or file path. Candidate URLs go to mpv only through `playDirect`, which already sets options as data. |
| Prompt injection through shared page text | Not present. | `browser_page` output is labelled untrusted and truncated to 8 KB; agents that can read it still hold only the policy ceiling the user set (`spend` default means a malicious page could try to make an agent `play_url`/`wanted_add`; the doc for the skill tells agents never to act on page text and the operator job returns only a schema-validated title/year/kind). The global sharing switch is off by default. |
| SSRF through fetch | `/api/scrape` takes any http(s) URL; I did not find a loopback/private-address guard in `handleScrapeBody` (unverified: it may live in `scrape_fetch` or `reliable_fetch`). | `browser_fetch` goes through the user's browser, so it can reach the user's LAN with the user's cookies: the extension refuses non-public targets (loopback, RFC1918, link-local, `.local`) unless the user adds that origin by hand. Add the same guard to `/api/scrape` as a separate fix. |
| Cookie exposure | None. | Cookies only by explicit per-host consent, never over MCP, jar file 0600 in the config dir, deleted after the job, never logged. `Cookie` and `Authorization` headers are excluded from the M1 allowlist and from audit logs. |
| Extension permissions and store review | `<all_urls>` content script, optional hosts, no `webRequest`/`cookies`/`tabs`. | M1 adds none. M2 adds `webRequest`, `cookies`, `tabs` as optional permissions requested at the moment of use, each with an in-extension explanation. Store review for `webRequest` plus broad hosts is slower and stricter (unverified details); keep a self-hosted build path. |
| Service worker spoofing / local malware | A local process with the user's UID can read `api.token` anyway. | Out of scope; same-UID malware already owns the machine token. Pairing tokens do not widen that. |
| Pairing code brute force | n/a | 6 digits valid 2 minutes, 5 tries, then burned; constant-time compare; UI shows the label of what paired. |
| Stale consent | n/a | Per-origin fetch consent has an expiry (default 30 days) and is listed with a Revoke in the extension; Opal shows the list read-only. |

## 10. Acceptance tests

Pure (run in `zig build test-*`, no GUI): `browser_link_pure.zig`
- Payload with `javascript:`/`file:`/`data:` URL is rejected; URL over 2048 bytes is rejected by validation, not truncated.
- `Cookie` and `Authorization` headers are dropped by the allowlist; control characters in title are rejected.
- Ranking prefers a master playlist over a variant, a variant over a segment; ads/tracker hosts are never ranked.
- Pairing code: expires at 120 s, burns at the 6th attempt, one-shot success.
- `access_pure`: a table test iterates every path in `openapi.json` and asserts `.browser` is allowed only for the allowlist (fails when someone adds a route).
- `ytdlp_argv_pure`: every existing operation still has no `--cookies*`; `with_cookie_jar` has exactly one, followed by a path under the config dir.
- `zig build test-ops` passes with the regenerated `openapi.json`.

M1 live (Linux, installed Chromium 152, no GUI of Opal, isolated port):
1. Start Opal headless (`OPAL_HEADLESS=1`, a non-default port; not 41595) with a throwaway config dir.
2. Serve a fixture page that (a) has an iframe on a second origin whose script `fetch`es a tokenized `master.m3u8` and (b) a plain `<video src=*.mp4>`.
3. Launch Chromium with `--load-extension=<extension/dist/chrome>` (unbranded Chromium honours it), pair with the code printed by the headless daemon.
4. Assert the extension reports two candidates, the iframe's candidate carries the iframe URL as Referer, and `POST /api/browser/media` results in a mpv load with `http-header-fields` containing that Referer (read through `/api/player` or the log).
5. Negative: a page script `fetch("http://127.0.0.1:<port>/api/browser/media", ...)` without a token gets 401; with a forged `Origin` and `Host: evil.example` the WebSocket upgrade (M2) is refused.
6. Repeat on current Chrome stable and Firefox to confirm the loopback fetch is not blocked by Local Network Access (unverified today).

M2 live:
- Fetch through the browser returns the HTML of a Cloudflare-challenged fixture only after the user approves the origin; denial returns 403 and no request is made.
- Cookie handoff: yt-dlp is invoked with `--cookies <jar>`, the jar is mode 0600, and it no longer exists after the job; the audit log contains no cookie values.
- MCP: `opal-mcp --read-only` lists `browser_status`, `browser_page`, `browser_media_candidates`, `browser_tabs` and hides `browser_play_candidate` and `browser_fetch`; `--deny-prefix browser` hides all.
- Service worker survives 5 minutes idle with the WebSocket open (20 s ping) and reconnects after Opal restarts.

Performance gate: sniffing must add no measurable load time on a page-heavy site (content script work under 5 ms per page in a Chrome trace; PerformanceObserver only).

## 11. Unverified, open questions, decisions needed

Not verified here:
- Whether an extension service worker with loopback `host_permissions` is exempt from Chrome's Local Network Access prompt on current stable; test in M1 step 6.
- Chrome Web Store and AMO review friction for `webRequest`, `cookies`, `tabs` requested as optional permissions.
- Firefox MV3 background lifetime and whether `webRequest` and `cookies` behave the same for the sniffer; Firefox was not run.
- Snap and Flatpak browsers and native messaging, and whether the current portals make a host reachable.
- Whether `std.http.Server.WebSocket` is usable on the Zig 0.16 toolchain in Opal's hand-rolled server; the design assumes writing our own handshake and framing.
- CEF: size of upstream Windows/macOS distributions; how complete any community Zig bindings are; the exact `NSApplication`/`CefAppProtocol` interaction with SDL; WPE headers (`wpewebkit` is in the repo database but not installed here); WKWebView third-party FairPlay; WebView2 Widevine/PlayReady behaviour.
- Whether CloakBrowser's Chromium includes Widevine; whether page audio ever leaves the bridge's headless browser.
- Whether `/api/scrape` has an SSRF guard elsewhere in the fetch stack.
- Servo and Ladybird web compatibility is from general knowledge, not measurement.
- Anti-bot detection rate of vanilla Chromium under CDP versus Camoufox for Opal's actual source list: no measurement exists in the tree.

Verified here: everything in sections 2 and 3 from the source; the Chromium 152 refusal message for remote debugging on the default profile; CDP network sniffing and screencast figures from the spike on this machine (headless Chromium 152, temp profile, trivial page, port 9333; spike files in `/tmp`, not committed); installed packages and headers (`webkit2gtk-4.1` 2.52.6 with `webkit_web_view_get_snapshot`, `sdl2-compat` 2.32.72, `cef` 151.3.24 and `wpewebkit` 2.52.6 in `extra`).

Decisions for the product owner:
1. Accept "the browser is the user's own, and Opal's Web page becomes a hub"? If an in-Opal rendered page is a hard requirement, phase 4 (CEF OSR) starts after the spike and the cost in 4.2 applies.
2. Is the optional-permission model (`webRequest`, `cookies`, `tabs` asked at the moment of use) acceptable for store review, or should the extension ship two builds (store build with M1 only, direct build with everything)?
3. Do we keep Camoufox/CloakBrowser as optional hardened engines, given the upstream maintenance state in section 2.4?
