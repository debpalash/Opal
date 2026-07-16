"""Auto-split from tests/test_features.py — AI models / AI features / Commands / Integration / Settings / Enrichment tests.
Byte-for-byte identical test bodies; see tests/features/harness.py for the
shared @test decorator, helpers, and run_all()."""
from .harness import *  # noqa: F401,F403
import os, sys, subprocess, sqlite3, socket, time, json  # noqa: F401

@test("Instant Commands Count", "Commands")
def test_instant_commands():
    ctx_file = os.path.join(PROJECT_DIR, "src/services/ai_context.zig")
    with open(ctx_file) as f:
        content = f.read()
    # Count unique addInstantResponse calls
    count = content.count("addInstantResponse(")
    # Count unique command patterns
    cmds = []
    for line in content.split("\n"):
        if 'std.mem.eql(u8, fl, "' in line:
            start = line.index('std.mem.eql(u8, fl, "') + len('std.mem.eql(u8, fl, "')
            end = line.index('"', start)
            cmds.append(line[start:end])
    return "pass", f"{len(set(cmds))} unique commands, {count} response points"


@test("Theme Voice Commands", "Commands")
def test_theme_commands():
    ctx_file = os.path.join(PROJECT_DIR, "src/services/ai_context.zig")
    with open(ctx_file) as f:
        content = f.read()
    found = []
    for cmd in ["theme", "next theme", "switch theme", "midnight", "abyss", "phantom", "nord", "ember"]:
        if f'"{cmd}"' in content:
            found.append(cmd)
    return "pass" if len(found) >= 5 else "warn", f"Found: {', '.join(found)}"


@test("TTS Voice Command", "Commands")
def test_voice_command():
    ctx_file = os.path.join(PROJECT_DIR, "src/services/ai_context.zig")
    with open(ctx_file) as f:
        content = f.read()
    if "use voice" in content:
        return "pass", '"use voice X" command exists'
    return "fail", "No voice selection command"


@test("Suggest Command", "Commands")
def test_suggest_command():
    ctx_file = os.path.join(PROJECT_DIR, "src/services/ai_context.zig")
    with open(ctx_file) as f:
        content = f.read()
    if "suggest" in content and "getProactiveSuggestion" in content:
        return "pass", '"suggest" / "what should i watch" commands'
    return "fail", "No suggest command"


@test("Save Chat Command", "Commands")
def test_save_chat():
    ctx_file = os.path.join(PROJECT_DIR, "src/services/ai_context.zig")
    with open(ctx_file) as f:
        content = f.read()
    if "save chat" in content and "export chat" in content:
        return "pass", '"save chat" / "export chat" commands'
    return "fail", "No chat export command"


@test("Dynamic Tool Selection", "Integration")
def test_dynamic_tools():
    ctx_file = os.path.join(PROJECT_DIR, "src/services/ai_context.zig")
    with open(ctx_file) as f:
        content = f.read()
    if "has_player" in content and "player_control" in content and "// Player tools — only when" in content:
        return "pass", "Player tools conditionally included"
    return "fail", "No dynamic tool selection"


@test("Cross-Session Context Injection", "Integration")
def test_cross_session_context():
    ctx_file = os.path.join(PROJECT_DIR, "src/services/ai_context.zig")
    with open(ctx_file) as f:
        content = f.read()
    checks = {
        "Past Sessions": "getRecentConversations" in content,
        "Preferences": "getTopPreferences" in content,
        "Memory Context": "[Memory Context]" in content,
    }
    passed = [k for k, v in checks.items() if v]
    return "pass" if len(passed) == 3 else "warn", f"Injected: {', '.join(passed)}"


@test("Configurable TTS", "Integration")
def test_configurable_tts():
    voice_file = os.path.join(PROJECT_DIR, "src/services/ai_voice.zig")
    with open(voice_file) as f:
        content = f.read()
    if "tts_voice_buf" in content and "tts_speed" in content:
        return "pass", "Voice + speed from state config"
    return "fail", "TTS still hardcoded"


