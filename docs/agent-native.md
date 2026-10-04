# Agent-native Opal

Goal: make Opal a media operating system that coding agents can operate and extend. The app is the growing, dynamic, robust framework. Agents supply the conversation and the judgment.

Opal does the acting; the agent decides. Every operation the app can perform is declared once, typed, permissioned and logged, and every surface (UI, web, MCP, in-app copilot) calls the same operation.

## What exists today

Verified by survey of the tree; these are the foundations to build on, not replace.

| Area | State | Where |
| --- | --- | --- |
| HTTP control API | Hand-rolled server on `:41595`, bearer token (`~/.config/opal/api.token`, 0600), principals `.machine` / `.admin_session` / `.session`, SSE `/events`, rate limits | `src/services/remote.zig`, `remote_http.zig`, `access_pure.zig` |
| Per-vertical handlers | catalog, anime, collections, custom sources, library, music, novels, plex, plugins, suwayomi, sync, transfer, youtube | `src/services/remote_*_api.zig` |
| In-app copilot | Local `llama-server` (Gemma) or any OpenAI-compatible cloud; JSON `tool_call` dispatch with ~16 hardcoded tools | `src/services/ai_*.zig` |
| Headless mode | `-Dheadless` build, `OPAL_HEADLESS=1`, runs the core and the API without a window | `src/headless.zig`, `docs/headless-server-spec.md` |
| Child processes | Bounded run and streaming, no pty | `src/core/bounded_process.zig` |
| Browser extension | Closest existing external API client | `extension/` |

Gaps:

- Tool schemas are inline JSON strings with fixed 64/512/2048-byte buffers (`ai_context.zig`, `ai_tools.zig`). There is no registry.
- The HTTP API has no route table or schema, and it is inconsistent: some routes sit outside `/api/`, some return HTML-oriented output.
- Permissions exist only per principal, not per operation.
- No MCP, no JSON-RPC, no terminal embed, no pty.

The safety principle already written in `docs/next-level-research.md` stays binding: never expose raw mpv commands, arbitrary shell options, provider secrets or unrestricted host paths.

## Architecture

```
            coding agents (Claude Code, Codex, Gemini CLI, ...)
                 |  MCP (stdio / streamable HTTP)         ^ hosted in
                 v                                        | embedded terminal
        +-------------------+                    +------------------+
        |  opal-mcp bridge  |                    | libghostty panel |
        +---------+---------+                    +--------+---------+
                  | loopback, bearer token                 |
                  v                                        |
        +------------------------------------------------------+
        |              Operation registry (core)               |
        |  name, input/output schema, tier, handler, audit tag |
        +--+------------+-------------+-------------+----------+
           |            |             |             |
         UI/dvui   HTTP/web API   in-app copilot   extensions
```

### 1. Operation registry (foundation)

A single comptime table in `src/services/ops/`: each entry has a stable name (`media.search`, `player.pause`, `downloads.add`), input and output JSON schemas, a permission tier, and a handler. Everything else is generated from it:

- the MCP `tools/list` and `tools/call`
- the copilot tool prompt (replaces the inline strings in `ai_context.zig`)
- an OpenAPI document for the HTTP API
- the per-operation audit log

Existing `remote_*_api.zig` handlers are wrapped, not rewritten. Move them behind the registry one vertical at a time, starting with search, playback, queue and library.

### 2. MCP server

Shipped as `opal-mcp`, a separate std-only binary: a stdio MCP server that talks to a running Opal over the loopback API with the machine token. It is separate from `opal` so it starts instantly, links no GUI, libmpv or libtorrent, and can never become a second player. Streamable HTTP is a later transport. Because it is generated from the registry, new app features become agent tools with no extra work.

Expose three MCP primitives:

- **Tools**: registry operations, for example `search`, `play`, `queue_add`, `download_add`, `library_list`, `sources_add`.
- **Resources**: read-only state agents can subscribe to: now playing, queue, downloads, library, logs. Fed by the existing SSE `/events`.
- **Prompts / skills**: packaged workflows ("find and queue the next episode", "clean up stale downloads", "audit my sources"), shipped as `skills/*/SKILL.md` that call the tools.

### 3. Permission tiers and audit

Per operation, not per principal:

| Tier | Examples | Default |
| --- | --- | --- |
| `read` | search, status, library list, logs (redacted) | allowed |
| `playback` | play, pause, seek, queue edits | allowed |
| `write` | add source, edit collections, change settings | confirm once per session |
| `spend` | start downloads, bulk fetch | confirm, with a per-session budget |
| `destructive` | delete files, clear library, remove sources | always confirm in the UI |

Confirmation appears as a dvui prompt in the app (or a pending action in headless mode, approved through the web UI). Every call is appended to an audit log: time, principal, agent name, operation, arguments (secrets redacted), outcome. Agents can never read provider secrets or raw filesystem paths; paths are handles resolved by the app.

### 4. Embedded agent terminal (libghostty)

A terminal panel inside Opal that hosts coding agents with Opal's MCP server preconfigured.

- Use libghostty (the embeddable terminal core from Ghostty) for VT parsing and screen state, and render the cell grid in a dvui custom widget. The `ghostling` reference project is the model for a minimal host. Confirm the library's current API and Zig 0.16 build compatibility before committing to a version; spike this first.
- Add a pty layer next to `bounded_process.zig` (`openpty`/`forkpty` on Linux and macOS; ConPTY on Windows later). `StreamProcess` stays for non-interactive work.
- An "Agents" launcher detects installed CLIs (`claude`, `codex`, `gemini`, others), starts the chosen one in a pty with `OPAL_MCP` env and an MCP config pointing at `opal mcp`, and keeps one terminal tab per agent session.
- The panel is optional. The MCP server must work with agents the user launches in their own terminal.

