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
| `read` | observe, search | `status`, `search`, `search_results`, `queue_list`, `downloads_list`, `history_list`, `recommendations`, `library_list`, `calendar_list`, `collections_list`, `settings_list`, `wanted_list` |
| `playback` | control what plays now | `search_play`, `search_queue`, `player_toggle`, `player_seek`, `player_speed`, `player_volume`, `player_next`, `player_previous`, `subtitles_search`, `subtitles_download`, `queue_action` |
| `write` | change persistent state | `subtitles_generate`, `downloads_pause`, `downloads_resume`, `settings_set`, `wanted_add`, `wanted_follow`, `wanted_pause`, `wanted_resume`, `wanted_remove` |
| `spend` | use bandwidth, disk or compute | `play_url`, `downloads_add_url` (a magnet starts a torrent), `wanted_check` (searches now and may start a download) |
| `destructive` | remove data | `queue_clear`, `downloads_cancel` |

The default ceiling is `spend`. Destructive tools are off until you opt in, and even then each call must carry `confirm: true`.

```sh
opal-mcp --read-only              # observe and search only
opal-mcp --allow playback         # control playback, no downloads
opal-mcp --allow destructive      # everything; destructive calls still need confirm=true
```

Arguments are typed and bounded. Unknown arguments are rejected, `play_url` and `downloads_add_url` accept only `http(s)` URLs and magnet links (never local paths), and no tool exposes raw player commands, shell options, provider secrets or file paths.

## Wanted list

Tell Opal what you want and it fetches it. `wanted_add` takes a movie (`title`, optional `year`) or an episode (`title`, `season`, `episode`) plus optional quality bounds, minimum seeds and a size cap. Opal then searches in the background, scores the candidates, starts the best torrent and marks the item fulfilled when it finishes. Failed searches retry with backoff (30 minutes, doubling to a day). `wanted_list` shows status, attempts and what was picked; `wanted_check` forces a search now. `wanted_follow` (also **Settings → Agent Access → Follow tracked shows**) queues the newest aired episode of every show you track, never the back catalogue, skipping anything you have already watched. Searches run on a private channel, so they never disturb the results on screen.

## Audit log

Each call appends one JSON line to `~/.config/opal/mcp-audit.jsonl`: time, tool, tier, outcome (`ok`, `api_error`, `unreachable_`, `rejected`, `blocked`) and the arguments. URL query strings and fragments are dropped because they can carry credentials. Disable with `OPAL_MCP_AUDIT=0`.

## Resources

Read-only snapshots clients can attach as context: `opal://status`, `opal://queue`, `opal://downloads`, `opal://history`, `opal://wanted`.

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
