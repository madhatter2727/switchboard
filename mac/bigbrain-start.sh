#!/bin/bash
# Gemma 4 26B "Big Brain" for Switchboard (engine "bigbrain"), Nov 13.
# Runs TurboFieldfareServer (~/Projects/turbo-fieldfare) with the text model and the vision pack on 127.0.0.1:8124.
# The Big Brain demo (~/Projects/tech-demos/apps/turbo-fieldfare/start.sh) uses the same port and the same model:
# if anything is already listening on 8124, exit 0 and leave that process alone (Switchboard just uses it).
# Switchboard only ever stops the pid written below, and only while the demo page (8125) is not open.
# This script never downloads anything.
# Log: ~/Library/Logs/Switchboard-bigbrain.log
# Pid: ~/Library/Application Support/Model Picker/bigbrain.pid
# Installed copy: ~/Models/switchboard-bigbrain/start.sh (source: mac/bigbrain-start.sh)
TF="$HOME/Projects/turbo-fieldfare"
B="$TF/.build/release/TurboFieldfareServer"
M="$TF/scratch/gemma4.gturbo"
V="$TF/scratch/gemma4.vision.gturbo"
[ -x "$B" ] && [ -f "$M/manifest.json" ] || { echo "missing TurboFieldfareServer or model" >&2; exit 1; }
if lsof -nP -iTCP:8124 -sTCP:LISTEN >/dev/null 2>&1; then exit 0; fi
args=(--model "$M" --port 8124)
[ -f "$V/manifest.json" ] && args+=(--vision-pack "$V")
mkdir -p "$HOME/Library/Logs" "$HOME/Library/Application Support/Model Picker"
cd "$TF" || exit 1
nohup /usr/bin/perl -e 'use POSIX;setsid();exec @ARGV' "$B" "${args[@]}" \
  > "$HOME/Library/Logs/Switchboard-bigbrain.log" 2>&1 < /dev/null &
echo $! > "$HOME/Library/Application Support/Model Picker/bigbrain.pid"
