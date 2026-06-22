#!/usr/bin/env python3
"""zigzag continuous voice server (Unix socket) — hands-free conversation.

Runs the mic continuously, detects speech with VAD, transcribes each
utterance, and supports barge-in (interrupting TTS by speaking).

Protocol (matches ai_voice.conversationLoopV2):

    socket: /tmp/zigzag-voice.sock
    client -> server (newline-terminated commands):
        RESUME         start/continue listening
        PAUSE          stop listening
        DUCK           media started — raise speech threshold
        UNDUCK         media stopped — restore threshold
        SPEAKING       TTS is playing — watch for barge-in
        DONE_SPEAKING  TTS finished — resume normal listening
    server -> client (newline-terminated events):
        VAD:start          speech onset
        VAD:end            speech offset
        PARTIAL:<text>     interim transcript (best-effort)
        TRANSCRIPT:<text>  final transcript for the utterance
        BARGEIN            user spoke while TTS was playing

Dependencies: sounddevice + faster-whisper (and optionally webrtcvad for
better VAD; falls back to an RMS energy gate). Exits non-zero if a hard
dependency is missing so the Zig caller falls back to its ffmpeg path.
"""
import os
import socket
import sys
import threading
import time

SOCK_PATH = "/tmp/zigzag-voice.sock"
SAMPLE_RATE = 16000
FRAME_MS = 30
FRAME_SAMPLES = SAMPLE_RATE * FRAME_MS // 1000  # 480 samples @ 16k/30ms


def _eprint(*a):
    print(*a, file=sys.stderr, flush=True)


# ── VAD: prefer webrtcvad, fall back to an RMS energy gate ──
class EnergyVad:
    def __init__(self):
        self.threshold = 500.0  # int16 RMS; tuned at runtime via DUCK/UNDUCK

    def is_speech(self, pcm16: bytes, _rate: int) -> bool:
        import numpy as np

        arr = np.frombuffer(pcm16, dtype=np.int16).astype(np.float32)
        if arr.size == 0:
            return False
        rms = float(np.sqrt(np.mean(arr * arr)))
        return rms >= self.threshold

    def duck(self):
        self.threshold = 1100.0

    def unduck(self):
        self.threshold = 500.0


class WebrtcVad:
    def __init__(self, vad):
        self._vad = vad
        self._aggr = 2

    def is_speech(self, pcm16: bytes, rate: int) -> bool:
        try:
            return self._vad.is_speech(pcm16, rate)
        except Exception:  # noqa: BLE001 — odd frame size etc.
            return False

    def duck(self):
        self._aggr = 3
        self._vad.set_mode(3)

    def unduck(self):
        self._aggr = 2
        self._vad.set_mode(2)


def _make_vad():
    try:
        import webrtcvad

        return WebrtcVad(webrtcvad.Vad(2))
    except Exception as e:  # noqa: BLE001
        _eprint(f"webrtcvad unavailable, using energy VAD: {e}")
        return EnergyVad()


