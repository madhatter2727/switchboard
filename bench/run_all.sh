#!/bin/bash
cd ~/Projects/model-picker/bench
unload(){ curl -s -m5 127.0.0.1:11434/api/generate -d "{\"model\":\"$1\",\"keep_alive\":0}" >/dev/null; }
stopall(){ launchctl remove com.tara.modelpicker.spark 2>/dev/null; launchctl remove com.tara.modelpicker.bonsai27b 2>/dev/null; pkill -f 'llama-server.*--port 8097'; pkill -f 'llama-server.*--port 8098'; for m in gemma2:2b gemma4:e2b ornith:9b ornith-agent:latest qwen2.5-coder:7b; do unload $m; done; sleep 3; }
stopall
for pair in "Raptor|raptor-0.6-4b-jang_6m" "Spark|spark-x2.5-4b-mlx" "Bonsai-4B|bonsai-2-4b" "Bonsai-9B|bonsai-2-9b" "gemma2-2b|gemma2:2b" "gemma4-e2b|gemma4:e2b" "ornith-9b|ornith:9b" "ornith-agent|ornith-agent:latest" "qwen2.5-coder-7b|qwen2.5-coder:7b" "Bonsai-27B|bonsai-2-27b"; do
  python3 bench.py "${pair%%|*}" "${pair##*|}"
  stopall
done
echo ALLDONE
