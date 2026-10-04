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
- An "Agents" launcher detects installed CLIs (`claude`, `codex`, `gemini`, others), starts the chosen one in a pty with `OPAL_MCP` env and an MCP config pointing at `opal mcp`, and keeps one terminal tab per agent session. The page also has a **Tasks** tab (scheduled prompts) and an **Activity** tab for the background operator: its switch and daily limit, the proposals waiting for your OK (marked with a count on the tab), and the recent jobs with their outcome and cost.
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
| 1. Registry | Done for the observe, playback, download, queue, library and wanted surface: more than 100 tools with typed parameters, tiers and API bindings (`src/services/ops_pure.zig`). OpenAPI is generated from it (`docs/openapi.json`, `opal-mcp --openapi`) and checked for drift in `zig build test-ops`. The in-app copilot keeps its own compact tool list on purpose: a small local model cannot carry 100-plus schemas. |
| 2. MCP server | Done: `opal-mcp` (stdio), tools and resources, policy ceiling, destructive confirm, URL guard, JSON audit log, shipped in every package. Verified live. See [mcp.md](mcp.md). |
| 3. Skills | `skills/opal-media` (watch, control, downloads, wanted list), installed into the agent workspace. |
| 4. Terminal | Done on Linux/macOS: the **Agents** page runs Claude Code, Codex, Gemini CLI or a shell on a pty inside Opal, parsed by libghostty-vt and drawn with dvui (below). **Settings → Agent Access** still launches them in the user's own terminal. Windows (ConPTY) is not wired up. |
| 5. Extension loop | Not started. |
| 6. Autonomy | Wanted list engine done (below). Scheduled agent tasks done (below). |

### Background operator

**Local file names (`local_names`).** After a library scan completes, if the operator is on (and the session is not incognito), Opal picks up to 20 files whose automatically cleaned title still looks like a release name (quality, codec or source tags, a trailing `-GROUP`, `SxxExx`, bracketed tags, numeric-only) and that have no display title yet. It sends the agent only the file's base name (`index<TAB>filename`, never a folder) and asks for a human title and a kind (movie, tv, music, audiobook, other). The answer is validated twice (the CLI schema, then `parseLocalNames`: indexes inside the batch and unique, 1 to 120 characters, no control characters, path separators or angle brackets, at least one letter) and applied through `local_library.correct` only to rows whose display title is still empty and whose title has not changed since they were asked about. One request per scan, 8 cent cap, 6 hour cooldown. Files already asked about are remembered in `operator_names_batch` (which also holds the index to row mapping) and asked again only after 14 days. The pure rules and tests are in `src/services/operator_names_pure.zig`; the database side is `operator_local_names.zig`.

### Embedded terminal

