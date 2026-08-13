# Headless deployment (Opal)

Run Opal as a headless server in Docker — qbittorrent-nox / Jellyfin style. ONE
port (`:41595`) serves both the web UI (`/`) and the JSON API; no GUI/window is
opened. First-admin creation requires the one-time owner credential written to
the mounted config directory; a network visitor cannot claim a fresh server
with only a username and password. After setup, users sign in normally.
Automation and the browser extension can still use the static `api.token`
(`$XDG_CONFIG_HOME/opal/api.token`). Browser playback streams downloaded files
via HTTP Range (`/stream`) with SRT sidecars served as WebVTT (`/vtt`).

Put it behind a reverse proxy (Caddy / nginx / Traefik) for HTTPS, or expose it
on your tailnet with `tailscale serve`. Bind to `127.0.0.1` and let the proxy
handle TLS + public access.

> The binary, app name, and on-disk config directory are named `opal`; inside
> the container, persistent configuration therefore lives under `/config/opal/`.

## Build & run

On a **real Linux/Docker host** (see the macOS caveat at the bottom):

```sh
install -d data/config data/cache data/media
sudo chown -R 10001:10001 data/config data/cache data/media
docker compose -f deploy/docker-compose.yml up --build -d
docker compose -f deploy/docker-compose.yml logs -f opal  # path only, never token value
docker compose -f deploy/docker-compose.yml down
```

The image runs as UID/GID `10001:10001`. Preparing the bind-mount directories
before the first start lets that non-root process create its database and
owner-only credentials.

Or with plain Docker:

```sh
docker build -t opal:headless .
install -d data/config data/cache data/media
sudo chown -R 10001:10001 data/config data/cache data/media
docker run -d \
  -e OPAL_HEADLESS=1 \
  -p 127.0.0.1:41595:41595 \
  -v "$PWD/data/config:/config" \
  -v "$PWD/data/cache:/cache" \
  -v "$PWD/data/media:/media" \
  opal:headless
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

The service binds all container interfaces in headless mode, but the basic
compose and `docker run` examples publish it on host loopback only. Keep
`api.token`, account sessions, and the one-time `setup.token` secret, and put
the container behind a firewall / reverse proxy for remote access. Do not
publish `41595` to the internet without TLS and access control in front.

## Required volume mounts

| Mount      | Purpose                                  | XDG mapping            |
|------------|------------------------------------------|------------------------|
| `/config`  | config, DB, `api.token`, one-time `setup.token` | `XDG_CONFIG_HOME`/`HOME` |
| `/cache`   | caches, thumbnails, transient data       | `XDG_CACHE_HOME`       |
| `/media`   | local media library                      | —                      |

With `XDG_CONFIG_HOME=/config`, the config dir resolves to **`/config/opal/`**.

## Config setup

Mount your config so it lands at `/config/opal/`:

```
data/config/opal/config.json   # TMDB key, Jellyfin URL/keys, etc.
data/config/opal/api.token     # long-lived machine Bearer token
data/config/opal/setup.token   # one-time first-admin credential (fresh install only)
```

- `config.json` — TMDB / Jellyfin / scraper keys and preferences.
- `api.token` — the API token. If absent, the server creates one on first boot
  (`loadOrCreateToken()`); read it back from `/config/opal/api.token` to
  configure clients. Provide your own to keep it stable across rebuilds.
- `setup.token` — a random 256-bit credential created with mode `0600` while
  there are no accounts. It authorizes exactly the first admin registration
  and is deleted immediately after that succeeds. Startup logs announce this
  path only; they never print the credential.

## First-admin bootstrap

This is a local operator proof, not an unauthenticated first-visit claim:

1. Start the container and wait for `/health`.
2. Read `data/config/opal/setup.token` on the Docker host (or run
   `docker compose -f deploy/docker-compose.yml exec -T opal cat
   /config/opal/setup.token`). Do not paste it into chat, issue reports, or
   logs.
3. Open `http://127.0.0.1:41595/` locally and enter the credential with the new
   admin username and password. For an API client, POST the form fields to
   `/api/auth/register` and send the credential in the dedicated
   `X-Opal-Setup-Token` header—not in the URL or form body.
