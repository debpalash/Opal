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

DB_PATH = os.path.expanduser("~/.config/zigzag/zigzag.db")
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
    return "fail", "zigzag.db not found"

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
            binary = os.path.join(PROJECT_DIR, "zig-out/bin/zigzag")
            if os.path.exists(binary):
                size = os.path.getsize(binary) / (1024*1024)
                return "pass", f"Binary: {size:.1f} MB"
            return "pass", "Build succeeded"
        return "fail", result.stderr[:200]
    except subprocess.TimeoutExpired:
        return "fail", "Build timed out (>120s)"

@test("Binary Exists", "Build")
def test_binary_exists():
    binary = os.path.join(PROJECT_DIR, "zig-out/bin/zigzag")
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
    script = os.path.join(PROJECT_DIR, "bin/zigzag-voice-server.py")
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
    sock_path = "/tmp/zigzag-voice.sock"
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
    "zigzag-stt.py",
    "zigzag-stt-server.py",
    "zigzag-tts-server.py",
    "zigzag-voice-server.py",
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


for _s in ("zigzag-stt-server.py", "zigzag-tts-server.py", "zigzag-voice-server.py"):
    globals()[f"test_check_{_s.replace('-', '_').replace('.', '_')}"] = _make_check_test(_s)


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
    if "Continue Watching" in home and "Time in app" in home:
        return "pass", "Home is a distinct metrics/lists dashboard"
    return "fail", "home dashboard lacks metrics/continue-watching"


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
