#!/usr/bin/env python3
"""
ZigZag Language Learning Server
Combines KittenTTS (local TTS) + Cohere ASR (speech recognition).
Runs as a lightweight HTTP sidecar on localhost:9877.
"""

import sys, os, io, json, struct, tempfile
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import numpy as np

# Add KittenTTS to path
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
KITTEN_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "KittenTTS")
sys.path.insert(0, KITTEN_DIR)

# Lazy-load models
tts_model = None
tts_model_name = "KittenML/kitten-tts-mini-0.8"

asr_model = None
asr_processor = None

translator_cache = {}  # Cache translators by (src, tgt) pair

SAMPLE_RATE = 24000
ASR_SAMPLE_RATE = 16000
PORT = 9877

VOICES = ['Bella', 'Jasper', 'Luna', 'Bruno', 'Rosie', 'Hugo', 'Kiki', 'Leo']
ASR_LANGUAGES = ['en', 'es', 'fr', 'de', 'it', 'pt', 'nl', 'pl', 'ru', 'ja', 'ko', 'zh', 'ar', 'hi']
TRANSLATE_LANGUAGES = {
    'en': 'english', 'es': 'spanish', 'fr': 'french', 'de': 'german',
    'it': 'italian', 'pt': 'portuguese', 'nl': 'dutch', 'pl': 'polish',
    'ru': 'russian', 'ja': 'japanese', 'ko': 'korean', 'zh-CN': 'chinese (simplified)',
    'ar': 'arabic', 'hi': 'hindi', 'tr': 'turkish', 'vi': 'vietnamese',
    'th': 'thai', 'sv': 'swedish', 'da': 'danish', 'fi': 'finnish',
    'el': 'greek', 'cs': 'czech', 'ro': 'romanian', 'hu': 'hungarian',
    'uk': 'ukrainian', 'id': 'indonesian', 'ms': 'malay', 'tl': 'filipino',
    'bn': 'bengali', 'ta': 'tamil', 'te': 'telugu', 'mr': 'marathi',
    'ur': 'urdu', 'pa': 'punjabi', 'gu': 'gujarati', 'kn': 'kannada',
    'ml': 'malayalam', 'si': 'sinhala', 'ne': 'nepali',
}

def get_tts():
    global tts_model
    if tts_model is None:
        print(f"[lang_server] Loading KittenTTS: {tts_model_name}")
        from kittentts import KittenTTS
        tts_model = KittenTTS(tts_model_name)
        print(f"[lang_server] KittenTTS ready!")
    return tts_model

asr_backend = None  # 'cohere' or 'whisper'

def get_asr():
    global asr_model, asr_processor, asr_backend
    if asr_model is not None:
        return asr_model, asr_processor

    # Try Cohere ASR first (best quality, multilingual)
    try:
        print("[lang_server] Loading Cohere ASR (2B params, first run downloads ~4GB)...")
        from transformers import AutoProcessor, CohereAsrForConditionalGeneration
        import torch
        asr_processor = AutoProcessor.from_pretrained(
            "CohereLabs/cohere-transcribe-03-2026",
            trust_remote_code=True
        )
        device = "cuda" if torch.cuda.is_available() else "cpu"
        asr_model = CohereAsrForConditionalGeneration.from_pretrained(
            "CohereLabs/cohere-transcribe-03-2026",
            trust_remote_code=True,
            device_map="auto" if torch.cuda.is_available() else None,
        )
        if device == "cpu":
            asr_model = asr_model.to("cpu")
        asr_backend = 'cohere'
        print(f"[lang_server] Cohere ASR ready on {device}!")
        return asr_model, asr_processor
    except Exception as e:
        print(f"[lang_server] Cohere ASR failed: {e}")

    # Fallback: OpenAI Whisper (lighter, widely available)
    try:
        print("[lang_server] Trying Whisper fallback...")
        import whisper
        asr_model = whisper.load_model("base")  # ~140MB, good enough
        asr_processor = None  # whisper has its own pipeline
        asr_backend = 'whisper'
        print("[lang_server] Whisper ASR ready!")
        return asr_model, asr_processor
    except Exception as e2:
        print(f"[lang_server] Whisper also failed: {e2}")
        print("[lang_server] Install ASR: pip install transformers torch  OR  pip install openai-whisper")
        raise RuntimeError("No ASR backend available")

def audio_to_wav_bytes(audio_np, sample_rate=24000):
    """Convert numpy float32 audio to WAV bytes in memory."""
    audio_np = np.clip(audio_np, -1.0, 1.0)
    pcm = (audio_np * 32767).astype(np.int16)
    buf = io.BytesIO()
    num_samples = len(pcm)
    data_size = num_samples * 2
    buf.write(b'RIFF')
    buf.write(struct.pack('<I', 36 + data_size))
    buf.write(b'WAVE')
    buf.write(b'fmt ')
    buf.write(struct.pack('<I', 16))
    buf.write(struct.pack('<H', 1))
    buf.write(struct.pack('<H', 1))
    buf.write(struct.pack('<I', sample_rate))
    buf.write(struct.pack('<I', sample_rate * 2))
    buf.write(struct.pack('<H', 2))
    buf.write(struct.pack('<H', 16))
    buf.write(b'data')
    buf.write(struct.pack('<I', data_size))
    buf.write(pcm.tobytes())
    return buf.getvalue()

