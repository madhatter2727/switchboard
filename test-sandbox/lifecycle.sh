#!/bin/bash
# helpers for the "models run only while an app is open" tests
cd ~/Projects/model-picker
mem(){ echo "$(date +%T) free memory: $(memory_pressure | tail -1 | awk '{print $NF}')  | model servers: $(lsof -nP -iTCP:8095,8096,8097,8098,1337 -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $1"@"$9}' | sort -u | tr '\n' ' ') | ollama loaded: $(curl -s localhost:11434/api/ps | python3 -c 'import json,sys;print(",".join(m["name"] for m in json.load(sys.stdin)["models"]) or "none")')"; }
st(){ rm -f selftest.json; open -n "$HOME/Applications/Switchboard.app" --args --selftest chat "$1" "$2" --chats-dir "$PWD/test-sandbox/lifechats"; for i in $(seq 1 120); do [ -f selftest.json ] && break; sleep 2; done; pkill -f "Switchboard --selftest"; echo "  chat via $1: $(head -c 200 selftest.json)"; sleep 2; }
amm(){ curl -s -m 300 localhost:7777/v1/chat/completions -A "AskMyMac/1 CFNetwork/test" -H 'Content-Type: application/json' -d "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi in three words.\"}],\"max_tokens\":400}" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("  reply:",(d["choices"][0]["message"].get("content") or "")[:80].replace("\n"," "))'; }
