# `bin/` — voice helper scripts & runtime models

This directory holds two kinds of things:

- **Tracked source** (committed): the `opal-*.py` voice helpers below.
- **Runtime artifacts** (gitignored): downloaded ML models such as
  `bin/whisper.cpp/models/*.bin`.

The Zig app shells out to these scripts by path (see
[`src/services/ai_voice.zig`](../src/services/ai_voice.zig)). Every script
degrades gracefully — if a Python dependency is missing it exits non-zero,
and the Zig caller falls back to the next strategy in its chain.

## Scripts

| Script | Role | Socket / output |
| --- | --- | --- |
| `opal-stt.py` | One-shot transcription of a WAV → stdout | — |
| `opal-stt-server.py` | Warm STT server (model stays loaded) | `/tmp/opal-stt.sock` |
| `opal-tts-server.py` | Warm TTS server (text → WAV) | `/tmp/opal-tts.sock` → `/tmp/opal_ai_tts.wav` |
| `opal-voice-server.py` | Continuous VAD conversation + barge-in | `/tmp/opal-voice.sock` |

## Voice paths (no Python required)

The app works out of the box on macOS with **zero** Python deps:

- **Mic** — `ffmpeg` (`brew install ffmpeg`)
- **STT** — `whisper-cli` (`brew install whisper-cpp`) + a ggml model at
  `bin/whisper.cpp/models/ggml-base.en.bin`:
  ```sh
  mkdir -p bin/whisper.cpp/models
  curl -L -o bin/whisper.cpp/models/ggml-base.en.bin \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
  ```
- **TTS** — macOS `say`
- **LLM** — the bundled HF-served model (AI tab)

## Upgrading to the neural / hands-free paths (optional)

```sh
python3 -m pip install -r bin/requirements.txt
```

This enables faster-whisper STT (better accuracy, HF-hosted models), the
warm STT/TTS servers, KittenTTS, and the continuous hands-free
conversation server with barge-in.

### Environment overrides

| Variable | Default | Effect |
| --- | --- | --- |
| `OPAL_STT_MODEL` | `base.en` | faster-whisper model size (`tiny.en`, `small.en`, …) |
| `OPAL_TTS_VOICE` | `Bella` | KittenTTS voice |
| `OPAL_TTS_SPEED` | `1.0` | KittenTTS speed multiplier |