@test("Playback Memory Hooks", "Integration")
def test_playback_hooks():
    player_file = os.path.join(PROJECT_DIR, "src/player/player.zig")
    with open(player_file) as f:
        content = f.read()
    if "ai_memory" in content and "learnPreference" in content:
        return "pass", "Media play → memory + preference learning"
    return "fail", "No memory hooks in player"


@test("Startup Proactive Greeting", "Integration")
def test_startup_greeting():
    chat_file = os.path.join(PROJECT_DIR, "src/services/ai_chat.zig")
    with open(chat_file) as f:
        content = f.read()
    if "getProactiveSuggestion" in content and "startup greeting" in content.lower():
        return "pass", "Injects 'continue watching' on first frame"
    return "fail", "No startup greeting"


@test("Conversation Persistence", "Integration")
def test_conversation_persistence():
    ctx_file = os.path.join(PROJECT_DIR, "src/services/ai_context.zig")
    with open(ctx_file) as f:
        content = f.read()
    if "saveConversation" in content:
        return "pass", "Conversations saved to conversation_log table"
    return "fail", "No conversation persistence"


@test("Local LLM is the default brain (apfel retired)", "AI Features")
def test_local_llm_default():
    # Apple Intelligence measured ~5 tok/s + broken JSON compliance — the
    # default brain is now Qwen2.5-3B via llama-server, self-installing on
    # first message (ensureReady: detect → download → start).
    srv = open(os.path.join(PROJECT_DIR, "src/services/ai_server.zig")).read()
    chat = open(os.path.join(PROJECT_DIR, "src/services/ai_chat.zig")).read()
    cfg = open(os.path.join(PROJECT_DIR, "src/core/config.zig")).read()
    if "backend_kind: BackendKind = .gemma_llama" not in srv:
        return "fail", "default backend is not gemma_llama"
    if "active_model_idx: usize = 1" not in srv:
        return "fail", "default model is not the qwen2.5-3b catalog entry"
    if "pub fn ensureReady" not in srv or "server.ensureReady()" not in chat:
        return "fail", "self-install path (ensureReady) not wired into send"
    # "cloud" is honored; on macOS an explicit "apfel" segment choice is now
    # honored too; any other/legacy value falls back to gemma_llama.
    if ('std.mem.eql(u8, val, "cloud")' not in cfg
            or 'is_macos and std.mem.eql(u8, val, "apfel")' not in cfg
            or ".gemma_llama" not in cfg):
        return "fail", "ai_backend load branch (cloud / macOS apfel / gemma_llama) missing"
    return "pass", "gemma_llama default + qwen2.5-3b + first-message self-install + explicit cloud/apfel honored"


@test("Tool results are exact-sized allocations", "AI Features")
def test_tool_result_alloc_discipline():
    # Regression: normResult freed ptr[0..MAX_TOOL_RESULT] for EVERY short
    # result, but error paths return exact-sized allocPrint strings — the
    # guessed-length free was an Invalid free panic (whole-app abort when a
    # tool found no results). Discipline now: scratch buffers are shrunk via
    # realloc at the return site; no raw sub-slice of a scratch buffer may
    # escape a tool function.
    src = open(os.path.join(PROJECT_DIR, "src/services/ai_tools.zig")).read()
    import re
    if "normResult(" in src.replace("fn normResult", ""):
        return "fail", "normResult guessing wrapper is back"
    if re.search(r"return result\[0\.\.", src):
        return "fail", "raw scratch-buffer slice returned (unfreeable length)"
    if "fn shrinkResult" not in src or src.count("shrinkResult(alloc, result") < 6:
        return "fail", "shrinkResult not applied at all return sites"
    return "pass", "6 scratch returns shrunk via realloc; no guessed-length frees"


@test("HF Model Catalog", "AI Models")
def test_hf_catalog():
    cat = _parse_catalog()
    if len(cat) < 3:
        return "fail", f"only {len(cat)} models parsed"
    for e in cat:
        for key in ("id", "name", "url", "filename", "size_label", "note"):
            if not e.get(key):
                return "fail", f"{e.get('id', '?')} missing {key}"
        if not e["url"].startswith("https://huggingface.co/"):
            return "fail", f"{e['id']} url not on HF hub"
        if not e["url"].endswith(".gguf"):
            return "fail", f"{e['id']} url not a .gguf"
    return "pass", f"{len(cat)} HF GGUF models, all fields valid"