### 5. Agents extending the app

The "growing, dynamic" half. Agents add capability without a rebuild, inside a sandbox:

- Sources and catalogs through the existing Lua plugin system (`plugins.zig`, `plugin_repo.zig`) and the custom-source API. Tools: `plugins.scaffold`, `plugins.test`, `plugins.install`.
- Skills as files in the config dir (`~/.config/opal/skills/`), hot-reloaded and surfaced to MCP prompts.
- New operations declared by plugins register into the registry at `write` tier or above and show their origin in the audit log.
- Agents that want to change the app's own code work through normal git branches and PRs, not through a runtime hook.

### 6. Making operations intelligent

Once operations are typed tools, the intelligent behavior is composition, which the agent does and the app only needs to support:

- Search that understands intent (the registry returns ranked results with explanations; the agent refines).
- Library curation, de-duplication, subtitle fixing, source health checks, and download policy as skills.
- Watch and release monitoring ("tell me when the next episode appears, download it in 1080p") as scheduled agent tasks through the headless daemon.

The in-app copilot becomes one more registry client, so it gains every new operation for free.

## Status

Branch `v2/agent-os` is stacked on PR #119 (browse, episode redesign, remote hardening), which sits on `main`.

| Phase | State |
| --- | --- |
| 1. Registry | Done for the observe, playback, download, queue, library and wanted surface: more than 70 tools with typed parameters, tiers and API bindings (`src/services/ops_pure.zig`). OpenAPI is generated from it (`docs/openapi.json`, `opal-mcp --openapi`) and checked for drift in `zig build test-ops`. The in-app copilot keeps its own compact tool list on purpose: a small local model cannot carry 70-plus schemas. |
| 2. MCP server | Done: `opal-mcp` (stdio), tools and resources, policy ceiling, destructive confirm, URL guard, JSON audit log, shipped in every package. Verified live. See [mcp.md](mcp.md). |
| 3. Skills | `skills/opal-media` (watch, control, downloads, wanted list), installed into the agent workspace. |
| 4. Terminal | libghostty-vt today exposes only key, OSC, SGR and paste APIs, not a screen-state terminal, so an embedded terminal is deferred. Shipped instead: **Settings → Agent Access** launches Claude Code, Codex or Gemini CLI in the user's own terminal inside a pre-wired workspace (Linux). |
| 5. Extension loop | Not started. |
| 6. Autonomy | Wanted list engine done (below). Scheduled agent tasks done (below). |

### Scheduled agent tasks

`src/services/agent_tasks.zig` plus `agent_tasks_pure.zig` (limits, schedule, headless argv). Saved prompts run `claude -p` (only the `opal` tools allowed, `--max-budget-usd` cap) or `codex exec` (read-only sandbox) on a timer, one at a time, inside the agent workspace. Opt-in through a master switch only the user can flip; a daily run cap counted at run start, a ten minute timeout and a host-admin-only API bound the cost. The prompt travels as one argv element via `sh -c 'exec "$@" 2>&1'`, never through shell parsing. Exposed as `/api/agent/tasks/*` and `agent_task*` tools. Gemini CLI is not schedulable yet: its unattended MCP approval has not been verified.

### Wanted list (the CouchPotato core)

`src/services/wanted.zig` plus `wanted_pure.zig` (scoring, backoff). Add a movie or episode once; Opal searches on a private channel that never disturbs on-screen results, filters cams, screeners, fan edits and trailers, scores by quality, seeders and size, starts the best torrent on the owner thread, retries with backoff (30 min doubling to a day) and marks the item fulfilled when the download completes. "Follow tracked shows" queues the newest aired episode of each tracked show. Verified live against EZTV. Exposed as `/api/wanted/*` and `wanted_*` tools, and as a Wanted section at the top of the Downloads page (add by typing `Dune 2021` or `Severance S02E03`; find, pause, resume, remove).

Next up: scheduled agent tasks, plugin scaffolding tools, OpenAPI from the registry, and an embedded terminal once libghostty exposes a terminal API.

## Phases

1. **Registry and schemas.** Define the registry, port search, playback, queue, library, downloads and status. Generate the copilot tool list from it. Keep the HTTP routes working. Tests for schema validation and tier enforcement.
2. **MCP server.** `opal-mcp` over stdio, tools and resources, audit log, tier confirmation. Docs and a Claude Code / Codex config snippet. Site page.
3. **Skills.** A first set of `SKILL.md` workflows shipped in the repo and installable from the app.
4. **Terminal spike, then panel.** Prove libghostty builds and renders in dvui; then pty plumbing, the Agents launcher, one-click MCP wiring.
5. **Extension loop.** Plugin scaffold/test/install tools and hot-reloaded skills.
6. **Autonomy.** Scheduled agent tasks through the headless daemon, with budgets.

Each phase is independently shippable; phase 2 is the first user-visible milestone.

## Open decisions

- **Transport default.** stdio bridge (simple, works with every agent) versus built-in streamable HTTP on the existing server. Proposed: stdio first.
- **Bridge packaging.** Decided: a separate `opal-mcp` binary built by the same `zig build`. Packages (AUR, AppImage, Homebrew, Windows zip) must ship it next to `opal`.
- **Enabling the API.** Web Remote is off by default in the windowed app, so agents get "not reachable" until the user turns it on. Proposed: an "Agent access" switch in Settings that starts the loopback API and writes the token, with the audit log beside it.
- **Confirmation UX in headless mode.** Web UI approval queue versus fail closed. Proposed: approval queue, fail closed when nobody is attached.
- **Windows terminal support** (ConPTY) in phase 4 or deferred.
