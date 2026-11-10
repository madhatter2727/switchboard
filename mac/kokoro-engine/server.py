#!/usr/bin/env python3
"""Switchboard Read aloud helper. Speaks one text chunk with Kokoro-82M and returns a WAV.

Listens only on 127.0.0.1:8123. This is Switchboard's own copy. It never binds
Woof TTS Lab's port 8121 and never stops that server.

Reuse: same kokoro-onnx + espeak-ng path as Woof TTS Lab
(~/Projects/tech-demos/apps/woof-tts-lab/server.py).
Weights: ~/Models/kokoro-82m/ (kokoro-v1.0.onnx, voices-v1.0.bin), Apache-2.0.
"""
import argparse
import io
import json
import math
import os
import struct
import sys
import threading
import traceback
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

HOST = "127.0.0.1"
PORT = 8123
MAX_CHARS = 800
SAMPLE_RATE = 24000

KOKORO_VOICE_GROUPS = (
    (
        "US female",
        (
            ("af_heart", "Heart"),
            ("af_bella", "Bella"),
            ("af_alloy", "Alloy"),
            ("af_aoede", "Aoede"),
            ("af_jessica", "Jessica"),
            ("af_kore", "Kore"),
            ("af_nicole", "Nicole"),
            ("af_nova", "Nova"),
            ("af_river", "River"),
            ("af_sarah", "Sarah"),
            ("af_sky", "Sky"),
        ),
    ),
    (
        "US male",
        (
            ("am_adam", "Adam"),
            ("am_echo", "Echo"),
            ("am_eric", "Eric"),
            ("am_fenrir", "Fenrir"),
            ("am_liam", "Liam"),
            ("am_michael", "Michael"),
            ("am_onyx", "Onyx"),
            ("am_puck", "Puck"),
            ("am_santa", "Santa"),
        ),
    ),
    (
        "UK female",
        (
            ("bf_alice", "Alice"),
            ("bf_emma", "Emma"),
            ("bf_isabella", "Isabella"),
            ("bf_lily", "Lily"),
        ),
    ),
    (
        "UK male",
        (
            ("bm_daniel", "Daniel"),
            ("bm_fable", "Fable"),
            ("bm_george", "George"),
            ("bm_lewis", "Lewis"),
        ),
    ),
)
KOKORO_VOICES = tuple(
    voice_id
    for _label, voices in KOKORO_VOICE_GROUPS
    for voice_id, _name in voices
)
# Heart is Kokoro's flagship American English voice (clear, natural).
KOKORO_DEFAULT = "af_heart"

MOCK = False
_kokoro = None
_ready = False
_load_error = None
_lock = threading.Lock()


def cors(handler):
    handler.send_header("Access-Control-Allow-Origin", "*")
    handler.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    handler.send_header("Access-Control-Allow-Headers", "Content-Type")
    handler.send_header("Cache-Control", "no-store")


def resolve_kokoro_dir():
    env = os.environ.get("KOKORO_MODEL_DIR", "").strip()
    if env:
        return Path(env).expanduser()
    return Path.home() / "Models" / "kokoro-82m"


def kokoro_paths():
    folder = resolve_kokoro_dir()
    return folder, folder / "kokoro-v1.0.onnx", folder / "voices-v1.0.bin"


def kokoro_label():
    folder, onnx, voices = kokoro_paths()
    if onnx.is_file() and voices.is_file():
        return str(folder)
    return "missing"


def kokoro_lang(voice):
    return "en-gb" if voice.startswith("b") else "en-us"


def voice_catalog():
    out = []
    for group, voices in KOKORO_VOICE_GROUPS:
        for voice_id, name in voices:
            out.append({"id": voice_id, "name": name, "group": group})
    return out


def mock_wav(text):
    duration = min(2.0, max(0.55, 0.35 + len(text) * 0.02))
    frames = int(SAMPLE_RATE * duration)
    pcm = bytearray()
    for i in range(frames):
        t = i / SAMPLE_RATE
        attack = min(1.0, t / 0.015)
        release = min(1.0, max(0.0, (duration - t) / 0.06))
        env = attack * release
        sample = 0.28 * math.sin(2 * math.pi * 392 * t) + 0.12 * math.sin(2 * math.pi * 588 * t)
        val = int(round(max(-1.0, min(1.0, sample * env)) * 32767))
        pcm += struct.pack("<h", val)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(pcm)
    return buf.getvalue()


def audio_to_wav(samples, sample_rate):
    import numpy as np

    arr = np.asarray(samples, dtype=np.float32).reshape(-1)
    pcm = (np.clip(arr, -1, 1) * 32767).round().astype("<i2")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(int(sample_rate))
        wf.writeframes(pcm.tobytes())
    return buf.getvalue()


