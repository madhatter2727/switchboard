#!/bin/bash
# Switchboard "Search my files" meaning engine: EmbeddingGemma 2 (768 numbers per text) on 127.0.0.1:8116 only.
# Started by Switchboard while it indexes or searches; stopped by the 15-minute idle stop or on Quit.
# Reads (never changes) One Space's model file; uses Switchboard's own llama.cpp copy. One Space's own servers (8080/8081) are never touched.
# Installed copy: ~/Models/switchboard-search/start.sh (source: ~/Projects/model-picker/mac/search-engine/start.sh)
cd "$HOME/Models/switchboard-search" || exit 1
B="$HOME/src/llama.cpp-lfm3/build/bin/llama-server"
M="$HOME/Projects/one-space-mac/models/embeddinggemma-2-UD-Q4_K_XL.gguf"
[ -x "$B" ] && [ -f "$M" ] || { echo "missing llama-server or model" >&2; exit 1; }
nohup /usr/bin/perl -e 'use POSIX;setsid();exec @ARGV' "$B" -m "$M" --alias embeddinggemma2 --embeddings --pooling mean \
  --ctx-size 2048 --batch-size 2048 --ubatch-size 2048 --parallel 1 --host 127.0.0.1 --port 8116 > switchboard-search.log 2>&1 &
echo $! > switchboard-search.pid
