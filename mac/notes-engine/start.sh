#!/bin/bash
# Switchboard Notes speech-to-text engine: Underdog Bark 3.0 Clean on 127.0.0.1:8115 only.
# Started by Switchboard when a recording needs turning into text; stopped by the 15-minute idle stop or on Quit.
# Uses (read-only) the model files in ~/Models/underdog-bark/clean and the Python packages of the Bark project.
# It never touches the Bark Voice Notes app or its server on 8099.
# Installed copy: ~/Models/switchboard-notes/ (source: ~/Projects/model-picker/mac/notes-engine/)
cd "$HOME/Models/switchboard-notes" || exit 1
PY="$HOME/Projects/bark-voice-notes/.venv/bin/python"
[ -x "$PY" ] && [ -d "$HOME/Models/underdog-bark/clean/bark_mlx_fp16" ] || { echo "missing python or model" >&2; exit 1; }
PYTHONDONTWRITEBYTECODE=1 HF_HUB_OFFLINE=1 nohup /usr/bin/perl -e 'use POSIX;setsid();exec @ARGV' "$PY" -B "$HOME/Models/switchboard-notes/stt_server.py" > switchboard-notes.log 2>&1 &
echo $! > switchboard-notes.pid
