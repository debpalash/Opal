# Opal for coding agents (MCP)

`opal-mcp` is a Model Context Protocol server that lets Claude Code, Codex, Gemini CLI or any MCP client operate a running Opal: search every source, play, queue, control playback, manage downloads. It speaks newline-delimited JSON-RPC over stdio and forwards to Opal's local HTTP API.

## Set up

1. Turn on **Web Remote** in Opal (Settings) and set the bind mode to **loopback** so the API is not exposed to your network. Opal creates `~/.config/opal/api.token` the first time it runs. Headless servers: `OPAL_HEADLESS=1 opal`.
2. Build or install: `zig build` produces `zig-out/bin/opal-mcp` next to `opal`.
3. Register it with your agent.

Claude Code:

```sh
claude mcp add opal -- opal-mcp
```

Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.opal]
command = "opal-mcp"
```

Any other client, as JSON:

```json
{ "mcpServers": { "opal": { "command": "opal-mcp" } } }
```

Then ask the agent: "find Big Buck Bunny and play it", "what's in my queue?", "pause", "download this magnet link".

## Launch an agent from Opal (Linux)

**Settings → Agent Access** has *Launch Claude Code / Codex / Gemini CLI* buttons. Each opens your own terminal (ghostty, kitty, alacritty, wezterm, foot, gnome-terminal, konsole, xfce4-terminal or xterm, first found) in `~/.config/opal/agent-workspace`, running the agent with Opal already connected. Opal rewrites these files in the workspace on every launch: `CLAUDE.md` / `AGENTS.md` / `GEMINI.md` (instructions), `.mcp.json` and `.gemini/settings.json` (the `opal-mcp` wiring), and `.claude/skills/opal-media/SKILL.md`. Codex gets the server through a `-c mcp_servers.opal.command=...` override. Agents that are not on your `PATH` report that instead of failing silently.

## Permissions

Every tool has a tier. The server refuses anything above the ceiling you give it.

| Tier | Meaning | Examples |
| --- | --- | --- |
| `read` | observe, search | `status`, `search`, `search_results`, `queue_list`, `downloads_list`, `history_list`, `recommendations`, `library_list`, `library_watched`, `calendar_list`, `tmdb_browse`, `tmdb_search`, `tmdb_results`, `anime_search`, `anime_results`, `anime_episodes`, `podcast_search`, `podcast_results`, `podcast_episodes`, `music_search`, `music_results`, `youtube_search`, `youtube_results`, `rss_list`, `livetv_list`, `collections_list`, `settings_list`, `wanted_list`, `agent_tasks_list`, `home_summary`, `player_info`, `cast_scan`, `cast_devices`, `torrents_list`, `torrent_files`, `download_history_list`, `jellyfin_results`, `jellyfin_libraries`, `jellyfin_browse`, `jellyfin_search`, `browser_status`, `browser_page`, `browser_media_candidates`, `browser_tabs` |
| `playback` | control what plays now | `search_play`, `search_queue`, `player_toggle`, `player_seek`, `player_speed`, `player_volume`, `player_next`, `anime_play`, `podcast_play`, `music_play`, `player_previous`, `subtitles_search`, `subtitles_download`, `queue_action`, `player_audio_track`, `player_subtitle_track`, `subtitles_delay`, `cast_start`, `cast_stop`, `jellyfin_play` |
| `write` | change persistent state | `subtitles_generate`, `downloads_pause`, `downloads_resume`, `settings_set`, `library_set_status`, `library_mark_watched`, `library_refresh`, `rss_refresh`, `library_favorite`, `library_rate`, `collection_save_queue`, `wanted_pause`, `wanted_resume`, `wanted_remove`, `agent_task_remove`, `torrent_pause`, `torrent_resume`, `rss_add` |
| `spend` | use bandwidth, disk or compute | `play_url`, `downloads_add_url` (a magnet starts a torrent), `wanted_add` and `wanted_follow` (start automatic downloads), `wanted_check` (searches now and may start a download), `agent_task_add`, `agent_task_run` (paid agent runs), `browser_play_candidate` (streams a video the user's browser found), `browser_fetch` (loads a page through the user's own browser, with their cookies) |
| `destructive` | remove data | `queue_clear`, `downloads_cancel`, `library_remove`, `collection_remove`, `torrent_cancel`, `rss_remove`, `download_history_remove`, `download_history_clear` |

The default ceiling is `spend`. Destructive tools are off until you opt in, and even then each call must carry `confirm: true`.

```sh
opal-mcp --read-only              # observe and search only
opal-mcp --allow playback         # control playback, no downloads
opal-mcp --allow destructive      # everything; destructive calls still need confirm=true
opal-mcp --deny-prefix agent_task # hide and refuse every tool whose name starts with agent_task
```

`--deny-prefix NAME` removes matching tools from `tools/list` and refuses calls to them with a clear message, whatever the tier ceiling. Scheduled agent runs start `opal-mcp` with `--deny-prefix agent_task`, so an unattended agent can never create, run or remove scheduled tasks.

Discovery tools (`tmdb_*`, `anime_*`, `podcast_*`, `music_*`, `youtube_*`, `jellyfin_*`, and `cast_scan` / `cast_devices`) work in two steps because the sources answer in the background: start a search or browse, then read the matching `*_results` tool a moment later. They drive the same screens the app shows, so a search an agent starts also appears in the app. Search endpoints share a request budget; a "too many requests" reply carries a `retry_after` in seconds.

Arguments are typed and bounded. Unknown arguments are rejected, `play_url` and `downloads_add_url` accept only `http(s)` URLs and magnet links (never local paths), and no tool exposes raw player commands, shell options, provider secrets or file paths.

## Players, casting, torrents and media servers

- **Player.** `player_info` is the full snapshot (tracks with ids, chapters, subtitle delay, subtitle search results). `player_audio_track` and `player_subtitle_track` take an id from it or `off`; `subtitles_delay` shifts subtitles by up to 30 seconds either way.
- **Cast.** `cast_scan`, then `cast_devices`, then `cast_start` with a device position casts what is playing to a Chromecast (the `catt` tool must be installed); `cast_stop` ends it.
- **Torrents.** `downloads_list` covers direct downloads; `torrents_list` and `torrent_files` show live torrent sessions. `torrent_pause` and `torrent_resume` are `write`; `torrent_cancel` removes the torrent and hides what it downloaded, so it is `destructive`. `download_history_*` manage the list of past downloads (never the files).
- **Jellyfin.** The user signs in once in the app; there is no tool for logging in or out. `jellyfin_libraries`, `jellyfin_browse` and `jellyfin_search` start loading; read `jellyfin_results` a moment later for items and ids, then `jellyfin_play`. Item ids must be plain ids (letters, digits, dashes). Plex, Audiobookshelf and OPDS have no tools yet.
- **RSS.** `rss_add` takes an http(s) feed URL (at most 8 feeds), `rss_remove` deletes one. Note that `rss_list` returns the feed URLs as saved, so do not put credentials in a feed URL if an agent will read it.
- **Home.** `home_summary` is the quick answer to "what should I watch": counts plus up to 12 titles with their next episode.

`history_list` returns recent search queries plus shuffle and repeat state, not watch history; watch progress is in `library_list` and `status`.

## Plugins

`plugins_list` shows catalogue sources and installed executable plugins; `plugin_install`, `plugin_update` and `plugins_refresh` manage source plugins (endpoint config only; the app holds the connector code). To extend Opal, an agent calls `plugin_scaffold`, which creates `<config>/plugins/<id>/` with a `manifest.json` and a Lua `search` script, edits that script with its own file tools, then asks you to review and approve it in Settings → Plugins. Nothing executes before that: approval is stored outside the plugin folder against a digest of its exact bytes, no tool can grant it, and any edit revokes it. After approval `plugin_test` dry-runs the search through the production path (Lua sandbox, eight second limit, strict JSON) and returns the outcome and rows, so the agent can iterate. `plugin_uninstall` is destructive.

## Browser

With the Opal Connect extension paired (Settings → Agent Access → Browser), the user can share the page they are on and let an agent help with it. Six tools, all under the `browser` prefix, so `--deny-prefix browser` removes the whole family.

| Tool | Tier | What it returns |
| --- | --- | --- |
| `browser_status` | `read` | Paired browsers with `connected` (seen in the last 150 seconds), whether a page is shared, whether it was shared with agents, and the state of the Agent Access switch. Never page content. |
| `browser_page` | `read` | The shared page: title, address without its query string, Open Graph fields, JSON-LD, up to 8 KB of text, `page_id`. Everything under `untrusted_page` was copied from a web page and the response says so; the text sits between `BEGIN UNTRUSTED PAGE TEXT` and `END UNTRUSTED PAGE TEXT` markers, and a copy of the marker inside the text is defused. |
| `browser_media_candidates` | `read` | Streams the browser found on the page: `id`, `kind`, `host`, `path` and `duration` only (no query string, no Referer, no User-Agent), plus the `page_id`. |
| `browser_play_candidate` | `spend` | Plays or queues one candidate by `page_id` and `id`. Never by URL. Opal sends the Referer, Origin and User-Agent the browser used. A queued item keeps those headers and plays with them later. |
| `browser_tabs` | `read` | Titles and sites of the tabs open in a paired browser: `title`, `host`, `path`, `audible`, `active`, never a full address (no query string, no fragment). Empty unless two consents exist (below). Everything under `untrusted_tabs` is text from web pages. |
| `browser_fetch` | `spend` | Loads one http(s) page through the user's own browser and returns its text: their real cookies and bot clearance, 2 MB at most, text, JSON and HTML only (binary is refused with `415`). Takes only `url`. Works only for a site the user allowed in Opal Connect; a new site asks them in the extension's side panel and can wait up to 90 seconds. Declined, unanswered or not allowed: `403 {"error":"origin not allowed"}`. No browser connected: `503`. Addresses on the user's own network (loopback, LAN, `.local`) are refused unless the user named them. The page comes back inside `untrusted_page`, wrapped between `BEGIN UNTRUSTED PAGE TEXT` and `END UNTRUSTED PAGE TEXT`, with the final address shown without its query string. |

Two consents, both the user's, neither reachable by an agent. The extension's **Share this page with Opal** button is per page, user initiated, and its "Also let coding agents read this page" box starts unticked. **Settings → Agent Access → Let agents read shared pages** is a second, global switch, off by default; only that screen changes it (no route and no tool, and it is not in `settings_set`). When either is missing, `browser_page`, `browser_media_candidates` and `browser_play_candidate` answer as if nothing were shared ("Nothing is shared with agents" with a hint, or `403` for play), without revealing whether a page exists.

`browser_tabs` has its own pair of consents. **Settings → Agent Access → Share tab list with agents** is off by default and only that screen changes it (no route, no tool, not in `settings_set`); in Opal Connect, the user must also press *Allow tab titles* in the side panel, which asks the browser for the optional `tabs` permission at that moment. With either missing the tool answers `sharing: false` and an empty list, and Opal refuses and discards any list the browser posts while its switch is off. Private (incognito) windows are never reported, addresses are cut to host and path in the browser and again in Opal, a title that is the page's own address loses its query string, the list lives in memory only and is dropped after 150 seconds of silence.

`browser_fetch` is gated by the tier (it is `spend`) and, separately, by the extension's allow list: a per-site list only the user edits (options page and side panel; Opal and agents cannot add to it), an entry unused for 30 days drops off, and the decision is per exact origin (`https://example.org` and `https://www.example.org` are two sites). The request goes out with `credentials: "include"`, follows redirects, and the page is returned only if the final site is also allowed. The tool reads: no method, header, cookie or body argument exists, so an agent cannot post through the user's logged in session. The route behind it is `POST /api/browser/fetch?url=`, available to the machine token and web admins only.

