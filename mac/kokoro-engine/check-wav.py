#!/usr/bin/env python3
"""POST one sentence to the Switchboard Kokoro helper and check the WAV."""
import argparse
import json
import struct
import sys
import urllib.error
import urllib.request

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--url", default="http://127.0.0.1:8123/speak")
    p.add_argument("--text", default="Hello, this is a short read aloud test.")
    p.add_argument("--voice", default="af_heart")
    p.add_argument("--out", default="")
    args = p.parse_args()
    body = json.dumps({"text": args.text, "voice": args.voice}).encode("utf-8")
    req = urllib.request.Request(args.url, data=body, headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = resp.read()
            ctype = resp.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, e.read().decode("utf-8", "replace"))
        return 2
    except Exception as e:
        print("error:", e)
        return 2
    if not data.startswith(b"RIFF") or data[8:12] != b"WAVE":
        print("not a WAV, content-type=%s bytes=%d head=%r" % (ctype, len(data), data[:16]))
        return 1
    # ch, sampwidth, rate, nframes from the fmt/data chunks via the header
    # 22-24 channels, 24-26 width, 24-28 rate is not reliable; parse simply:
    if len(data) < 44:
        print("WAV too short:", len(data))
        return 1
    channels = struct.unpack_from("<H", data, 22)[0]
    rate = struct.unpack_from("<I", data, 24)[0]
    width = struct.unpack_from("<H", data, 34)[0]
    # find data chunk size if possible
    nframes = max(0, (len(data) - 44) // max(1, (width // 8) * max(1, channels)))
    secs = nframes / float(rate or 1)
    if args.out:
        open(args.out, "wb").write(data)
    print("ok bytes=%d rate=%d width=%d ch=%d secs=%.2f voice=%s" % (len(data), rate, width, channels, secs, args.voice))
    if len(data) < 2000 or secs < 0.4:
        print("WAV is too short to be real speech")
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
