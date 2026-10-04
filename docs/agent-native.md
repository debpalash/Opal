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
| 4. Terminal | Done on Linux/macOS: the **Agents** page runs up to six sessions as tabs (Claude Code, Codex, Gemini CLI or a shell) on ptys inside Opal, parsed by libghostty-vt and drawn with dvui (below). **Settings → Agent Access** still launches them in the user's own terminal. Windows (ConPTY) is written and cross-compiled, not run. |
| 5. Extension loop | Not started. |
| 6. Autonomy | Wanted list engine done (below). Scheduled agent tasks done (below). |

### Background operator

**Local file names (`local_names`).** After a library scan completes, if the operator is on (and the session is not incognito), Opal picks up to 20 files whose automatically cleaned title still looks like a release name (quality, codec or source tags, a trailing `-GROUP`, `SxxExx`, bracketed tags, numeric-only) and that have no display title yet. It sends the agent only the file's base name (`index<TAB>filename`, never a folder) and asks for a human title and a kind (movie, tv, music, audiobook, other). The answer is validated twice (the CLI schema, then `parseLocalNames`: indexes inside the batch and unique, 1 to 120 characters, no control characters, path separators or angle brackets, at least one letter) and applied through `local_library.correct` only to rows whose display title is still empty and whose title has not changed since they were asked about. One request per scan, 25 cent cap, 6 hour cooldown. Files already asked about are remembered in `operator_names_batch` (which also holds the index to row mapping) and asked again only after 14 days. The pure rules and tests are in `src/services/operator_names_pure.zig`; the database side is `operator_local_names.zig`.

### Cost per run

Every headless agent run pays for its context before it does anything. Measured with the real `claude -p` CLI (a one-tool status question, warm cache): the default run with all 107 tools and Claude Code's own system prompt cost $0.019; with the `tasks` tool preset (34 tools, ~4.6K tokens instead of ~14K) and a short `--system-prompt` it costs $0.0075 on Sonnet and $0.0053 on Haiku. A no-tool structured call (operator jobs) drops from ~$0.014 to ~$0.003 with Haiku and a short system prompt (and from ~$0.08 with default tools). So: scheduled tasks default to Haiku (choose Sonnet per task when judgement matters), `opal-mcp --preset ask|tasks|digest` shows an agent only the tools it needs (`all` is the default for interactive use), and `--bare` is deliberately not used because it disables subscription (OAuth) login.

### Embedded terminal