libghostty-vt on ghostty `main` now exposes a terminal and render-state C API (the 0.1.0 package we first tried did not), and `main` requires the Zig version Opal already uses, so Opal depends on a pinned ghostty commit (`build.zig.zon`) and links its static `ghostty-vt-static` (ReleaseFast, SIMD off). `src/terminal/pty.zig` wraps `forkpty` (the child only calls `execve`; arguments and environment are built before the fork), `session.zig` runs one reader thread that feeds the pty into the terminal under a mutex and flattens the render state into plain cells for the UI, and `keymap.zig` maps dvui keys onto the libghostty key encoder (cursor-key mode, kitty protocol and so on; plain typing is left to the text event so nothing is sent twice). `src/ui/agent_terminal.zig` is the page: it starts the agent in the same workspace as the launcher, draws backgrounds and text runs per row (non-ASCII cell by cell so columns stay put) in the bundled Hack font, and takes over the keyboard while focused (`input.zig` skips Opal's shortcuts then; click outside to get them back). Verified on screen with a real shell: colours, bold, underline, inverse, prompt. Pty, snapshot and key encoding have unit tests (`zig build test-terminal`).

Windows (ConPTY, `pty_windows.zig`) is written but has only been cross-compiled, never run. Program lookup (`agent_launch.onPath`, also used by the operator and scheduled tasks) searches `PATH` for `name.exe`, `.cmd` and `.bat` and never the current directory (`agent_launch_pure.searchPath`, tested with a fake file system). `cmd.exe` and PowerShell are started by full path under `%SystemRoot%\System32` (fallback `C:\Windows\System32` when the variable is missing or unsafe), not by bare name. `writeAll` gives up after about 250 ms without progress like the POSIX pty; this relies on the write end being switched to non-blocking mode, which is unverified on a real machine. Scheduled tasks still start agents through `sh -c`, so on Windows they now find the agent but cannot run it yet.

### Scheduled agent tasks

`src/services/agent_tasks.zig` plus `agent_tasks_pure.zig` (limits, schedule, headless argv). Saved prompts run `claude -p` (only the `opal` tools allowed, `--max-budget-usd` cap) or `codex exec` (read-only sandbox) on a timer, one at a time, inside the agent workspace. Opt-in through a master switch only the user can flip; a daily run cap counted at run start, a ten minute timeout and a host-admin-only API bound the cost. The prompt travels as one argv element via `sh -c 'exec "$@" 2>&1'`, never through shell parsing. Exposed as `/api/agent/tasks/*` and `agent_task*` tools. Gemini CLI is not schedulable yet: its unattended MCP approval has not been verified.

### Wanted list (the CouchPotato core)

`src/services/wanted.zig` plus `wanted_pure.zig` (scoring, backoff). Add a movie or episode once; Opal searches on a private channel that never disturbs on-screen results, filters cams, screeners, fan edits and trailers, scores by quality, seeders and size, starts the best torrent on the owner thread, retries with backoff (30 min doubling to a day) and marks the item fulfilled when the download completes. "Follow tracked shows" queues the newest aired episode of each tracked show. Verified live against EZTV. Exposed as `/api/wanted/*` and `wanted_*` tools, and as a Wanted section at the top of the Downloads page (add by typing `Dune 2021` or `Severance S02E03`; find, pause, resume, remove).

### Background operator

`src/services/operator*.zig`: Opal hands a problem to a headless coding agent that has no Opal tools and only a context text in its prompt, and gets back schema-validated JSON. Off until the user enables it.

**Cost per job.** Measured with the real `claude -p` CLI on a trivial structured call: the default run costs about $0.014 even with `--tools ""` (about 3K cached tokens of Claude Code's own system prompt) and about $0.08 with default tools. Opal therefore always passes its own short `--system-prompt` and `--model` (`haiku` for the structured, no-web kinds, `sonnet` for the web kind `endpoint_repair`), which brings a call to about $0.0026 (1.1K input tokens, no cache creation). `--effort low` made no difference and `--bare` is not used because it disables OAuth/subscription login. Caps per job: match_help 8 cents, local_names 8, endpoint_repair 25; the whole cap is still reserved against the daily limit when the job is queued and replaced by the reported cost when it ends (Codex reports none and is charged the cap). Codex gets no model flag: `-m` exists but the cheap model names depend on the account, so it runs on the user's configured model.

**endpoint_repair** (`operator_endpoint.zig`, logic in `operator_endpoint_pure.zig`). When an installed source keeps failing, the agent (with web search) says where it lives now.
- *Trigger.* `source_request.zig` counts consecutive failures per source. Five failures spanning at least two minutes ask the operator (once per 24 hours per source). Only connection failures, timeouts and real HTTP error statuses count; cancellations, local errors, rate limits (429), 401 and body-validation failures neither count nor reset, and any success resets. Connect-only streaks with no success from any source since they began are treated as the user being offline. Sources not installed are never asked about.
- *Context.* Source id, manifest type, the base address reduced to scheme and host, the last status or failure kind and the streak length. No other configuration field is ever read, so keys, tokens, debrid keys, cookies and user names cannot leave the app.
- *Probe.* The answer must be a bare public http(s) address, confidence 0.5 or more, and different from the current one. Opal then does one GET of it: 8 second timeout, no credentials or cookies, redirects not followed (a 3xx counts only when it does not point at a private host), size bounded, status 200 to 399. Only then is the job `proposed`, with a summary like "bxx.example may have moved to https://new.example (checked: reachable)".
- *Approval.* Never automatic and human-only: the Agents page or `POST /api/operator/approve`. No agent tool can approve. On approval the stored answer is validated again and only the `base` field of the source file is rewritten; every other field (mirrors, sealed credentials) is kept, secrets are protected by `source_config.install`, and the change is live at once. If the source was uninstalled meanwhile the approval fails.
- *Scope.* Sources fetched through `source_request` (anime, comics, audio, webcomic providers) and torrent indexes. Indexes feed the same per-source streak through `source_request.noteIndex` (same thresholds, same 24 hour cooldown, same id as the source file): the Python engines print one `#opal-health` line per source next to their result rows (verdict over all of the source's mirrors: any answer is a success; a source with no fetch outcome, or only a challenge page, reports nothing), and the native EZTV, Torznab family, readallcomics (`core/mirrors.zig`, one report per call, not per mirror) and YTS fetches report directly. Only installed sources with a `base` are counted; cancellations, shutdown, offline connect-only streaks, 429 and unreadable bodies behave as above, and the context is still built by the same secret-free builder. Limits: an engine that hangs past nova2's 6 second deadline reports nothing, a YTS source file without a `base` is not counted (there is nothing to repair), and the EZTV list call in `search.zig` does not report.

**search_help** (`operator_search_help.zig`, rules in `operator_search_help_pure.zig`). When the unified search finishes with no results for words the user typed, the empty state asks the operator once per normalised query (lower case, separators collapsed; cooldown 24 hours, 6 cent cap, small model). Links, magnets, paths, hashes and queries under three characters are never sent. The agent may return up to three other wordings (typo fixes, alternate or original-language titles, transliterations); each must pass the same plain-words validator as match_help (no operators, quotes or control characters, valid UTF-8) and must differ from what was typed, and an empty list is a valid "nothing better" answer. They are stored in `operator_search_help` and shown as "Did you mean" chips above the empty state; one click re-runs the search with that wording through the normal search path. Nothing is ever searched without a click, and a query reached through a chip never asks the operator itself. Cost with the operator off: one boolean check.

**picks** (`operator_picks.zig`, rules in `operator_picks_pure.zig`). The Home row "Picked for you". Needs the operator switch AND a second switch, *Use my watch history for picks* (default off, flipped only in the UI, stored as `operator_picks`), because it sends titles to the agent. Once a day (cooldown 20 hours, key `daily`, 12 cent cap, small model), when Home is open, Opal sends up to 40 lines of `watched:`, `favourite:` or `following:` plus a title: the last watched items (file names go through the file-name cleaner and are dropped if they still look like release names, links and hashes never pass), favourites and tracked shows. No paths, no folders, nothing else; at least three usable lines are needed to ask. The agent returns up to 12 `{title, year, kind, reason <= 100 characters}`. The app trusts none of it: each title is looked up in Cinemeta (`/catalog/{movie|series}/top/search=`, keyless) and kept only when a catalogue row has the same kind, the same title after normalising case and punctuation, and a year within one of the agent's (a catalogue row without a year is refused when the agent gave one); a lookup that could not reach Cinemeta is retried once. Titles the user already has are dropped, a pick needs a reason, and dismissed titles never return. Survivors are stored in `operator_picks` and drawn with the normal catalogue card plus the reason, Details and Dismiss. The newest batch replaces the previous one.

**Cost.** Jobs run `claude -p` with its own short system prompt and the small model (see "Cost per job"); caps are match_help 8 cents, local_names 8, search_help 6, picks 12, endpoint_repair 25. The whole cap is reserved against the daily limit when a job is queued and replaced by the reported cost when it ends; a failed or timed out run keeps the full cap charged because the agent may have spent it.

**What auto-applies, and why.** Only match_help (extra search wording), local_names (display text for the user's own files, never over a title the user set), search_help (chips the user must click) and picks (a rail made only of catalogue-verified titles) apply themselves. Anything that touches an address or a setting (endpoint_repair) waits for a person; `operator_pure.zig` asserts both lists in a test.

**Verified live (isolated profile, fake agents, no real agent or download).** A throwaway directory with shell shims named `claude` and `codex` first on `PATH` for the Opal under test read the exact command lines `buildArgv` produces (the shim exits non-zero if a flag is missing) and answered with the claude JSON envelope or the `-o` file. Seen in the running app:
- match_help: a wanted item with an invented title fired after its third miss (attempts 3); the job applied two alternate titles and dropped a `$(...)` query; the next check searched three titles (the title and both alternates); the cost replaced the reservation (8 cents reserved, 2 charged).
- endpoint_repair: a source whose base pointed at a dead port was not asked about while no source anywhere answered (offline guard), then, once the old host answered HTTP 503 five times over more than two minutes, the context (id, type, scheme and host, last status) went to the agent, the proposed `http://lvh.me:41631` was probed (one GET at that host) and the job became `proposed`; `POST /api/operator/approve` rewrote only `base` (mirrors and the extra field were kept), the next search used the new host, and a second approve answered 409.
- local_names: a library root with 0-byte, invented release names gave a batch of messy names only (not the human-titled file); four titles and kinds were applied, one undecided file was left alone.
- search_help: an invented typo query showed two chips ("$(evil)" dropped) once the answer arrived.
- picks: with watch history, a favourite and a tracked show seeded, the agent was sent titles only (a YouTube watch URL and a hash name were left out after a bug found by this run); of five recommendations an invented title was dropped, a title already watched was dropped, and three resolved to real Cinemeta items with real posters in the Home row.
- Failure paths: agent exit code 1, garbage output and a run that never ends (killed at the 5 minute limit, nothing left running) end `failed` with the full cap charged; budget exhaustion refused the next request (the job was never created); killing the app (SIGKILL) mid-job left `failed: Interrupted` on restart with the reservation kept; the Codex path (shim only, no `claude` on `PATH`) applied local_names and picks through the schema file and `-o` file and charged the cap, and the scratch files were removed.
- Bugs this found and fixed: the local_names schema forced at least one item (an honest "none" became a failure, or forced a guess); a failed local_names batch locked its files out for 14 days (now retried after a day, also after an interruption); early failures were not logged; the picks taste list let a URL's last segment through; a first-request network blip silently lost a pick (now retried once); the "Did you mean" chips did not appear until something else repainted the idle screen.
- Unit tested only: a wrong-shape answer, clicking a chip and the Dismiss and Details buttons (they use the same calls as the existing cards but were not clicked, since no input injection is used), and the Agents page toggle for picks (rendered by the offline native test).

Next up: more discovery and library tools, and the Windows terminal.

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