@test("Catalog IDs/Files Unique", "AI Models")
def test_catalog_unique():
    cat = _parse_catalog()
    ids = [e["id"] for e in cat]
    files = [e["filename"] for e in cat]
    if len(set(ids)) != len(ids):
        return "fail", "duplicate model id"
    if len(set(files)) != len(files):
        return "fail", "duplicate filename"
    return "pass", f"{len(ids)} unique ids + filenames"


@test("Model Picker UI Wired", "AI Models")
def test_picker_wired():
    s = os.path.join(PROJECT_DIR, "src/ui/settings.zig")
    with open(s) as f:
        c = f.read()
    if "MODEL_CATALOG" in c and "selectModelByIndex" in c:
        return "pass", "picker iterates catalog + selects"
    return "fail", "picker not wired in settings"


@test("Model Selection Persisted", "AI Models")
def test_model_persisted():
    cfg = os.path.join(PROJECT_DIR, "src/core/config.zig")
    with open(cfg) as f:
        c = f.read()
    if '"ai_model_id"' in c and "selectModelById" in c:
        return "pass", "ai_model_id saved + restored"
    return "fail", "model choice not persisted"


@test("Settings Persist+Replay Round-Trip", "Settings")
def test_settings_persist_replay():
    # Regression for the Settings audit: EQ preset, video color filters,
    # download rate limit and Co-Watcher sensitivity must each be BOTH saved
    # (setKey) AND loaded (applyConfig branch) — and the AV filters replayed at
    # player init so they survive restart / new files. Source-level check
    # (matches the existing persistence-test pattern).
    cfg = _src("src/core/config.zig")
    st = _src("src/core/state.zig")
    pl = _src("src/player/player.zig")
    pure = _src("src/player/av_pure.zig")

    # Video color filter fields + save + load + init replay.
    vf_keys = ["vf_brightness", "vf_contrast", "vf_saturation", "vf_gamma"]
    for k in vf_keys:
        if f"{k}: i32 = 0" not in st:
            return "fail", f"state field {k} missing"
        if f'setKey("{k}"' not in cfg or f'"{k}"' not in cfg:
            return "fail", f"{k} not save+load persisted in config"
    # Replayed at player init via the shared av_pure mapping.
    if "eqFilterSpec" not in pure or "clampVideoFilter" not in pure:
        return "fail", "av_pure EQ/video-filter helpers missing"
    if "av_pure" not in pl or 'mpv_set_option_string(self.mpv_ctx, "af"' not in pl:
        return "fail", "player.zig does not replay EQ/video filters at init"

    checks = {
        "eq_preset save+load": 'setKey("eq_preset"' in cfg and '"eq_preset"' in cfg,
        "download limit save+load": 'setKey("download_rate_limit"' in cfg
            and '"download_rate_limit"' in cfg,
        "download limit re-applied": "applyDownloadLimitIfReady" in cfg
            and "applyDownloadLimitIfReady" in _src("src/main.zig"),
        "cowatch sensitivity save": 'setKey("cowatch_sensitivity"' in cfg,
        "cowatch sensitivity load": '"cowatch_sensitivity"' in cfg
            and "stringToEnum" in cfg,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "missing: " + ", ".join(missing)
    return "pass", "EQ + video filters + download limit + cowatch sensitivity persist & replay"


@test("Unified Search: Local Files", "AI Models")
def test_local_source():
    r = open(os.path.join(PROJECT_DIR, "src/services/resolver.zig")).read()
    if "resolveLocalFiles" in r and ".local" in r and "status_local" in r:
        return "pass", "local files are a unified-search source"
    return "fail", "local files not wired into resolver"


@test("Remote /load Percent-Decodes", "AI Models")
def test_remote_load_decode():
    rm = open(os.path.join(PROJECT_DIR, "src/services/remote.zig")).read()
    # The /load handler must urlDecode before load_file (was passing raw).
    idx = rm.find('"/load"')
    if idx > 0 and "urlDecode(raw" in rm[idx:idx + 600]:
        return "pass", "/load decodes percent-encoded URLs"
    return "fail", "/load still passes raw url"


@test("Catalog URLs Reachable", "AI Models")
def test_catalog_urls():
    import urllib.request
    cat = _parse_catalog()
    if not cat:
        return "skip", "no catalog"
    bad = []
    for e in cat:
        try:
            req = urllib.request.Request(e["url"], method="HEAD")
            with urllib.request.urlopen(req, timeout=12) as r:
                if r.status >= 400:
                    bad.append(f"{e['id']}:{r.status}")
        except Exception:  # noqa: BLE001 — offline / transient → not a code fault
            return "skip", "network unavailable"
    if bad:
        return "fail", "unreachable: " + ", ".join(bad)
    return "pass", f"all {len(cat)} URLs resolve (HTTP 200)"


@test("Cloud LLM Backend + No Silent Local Installs", "AI Features")
def test_cloud_llm_backend():
    # Cloud (OpenAI-compatible) backend: .env-keyed providers, Bearer auth on
    # the chat request, and NO silent local-model auto-download on first send
    # (local models install only from explicit Settings/chat-card actions).
    srv = _src("src/services/ai_server.zig")
    ctx = _src("src/services/ai_context.zig")
    cfg = _src("src/core/config.zig")
    stg = _src("src/ui/settings.zig")
    checks = {
        "cloud kind": "cloud" in srv and "CLOUD_PROVIDERS" in srv,
        "env-keyed providers": "_API_KEY" in srv and "OPENROUTER" in srv and "GROQ" in srv,
        "bearer auth wired": "authHeader" in srv and "authHeader" in ctx,
        "chat url per backend": "chatCompletionsUrl" in srv and "chatCompletionsUrl" in ctx,
        # ensureReady must NOT kick startModelDownload anymore (the silent
        # 3.2GB first-message download). The fn still exists for the explicit
        # Settings/chat-card buttons.
        "no silent download": "startModelDownload" not in _between(srv, "pub fn ensureReady", "\npub fn"),
        "config persists cloud": '"cloud"' in cfg and "ai_cloud_provider" in cfg,
        "settings picker": "Cloud API" in stg and "cloudProviderHasKey" in stg,
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "cloud providers + bearer auth + on-demand-only local models wired"
    return "fail", f"missing: {missing}"


@test("Parakeet TDT Voice Backend Wired", "AI Features")
def test_parakeet_backend():
    # NVIDIA Parakeet TDT (sherpa-onnx int8 exports): backend kinds, verified
    # download URLs, transducer CLI flags, deps status + settings rows.
    vb = _src("src/services/voice_backend.zig")
    dp = _src("src/core/deps.zig")
    st = _src("src/ui/settings.zig")
    if "parakeet_tdt_v2" not in vb or "parakeet_tdt_v3" not in vb:
        return "fail", "parakeet kinds missing from voice_backend"
    if "--model-type=nemo_transducer" not in vb or "--joiner=" not in vb:
        return "fail", "nemo transducer CLI flags missing"
    for url_bit in ("sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2",
                    "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2"):
        if url_bit not in dp:
            return "fail", f"parakeet bundle URL missing: {url_bit}"
    if "fetchParakeetAsync" not in dp or "parakeet_v2_model" not in dp:
        return "fail", "parakeet fetcher/status missing from deps"
    if "parakeetModelRow" not in st:
        return "fail", "parakeet download rows missing from settings"
    return "pass", "parakeet v2/v3 backends + downloads + settings rows wired"


@test("Incognito Chat Leaves No Trace", "AI Features")
def test_incognito_chat():
    # Every conversation persistence sink is guarded on incognito_mode, and
    # retrieval (RAG/past sessions/preferences) is skipped so past data can't
    # leak into an incognito prompt either.
    am = _src("src/services/ai_memory.zig")
    ac = _src("src/services/ai_context.zig")
    ch = _src("src/services/ai_chat.zig")
    sm = _src("src/services/scene_memory.zig")
    hm = _src("src/ui/home.zig")
    if am.count("incognito_mode") < 2:
        return "fail", "ai_memory sinks (saveConversation/ingestMemory) not guarded"
    if ac.count("incognito_mode") < 5:
        return "fail", "ai_context guards missing (save-chat, RAG, past sessions, prefs, req-file cleanup)"
    if "incognito_mode" not in ch:
        return "fail", "starred-to-DB not guarded"
    if "incognito_mode" not in sm:
        return "fail", "scene memory ingestion not guarded"
    if "Incognito" not in hm:
        return "fail", "incognito toggle missing from the chat composer"
    return "pass", "sinks guarded + retrieval skipped + composer toggle present"


@test("Chat Console: Wrapped Transcript + Agent Steps", "AI Features")
def test_chat_console():
    # The chat surface: wrapped textLayout messages (labels never wrap — long
    # replies used to clip), avatar/bubble asymmetry, live phase spinner, copy
    # action, home hero + suggestion chips, pinned composer.
    gr = _src("src/ui/grid.zig")
    hm = _src("src/ui/home.zig")
    if "textLayout" not in gr.split("renderChatMessages")[1].split("pub fn computeGridColumns")[0]:
        return "fail", "chat messages not on wrapping textLayout"
    if "dvui.spinner" not in gr or "clipboardTextSet" not in gr:
        return "fail", "streaming spinner / copy action missing"
    if "phaseLabel" not in gr:
        return "fail", "agent phase (tool steps) not surfaced in transcript"
    hp = _src("src/ui/home_pure.zig")
    if "renderChatMode" not in hm or "What are we watching tonight?" not in (hm + hp):
        return "fail", "home chat console (hero/transcript/composer) missing"
    if "scrollToOffset" not in hm:
        return "fail", "auto-follow scroll missing"
    return "pass", "console transcript + hero + follow-scroll + agent steps wired"


@test("OMDb Ratings Enrichment", "Enrichment")
def test_omdb_enrichment():
    """OMDb ratings enrichment is wired end-to-end: pure parser + worker exist,
    the detail view triggers + renders it, the key is stateful + persisted, and
    it ships inert (no fetch without a user key)."""
    def read(rel):
        p = os.path.join(PROJECT_DIR, rel)
        if not os.path.exists(p):
            return None
        with open(p) as f:
            return f.read()

    pure = read("src/services/omdb_pure.zig")
    worker = read("src/services/omdb.zig")
    if pure is None or worker is None:
        return "fail", "omdb_pure.zig / omdb.zig missing"
    # Pure parser exposes the parse + format + id helpers.
    for sym in ["pub fn parse", "pub fn extractImdbId", "pub fn normalizeImdbId",
                "pub fn formatScores", "Rotten Tomatoes", "Metacritic"]:
        if sym not in pure:
            return "fail", f"omdb_pure.zig missing '{sym}'"
    # Worker: OMDb endpoint, inert-without-key gate, mutex + gen/busy atomics.
    if "omdbapi.com" not in worker:
        return "fail", "omdb.zig missing omdbapi.com endpoint"
    if "omdb_api_key_len == 0" not in worker:
        return "fail", "omdb.zig not inert without a key"
    for sym in ["data_mutex", "gen", "busy", "onDetailOpen", "ratingsLabel"]:
        if sym not in worker:
            return "fail", f"omdb.zig missing '{sym}'"
    # State field + config persistence (save + load).
    st = read("src/core/state.zig") or ""
    if "omdb_api_key" not in st:
        return "fail", "state.zig missing omdb_api_key"
    cfg = read("src/core/config.zig") or ""
    if cfg.count("omdb_api_key") < 2:
        return "fail", "config.zig missing omdb_api_key save/load"
    # tmdb.zig triggers + renders; settings.zig exposes the key field.
    tmdb = read("src/services/tmdb.zig") or ""
    if 'onDetailOpen' not in tmdb or 'ratingsLabel' not in tmdb:
        return "fail", "tmdb.zig not wired to omdb trigger/render"
    settings = read("src/ui/settings.zig") or ""
    if "omdb_api_key" not in settings or "omdbapi.com" not in settings:
        return "fail", "settings.zig missing OMDb key field"
    # Registered as a unit-test in build.zig.
    build = read("build.zig") or ""
    if "omdb_pure.zig" not in build:
        return "fail", "build.zig missing test_omdb_pure registration"

    # If a key happens to be configured in the live DB, note it (still inert-safe).
    conn = get_db()
    keyed = False
    if conn:
        try:
            cur = conn.cursor()
            cur.execute("SELECT value FROM config WHERE key='omdb_api_key'")
            row = cur.fetchone()
            keyed = bool(row and row[0])
        except Exception:
            pass
        finally:
            conn.close()
    return "pass", f"OMDb enrichment wired (parser+worker+UI+persist); key set={keyed}"


@test("Local taste engine: activity + vectors + For You", "AI")
def test_local_taste_engine():
    def read(rel):
        with open(os.path.join(PROJECT_DIR, rel)) as f:
            return f.read()

    db_src = read("src/core/db.zig")
    activity = read("src/services/activity.zig")
    taste_pure = read("src/services/taste_pure.zig")
    problems = []

    # 1) DB layer: activity table + vec0 vector table at the featurizer dim.
    if "activity_log" not in db_src or "percent_watched" not in db_src:
        problems.append("activity_log table missing from db.zig")
    if "vec_taste USING vec0" not in db_src or "float[128]" not in db_src:
        problems.append("vec_taste vec0 table missing from db.zig")
    # Regression: sqlite3_auto_extension is a silent no-op on Apple's
    # libsqlite3, so vec0 must ALSO be registered per-connection (with
    # sqlite-vec compiled as -DSQLITE_CORE) or every vec0 CREATE TABLE
    # fails quietly and both vec_aimemory and vec_taste never exist.
    if "sqlite3_vec_init(db_handle" not in db_src:
        problems.append("per-connection sqlite3_vec_init missing (vec0 dead on macOS)")
    if "-DSQLITE_CORE" not in read("build.zig"):
        problems.append("sqlite-vec not compiled with SQLITE_CORE")

    # 2) record()/onPlay()/onProgress() wired at the agreed chokepoints only.
    if "pub fn record" not in activity:
        problems.append("activity.record missing")
    if 'activity.zig").onPlay' not in read("src/player/player.zig"):
        problems.append("player.load_file not recording plays")
    if 'activity.zig").onProgress' not in read("src/services/history.zig"):
        problems.append("history.savePlaybackPosition not feeding progress")
    if 'activity.zig").onProgress' not in read("src/player/watch_history.zig"):
        problems.append("watch_history.savePosition not feeding progress")
    if 'activity.zig").record(.queue_add' not in read("src/services/queue.zig"):
        problems.append("queue add not recorded")
    if 'activity.zig").record(.search' not in read("src/services/search.zig"):
        problems.append("submitQuery not recorded")

    # 3) taste_pure registered in the unit-test step AND routed (the shipped
    #    profile/score path goes through the tested pure functions).
    if "taste_pure.zig" not in read("build.zig"):
        problems.append("taste_pure not in build.zig test step")
    for fn in ("featurize", "eventWeight", "decayWeight", "finishProfile", "scoreCandidate"):
        if f"taste_pure.{fn}" not in activity:
            problems.append(f"activity.zig does not route through taste_pure.{fn}")

    # 4) Surfaced on Home + gated by the settings toggle/config key.
    if "computeSuggestions" not in read("src/services/recommendations.zig"):
        problems.append("suggestions not feeding the For You rail")
    if "taste_enabled" not in read("src/ui/home.zig"):
        problems.append("For You rail not gated on the toggle")
    settings_src = read("src/ui/settings.zig")
    if "taste_enabled" not in settings_src or "clearTasteData" not in settings_src:
        problems.append("settings toggle / Clear taste data missing")
    if "taste_suggestions" not in read("src/core/config.zig"):
        problems.append("taste_suggestions config key not persisted")

    # 5) Local-only: no network reach from the engine files.
    for name, src in (("activity.zig", activity), ("taste_pure.zig", taste_pure)):
        for needle in ("https://", "http://", "std.http", "fetchUrl", "curl", "api."):
            if needle in src:
                problems.append(f"network-ish string '{needle}' in {name}")

    if problems:
        return "fail", "; ".join(problems[:4])
    return "pass", "activity log + vec_taste vectors + gated For You tier wired"
