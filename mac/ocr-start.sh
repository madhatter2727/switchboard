#!/bin/bash
# LightOnOCR-3 0.8B document reader for Switchboard: 127.0.0.1:8114 only, context 16384, thinking off.
# Started by Switchboard only while it reads a document, stopped right after (and by the 15-minute idle stop).
# Same settings as the Oct 29 head-to-head test (there on port 8113). Own llama.cpp copy: ~/src/llama.cpp-lfm3
# Installed copy: ~/Models/lightonocr/start.sh (source: ~/Projects/model-picker/mac/ocr-start.sh)
cd "$HOME/Models/lightonocr" || exit 1
B="$HOME/src/llama.cpp-lfm3/build/bin/llama-server"
M=LightOnOCR-3-0.8B.Q8_0.gguf; MM=LightOnOCR-3-0.8B.mmproj-f16.gguf
[ -x "$B" ] && [ -f "$M" ] && [ -f "$MM" ] || { echo "missing llama-server or model" >&2; exit 1; }
nohup /usr/bin/perl -e 'use POSIX;setsid();exec @ARGV' "$B" -m "$M" --mmproj "$MM" --jinja -c 16384 -ngl 99 -fa on -np 1 \
  --host 127.0.0.1 --port 8114 --chat-template-kwargs '{"enable_thinking":false}' > switchboard-ocr.log 2>&1 &
echo $! > switchboard-ocr.pid
