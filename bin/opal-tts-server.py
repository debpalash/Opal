#!/usr/bin/env python3
"""Opal persistent TTS server (Unix socket).

Synthesizes speech to a WAV the Zig side then plays with afplay/aplay.
Protocol (matches ai_voice.speakViaServer):

    socket: /tmp/opal-tts.sock
    output: /tmp/opal_ai_tts.wav
    client -> server : "<text to speak>"
    server -> client : "OK"                on success (WAV written)
                       "ERROR: <reason>"    on failure

Backend order:
    1. KittenTTS (lightweight ONNX neural TTS) if installed.
    2. macOS `say` writing a WAV (always available on macOS).

Voice/speed come from env (OPAL_TTS_VOICE / OPAL_TTS_SPEED) so the
Zig settings can influence output without changing the protocol.
"""
import os
import socket
import subprocess
import sys

SOCK_PATH = "/tmp/opal-tts.sock"
OUT_WAV = "/tmp/opal_ai_tts.wav"


def _eprint(*a):
    print(*a, file=sys.stderr, flush=True)


def _load_kitten():
    """Return a synth(text)->bool callable, or None if KittenTTS is absent."""
    try:
        from kittentts import KittenTTS
    except Exception as e:  # noqa: BLE001
        _eprint(f"KittenTTS not available, using macOS say: {e}")
        return None

    voice = os.environ.get("OPAL_TTS_VOICE", os.environ.get("ZIGZAG_TTS_VOICE", "Bella"))
    try:
        speed = float(os.environ.get("OPAL_TTS_SPEED", os.environ.get("ZIGZAG_TTS_SPEED", "1.0")))
    except ValueError:
        speed = 1.0
    tts = KittenTTS()

    def synth(text: str) -> bool:
        try:
            tts.generate_to_file(text, OUT_WAV, voice=voice, speed=speed)
            return os.path.exists(OUT_WAV)
        except Exception as e:  # noqa: BLE001
            _eprint(f"kitten synth failed: {e}")
            return False

    return synth


def _say_synth(text: str) -> bool:
    """macOS `say` → 16-bit PCM WAV. No-op on non-macOS."""
    if sys.platform != "darwin":
        return False
    try:
        subprocess.run(
            ["say", "-o", OUT_WAV, "--data-format=LEI16@22050", text],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return os.path.exists(OUT_WAV)
    except Exception as e:  # noqa: BLE001
        _eprint(f"say synth failed: {e}")
        return False


def main() -> int:
    # Fast dependency preflight: the warm TTS server only earns its keep when
    # neural TTS (KittenTTS) is present — otherwise ai_voice uses `say` inline.
    if "--check" in sys.argv:
        try:
            import kittentts  # noqa: F401
            return 0
        except Exception:  # noqa: BLE001
            return 4

    synth = _load_kitten()

    try:
        os.unlink(SOCK_PATH)
    except FileNotFoundError:
        pass

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK_PATH)
    srv.listen(4)
    _eprint(f"opal-tts-server listening on {SOCK_PATH}")

    while True:
        try:
            conn, _ = srv.accept()
        except KeyboardInterrupt:
            break
        with conn:
            try:
                data = conn.recv(8192)
                if not data:
                    continue
                text = data.decode("utf-8", "replace").strip()
                ok = False
                if synth is not None:
                    ok = synth(text)
                if not ok:
                    ok = _say_synth(text)
                conn.sendall(b"OK" if ok else b"ERROR: synthesis failed")
            except Exception as e:  # noqa: BLE001
                try:
                    conn.sendall(f"ERROR: {e}".encode("utf-8"))
                except OSError:
                    pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
