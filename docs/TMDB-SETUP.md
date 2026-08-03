# TMDB setup

Opal uses [The Movie Database](https://www.themoviedb.org) for movie and TV
metadata — posters, trending rows, seasons and episodes, and title search. This
page is for **app users**: how to get a token and where to put it.

TMDB is only one of Opal's sources. Everything else — torrents, Jellyfin, Plex,
YouTube, Live TV, manga, local files — works with no token at all.

## Do I need one?

Depends on how you installed Opal.

| How you installed | Token needed? |
|---|---|
| Official release (GitHub Releases, `install.sh`, `.deb`/`.rpm`, AppImage, Homebrew, `opal-bin` from the AUR) | **No.** A working key is compiled in. Paste your own only if you want to use your own quota. |
| Built from source (`zig build`, `opal` from the AUR, Docker, any distro package built locally) | **Yes.** Source builds have no key compiled in, so TMDB browse and search stay empty until you add one. |

The difference is not a bug. The key is injected at build time from a repository
secret that only the official release job has, so any build you or a packager
runs produces a binary with an empty default.

You can tell which you have at a glance: open **Settings → TMDB Integration**.
Under the API Key field, Opal shows either

- *"Using Opal's built-in key — paste your own to override."* → you have a key, nothing to do, or
- *"Free key from themoviedb.org/settings/api"* → the field is empty and you need one.

## Getting a token

1. Create a free account at [themoviedb.org](https://www.themoviedb.org/signup).
2. Go to **Settings → API** (<https://www.themoviedb.org/settings/api>) and
   request a key. Personal/non-commercial use is approved automatically.
3. Copy the **API Read Access Token** — the long one under the *API Read Access
   Token (v4 auth)* heading. It starts with `eyJ`.

**Either credential on that page works.** Opal picks the authentication mode from
the shape of what you paste: a v4 token (starts with `eyJ`) is sent as
`Authorization: Bearer`, while the shorter 32-character *API Key (v3 auth)* is
sent as an `?api_key=` query parameter. Pasting one in the other's slot is a
`401`, which is why Opal detects it rather than asking you.

The v4 token is still the one to prefer — it is what TMDB steers new
integrations toward, and it is what the in-app hint points at.

## Setting it

Three ways. **The Settings field is the one to use** unless you have a reason not
to — it persists, survives updates, and needs no shell.

### 1. Settings (recommended)

**Settings → TMDB Integration → API Key**, paste, done. It applies immediately
and is saved to `config.tsv` in your config directory (see paths below).

### 2. Environment variable

Useful for servers, containers, and shell-launched runs.

```sh
export OPAL_TMDB_TOKEN='eyJhbGciOi…'
opal
```

`TMDB_API_TOKEN` works as an alias. On Windows, set it via
`System Properties → Environment Variables`, or per-session in PowerShell:

```powershell
$env:OPAL_TMDB_TOKEN = 'eyJhbGciOi…'
```

### 3. `.env` file

Opal reads `.env` from the current working directory first, then from its config
directory. Handy when you do not want the token in your shell history.

```sh
# ~/.config/opal/.env
TMDB_API_TOKEN=eyJhbGciOi…
```

Config directory by platform:

| Platform | Path |
|---|---|
| Linux / BSD | `$XDG_CONFIG_HOME/opal`, or `~/.config/opal` |
| macOS | `~/.config/opal` |
| Windows | `%APPDATA%\opal` |

## Which one wins

Resolved at startup, highest priority first:

1. **A key saved in Settings** (`tmdb_api_key` in `config.tsv`)
2. `$OPAL_TMDB_TOKEN` / `$TMDB_API_TOKEN` environment variable
3. `.env` — working directory, then the config directory
4. The key compiled in at build time, if any

The Settings key sitting above the environment variable is deliberate but easy
to trip over: **if you once pasted a key into Settings, exporting a different one
in your shell will not take effect.** Clear the Settings field first.

An *empty* saved key is ignored rather than treated as an override, so a fresh
install with `$OPAL_TMDB_TOKEN` set behaves the way you would expect. The
compiled-in key is never written to `config.tsv` — only a key you actually
entered is persisted.

## Building your own key in

If you build Opal yourself and would rather not paste a token on every fresh
machine, `build.zig` reads the same variable at build time and compiles it in:

```sh
OPAL_TMDB_TOKEN='eyJhbGciOi…' zig build -Doptimize=ReleaseSafe
```

For the AUR `opal` package, pass it through `makepkg`:

```sh
OPAL_TMDB_TOKEN='eyJhbGciOi…' makepkg -si
```

A repo-root `.env` is also picked up by the build. Note that a token compiled
into a binary is recoverable by anyone with the binary — fine for your own
machines, not something to redistribute.

## Troubleshooting

**Browse and trending are empty.** Check **Settings → Logs** for responses from
`api.themoviedb.org`. A `401` means the credential itself was rejected — most
often a partial copy/paste (a truncated JWT, or a leading/trailing space), since
Opal already routes v3 and v4 keys to their correct auth mechanism.

**The token is set but nothing changed.** A key saved in Settings outranks the
environment (see precedence above). Clear the Settings field, or paste the new
token there instead.

**Posters missing but titles load.** That is `image.tmdb.org`, not the API —
usually a network or DNS block rather than a token problem.

**Verify the credential independently.** Use the form that matches what you have —
these mirror exactly what Opal sends.

```sh
# v4 read access token (starts with eyJ)
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $OPAL_TMDB_TOKEN" \
  'https://api.themoviedb.org/3/movie/550'

# v3 API key (32-char hex)
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://api.themoviedb.org/3/movie/550?api_key=$OPAL_TMDB_TOKEN"
```

`200` means the credential is good and the problem is in how Opal is reading it —
re-check the precedence list above. `401` means the credential itself is wrong.

## Privacy

Requests go directly from your machine to TMDB — nothing proxies through us. See
[PRIVACY-POLICY.md](PRIVACY-POLICY.md) for what each integration sends.

## Attribution

> This product uses the TMDB API but is not endorsed or certified by TMDB.

TMDB [requires](https://www.themoviedb.org/about/logos-attribution) that every
application using their data or images attribute them as the source. Opal shows
their wordmark and the line above in-app under **Settings → TMDB Integration**,
and repeats it in [NOTICE.md](NOTICE.md).

Your use of TMDB data is also subject to their
[terms of use](https://www.themoviedb.org/api-terms-of-use).
