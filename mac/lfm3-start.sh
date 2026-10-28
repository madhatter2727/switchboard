#!/bin/bash
# usage: start.sh text|vl      (Switchboard starts this only when you pick an LFM3 model; 127.0.0.1 only)
# text: LFM3-1.7B on port 8110, context 114688 tokens (long documents up to ~100K tokens)
# vl:   LFM3-VL-2B on port 8111 with its picture projector (--mmproj), context 16384
# Thinking is OFF by default (chat template setting enable_thinking=false). Own llama.cpp copy: ~/src/llama.cpp-lfm3
cd "$(dirname "$0")"
B="$HOME/src/llama.cpp-lfm3/build/bin/llama-server"
case $1 in
 text) P=8110; M=text/LFM3-1.7B-Q4_K_M.gguf; C=114688; MM="";;
 vl)   P=8111; M=vl/LFM3-VL-2B-Q4_K_M.gguf;  C=16384;  MM=vl/mmproj-LFM3-VL-2B-Q8_0.gguf;;
 *) echo "usage: start.sh text|vl" >&2; exit 2;;
esac
[ -x "$B" ] && [ -f "$M" ] || { echo "missing llama-server or model" >&2; exit 1; }
VIS=(); [ -n "$MM" ] && [ -f "$MM" ] && VIS=(--mmproj "$MM")
nohup /usr/bin/perl -e 'use POSIX;setsid();exec @ARGV' "$B" -m "$M" --jinja -c $C -ngl 99 -fa on -np 1 --host 127.0.0.1 --port $P \
  --chat-template-kwargs '{"enable_thinking":false}' --temp 0.1 --top-k 50 --repeat-penalty 1.1 "${VIS[@]}" > "lfm3-$1.log" 2>&1 &
echo $! > "lfm3-$1.pid"