class VoiceServer:
    def __init__(self, model, vad):
        self.model = model
        self.vad = vad
        self.conn = None
        self.lock = threading.Lock()
        # control state
        self.listening = False     # RESUME/PAUSE
        self.speaking = False      # SPEAKING/DONE_SPEAKING (barge-in window)
        self.running = True
        self._barged = False

    # ── socket I/O ──
    def send(self, msg: str):
        with self.lock:
            if self.conn is None:
                return
            try:
                self.conn.sendall((msg + "\n").encode("utf-8"))
            except OSError:
                self.running = False

    def _command_reader(self):
        buf = b""
        while self.running:
            try:
                data = self.conn.recv(256)
            except OSError:
                break
            if not data:
                break
            buf += data
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                self._handle_command(line.decode("utf-8", "replace").strip())
        self.running = False

    def _handle_command(self, cmd: str):
        if cmd == "RESUME":
            self.listening = True
        elif cmd == "PAUSE":
            self.listening = False
        elif cmd == "DUCK":
            self.vad.duck()
        elif cmd == "UNDUCK":
            self.vad.unduck()
        elif cmd == "SPEAKING":
            self.speaking = True
            self._barged = False
        elif cmd == "DONE_SPEAKING":
            self.speaking = False
            self._barged = False

    # ── transcription ──
    def _transcribe(self, frames):
        import numpy as np

        pcm = b"".join(frames)
        audio = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
        try:
            segments, _ = self.model.transcribe(audio, beam_size=1, language="en")
            return " ".join(s.text.strip() for s in segments).strip()
        except Exception as e:  # noqa: BLE001
            _eprint(f"transcribe failed: {e}")
            return ""

    # ── main audio loop ──
    def run(self, conn):
        import sounddevice as sd

        self.conn = conn
        threading.Thread(target=self._command_reader, daemon=True).start()

        speech_frames = []
        in_speech = False
        silence_run = 0
        speech_run = 0
        # ~600ms of trailing silence ends an utterance; ~150ms of speech
        # during TTS counts as a barge-in.
        silence_end_frames = max(1, 600 // FRAME_MS)
        bargein_frames = max(1, 150 // FRAME_MS)

        with sd.RawInputStream(
            samplerate=SAMPLE_RATE,
            blocksize=FRAME_SAMPLES,
            dtype="int16",
            channels=1,
        ) as stream:
            _eprint("zigzag-voice-server: mic open, awaiting RESUME")
            while self.running:
                pcm, _overflow = stream.read(FRAME_SAMPLES)
                pcm = bytes(pcm)
                speech = self.vad.is_speech(pcm, SAMPLE_RATE)

                # Barge-in detection while TTS is playing.
                if self.speaking:
                    speech_run = speech_run + 1 if speech else 0
                    if speech_run >= bargein_frames and not self._barged:
                        self._barged = True
                        self.send("BARGEIN")
                    continue

                if not self.listening:
                    in_speech = False
                    speech_frames = []
                    continue

                if speech:
                    if not in_speech:
                        in_speech = True
                        speech_frames = []
                        self.send("VAD:start")
                    speech_frames.append(pcm)
                    silence_run = 0
                elif in_speech:
                    speech_frames.append(pcm)
                    silence_run += 1
                    if silence_run >= silence_end_frames:
                        in_speech = False
                        silence_run = 0
                        self.send("VAD:end")
                        text = self._transcribe(speech_frames)
                        speech_frames = []
                        if text:
                            self.send("TRANSCRIPT:" + text)


def main() -> int:
    try:
        import sounddevice  # noqa: F401
    except Exception as e:  # noqa: BLE001
        _eprint(f"sounddevice not available: {e}")
        return 4
    try:
        import numpy  # noqa: F401
    except Exception as e:  # noqa: BLE001
        _eprint(f"numpy not available: {e}")
        return 4
    try:
        from faster_whisper import WhisperModel
    except Exception as e:  # noqa: BLE001
        _eprint(f"faster-whisper not available: {e}")
        return 4

    # Fast dependency preflight: `--check` verifies imports (no model load)
    # so the Zig caller can skip the spawn-and-wait when deps are missing.
    if "--check" in sys.argv:
        return 0

    model_name = os.environ.get("ZIGZAG_STT_MODEL", "base.en")
    try:
        model = WhisperModel(model_name, device="cpu", compute_type="int8")
    except Exception as e:  # noqa: BLE001
        _eprint(f"model load failed: {e}")
        return 5

    vad = _make_vad()

    try:
        os.unlink(SOCK_PATH)
    except FileNotFoundError:
        pass

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK_PATH)
    srv.listen(1)
    _eprint(f"zigzag-voice-server listening on {SOCK_PATH} (model={model_name})")

    while True:
        try:
            conn, _ = srv.accept()
        except KeyboardInterrupt:
            break
        server = VoiceServer(model, vad)
        try:
            server.run(conn)
        except Exception as e:  # noqa: BLE001
            _eprint(f"session ended: {e}")
        finally:
            try:
                conn.close()
            except OSError:
                pass
        # brief pause so a reconnect storm can't spin the CPU
        time.sleep(0.1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
