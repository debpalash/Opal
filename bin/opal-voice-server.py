#!/usr/bin/env python3
"""Opal continuous voice server (Unix socket) — hands-free conversation.

Runs the mic continuously, detects speech with VAD, transcribes each
utterance, and supports barge-in (interrupting TTS by speaking).

Protocol (matches ai_voice.conversationLoopV2):

    socket: /tmp/opal-voice.sock
    client -> server (newline-terminated commands):
        RESUME            start/continue listening
        PAUSE             stop listening
        DUCK              media started — raise speech threshold
        UNDUCK            media stopped — restore threshold
        SPEAKING          TTS is playing — watch for barge-in
        SPEAKING:<text>   TTS is playing THIS text — enables the semantic echo
                          guard so the assistant's own voice (heard back through
                          open speakers) is not mistaken for a barge-in
        DONE_SPEAKING     TTS finished — resume normal listening
    server -> client (newline-terminated events):
        VAD:start          speech onset
        VAD:end            speech offset
        PARTIAL:<text>     interim transcript, streamed live while speaking
        TRANSCRIPT:<text>  final transcript for the utterance
        BARGEIN            user spoke (NOT echo) while TTS was playing

Dependencies: sounddevice + faster-whisper (and optionally webrtcvad for
better VAD; falls back to an RMS energy gate). Exits non-zero if a hard
dependency is missing so the Zig caller falls back to its ffmpeg path.
"""
import difflib
import os
import socket
import sys
import threading
import time

SOCK_PATH = "/tmp/opal-voice.sock"
DEBUG = bool(os.environ.get("OPAL_VOICE_DEBUG"))
SAMPLE_RATE = 16000
FRAME_MS = 30
FRAME_SAMPLES = SAMPLE_RATE * FRAME_MS // 1000  # 480 samples @ 16k/30ms


def _eprint(*a):
    print(*a, file=sys.stderr, flush=True)


# Whisper reliably hallucinates these on short/noisy fragments (it was trained on
# subtitle data). Treating them as real speech during TTS produced FALSE barge-ins:
# 300ms of the assistant's own echo transcribed to "Thank you." and, not matching
# the spoken text, was read as an interruption.
_HALLUCINATIONS = {
    "", ".", "you", "thank you", "bye", "okay", "ok", "so", "um", "uh", "yeah",
}
# Whisper was trained on subtitles, so on speaker echo it emits whole sign-off
# phrases verbatim. Measured live: the assistant's own TTS came back as
# "We will see you in the next video." — matching no part of the spoken sentence,
# so the semantic guard read it as a real interruption and the assistant cut
# itself off mid-reply. Substring-matched, because the drift varies run to run.
_HALLUCINATION_PHRASES = (
    "thanks for watching", "thank you for watching", "see you in the next video",
    "see you next time", "see you next week", "please subscribe", "subscribe to",
    "like and subscribe", "subtitles by", "amara org", "transcription by",
    "we will see you", "i will see you", "see you in the next",
)


# Saying any of these while the assistant is talking always interrupts it, even
# if it happens to overlap the sentence being spoken. "stop" is the single most
# natural barge-in and must never be swallowed by the echo guard.
_INTERRUPT_WORDS = {
    "stop", "no", "nope", "wait", "cancel", "quiet", "enough", "shut", "nevermind",
}


def _is_hallucination(text: str) -> bool:
    n = _normalize(text)
    if n in _HALLUCINATIONS:
        return True
    return any(p in n for p in _HALLUCINATION_PHRASES)


