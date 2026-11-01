#!/bin/bash
# Qwen3.5-4B-3D-Coder for Switchboard (engine "little3d"), Nov 1.
# Makes 3D scenes as one HTML page with three.js. Listens on 127.0.0.1:8117 only.
# Little 3D Scene Maker may already be serving this same model with Homebrew llama-server.
# If anything is already listening on 8117, exit 0 and leave that process alone. Never stop it.
# Switchboard's own copy is marked --alias switchboard-little3d. Only a process whose command
# line carries that marker is ever killed. This script never downloads anything.
# Log: ~/Library/Logs/Switchboard-little3d.log
# Pid: ~/Library/Application Support/Model Picker/little3d.pid
# Installed copy: ~/Models/little-3d/switchboard-start.sh (source: ~/Projects/model-picker/mac/little3d-start.sh)
cd "$HOME/Models/little-3d" || exit 1
B=/opt/homebrew/bin/llama-server
[ -x "$B" ] || B="$(command -v llama-server)"
M="$HOME/Models/little-3d/Qwen3.5-4B-3D-Coder-Q4_K_M.gguf"
[ -x "$B" ] && [ -f "$M" ] || { echo "missing llama-server or model" >&2; exit 1; }
# Reuse whoever already holds 8117 (Scene Maker or a previous Switchboard copy).
if lsof -nP -iTCP:8117 -sTCP:LISTEN >/dev/null 2>&1; then exit 0; fi
mkdir -p "$HOME/Library/Logs" "$HOME/Library/Application Support/Model Picker"
nohup /usr/bin/perl -e 'use POSIX;setsid();exec @ARGV' "$B" -m "$M" --alias switchboard-little3d \
  --host 127.0.0.1 --port 8117 --ctx-size 32768 --parallel 1 --n-gpu-layers all --flash-attn on \
  --cache-type-k q8_0 --cache-type-v q8_0 --jinja \
  > "$HOME/Library/Logs/Switchboard-little3d.log" 2>&1 &
echo $! > "$HOME/Library/Application Support/Model Picker/little3d.pid"
