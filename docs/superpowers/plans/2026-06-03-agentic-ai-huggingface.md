# Agentic AI + HuggingFace Model Registry — Implementation Plan

**Date:** 2026-06-03
**Status:** Autopilot execution (overnight). Additive, non-breaking.
**Goal:** Make Opal's AI a stronger, user-selectable *agentic media assistant you can talk to*, by (1) turning the single hardcoded model into a data-driven registry of verified HuggingFace GGUF models — including newer, better-at-tool-calling models — selectable in Settings; (2) persisting the choice; (3) hardening the tool-call loop; (4) tightening the voice path. The system is **already** agentic (17 tools, JSON tool-call loop in `ai_tools.zig`, voice via `ai_voice.zig`/`voice_backend.zig`) and already downloads GGUF from HuggingFace — this plan upgrades *which* models and *how they're chosen*, without breaking the working path.

## Architecture (current → target)

- **Current:** `ai_server.zig` hardcodes `GEMMA_MODEL_URL/FILENAME/SIZE_LABEL` consts; `BackendKind = enum { apfel, gemma_llama }`; `activeModelFilename()/Url()/SizeLabel()` switch on backend. Talks to llama-server's OpenAI-compatible `/v1/chat/completions`. Download-on-demand machinery exists (`model_downloading`, `download_progress_*`).
- **Target:** Keep `BackendKind` (apfel vs llama). Add a **model registry** `pub const ModelEntry = struct { id, display_name, hf_url, filename, size_label, note }` and `pub const models = [_]ModelEntry{...}`, plus `pub var selected_model: usize = 0`. The `gemma_llama` accessors resolve through `models[selected_model]` instead of the consts. Default stays Gemma-4-E2B (index 0) so existing installs are unaffected.

## Verified models (HF API confirmed 2026-06-03; filenames exist)

| idx | id | display | repo / file (resolve URL) | size | note |
|---|---|---|---|---|---|
| 0 | `gemma4_e2b` | Gemma 4 E2B (default) | `unsloth/gemma-4-E2B-it-GGUF` / `gemma-4-E2B-it-UD-Q4_K_XL.gguf` | ~3.2 GB | current default; multimodal-capable |
| 1 | `qwen3_4b` | Qwen3 4B (best tools) | `unsloth/Qwen3-4B-Instruct-2507-GGUF` / `Qwen3-4B-Instruct-2507-UD-Q4_K_XL.gguf` | ~2.5 GB | Apache-2.0; strongest agentic/function-calling in this size |
| 2 | `gemma3n_e4b` | Gemma 3n E4B | `unsloth/gemma-3n-E4B-it-GGUF` / `gemma-3n-E4B-it-UD-Q4_K_XL.gguf` | ~4.2 GB | on-device multimodal |
| 3 | `qwen25_3b` | Qwen2.5 3B (fast) | `Qwen/Qwen2.5-3B-Instruct-GGUF` / `qwen2.5-3b-instruct-q4_k_m.gguf` | ~2.0 GB | smallest/fastest fallback |

HF resolve URL form: `https://huggingface.co/<repo>/resolve/main/<file>`.
**Every agent that adds a URL MUST verify it with:** `curl -sI -o /dev/null -w "%{http_code}\n" -L "<url>"` → expect `200`. If a URL does not resolve, drop that entry rather than ship a 404.

## Conventions (from CLAUDE.md)

`io_global` wrappers (not `std.fs`/`std.time`); single global allocator; `std.atomic`+`sync.Mutex` thread-safety; no `zigzag`→`opal` rename; pure tests only for modules that don't cross `io_global`. Local commits per task for checkpointing; **never push**.

## Verification (same env as the UI plan)

- `zig build 2>&1 | tail -6; echo rc=$?` → rc 0 (SDL2 `ld.lld` warnings + "native failure" label are benign; only nonzero exit / Zig `error:` counts).
- `zig build test 2>&1 | tail -6; echo rc=$?` → rc 0.
- Smoke: `timeout --preserve-status 5 env DISPLAY=:1 ./zig-out/bin/zigzag > /tmp/zz.log 2>&1 || true` then `grep -vi "0 memory leaks" /tmp/zz.log | grep -ci "error\|panic\|leak"` → 0. (No foreground `sleep`/busy-loops — the harness kills them; use `timeout`.)
- **Guardrail:** if a task can't go green, `git stash --include-untracked && git stash drop` to restore the last commit, then report failure. Never leave a broken tree.

---

## Task 1: Model registry in `ai_server.zig` (data-driven, non-breaking)