def wav_bytes_to_audio(wav_data, target_sr=16000):
    """Convert WAV bytes to numpy float32 array at target sample rate."""
    import soundfile as sf
    audio, sr = sf.read(io.BytesIO(wav_data))
    if len(audio.shape) > 1:
        audio = audio.mean(axis=1)  # mono
    if sr != target_sr:
        ratio = target_sr / sr
        n_samples = int(len(audio) * ratio)
        indices = np.linspace(0, len(audio) - 1, n_samples)
        audio = np.interp(indices, np.arange(len(audio)), audio)
    return audio.astype(np.float32)


class LangHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        print(f"[lang_server] {args[0]}")

    def do_GET(self):
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)

        if parsed.path == '/health':
            self._json_response({
                "status": "ok",
                "tts_loaded": tts_model is not None,
                "asr_loaded": asr_model is not None,
                "voices": VOICES,
                "asr_languages": ASR_LANGUAGES,
                "translate_languages": list(TRANSLATE_LANGUAGES.keys()),
            })

        elif parsed.path == '/speak':
            text = params.get('text', [''])[0]
            voice = params.get('voice', ['Luna'])[0]
            speed = float(params.get('speed', ['1.0'])[0])

            if not text:
                self._json_response({"error": "missing text param"}, 400)
                return

            if voice not in VOICES:
                voice = 'Luna'

            try:
                model = get_tts()
                audio = model.generate(text=text, voice=voice, speed=speed)
                if hasattr(audio, 'squeeze'):
                    audio = audio.squeeze()
                wav_bytes = audio_to_wav_bytes(audio, SAMPLE_RATE)
                
                self.send_response(200)
                self.send_header('Content-Type', 'audio/wav')
                self.send_header('Content-Length', str(len(wav_bytes)))
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(wav_bytes)
            except Exception as e:
                print(f"[lang_server] TTS error: {e}")
                self._json_response({"error": str(e)}, 500)

        elif parsed.path == '/voices':
            self._json_response({"voices": VOICES})

        elif parsed.path == '/translate':
            text = params.get('text', [''])[0]
            src = params.get('from', ['auto'])[0]
            tgt = params.get('to', ['en'])[0]

            if not text:
                self._json_response({"error": "missing text param"}, 400)
                return

            try:
                from deep_translator import GoogleTranslator
                key = (src, tgt)
                if key not in translator_cache:
                    translator_cache[key] = GoogleTranslator(source=src, target=tgt)
                translated = translator_cache[key].translate(text)
                self._json_response({"translated": translated, "from": src, "to": tgt, "original": text})
            except ImportError:
                self._json_response({"error": "deep_translator not installed. Run: pip install deep-translator"}, 500)
            except Exception as e:
                print(f"[lang_server] Translate error: {e}")
                self._json_response({"error": str(e)}, 500)

        elif parsed.path == '/languages':
            self._json_response({"languages": TRANSLATE_LANGUAGES})

        else:
            self._json_response({"error": "not found"}, 404)

    def do_POST(self):
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)

        if parsed.path == '/transcribe':
            language = params.get('lang', ['en'])[0]
            if language not in ASR_LANGUAGES:
                language = 'en'

            content_length = int(self.headers.get('Content-Length', 0))
            if content_length == 0:
                self._json_response({"error": "empty body"}, 400)
                return

            try:
                wav_data = self.rfile.read(content_length)
                model, processor = get_asr()

                if asr_backend == 'whisper':
                    # Whisper: save to temp file, use model.transcribe()
                    with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f:
                        f.write(wav_data)
                        tmp_path = f.name
                    try:
                        result = model.transcribe(tmp_path, language=language if language != 'auto' else None)
                        text = result.get('text', '').strip()
                    finally:
                        os.unlink(tmp_path)
                else:
                    # Cohere ASR
                    audio = wav_bytes_to_audio(wav_data, ASR_SAMPLE_RATE)
                    inputs = processor(
                        audio, sampling_rate=ASR_SAMPLE_RATE,
                        return_tensors="pt", language=language
                    )
                    audio_chunk_index = inputs.get("audio_chunk_index")
                    inputs.to(model.device, dtype=model.dtype)
                    outputs = model.generate(**inputs, max_new_tokens=256)
                    text = processor.decode(
                        outputs, skip_special_tokens=True,
                        audio_chunk_index=audio_chunk_index,
                        language=language
                    )

                self._json_response({"text": text, "language": language})
            except Exception as e:
                print(f"[lang_server] ASR error: {e}")
                import traceback
                traceback.print_exc()
                self._json_response({"error": str(e)}, 500)
        else:
            self._json_response({"error": "not found"}, 404)

    def _json_response(self, data, code=200):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)


def main():
    print(f"[lang_server] Starting on port {PORT}...")
    
    # Pre-warm TTS on startup (fast, 80MB)
    get_tts()
    
    # ASR loads lazily on first /transcribe call (slow, ~4GB)
    print(f"[lang_server] Cohere ASR will load on first /transcribe request")
    
    class ReusableHTTPServer(HTTPServer):
        allow_reuse_address = True
    
    server = ReusableHTTPServer(('127.0.0.1', PORT), LangHandler)
    print(f"[lang_server] Ready at http://127.0.0.1:{PORT}")
    print(f"[lang_server] Endpoints:")
    print(f"  GET  /health")
    print(f"  GET  /speak?text=hello&voice=Luna&speed=1.0")
    print(f"  GET  /voices")
    print(f"  GET  /translate?text=hello&from=auto&to=es")
    print(f"  GET  /languages")
    print(f"  POST /transcribe?lang=en  (body: WAV audio)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[lang_server] Shutting down.")
        server.server_close()


if __name__ == '__main__':
    main()