def get_kokoro():
    """Load Kokoro once. ONNX weights live in ~/Models/kokoro-82m."""
    global _kokoro
    if _kokoro is not None:
        return _kokoro

    folder, onnx, voices = kokoro_paths()
    if not onnx.is_file() or not voices.is_file():
        raise RuntimeError(
            "Could not find Kokoro files. Put kokoro-v1.0.onnx and "
            f"voices-v1.0.bin in {folder}, or set KOKORO_MODEL_DIR."
        )

    try:
        from kokoro_onnx import EspeakConfig, Kokoro
    except ImportError as exc:
        raise RuntimeError(
            "Could not import kokoro_onnx. Use the Python 3.12 venv and "
            f"install requirements.txt. ({exc})"
        ) from exc

    lib = Path("/opt/homebrew/opt/espeak-ng/lib/libespeak-ng.dylib")
    data = Path("/opt/homebrew/opt/espeak-ng/share/espeak-ng-data")
    kwargs = {}
    if lib.is_file() and data.is_dir():
        kwargs["espeak_config"] = EspeakConfig(lib_path=str(lib), data_path=str(data))
    _kokoro = Kokoro(str(onnx), str(voices), **kwargs)
    return _kokoro


def preload():
    global _ready, _load_error
    if MOCK:
        _ready = True
        return
    try:
        get_kokoro()
        _ready = True
        _load_error = None
        print("kokoro: ready", flush=True)
    except Exception as exc:
        _load_error = str(exc)
        _ready = False
        traceback.print_exc()
        print(f"kokoro: load failed: {exc}", flush=True)


def synthesize(text, voice):
    if MOCK:
        return mock_wav(text)
    with _lock:
        tts = get_kokoro()
        audio, sr = tts.create(text, voice=voice, lang=kokoro_lang(voice))
        return audio_to_wav(audio, sr)


def parse_speak(payload):
    if not isinstance(payload, dict):
        return None, "Request body must be a JSON object."
    text = payload.get("text", "")
    if not isinstance(text, str):
        return None, "Text must be a string."
    text = text.strip()
    if not text:
        return None, "Text is empty."
    if len(text) > MAX_CHARS:
        return None, f"Text is longer than {MAX_CHARS} characters."
    voice = payload.get("voice", "") or ""
    if not isinstance(voice, str):
        return None, "Voice must be a string."
    voice = voice.strip().lower()
    if not voice:
        voice = KOKORO_DEFAULT
    if voice not in KOKORO_VOICES:
        return None, "Voice is not a Kokoro English voice."
    return (text, voice), None


def status_payload():
    return {
        "ok": True,
        "ready": bool(_ready or MOCK),
        "error": _load_error,
        "model": "kokoro-82m",
        "model_dir": kokoro_label(),
        "default_voice": KOKORO_DEFAULT,
        "voices": voice_catalog(),
        "mock": MOCK,
        "port": PORT,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "SwitchboardKokoro/1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _json(self, code, obj):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        cors(self)
        self.end_headers()
        self.wfile.write(data)

    def _body(self, code, data, content_type):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        cors(self)
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self.send_response(204)
        cors(self)
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/health", "/models", "/v1/models"):
            payload = status_payload()
            if path in ("/models", "/v1/models"):
                payload = {
                    "object": "list",
                    "data": [{"id": "kokoro-82m", "object": "model"}],
                    **payload,
                }
            self._json(200, payload)
            return
        self._json(404, {"error": "Not found."})

    def do_POST(self):
        path = urlparse(self.path).path
        if path != "/speak":
            self._json(404, {"error": "Not found."})
            return
        raw_len = self.headers.get("Content-Length")
        if raw_len is None:
            self._json(400, {"error": "Content-Length required."})
            return
        try:
            length = int(raw_len)
        except ValueError:
            self._json(400, {"error": "Bad Content-Length."})
            return
        if length < 0 or length > 65536:
            self._json(400, {"error": "Request is too large."})
            return
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._json(400, {"error": "Request body must be JSON."})
            return
        parsed, err = parse_speak(payload)
        if err:
            self._json(400, {"error": err})
            return
        text, voice = parsed
        try:
            wav = synthesize(text, voice)
        except Exception as exc:
            traceback.print_exc()
            self._json(500, {"error": str(exc)})
            return
        self._body(200, wav, "audio/wav")


def main():
    global MOCK, PORT
    parser = argparse.ArgumentParser(description="Switchboard Kokoro read-aloud helper")
    parser.add_argument("--mock", action="store_true", help="Return a short tone instead of real speech")
    parser.add_argument("--port", type=int, default=PORT)
    args = parser.parse_args()
    MOCK = args.mock or os.environ.get("KOKORO_MOCK", "").strip() in ("1", "true", "yes")
    PORT = args.port
    threading.Thread(target=preload, name="kokoro-preload", daemon=True).start()
    class Server(ThreadingHTTPServer):
        allow_reuse_address = True
        daemon_threads = True
    httpd = Server((HOST, PORT), Handler)
    print(
        f"Switchboard Kokoro at http://{HOST}:{PORT}  mock={MOCK}  model={kokoro_label()}",
        flush=True,
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.", flush=True)


if __name__ == "__main__":
    main()
