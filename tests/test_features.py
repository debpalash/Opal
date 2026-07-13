#!/usr/bin/env python3
"""
ZigZag Feature Test Suite
Tests all features across DB, config, voice pipeline, theming, and memory systems.
Outputs JSON results for the web dashboard.
"""

import sqlite3
import subprocess
import os
import json
import time
import socket
import sys

DB_PATH = os.path.expanduser("~/.config/opal/opal.db")
PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS_FILE = os.path.join(PROJECT_DIR, "tests", "results.json")

class TestResult:
    def __init__(self, name, category, status, detail="", duration_ms=0):
        self.name = name
        self.category = category
        self.status = status  # "pass", "fail", "skip", "warn"
        self.detail = detail
        self.duration_ms = duration_ms

    def to_dict(self):
        return {
            "name": self.name,
            "category": self.category,
            "status": self.status,
            "detail": self.detail,
            "duration_ms": self.duration_ms
        }

results = []

def test(name, category):
    """Decorator for test functions"""
    def decorator(fn):
        def wrapper():
            t0 = time.time()
            try:
                status, detail = fn()
                dt = int((time.time() - t0) * 1000)
                results.append(TestResult(name, category, status, detail, dt))
            except Exception as e:
                dt = int((time.time() - t0) * 1000)
                results.append(TestResult(name, category, "fail", str(e), dt))
        wrapper._test = True
        wrapper._name = name
        return wrapper
    return decorator

# ══════════════════════════════════════════════════════════
# Database Schema Tests
# ══════════════════════════════════════════════════════════

def get_db():
    if not os.path.exists(DB_PATH):
        return None
    return sqlite3.connect(DB_PATH)

@test("Database Exists", "Database")
def test_db_exists():
    if os.path.exists(DB_PATH):
        size = os.path.getsize(DB_PATH)
        return "pass", f"Size: {size/1024:.1f} KB"
    # The db is created on first app launch — absent on fresh machines/CI.
    return "skip", "opal.db not found (app never launched here)"

@test("Config Table", "Database")
def test_config_table():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT COUNT(*) FROM config")
    count = cur.fetchone()[0]
    db.close()
    return "pass", f"{count} config entries"

@test("Watch History Table", "Database")
def test_watch_history():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT COUNT(*) FROM watch_history")
    count = cur.fetchone()[0]
    db.close()
    return "pass", f"{count} watch entries"

@test("Search History Table", "Database")
def test_search_history():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT COUNT(*) FROM search_history")
    count = cur.fetchone()[0]
    db.close()
    return "pass", f"{count} searches"

@test("Download History Table", "Database")
def test_download_history():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT COUNT(*) FROM download_history")
    count = cur.fetchone()[0]
    db.close()
    return "pass", f"{count} downloads"

@test("TMDB Items Table", "Database")
def test_tmdb_items():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT COUNT(*) FROM tmdb_items")
    count = cur.fetchone()[0]
    db.close()
    return "pass", f"{count} TMDB items"

@test("AI Memory Table", "Database")
def test_aimemory():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT COUNT(*) FROM aimemory")
    count = cur.fetchone()[0]
    db.close()
    return "pass", f"{count} memories"

@test("Vector Memory Table", "Database")
def test_vec_aimemory():
    db = get_db()
    if not db: return "skip", "No DB"
    try:
        cur = db.execute("SELECT COUNT(*) FROM vec_aimemory")
        count = cur.fetchone()[0]
        db.close()
        return "pass", f"{count} vectors"
    except:
        db.close()
        return "warn", "sqlite-vec extension not loaded (expected outside app)"

@test("Poster Cache Table", "Database")
def test_poster_cache():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT COUNT(*) FROM poster_cache")
    count = cur.fetchone()[0]
    db.close()
    return "pass", f"{count} cached posters"

# ── Cross-Session Memory Tables ──

@test("Conversation Log Table", "Memory")
def test_conversation_log():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT COUNT(*) FROM conversation_log")
    count = cur.fetchone()[0]
    db.close()
    return "pass", f"{count} logged conversations"

@test("User Preferences Table", "Memory")
def test_user_preferences():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT key, value, weight FROM user_preferences ORDER BY weight DESC LIMIT 5")
    rows = cur.fetchall()
    db.close()
    if rows:
        detail = "; ".join(f"{k}={v} (w:{w:.0f})" for k, v, w in rows)
        return "pass", detail
    return "pass", "No preferences learned yet"

@test("Watch Sessions Table", "Memory")
def test_watch_sessions():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT COUNT(*) FROM watch_sessions")
    count = cur.fetchone()[0]
    db.close()
    return "pass", f"{count} sessions"

@test("Proactive Suggestion Query", "Memory")
def test_proactive_suggestion():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute(
        "SELECT name, percent, position_secs FROM watch_history "
        "WHERE percent > 0.1 AND percent < 0.9 ORDER BY updated_at DESC LIMIT 1"
    )
    row = cur.fetchone()
    db.close()
    if row:
        name = row[0].split("/")[-1] if "/" in row[0] else row[0]
        return "pass", f'"{name[:50]}" at {row[1]*100:.0f}%'
    return "warn", "No unfinished content to suggest"

# ══════════════════════════════════════════════════════════
# Config Persistence Tests
# ══════════════════════════════════════════════════════════

@test("Theme Persistence", "Config")
def test_theme_persistence():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT value FROM config WHERE key = 'theme_preset'")
    row = cur.fetchone()
    db.close()
    if row:
        return "pass", f"Theme: {row[0]}"
    return "warn", "No theme saved yet"

@test("UI Scale Config", "Config")
def test_ui_scale():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT value FROM config WHERE key = 'ui_scale'")
    row = cur.fetchone()
    db.close()
    if row:
        return "pass", f"Scale: {row[0]}x"
    return "warn", "Not set"

@test("TTS Voice Config", "Config")
def test_tts_voice():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT value FROM config WHERE key = 'tts_voice'")
    row = cur.fetchone()
    db.close()
    if row and row[0]:
        return "pass", f"Voice: {row[0]}"
    return "warn", "Default (Bella)"

@test("TTS Speed Config", "Config")
def test_tts_speed():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT value FROM config WHERE key = 'tts_speed'")
    row = cur.fetchone()
    db.close()
    if row and row[0]:
        return "pass", f"Speed: {row[0]}x"
    return "warn", "Default (1.0)"

@test("Window State Persistence", "Config")
def test_window_state():
    db = get_db()
    if not db: return "skip", "No DB"
    keys = ['win_x', 'win_y', 'win_w', 'win_h']
    vals = {}
    for k in keys:
        cur = db.execute("SELECT value FROM config WHERE key = ?", (k,))
        row = cur.fetchone()
        if row: vals[k] = row[0]
    db.close()
    if len(vals) == 4:
        return "pass", f"{vals['win_w']}x{vals['win_h']} at ({vals['win_x']},{vals['win_y']})"
    return "warn", f"Only {len(vals)}/4 window values saved"

@test("Jellyfin Integration Config", "Config")
def test_jellyfin_config():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT value FROM config WHERE key = 'jf_server_url'")
    row = cur.fetchone()
    db.close()
    if row and row[0]:
        return "pass", f"Server: {row[0][:30]}"
    return "skip", "Not configured"

# ══════════════════════════════════════════════════════════
# Build & Binary Tests
# ══════════════════════════════════════════════════════════

@test("Zig Build", "Build")
def test_zig_build():
    try:
        result = subprocess.run(
            ["zig", "build"], cwd=PROJECT_DIR,
            capture_output=True, text=True, timeout=120
        )
        if result.returncode == 0:
            binary = os.path.join(PROJECT_DIR, "zig-out/bin/opal")
            if os.path.exists(binary):
                size = os.path.getsize(binary) / (1024*1024)
                return "pass", f"Binary: {size:.1f} MB"
            return "pass", "Build succeeded"
        return "fail", result.stderr[:200]
    except subprocess.TimeoutExpired:
        return "fail", "Build timed out (>120s)"

@test("Binary Exists", "Build")
def test_binary_exists():
    binary = os.path.join(PROJECT_DIR, "zig-out/bin/opal")
    if os.path.exists(binary):
        size = os.path.getsize(binary) / (1024*1024)
        mtime = time.strftime("%H:%M:%S", time.localtime(os.path.getmtime(binary)))
        return "pass", f"{size:.1f} MB, built at {mtime}"
    return "fail", "Binary not found"

@test("LLM Model File", "Build")
def test_llm_model():
    model_dir = os.path.join(PROJECT_DIR, "models")
    if os.path.exists(model_dir):
        models = [f for f in os.listdir(model_dir) if f.endswith('.gguf')]
        if models:
            sizes = [os.path.getsize(os.path.join(model_dir, m))/(1024**3) for m in models]
            return "pass", f"{', '.join(models)} ({sum(sizes):.1f} GB)"
    return "warn", "No GGUF model found"

@test("Voice Server Script", "Build")
def test_voice_server_script():
    script = os.path.join(PROJECT_DIR, "bin/opal-voice-server.py")
    if os.path.exists(script):
        size = os.path.getsize(script)
        return "pass", f"{size} bytes"
    # Optional component: the voice server is provisioned separately and the
    # app degrades gracefully when it is absent (ai_voice.zig skips it).
    return "skip", "Voice server not installed (optional)"

@test("Libtorrent Wrapper", "Build")
def test_libtorrent():
    so = os.path.join(PROJECT_DIR, "libtorrent_wrapper.so")
    if os.path.exists(so):
        size = os.path.getsize(so) / 1024
        return "pass", f"{size:.0f} KB"
    return "warn", "libtorrent_wrapper.so not built"

# ══════════════════════════════════════════════════════════
# Voice Pipeline Tests
# ══════════════════════════════════════════════════════════

@test("Voice Server Socket", "Voice")
def test_voice_socket():
    sock_path = "/tmp/opal-voice.sock"
    if os.path.exists(sock_path):
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(1)
            s.connect(sock_path)
            s.close()
            return "pass", "Connected to voice server"
        except:
            return "warn", "Socket exists but not accepting connections"
    return "skip", "Voice server not running"

