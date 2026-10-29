"""Switchboard's own speech-to-text engine for the Notes tab (Oct 29).

Runs Underdog Bark 3.0 Clean (already on this Mac in ~/Models/underdog-bark/clean, its unpacked fp16 MLX copy)
on 127.0.0.1:8115 only. Read-only use of those model files and of the Bark app's Python packages; it never
touches the Bark Voice Notes app, its recordings, its settings or its server on 8099.
Switchboard starts it when you stop a recording and stops it after 15 idle minutes (or when it quits).

  GET  /v1/models   -> {"data": []}   (health check; it is not a chat model)
  POST /transcribe  {"path": "/abs/file.m4a|wav|caf"} -> {"text", "seconds", "audio_seconds"}
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8115
MODEL_DIR = os.path.expanduser(os.environ.get("SB_NOTES_MODEL", "~/Models/underdog-bark/clean/bark_mlx_fp16"))
LONG_SECONDS, CHUNK_SECONDS = 120, 60   # same as Bark: the model holds the whole clip, so long audio goes in 60 s parts
_lock = threading.Lock()
_model = None


def model():
    global _model
    with _lock:
        if _model is None:
            import mlx.core as mx
            from mlx_audio.stt import load
            t = time.perf_counter()
            _model = load(MODEL_DIR, strict=True, model_type="parakeet")
            mx.eval(_model.parameters())
            mx.set_cache_limit(512 * 1024 * 1024)
            print(f"loaded {MODEL_DIR} in {time.perf_counter() - t:.1f}s", flush=True)
        return _model


def read_audio(path):
    import numpy as np
    import soundfile as sf
    with tempfile.TemporaryDirectory(prefix="sb-notes-") as d:
        wav = os.path.join(d, "a.wav")
        p = subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", path, wav], capture_output=True, timeout=300)
        if p.returncode != 0:
            raise ValueError("could not read this audio: " + (p.stderr or p.stdout).decode("utf-8", "replace").strip()[-200:])
        w, sr = sf.read(wav, dtype="float32", always_2d=True)
    return np.ascontiguousarray(w.mean(axis=1)), sr


def transcribe(path):
    import mlx.core as mx
    m = model()
    wave, sr = read_audio(path)
    t = time.perf_counter()
    n = len(wave)
    step = n if n / sr <= LONG_SECONDS else int(CHUNK_SECONDS * sr)
    parts = []
    with _lock:
        for off in range(0, max(n, 1), max(step, 1)):
            seg = wave[off:off + step]
            if len(seg) < sr // 10:
                continue
            txt = m.generate(mx.array(seg), dtype=mx.bfloat16, chunk_duration=None, verbose=False).text.strip()
            if txt:
                parts.append(txt)
    return {"text": " ".join(parts), "seconds": round(time.perf_counter() - t, 2), "audio_seconds": round(n / float(sr), 2)}


class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path in ("/v1/models", "/health"):
            return self._send(200, {"object": "list", "data": [], "ready": _model is not None})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/transcribe":
            return self._send(404, {"error": "not found"})
        try:
            d = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
            path = os.path.abspath(str(d.get("path") or ""))
            if not os.path.isfile(path):
                return self._send(400, {"error": "no such audio file"})
            self._send(200, transcribe(path))
        except Exception as e:  # report, keep serving
            self._send(500, {"error": str(e).splitlines()[0][:300] if str(e) else type(e).__name__})

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    threading.Thread(target=model, daemon=True).start()   # warm up while the first request is on its way
    print(f"Switchboard notes speech engine on 127.0.0.1:{PORT}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
