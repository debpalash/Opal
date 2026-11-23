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

## Listener and transport

Native and headless binaries default to `127.0.0.1`. Explicit `web_bind=lan`
profiles still bind all interfaces. The Docker image sets `OPAL_WEB_BIND=lan`
so its basic Compose profile can publish the container port on host loopback.

The Caddy and Tailscale profiles set `OPAL_HTTPS_PROXY=1`. Opal shares the proxy's
network namespace, forces its listener to loopback, and emits Secure cookies.
Only the proxy accepts network traffic. Forwarded headers cannot enable this
mode. Complete first-admin setup with the basic local profile before switching.

See [secure remote access](secure-remote.md) for non-container deployment,
account privileges, and the exact trust boundary. Do not publish plain HTTP to
network clients: passwords and session cookies would be unencrypted.

## Required volume mounts

| Mount      | Purpose                                  | XDG mapping            |
|------------|------------------------------------------|------------------------|
| `/config`  | config, DB, `api.token`, one-time `setup.token` | `XDG_CONFIG_HOME`/`HOME` |
| `/cache`   | caches, thumbnails, transient data       | `XDG_CACHE_HOME`       |
| `/media`   | downloads, `/stream` root, default local library | `OPAL_DOWNLOAD_DIR=/media` |

With `XDG_CONFIG_HOME=/config`, the config dir resolves to **`/config/opal/`**.

`OPAL_DOWNLOAD_DIR` (absolute paths only) sets the default download folder.
Without it, downloads went to `$HOME/Downloads/opal`. Because `HOME=/config`, that put
them on the config volume, and `/media` was never read. A `save_path` you set
in Settings still takes precedence.

The compose files use long-syntax bind mounts with
`create_host_path: false`. If a host directory is missing, startup fails with
a clear error. With the short `../data/config:/config` form, Docker would
silently create a root-owned directory that UID 10001 cannot write. Run the
`install -d` / `chown` lines above before the first start. You can add extra
read-only libraries beneath `/media` (for example
`- /srv/films:/media/films:ro`).

## Pinned images

`Dockerfile` (`debian:12-slim`), `docker-compose.tls.yml` (`caddy:2`) and
`docker-compose.tailscale.yml` (`tailscale/tailscale:stable`) reference
reviewed multi-arch index digests (`image:tag@sha256:…`; the digest wins).
The Docker workflow fails if any `FROM`/`image:` loses its digest. To bump an
image, resolve the new index digest from the registry, rebuild, rerun the
validation below, and commit the digest change on its own.

## Local validation (scripted)

`scripts/validate-headless-deploy.py` exercises a private deployment end to
end. It uses a throwaway HOME/XDG root with the container layout and a free
port, so it never touches `~/.config/opal`, and it never prints a credential:

```sh
zig build -Dheadless=true                     # or point --binary at a build
python3 scripts/validate-headless-deploy.py   # bare binary
python3 scripts/validate-headless-deploy.py --image opal:headless   # Docker host
```

| Step | What is proved |
|---|---|
| startup | `/health` 200; `setup.token` is 0600, 64 hex, and absent from the log |
| bootstrap | registration needs the header token, rejects a cross-origin request, is single-use, and removes the token file |
| range | `/stream` from the download mount: 206 plus the exact `Content-Range` and bytes for four ranges; 401 without a session; traversal refused |
| identity | `/api/downloads` gives the hosted file the shared media identity: `here=direct`, `opal=false`, and only a "Play here" action |
| sse | `/events` is `text/event-stream` and sends a data frame |
| reconnect | three SSE reconnects each get a frame; a bogus session gets 401 |
| restart | clean SIGTERM exit; the session, the account and `api.token` survive; `setup.token` is not recreated |
| https_proxy | Caddy (`tls internal`, `skip_install_trust`, `admin off`) in front of an `OPAL_HTTPS_PROXY=1` loopback server: verified TLS, a Secure cookie, and SSE + Range through the proxy (SKIP when `caddy` is absent) |
| expiry | expired and logged-out sessions are refused by the API and `/stream`; a live session is kept; re-login works |

`tests/features/test_headless_deploy.py` runs it whenever a headless binary is
present.

## Tailscale: manual-only steps

The repository never automates anything that changes a real tailnet. The
validation script and the feature tests make **no** Tailscale calls. Do the
following steps by hand, on the deployment host, with your own account:

1. Create the auth key in the Tailscale admin console (reusable or one-off,
   with an expiry you choose). Pass it as `TS_AUTHKEY` in the environment only,
   never in a committed file.
2. Review your tailnet ACL / grants so that only the intended users or tags
   reach `opal:443`.
3. Start `deploy/docker-compose.tailscale.yml`, then run
   `docker compose -f deploy/docker-compose.tailscale.yml exec tailscale tailscale status`.
4. From another tailnet device, test an authenticated HTTPS request and a
   media seek. You can run the validation script's checks by hand against
   `https://opal.<tailnet>.ts.net`.
5. Funnel (public exposure) is opt-in and off by default. Enabling it is a
   separate, deliberate admin-console and `tailscale funnel` action. Read
   [secure remote access](secure-remote.md) first.
6. After first login, revoke or let the auth key expire. `TS_AUTH_ONCE=true`
   and the persisted `data/tailscale` state keep the node joined.

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

Caddy terminates TLS and proxies to `127.0.0.1:41595` in its shared network
namespace. Opal binds no public port and sends Secure cookies.

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
The sidecar persists its node identity in `data/tailscale` and uses
`TS_AUTH_ONCE=true`, so a routine restart does not try to consume the auth key
again. It explicitly uses kernel networking (`TS_USERSPACE=false`) with
`/dev/net/tun` and `NET_ADMIN`; the image otherwise defaults to slower userspace
networking. The host must provide `/dev/net/tun`. On the deployment host, check
`docker compose -f deploy/docker-compose.tailscale.yml exec tailscale tailscale status`
after startup, then test both an authenticated HTTPS request and a media stream
from another tailnet device. These runtime checks have not been performed by
the repository's static tests. Restrict who can read `data/tailscale`, since it
contains the node identity, and do not put `TS_AUTHKEY` in committed files.

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