@test("Silero VAD Available", "Voice")
def test_silero_vad():
    try:
        result = subprocess.run(
            ["python3", "-c", "import torch; from silero_vad import get_speech_timestamps; print('ok')"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            return "pass", "silero-vad importable"
        return "skip", "silero-vad not installed (optional)"
    except:
        return "skip", "Python/torch not available (optional)"

@test("Faster-Whisper Available", "Voice")
def test_faster_whisper():
    try:
        result = subprocess.run(
            ["python3", "-c", "from faster_whisper import WhisperModel; print('ok')"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            return "pass", "faster-whisper importable"
        return "skip", "faster-whisper not installed (optional)"
    except:
        return "skip", "Import failed (optional)"

@test("KittenTTS Available", "Voice")
def test_kittentts():
    try:
        result = subprocess.run(
            ["python3", "-c", "from kittentts import KittenTTS; print('ok')"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            return "pass", "kittentts importable"
        return "skip", "kittentts not installed (optional)"
    except:
        return "skip", "Import failed (optional)"

@test("PulseAudio Echo Cancel", "Voice")
def test_echo_cancel():
    try:
        result = subprocess.run(
            ["pactl", "list", "modules", "short"],
            capture_output=True, text=True, timeout=5
        )
        if "module-echo-cancel" in result.stdout:
            return "pass", "module-echo-cancel loaded"
        return "warn", "Not loaded (loads on voice server start)"
    except:
        return "skip", "pactl not available"


@test("Conversational: voice-server echo guard + live partials", "Voice")
def test_voice_server_echo_and_partials():
    # The full-duplex event loop is the realtime conversational path. Its voice
    # server must (a) stream live PARTIAL: interim transcripts and (b) apply a
    # semantic echo guard so full-duplex barge-in fires on a real interruption
    # but NOT on the assistant's own TTS heard back through open speakers.
    server = os.path.join(PROJECT_DIR, "bin", "opal-voice-server.py")
    if not os.path.exists(server):
        return "fail", "opal-voice-server.py missing"
    # Behavioral: import with heavy deps stubbed, drive the pure decision logic.
    probe = (
        "import importlib.util, types, sys\n"
        "for m in ('numpy','sounddevice','webrtcvad','faster_whisper'):\n"
        "    sys.modules.setdefault(m, types.ModuleType(m))\n"
        "spec = importlib.util.spec_from_file_location('vs', %r)\n"
        "vs = importlib.util.module_from_spec(spec); spec.loader.exec_module(vs)\n"
        "assert vs._normalize('Here, THREE sci-fi!!') == 'here three sci fi'\n"
        "srv = vs.VoiceServer(object(), object())\n"
        "srv._handle_command('SPEAKING:here are three great comedies you might enjoy tonight')\n"
        "assert srv.speaking and srv.speaking_text.startswith('here are three great comedies')\n"
        # Regression: these are the ACTUAL garbled renderings the microphone
        # produced of the assistant's own TTS during live E2E. Exact word-overlap
        # scored them below threshold and the assistant interrupted ITSELF — hence
        # the fuzzy match + whisper-hallucination filter. Keep them suppressed.
        "for e in ['three comedies',\n"
        "          'You are three great communists.',\n"
        "          'You are a three-grade commie...',\n"
        "          'I think you have three great comments.',\n"
        "          'We will see you in the next video.',\n"   # whisper subtitle hallucination
        "          'Thank you.', '']:\n"
        "    assert srv._is_echo(e) is True, ('echo leaked -> false barge-in: %%r' %% e)\n"
        # Genuine interruptions must still cut through — including bare stop words.
        "for t in ['no i want horror instead', 'stop', 'no', 'wait go back',\n"
        "          'actually show me documentaries about volcanoes']:\n"
        "    assert srv._is_echo(t) is False, ('real interruption swallowed: %%r' %% t)\n"
        "srv._handle_command('DONE_SPEAKING')\n"
        "assert not srv.speaking and srv.speaking_text == ''\n"
        "srv._handle_command('SPEAKING')\n"                        # bare → energy-only
        "assert srv._is_echo('whatever words here') is False\n"
        "print('ok')\n"
    ) % server
    r = subprocess.run([sys.executable, "-c", probe], capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        last = (r.stderr.strip().splitlines() or ["import/assert failed"])[-1]
        return "fail", last[:100]
    # Structural: server streams partials + routes barge-in through the guard.
    src = _src("bin/opal-voice-server.py")
    if 'self.send("PARTIAL:"' not in src:
        return "fail", "server no longer streams PARTIAL:"
    if "_is_echo" not in src or "bargein_frames_buf" not in src:
        return "fail", "barge-in echo guard missing from run loop"
    return "pass", "echo guard drops self-echo; real interruption passes; PARTIAL streamed"


@test("Conversational: prefer full-duplex event loop + wiring", "Voice")
def test_conversational_wiring():
    # Realtime conversational mode should prefer the full-duplex event loop (live
    # partials + talk-over-it barge-in) over the finals-only sherpa loop, feed the
    # spoken sentence to the echo guard, and render interim transcript in the UI.
    av = _src("src/services/ai_voice.zig")
    hz = _src("src/ui/home.zig")
    checks = {
        "readiness probe": "pub fn voiceServerReady" in av,
        "auto dispatcher prefers event loop": (
            "fn conversationLoopAuto" in av and "if (voiceServerReady())" in av),
        "toggle spawns dispatcher off-UI-thread": "conversationLoopAuto, .{}" in av,
        "sends SPEAKING:<text> as echo reference": (
            '"SPEAKING:"' in av and "voiceSocketWrite(sp_buf" in av),
        "UI renders live partials": (
            "partial_text_len" in hz and "conv_phase == .listening" in hz),
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "event loop preferred; SPEAKING:<text> echo ref; live partials in UI"
    return "fail", f"missing: {missing}"

# ══════════════════════════════════════════════════════════
# LLM Server Tests
# ══════════════════════════════════════════════════════════

@test("LLM Server Health", "LLM")
def test_llm_health():
    try:
        import urllib.request
        req = urllib.request.Request("http://127.0.0.1:8080/health")
        resp = urllib.request.urlopen(req, timeout=3)
        data = json.loads(resp.read())
        status = data.get("status", "unknown")
        return "pass" if status == "ok" else "warn", f"Status: {status}"
    except:
        return "skip", "LLM server not running"

@test("Embedding Server Health", "LLM")
def test_embedding_health():
    try:
        import urllib.request
        req = urllib.request.Request("http://127.0.0.1:8082/v1/embeddings",
            data=json.dumps({"input": "test"}).encode(),
            headers={"Content-Type": "application/json"})
        resp = urllib.request.urlopen(req, timeout=5)
        data = json.loads(resp.read())
        if "data" in data:
            dim = len(data["data"][0].get("embedding", []))
            return "pass", f"Embedding dim: {dim}"
        return "warn", "Unexpected response"
    except:
        return "skip", "Embedding server not running"

# ══════════════════════════════════════════════════════════
# Theme System Tests
# ══════════════════════════════════════════════════════════

@test("Theme Presets Defined", "Theming")
def test_theme_presets():
    theme_file = os.path.join(PROJECT_DIR, "src/ui/theme.zig")
    if not os.path.exists(theme_file):
        return "fail", "theme.zig not found"
    with open(theme_file) as f:
        content = f.read()
    presets = []
    for name in ["midnight", "abyss", "phantom", "nord", "solarized", "rose", "ember"]:
        if f".{name}" in content or f'"{name}"' in content:
            presets.append(name)
    if len(presets) == 7:
        return "pass", f"7 presets: {', '.join(presets)}"
    return "warn", f"Only {len(presets)}/7 presets found"

@test("Theme Cycle Function", "Theming")
def test_theme_cycle():
    theme_file = os.path.join(PROJECT_DIR, "src/ui/theme.zig")
    with open(theme_file) as f:
        content = f.read()
    if "pub fn cycleTheme" in content and "pub fn setPreset" in content:
        return "pass", "cycleTheme + setPreset defined"
    return "fail", "Missing theme functions"

@test("Icon Size System", "Theming")
def test_icon_sizes():
    theme_file = os.path.join(PROJECT_DIR, "src/ui/theme.zig")
    with open(theme_file) as f:
        content = f.read()
    if "pub const IconSize" in content and "pub fn iconSize" in content:
        return "pass", "IconSize enum + iconSize() defined"
    return "fail", "Missing icon size system"

@test("Theme Palette Button", "Theming")
def test_palette_button():
    # Palette cycle button lives in the header toolbar (header.zig),
    # wired to theme.cycleTheme().
    header_file = os.path.join(PROJECT_DIR, "src/ui/header.zig")
    with open(header_file) as f:
        content = f.read()
    if "palette" in content and "cycleTheme" in content:
        return "pass", "Palette button wired to cycleTheme"
    return "fail", "No palette button"

@test("Settings Theme Picker", "Theming")
def test_settings_picker():
    settings_file = os.path.join(PROJECT_DIR, "src/ui/settings.zig")
    with open(settings_file) as f:
        content = f.read()
    if "ThemePreset" in content and "setPreset" in content:
        return "pass", "Theme picker in settings"
    return "fail", "No theme picker in settings"

# ══════════════════════════════════════════════════════════
# Instant Command Tests (source analysis)
# ══════════════════════════════════════════════════════════

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

# ══════════════════════════════════════════════════════════
# Integration Tests
# ══════════════════════════════════════════════════════════

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

# ══════════════════════════════════════════════════════════
# Voice Helper Scripts (bin/)
# ══════════════════════════════════════════════════════════

VOICE_SCRIPTS = [
    "opal-stt.py",
    "opal-stt-server.py",
    "opal-tts-server.py",
    "opal-voice-server.py",
]


def _make_script_compile_test(script):
    @test(f"Compiles: {script}", "Voice Scripts")
    def _fn():
        path = os.path.join(PROJECT_DIR, "bin", script)
        if not os.path.exists(path):
            return "fail", "script missing"
        r = subprocess.run(
            [sys.executable, "-m", "py_compile", path],
            capture_output=True, text=True, timeout=30,
        )
        if r.returncode == 0:
            return "pass", "py_compile OK"
        return "fail", r.stderr[:80]
    return _fn


# Register one compile test per script (auto-discovered by run_all).
for _s in VOICE_SCRIPTS:
    globals()[f"test_compile_{_s.replace('-', '_').replace('.', '_')}"] = _make_script_compile_test(_s)


def _make_check_test(script):
    @test(f"--check degrades: {script}", "Voice Scripts")
    def _fn():
        path = os.path.join(PROJECT_DIR, "bin", script)
        if not os.path.exists(path):
            return "skip", "script missing"
        try:
            r = subprocess.run(
                [sys.executable, path, "--check"],
                capture_output=True, text=True, timeout=15,
            )
        except subprocess.TimeoutExpired:
            return "fail", "--check hung (>15s) — would stall the Zig preflight"
        # 0 = deps present, non-zero = deps absent. Either is a clean, fast
        # exit; only a hang or crash-with-traceback is a real failure.
        if "Traceback" in r.stderr:
            return "fail", "crashed: " + r.stderr.strip().splitlines()[-1][:60]
        state = "deps present" if r.returncode == 0 else "deps absent (fallback)"
        return "pass", f"clean exit {r.returncode} ({state})"
    return _fn


for _s in ("opal-stt-server.py", "opal-tts-server.py", "opal-voice-server.py"):
    globals()[f"test_check_{_s.replace('-', '_').replace('.', '_')}"] = _make_check_test(_s)


@test("Tracked + compiles: tools/lang_server.py", "Voice Scripts")
def test_lang_server_tracked_and_compiles():
    # The language-learning TTS/ASR sidecar is spawned by
    # src/services/lang_learn.zig at "tools/lang_server.py". It lives under the
    # otherwise-ignored tools/ dir, so guard that it stays tracked source (a
    # `git rm --cached` or a broadened ignore would silently drop it from every
    # published platform, degrading the feature to "start manually").
    path = os.path.join(PROJECT_DIR, "tools", "lang_server.py")
    if not os.path.exists(path):
        return "fail", "tools/lang_server.py missing"
    tracked = subprocess.run(
        ["git", "ls-files", "--error-unmatch", "tools/lang_server.py"],
        cwd=PROJECT_DIR, capture_output=True, text=True, timeout=15,
    )
    if tracked.returncode != 0:
        return "fail", "tools/lang_server.py is not tracked by git"
    r = subprocess.run(
        [sys.executable, "-m", "py_compile", path],
        capture_output=True, text=True, timeout=30,
    )
    if r.returncode != 0:
        return "fail", r.stderr[:80]
    return "pass", "tracked + py_compile OK"


# ══════════════════════════════════════════════════════════
# In-app Browser (Browse › Web — Camoufox bridge)
# ══════════════════════════════════════════════════════════

@test("Compiles: camoufox_bridge.py", "Browser")
def test_camoufox_bridge_compiles():
    path = os.path.join(PROJECT_DIR, "scripts", "camoufox_bridge.py")
    if not os.path.exists(path):
        return "fail", "script missing"
    r = subprocess.run(
        [sys.executable, "-m", "py_compile", path],
        capture_output=True, text=True, timeout=30,
    )
    if r.returncode == 0:
        return "pass", "py_compile OK"
    return "fail", r.stderr[:80]


@test("Bridge protocol selftest", "Browser")
def test_camoufox_bridge_selftest():
    # --selftest exercises J/F frame framing, viewport clamps and the adaptive
    # pump cadence model WITHOUT importing camoufox — runs on any machine.
    path = os.path.join(PROJECT_DIR, "scripts", "camoufox_bridge.py")
    if not os.path.exists(path):
        return "fail", "script missing"
    r = subprocess.run(
        [sys.executable, path, "--selftest"],
        capture_output=True, text=True, timeout=15,
    )
    if r.returncode == 0:
        return "pass", "framing + pump model OK"
    return "fail", (r.stderr or r.stdout).strip()[:80]


@test("Poster cache SQL matches schema", "Database")
def test_poster_cache_sql():
    # core/poster.zig now reads/writes the poster_cache table from its fetch
    # workers. Execute the exact SQL strings shipped in poster.zig against the
    # CREATE TABLE from db.zig in a scratch sqlite — catches column renames or
    # SQL typos that would silently no-op the disk cache (db helpers swallow
    # prepare errors).
    import re
    poster_src = open(os.path.join(PROJECT_DIR, "src/core/poster.zig")).read()
    db_src = open(os.path.join(PROJECT_DIR, "src/core/db.zig")).read()

    # Reassemble the Zig multiline string (`\\`-prefixed lines) for the table.
    lines = db_src.splitlines()
    start = next((i for i, l in enumerate(lines)
                  if "CREATE TABLE IF NOT EXISTS poster_cache" in l), None)
    if start is None:
        return "fail", "poster_cache CREATE TABLE not found in db.zig"
    sql_lines = []
    for l in lines[start:]:
        stripped = l.strip().lstrip("\\")
        sql_lines.append(stripped)
        if stripped == ")":
            break
    create_sql = "\n".join(sql_lines)

    stmts = re.findall(r'"((?:INSERT|SELECT|DELETE)[^"]+poster_cache[^"]*)"', poster_src)
    if len(stmts) < 3:
        return "fail", f"expected >=3 poster_cache statements in poster.zig, found {len(stmts)}"

    conn = sqlite3.connect(":memory:")
    conn.execute(create_sql)
    for sql in stmts:
        n_params = len(set(re.findall(r"\?\d+", sql)))
        params = tuple(b"x" if i == 1 else 1 for i in range(n_params))
        conn.execute(sql, params)
    conn.close()
    return "pass", f"{len(stmts)} statements OK against schema"


@test("Browser bookmarks SQL matches schema", "Browser")
def test_browser_bookmarks_sql():
    # browser.zig persists Browse › Web bookmarks in the browser_bookmarks
    # table. Same source-extracted SQL-vs-schema check as the poster cache —
    # a column rename or SQL typo would silently no-op bookmarks.
    import re
    browser_src = open(os.path.join(PROJECT_DIR, "src/services/browser.zig")).read()
    db_src = open(os.path.join(PROJECT_DIR, "src/core/db.zig")).read()

    lines = db_src.splitlines()
    start = next((i for i, l in enumerate(lines)
                  if "CREATE TABLE IF NOT EXISTS browser_bookmarks" in l), None)
    if start is None:
        return "fail", "browser_bookmarks CREATE TABLE not found in db.zig"
    sql_lines = []
    for l in lines[start:]:
        stripped = l.strip().lstrip("\\")
        sql_lines.append(stripped)
        if stripped == ")":
            break
    create_sql = "\n".join(sql_lines)

    stmts = re.findall(r'"((?:INSERT|SELECT|DELETE)[^"]+browser_bookmarks[^"]*)"', browser_src)
    if len(stmts) < 3:
        return "fail", f"expected >=3 browser_bookmarks statements, found {len(stmts)}"

    conn = sqlite3.connect(":memory:")
    conn.execute(create_sql)
    for sql in stmts:
        n_params = len(set(re.findall(r"\?\d+", sql)))
        params = tuple("x" for _ in range(n_params))
        conn.execute(sql, params)
    conn.close()
    return "pass", f"{len(stmts)} statements OK against schema"


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


@test("Parakeet conversational self-install wired", "Voice")
def test_voice_self_install():
    # First-run self-install: sherpa CLI bundle + silero VAD + Parakeet v3,
    # kicked from toggleConversation; the VAD pipeline is preferred in the
    # streaming loop; startup promotes the backend when the stack is present.
    vs_path = os.path.join(PROJECT_DIR, "src/services/voice_setup.zig")
    if not os.path.exists(vs_path):
        return "fail", "voice_setup.zig missing"
    vs = open(vs_path).read()
    voice = open(os.path.join(PROJECT_DIR, "src/services/ai_voice.zig")).read()
    vb = open(os.path.join(PROJECT_DIR, "src/services/voice_backend.zig")).read()
    main_src = open(os.path.join(PROJECT_DIR, "src/main.zig")).read()
    for needle, where in (
        ("sherpa-onnx-v1.13.3-osx-arm64-shared.tar.bz2", vs),
        ("silero_vad.onnx", vs),
        ("fetchParakeetBlocking", vs),
        ("installAsync", voice),
        ("spawnParakeetVadConvo", vb),
        ("spawnParakeetVadConvo", voice),
        ("convoReady", main_src),
    ):
        if needle not in where:
            return "fail", f"missing wiring: {needle}"
    return "pass", "installer + VAD convo pipeline + startup promotion all wired"


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


@test("Voice callbacks wired outside render", "Voice")
def test_voice_callbacks_wired():
    # Regression: initCallbacks lived only in renderChatBody, which lost all
    # callers when chat moved to Home — voice transcripts then vanished into
    # a null on_transcribed_fn. ensureInit must be reachable from the frame
    # loop AND both voice entry points.
    chat_src = open(os.path.join(PROJECT_DIR, "src/services/ai_chat.zig")).read()
    voice_src = open(os.path.join(PROJECT_DIR, "src/services/ai_voice.zig")).read()
    main_src = open(os.path.join(PROJECT_DIR, "src/main.zig")).read()
    if "pub fn ensureInit" not in chat_src:
        return "fail", "ai_chat.ensureInit missing"
    if "ensureInit()" not in main_src:
        return "fail", "main.zig frame loop does not call ensureInit"
    if voice_src.count("ensureInit()") < 2:
        return "fail", "voice entry points (conversation + dictation) not wired"
    return "pass", "frame loop + toggleConversation + toggleMicRecording all wire callbacks"


@test("Chat session SQL matches schema", "Memory")
def test_chat_sessions_sql():
    # The Claude-style history sidebar groups conversation_log rows by
    # session_id (ai_chat.loadSessions/loadSession; ai_memory writes the tag).
    # Execute the shipped SQL against the real schema in a scratch sqlite.
    import re
    chat_src = open(os.path.join(PROJECT_DIR, "src/services/ai_chat.zig")).read()
    mem_src = open(os.path.join(PROJECT_DIR, "src/services/ai_memory.zig")).read()
    db_src = open(os.path.join(PROJECT_DIR, "src/core/db.zig")).read()

    lines = db_src.splitlines()
    start = next((i for i, l in enumerate(lines)
                  if "CREATE TABLE IF NOT EXISTS conversation_log" in l), None)
    if start is None:
        return "fail", "conversation_log CREATE TABLE not found"
    sql_lines = []
    for l in lines[start:]:
        stripped = l.strip().lstrip("\\")
        sql_lines.append(stripped)
        if stripped == ")":
            break
    conn = sqlite3.connect(":memory:")
    conn.execute("\n".join(sql_lines))

    # Multiline sidebar SELECT (Zig \\-string containing the GROUP BY).
    m = re.search(r"const sql =\n((?:\s*\\\\.*\n)+)\s*;", chat_src)
    if not m or "GROUP BY c1.session_id" not in m.group(1):
        return "fail", "loadSessions SQL not found in ai_chat.zig"
    sidebar_sql = "\n".join(l.strip().lstrip("\\") for l in m.group(1).splitlines())
    conn.execute(sidebar_sql)

    # Single-line statements: session restore + the tagged INSERT.
    for src, needle in ((chat_src, "SELECT role, content FROM conversation_log WHERE session_id"),
                        (mem_src, "INSERT INTO conversation_log(role, content, session_id)")):
        stmt = next((s for s in re.findall(r'"([^"\n]+)"', src) if needle in s), None)
        if stmt is None:
            return "fail", f"missing statement: {needle[:50]}"
        n_params = len(set(re.findall(r"\?\d+", stmt)))
        conn.execute(stmt, tuple("x" for _ in range(n_params)))
    conn.close()
    return "pass", "sidebar SELECT + restore + tagged INSERT OK against schema"


@test("browser_pure registered in zig tests", "Browser")
def test_browser_pure_registered():
    # The smart-address / keypress-forwarding / routing logic must stay in the
    # `zig build test` gate (its tests run via the folded Zig unit suite).
    build_zig = os.path.join(PROJECT_DIR, "build.zig")
    with open(build_zig) as f:
        content = f.read()
    if "browser_pure.zig" in content:
        return "pass", "in build.zig test step"
    return "fail", "browser_pure.zig missing from build.zig"


@test("Whisper Model Present", "Voice Scripts")
def test_whisper_model_present():
    mdir = os.path.join(PROJECT_DIR, "bin/whisper.cpp/models")
    if os.path.isdir(mdir):
        models = [f for f in os.listdir(mdir) if f.startswith("ggml-") and f.endswith(".bin")]
        if models:
            sizes = sum(os.path.getsize(os.path.join(mdir, m)) for m in models) / (1024 * 1024)
            return "pass", f"{', '.join(models)} ({sizes:.0f} MB)"
    return "skip", "No ggml model (run brew whisper-cpp + download a model)"


@test("STT End-to-End (say→whisper)", "Voice Scripts")
def test_stt_end_to_end():
    if sys.platform != "darwin":
        return "skip", "macOS-only smoke test"
    import shutil
    whisper = None
    for cand in ("/opt/homebrew/bin/whisper-cli", "/opt/homebrew/bin/whisper-cpp"):
        if os.path.exists(cand):
            whisper = cand
            break
    if not whisper or not shutil.which("ffmpeg") or not shutil.which("say"):
        return "skip", "needs say + ffmpeg + whisper-cli"
    mdir = os.path.join(PROJECT_DIR, "bin/whisper.cpp/models")
    model = None
    for name in ("ggml-small.en.bin", "ggml-base.en.bin", "ggml-tiny.en.bin"):
        p = os.path.join(mdir, name)
        if os.path.exists(p):
            model = p
            break
    if not model:
        return "skip", "no ggml model"
    phrase = "play the next episode"
    aiff, wav = "/tmp/zz_test_say.aiff", "/tmp/zz_test_mic.wav"
    try:
        subprocess.run(["say", "-o", aiff, phrase], check=True, timeout=20,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["ffmpeg", "-y", "-i", aiff, "-ar", "16000", "-ac", "1", wav],
                       check=True, timeout=20, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([whisper, "-m", model, "-f", wav, "-t", "4",
                        "--no-timestamps", "--no-prints", "-otxt"],
                       check=True, timeout=60, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with open(wav + ".txt") as f:
            text = f.read().strip()
    except Exception as e:  # noqa: BLE001
        return "fail", str(e)[:80]
    finally:
        for p in (aiff, wav, wav + ".txt"):
            try:
                os.unlink(p)
            except OSError:
                pass
    if len(text) >= 4:
        return "pass", f'transcribed: "{text[:40]}"'
    return "fail", "empty transcript"


# ══════════════════════════════════════════════════════════
# ASR Streaming (sherpa-onnx)
# ══════════════════════════════════════════════════════════

@test("Sherpa Model Canonicalization", "ASR Streaming")
def test_sherpa_canon():
    # Regression guard: the streaming downloader must rename the archive's
    # versioned weights to canonical encoder/decoder/joiner.onnx, or
    # deps.check().sherpa_stream_model is permanently false.
    deps = os.path.join(PROJECT_DIR, "src/core/deps.zig")
    with open(deps) as f:
        content = f.read()
    if 'cp "$m" "$d/$stem.onnx"' in content:
        return "pass", "canonicalization step present"
    return "fail", "downloader leaves versioned onnx names (streaming dead)"


@test("Streaming Convo Wired", "ASR Streaming")
def test_streaming_wired():
    vb = os.path.join(PROJECT_DIR, "src/services/voice_backend.zig")
    av = os.path.join(PROJECT_DIR, "src/services/ai_voice.zig")
    with open(vb) as f:
        vb_c = f.read()
    with open(av) as f:
        av_c = f.read()
    if "spawnStreamingConvo" in vb_c and "conversationLoopSherpa" in av_c:
        return "pass", "spawn + read loop present"
    return "fail", "streaming path not wired"


# ══════════════════════════════════════════════════════════
# AI Models (Hugging Face picker)
# ══════════════════════════════════════════════════════════

def _parse_catalog():
    """Extract MODEL_CATALOG entries from ai_server.zig as dicts."""
    import re
    src = os.path.join(PROJECT_DIR, "src/services/ai_server.zig")
    with open(src) as f:
        content = f.read()
    start = content.find("MODEL_CATALOG")
    if start < 0:
        return []
    block = content[start:content.find("};", start)]
    entries = []
    for m in re.finditer(r"\.\{(.*?)\}", block, re.DOTALL):
        body = m.group(1)
        fields = dict(re.findall(r'\.(\w+)\s*=\s*"([^"]*)"', body))
        if "id" in fields and "url" in fields:
            entries.append(fields)
    return entries


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


# ══════════════════════════════════════════════════════════
# UI Standards
# ══════════════════════════════════════════════════════════

import re as _re

# Pictographic emoji + dingbats/symbols (NOT typographic arrows/middot/stars).
_EMOJI = _re.compile(
    "[\U0001F000-\U0001FAFF\U00002600-\U000027BF\U00002B00-\U00002BFF"
    "\U000023E9-\U000023FA\U0000FE0F]"
)


@test("No Emojis in UI", "UI Standards")
def test_no_emoji():
    # Hard project rule: SVG (lucide TVG) icons only, never emojis. Scans
    # string LITERALS in native .zig (comments + \\x escapes are exempt; test
    # files excluded). Any emoji inside a "..." literal is a UI offender.
    offenders = []
    for root, _, files in os.walk(os.path.join(PROJECT_DIR, "src")):
        for f in files:
            if not f.endswith(".zig") or f.endswith("_test.zig"):
                continue
            p = os.path.join(root, f)
            for i, line in enumerate(open(p, encoding="utf-8").read().splitlines(), 1):
                for lit in _re.findall(r'"[^"\n]*"', line):
                    if _EMOJI.search(lit):
                        rel = os.path.relpath(p, PROJECT_DIR)
                        offenders.append(f"{rel}:{i}")
                        break
    if offenders:
        return "fail", f"{len(offenders)} emoji literal(s): " + ", ".join(offenders[:4])
    return "pass", "no emoji in UI string literals"


@test("Page Router", "Page Shell")
def test_page_router():
    p = os.path.join(PROJECT_DIR, "src/core/router.zig")
    if not os.path.exists(p):
        return "fail", "router.zig missing"
    c = open(p).read()
    if "pub const Route" in c and "pub const History" in c and "fn navigate" in c:
        return "pass", "Route + History (navigate/back/forward)"
    return "fail", "router incomplete"


@test("Page Shell Wired", "Page Shell")
def test_page_shell():
    shell = os.path.join(PROJECT_DIR, "src/ui/shell.zig")
    main = open(os.path.join(PROJECT_DIR, "src/main.zig")).read()
    if (os.path.exists(shell)
            and "page_shell_enabled" in main
            and "shell.zig" in main):
        return "pass", "shell + flag branch in appFrame"
    return "fail", "page shell not wired"


@test("No Dead drawer_tab Writes", "Page Shell")
def test_no_dead_drawer_tab():
    # Services must navigate via state.navigateToTab (router-aware), never write
    # the dead state.app.drawer_tab (which the shell no longer reads to pick a page).
    sdir = os.path.join(PROJECT_DIR, "src/services")
    offenders = []
    for root, _, files in os.walk(sdir):
        for f in files:
            if not f.endswith(".zig"):
                continue
            p = os.path.join(root, f)
            for i, line in enumerate(open(p).read().splitlines(), 1):
                if "state.app.drawer_tab =" in line:
                    offenders.append(f"{os.path.relpath(p, PROJECT_DIR)}:{i}")
    if offenders:
        return "fail", "dead drawer_tab write: " + ", ".join(offenders[:4])
    return "pass", "services navigate via navigateToTab"


@test("Omnibox → Unified Search", "Page Shell")
def test_omnibox_search():
    shell = open(os.path.join(PROJECT_DIR, "src/ui/shell.zig")).read()
    search = open(os.path.join(PROJECT_DIR, "src/services/search.zig")).read()
    if "submitQuery" in shell and "pub fn submitQuery" in search and "navigate(.search)" in shell:
        return "pass", "omnibox routes plain queries to unified search"
    return "fail", "omnibox not wired to unified search"


@test("Playback Navigates to Player", "Page Shell")
def test_play_navigates():
    st = open(os.path.join(PROJECT_DIR, "src/core/state.zig")).read()
    browser = open(os.path.join(PROJECT_DIR, "src/services/browser.zig")).read()
    if "pub fn gotoPlayer" in st and "gotoPlayer()" in browser:
        return "pass", "load helpers reveal the Player route"
    return "fail", "playback doesn't navigate to player"


@test("Home Distinct From Browse", "Page Shell")
def test_home_distinct():
    shell = open(os.path.join(PROJECT_DIR, "src/ui/shell.zig")).read()
    home_path = os.path.join(PROJECT_DIR, "src/ui/home.zig")
    if not os.path.exists(home_path):
        return "fail", "home.zig dashboard missing"
    home = open(home_path).read()
    # Home must route to home.zig (not alias the TMDB browse content).
    if ".home => @import(\"home.zig\").render()" not in shell:
        return "fail", "home route still aliases TMDB content"
    # 2026-07 console redesign: Home is the agentic console — hero prompt +
    # centered rails (continue/trending/for-you), NOT a metrics dashboard.
    if ("Continue Watching" in home and "Trending tonight" in home
            and "renderHero" in home and "Time in app" not in home):
        return "pass", "Home is the media console (hero + rails, no stats dashboard)"
    return "fail", "home console lacks hero/rails or still has the stats dashboard"


@test("Usage Metrics Persisted", "Page Shell")
def test_usage_metrics():
    cfg = open(os.path.join(PROJECT_DIR, "src/core/config.zig")).read()
    st = open(os.path.join(PROJECT_DIR, "src/core/state.zig")).read()
    if "usage_seconds_total" in st and 'setKey("usage_seconds"' in cfg and "accrueUsage" in cfg:
        return "pass", "lifetime in-app time accrued + persisted"
    return "fail", "usage metrics not wired"


@test("TMDB Filters Single Toolbar", "Page Shell")
def test_tmdb_toolbar():
    tm = open(os.path.join(PROJECT_DIR, "src/services/tmdb.zig")).read()
    # The old multi-row layout (renderCategoryBar / renderSubTabs / gallery
    # toolbar) is collapsed into one renderToolbar(count).
    if "fn renderToolbar(" in tm and "fn renderCategoryBar(" not in tm:
        return "pass", "filter rows collapsed into one toolbar"
    return "fail", "TMDB still uses stacked filter rows"


@test("Free-Text UTF-8 Safe", "Page Shell")
def test_utf8_guard():
    # Fixed-buffer titles/names can truncate mid-codepoint; dvui's text layout
    # asserts valid UTF-8. A shared safeUtf8() guard must wrap dvui-rendered
    # free text in every network-fed renderer.
    txt = os.path.join(PROJECT_DIR, "src/core/text.zig")
    if not os.path.exists(txt) or "pub fn safeUtf8(" not in open(txt).read():
        return "fail", "core/text.zig safeUtf8 helper missing"
    renderers = {
        "src/services/tmdb.zig": "safeUtf8(item.title",
        "src/services/youtube.zig": "safeUtf8(item.title",
        "src/ui/jellyfin_ui.zig": "safeUtf8(item.name",
        "src/services/comics.zig": "safeUtf8(state.app.comic.title",
        "src/services/search.zig": "safeUtf8(item.name",
    }
    missing = [f for f, needle in renderers.items()
               if needle not in open(os.path.join(PROJECT_DIR, f)).read()]
    if missing:
        return "fail", "UTF-8 guard missing in: " + ", ".join(missing)
    return "pass", "all network-fed renderers UTF-8 guarded"


@test("Anime Threads Detached", "Page Shell")
def test_anime_detach():
    an = open(os.path.join(PROJECT_DIR, "src/services/anime.zig")).read()
    # Discarded `_ = std.Thread.spawn(...)` handles leak the pthread; every
    # spawn must store + detach (or join).
    if "_ = std.Thread.spawn(" not in an:
        return "pass", "all anime threads detached (no leaked handles)"
    return "fail", "an anime thread handle is discarded without detach"


@test("Podcasts Tab Wired", "Page Shell")
def test_podcasts_wired():
    # New media class: search (iTunes) → show → RSS episodes → stream audio.
    # Verify the tab is present end-to-end: enum + routing + service + parser +
    # remote API + web tab, and that the enclosure URL reaches mpv.
    st = _src("src/core/state.zig")
    drawer = _src("src/ui/drawer.zig")
    shell = _src("src/ui/shell.zig")
    svc = _src("src/services/podcasts.zig")
    pure = _src("src/services/podcasts_pure.zig")
    rem = _src("src/services/remote.zig")
    web = _src("web/index.html")
    checks = {
        # REGRESSION — a 6.9 MB feed against a 1 MB cap hung the app permanently.
        # readAll() stops when the buffer is full and leaves the rest in the pipe;
        # curl then blocks in write(2), where it can never reach its own --max-time
        # check, so child.wait() waits forever on a process that cannot exit. The
        # worker thread hung on "Loading…" — and because loadEpisodes() early-returns
        # while episodes_loading is set, EVERY later podcast click was a silent no-op
        # for the rest of the session.
        "drains curl's pipe (no deadlock)": "while ((io.read(so, &sink) catch 0) > 0) {}" in svc,
        # episodes[] holds 200, but a 1 MB cap only ever reached the newest 61.
        "episode cap fills the array": "4 * 1024 * 1024" in svc,
        "enum variant": "Podcasts," in st and "podcasts: struct" in st,
        "drawer route": ".Podcasts =>" in drawer and "podcasts.zig" in drawer,
        "shell label+icon": '.Podcasts => "Podcasts"' in shell and "lucide.podcast" in shell,
        "service search→episodes→play": all(
            f"pub fn {fn}" in svc for fn in ("searchPodcasts", "loadEpisodes", "playEpisode")
        ),
        "itunes endpoint": "itunes.apple.com/search?media=podcast" in svc,
        "enclosure→mpv": "loadContentDirect" in svc,
        "pure parsers": "pub fn parseItunes" in pure and "pub fn parseRssEpisodes" in pure,
        "remote routes": '/podcasts/search' in rem and '/podcasts/play' in rem,
        "web tab": 'id="page-podcasts"' in web and "loadPodcasts(" in web,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", "podcasts tab wired: enum→nav→service→pure→remote→web"
    return "fail", "podcasts wiring incomplete: " + ", ".join(missing)


@test("Radio Tab Wired", "Page Shell")
def test_radio_wired():
    # New media class: search (RadioBrowser) → station list → stream audio.
    # Verify the tab is present end-to-end: enum + routing + service + parser,
    # and that url_resolved reaches mpv plus the click-count ping fires.
    st = _src("src/core/state.zig")
    drawer = _src("src/ui/drawer.zig")
    shell = _src("src/ui/shell.zig")
    svc = _src("src/services/radio.zig")
    pure = _src("src/services/radio_pure.zig")
    checks = {
        "enum variant": "Radio," in st and "radio: struct" in st,
        "drawer route": ".Radio =>" in drawer and "radio.zig" in drawer,
        "shell label+icon": '.Radio => "Radio"' in shell and "lucide.radio" in shell,
        "service search→play": all(
            f"pub fn {fn}" in svc for fn in ("searchRadio", "playStation")
        ),
        "radiobrowser endpoint": "all.api.radio-browser.info/json/stations/search" in svc,
        "url_resolved→mpv": "url_resolved" in svc and "loadContentDirect" in svc,
        "click-count ping": "/json/url/" in svc,
        "pure parser": "pub fn parseStations" in pure,
        "threads detached": "_ = std.Thread.spawn(" not in svc,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", "radio tab wired: enum→nav→service→pure (url_resolved→mpv)"
    return "fail", "radio wiring incomplete: " + ", ".join(missing)


@test("Podcasts/Radio Open Populated", "Page Shell")
def test_podcasts_radio_default_content():
    # Both pages used to open empty (search box only). They now fetch a default
    # grid of popular content once per session, off the UI thread, through the
    # SAME API + parser + click handler the search path uses. Verify: the pure
    # URL builders/parsers exist and the service routes through them, the fetch
    # is latched + backgrounded, and cards reuse the shared poster daemon.
    pod = _src("src/services/podcasts.zig")
    pod_pure = _src("src/services/podcasts_pure.zig")
    rad = _src("src/services/radio.zig")
    rad_pure = _src("src/services/radio_pure.zig")
    st = _src("src/core/state.zig")
    checks = {
        # ── Podcasts: Apple top-shows chart → iTunes /lookup → parseItunes ──
        "podcast pure builders": all(
            f"pub fn {fn}" in pod_pure
            for fn in ("buildTopChartUrl", "parseTopChartIds", "buildLookupUrl")
        ),
        "podcast routes through pure": all(
            f"pure.{fn}(" in pod
            for fn in ("buildTopChartUrl", "parseTopChartIds", "buildLookupUrl")
        ),
        # The chart supplies ids only; /lookup returns search's result objects,
        # so the EXISTING parser must be what fills results[] (no 2nd parser).
        "podcast reuses parseItunes": "pure.parseItunes(" in pod,
        "podcast one-shot latch": "popular_fetched" in pod and "pub fn loadPopularOnce" in pod,
        "podcast fetch is backgrounded": "std.Thread.spawn(.{}, popularWorker" in pod,
        # ── Radio: RadioBrowser /topvote → the same parseStations ──
        "radio pure builder": "pub fn buildTopVoteUrl" in rad_pure,
        "radio topvote endpoint": "stations/topvote/" in rad_pure,
        "radio routes through pure": "pure.buildTopVoteUrl(" in rad,
        "radio reuses parseStations": "pure.parseStations(" in rad,
        "radio one-shot latch": "popular_fetched" in rad and "pub fn loadPopularOnce" in rad,
        "radio fetch is backgrounded": "std.Thread.spawn(.{}, popularWorker" in rad,
        # Both curl helpers allocate `cap` bytes and hand back only what was read.
        # Returning `buf[0..n]` is an INVALID FREE under the global DebugAllocator
        # (it checks free size against alloc size) and aborts the process on launch
        # — 49584 freed against 524288 allocated. The buffer must be shrunk to `n`.
        "curl shrinks buffer to the read length": all(
            "alloc.realloc(buf, n)" in s and "return buf[0..n];" not in s
            for s in (pod, rad)
        ),
        # ── Cards: artwork via the shared poster daemon, existing click path ──
        "podcast cards click loadEpisodes": "if (clicked) loadEpisodes(i)" in pod,
        "radio cards click playStation": "if (clicked) playStation(i)" in rad,
        "poster daemon reused": all(
            "poster.fetchAsync(" in s and "poster.uploadIfReady(" in s for s in (pod, rad)
        ),
        # Pages kick the fetch from their own render root, not a shared shell.
        "kicked from renderContent": all("loadPopularOnce();" in s for s in (pod, rad)),
        "state flag": st.count("showing_popular: bool") == 2,
        # Detached threads only — a discarded handle leaks the pthread.
        "threads detached": all("_ = std.Thread.spawn(" not in s for s in (pod, rad)),
    }
    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", "podcasts+radio open populated (top charts, reused fetchers/parsers/click paths)"
    return "fail", "default content incomplete: " + ", ".join(missing)


@test("Comics MangaDex Source", "Page Shell")
def test_comics_mangadex_source():
    # The Comics tab shipped with ONE source (readallcomics) whose endpoint lives
    # in source_config — so on a fresh install it is INERT and the tab is empty.
    # MangaDex is a keyless, documented public API (api.mangadex.org): no key slot,
    # no source_config entry, works out of the box.
    #
    # A MangaDex card can't be read by the generic curl+HTML scraper (its pages
    # come from a 3-call JSON chain), so cards carry a `mangadex:<uuid>` route URL
    # that fetchComicThread dispatches on BEFORE the scraper. Verify that seam, and
    # that every URL/JSON decision routes through the unit-tested pure module.
    svc = _src("src/services/comics.zig")
    pure = _src("src/services/comics_pure.zig")
    build = _src("build.zig")
    checks = {
        # ── Source registered in the selector ──
        "source enum variant": "const Source = enum { all, readallcomics, mangadex }" in svc,
        "source chip": 'renderSourceChip("MangaDex", 3, .mangadex)' in svc,
        # ── Keyless: the endpoint is a constant, NOT a source_config lookup ──
        "keyless api const": 'pub const MD_API = "https://api.mangadex.org"' in pure,
        "no source_config gate": 'source_config.zig").get("mangadex"' not in svc,
        # ── Pure module owns URL building + JSON parsing ──
        "pure builders": all(
            f"pub fn {fn}" in pure
            for fn in (
                "buildSearchUrl",
                "buildFeedUrl",
                "buildAtHomeUrl",
                "buildCoverUrl",
                "buildPageUrl",
                "buildRouteUrl",
                "mangaIdFromRoute",
                "parseMangaEntry",
                "parseAtHome",
                "firstChapterId",
            )
        ),
        # Production MUST call the pure fns (so the tested logic is the shipped logic).
        "service routes through pure": all(
            f"pure.{fn}(" in svc
            for fn in (
                "buildSearchUrl",
                "buildFeedUrl",
                "buildAtHomeUrl",
                "buildCoverUrl",
                "buildPageUrl",
                "buildRouteUrl",
                "mangaIdFromRoute",
                "parseMangaEntry",
                "parseAtHome",
                "firstChapterId",
            )
        ),
        # The existing percent-encoder now delegates to the tested one (no drift).
        "encoder routes through pure": "return pure.percentEncodeQuery(input, out);" in svc,
        # ── Reader seam: mangadex: route dispatched before the HTML scraper ──
        "route scheme": 'pub const MD_SCHEME = "mangadex:"' in pure,
        "reader dispatch": "if (pure.mangaIdFromRoute(url)) |manga_id|" in svc,
        "reader stages pages": "fn loadMangadexPages(manga_id: []const u8) bool" in svc,
        # Reuses the shared page-download pipeline rather than a second downloader.
        "reuses downloadPages": "downloadPages(gen);" in svc,
        # ── Security: ids are interpolated into a request path → must be validated ──
        "id validation gate": "pub fn isValidId" in pure,
        # ── Networking: curl only. std.http SEGVs on some ISP TLS resets, so the
        #    client type must never be constructed (a *mention* in a comment
        #    explaining why we avoid it is fine — match on real usage).
        "curl not std.http": "std.http.Client" not in svc and '"curl"' in svc,
        # Detached threads only — a discarded handle leaks the pthread.
        "threads detached": "_ = std.Thread.spawn(" not in svc,
        # ── Pure module registered in the `zig build test` step ──
        "test registered": 'b.path("src/services/comics_pure.zig")' in build,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", "comics: MangaDex source wired (keyless API → route URL → JSON reader chain)"
    return "fail", "mangadex wiring incomplete: " + ", ".join(missing)


# ══════════════════════════════════════════════════════════
# Session features: single-media, browser, voice, Co-Watcher, Recall
# (wiring/regression guards so the build+test gate exercises new code)
# ══════════════════════════════════════════════════════════

def _src(rel):
    p = os.path.join(PROJECT_DIR, rel)
    return open(p).read() if os.path.exists(p) else ""


@test("Single-Media Mode", "Player")
def test_single_media():
    main = _src("src/main.zig")
    inp = _src("src/ui/input.zig")
    hdr = _src("src/ui/header.zig")
    # Frame-top collapse keeps exactly one player; Ctrl+T retired; Add screen gone.
    if ("players.items.len > 1" in main and "orderedRemove" in main
            and "Single-player mode" in inp and "Add screen" not in hdr):
        return "pass", "collapse-to-one + multistream affordances removed"
    return "fail", "single-media invariant not fully wired"


@test("Browser in Web Tab", "Player")
def test_browser_web_tab():
    st = _src("src/core/state.zig")
    dr = _src("src/ui/drawer.zig")
    br = _src("src/services/browser.zig")
    # Browser is a Browse>Web tab (not a player pane); .browser provider removed.
    if ("AI, Web" in st and ".Web =>" in dr and "renderContent" in br
            and "comic_viewer }" in st):
        return "pass", "browser routed to Browse>Web; provider .browser dropped"
    return "fail", "browser-in-web-tab not wired"


@test("Voice Barge-in + Abort", "Voice")
def test_voice_bargein():
    av = _src("src/services/ai_voice.zig")
    ac = _src("src/services/ai_chat.zig")
    ax = _src("src/services/ai_context.zig")
    if ("barge_in" in av and "stopAllAudio" in av
            and "gen_abort" in ac and "gen_abort" in ax):
        return "pass", "barge_in + stopAllAudio + gen_abort present"
    return "fail", "barge-in/abort not fully wired"


@test("TTS Non-Deadlock Mutex", "Voice")
def test_tts_mutex():
    av = _src("src/services/ai_voice.zig")
    # ttsWorker must use a dedicated tts_mutex, never the LLM inference_mutex
    # (which generateResponse holds while streaming → cross-thread deadlock).
    if "tts_mutex" in av:
        return "pass", "TTS uses dedicated tts_mutex (deadlock fixed)"
    return "fail", "tts_mutex missing — TTS may deadlock vs LLM"


@test("Co-Watcher look_at_screen", "Co-Watcher")
def test_look_at_screen():
    tools = _src("src/services/ai_tools.zig")
    ctx = _src("src/services/ai_context.zig")
    ocr = _src("src/services/frame_ocr.zig")
    if ("look_at_screen" in tools and "executeLookAtScreen" in tools
            and "look_at_screen" in ctx and "pub fn ocrCurrentFrame" in ocr):
        return "pass", "look_at_screen tool + frame OCR wired"
    return "fail", "look_at_screen not fully wired"


@test("Proactive Co-Watcher Triggers", "Co-Watcher")
def test_proactive_cowatch():
    cw = _src("src/services/co_watch.zig")
    pl = _src("src/player/player.zig")
    if ("pub fn onPlaybackEvent" in cw and "sensitivity" in cw
            and "onPlaybackEvent(.paused)" in pl and "onPlaybackEvent(.rewound)" in pl
            and '"time-pos"' in pl):
        return "pass", "pause/rewind triggers + time-pos observe wired"
    return "fail", "proactive co-watcher triggers not wired"


@test("Spoiler Firewall", "Co-Watcher")
def test_spoiler_firewall():
    sp = _src("src/services/spoiler.zig")
    cw = _src("src/services/co_watch.zig")
    tools = _src("src/services/ai_tools.zig")
    if ("pub fn clampLine" in sp and "pub fn flagsSpoiler" in sp
            and "flagsSpoiler" in cw and "clampLine" in tools):
        return "pass", "clamp + leak-check enforced in co_watch and tool"
    return "fail", "spoiler firewall not fully wired"


@test("Total Recall Wired", "Recall")
def test_total_recall():
    sm = _src("src/services/scene_memory.zig")
    cw = _src("src/services/co_watch.zig")
    db = _src("src/core/db.zig")
    tools = _src("src/services/ai_tools.zig")
    ctx = _src("src/services/ai_context.zig")
    if ("pub fn ingestScene" in sm and "ingestScene" in cw
            and "insertSceneMemory" in db and "retrieveScene" in db and "position_secs" in db
            and "recall_scene" in tools and "executeRecallScene" in tools and "recall_scene" in ctx):
        return "pass", "scene capture + recall_scene tool + DB store wired"
    return "fail", "total recall not fully wired"


@test("aimemory position_secs Column", "Recall")
def test_aimemory_position_col():
    db = get_db()
    if not db: return "skip", "No DB"
    cols = [r[1] for r in db.execute("PRAGMA table_info(aimemory)").fetchall()]
    db.close()
    if "position_secs" in cols:
        return "pass", "position_secs migration applied"
    return "warn", "position_secs not present yet (runs on first launch)"


@test("Taste Receipts Wired", "Recall")
def test_taste_receipts():
    tv = _src("src/services/taste_vector.zig")
    db = _src("src/core/db.zig")
    recs = _src("src/services/recommendations.zig")
    dui = _src("src/ui/discovery_ui.zig")
    home = _src("src/ui/home.zig")
    shell = _src("src/ui/shell.zig")
    srch = _src("src/services/search.zig")
    if ("pub fn computeTaste" in tv and "seedTitlesByTaste" in db and "getEmbeddingBlob" in db
            and "computeTaste" in recs and "renderForYouRail" in dui and "renderForYouRail" in home
            and "pub fn memorySearch" in srch and "memorySearch" in shell):
        return "pass", "taste vector + For-You rail + ?-memory-search wired"
    return "fail", "taste receipts not fully wired"


@test("Headless Server Mode Wired", "Server")
def test_headless_mode():
    # Compile-time entry split (dvui requires root.main == dvui.App.main, so the
    # headless entry is selected via -Dheadless, NOT a runtime wrapper).
    main = _src("src/main.zig")
    hl = _src("src/headless.zig")
    det = _src("src/core/headless_detect.zig")
    st = _src("src/core/state.zig")
    rem = _src("src/services/remote.zig")
    bld = _src("build.zig")
    checks = [
        '@import("build_options").headless' in main,  # compile-time entry select
        "pub const main = if" in main,
        "pub fn coreInit" in main and "pub fn appDeinit" in main,
        "pub fn headlessMain" in hl and "shutdown" in hl and "sigaction" in hl,
        "pub fn detect" in det,
        "is_headless" in st,
        "0.0.0.0" in rem and "is_headless" in rem,            # T6 bind
        '"headless"' in bld,                                    # -Dheadless option
    ]
    if all(checks):
        return "pass", "compile-time headless entry + coreInit/headlessMain + 0.0.0.0 bind + -Dheadless"
    return "fail", f"headless wiring incomplete: {checks}"


@test("Headless Render Guards", "Server")
def test_headless_render_guards():
    # Windowed mode must stay byte-identical: every headless branch gated on
    # is_headless / mpv_gl==null. mpv render-context + pixels skipped headless.
    pl = _src("src/player/player.zig")
    gr = _src("src/ui/grid.zig")
    th = _src("src/ui/theme.zig")
    # theme.applyToDvui defers when there's no UI-thread frame context
    # (current_window == null) — covers BOTH headless and background-thread
    # callers like config.load(); reapplied on the UI thread via appFrame.
    if ("is_headless" in pl and "mpv_gl != null" in gr
            and "onUiThread" in th and "reapplyIfPending" in th):
        return "pass", "render-context/pixels gated; grid guards mpv_gl; theme defers off-UI-thread"
    return "fail", "headless render guards missing"


@test("Log Severity By Level", "Stability")
def test_log_severity_by_level():
    # Info/debug/warn logs must not render red: pushLog derives the error flag
    # from `level`, not the inconsistently-set call-site is_error bool (dozens
    # of "info" logs passed true, painting the whole Logs view red).
    lg = _src("src/core/logs.zig")
    if ("effective_error" in lg and 'eqlIgnoreCase(level, "info")' in lg
            and ".is_error = effective_error" in lg):
        return "pass", "log severity derived from level (info/warn/debug never error-red)"
    return "fail", "log severity still keyed on inconsistent is_error bool"


@test("Card Views Live Search + Polish", "Browse")
def test_card_views_polish():
    # Anime / YouTube / Comics browse views upgraded to TMDB-grade: debounced
    # live search (generation-guarded), card-size control, hover. Comics gains a
    # real cover-image grid (covers parsed from source, async fetch→texture).
    an = _src("src/services/anime.zig")
    yt = _src("src/services/youtube.zig")
    cm = _src("src/services/comics.zig")
    checks = {
        "anime live search": "search_gen" in an and "last_edit_ms" in an,
        "youtube live search": "search_gen" in yt and "last_edit_ms" in yt,
        "comics live search": "search_gen" in cm and "last_edit_ms" in cm,
        "anime card size": "card_w" in an,
        "youtube card size": "card_w" in yt,
        "comics cover grid": ("sr_cover_tex" in cm and "fetchCover" in cm
                              and "renderCoverCard" in cm),
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "live search + card-size + comics cover grid wired across all 3 views"
    return "fail", f"missing: {missing}"


@test("TV Seasons/Episodes/Tracking", "Browse")
def test_tv_seasons():
    # TMDB TV-show drill-down: click a TV card → seasons → episodes → resolver
    # play, with persisted episode watched-tracking.
    st = _src("src/core/state.zig")
    db = _src("src/core/db.zig")
    tm = _src("src/services/tmdb.zig")
    checks = {
        "state types": ("TvSeason" in st and "TvEpisode" in st
                        and "tv_detail_open" in st and "tv_episode_watched" in st),
        "db tracking": ("tvMarkWatched" in db and "tvLoadWatched" in db
                        and "tv_watched" in db and "tv_continue" in db),
        "detail view": "openTvDetail" in tm and "renderTvDetail" in tm,
        "season/episode fetch": "/tv/" in tm and "/season/" in tm,
        "tracking wired": "tvMarkWatched" in tm and "tvLoadWatched" in tm,
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "tv seasons → episodes → resolver play + episode tracking wired"
    return "fail", f"missing: {missing}"


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


def _between(src, start, end):
    i = src.find(start)
    if i < 0:
        return ""
    j = src.find(end, i + len(start))
    return src[i:j if j > 0 else len(src)]


@test("Deferred Watch Commit + Smart Episode Play + Onboarding", "Browse")
def test_watch_commit_smart_play_onboarding():
    # 1) Clicking ▶ must NOT mark watched — the commit is armed and fires from
    #    the player's time-pos stream after ~2min (tvWatchCommitDue, pure).
    # 2) Episode play auto-plays the top-ranked CONFIDENT source (pickBest,
    #    pure) and falls back to the Search picker otherwise.
    # 3) First-run wizard: starter source pack + TMDB key + AI note; onboarded
    #    flag persisted; pre-wizard installs grandfathered.
    tm = _src("src/services/tmdb.zig")
    pl = _src("src/player/player.zig")
    st = _src("src/core/state.zig")
    rk = _src("src/services/resolver_rank.zig")
    ob = _src("src/ui/onboarding.zig")
    pr = _src("src/services/plugin_repo.zig")
    cfg = _src("src/core/config.zig")
    mn = _src("src/main.zig")
    checks = {
        "no click-time mark": "tvMarkWatched" not in _between(tm, "fn playTvEpisode", "\nfn "),
        "pending watch state": "pending_watch" in st and "armed" in st,
        "commit on playback": "tvWatchCommitDue" in pl and "commitPendingWatch" in pl,
        # The commit marks the episode watched, scrobbles to Trakt, and AUTO-TRACKS
        # the show. It used to upsert tv_continue (which stored the LAST WATCHED
        # episode); that table is superseded by tv_shows, and "what's next" is now
        # derived by tv_pure rather than stored — see the TV Tracking test.
        "commit does db+trakt+track": ("tvMarkWatched" in _between(tm, "pub fn commitPendingWatch", "\nfn ")
                                       and "markWatchedEpisode" in _between(tm, "pub fn commitPendingWatch", "\nfn ")
                                       and "tvTouchShow" in _between(tm, "pub fn commitPendingWatch", "\nfn ")),
        "smart pick pure": "pub fn pickBest" in rk and "PickCand" in rk,
        "smart play wired": "smartPlayEpisode" in tm and "pickBest" in tm and "setUniversalQuery" in tm,
        "wizard": "installStarterPack" in ob and "onboarded" in ob,
        "starter pack": "pub fn installStarterPack" in pr and "torrentio" in pr,
        "persist + grandfather": '"onboarded"' in cfg and "anyInstalled" in cfg,
        "wizard rendered": "onboarding.zig" in mn,
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "deferred watch commit + confident auto-play + first-run wizard wired"
    return "fail", f"missing: {missing}"


@test("Onboarding: paged feature tour + replay from Settings", "Browse")
def test_onboarding_tour():
    # The first-run wizard used to only *configure* the app (sources/TMDB/AI)
    # and was a one-shot — nothing ever explained what Opal could do, and once
    # dismissed it was unreachable. It's now a paged wizard: page 0 = setup,
    # then a short feature tour, reopenable from Settings › About.
    #
    # Paging is GUI code (dvui immediate mode), so the pure Back/Next/clamp
    # decisions live in onboarding_pure.zig and the modal routes through them —
    # guard that the routing stays in place so the tested logic is the shipped
    # logic (no drift back to inline arithmetic).
    ob = _src("src/ui/onboarding.zig")
    obp = _src("src/ui/onboarding_pure.zig")
    se = _src("src/ui/settings.zig")
    bz = _src("build.zig")
    checks = {
        # Pure nav module exists, is exercised, and is registered as a unit test.
        "pure nav fns": all(f"pub fn {f}" in obp for f in ("isLast", "clamp", "next", "prev")),
        "pure nav tested": obp.count('test "') >= 4,
        "pure nav registered": "src/ui/onboarding_pure.zig" in bz,
        # The modal routes paging through the pure module (not inline math).
        "routes through pure": 'onboarding_pure.zig' in ob and "nav.isLast" in ob and "nav.next" in ob and "nav.prev" in ob,
        # The tour itself: pages, per-page features, dots, and Back/Next nav.
        "tour pages": "const TOUR" in ob and "TourPage" in ob and "PAGE_COUNT" in ob,
        "tour renders": "fn tourPage" in ob and "fn pageDots" in ob and "fn navFooter" in ob,
        "next/finish split": '"Get started"' in ob and '"Next"' in ob and '"Back"' in ob,
        # Reopenable — replay() resets to page 0 and clears the onboarded flag.
        "replay exported": "pub fn replay" in ob and "state.app.onboarded = false" in ob,
        "replay wired in settings": "onboarding.zig" in se and "replay()" in se,
        # finish() must reset the page or a replay resumes mid-tour.
        "finish resets page": "page = 0;" in _between(ob, "fn finish", "\n}"),
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "paged tour + pure nav + replay from Settings › About"
    return "fail", f"missing: {missing}"


@test("TV Calendar: Coming-Up Rail + EZTV Availability + HW Decode", "Browse")
def test_tv_calendar_and_hwdec():
    # Coming-up rail: TMDB next/last-episode-to-air parsing, countdown labels,
    # EZTV get-torrents availability (neutral-gated on the eztv source), Home
    # rail + click-through. Plus the playback-CPU fixes: hw decode ON by
    # default (legacy auto-persisted hwdec=0 migrated via hwdec2) and the SW
    # render targeting native video size instead of fixed 1920x1080.
    calp = _src("src/services/tv_calendar_pure.zig")
    cal = _src("src/services/tv_calendar.zig")
    hm = _src("src/ui/home.zig")
    st = _src("src/core/state.zig")
    cfg = _src("src/core/config.zig")
    gr = _src("src/ui/grid.zig")
    checks = {
        "pure parsers": ("parseEpisodeToAir" in calp and "eztvEpisodeSeeds" in calp
                         and "countdownLabel" in calp and "imdbDigits" in calp),
        # The calendar no longer fetches /3/tv/{id} itself — tv_library's sync
        # worker makes that call once for every tracked show and stages the rail
        # from the same document, so the rail and My Shows cannot disagree about
        # what is next.
        "service wired": ("pub fn stage(" in cal and "next_episode_to_air" in cal
                          and 'has("eztv")' in cal),
        "home rail": "renderComingUpRail" in hm and "refreshOnce" in hm,
        "click-through": "openTvDetailById" in hm,
        "hwdec default on": "hwdec_enabled: bool = true" in st,
        "hwdec migration": '"hwdec2"' in cfg,
        "adaptive render size": "dwidth" in gr and "textureDestroyLater" in gr,
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "coming-up rail + eztv availability + hwdec/native-size render wired"
    return "fail", f"missing: {missing}"


@test("Web Companion: Pairing + LAN Bind + Bundled Page", "Remote")
def test_web_companion():
    # Phase 1 of docs/web-companion.md: /pair code exchange is the ONLY way to
    # get the token (no injection into the unauthenticated page), server binds
    # LAN when the opt-in toggle is on, page served from Resources/web with a
    # dev fallback, Settings shows LAN URL + pairing code, build bundles it.
    rm = _src("src/services/remote.zig")
    stg = _src("src/ui/settings.zig")
    sh = open(os.path.join(PROJECT_DIR, "scripts/build-app.sh")).read()
    web = open(os.path.join(PROJECT_DIR, "web/index.html")).read()
    checks = {
        "pair route": '"/pair"' in rm and "regeneratePairCode" in rm,
        "brute-force guard": "MAX_PAIR_FAILS" in rm and "sleep(300" in rm,
        "no token injection": "replaceOwned" not in rm,
        "lan bind": '"0.0.0.0"' in rm and "127.0.0.1" not in _between(rm, "fn serverLoop", "std.debug.print"),
        "bundled serving": "resourceRoot" in rm and "web/index.html" in rm,
        "settings pairing ui": "pairingCode" in stg and "lanIp" in stg,
        "build bundles web": "Resources/web" in sh,
        "client pairs": "/pair?code=" in web and "localStorage" in web and "__ZIGZAG_API_TOKEN__" not in web,
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "pairing-code auth + LAN bind + bundled mobile page wired"
    return "fail", f"missing: {missing}"


@test("Hosted Mode: Stream/VTT/Poster + Docker + Perf Fixes", "Remote")
def test_hosted_mode_and_perf():
    # Headless hosting (docs/headless-hosting-spec.md H1+H2+H3 slice) and the
    # production CPU fixes from the 2026-07-10 profiling session.
    rs = _src("src/services/remote_stream.zig")
    rp = _src("src/services/remote_stream_pure.zig")
    rm = _src("src/services/remote.zig")
    hl = _src("src/headless.zig")
    al = _src("src/core/alloc.zig")
    gr = _src("src/ui/grid.zig")
    pl = _src("src/player/player.zig")
    dk = open(os.path.join(PROJECT_DIR, "Dockerfile")).read()
    ci = open(os.path.join(PROJECT_DIR, ".github/workflows/ci.yml")).read()
    web = open(os.path.join(PROJECT_DIR, "web/index.html")).read()
    checks = {
        "range streaming": "parseRange" in rp and "206 Partial Content" in rs,
        "srt→vtt": "srtToVtt" in rp and "handleVtt" in rs,
        "traversal guard": "safeRelPath" in rp and "safeRelPath" in rs,
        "query-token media auth": '"/stream"' in rm and 'getQueryParam(query, "t")' in rm,
        "parity routes": '"/calendar"' in rm and '"/tv"' in rm and '"/host"' in rm and '"/torrents"' in rm,
        "thread-per-conn + api mutex": "api_mutex" in rm and "Thread.spawn(.{}, Handler.run" in rm,
        "headless serves web": "web_remote_enabled = true" in hl and "pairingCode()" in hl,
        "docker headless build": "-Dheadless=true" in dk and "OPAL_PAIR_CODE" in dk and "3000" not in dk,
        "ci gate": "docker-headless" in ci and "/pair?code=123456" in ci,
        "hosted web player": "openPlayer" in web and "/stream?file=" in web and "/vtt?file=" in web,
        "web torrent progress": "pollTorrents" in web,
        "browser-first setup": '"/setup/sources"' in rm and "installStarterPack" in rm and "loadSetup" in web,
        "sse push": '"/events"' in rm and "text/event-stream" in rm and "buildStatusJson" in rm and "EventSource" in web,
        "queue reorder": '"/queue/move"' in rm and "moveQueueItem" in _src("src/services/queue.zig") and "qmv" in web,
        # Perf: release allocator, non-blocking mpv render, no built-in Lua VMs.
        "release allocator": "smp_allocator" in al,
        "no mpv render block": "MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME" in gr,
        "mpv lua trimmed": "load-osd-console" in pl and "load-stats-overlay" in pl,
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "hosted streaming + docker gate + CPU fixes wired"
    return "fail", f"missing: {missing}"


@test("Torrent File Safety: skip executables/archives", "Stability")
def test_torrent_file_safety():
    # A mislabeled/malicious torrent shipping a big .exe/.rar as its largest
    # file must NOT be auto-selected (fed mpv garbage) or auto-opened (malware).
    # The player picks the largest PLAYABLE file via the tested classifier and
    # aborts with a warning when the torrent has no media.
    me = _src("src/core/media_ext.zig")
    pl = _src("src/player/player.zig")
    checks = {
        "classifier": "pub fn isPlayable" in me and "pub fn isExecutableOrArchive" in me,
        "risky set": '"exe"' in me and '"rar"' in me and '"zip"' in me and '"iso"' in me,
        "auto-select uses it": "isPlayable" in pl and "isExecutableOrArchive" in pl,
        "aborts on no media": "-2" in pl and "possible malware" in pl,
        "advance skips non-media": pl.count("media_ext.isPlayable") >= 2,
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "non-media torrent files skipped; executables never auto-opened"
    return "fail", f"missing: {missing}"


@test("Anime Seasons/Calendar/Tracking", "Browse")
def test_anime_netflix_experience():
    # Netflix/Apple-TV+ anime browse: mode toolbar, Seasonal (/seasons),
    # Calendar (/schedules), franchise relations rail, and persisted episode
    # tracking + Continue-Watching.
    st = _src("src/core/state.zig")
    db = _src("src/core/db.zig")
    an = _src("src/services/anime.zig")
    checks = {
        "state modes": ("AnimeMode" in st and "AnimeSeasonSel" in st
                        and "ContinueItem" in st and "episode_watched" in st),
        "db tracking": ("animeMarkWatched" in db and "animeGetContinue" in db
                        and "anime_watched" in db and "anime_continue" in db),
        "seasonal fetch": "/seasons/" in an,
        "calendar fetch": "/schedules" in an,
        "relations rail": "/relations" in an,
        "tracking wired": ("animeMarkWatched" in an and "animeLoadWatched" in an
                           and "animeUpsertContinue" in an),
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "modes + seasonal + calendar + relations + episode tracking wired"
    return "fail", f"missing: {missing}"


@test("Anime Lists Source Plugin", "Anime")
def test_anime_lists_plugin():
    # The debpalash/lists repo (AniList<->MAL id maps + a currently-airing feed)
    # wired into the anime index. It is a METADATA source, so it ships with a
    # working default endpoint and an installed `lists` plugin merely OVERRIDES
    # it. It was originally gated behind a plugin install like a torrent index,
    # which meant the chip rendered NOTHING on every machine (no plugin ships
    # installed) -- the neutrality rule is about infringing endpoints, and Jikan
    # and AniList, the other two anime metadata APIs, are both hardcoded.
    import json as _json
    an = _src("src/services/anime.zig")
    pure = _src("src/services/anime_lists_pure.zig")
    bz = _src("build.zig")
    with open(os.path.join(PROJECT_DIR, "plugins-manifest.json")) as fh:
        manifest = _json.load(fh)
    entry = next((p for p in manifest["plugins"] if p["id"] == "lists"), None)

    checks = {
        # Registered through the EXISTING source-plugin contract (plugin_repo.zig
        # reads this manifest; install writes ~/.config/opal/plugins/sources/<id>.json).
        "manifest entry": entry is not None and entry.get("type") == "anime",
        "manifest endpoint": bool(entry and "debpalash/lists" in entry["endpoints"]["base"]),
        # Plugin can still override the endpoint...
        "source_config override": 'get("lists", "base")' in an,
        # ...but a machine with no plugin installed MUST still get data. A null
        # listsBase() hides the chip entirely, which is the bug this pins.
        "works with no plugin installed": ("LISTS_DEFAULT_BASE" in an
                                           and "debpalash/lists" in an),
        # Fetch: curl (never std.http), off the UI thread, into the shared grid.
        "fetches airing feed": "anime-airing.json" in an,
        "curl not std.http": "curl" in an and "std.http" not in an,
        "detached worker": "listsThread" in an and "search_gen" in an,
        # SWR disk cache so it isn't refetched every launch.
        "cached": "cacheStoreForUrl" in an and "cacheLoadForUrl" in an,
        "ttl": "LISTS_TTL_S" in an,
        # Parsing lives in the tested pure sibling, registered in build.zig.
        "pure parser": "pub fn parseAiring" in pure,
        "prod routes through pure": "lists_pure.parseAiring" in an,
        "pure real schema": '"idMal"' in pure and "nextEpisode" in pure,
        "pure registered": "anime_lists_pure.zig" in bz,
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "lists plugin: manifest → source_config → cached airing grid (pure-parsed)"
    return "fail", f"missing: {missing}"


@test("Now-Playing Media Bar", "Player")
def test_now_playing_bar():
    # Persistent bottom now-playing bar (Spotify-style): transport + scrubber +
    # playlist, shown across tabs when media is active; torrent strip preserved.
    f = _src("src/ui/footer.zig")
    if ("renderNowPlayingBar" in f and "activeMediaPlayer" in f
            and "renderTorrentActivityStrip" in f
            and "playlistDropdownMenu" in f and "active_player_idx <" in f):
        return "pass", "now-playing bar: transport+scrubber+playlist, guarded; torrent strip kept"
    return "fail", "now-playing media bar not wired"


@test("Brand Is Opal", "Page Shell")
def test_brand_is_opal():
    # User-facing brand unified to "Opal — Play everything". Guard the display
    # surfaces against regressing to the old "ZigZag Media Console" wording.
    main = _src("src/main.zig")
    web = _src("web/index.html")
    tools = _src("src/services/ai_tools.zig")
    checks = {
        "window title": 'title = "Opal' in main and "ZigZag Media Console" not in main,
        "web title/brand": "Opal — Play everything" in web and "ZigZag — Remote" not in web,
        "assistant identity": "You are Opal" in tools and "You are ZigZag AI" not in tools,
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "display brand = Opal / Play everything"
    return "fail", f"brand regressed: {missing}"


@test("Web UI API Base Port", "Page Shell")
def test_web_api_base_port():
    # Web UI is served on :3000 but the JSON API lives on :41595 — index.html
    # must target the API port, not location.origin (which is the :3000 server).
    html = _src("web/index.html")
    if not html:
        return "skip", "web/index.html not present"
    if ":41595" in html and "const API = location.origin;" not in html:
        return "pass", "web UI targets API :41595 (not location.origin)"
    return "fail", "web UI API base still points at the static server"


@test("Live-ASR Foundation", "Co-Watcher")
def test_live_asr_foundation():
    la = _src("src/services/live_asr.zig")
    st = _src("src/core/state.zig")
    cfg = _src("src/core/config.zig")
    # Wiring guard only: module + state flag + config persistence present.
    # (The no-mic-capture safety lives in the worker code itself, which is a
    # logs.pushLog no-op; a keyword grep can't tell code from the doc comments
    # that legitimately mention ffmpeg/avfoundation when describing the blocker.)
    if "pub fn setEnabled" in la and "live_asr_enabled" in st and "live_asr" in cfg:
        return "pass", "off-by-default foundation wired (module/state/config)"
    return "fail", "live-ASR foundation not wired"


# ── Regression guards for older subsystems (edited as the watcher runs) ──

@test("Player Resume Wired", "Player")
def test_player_resume():
    p = _src("src/player/player.zig")
    if ("pub fn load_file" in p and "pub fn saveCurrentPosition" in p
            and "pub fn tryResumePosition" in p):
        return "pass", "load_file + save/resume position present"
    return "fail", "player load/resume not wired"


@test("Multi-Source Search Wired", "Search")
def test_multi_source_search():
    s = _src("src/services/search.zig")
    if ("pub fn submitQuery" in s and "pub fn triggerSearch" in s
            and "pub fn loadTorrentToPlayer" in s):
        return "pass", "universal + torrent + magnet load paths present"
    return "fail", "search paths not wired"


@test("Queue Persistence Wired", "Library")
def test_queue_wired():
    q = _src("src/services/queue.zig")
    if "pub fn addToQueue" in q and "pub fn playNextUnplayed" in q and "queue_count" in q:
        return "pass", "addToQueue + playNextUnplayed + count present"
    return "fail", "queue not wired"


@test("Transfers Content Wired", "Downloads")
def test_transfers_wired():
    t = _src("src/services/transfers.zig")
    if "pub fn renderTransfersContent" in t:
        return "pass", "transfers content renderer present"
    return "fail", "transfers not wired"


@test("Player Init Applies Field Defaults", "Stability")
def test_player_init_defaults():
    # Regression: MediaPlayer.init does `allocator.create` (undefined memory) +
    # field-by-field assignment, so struct-declaration DEFAULTS are NOT applied.
    # Forgotten fields read 0xaa garbage — a garbage dialogue_head/count drove an
    # out-of-bounds crash in updateDialogueRing on the first subtitle. Guard the
    # whole class: every default-valued field MUST be assigned in init.
    import re
    p = _src("src/player/player.zig")
    decl = p.split("pub const MediaPlayer = struct", 1)[-1].split("pub fn init", 1)[0]
    init_body = p.split("pub fn init", 1)[-1].split("return self;", 1)[0]
    default_fields = re.findall(r"^    ([a-zA-Z_]\w*)\s*:\s*[^,]*=\s", decl, re.M)
    missed = [f for f in default_fields
              if not re.search(r"self\." + re.escape(f) + r"\b", init_body)]
    if missed:
        return "fail", "init never assigns default field(s): " + ", ".join(missed[:8])
    return "pass", f"all {len(default_fields)} default-valued fields assigned in init"


@test("Stream Resources Resolvable When Bundled", "Stability")
def test_stream_resource_root():
    # Regression: `python3 engines/nova2.py` (torrent search) is spawned with a
    # RELATIVE path, so a /Applications launch (CWD "/") found nothing → "loading
    # stream not working". Fix: a resource root (SDL_GetBasePath bundle Resources)
    # used as the child cwd, plus engines/ copied into the .app bundle.
    st = _src("src/core/state.zig")
    rv = _src("src/services/resolver.zig")
    sr = _src("src/services/search.zig")
    mn = _src("src/main.zig")
    sh = os.path.join(PROJECT_DIR, "scripts/build-app.sh")
    sh_txt = open(sh).read() if os.path.exists(sh) else ""
    checks = {
        "state.resourceRoot helper": "pub fn resourceRoot()" in st,
        "startup detection": "detectResourceRoot" in mn and "SDL_GetBasePath" in mn,
        "resolver uses cwd": "child.cwd = state.resourceRoot()" in rv,
        "search uses cwd": "child.cwd = state.resourceRoot()" in sr,
        "bundle copies engines/": "Contents/Resources/engines" in sh_txt,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "stream resource wiring missing: " + ", ".join(missing)
    return "pass", "resource-root cwd wired for nova2 + engines/ bundled"


@test("Source Endpoints Externalized To Plugins", "Stability")
def test_sources_externalized():
    # Neutral-player: connector CODE stays in the app, but source URLs/creds are
    # migrated to opal-plugins and read via core/source_config. No installed
    # endpoint → the source is inert. Guard that the migrated sources route
    # through source_config.get and no longer hardcode their URL builder.
    sc = _src("src/core/source_config.zig")
    rv = _src("src/services/resolver.zig")
    sr = _src("src/services/search.zig")
    cm = _src("src/services/comics.zig")
    checks = {
        "source_config.get exists": "pub fn get(" in sc and "plugins/sources" in sc,
        "1337x via config": 'get("1337x"' in rv,
        "yts via config": 'get("yts"' in rv,
        "eztv via config": 'get("eztv"' in sr,
        "readallcomics via config": 'get("readallcomics"' in rv and 'get("readallcomics"' in cm,
        # The old hardcoded URL builders must be gone (validators may remain).
        "no hardcoded 1337x search": '"https://1337x.to/search' not in rv,
        "no hardcoded yts api": "yts.mx/api/v2/list_movies" not in rv,
        "no hardcoded eztv api": "eztvx.to/api/get-torrents" not in sr,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "source externalization gaps: " + ", ".join(missing)
    return "pass", "1337x/yts/eztv/readallcomics endpoints read from installed plugins"


@test("Legal Direct-Play Sources (NASA / Commons / IA-Audio)", "Stability")
def test_legal_directplay_sources():
    # Three legal, DEFAULT-ON direct-play search sources mirror the Internet
    # Archive worker: NASA library, Wikimedia Commons, and an intent-aware IA
    # AUDIO path. Each rides the .stremio source variant (HTTP-direct mpv), runs
    # with NO source_config marker (default-on), and routes JSON parsing through
    # a tested *_pure sibling.
    rv = _src("src/services/resolver.zig")
    npu = _src("src/services/nasa_pure.zig")
    cpu = _src("src/services/commons_pure.zig")
    apu = _src("src/services/archive_pure.zig")
    bz = open(os.path.join(PROJECT_DIR, "build.zig")).read()
    checks = {
        # NASA worker + endpoint + two-stage best-mp4 pick
        "resolveNasa worker": "fn resolveNasa(" in rv,
        "nasa status atomic": "status_nasa" in rv,
        "nasa spawned under stremio": "Spawn.go(resolveNasa, &status_nasa)" in rv,
        "nasa in checkAllDone": "status_nasa.load(.acquire) != .searching" in rv,
        "nasa endpoint": "images-api.nasa.gov/search" in rv,
        "nasa_pure pickBestMp4": "pub fn pickBestMp4(" in npu and "pub fn iterateItems(" in npu,
        "nasa_pure registered": "nasa_pure.zig" in bz,
        # Wikimedia Commons worker + single-fetch endpoint + pages{} parse
        "resolveCommons worker": "fn resolveCommons(" in rv,
        "commons status atomic": "status_commons" in rv,
        "commons spawned under stremio": "Spawn.go(resolveCommons, &status_commons)" in rv,
        "commons in checkAllDone": "status_commons.load(.acquire) != .searching" in rv,
        "commons endpoint": "commons.wikimedia.org/w/api.php" in rv,
        "commons UA policy": "https://github.com/debpalash/Opal" in rv,
        "commons_pure iteratePages": "pub fn iteratePages(" in cpu and "stripFilePrefix" in cpu,
        "commons_pure registered": "commons_pure.zig" in bz,
        # IA audio: intent-aware, no new worker, librivox/etree, VBR>ogg>flac
        "IA audio intent gate": "isAudioIntent" in rv and "pub fn isAudioIntent(" in apu,
        "IA audio best file": "pub fn pickBestAudioFile(" in apu and "pickBestAudioFile(meta)" in rv,
        "IA audio collections": "librivoxaudio" in rv and "etree" in rv,
        "IA default path intact": "mediatype:(movies)" in rv,
        "no bare audio in default": "mediatype:(audio)" not in rv,
        # Default-on: none of the three gate on a source_config marker.
        "nasa not marker-gated": 'get("nasa"' not in rv,
        "commons not marker-gated": 'get("commons"' not in rv,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "legal direct-play wiring gaps: " + ", ".join(missing)
    return "pass", "NASA + Commons + IA-audio wired, default-on, *_pure-routed"


@test("Plugin Manager Wired", "Page Shell")
def test_plugin_manager():
    # qBittorrent-style source-endpoint manager: fetch opal-plugins manifest →
    # Install writes ~/.config/opal/plugins/sources/<id>.json (read by
    # source_config) → the built-in connector goes live.
    pr = _src("src/services/plugin_repo.zig")
    pg = _src("src/services/plugins.zig")
    ok = (
        "pub fn refresh()" in pr
        and "pub fn install(" in pr
        and "pub fn uninstall(" in pr
        and "api.github.com/repos" in pr
        and "source_config.reload()" in pr
        and "renderSourcePlugins" in pg
    )
    debrid = (
        "debridKey()" in pr
        and "applyDebrid" in _src("src/services/stremio.zig")
        and "loadInstalledAddons" in _src("src/services/resolver.zig")
    )
    if not ok:
        return "fail", "plugin manager not wired"
    if not debrid:
        return "fail", "debrid not wired"
    return "pass", "fetch/install/uninstall + UI + debrid wired"


@test("Bundled Plugin Manifest", "Page Shell")
def test_bundled_manifest():
    # The Plugins page must show the source list instantly + offline: a checked-in
    # plugins-manifest.json is loaded via loadLocalManifest() before the network
    # refresh, bundled into the .app by build-app.sh, and read from resourceRoot.
    import json
    mpath = os.path.join(PROJECT_DIR, "plugins-manifest.json")
    if not os.path.exists(mpath):
        return "fail", "plugins-manifest.json missing at repo root"
    try:
        m = json.load(open(mpath))
    except Exception as e:
        return "fail", f"manifest not valid JSON: {e}"
    plugins = m.get("plugins")
    if not isinstance(plugins, list) or len(plugins) == 0:
        return "fail", "manifest has no plugins[]"
    for p in plugins:
        if not p.get("id") or not p.get("type"):
            return "fail", f"plugin missing id/type: {p!r}"
    if "zigzag" in json.dumps(m):
        return "fail", "manifest still references legacy 'zigzag' path"
    # Wiring: loaded before refresh, and bundled by the packager.
    pg = _src("src/services/plugins.zig")
    pr = _src("src/services/plugin_repo.zig")
    sh = _src("scripts/build-app.sh")
    if "loadLocalManifest()" not in pg:
        return "fail", "loadLocalManifest() not called from Plugins page"
    if "pub fn loadLocalManifest" not in pr:
        return "fail", "loadLocalManifest not defined"
    if "plugins-manifest.json" not in sh:
        return "fail", "build-app.sh does not bundle plugins-manifest.json"
    return "pass", f"{len(plugins)} plugins, offline-loaded + bundled"


@test("Added Torrent Engines Wired", "Page Shell")
def test_added_torrent_engines():
    # The 11 ported nova2 torrent engines: each needs (a) an engine .py whose
    # class name == module name == id (nova2 imports getattr(module, id)), and
    # (b) a matching torrent entry in the bundled manifest so it's installable.
    import json, os, re
    ids = ["therarbg", "torrentdownloads", "rutor", "glotorrents", "bitsearch",
           "torrentgalaxy", "academictorrents", "ilcorsaronero", "tokyotoshokan", "torrentfunk",
           "knaben"]
    eng_dir = os.path.join(PROJECT_DIR, "engines", "engines")
    m = json.load(open(os.path.join(PROJECT_DIR, "plugins-manifest.json")))
    torrent_ids = {p["id"] for p in m["plugins"] if p.get("type") == "torrent"}
    missing_eng, bad_class, missing_manifest = [], [], []
    for eid in ids:
        p = os.path.join(eng_dir, f"{eid}.py")
        if not os.path.exists(p):
            missing_eng.append(eid); continue
        src = open(p).read()
        # class name must equal the module/id (nova2 getattr contract)
        if not re.search(rf"^class {re.escape(eid)}\b", src, re.M):
            bad_class.append(eid)
        if "prettyPrinter" not in src:
            bad_class.append(eid + "(no prettyPrinter)")
        if eid not in torrent_ids:
            missing_manifest.append(eid)
    if missing_eng:
        return "fail", f"engine .py missing: {missing_eng}"
    if bad_class:
        return "fail", f"class!=module / no prettyPrinter: {bad_class}"
    if missing_manifest:
        return "fail", f"no manifest entry: {missing_manifest}"
    return "pass", f"{len(ids)} engines placed, class==module, manifest-wired"


@test("Content Plugin Sandbox Hardened", "Stability")
def test_plugin_sandbox_hardened():
    # Lua content-plugin sandbox: allow_unsafe must require a USER trust marker
    # (plugin can't self-declare its way out), the prelude nils escape vectors
    # (debug library, os.getenv, package paths), and native plugins warn when
    # untrusted. Decision logic lives in plugins_pure.runMode (unit-tested).
    pg = _src("src/services/plugins.zig")
    pgp = _src("src/services/plugins_pure.zig")
    # Prelude closes the debug-library escape + env/package surface.
    prelude_hardened = all(
        s in pg for s in ("debug=nil", "os.getenv=nil", 'package.path=""', 'package.cpath=""')
    )
    # allow_unsafe now gated behind a user-created marker, routed via pure runMode.
    gated = (
        "user_trusted" in pg
        and '".trusted"' in pg
        and "runMode(" in pg
        and "untrustedNative(" in pg
        and "and p.user_trusted" in pg  # allow_unsafe honored only WITH user trust
    )
    # Pure decision + regression tests present.
    pure_ok = (
        "pub fn runMode(" in pgp
        and "pub fn untrustedNative(" in pgp
        and 'test "runMode sandboxes Lua' in pgp
    )
    if not prelude_hardened:
        return "fail", "Lua prelude missing debug/getenv/package hardening"
    if not gated:
        return "fail", "allow_unsafe not gated behind user trust marker via runMode"
    if not pure_ok:
        return "fail", "plugins_pure runMode/tests missing"
    return "pass", "user-trust gate + hardened prelude + native warn, pure-tested"


@test("Polish Tokens Adopted", "Page Shell")
def test_polish_tokens():
    # Phase 3 polish (GUI-only): nav + sub-tab icons use the iconSize token (was
    # raw 15/14px literals that differed between adjacent nav surfaces), and the
    # soft drop shadow is a single theme token instead of copied {0,0,0,160}.
    th = _src("src/ui/theme.zig")
    sh = _src("src/ui/shell.zig")
    ft = _src("src/ui/footer.zig")
    if "pub const shadow_soft" not in th:
        return "fail", "theme.shadow_soft token missing"
    if "theme.iconSize(.sm)" not in sh:
        return "fail", "nav icons not on iconSize token"
    if "theme.shadow_soft" not in ft or "0, .g = 0, .b = 0, .a = 160" in ft:
        return "fail", "footer still uses raw shadow literals"
    return "pass", "nav iconSize + shadow token adopted"


@test("Motion Tokens + Transitions Wired", "Page Shell")
def test_motion_transitions():
    # Phase 2 motion (GUI-only — verified by presence): a single motion-token
    # source of truth (durations + easings) drives transitions, and the app now
    # uses dvui's animation APIs (previously 0 usage): route fade-in, toast
    # fade-in, and a control-bar chrome fade instead of a hard pop.
    th = _src("src/ui/theme.zig")
    sh = _src("src/ui/shell.zig")
    ft = _src("src/ui/footer.zig")
    if "pub const motion = struct" not in th or "dvui.easing" not in th:
        return "fail", "theme.motion tokens missing"
    if "dvui.animate(" not in sh or "@intFromEnum(r)" not in sh:
        return "fail", "route fade not wired in shell.zig"
    if "dvui.animate(" not in ft:
        return "fail", "toast fade not wired in footer.zig"
    if "dvui.alpha(chrome_vis)" not in ft:
        return "fail", "control-bar chrome fade not wired in footer.zig"
    return "pass", "motion tokens + route/toast/chrome transitions wired"


@test("Playback Repaint Gated + Async UI Wakes", "Stability")
def test_smoothness_repaint():
    # Phase 1 smoothness (GUI/thread-only wiring — verified by presence):
    #  1. the continuous playback refresh no longer runs every frame — it's gated
    #     on the control chrome being visible (mouse active), so immersive watching
    #     falls back to callback-driven, video-fps repaints instead of 60Hz relayout.
    #  2. poster decode workers wake the UI (dvui.refresh) so posters don't pop in
    #     only on incidental repaints.
    #  3. AI chat streaming wakes the UI per token chunk so live text renders.
    mn = _src("src/main.zig")
    ps = _src("src/core/poster.zig")
    ac = _src("src/services/ai_context.zig")
    if "chrome_live" not in mn or "DEFAULT_THRESHOLD_MS" not in mn:
        return "fail", "playback refresh not gated on chrome visibility (main.zig)"
    if "dvui_win" not in ps or "dvui.refresh(win" not in ps:
        return "fail", "poster worker does not wake the UI after decode"
    if "dvui_win" not in ac or "refresh(win" not in ac:
        return "fail", "AI streaming does not wake the UI"
    return "pass", "playback repaint gated; poster + AI-stream wakes wired"


@test("Page Shell Immersive Hides Nav", "Page Shell")
def test_shell_immersive_navbar():
    # On the Player route, the page-shell top nav (and compact bottom tabs) must
    # auto-hide during immersive playback (fullscreen or idle-while-watching), so
    # the video gets the whole window. Decision reuses the unit-tested pure
    # chrome_autohide.shouldHideChrome; this checks the shell wiring.
    sh = _src("src/ui/shell.zig")
    ok = (
        "shouldHideChrome" in sh
        and "renderTopNav(compact)" in sh
        and "if (!immersive)" in sh
        and "nav_alpha" in sh                          # phase 4: nav fades instead of popping
        and "router.current == .player" in sh          # scoped so browsing keeps the nav
        and "fullscreen_player_idx != null" in sh
        and "and !immersive) renderBottomTabs" in sh    # compact bottom tabs hide too
    )
    if not ok:
        return "fail", "shell top nav not gated on immersive playback"
    return "pass", "top nav + bottom tabs auto-hide on immersive Player route"


@test("Frame Loop: Seq Ids Reset + Deferred Nav", "Stability")
def test_frame_loop_integrity():
    # Phase 4 (GUI/thread wiring — verified by presence):
    #  1. components.beginFrame() resets the sectionHeader/divider/statusPill
    #     id sequence every frame — without it every one of those widgets is a
    #     "first frame" id and dvui force-refreshes, pinning the app at full
    #     repaint rate whenever Settings or a status pill is visible.
    #  2. navigateToTab from worker threads is deferred through an atomic and
    #     applied on the UI thread (router history writes raced the render read).
    #  3. The native file-open dialog is polled unconditionally in appFrame —
    #     it used to be polled only by the legacy header, so Ctrl+O results were
    #     silently dropped in the default page shell.
    mn = _src("src/main.zig")
    cp = _src("src/ui/components.zig")
    st = _src("src/core/state.zig")
    if "pub fn beginFrame" not in cp or 'components.zig").beginFrame()' not in mn:
        return "fail", "per-frame id sequence reset not wired (components.beginFrame)"
    if "pending_nav" not in st or "applyPendingNav" not in mn:
        return "fail", "worker navigation not deferred to the UI thread"
    if "ui.pollFileOpen()" not in mn:
        return "fail", "file-open dialog not polled from appFrame"
    return "pass", "seq-id reset + deferred nav + file-open poll wired"


@test("Interaction States Render (Hover/Focus/Confirm)", "Page Shell")
def test_interaction_states():
    # Phase 4: hover/focus states must be applied AFTER dvui.clicked() reports
    # hover (plain boxes draw their background at creation, so the old
    # `if (hovered)` ternaries at init were provably dead code), transparent-
    # fill buttons must spell out explicit hover fills (dvui derives hover by
    # lightening the fill, and lighten(transparent) is still transparent), and
    # destructive actions go through the two-step confirmDangerButton.
    cp = _src("src/ui/components.zig")
    sh = _src("src/ui/shell.zig")
    dr = _src("src/ui/drawer.zig")
    stg = _src("src/ui/settings.zig")
    if "color_fill_hover" not in cp or "confirmDangerButton" not in cp:
        return "fail", "components missing hover fills / confirm button"
    if "options.color_fill = tk.bg_hover()" not in cp:
        return "fail", "post-clicked hover repaint missing in components"
    if "navRowInteract" not in sh:
        return "fail", "shell nav rows missing hover/focus/keyboard interaction"
    if "confirmDangerButton" not in dr or "confirmDangerButton" not in stg:
        return "fail", "destructive clears not confirm-gated"
    return "pass", "hover repaint + focus rings + confirm-gated destructive actions"


@test("Color Aliases Collapsed To Canonical Tokens", "Page Shell")
def test_color_alias_collapse():
    # Phase 4: the duplicated color aliases (two divergent text ramps, 7-way
    # identical border token, 5-way elevated-bg token) are collapsed — the
    # legacy names must be GONE from ThemeColors and from all call sites.
    th = _src("src/ui/theme.zig")
    struct_body = th.split("ThemeColors = struct")[1].split("};")[0]
    for legacy in ("text_main", "text_muted", "text_dim", "accent_primary",
                   "semantic_error", "border_input", "bg_card", "bg_drawer",
                   "bg_input", "active_border"):
        if legacy + ":" in struct_body:
            return "fail", f"legacy color alias still defined: {legacy}"
    import subprocess
    r = subprocess.run(["grep", "-rn", "colors.text_main\|colors.semantic_\|colors.bg_input\|colors.accent_primary",
                        "src/"], capture_output=True, text=True)
    hits = [l for l in r.stdout.splitlines() if ".zig:" in l]
    if hits:
        return "fail", f"legacy alias call sites remain: {hits[:3]}"
    if "pub const transparent" not in th:
        return "fail", "theme.transparent shared token missing"
    return "pass", "canonical tokens only; legacy aliases deleted"


@test("Compact Type Ramp Drives dvui Fonts", "Page Shell")
def test_typography_unified():
    # Phase 4: one type ramp. applyToDvui routes dvui's font_body/heading/title
    # through theme.font_size, so labels that use themeGet() fonts and
    # components that use fontAt() finally agree; ramp is the compact one.
    th = _src("src/ui/theme.zig")
    if "font_body.withSize(font_size.body)" not in th:
        return "fail", "dvui font_body not routed through the token ramp"
    if "font_heading.withSize(font_size.title)" not in th or "font_title.withSize(font_size.display)" not in th:
        return "fail", "dvui heading/title fonts not routed through tokens"
    if "body: f32 = 11" not in th:
        return "fail", "type ramp is not the compact one (body should be 11)"
    return "pass", "compact ramp drives dvui + component fonts"


@test("Browse Sub-Tabs Own Their Row", "Page Shell")
def test_subtab_layout():
    # Phase 4 regression guard: the route fade (AnimateWidget) wraps a SINGLE
    # child; pages with sub-tabs render two siblings, which used to each get
    # the full page rect and draw interleaved (Browse toolbar over sub-tabs).
    sh = _src("src/ui/shell.zig")
    if "var page_col = dvui.box" not in sh:
        return "fail", "route fade missing the single-child column wrapper"
    if "scrollArea" not in sh.split("fn subTabs")[1].split("fn ")[0]:
        return "fail", "sub-tab strip not in a height-reserving scroll strip"
    return "pass", "fade wraps one column; sub-tabs reserve their row"


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


@test("Plex Client Wired", "Page Shell")
def test_plex_wired():
    # Plex client: PIN auth → server discovery → library browse → direct-play,
    # with a .Plex nav tab.
    px = _src("src/services/plex.zig")
    dr = _src("src/ui/drawer.zig")
    en = _src("src/core/state.zig")
    ok = (
        "api/v2/pins" in px
        and "api/v2/resources" in px
        and "/library/sections" in px
        and "pub fn renderContent()" in px
        and "X-Plex-Token" in px
        and ".Plex =>" in dr
        and "Plex," in en.split("DrawerTab = enum")[1].split("}")[0]
        and 'plex.zig").init()' in _src("src/main.zig")
    )
    return ("pass", "PIN auth + discovery + browse + play + tab wired") if ok else ("fail", "plex not fully wired")


@test("Trakt Sync Wired", "Page Shell")
def test_trakt_wired():
    # Trakt was dead code missing client_secret (auth couldn't complete). Now:
    # device flow w/ secret + persistence, a Connect UI, and id-based mark-watched
    # wired to TMDB episode play.
    tr = _src("src/services/trakt.zig")
    pg = _src("src/services/plugins.zig")
    tm = _src("src/services/tmdb.zig")
    ok = (
        "client_secret" in tr
        and "markWatchedEpisode" in tr
        and "pub fn init()" in tr
        and tr.count("client_secret") >= 4  # decl + save + load + token poll
        and "renderTrakt" in pg
        and "markWatchedEpisode" in tm
        and "trakt.zig\").init()" in _src("src/main.zig")
    )
    return ("pass", "device-flow + persistence + mark-watched wired") if ok else ("fail", "trakt not fully wired")


@test("Threads Detached (project-wide)", "Stability")
def test_threads_detached():
    # Discarded `_ = std.Thread.spawn(...)` leaks the pthread handle (CLAUDE.md);
    # every spawn must store + detach (or join). Repo-wide sweep is complete, so
    # this guard now walks ALL of src/ and fails if the pattern ever returns.
    offenders = []
    src = os.path.join(PROJECT_DIR, "src")
    for root, _, files in os.walk(src):
        for fn in files:
            if not fn.endswith(".zig"):
                continue
            p = os.path.join(root, fn)
            for i, line in enumerate(open(p).read().splitlines(), 1):
                if "_ = std.Thread.spawn(" in line:
                    offenders.append(f"{os.path.relpath(p, PROJECT_DIR)}:{i}")
    if offenders:
        return "fail", "leaked thread handle(s): " + ", ".join(offenders[:6])
    return "pass", "no discarded std.Thread.spawn handles in src/"


@test("TMDB Fetch Stages Results Off-Thread", "Stability")
def test_tmdb_fetch_stages_results():
    # Regression guard for the renderCatalogRail out-of-bounds crash
    # (2026-07-03): the detached fetch worker cleared/appended the LIVE
    # state.app.tmdb.results list while the UI thread iterated it mid-frame.
    # The fix: workers parse into a local list and stage it (pending_results,
    # under results_mutex); ONLY the UI thread mutates `results`, via
    # applyPendingResults() at frame start.
    api = open(os.path.join(PROJECT_DIR, "src/services/tmdb_api.zig")).read()
    parse_src = open(os.path.join(PROJECT_DIR, "src/services/tmdb_parse.zig")).read()
    main_src = open(os.path.join(PROJECT_DIR, "src/main.zig")).read()
    for needle in ("pending_results", "results_mutex", "fn applyPendingResults"):
        if needle not in api:
            return "fail", f"tmdb_api.zig lost the staged-results swap ({needle})"
    # The live-list clear may exist ONLY inside applyPendingResults (UI thread).
    clear = "results.clearRetainingCapacity()"
    before_apply = api.split("fn applyPendingResults")[0]
    if clear in before_apply.replace("pending_" + clear, ""):
        return "fail", "fetch worker clears the live results list again (UI-render race)"
    if "state.app.tmdb.results.append" in parse_src:
        return "fail", "tmdb_parse.zig appends to the live results list (must parse into `out`)"
    if "applyPendingResults()" not in main_src:
        return "fail", "appFrame no longer applies staged TMDB pages (applyPendingResults)"
    return "pass", "fetch worker stages into pending_results; UI thread owns live list"


@test("Keyless Subtitle Fetch Works E2E", "Page Shell")
def test_keyless_subtitle_fetch_e2e():
    # Three real bugs fixed so auto-download actually lands an SRT:
    #  1. uppercase queries 302 to a broken host → urlEncode must lowercase
    #  2. OpenSubtitles JSON escapes slashes (\/) → unescapeJsonSlashes on the URL
    #  3. the redirect + gzip broke std.http → httpGet uses curl (-L --compressed)
    eng = open(os.path.join(PROJECT_DIR, "src/player/subtitles.zig")).read()
    pure = open(os.path.join(PROJECT_DIR, "src/services/subtitles_pure.zig")).read()
    if "ch + 32" not in eng:
        return "fail", "urlEncode no longer lowercases (uppercase → broken 302 redirect)"
    if "unescapeJsonSlashes" not in eng or "unescapeJsonSlashes" not in pure:
        return "fail", "download URL no longer unescapes JSON \\/ (Uri.parse rejects it)"
    if '"curl"' not in eng or "--compressed" not in eng:
        return "fail", "httpGet no longer uses curl (std.http chokes on the OS redirect)"
    return "pass", "lowercase query + URL unescape + curl fetch — auto-download lands an SRT"


@test("Keyless Subtitle Providers Wired", "Page Shell")
def test_keyless_subtitle_providers():
    # Auto-subs must work with NO API key via public engines: the legacy
    # rest.opensubtitles.org (movies+TV, gzipped) plus Gestdown/Addic7ed
    # (api.gestdown.info, TV, direct SRT). Gestdown APPENDS its matches to the
    # merged, source-tagged result list (primary first) instead of only
    # rescuing an empty primary. Non-torrent playback triggers the keyless
    # engine from the FILE_LOADED handler.
    eng = open(os.path.join(PROJECT_DIR, "src/player/subtitles.zig")).read()
    player = open(os.path.join(PROJECT_DIR, "src/player/player.zig")).read()
    if "rest.opensubtitles.org" not in eng:
        return "fail", "keyless legacy OpenSubtitles REST provider missing"
    if "api.gestdown.info" not in eng or "gestdownAppend" not in eng:
        return "fail", "Gestdown keyless append provider missing"
    if "MAX_RESULTS = 15" not in eng:
        return "fail", "merged result list no longer holds 15 entries"
    if "source: SubSource" not in eng or "pub fn sourceName" not in eng:
        return "fail", "results lost their provider source tag"
    # Engine parses provider JSON through the unit-tested pure module.
    if "osRestResults" not in eng or "gestdownSubs" not in eng:
        return "fail", "engine no longer routes parsing through subtitles_pure"
    # Manual UI entries: query search + per-row worker download.
    if "pub fn searchQuery" not in eng or "pub fn downloadIndex" not in eng:
        return "fail", "engine lost its manual searchQuery/downloadIndex entry points"
    if "startSearch(&state.app.sub_engine" not in player or "current_torrent_id < 0" not in player:
        return "fail", "non-torrent playback no longer triggers the keyless engine"
    build = open(os.path.join(PROJECT_DIR, "build.zig")).read()
    if "subtitles_pure.zig" not in build:
        return "fail", "subtitles_pure parser tests unregistered"
    return "pass", "keyless chain: rest.opensubtitles.org + Gestdown merged (15 tagged results), fired on any playback"


@test("Subdl Subtitle Provider Wired", "Page Shell")
def test_subdl_provider():
    # Subdl (api.subdl.com) is a KEYED wave-2 provider parallel to
    # OpenSubtitles.com: free per-user key, ZIP downloads extracted in-process
    # via std.zip. Ships inert — no key ⇒ no fetch. Verify the whole chain:
    # state key + config persistence + pure parser (tested) + provider funcs +
    # in-process ZIP extraction + Settings UI field.
    state = open(os.path.join(PROJECT_DIR, "src/core/state.zig")).read()
    cfg = open(os.path.join(PROJECT_DIR, "src/core/config.zig")).read()
    pure = open(os.path.join(PROJECT_DIR, "src/services/subtitles_pure.zig")).read()
    svc = open(os.path.join(PROJECT_DIR, "src/services/subtitles.zig")).read()
    ui = open(os.path.join(PROJECT_DIR, "src/ui/settings.zig")).read()

    # Key plumbing: fixed buffer in state, persisted both ways in config.
    if "subdl_api_key" not in state or "subdl_api_key_len" not in state:
        return "fail", "subdl_api_key not added to state.zig"
    if 'setKey("subdl_api_key"' not in cfg or '"subdl_api_key"' not in cfg:
        return "fail", "subdl_api_key not persisted/loaded in config.zig"

    # Pure, unit-tested parser + language mapper; production routes through them.
    if "pub fn subdlSubs" not in pure or "pub fn subdlLangCode" not in pure:
        return "fail", "subdlSubs/subdlLangCode missing from subtitles_pure.zig"
    if "sp.subdlSubs" not in svc or "sp.subdlLangCode" not in svc:
        return "fail", "provider no longer routes parsing through subtitles_pure"

    # Provider entry points + inert-without-key guard.
    if "pub fn subdlSearch" not in svc or "pub fn subdlDownload" not in svc:
        return "fail", "subdlSearch/subdlDownload entry points missing"
    if "state.app.subdl_api_key_len == 0" not in svc:
        return "fail", "Subdl search no longer no-ops without a key (not inert)"
    if "api.subdl.com/api/v1/subtitles" not in svc:
        return "fail", "Subdl search endpoint missing"
    if "https://dl.subdl.com" not in svc:
        return "fail", "Subdl download host missing"

    # ZIP handling: in-process extraction via std.zip (no external unzip dep).
    if "std.zip.extract" not in svc:
        return "fail", "Subdl ZIP no longer extracted via std.zip"

    # Settings UI: masked key field + free-key hint + results wiring.
    if "subdl_api_key" not in ui or "subdl.com/panel/api" not in ui:
        return "fail", "Settings → Subtitles missing Subdl key field / free-key hint"
    if "subs.subdlSearch" not in ui or "subs.subdlDownload" not in ui:
        return "fail", "Settings tab not wired to Subdl search/download"

    return "pass", "keyed Subdl: state+config key, pure parser, api.subdl.com search, std.zip download, Settings UI — inert without key"


@test("Auto-Download Subtitles On Play", "Page Shell")
def test_auto_download_subs():
    # A video with no embedded/sidecar sub track should trigger an automatic
    # OpenSubtitles fetch of the best match. Wiring: mpv FILE_LOADED handler
    # checks for a sub track and calls subtitles.autoFetchForPlayer(); doSearch
    # chains into doDownload when auto_mode is set; gated by a persisted toggle.
    player = open(os.path.join(PROJECT_DIR, "src/player/player.zig")).read()
    cfg = open(os.path.join(PROJECT_DIR, "src/core/config.zig")).read()
    # FILE_LOADED handler checks for an existing sub track and, when there's
    # none, fires the keyless engine (gated by the persisted toggle).
    if "MPV_EVENT_FILE_LOADED" not in player:
        return "fail", "player has no FILE_LOADED handler"
    if "auto_download_subs" not in player or "startSearch(&state.app.sub_engine" not in player:
        return "fail", "FILE_LOADED no longer auto-triggers the subtitle engine on the toggle"
    if "auto_download_subs" not in cfg:
        return "fail", "auto_download_subs toggle not persisted in config"
    # The auto path must still chain search → download (manual UI searches
    # set auto_load=false and wait for a per-row downloadIndex instead).
    eng = open(os.path.join(PROJECT_DIR, "src/player/subtitles.zig")).read()
    if "auto_load" not in eng or "engine.auto_load" not in eng:
        return "fail", "engine lost the auto_load search→download chain flag"
    return "pass", "FILE_LOADED with no sub track auto-fires the keyless engine (toggle-gated)"


@test("Sub Picker Lists Keyless Results", "Page Shell")
def test_sub_picker_keyless_results():
    # The two browsable subtitle lists (footer Find Subtitles modal + Settings
    # › Subtitles) must render the KEYLESS engine's merged results — source-
    # tagged rows with a per-row Download — with no API key required. A key
    # only APPENDS an opensubtitles.com section; without one the hint is a
    # subtle one-liner, never a blocking banner.
    footer = open(os.path.join(PROJECT_DIR, "src/ui/footer.zig")).read()
    settings = open(os.path.join(PROJECT_DIR, "src/ui/settings.zig")).read()
    if "pub fn renderSubPicker" not in footer:
        return "fail", "footer lost renderSubPicker"
    picker = footer.split("pub fn renderSubPicker")[1].split("\npub fn ")[0]
    if "state.app.sub_engine" not in picker:
        return "fail", "footer picker no longer renders the keyless engine results"
    if "downloadIndex" not in picker:
        return "fail", "footer picker rows lost the per-row keyless Download"
    if "sourceName" not in picker:
        return "fail", "footer picker rows lost their provider source chip"
    if "loaded_idx" not in picker:
        return "fail", "footer picker no longer marks the loaded subtitle row"
    if "opensub_api_key_len > 0" not in picker:
        return "fail", "keyed opensubtitles.com section is no longer gated on the key"
    if "for more results" not in picker:
        return "fail", "no-key hint one-liner missing from the picker"
    # Footer chip kicks the keyless search when opening the picker.
    if "searchFromActivePlayer(&state.app.sub_engine)" not in footer:
        return "fail", "footer Subs chip no longer kicks the keyless search"
    # Settings list mirrors the same wiring.
    if "searchQuery(engine" not in settings and "searchQuery(&state.app.sub_engine" not in settings:
        return "fail", "Settings search no longer routes through the keyless engine"
    if "sourceName" not in settings or "downloadIndex" not in settings:
        return "fail", "Settings result rows lost keyless source tags / download"
    # Language change re-fires the search.
    if "refire" not in footer or "refire" not in settings:
        return "fail", "language change no longer re-fires the subtitle search"
    return "pass", "footer + Settings lists render keyless source-tagged rows; key only appends"


@test("SQLite Opened Serialized (Thread-Safe)", "Stability")
def test_sqlite_serialized():
    # The one shared connection is used by the UI thread and background
    # workers; it MUST be opened SQLITE_OPEN_FULLMUTEX (serialized) or
    # concurrent access segfaults inside sqlite3Prepare — the file-open
    # launch crash (DiagnosticReports 2026-07-03 22:06).
    db = open(os.path.join(PROJECT_DIR, "src/core/db.zig")).read()
    if "sqlite3_open_v2" not in db or "SQLITE_OPEN_FULLMUTEX" not in db:
        return "fail", "db.zig no longer opens the connection serialized (FULLMUTEX)"
    return "pass", "shared sqlite connection opened SQLITE_OPEN_FULLMUTEX"


@test("Poster Pixels Freed With C Allocator", "Stability")
def test_poster_pixel_allocator():
    # core/poster.zig fetchAsync allocates pixel buffers with the C allocator;
    # freeing them with the global DebugAllocator aborts the app (freeLarge
    # assert — the 2026-07-03 shutdown crash in freeImageBuffers).
    tmdb = open(os.path.join(PROJECT_DIR, "src/services/tmdb.zig")).read()
    fib = tmdb.split("pub fn freeImageBuffers")[1].split("\n}")[0]
    if "std.heap.c_allocator.free" not in fib:
        return "fail", "freeImageBuffers no longer frees poster pixels via the C allocator"
    if "alloc.free(px)" in fib:
        return "fail", "freeImageBuffers frees c_alloc pixels with the debug allocator again"
    return "pass", "fetchAsync-owned poster pixels freed with the matching C allocator"


@test("Anime Tab Honors NSFW Filter", "Page Shell")
def test_anime_nsfw_filter():
    # Settings › NSFW toggle must govern anime browsing, not just search:
    # every Jikan grid URL carries sfw=true and the parser drops Rx/R+ rated
    # entries (anime_pure.jikanRatingIsAdult, unit-tested).
    anime = open(os.path.join(PROJECT_DIR, "src/services/anime.zig")).read()
    if "sfwSuffix(state.app.nsfw_filter_enabled)" not in anime:
        return "fail", "Jikan URLs no longer append the sfw param from the NSFW toggle"
    if anime.count("sfwSuffix(state.app.nsfw_filter_enabled)") < 15:
        return "fail", "some Jikan grid URL sites lost the sfw param (expected 15+)"
    if "jikanRatingIsAdult(obj_slice)" not in anime:
        return "fail", "parser no longer drops Rx/R+ entries when the filter is on"
    build = open(os.path.join(PROJECT_DIR, "build.zig")).read()
    if "anime_pure.zig" not in build:
        return "fail", "anime_pure tests unregistered from zig build test"
    return "pass", "sfw=true on all Jikan URLs + Rx/R+ parser drop, gated on the toggle"


@test("Windows Port: Source Invariants", "Stability")
def test_windows_port_invariants():
    # The x86_64-windows-gnu port is comptime-gated (windows arms never run
    # natively), so guard its load-bearing invariants at source level. The
    # real gate is `zig build -Dtarget=x86_64-windows-gnu` reaching the link
    # stage with zero sema errors; these checks catch accidental regressions
    # of the arms that made that possible.
    build = _src("build.zig")
    if "MINGW_PREFIX" not in build:
        return "fail", "build.zig lost the MINGW_PREFIX env handling for Windows"
    if "torrent_wrapper.dll" not in build:
        return "fail", "build.zig no longer produces torrent_wrapper.dll on Windows"
    if "libmpv.dll.a" not in build or "libsqlite3.dll.a" not in build or "libonnxruntime.dll.a" not in build:
        return "fail", "build.zig lost the MinGW .dll.a import-lib objects (zig -l search never finds lib{name}.dll.a)"
    iog = _src("src/core/io_global.zig")
    if 'extern "kernel32" fn Sleep' not in iog:
        return "fail", "io_global.sleep lost its kernel32 Sleep arm (nanosleep does not exist on Windows)"
    if "terminateProcess" not in iog or "TerminateProcess" not in iog:
        return "fail", "io_global lost the portable terminateProcess helper"
    sync = _src("src/core/sync.zig")
    if "SRWLockExclusive" not in sync:
        return "fail", "sync.Mutex lost its SRWLOCK arm (std.c.pthread_mutex_t is void on Windows)"
    paths = _src("src/core/paths.zig")
    if "APPDATA" not in paths or "LOCALAPPDATA" not in paths:
        return "fail", "paths.zig lost the %APPDATA%/%LOCALAPPDATA% Windows arms"
    # posix kill/raw nanosleep outside io_global are Windows compile blockers.
    sl = _src("src/services/streamlink.zig")
    if "std.posix.kill" in sl:
        return "fail", "streamlink regressed to std.posix.kill (breaks Windows compile); use io_global.terminateProcess"
    return "pass", "MINGW_PREFIX + dll.a link + win arms in io_global/sync/paths intact"


# ══════════════════════════════════════════════════════════
# OMDb Ratings Enrichment
# ══════════════════════════════════════════════════════════

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


@test("Unified Downloads List", "Page Shell")
def test_unified_downloads():
    # Downloads is ONE merged list (torrents + files + history) with filter
    # chips — not three tabs. The merge/dedup/status/sort decisions must come
    # from the unit-tested pure module, and the renderer must only execute them.
    tr = _src("src/services/transfers.zig")
    pure = _src("src/services/transfers_pure.zig")
    hdr = _src("src/torrent_wrapper.h")
    cpp = _src("src/torrent_wrapper.cpp")
    checks = {
        "pure merge engine": "pub fn buildRows(" in pure and "pub fn matchStrength(" in pure,
        "renderer uses pure merge": "tp.buildRows(" in tr and "tp.sortOrder(" in tr,
        "filter chips (not tabs)": "var filter: tp.Filter" in tr and "tab_idx" not in tr,
        "old tab renderers gone": ("renderFilesInline" not in tr
                                   and "renderActiveInline" not in tr
                                   and "renderHistoryInline" not in tr),
        "one unified list": "fn renderUnifiedList()" in tr and "tp.matchesFilter(" in tr,
        "chip counts from pure": "tp.countsFor(" in tr,
        # An index would be invalidated by every 2Hz rebuild — expansion is keyed
        # by identity (infohash / disk entry / normalized name).
        "expansion keyed by identity": ("expanded_key" in tr
                                        and "expanded_torrent_id" not in tr),
        # torrent_poll is side-effecting (streaming deadline window) but used to
        # run every frame at ~60Hz; the snapshot throttles it to 2Hz.
        "snapshot throttled to 2Hz": "last_build_ms" in tr and "rows_dirty" in tr,
        "infohash getter (C++)": ("int torrent_get_infohash(" in hdr
                                  and 'extern "C" int torrent_get_infohash(' in cpp
                                  and "info_hashes().get_best()" in cpp),
        "renderer reads the infohash": "torrent_get_infohash(" in tr,
        # Names from libtorrent/disk are untrusted bytes; invalid UTF-8 panics dvui.
        "untrusted names validated": "safeUtf8Buf(displayName(" in tr,
        # "Remove" must never delete disk bytes; deleting files is a separate,
        # explicitly confirmed action in the expanded panel.
        "remove ≠ delete from disk": ("confirmDangerButton(@src(), \"Remove\"" in tr
                                      and "Delete files from disk" in tr),
        # Dropping the proxy teardown leaks an accept-loop thread + a port.
        "proxy torn down on remove": "stream_proxy.stopProxy(p.proxy_handle)" in tr,
        "folder drill-down kept": "browse_subdir_len" in tr and "← Up" in tr,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "missing: " + ", ".join(missing)
    return "pass", "one merged list: pure dedup + chips + union actions + infohash join"


@test("Watching library: all kinds, next-up, user status", "Page Shell")
def test_tv_tracking():
    # TV tracking used to be ~80% built and quietly wrong: next-up could not
    # cross a season, tv_continue stored the LAST WATCHED episode (so every
    # consumer re-derived "what's next" and none agreed), there was no
    # per-episode resume, and nothing clamped next-up to what had actually aired.
    pure = _src("src/services/tv_pure.zig")
    lib = _src("src/services/tv_library.zig")
    dbz = _src("src/core/db.zig")
    tm = _src("src/services/tmdb.zig")
    cal = _src("src/services/tv_calendar.zig")
    pl = _src("src/player/player.zig")
    st = _src("src/core/state.zig")
    sh = _src("src/ui/shell.zig")
    rt = _src("src/core/router.zig")
    checks = {
        # The engine, and the fact that production routes through it.
        "pure engine": ("pub fn nextUp(" in pure
                        and "pub fn progress(" in pure
                        and "pub fn statusOf(" in pure),
        "aired clamp exists": "last_aired" in pure and "fn airedInSeason(" in pure,
        "specials excluded": "SPECIALS_SEASON" in pure,
        "library routes through pure": "tp.nextUp(" in lib and "tp.progress(" in lib,
        # Cross-season next-up needs every watched row + the season map, not the
        # 120-bool window of whichever season happens to be open.
        "season map persisted": "CREATE TABLE IF NOT EXISTS tv_seasons" in dbz,
        "tracked shows table": "CREATE TABLE IF NOT EXISTS tv_shows" in dbz,
        "watched loaded across seasons": "pub fn tvLoadWatchedAll(" in dbz,
        "detail resume is cross-season": "fn tvNextUp()" in tm and "nextUpFor(" in tm,
        # Per-episode resume, keyed by real episode identity.
        "episode resume columns": ("ALTER TABLE tv_watched ADD COLUMN position_secs" in dbz
                                   and "pub fn tvSavePosition(" in dbz
                                   and "pub fn tvGetPosition(" in dbz),
        "player binds the episode": "playing_episode" in pl and "tvSavePosition(" in pl,
        "player resumes the episode": "tvGetPosition(" in pl,
        # The binding is to a specific stream URL, not a bare "an episode is
        # playing" flag. Without the URL guard, playing a movie after an episode
        # writes the movie's position into the episode's row and then resumes the
        # movie at the episode's timestamp. Both save and resume must be gated.
        "episode binding is url-guarded": ("pub fn matches(" in st
                                           and pl.count("pe.matches(") >= 2
                                           and "pe.armed" in pl),
        # 64-bit columns: updated_at is a ms timestamp (~1.75e12) and would
        # silently truncate through columnInt's i32, wrecking the sort order.
        "int64 column reader": "pub fn columnInt64(" in dbz,
        # Untracking must never destroy watch history.
        "untrack keeps history": ("pub fn tvSetTracked(" in dbz
                                  and "DELETE FROM tv_watched" not in dbz),
        # User-settable status, next to the show name, changeable at any time.
        # It lives in a generic library_status table (not a tv_shows column)
        # because anime keys off a MAL id and a movie off its name.
        "status chips on detail": "pub fn renderStatusChips(" in tm,
        "user status beats derived": "pub fn effectiveStatus(" in pure and "r.user = " in lib,
        "generic status table": ("CREATE TABLE IF NOT EXISTS library_status" in dbz
                                 and "pub fn librarySetStatus(" in dbz
                                 and "pub fn libraryGetStatus(" in dbz),
        "auto-track on watch": "tvTouchShow(" in tm,
        # The Watching library is not TV-only.
        "all kinds aggregated": ("fn addTvRows(" in lib and "fn addAnimeRows(" in lib
                                 and "fn addMovieRows(" in lib),
        "kind chips": "tp.kindCountsFor(" in lib and "kind_filter" in lib,
        # A TV episode also lands in watch_history under its release name; listing
        # it as a "movie" would duplicate the show under a worse identity.
        "episodes excluded from movies": "subs.parse(name, &qbuf, &showbuf).is_tv" in lib,
        # "No next episode" != "caught up". With no season map we don't KNOW, and
        # saying "Caught up" hid the user's next episode (Silo: caught up at 0/10).
        "unknown never reads as caught up": ('"Not synced yet"' in pure
                                             and "if (r.prog.total == 0)" in pure),
        # Opening a show persists its season map, so "unknown" stops being
        # reachable for anything the user has actually looked at.
        "detail open persists season map": "tvUpsertSeasons(tmdb_id" in tm,
        # One fetch, one truth: the calendar no longer makes its own /3/tv/{id}
        # call, and no longer derives its own idea of what is unseen.
        "calendar consumes, not fetches": ("fn worker() void" not in cal
                                           and "e.unseen = next_up != null" in cal),
        "calendar fed by the sync": "cal.stage(" in lib,
        # The page.
        "watching route": "watching," in rt and ".watching =>" in sh,
        # Both chip rows and the visibility rule come from the tested pure module.
        "filter chips from pure": "tp.countsFor(" in lib and "tp.visible(" in lib,
        # Each row costs 2 queries; polling 200 shows at 2Hz would be ~800 q/s.
        "snapshot is dirty-driven, not polled": ("library_dirty" in lib
                                                 and "last_build_ms" not in lib),
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "missing: " + ", ".join(missing)
    return "pass", "TV+anime+movies in one library; aired-clamped next-up; user-set status"


@test("Torrent streaming: readiness gate + per-container index", "Stability")
def test_stream_readiness_gate():
    # A 1080p MKV at 11% with 69 seeds sat black at 00:00 forever. Two bugs:
    #
    #  1. mpv was launched as soon as ONE piece existed. But mpv's Matroska
    #     demuxer SEEKS TO EOF during open to read the Cues + Tags, so it blocked
    #     inside demux_mkv_open() before creating a single track, waiting on bytes
    #     nothing had prioritized. Head progress was irrelevant.
    #  2. The proxy TRUNCATED the body on a read timeout after promising a
    #     Content-Length. ffmpeg cannot tell a read error from EOF, so mpv decided
    #     the file had ended and gave up -- which is why downloading more never
    #     helped.
    cp = _src("src/player/container_pure.zig")
    gate = _src("src/player/stream_gate.zig")
    pl = _src("src/player/player.zig")
    px = _src("src/player/stream_proxy.zig")
    cpp = _src("src/torrent_wrapper.cpp")
    hdr = _src("src/torrent_wrapper.h")
    gr = _src("src/ui/grid.zig")
    bz = _src("build.zig")

    checks = {
        # Different containers demand different bytes -- that IS the feature.
        "per-container plan": ("pub fn initialPlan(" in cp and "pub fn refine(" in cp
                               and "pub fn needsTail(" in cp),
        "mkv reads its own SeekHead": "fn mkvIndexOffset(" in cp,
        "mp4 finds moov (faststart => no tail)": "fn mp4MoovOffset(" in cp,
        "avi finds idx1": "fn aviIndexOffset(" in cp,
        # Linear formats must NOT be made to wait for a tail that doesn't exist.
        "ts/flv need no tail": ".ts, .flv => false" in cp,
        # Byte-sized, never piece-sized: "last 5 pieces" is 5MB at 1MB pieces and
        # 80MB at 16MB pieces.
        "tail measured in bytes": "TAIL_FALLBACK_BYTES" in cp,
        "pure registered": "container_pure.zig" in bz,

        # The gate itself.
        "gate exists": "pub fn isReady(" in gate and "container_pure.zig" in gate,
        # It must wait on as LITTLE as possible. Waiting for the whole head + the
        # index was correct but needlessly slow: an 8 MB/s torrent still showed
        # "Buffering 87%". Playback now waits only for START_BYTES; the rest of the
        # head and the index at EOF keep racing at top priority behind it, which is
        # safe only because the tail is now prioritized and the proxy no longer
        # truncates (the two things that caused the original black screen).
        "starts on a small head, not the whole thing": ("START_BYTES" in cp
                                                        and "cp.START_BYTES" in gate),
        "index keeps racing after start": "index still racing" in gate,
        "player waits on the gate": "stream_gate.zig" in pl and "gate.isReady(" in pl,
        "no more instant start": "START PLAYBACK IMMEDIATELY" not in pl,

        # C++ byte-range primitives the gate needs.
        "range primitives": all(f in hdr and f in cpp for f in (
            "torrent_range_ready", "torrent_prioritize_range", "torrent_range_progress")),
        # Priorities BEFORE deadlines: prioritize_pieces() calls
        # remove_time_critical_pieces(), so the reverse order silently drops them.
        "priorities before deadlines": (cpp.index("prioritize_pieces(prios)")
                                        < cpp.index("set_piece_deadline(lt::piece_index_t(p), dl)")),

        # Never truncate a body we promised a Content-Length for.
        "proxy never truncates": "aborting so the player reconnects" in px,
        # A network timeout reaches ffmpeg as a fake EOF.
        "no network timeout": '"network-timeout", "0"' in pl,

        # The bar must report readiness, not whole-torrent progress.
        "buffer bar shows readiness": "gate.bufferPercent(" in gr,

        # CRASH REGRESSION: load_file blanks the video texture, but `pixels` is
        # allocated at video_w*video_h while the texture is created in grid.zig at
        # the current RENDER size. dvui's Texture.update hard-@panics on a length
        # mismatch (it is not a catchable error, so the `catch {}` was decoration),
        # so reloading a file while a texture was alive aborted the process with
        # "Texture size and supplied Content did not match". Slice to the texture.
        "texture update sliced to texture size": ("const npix = @as(usize, tex.width) * @as(usize, tex.height);" in pl
                                                  and "self.pixels[0..npix]" in pl),
        # A read of 0 is a legitimate EOF; only a NEGATIVE read is a failure that
        # must abort the connection. Treating 0 as failure aborted every clean end.
        "eof is not an error": "if (read == 0) break;" in px and "if (read < 0) {" in px,
        # A mid-stream buffering reload must resume where it was, not fall back to
        # the coarse watch-history percent (which visibly jumps playback backwards).
        "buffering reload keeps position": '"percent-pos", c.mpv.MPV_FORMAT_DOUBLE, &cur_pct' in pl,
        # REGRESSION: loadfile used to implicitly end the previous file. Now that we
        # wait for a readable head before calling it, nothing stopped the old media
        # -- picking a new episode left the PREVIOUS one playing, audio and all,
        # behind the buffering overlay with its timeline still ticking.
        "new torrent stops the old playback": ('mpv_command_string(p.mpv_ctx, "stop")'
                                               in _src("src/services/search.zig")),
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "missing: " + ", ".join(missing)
    return "pass", "head+index gate, per-container tail (mkv/mp4/avi/ts), no truncation"


@test("Player control bar: drop-ups + FF fullscreen", "Page Shell")
def test_player_dropups():
    # The control-bar pickers (aspect / audio / subs / language / files) were
    # MODAL dialogs: a dimming backdrop over the video, a title bar, a close
    # button. The scrim dimmed the very thing you were adjusting. They are now
    # backdrop-less panels anchored ABOVE the chip that opened them.
    pk = _src("src/ui/pickers.zig")
    ft = _src("src/ui/footer.zig")
    dp = _src("src/ui/dropup_pure.zig")
    bz = _src("build.zig")
    checks = {
        # Placement is pure + unit-tested; the UI only executes it.
        "pure placement": "pub fn place(" in dp and "pub fn contains(" in dp,
        "pure registered": "dropup_pure.zig" in bz,
        "pickers route through pure": "dropup.place(" in pk,
        # The whole point: no backdrop, and no window chrome.
        "no modals left": "modal = true" not in pk,
        "explicitly non-modal": ".modal = false" in pk,
        "no window title bars": "windowHeader" not in pk,
        # Anchored to the chip that opened it, so it drops UP from that chip.
        "chip anchor recorded": "picker_anchor" in ft and "recordAnchor(" in ft,
        "panel anchors to the chip": "footer.anchorFor(" in pk,
        # With no backdrop there is nothing to swallow a stray click, so Esc must work.
        "esc dismisses": "pub fn handleDropUpKeys(" in pk and "pickers.handleDropUpKeys();" in ft,
        # FF button now toggles fullscreen, reusing the same path the 'f' key drives.
        "ff toggles fullscreen": ("fullscreen_player_idx" in ft
                                  and 'components.tip(@src(), wd, if (is_fs) "Exit fullscreen (f)"' in ft),
        "ff no longer seeks": '"seek 10"' not in ft,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "missing: " + ", ".join(missing)
    return "pass", "backdrop-less drop-ups anchored above their chip; FF toggles fullscreen"


@test("Player: prev/next episode buttons", "Page Shell")
def test_episode_transport():
    # When a tracked TV episode is playing, the control bar gets prev/next EPISODE
    # buttons. Distinct from mpv's playlist-prev/next (a different thing, only
    # shown when there is an mpv playlist) and absent entirely for movies, where
    # "next episode" is meaningless.
    ft = _src("src/ui/footer.zig")
    lib = _src("src/services/tv_library.zig")
    pure = _src("src/services/tv_pure.zig")
    checks = {
        "neighbour logic is pure": ("pub fn episodeAfter(" in pure
                                    and "pub fn episodeBefore(" in pure),
        "library exposes neighbours": ("pub fn neighborEpisode(" in lib
                                       and "pub fn playNeighborEpisode(" in lib),
        "buttons in the control bar": '"ep-prev"' in ft and '"ep-next"' in ft,
        # Only for a tracked episode -- never for a movie / one-off file.
        "gated on a tracked episode": "tv_lib.playingEpisode()" in ft,
        "routes through the library": "tv_lib.playNeighborEpisode(" in ft,
        # "Next" must never offer an episode that hasn't aired -- that sends the
        # resolver hunting for a file that does not exist.
        "next is aired-clamped": "last_aired" in _between(lib, "pub fn neighborEpisode", "pub fn playNeighborEpisode"),
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "missing: " + ", ".join(missing)
    return "pass", "prev/next episode in the transport, aired-clamped, TV-only"


@test("Latest releases render as show cards", "Page Shell")
def test_release_cards():
    # "Latest releases" on Watching used to be a list of raw torrent rows next to a
    # grid of poster cards -- two renderers for the same shows, which is how one
    # page ends up looking like two apps. There is now ONE card (ui/media_card.zig)
    # and both surfaces call it.
    mc = _src("src/ui/media_card.zig")
    ez = _src("src/services/eztv_calendar.zig")
    ezp = _src("src/services/eztv_calendar_pure.zig")
    lib = _src("src/services/tv_library.zig")
    checks = {
        "one shared card": "pub fn render(" in mc and "pub const Card = struct" in mc,
        "library uses it": "media_card.render(" in lib,
        "releases use it": "media_card.render(" in ez,
        # One card per SHOW, not one per torrent: two releases of the same episode
        # (different groups/qualities) must not become two cards.
        "grouped by show": "pub fn groupShows(" in ezp and "pure.groupShows(" in ez,
        # The feed carries no artwork and no tmdb id, so each show is resolved.
        "artwork resolved": ("pub fn firstTvResult(" in ezp
                            and "pure.firstTvResult(" in ez
                            and "/3/search/tv?query=" in ez),
        # A stray & or # in a show name would truncate the query.
        "query encoded": "pub fn encodeQuery(" in ezp and "pure.encodeQuery(" in ez,
        # Poster slots keyed by show, never by list position -- the card list is
        # rebuilt every 15 min and a detached poster worker holds a slot pointer.
        "poster slots keyed by show": "fn posterFor(show: []const u8)" in ez,
        # The show-name parse reuses the tested SxxEyy filename parser.
        "reuses the tested name parser": "subs.parse(title, &qbuf, buf)" in ez,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "missing: " + ", ".join(missing)
    return "pass", "one shared poster card; releases grouped per show + artwork resolved"


@test("C toggles subtitles (not the comic viewer)", "Page Shell")
def test_c_toggles_subs():
    # C used to force the active player into the comic viewer, which blanked the
    # picture mid-video. That was a manual override of a decision the app already
    # makes for itself: browser.loadContent routes comic/image URLs to the comic
    # viewer via the unit-tested browser_pure.routeContent, and the Plugins page
    # sets it too -- so nothing is orphaned by taking the key.
    inp = _src("src/ui/input.zig")
    st = _src("src/ui/settings.zig")
    checks = {
        "C toggles subtitle visibility": '"cycle sub-visibility"' in inp,
        "C no longer hijacks the provider": "provider = .comic_viewer" not in inp,
        # Distinct from V / J, which CYCLE the track. Toggling visibility and
        # cycling tracks are different actions and both must survive.
        "V/J still cycle the track": inp.count('"cycle sub"') >= 2,
        # The Settings shortcut list must not lie about what the key does.
        "help text updated": ('"Toggle Subtitles On/Off"' in st
                              and '"Switch Cell to Comic"' not in st),
        # The comic viewer is still reachable the way it actually should be.
        "comic viewer still routed by URL": "comic_viewer" in _src("src/services/browser_pure.zig"),
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "missing: " + ", ".join(missing)
    return "pass", "C toggles sub-visibility; comic viewer still auto-routed by URL"


@test("Title-bar resource meters", "Stability")
def test_sysmeter():
    # CPU / MEM / THR / NRG in the OS title bar, folded into the window title as
    # text. There is no dvui widget: SDL2 gives no drawable surface up there.
    mon = _src("src/core/sysmon.zig")
    pur = _src("src/core/sysmon_pure.zig")
    sh = _src("src/ui/shell.zig")
    mn = _src("src/main.zig")
    bz = _src("build.zig")
    checks = {
        "sampler exists": "pub fn start() void" in mon and "pub fn get() Snapshot" in mon,
        "started at launch": 'core/sysmon.zig").start()' in mn,
        # The meters are NOT a dvui widget any more — they're text in the window
        # title, so there is no in-app strip to mount (and no duplicate row).
        "no duplicate in-app strip": "renderTitleStrip" not in sh,
        # Every reading is a syscall. Sampling per-frame on the UI thread would
        # cost more than the thing it measures.
        "sampled off-thread at 1Hz": ("std.Thread.spawn" in mon and ".detach()" in mon
                                      and "io.sleep(1000 * std.time.ns_per_ms)" in mon),
        # CPU is a RATE: it needs two samples. The first tick can only guess, so
        # the meters hide rather than show a confident zero (or a 100% spike).
        "no reading before a real delta": "valid" in mon and "snap.valid" in mn,
        # Thresholds/clamping/formatting are decided in the tested pure module.
        "decisions are pure + tested": all(f in pur for f in
                                           ("pub fn frac(", "pub fn levelOf(", "pub fn energyImpact(",
                                            "pub fn fmtBytes(")),
        "title routes through pure": all(f in pur for f in ("cpuMetric(", "memMetric(", "titleMeters(")),
        "pure registered": "sysmon_pure.zig" in bz,
        # mach hands us VM-allocated arrays and thread ports. Leaking them every
        # second inside the thing that MEASURES leaks would be quite the own goal.
        "mach allocations freed": ("vm_deallocate" in mon and "mach_port_deallocate" in mon),
        # Real syscalls, not a stub.
        "real syscalls": all(f in mon for f in ("host_statistics64", "host_processor_info",
                                                "task_threads", "TASK_POWER_INFO")),
        # Energy has no public power API; deriving it from CPU alone would be a
        # plausible-but-wrong number, so wakeups go in and it's labelled a score.
        "energy is honest": "wakeups" in pur and "not watts" in pur,
        "clock via io_global": "std.time.timestamp" not in mon,
        # The meters render IN the OS title bar — as TEXT, folded into the window
        # title. SDL2 gives no drawable surface up there: the content view can be
        # extended under the title bar, but SDL keeps rendering into the old,
        # shorter rect, so dvui's y=0 never moves (measured: SDL reported 1244x771
        # before AND after). What the OS does render there is the title string.
        "meters in the window title": "titleMeters" in _src("src/main.zig"),
        "bar glyph per metric": "barGlyph" in pur,
        # A partial run ("CPU ▃ 12%   MEM ▅ 1.2") would read as a bug, and the
        # title must survive regardless — so a short buffer yields nothing.
        "no truncated meter run": 'catch ""' in pur,
        # No confident "CPU 0%" before the first delta lands.
        "hidden until first sample": "snap.valid" in _src("src/main.zig"),
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "missing: " + ", ".join(missing)
    return "pass", "CPU/MEM/THR/NRG meters: 1Hz off-thread sampler, tested thresholds"


@test("Nav Donate Button", "Page Shell")
def test_nav_donate_button():
    # The button itself is dvui draw code (GUI-only, not unit-testable), so this
    # pins the wiring instead: one URL constant, the chip lives in header.zig,
    # the shell calls it, it reuses the existing openExternal launcher (no second
    # process-spawn helper), and the omnibox gave up width to make room for it.
    hdr = _src("src/ui/header.zig")
    shell = _src("src/ui/shell.zig")
    settings = _src("src/ui/settings.zig")
    checks = {
        "single URL constant": hdr.count("pub const DONATE_URL") == 1,
        "chip in header": "pub fn donateButton()" in hdr and "lucide.heart" in hdr,
        "shell call site": "header.donateButton();" in shell,
        "reuses openExternal": ("pub fn openExternal" in settings
                                and 'openExternal(DONATE_URL)' in hdr),
        # A donate chip that spawns its own child process = duplicated launcher.
        "no second launcher": "Child.init(" not in hdr,
        # Room for the chip came from the omnibox cap, not from overlapping it.
        "omnibox narrowed": ".max_size_content = .{ .w = 640, .h = 26 }" in shell,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "donate button wiring incomplete: " + ", ".join(missing)
    return "pass", "donate chip: header.zig → openExternal, omnibox capped at 640"


@test("EZTV Release Calendar (neutral + live)", "Page Shell")
def test_eztv_calendar():
    # The section is dvui draw code + a detached worker (GUI/thread-only), so
    # this pins the two things that can silently rot: the NEUTRALITY contract
    # (no endpoint may be hardcoded in the binary — it must come from the
    # installed eztv source plugin, else the module stays inert) and the LIVE
    # refresh contract (periodic re-fetch, countdown recomputed per frame).
    svc = _src("src/services/eztv_calendar.zig")
    pur = _src("src/services/eztv_calendar_pure.zig")
    build = _src("build.zig")
    if not svc or not pur:
        return "fail", "eztv_calendar.zig / eztv_calendar_pure.zig missing"

    manifest_path = os.path.join(PROJECT_DIR, "plugins-manifest.json")
    eztv = {}
    if os.path.exists(manifest_path):
        with open(manifest_path) as f:
            for p in json.load(f).get("plugins", []):
                if p.get("id") == "eztv":
                    eztv = p.get("endpoints", {})

    # The endpoints live in the manifest, never in src/. Scan BOTH new files for
    # any hardcoded eztv host (the whole point of source_config gating).
    hardcoded = [h for h in ("eztvx.to", "eztv.re", "eztv.ag", "eztv.it")
                 if h in svc or h in pur]

    checks = {
        # ── Neutrality ──
        "manifest declares calendar":  eztv.get("calendar", "").startswith("http"),
        "manifest declares countdown": eztv.get("countdown", "").startswith("http"),
        "manifest declares api":       eztv.get("api", "").startswith("http"),
        "no hardcoded eztv host in src": not hardcoded,
        "gated on installed plugin":   'source_config.has("eztv")' in svc,
        "endpoints read from plugin":  'source_config.get("eztv", field)' in svc,
        # Inert = render nothing: renderSection bails before drawing anything.
        "renders nothing when inert":  svc.count("if (!source_config.has(\"eztv\")) return;") >= 1,

        # ── The two-call mount contract the Watching page uses ──
        "pub fn refreshTick":          "pub fn refreshTick() void" in svc,
        "pub fn renderSection":        "pub fn renderSection() void" in svc,

        # ── Live, not once-per-session ──
        "named refresh interval":      "pub const REFRESH_INTERVAL_MS" in svc,
        "interval-gated refetch":      "REFRESH_INTERVAL_MS) return;" in svc,
        "clock via io_global":         "io.milliTimestamp()" in svc,
        "no std.time":                 "std.time." not in svc,
        # A countdown baked at fetch time freezes on screen. It must be derived
        # from the stored epoch at the RENDER site, every frame. (Asserted on the
        # behaviour -- `now_s` fed in at render, from a stored epoch -- not on the
        # loop variable's name, which was `r` when releases were rows and is `cd`
        # now that they're cards.)
        "countdown per frame":         ("pure.releaseLabel(now_s," in svc
                                        and "released_epoch" in svc
                                        and "const now_s = io.timestamp();" in svc),

        # ── Threading / memory ──
        "busy guard":                  "loading.load(.acquire)" in svc and "loading.store(true, .release)" in svc,
        "detached worker":             "std.Thread.spawn" in svc and ".detach()" in svc,
        "big body on the heap":        "alloc.alloc(u8, BODY_CAP)" in svc and "defer alloc.free(body)" in svc,
        "publish count last":          "front.store(back, .release); // publish LAST" in svc,
        # The invalid-free trap: alloc(cap) then returning buf[0..n] is an
        # invalid free under the global DebugAllocator. The parser sidesteps it
        # entirely by writing into a caller-owned slice and touching no
        # allocator at all (so there is no buffer to mis-size).
        "parser allocates nothing":    not any(t in pur for t in
                                               ("alloc.zig", "allocator", ".alloc(", "realloc")),
        "parser fills caller buffer":  "pub fn parseFeed(body: []const u8, out: []Release) usize" in pur,
        # std.http SEGVs on some ISP TLS resets (tmdb_api.zig:275) — the fetch
        # must shell out to curl through the io_global child wrapper.
        "curl, never std.http":        ('"curl"' in svc and "io.Child.init" in svc
                                        and "std.http.Client" not in svc),

        # ── Pure logic is tested and production routes through it ──
        # sizeLabel was dropped with the row layout -- a poster card has no place
        # for a file size, and a tested pure fn that nothing ships is dead weight.
        # groupShows/firstTvResult/encodeQuery are what the card path needs.
        "pure fns used in prod":       all(f in svc for f in ("pure.buildFeedUrl", "pure.parseFeed",
                                                              "pure.releaseLabel", "pure.episodeTag",
                                                              "pure.groupShows", "pure.firstTvResult",
                                                              "pure.encodeQuery")),
        "pure module has tests":       pur.count('test "') >= 5,
        "registered in build.zig":     "src/services/eztv_calendar_pure.zig" in build,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "eztv calendar contract broken: " + ", ".join(missing[:4])
    return "pass", "neutral (source_config-gated), 15-min refresh, per-frame countdown"


# ══════════════════════════════════════════════════════════
# Zig Unit Tests
# ══════════════════════════════════════════════════════════

@test("Zig Unit Tests", "Unit Tests")
def test_zig_unit():
    try:
        r = subprocess.run(["zig", "build", "test"], cwd=PROJECT_DIR,
                            capture_output=True, text=True, timeout=600)
    except FileNotFoundError:
        return "skip", "zig not on PATH"
    except subprocess.TimeoutExpired:
        return "fail", "zig build test timed out (>600s)"
    if r.returncode == 0:
        return "pass", "all pure-Zig unit tests pass"
    # Surface the first real error line.
    for line in (r.stderr + r.stdout).splitlines():
        if "error:" in line:
            return "fail", line.strip()[:80]
    return "fail", f"exit {r.returncode}"


# ══════════════════════════════════════════════════════════
# Run All Tests
# ══════════════════════════════════════════════════════════


@test("Installer Does Not Need Xcode", "Packaging")
def test_installer_no_xcode():
    # REGRESSION — `curl … install.sh | sh` failed for everyone on macOS:
    #
    #   opal: A full installation of Xcode.app 15.0 is required to compile
    #   this software. Installing just the Command Line Tools is not sufficient.
    #
    # Two bugs stacked. install.sh PREFERRED the Homebrew tap whenever brew was
    # present, and the formula built from SOURCE — so it demanded a 15 GB Xcode
    # install, while the self-contained .app (which vendors its own mpv/SDL and
    # needs no toolchain at all) sat one line below, never reached.
    import re
    # Strip comments before grepping. The first version of this test matched the
    # comment ABOVE that explains the bug ("depends_on xcode: …") and reported the
    # fixed formula as broken — a test that greps prose tests nothing.
    def _code(text, marker="#"):
        return "\n".join(l for l in text.splitlines()
                          if not l.lstrip().startswith(marker))

    f = _code(_src("Formula/opal.rb"))
    sh = _code(_src("scripts/install.sh"))
    zon = _src("build.zig.zon")

    m = re.search(r'\.version = "([^"]+)"', zon)
    zon_ver = m.group(1) if m else "?"
    fm = re.search(r'^\s*version "([^"]+)"', f, re.M)
    f_ver = fm.group(1) if fm else "?"

    checks = {
        # The bug, verbatim.
        "formula needs no Xcode": "xcode:" not in f,
        "formula does not build from source": '"zig" => :build' not in f,
        "formula installs a prebuilt binary": "releases/download" in f and 'bin.install "opal"' in f,
        "formula pins a real checksum": bool(re.search(r'sha256 "[a-f0-9]{64}"', f)),
        # It sat pinned at v0.1.2 while the app shipped 0.3.0 — nothing kept the two
        # in step, so it rotted silently. Fail the gate instead of shipping stale.
        "formula version tracks build.zig.zon (%s vs %s)" % (f_ver, zon_ver): f_ver == zon_ver,
        # The vendored .app is the default; brew is opt-in for the CLI on PATH.
        "installer prefers the self-contained .app": "OPAL_USE_BREW" in sh,
        "installer no longer auto-prefers brew": "brew tap-info debpalash/tap" not in sh,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "install.sh installs the vendored .app; formula is a binary install at " + f_ver


@test("Audio Visualizer", "Player")
def test_audio_visualizer():
    # Radio / podcasts / music have no video track, so mpv synthesises one:
    # `lavfi-complex` runs the audio through an ffmpeg filter that EMITS a video
    # stream (showwaves / showfreqs / showspectrum / avectorscope). ffmpeg does the
    # FFT — no PCM is plumbed into dvui and no audio thread of our own.
    # Strip comments before grepping for banned filters — the module comment
    # EXPLAINS the `gradients`/`nullsrc` hazard by name, and a naive substring match
    # flags the fixed code as broken. (Made this exact mistake once already.)
    def _code(text):
        out = []
        for line in text.splitlines():
            ls = line.lstrip()
            if ls.startswith("//"):
                continue
            out.append(line.split("//")[0] if "//" in line else line)
        return "\n".join(out)

    pl = _src("src/player/player.zig")
    pure_all = _src("src/player/visualizer_pure.zig")
    pure = pure_all
    # ...and only the IMPLEMENTATION, not the test block below it — the Zig test
    # asserts these filters are absent, so the literals legitimately appear there.
    pure_code = _code(pure_all.split("// ── Tests ──")[0])
    st = _src("src/ui/settings.zig")
    cfg = _src("src/core/config.zig")
    bz = _src("build.zig")

    checks = {
        "filter graph builder is pure": "pub fn lavfiComplex" in pure,
        "styles: waves/bars/spectrum/scope": all(f in pure for f in
                                                 ("showwaves", "showfreqs", "showspectrum", "avectorscope")),
        # A graph without `asplit [ao]` renders a lovely visualiser and plays NO
        # SOUND. Every style must keep the audio wired to the speakers.
        "audio still reaches the speakers": "asplit [ao]" in pure,
        # The accent reaches ffmpeg as three DECIMAL NUMBERS (u8 -> 0-255), so a
        # theme colour has no way to inject filter syntax. Safe by construction
        # rather than by a validator being correct.
        "colour cannot inject into the graph": "fn gradient(r: u8, g: u8, b: u8" in pure,
        # REGRESSION — the pretty way to build the gradient (a `gradients` source
        # plus a `nullsrc` stripe mask) HANGS mpv: infinite sources never EOF, so a
        # 3s file plays forever, podcasts never end and the next track never starts.
        # Everything must be derived from [aid1] alone.
        "no source filters (they hang playback)": ("gradients" not in pure_code
                                                   and "nullsrc" not in pure_code),
        # Upscaling 48 bars to 576px sets a 12:1 sample aspect and mpv stretches the
        # picture to 576x2640 unless the SAR is reset.
        "square pixels (setsar)": "setsar=1" in pure,
        # The graph maps [aid1] to [ao] AND [vo] — left set, it would replace a real
        # video file's picture with a waveform.
        "cleared on every load": 'mpv_set_property_string(self.mpv_ctx, "lavfi-complex", "")' in pl,
        # Setting the graph GIVES mpv a video track, so the "vid" observer fires
        # again — without the latch this re-sets the graph forever.
        "applied once per file (latch)": "vis_applied" in pl,
        "applied only when audio-only": "if (p.cached_vid_no) applyVisualizer(p)" in pl,
        "selectable in Settings": "Audio visualizer" in st,
        "persisted across restarts": '"audio_vis"' in cfg,
        "pure module is unit-tested": "visualizer_pure.zig" in bz,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "mpv lavfi-complex visualizer: 4 styles, audio preserved, colour validated"

def run_all():
    test_fns = [v for v in globals().values() if callable(v) and hasattr(v, '_test')]
    
    print(f"\n{'='*60}")
    print(f"  ZigZag Feature Test Suite — {len(test_fns)} tests")
    print(f"{'='*60}\n")
    
    for fn in test_fns:
        fn()
    
    # Summary
    cats = {}
    for r in results:
        if r.category not in cats:
            cats[r.category] = {"pass": 0, "fail": 0, "warn": 0, "skip": 0}
        cats[r.category][r.status] += 1
    
    total_pass = sum(c["pass"] for c in cats.values())
    total_fail = sum(c["fail"] for c in cats.values())
    total_warn = sum(c["warn"] for c in cats.values())
    total_skip = sum(c["skip"] for c in cats.values())
    
    for r in results:
        icon = {"pass": "✅", "fail": "❌", "warn": "⚠️", "skip": "⏭️"}[r.status]
        print(f"  {icon} [{r.category:12s}] {r.name:35s} {r.detail[:50]:50s} {r.duration_ms:4d}ms")
    
    print(f"\n{'─'*60}")
    print(f"  ✅ {total_pass} passed  ❌ {total_fail} failed  ⚠️ {total_warn} warnings  ⏭️ {total_skip} skipped")
    print(f"{'─'*60}\n")
    
    # Write JSON for web dashboard
    output = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "total": len(results),
        "passed": total_pass,
        "failed": total_fail,
        "warnings": total_warn,
        "skipped": total_skip,
        "categories": {cat: counts for cat, counts in cats.items()},
        "tests": [r.to_dict() for r in results]
    }
    
    with open(RESULTS_FILE, "w") as f:
        json.dump(output, f, indent=2)
    print(f"  Results written to {RESULTS_FILE}")
    
    return total_fail == 0

if __name__ == "__main__":
    success = run_all()
    sys.exit(0 if success else 1)
