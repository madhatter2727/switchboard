#!/bin/bash
# Logs every new process of each backend app (one line per launch).
declare -A seen
while true; do
  for spec in "osaurus|osaurus.app/Contents/MacOS/osaurus" "ollama-app|Ollama.app/Contents/MacOS/Ollama" "ollama-serve|ollama serve" "lmstudio|LM Studio.app/Contents/MacOS/LM Studio" "magnitude|magnitude serve"; do
    n=${spec%%|*}; pat=${spec#*|}
    for pid in $(pgrep -f "$pat"); do
      [ -z "${seen[$pid]}" ] && { seen[$pid]=1; echo "$(date +%H:%M:%S) LAUNCH $n pid=$pid $(ps -o command= -p $pid | cut -c1-90)"; }
    done
  done
  sleep 0.5
done