Opal keeps only the last shared page, in memory, never on disk; quitting Opal or pressing Dismiss in the Browser hub forgets it. A new share replaces it and changes `page_id`, so an id read from an earlier page fails with `409`. The routes behind the tools are `GET /api/browser/context?view=status|page|candidates` and `POST /api/browser/play?page=&id=&action=play|queue`, available to the machine token and web admins only; a paired browser's own token cannot call them (it holds a short allowlist: status, its own check, media, page share, tab list, the two job routes, unpair itself).

There is no tool for pairing, revoking, switching sharing on, reading or importing cookies, controlling tabs (`browser_tabs` only lists them) or running scripts, and there will not be. Page text is untrusted: it may contain instructions aimed at an agent, so an agent acts on what the user asked for, not on what the page says. The audit log records tool names and outcomes, never page text or URLs.

## Ask Opal

The in-app assistant that is powered by your coding agent (Settings > Agent Access > Ask Opal) starts `opal-mcp --preset ask --allow write` with `--deny-prefix` for `agent_task`, `operator`, `plugin`, `browser`, `settings`, `rss_add`, `wanted_remove`, `subtitles_generate` and every spend or destructive tool, and the agent never performs a spend action itself: it proposes `wanted_add` and downloads as buttons the user clicks. `--deny-prefix` may be repeated. See [agent-native.md](agent-native.md#ask-opal-the-assistant-is-your-coding-agent).

## OpenAPI

[`docs/openapi.json`](openapi.json) describes the same operations as an OpenAPI 3.1 document, generated from the registry so the spec, the MCP tools and the docs cannot drift (`opal-mcp --openapi` prints it and needs no running Opal). Several operations share one route and differ in a fixed `action=` value, so those paths carry it in the key (`/library/action?action=status`); see the header of `src/services/openapi_pure.zig`. After changing the registry, run `opal-mcp --openapi > docs/openapi.json`; `zig build test-ops` fails while the committed file is stale.

## Scheduled agent tasks

A task is a prompt a coding agent runs unattended on a timer: `agent_task_add` takes a `name`, a `prompt`, an `agent` (`claude` or `codex`), `interval_min` (15 to 10080), `max_runs_per_day` (1 to 24) and, for Claude Code, `budget_cents` per run (passed as `--max-budget-usd`). Each run starts in the same workspace as the terminal launcher, with the same `opal-mcp` and the same policy, so it can do no more than a chat could. Claude Code runs with only the `opal` tools allowed; Codex runs in a read-only sandbox. A run is stopped after ten minutes, and the last line of its output is kept as `last_summary`.

Running an agent spends your own subscription or API credit, so nothing runs until you switch on **Settings → Agent Access → Run scheduled agent tasks**. Agents cannot flip that switch, and there is no tool to pause or resume a task: only you do that, in the UI (there is no HTTP route for it, so nobody holding the token can enable what an agent added). The task routes are host-admin only for web-remote user accounts. A run counts against the daily cap when it starts, so a failing agent cannot retry in a loop. `agent_task_run` runs a task now and counts toward the same cap.

## Wanted list

Tell Opal what you want and it fetches it. `wanted_add` takes a movie (`title`, optional `year`) or an episode (`title`, `season`, `episode`) plus optional quality bounds, minimum seeds and a size cap. Opal then searches in the background, scores the candidates, starts the best torrent and marks the item fulfilled when it finishes. Failed searches retry with backoff (30 minutes, doubling to a day). `wanted_list` shows status, attempts and what was picked; `wanted_check` forces a search now. `wanted_follow` (also **Settings → Agent Access → Follow tracked shows**) queues the newest aired episode of every show you track, never the back catalogue, skipping anything you have already watched. Searches run on a private channel, so they never disturb the results on screen.

## Audit log

Each call appends one JSON line to `~/.config/opal/mcp-audit.jsonl`: time, tool, tier, outcome (`ok`, `api_error`, `unreachable_`, `rejected`, `blocked`) and the arguments. URL query strings and fragments are dropped because they can carry credentials. Disable with `OPAL_MCP_AUDIT=0`.

## Resources

Read-only snapshots clients can attach as context: `opal://status`, `opal://queue`, `opal://downloads`, `opal://history`, `opal://library`, `opal://wanted`, `opal://agent-tasks`.

## Configuration

| Setting | Purpose |
| --- | --- |
| `OPAL_API_TOKEN` | Token to use instead of reading the token file |
| `OPAL_API_TOKEN_FILE` | Read the token from this file |
| `OPAL_PORT` / `--port` | API port (default 41595) |
| `OPAL_MCP_AUDIT=0` | Turn the audit log off |

## How it works

The tool list is generated from one table, `ops` in `src/services/ops_pure.zig`. Each entry names the tool, its typed parameters, its tier and the Opal API route it calls, and the schemas, validation, policy and audit all derive from it. Adding a tool is adding one entry. The protocol core is pure Zig with an injected transport, so it is unit tested without a running Opal: `zig build test-ops`.

See [agent-native.md](agent-native.md) for where this is going.
