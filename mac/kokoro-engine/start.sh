#!/bin/bash
# Switchboard Read aloud: Kokoro-82M on 127.0.0.1:8123 only.
# Started by Switchboard on the first Read aloud click; stopped after 15 minutes idle or on Quit.
# Uses (read-only) the model files in ~/Models/kokoro-82m and a Python 3.12 venv that already
# has kokoro-onnx (the same one Woof TTS Lab uses). It never touches Woof's server on 8121.
# The process command line contains "switchboard-kokoro/server.py" so stop only hits this helper.
# Installed copy: ~/Models/switchboard-kokoro/ (source: mac/kokoro-engine/)
# Pid: ~/Library/Application Support/Model Picker/kokoro.pid
# Log: ~/Library/Logs/Switchboard-kokoro.log
set -e
cd "$(CDPATH= cd -- "$(dirname "$0")" && pwd)"

# Homebrew so espeak-ng is on PATH (launchd / app launches have a tiny PATH).
if [ -d /opt/homebrew/bin ]; then
  PATH="/opt/homebrew/bin:$PATH"
  export PATH
fi

# If our helper already holds 8123, leave it alone. If something else is there, do not kill it.
if lsof -nP -iTCP:8123 -sTCP:LISTEN >/dev/null 2>&1; then
  if pgrep -f "switchboard-kokoro/server.py" >/dev/null 2>&1; then
    exit 0
  fi
  echo "port 8123 is already in use by something else; not starting" >&2
  exit 1
fi

PY=""
if [ -x "$HOME/Models/switchboard-kokoro/.venv-312/bin/python" ]; then
  PY="$HOME/Models/switchboard-kokoro/.venv-312/bin/python"
elif [ -x "$HOME/Projects/tech-demos/apps/woof-tts-lab/.venv-312/bin/python" ]; then
  PY="$HOME/Projects/tech-demos/apps/woof-tts-lab/.venv-312/bin/python"
fi
if [ -z "$PY" ]; then
  echo "missing Python 3.12 venv with kokoro-onnx" >&2
  exit 1
fi
[ -f "$HOME/Models/kokoro-82m/kokoro-v1.0.onnx" ] && [ -f "$HOME/Models/kokoro-82m/voices-v1.0.bin" ] || {
  echo "missing Kokoro model files in ~/Models/kokoro-82m" >&2
  exit 1
}

SUPPORT="$HOME/Library/Application Support/Model Picker"
mkdir -p "$SUPPORT" "$HOME/Library/Logs"
SERVER="$PWD/server.py"

# Marker in the command line: the installed path is .../switchboard-kokoro/server.py
PYTHONDONTWRITEBYTECODE=1 HF_HUB_OFFLINE=1 nohup /usr/bin/perl -e 'use POSIX;setsid();exec @ARGV' \
  "$PY" -B "$SERVER" --port 8123 \
  > "$HOME/Library/Logs/Switchboard-kokoro.log" 2>&1 &
echo $! > "$SUPPORT/kokoro.pid"
