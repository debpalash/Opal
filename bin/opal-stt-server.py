#!/usr/bin/env python3
"""Opal persistent STT server (Unix socket).

Keeps a faster-whisper model warm so repeated transcriptions skip the
cold-start cost. Protocol (matches ai_voice.transcribeViaServer):

    socket: /tmp/opal-stt.sock
    client -> server : "<path-to-wav>"          (one write, no newline needed)
    server -> client : "<transcript>"           on success
                       "ERROR: <reason>"         on failure

Exits cleanly (non-zero) if faster-whisper is unavailable, so the Zig
caller never starts depending on a socket that won't appear.
"""
import os
import socket
import sys

SOCK_PATH = "/tmp/opal-stt.sock"


def _eprint(*a):
    print(*a, file=sys.stderr, flush=True)


def main() -> int:
    try:
        from faster_whisper import WhisperModel
    except Exception as e:  # noqa: BLE001
        _eprint(f"faster-whisper not available: {e}")
        return 4

    # Fast dependency preflight (see opal-voice-server.py).
    if "--check" in sys.argv:
        return 0

    model_name = os.environ.get("OPAL_STT_MODEL", os.environ.get("ZIGZAG_STT_MODEL", "base.en"))
    try:
        model = WhisperModel(model_name, device="cpu", compute_type="int8")
    except Exception as e:  # noqa: BLE001
        _eprint(f"model load failed: {e}")
        return 5

    # Fresh socket each launch — Zig deletes stale ones, but be defensive.
    try:
        os.unlink(SOCK_PATH)
    except FileNotFoundError:
        pass

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK_PATH)
    srv.listen(4)
    _eprint(f"opal-stt-server listening on {SOCK_PATH} (model={model_name})")

    def transcribe(path: str) -> str:
        if not os.path.exists(path):
            return f"ERROR: no such file: {path}"
        try:
            segments, _ = model.transcribe(path, beam_size=1, vad_filter=True)
            return " ".join(s.text.strip() for s in segments).strip()
        except Exception as e:  # noqa: BLE001
            return f"ERROR: {e}"

    while True:
        try:
            conn, _ = srv.accept()
        except KeyboardInterrupt:
            break
        with conn:
            try:
                data = conn.recv(4096)
                if not data:
                    continue
                wav = data.decode("utf-8", "replace").strip()
                conn.sendall(transcribe(wav).encode("utf-8"))
            except Exception as e:  # noqa: BLE001
                try:
                    conn.sendall(f"ERROR: {e}".encode("utf-8"))
                except OSError:
                    pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