def _normalize(text: str) -> str:
    """Lowercase, strip punctuation, collapse whitespace — for echo-overlap
    comparison between the assistant's TTS text and captured mic speech."""
    out = []
    for ch in text.lower():
        out.append(ch if (ch.isalnum() or ch.isspace()) else " ")
    return " ".join("".join(out).split())


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
        self.speaking_text = ""    # normalized words the assistant is speaking now
        self.running = True
        self._barged = False
        # Partial transcription runs OFF the capture thread (see run()); these
        # coordinate it. `_tx_lock` serializes model access — faster-whisper is
        # one model instance and a partial must never overlap the final.
        self._tx_lock = threading.Lock()
        self._partial_busy = False
        self._utt = 0              # utterance generation; stale partials are dropped

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
        elif cmd == "SPEAKING" or cmd.startswith("SPEAKING:"):
            # `SPEAKING:<text>` carries the exact sentence the assistant is about
            # to say, so the echo guard can tell the AI's own voice apart from a
            # real interruption. Bare `SPEAKING` (no text) keeps the old
            # energy-only behaviour for older callers.
            self.speaking = True
            self._barged = False
            self.speaking_text = _normalize(cmd[len("SPEAKING:"):]) if cmd.startswith("SPEAKING:") else ""
        elif cmd == "DONE_SPEAKING":
            self.speaking = False
            self._barged = False
            self.speaking_text = ""

    # ── transcription ──
    def _transcribe(self, frames):
        import numpy as np

        pcm = b"".join(frames)
        audio = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
        # One model instance: serialize so an in-flight partial can't overlap the
        # final transcribe (or another partial).
        with self._tx_lock:
            try:
                # without_timestamps + no cross-segment conditioning: this runs on
                # the interactive path (live partials, barge-in decisions), so
                # latency matters more than transcript polish.
                segments, _ = self.model.transcribe(
                    audio, beam_size=1, language="en",
                    without_timestamps=True, condition_on_previous_text=False,
                )
                return " ".join(s.text.strip() for s in segments).strip()
            except Exception as e:  # noqa: BLE001
                _eprint(f"transcribe failed: {e}")
                return ""

    def _partial_worker(self, frames, utt):
        """Transcribe an in-progress utterance and emit PARTIAL:. Runs on its own
        thread — transcription takes hundreds of ms and MUST NOT block the audio
        capture loop, or mic frames are dropped, the utterance is truncated, and
        the final transcript comes back empty."""
        try:
            text = self._transcribe(frames)
            # Drop the result if the utterance already ended (the final wins) or
            # a new one began — otherwise a late PARTIAL lands after TRANSCRIPT.
            stale = self._utt != utt
            if DEBUG:
                _eprint(f"[dbg] partial: frames={len(frames)} utt={utt} cur={self._utt} "
                        f"stale={stale} speaking={self.speaking} text={text!r}")
            if text and not stale and not self.speaking:
                self.send("PARTIAL:" + text)
        finally:
            self._partial_busy = False

    def _is_echo(self, text: str) -> bool:
        """True if `text` is (mostly) the assistant's own TTS heard back through
        open speakers, rather than a genuine interruption. Without acoustic echo
        cancellation this is what keeps full-duplex barge-in from firing on the
        AI's own voice. If we don't know what's being spoken (bare SPEAKING),
        nothing is treated as echo — energy alone decides.

        Matching must be FUZZY. Echo picked up off a speaker is garbled by the
        recognizer ("comedies"→"commie", "great"→"grade"), so exact word overlap
        badly under-counts: measured 'You are a three-grade commie' against
        'here are three great comedies…' scores only 3/6 exact — under any sane
        threshold — and the assistant then interrupts itself."""
        if _is_hallucination(text):
            return True  # whisper filler on a short/echoey fragment — never a real turn
        cand = _normalize(text)
        if not cand:
            return True
        if not self.speaking_text:
            return False
        cand_words = cand.split()
        if not cand_words:
            return True

        # An explicit interrupt always cuts through, even mid-word-overlap.
        if any(w in _INTERRUPT_WORDS for w in cand_words):
            return False

        spoken_words = self.speaking_text.split()
        spoken_set = set(spoken_words)

        exact = sum(1 for w in cand_words if w in spoken_set) / len(cand_words)
        fuzzy = sum(
            1 for w in cand_words
            if difflib.get_close_matches(w, spoken_words, n=1, cutoff=0.7)
        ) / len(cand_words)
        ratio = difflib.SequenceMatcher(None, cand, self.speaking_text).ratio()

        if exact >= 0.6 or fuzzy >= 0.6 or ratio >= 0.5:
            return True
        # Too little signal to justify cutting the assistant off mid-sentence:
        # a genuine interruption is a phrase (or an explicit stop word, handled
        # above), not a two-word garble of our own audio.
        return len(cand_words) < 3

    # ── main audio loop ──
    def run(self, conn):
        import sounddevice as sd

        self.conn = conn
        threading.Thread(target=self._command_reader, daemon=True).start()

        speech_frames = []
        in_speech = False
        silence_run = 0
        # ~600ms of trailing silence ends an utterance. Barge-in needs enough
        # audio to transcribe for the echo check, so it collects ~300ms of
        # speech during TTS before deciding.
        silence_end_frames = max(1, 600 // FRAME_MS)
        # Needs ~0.9s of speech before deciding: at 300ms whisper hallucinates
        # ("Thank you.") from the assistant's own echo, which doesn't match the
        # spoken text and fires a FALSE barge-in. Longer window = reliable echo
        # comparison, at the cost of ~0.9s interrupt latency.
        bargein_frames = max(1, 900 // FRAME_MS)
        # A pause longer than this means the speaker stopped — drop the candidate.
        bargein_gap_frames = max(1, 400 // FRAME_MS)
        bargein_silence = 0
        # Live partials: re-transcribe the growing utterance at most this often.
        # Needs ~0.5s of audio before whisper returns anything useful (a 300ms
        # fragment transcribes to ""), then refresh every ~400ms.
        partial_every_frames = max(1, 400 // FRAME_MS)
        partial_min_frames = max(1, 500 // FRAME_MS)
        frames_since_partial = 0
        # Barge-in candidate buffer (only used while self.speaking).
        bargein_frames_buf = []

        with sd.RawInputStream(
            samplerate=SAMPLE_RATE,
            blocksize=FRAME_SAMPLES,
            dtype="int16",
            channels=1,
        ) as stream:
            _eprint("opal-voice-server: mic open, awaiting RESUME")
            while self.running:
                pcm, _overflow = stream.read(FRAME_SAMPLES)
                pcm = bytes(pcm)
                speech = self.vad.is_speech(pcm, SAMPLE_RATE)

                # Barge-in detection while TTS is playing. Collect the candidate
                # speech, and once we have enough, transcribe it and only fire
                # BARGEIN if it is NOT the assistant's own voice (echo guard).
                if self.speaking:
                    if self._barged:
                        continue
                    if speech:
                        bargein_frames_buf.append(pcm)
                        bargein_silence = 0
                    elif bargein_frames_buf:
                        # Keep short gaps: real speech pauses between words, and
                        # clearing on the first non-speech frame meant the buffer
                        # never accumulated a full window — barge-in either never
                        # fired or transcribed a meaningless fragment ('').
                        bargein_frames_buf.append(pcm)
                        bargein_silence += 1
                        if bargein_silence >= bargein_gap_frames:
                            bargein_frames_buf = []
                            bargein_silence = 0
                    if len(bargein_frames_buf) >= bargein_frames:
                        cand = self._transcribe(bargein_frames_buf)
                        echo = self._is_echo(cand)
                        if DEBUG:
                            _eprint(f"[dbg] bargein-cand: frames={len(bargein_frames_buf)} "
                                    f"heard={cand!r} vs speaking={self.speaking_text!r} echo={echo}")
                        bargein_frames_buf = []
                        if cand and not echo:
                            self._barged = True
                            self.send("BARGEIN")
                    continue
                if bargein_frames_buf:
                    bargein_frames_buf = []

                if not self.listening:
                    in_speech = False
                    speech_frames = []
                    continue

                if speech:
                    if not in_speech:
                        in_speech = True
                        speech_frames = []
                        frames_since_partial = 0
                        self._utt += 1
                        self.send("VAD:start")
                    speech_frames.append(pcm)
                    frames_since_partial += 1
                    silence_run = 0
                    # Stream a live interim transcript as the utterance grows so
                    # the UI shows words the moment they're spoken (the "realtime"
                    # feel), instead of only at end-of-turn. Dispatched to a worker
                    # thread with a snapshot of the audio: transcribing inline here
                    # stalls the mic read for hundreds of ms, which drops frames,
                    # truncates the utterance and leaves the final transcript empty.
                    # Counter, not `len % N == 0`: the modulo is only evaluated on
                    # speech frames, so the frame that would hit the multiple often
                    # lands in a between-words silence gap and the partial is
                    # silently skipped.
                    if (len(speech_frames) >= partial_min_frames
                            and frames_since_partial >= partial_every_frames
                            and not self._partial_busy):
                        frames_since_partial = 0
                        self._partial_busy = True
                        threading.Thread(
                            target=self._partial_worker,
                            args=(list(speech_frames), self._utt),
                            daemon=True,
                        ).start()
                elif in_speech:
                    speech_frames.append(pcm)
                    silence_run += 1
                    if silence_run >= silence_end_frames:
                        in_speech = False
                        silence_run = 0
                        self._utt += 1  # supersede any in-flight partial
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

    # Default bumped base.en → small.en: a clear accuracy jump for conversational
    # speech while staying real-time on CPU (int8). Override with OPAL_STT_MODEL —
    # e.g. "distil-small.en" (faster) or "large-v3-turbo" (best, heavier).
    model_name = os.environ.get("OPAL_STT_MODEL", os.environ.get("ZIGZAG_STT_MODEL", "small.en"))
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
    _eprint(f"opal-voice-server listening on {SOCK_PATH} (model={model_name})")

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