4. Confirm `setup.token` has disappeared. All later access uses account login
   or the long-lived machine `api.token` as appropriate.

Registration also rejects non-local/non-numeric Host authorities and a
cross-authority browser Origin. When deploying behind Caddy or Tailscale,
start the basic loopback-only compose profile first, complete this bootstrap,
stop it, and then start the proxy profile against the same `data/config` mount.

Call the API with the token:

```sh
curl -H "Authorization: Bearer $(cat data/config/opal/api.token)" \
  http://HOST:41595/api/status
```

(Authenticated data endpoints live under the `/api/` prefix, e.g.
`/api/status`, `/api/search`, `/api/load`.)

## Healthcheck

The container `HEALTHCHECK` hits `http://localhost:41595/health` — an
unauthenticated liveness probe that returns `{"ok":true}` (served before the
Bearer-auth gate). A clean HTTP 200 means the JSON API is up and serving; no
token needed.

## Access — accounts, HTTPS, Tailscale

Auth is a **web-UI account**. The first account additionally requires the
local `setup.token` proof described above; after that, users sign in with their
username and bcrypt-hashed password. Automation can still authenticate with
the static machine `api.token`.

For remote access, don't expose plain HTTP — put TLS in front. Two ready-to-run
profiles ship in `deploy/`:

**HTTPS via Caddy** (public domain, automatic Let's Encrypt cert):

```sh
# First complete the local bootstrap above using deploy/docker-compose.yml,
# then stop that profile. Both profiles reuse data/config.
docker compose -f deploy/docker-compose.yml down
# DNS for your domain must point at this host; ports 80 + 443 reachable.
DOMAIN=opal.example.com docker compose -f deploy/docker-compose.tls.yml up --build -d
# Sign in at https://opal.example.com
```

Caddy terminates TLS and proxies to `opal:41595`; Opal binds no public port.

**Tailscale** (private tailnet, `*.ts.net` HTTPS, no domain/ports/certs to
manage):

```sh
# First complete the local bootstrap above using deploy/docker-compose.yml,
# then stop that profile. Both profiles reuse data/config.
docker compose -f deploy/docker-compose.yml down
# Reusable auth key from https://login.tailscale.com/admin/settings/keys
TS_AUTHKEY=tskey-auth-xxxx docker compose -f deploy/docker-compose.tailscale.yml up --build -d
# Sign in at https://opal.<your-tailnet>.ts.net
```

A `tailscale/tailscale` sidecar joins the tailnet and `tailscale serve`s Opal
over HTTPS with a Tailscale-issued cert. Use Tailscale Funnel to make it public.

Either way, keep the base HTTP server on `127.0.0.1`/the internal network and
let the proxy handle TLS + exposure.

## NOT verifiable on macOS dev — needs a real Linux/Docker host

The following **cannot** be validated on the macOS development machine and must
be checked on a real Linux/x86_64 Docker host:

- **Actual headless boot** — `OPAL_HEADLESS=1` path coming up without a display.
- **mpv `vo=null` streaming to a client** — playback driven server-side with no
  video output, streamed to a remote client.
- **SDL/X11 absence** — the runtime image installs no SDL2/libX11/mesa/xorg;
  CI also inspects the binary's direct ELF dependencies and fails if the GUI
  stack reappears.
- **`docker build` success** — including g++ compiling `torrent_wrapper.cpp`
  inside the container and the onnxruntime/libtorrent package names resolving
  (best-effort for debian:12; may need vendored installs).
- **SIGTERM clean-exit timing** — `docker stop` sends SIGTERM; verify the
  server shuts down cleanly (`stop()` join, no leak report failures) within the
  stop grace period.
