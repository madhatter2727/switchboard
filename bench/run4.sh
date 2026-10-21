#!/bin/bash
cd ~/Projects/model-picker/bench
unload(){ curl -s -m5 127.0.0.1:11434/api/generate -d "{\"model\":\"$1\",\"keep_alive\":0}" >/dev/null; }
stopall(){ launchctl remove com.tara.modelpicker.spark 2>/dev/null; pkill -f 'llama-server.*--port 8097'; pkill -f 'llama-server.*--port 8098'; unload ornith:9b; sleep 60; }
stopall
for pair in "Bonsai-4B|bonsai-2-4b" "Spark|spark-x2.5-4b-mlx" "Raptor|raptor-0.6-4b-jang_6m" "Bonsai-9B|bonsai-2-9b" "ornith-9b|ornith:9b"; do
  IFS='|' read L M <<< "$pair"
  F=$(memory_pressure | sed -n 's/.*free percentage: \([0-9]*\)%.*/\1/p')
  if [ "$F" -lt 40 ]; then echo "SKIP $L low memory $F%"; continue; fi
  python3 bench4.py "$L" "$M"
  stopall
done
rm -rf /tmp/mpchrome
echo ALLDONE4
