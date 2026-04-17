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
    return "fail", "zigzag-voice-server.py missing"

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
        return "fail", result.stderr[:100]
    except:
        return "fail", "Python/torch not available"

@test("Faster-Whisper Available", "Voice")
def test_faster_whisper():
    try:
        result = subprocess.run(
            ["python3", "-c", "from faster_whisper import WhisperModel; print('ok')"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            return "pass", "faster-whisper importable"
        return "fail", result.stderr[:100]
    except:
        return "fail", "Import failed"

@test("KittenTTS Available", "Voice")
def test_kittentts():
    try:
        result = subprocess.run(
            ["python3", "-c", "from kittentts import KittenTTS; print('ok')"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            return "pass", "kittentts importable"
        return "fail", result.stderr[:100]
    except:
        return "fail", "Import failed"

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
    ui_file = os.path.join(PROJECT_DIR, "src/ui/ui.zig")
    with open(ui_file) as f:
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
