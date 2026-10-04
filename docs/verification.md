# Verification status

What has actually been run, and where. Compiled from the verification notes in
[agent-native.md](agent-native.md), [browser-integration.md](browser-integration.md),
[mcp.md](mcp.md) and [browse-sources.md](browse-sources.md), plus the build and
packaging checks on branch `v2/build-health`. If a feature is not mentioned for a
platform, it has not been verified there.

Legend: **live** = run against the real app (or real service); **tests** = unit
or fixture tests pass; **compile** = cross-compiled or built only, never run;
**-** = not verified.

| Feature | Linux | macOS | Windows | Notes |
| --- | --- | --- | --- | --- |
| MCP tools (`opal-mcp`, registry, OpenAPI) | live + tests | compile (CI builds it; `zig build opal-mcp`) | compile | Verified live on Linux against the running app. `opal-mcp --version` and `--openapi` run from a ReleaseSafe build, and `docs/openapi.json` is checked for drift (`test-ops`, CI job `openapi-drift`). |
| Wanted list | live + tests | tests (pure logic) | tests (pure logic) | Live search and download start against EZTV on Linux. Scoring and backoff are pure Zig tests. |
| Scheduled agent tasks | tests | - | - | Argv, schedule and limit rules are unit tested. The docs record no unattended run of `claude -p` or `codex exec`. Gemini CLI is not schedulable (unverified approval flow). Windows cannot run them (`sh -c`). |
| Embedded terminal (Agents page) | live + tests | compile + tests | compile only | Linux: real shell on screen (colours, bold, underline, inverse). macOS: `forkpty` path cross-compiled, never run. Windows: ConPTY written and cross-compiled; non-blocking write behaviour unverified. |
| Background operator | tests | - | - | Validation, gating, wording and names are unit tested and the Activity page has offline UI fixtures. The docs record no live run with a real agent. |
| Browser integration (extension, pairing, hub) | live (Chromium 152, headless) + tests | - | - | Milestones 1 and 2 verified on Linux with headless Chromium and a test stream. Not verified: headed Chrome, Firefox, Edge, the real Detect media permission prompt, Local Network Access prompt, worker restart. Extension node tests: 22 pass. |
| Keyless (Cinemeta, TVmaze, EZTV) | live (curl, on screen) + tests | tests | tests | Asian Drama checked with curl on 2026-10-05. TV and keyless catalog UI captured on Linux. TVmaze Korean coverage is thin. |

## Build and packaging (this machine: Linux x86_64, Zig 0.16.0)

| Check | Result |
| --- | --- |
| `zig build test` (full suite) | 3575 of 3577 tests pass, 2 skipped, 0 failed, 438 of 438 build steps |
| `zig build test-agentic` | 541 of 543 pass, 2 skipped |
| `zig build -Doptimize=ReleaseSafe` (app plus `opal-mcp`) | builds; both binaries produced |
| `opal-mcp --version`, `--openapi` | run; `--openapi` output equals `docs/openapi.json` |
| nfpm 2.41.3 (`deb`, `rpm`, `archlinux` from `packaging/nfpm.yaml`) | packages build; the listing contains `/usr/bin/opal-mcp` |
| AUR `PKGBUILD`s | `bash -n` and `makepkg --printsrcinfo` pass; `package()` of the source package run against the real binaries in `/tmp` |
| Agent workspace assets (`SKILL.md`, `AGENT_WORKSPACE.md`) | embedded with `@embedFile` (anonymous imports); a packaged binary needs no files beside it |
| `opal-mcp` token lookup | uses the same config directory rule as the app (`XDG_CONFIG_HOME/opal`, `~/.config/opal`, `%APPDATA%/opal`), independent of install layout; the app finds `opal-mcp` next to its own executable |
| Not run here | snapcraft, `linux-compat` Docker staging (`stage.py` only syntax checked), AppImage, `scripts/build-app.sh` (needs macOS `otool`, `codesign`), Windows MSI, any GitHub Actions workflow |

macOS and Windows: nothing in the packaging was built or run. `scripts/build-app.sh`
copies `opal-mcp` into `Contents/MacOS` (next to the app executable, where the app
looks for it) and the later ad-hoc `codesign --deep` covers it, but this is from
reading the script. The Windows release job stages `opal-mcp.exe` beside `opal.exe`;
unverified.
