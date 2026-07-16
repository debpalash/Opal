"""Auto-split from tests/test_features.py — Voice pipeline / Voice scripts / ASR streaming tests.
Byte-for-byte identical test bodies; see tests/features/harness.py for the
shared @test decorator, helpers, and run_all()."""
from .harness import *  # noqa: F401,F403
import os, sys, subprocess, sqlite3, socket, time, json  # noqa: F401

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