- Add `pub const ModelEntry = struct { id: []const u8, display_name: []const u8, hf_url: []const u8, filename: []const u8, size_label: []const u8, note: []const u8 };`
- Add `pub const models = [_]ModelEntry{ ...the 4 verified entries above... };` (index 0 = the existing Gemma, byte-identical URL/filename/size to today's consts).
- Add `pub var selected_model: usize = 0;`
- Rewrite `activeModelFilename()/activeModelUrl()/activeModelSizeLabel()` so the `.gemma_llama` arm returns `models[selected_model].filename/.hf_url/.size_label` (guard `selected_model < models.len`). Keep `.apfel` arm `""`.
- Keep the old `GEMMA_MODEL_*` consts (used by `models[0]`) so nothing else breaks.
- Add `pub fn setModel(idx: usize) void` that bounds-checks, sets `selected_model`, and calls `resetDetection()` (so the model path re-resolves).
- **Verify:** `zig build` rc 0; `curl -sI` each of the 4 URLs → 200. **Commit:** `feat(ai): data-driven HF model registry (Qwen3-4B, Gemma-3n, Qwen2.5 + default Gemma)`

## Task 2: Persist model choice in `config.zig`

- In the save path, add `setKey("ai_model", ai_server.models[ai_server.selected_model].id)` (mirror the existing `tmdb_api_key` style; import path as used elsewhere).
- In the load path, add an `ai_model` branch that matches the saved id against `ai_server.models[].id` and sets `selected_model` (default 0 if unknown). Use `ai_server.setModel(idx)` if it doesn't recurse into save.
- **Verify:** `zig build` rc 0; `zig build test` rc 0. **Commit:** `feat(ai): persist selected AI model in config`

## Task 3: Settings model picker

- In `settings.zig`, in the AI section (near the existing backend/server controls — search `ai_server`/`backend_kind`/"Gemma"), add a model picker. Prefer the new `components.menu(@src(), labels, &sel)` primitive (added by the UI Foundation workflow); if `menu` is absent, fall back to the existing `selectRow`/`dvui.dropdown` pattern already used in that file.
- Build `labels` from `ai_server.models[].display_name`; bind to a local `usize` seeded from `ai_server.selected_model`; on change call `ai_server.setModel(idx)` then persist via the same config save the other settings use. Show `models[sel].size_label` + `.note` beneath.
- Only show the picker when `backend_kind == .gemma_llama` (apfel has no downloadable model).
- **Verify:** `zig build` rc 0; RENDER-SMOKE clean. **Commit:** `feat(ai): settings model picker for HF model registry`

## Task 4: Tool-call loop robustness (conservative, tested)

- In `ai_tools.zig`, harden `parseToolCall`/`containsToolCall` against common real-world LLM formatting: tool-call JSON wrapped in ```json fences, leading prose before the JSON, and the OpenAI-style `{"name":..,"arguments":..}` without the outer `tool_call` wrapper. Keep the existing accepted format working.
- If `ai_tools` has (or can have) a pure sibling that doesn't cross `io_global`, add `zig build test` cases for the new parsing branches (factor pure parsing into `ai_tools_pure.zig` only if low-risk; otherwise add an inline `test` block kept pure). Do NOT change tool *dispatch* or tool *semantics* — parsing only.
- **Verify:** `zig build` rc 0; `zig build test` rc 0. **Commit:** `feat(ai): robust tool-call extraction (fenced/prefixed/openai-style JSON)`

## Task 5: System prompt — advertise tools + the selected model's strengths

- Locate the system-prompt builder (search `system` in `ai_chat.zig`/`ai_context.zig`/`ai_tools.zig`). Ensure the tool catalog is described clearly and the prompt nudges concise tool-use. Keep it model-agnostic (works for Gemma and Qwen formats). Small, surgical edit — no behavioral rewrite.
- **Verify:** `zig build` rc 0; RENDER-SMOKE clean. **Commit:** `feat(ai): clearer tool-use system prompt`

## Task 6: Final verify + note

- Full `zig build` + `zig build test` + RENDER-SMOKE green.
- Append a short note to this file's top ("Outcome:") summarizing what landed and any dropped/deferred items.
- **Commit:** `docs(ai): agentic AI + HF registry — outcome note`

## Out of scope (do NOT do autonomously — needs the user's hardware/keys/decisions)

- Auto-downloading any multi-GB model (the user triggers downloads from Settings; we only register URLs).
- HF Inference API / remote keys (no credentials available).
- Swapping the STT/TTS engine or changing `speaches`/whisper wiring (working path; risky).
- Any change that can't be proven build-green + smoke-clean → revert and report instead.
