# Headless deployment (Opal / zigzag)

Run zigzag as a headless server in Docker. The JSON API (`:41595`) and web UI
(`:3000`) are exposed; no GUI/window is opened in headless mode.

> The binary, app name, and on-disk config dir are all **`zigzag`** (legacy) —
> do not expect an `opal` path anywhere.

## Build & run

On a **real Linux/Docker host** (see the macOS caveat at the bottom):

```sh
docker compose up --build -d      # build image + start, detached
docker compose logs -f zigzag     # follow logs
docker compose down               # stop
```

Or with plain Docker:

```sh
docker build -t opal-zigzag:headless .
docker run -d \
  -e OPAL_HEADLESS=1 \
  -p 41595:41595 -p 3000:3000 \
  -v "$PWD/data/config:/config" \
  -v "$PWD/data/cache:/cache" \
  -v "$PWD/data/media:/media" \
  opal-zigzag:headless
```

## The 0.0.0.0 bind (T6)

In **windowed desktop** mode the JSON API binds **`127.0.0.1`** (loopback only)
for security — this is unchanged and byte-identical.

In **headless** mode (`state.app.is_headless == true`, set from `OPAL_HEADLESS=1`)
`serverLoop` binds **`0.0.0.0`** so the container is reachable from outside:

```zig
const ip = if (state.app.is_headless) "0.0.0.0" else "127.0.0.1";
const addr = std.Io.net.IpAddress.parseIp4(ip, port) catch return;
```

The `stop()` accept-wakeup connect always uses `127.0.0.1` (connecting to
loopback works regardless of bind address) — that is intentional and untouched.

Because the API is now reachable on the network in headless mode, the Bearer
token is your only protection — keep `api.token` secret and put the container
behind a firewall / reverse proxy. Do not expose `41595` to the public internet
without TLS termination and access control in front.

## Required volume mounts

| Mount      | Purpose                                  | XDG mapping            |
|------------|------------------------------------------|------------------------|
| `/config`  | config.json, `api.token`, app state      | `XDG_CONFIG_HOME`/`HOME` |
| `/cache`   | caches, thumbnails, transient data       | `XDG_CACHE_HOME`       |
| `/media`   | local media library                      | —                      |

With `XDG_CONFIG_HOME=/config`, the config dir resolves to **`/config/zigzag/`**.

## Config setup

Mount your config so it lands at `/config/zigzag/`:

```
data/config/zigzag/config.json   # TMDB key, Jellyfin URL/keys, etc.
data/config/zigzag/api.token     # Bearer token for the JSON API + web UI
```

- `config.json` — TMDB / Jellyfin / scraper keys and preferences.
- `api.token` — the API token. If absent, the server creates one on first boot
  (`loadOrCreateToken()`); read it back from `/config/zigzag/api.token` to
  configure clients. Provide your own to keep it stable across rebuilds.

Call the API with the token:

```sh
curl -H "Authorization: Bearer $(cat data/config/zigzag/api.token)" \
  http://HOST:41595/api/status
```

(Authenticated data endpoints live under the `/api/` prefix, e.g.
`/api/status`, `/api/search`, `/api/load`.)

## Healthcheck

The container `HEALTHCHECK` hits `http://localhost:41595/health` — an
unauthenticated liveness probe that returns `{"ok":true}` (served before the
Bearer-auth gate). A clean HTTP 200 means the JSON API is up and serving; no
token needed.

## NOT verifiable on macOS dev — needs a real Linux/Docker host

The following **cannot** be validated on the macOS development machine and must
be checked on a real Linux/x86_64 Docker host:

- **Actual headless boot** — `OPAL_HEADLESS=1` path coming up without a display.
- **mpv `vo=null` streaming to a client** — playback driven server-side with no
  video output, streamed to a remote client.
- **SDL/X11 absence** — the runtime image installs no SDL2/libX11/mesa/xorg.
  NOTE: this is **not clean this cycle** — dvui/SDL are still linked into the
  binary (the no-SDL/headless link is the follow-up, T7), so the binary may
  still reference SDL symbols even though the libs are absent at runtime.
- **`docker build` success** — including g++ compiling `torrent_wrapper.cpp`
  inside the container and the onnxruntime/libtorrent package names resolving
  (best-effort for debian:12; may need vendored installs).
- **SIGTERM clean-exit timing** — `docker stop` sends SIGTERM; verify the
  server shuts down cleanly (`stop()` join, no leak report failures) within the
  stop grace period.
