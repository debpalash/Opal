# Autopilot session — 2026-06-03 (overnight)

Branch **`v2-autopilot`** (off `main`). **35 commits, all local — nothing pushed.** `main` is untouched.
End state: `zig build` **green**, GUI render-smoke **0 collisions / 0 errors**, no new `zig build test` regressions.

Review with: `git log --oneline main..v2-autopilot` · diff with `git diff main..v2-autopilot`.

## What landed (4 workflows, each task self-verified build→smoke→commit)

### 1. v2 UI Foundation — Phase 1 (17/17)
Calm-flat token + primitive system so later phases are component calls, not bespoke styling.
- `src/ui/theme_pure.zig` (new): pure motion/type math (easeInOut, pulse, lineHeightPx) + unit tests.
- `src/ui/theme.zig`: `transparent`/`shadow_overlay` tokens, derived `focus()`/`textDisabled()`/`loading()`, `motion` re-export, type scale + weights, `spacing.huge`; removed 2 dead tokens.
- `src/ui/components.zig`: 10 primitives — `button, card, badge, checkbox, radioGroup, slider, listItem, spinner, menu, modal` (legacy `statusPill`/`ProgressBar` kept as aliases).
- `src/ui/ids.zig` (new): named `id_extra` bases. `src/ui/components_gallery.zig` (new): `ZZ_GALLERY=1` debug QA overlay (renders every primitive ≥2× to prove zero widget-id collisions).
- Transparent-literal sweep across all `src/ui/*.zig`.

### 2. Agentic AI + HuggingFace model registry (6/6)
Make the AI a user-selectable, stronger agent. **Additive — default behavior unchanged.**
- `src/services/ai_server.zig`: data-driven `models[]` registry (`ModelEntry`), `selected_model`, `setModel()`. Default index 0 = the existing Gemma (byte-identical). Verified HF GGUF entries: **Gemma-4-E2B** (default), **Qwen3-4B-Instruct-2507** (stronger tool-calling), **Gemma-3n-E4B**, **Qwen2.5-3B**. All 4 resolve URLs returned HTTP 200.
- `src/core/config.zig`: persists choice as `ai_model`.
- `src/ui/settings.zig`: model picker (uses the new `menu` primitive), shown only for the llama backend, with size + note.
- `src/services/ai_tools.zig`: hardened tool-call extraction (```json fences, leading prose, OpenAI-style bare `{"name","arguments"}`) + a clearer tool-use system prompt. Tool dispatch semantics unchanged.

### 3. UI Phase 2 — Navigation & IA (7/7)
- Drawer tabs grouped **Sources / Library / System** via a data table (no enum reorder → no config drift).
- Save/Load Workspace modals (`src/ui/ui.zig`) converted to the new `components.modal` primitive (~150 lines of hand-rolled chrome removed).
- **Command palette** (`src/ui/command_palette.zig`, new) — fuzzy nav/chrome commands; bound to **Ctrl/Cmd+K**.
- **`?`** now opens the (pre-existing) shortcut overlay, re-skinned onto calm tokens.
- Spec + plan: `docs/superpowers/specs/2026-06-03-ui-nav-ia-phase2-design.md`, `docs/superpowers/plans/2026-06-03-ui-nav-ia-phase2.md`.

### 4. Adversarial review sweep — 3 real bugs caught & fixed
Parallel reviewers → refute-verify → guardrailed fix. 7 findings → 4 confirmed → fixed; 3 low-severity false-positives correctly rejected.
- `ee19d7c` **tool-call args corrupted by braces inside JSON strings** — made the brace scanner string/escape-aware.
- `c46501a` **registry was non-functional for non-default models** — `detectGemmaLlama` hardcoded the Gemma filename, so picking Qwen3 wouldn't probe/launch it. (Without this fix the whole picker silently did nothing.)
- `2780550` **spinner never animated** — f32 mantissa precision loss at ~1.7e12 ms; reduce modulo the period in i64 first.

## Needs your decision (NOT done autonomously)
- **`settings.zig` module split** (Phase 2 Task 8) — large, risky refactor; gated `needs-approval`. Plan is written; say the word to execute.
- **Phases 3 (screen polish) & 4 (core flows)** — design-heavy; deferred to your direction. Foundation + nav are in place for them.

## Known pre-existing issue (not from tonight)
`zig build test` exits 1 because the `src/core/paths.zig` test module calls libc `getenv` without linking libc; linking libc trips a separate toolchain linker-relocation bug on this machine. Reproduces on the pre-tonight baseline. `zig build` (the app) is unaffected. Left alone deliberately — it's an environment/toolchain fix, not a code change.

## Verify the app yourself
```
zig build && env DISPLAY=:1 ./zig-out/bin/zigzag        # normal run
env DISPLAY=:1 ZZ_GALLERY=1 ./zig-out/bin/zigzag        # primitive gallery (Debug)
```
Then: open the drawer (grouped tabs), press Ctrl+K (palette) and ? (shortcuts), and Settings → AI to try the model picker.
