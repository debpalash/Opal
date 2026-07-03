#!/usr/bin/env python3
"""Opal one-shot STT — transcribe a WAV file to stdout.

Usage:  python3 bin/opal-stt.py /path/to/audio.wav

Prints the transcript to stdout (one line) and exits 0 on success.
On any failure it prints nothing to stdout and exits non-zero, so the
Zig caller (ai_voice.transcribeAndSend) cleanly falls through to its
whisper.cpp fallback.

Backend: faster-whisper (CTranslate2). The model is pulled from the
Hugging Face hub on first run and cached under ~/.cache. Override the
model size with OPAL_STT_MODEL (tiny.en / base.en / small.en / ...).
"""
import os
import sys


def _eprint(*a):
    print(*a, file=sys.stderr, flush=True)


def main() -> int:
    if len(sys.argv) < 2:
        _eprint("usage: opal-stt.py <wav>")
        return 2
    wav = sys.argv[1]
    if not os.path.exists(wav):
        _eprint(f"no such file: {wav}")
        return 3

    try:
        from faster_whisper import WhisperModel
    except Exception as e:  # noqa: BLE001 — any import failure → fall through
        _eprint(f"faster-whisper not available: {e}")
        return 4

    model_name = os.environ.get("OPAL_STT_MODEL", os.environ.get("ZIGZAG_STT_MODEL", "base.en"))
    try:
        # CPU + int8 is the portable default; fast enough for short clips.
        model = WhisperModel(model_name, device="cpu", compute_type="int8")
        segments, _info = model.transcribe(wav, beam_size=1, vad_filter=True)
        text = " ".join(seg.text.strip() for seg in segments).strip()
    except Exception as e:  # noqa: BLE001
        _eprint(f"transcribe failed: {e}")
        return 5

    if not text:
        return 6
    print(text, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