libghostty-vt on ghostty `main` now exposes a terminal and render-state C API (the 0.1.0 package we first tried did not), and `main` requires the Zig version Opal already uses, so Opal depends on a pinned ghostty commit (`build.zig.zon`) and links its static `ghostty-vt-static` (ReleaseFast, SIMD off). `src/terminal/pty.zig` wraps `forkpty` (the child only calls `execve`; arguments and environment are built before the fork), `session.zig` runs one reader thread that feeds the pty into the terminal under a mutex and flattens the render state into plain cells for the UI, and `keymap.zig` maps dvui keys onto the libghostty key encoder (cursor-key mode, kitty protocol and so on; plain typing is left to the text event so nothing is sent twice). `src/ui/agent_terminal.zig` is the page: it starts the agent in the same workspace as the launcher, draws backgrounds and text runs per row (non-ASCII cell by cell so columns stay put) in the bundled Hack font, and takes over the keyboard while focused (`input.zig` skips Opal's shortcuts then; click outside to get them back). Verified on screen with a real shell: colours, bold, underline, inverse, prompt. Pty, snapshot and key encoding have unit tests (`zig build test-terminal`).

Windows (ConPTY, `pty_windows.zig`) is written but has only been cross-compiled, never run. Program lookup (`agent_launch.onPath`, also used by the operator and scheduled tasks) searches `PATH` for `name.exe`, `.cmd` and `.bat` and never the current directory (`agent_launch_pure.searchPath`, tested with a fake file system). `cmd.exe` and PowerShell are started by full path under `%SystemRoot%\System32` (fallback `C:\Windows\System32` when the variable is missing or unsafe), not by bare name. `writeAll` gives up after about 250 ms without progress like the POSIX pty; this relies on the write end being switched to non-blocking mode, which is unverified on a real machine.

**Tabs.** The page holds up to six sessions (`tabs_pure.MAX_TABS`), each a self-contained `Session` with its own snapshot, shown as a tab strip above the terminal: the agent name (`Claude Code`, `Shell 2`: the lowest free number per kind), the terminal title when the program set one (clipped to a budget that shrinks with the strip width, control bytes shown as spaces), an `x` to close, and a `+` menu to start Claude Code, Codex, Gemini CLI or a shell. Switching keeps every session running; only the active one is drawn, resized and gets input, and it is handed keyboard focus (the tab left behind is told it lost focus if its program asked for focus reports). A background tab shows a dot when it rang the bell (accent) or its title changed or it exited (muted) until you look at it. An exited tab reads `(exited)` and still shows its output until closed. Closing the active tab activates its right neighbour, else its left. Quitting ends all of them. `capturesKeyboard()` is true only for the active tab's focused terminal, behind the same frame-stamp guard as before. The ordering, naming, cap, close choice and marker rules are in `src/terminal/tabs_pure.zig` (tested in `test-terminal`). At very narrow windows the strip clips on the right (the `+` is first so it stays reachable).

**Input details.** Copy and paste are Cmd+C and Cmd+V on macOS, Ctrl+Shift+C and Ctrl+Shift+V elsewhere, plus Ctrl+Insert and Shift+Insert off macOS (`keymap.clipboardChord`, tested as a pure function; plain Ctrl+C and Ctrl+V always go to the program). A horizontal wheel is reported as buttons six and seven (xterm: left and right) to a program that tracks the mouse and ignored otherwise; Shift+wheel is a vertical scroll in dvui's eyes and is treated as one. Input methods: SDL reports the text still being composed (preedit) to dvui as a text event with `selected = true`, and the finished text as a plain one. Only plain text is typed; the preedit used to be written to the pty too, so a composed word arrived twice. Keys without Ctrl, Alt or Super are also swallowed while a composition is open and for 30 ms after it ends, so the Enter that confirms a word does not also send a carriage return (`keymap.ImeGuard`, tested; a composition silent for 10 seconds is dropped so a lost event cannot lock the keyboard). The composing text itself is not drawn in the terminal; the input method's own candidate window is placed at the cursor cell. Verified live with injected text and key events (preedit not typed, committed text typed once, confirming Enter swallowed, a later Enter sent) and injected horizontal wheel events against `cat -v` with mouse tracking on (`^[[<67;..M`, `^[[<66;..M`); a real input method has not been tried.

**Focus after a resize.** Reproduced as far as possible: after Ctrl+Shift+Esc, resizing the window through the compositor (tiled, then floating and resized) leaves the terminal unfocused. dvui hands a widget focus only on a mouse press inside it (a window focus event does not touch widget focus), so the odd refocus is a press that landed in the terminal; the terminal fills the window to its edges, so a press that starts a resize at the very edge can reach it. That is the same click-to-focus every press does; no code path focuses it on a resize alone.

**Scheduled tasks and the operator on Windows.** There is no `sh -c` there. `execute` and the operator's `runJob` find the agent with `agent_launch.findOnPath` (full path, never the bare name, which Windows would also look for in the working directory) and start it without a shell through `bounded_process`. `agent_exec_pure.windowsPlan` decides how: a native program (`claude.exe`) gets the plain argv, which Zig quotes for `CommandLineToArgvW`, so the prompt rides on the command line like on Linux. An npm `.cmd` shim can only run under `cmd.exe`, so it runs as `cmd.exe /d /e:ON /v:OFF /c` from the system directory (Zig's own batch-file path, `%` escaped), only after every argument passed a check against `" % ^ & | < > !` and control bytes, and the prompt is not an argument at all: it is written to the agent's standard input (`claude -p` without a prompt, `codex exec ... -`). Anything that cannot be made safe is refused with the reason as the run's summary instead of being risked: an unsafe install path, a setting with quotes or operators (the operator's `--json-schema` and `--mcp-config` JSON, so Claude Code as a `.cmd` shim cannot serve the operator), an empty argument (`--tools ""`, the no-built-in-tools setting of scheduled Claude runs, which cmd may drop, so a Claude shim is refused for scheduled tasks too: install the native `claude.exe` or use Codex). The Codex overrides on Windows are TOML literal strings (`'C:\path'`), which need no backslash escaping and carry no double quote. Standard error is not merged into the summary on Windows. Everything pure (plan, quoting, refusals, argv) is unit tested on Linux and the tests and sources compile for `x86_64-windows-gnu`; none of it has run on a real Windows machine.

### Scheduled agent tasks

`src/services/agent_tasks.zig` plus `agent_tasks_pure.zig` (limits, schedule, headless argv). Saved prompts run `claude -p` (only the `opal` tools allowed, `--max-budget-usd` cap) or `codex exec` (read-only sandbox) on a timer, one at a time, inside the agent workspace. Opt-in through a master switch only the user can flip; a daily run cap counted at run start, a ten minute timeout and a host-admin-only API bound the cost. On Linux and macOS the prompt travels as one argv element via `sh -c 'exec "$@" 2>&1'`, never through shell parsing; on Windows see "Scheduled tasks and the operator on Windows" above. Exposed as `/api/agent/tasks/*` and `agent_task*` tools. Gemini CLI is not schedulable yet: its unattended MCP approval has not been verified.

### Wanted list (the CouchPotato core)

`src/services/wanted.zig` plus `wanted_pure.zig` (scoring, backoff). Add a movie or episode once; Opal searches on a private channel that never disturbs on-screen results, filters cams, screeners, fan edits and trailers, scores by quality, seeders and size, starts the best torrent on the owner thread, retries with backoff (30 min doubling to a day) and marks the item fulfilled when the download completes. "Follow tracked shows" queues the newest aired episode of each tracked show. Verified live against EZTV. Exposed as `/api/wanted/*` and `wanted_*` tools, and as a Wanted section at the top of the Downloads page (add by typing `Dune 2021` or `Severance S02E03`; find, pause, resume, remove).

### Background operator

`src/services/operator*.zig`: Opal hands a problem to a headless coding agent that has no Opal tools and only a context text in its prompt, and gets back schema-validated JSON. Off until the user enables it.

**endpoint_repair** (`operator_endpoint.zig`, logic in `operator_endpoint_pure.zig`). When an installed source keeps failing, the agent (with web search) says where it lives now.
- *Trigger.* `source_request.zig` counts consecutive failures per source. Five failures spanning at least two minutes ask the operator (once per 24 hours per source). Only connection failures, timeouts and real HTTP error statuses count; cancellations, local errors, rate limits (429), 401 and body-validation failures neither count nor reset, and any success resets. Connect-only streaks with no success from any source since they began are treated as the user being offline. Sources not installed are never asked about.
- *Context.* Source id, manifest type, the base address reduced to scheme and host, the last status or failure kind and the streak length. No other configuration field is ever read, so keys, tokens, debrid keys, cookies and user names cannot leave the app.
- *Probe.* The answer must be a bare public http(s) address, confidence 0.5 or more, and different from the current one. Opal then does one GET of it: 8 second timeout, no credentials or cookies, redirects not followed (a 3xx counts only when it does not point at a private host), size bounded, status 200 to 399. Only then is the job `proposed`, with a summary like "bxx.example may have moved to https://new.example (checked: reachable)".
- *Approval.* Never automatic and human-only: the Agents page only (there is no HTTP route for it, so a token holder cannot approve its own proposals). No agent tool can approve. On approval the stored answer is validated again and only the `base` field of the source file is rewritten; every other field (mirrors, sealed credentials) is kept, secrets are protected by `source_config.install`, and the change is live at once. If the source was uninstalled meanwhile the approval fails.
- *Scope.* Sources fetched through `source_request` (anime, comics, audio, webcomic providers) and torrent indexes. Indexes feed the same per-source streak through `source_request.noteIndex` (same thresholds, same 24 hour cooldown, same id as the source file): the Python engines print one `#opal-health` line per source next to their result rows (verdict over all of the source's mirrors: any answer is a success; a source with no fetch outcome, or only a challenge page, reports nothing), and the native EZTV, Torznab family, readallcomics (`core/mirrors.zig`, one report per call, not per mirror) and YTS fetches report directly. Only installed sources with a `base` are counted; cancellations, shutdown, offline connect-only streaks, 429 and unreadable bodies behave as above, and the context is still built by the same secret-free builder. Limits: an engine that hangs past nova2's 6 second deadline reports nothing, a YTS source file without a `base` is not counted (there is nothing to repair), and the EZTV list call in `search.zig` does not report.

Next up: more discovery and library tools, and the Windows terminal.

## Running the tests

`zig build test` runs every unit suite (it needs the ghostty package and libsqlite3; on Linux the test artifacts that the self-hosted backend cannot link set `use_llvm = true`). `zig build test-agentic` runs only the agent-native suites in one command: `test-operator`, `test-agent`, `test-ops` (includes the OpenAPI drift check), `test-terminal`, `test-wanted`, `test-browser` and `test-keyless`. The browser extension has its own tests: `cd extension && npm ci --ignore-scripts && npm test`.

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
