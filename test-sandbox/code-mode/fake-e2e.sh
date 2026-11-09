#!/bin/bash
# Code mode, Milestone 2: the real Swift runner + real harness/project.js, with a FAKE model (port 18931) on a throwaway repo.
# Never calls Osaurus or a real model, never touches a real project or ~/Projects/harness-game-kit/runs.
# Needs: mac/.build/release/ModelPicker (swift build -c release) and a harness copy at $T/harness-kit (git clone ... harness-game-kit).
set -u; T=${T:-$HOME/Scratch/code-mode-test}; HERE="$(cd "$(dirname "$0")" && pwd)"; BIN="$HERE/../../mac/.build/release/ModelPicker"
export SB_CODE_HARNESS=$T/harness-kit SB_CODE_MODEL_URL=http://127.0.0.1:18931/v1 SB_CODE_DIR=$T/state
[ -f "$T/harness-kit/harness/project.js" ] || { echo "need a harness copy at $T/harness-kit"; exit 1; }
R=$T/demo-game; rm -rf "$R"; mkdir -p "$R/src"; cd "$R" && git init -q -b main
echo '{ "name": "demo-game", "private": true, "scripts": { "build": "node build-check.js" } }' > package.json
echo "const fs=require('fs');for(const f of fs.readdirSync('src'))if(f.endsWith('.js'))new Function(fs.readFileSync('src/'+f,'utf8').replace(/^export /gm,''));console.log('build ok')" > build-check.js
printf "// Heads-up display: the score box in the top corner.\nexport const HUD = {\n  scoreColor: '#ffd84a', // points number in the score box (yellow)\n  labelText: 'POINTS',\n};\n" > src/hud.js
git add -A && git -c user.name=test -c user.email=test@localhost commit -q -m "demo game"
fake(){ kill $(cat $T/fake.pid 2>/dev/null) 2>/dev/null; sleep 0.3; MODE=${1:-} node "$HERE/fake-model.mjs" > $T/fake.log 2>&1 & echo $! > $T/fake.pid; sleep 0.8; }
ok=0; bad=0; t(){ if eval "$2"; then echo "PASS  $1"; ok=$((ok+1)); else echo "FAIL  $1"; bad=$((bad+1)); fi; }
ASK="Make the points number in the score box bright green"
fake
o=$("$BIN" --code-run "$R" "$ASK" --dry); t "preview picks src/hud.js, changes nothing" '[[ $o == *"src/hud.js [whole file]"* && $o == *"\"state\":\"preview\""* && $(git -C "$R" branch --show-current) == main ]]'
o=$("$BIN" --code-run "$R" "$ASK" --check "npm run build" --model fake); t "run passes on try 2 on a harness/ branch" '[[ $o == *"\"state\":\"pass\""* && $o == *"\"tries\":2"* && $o == *"\"files\":[\"src\\/hud.js\"]"* && $(git -C "$R" branch --show-current) == harness/* ]]'
t "file really changed" 'grep -q "#39ff14" "$R/src/hud.js"'
o=$("$BIN" --code-undo); t "undo: back on main, branch deleted, file restored" '[[ $o == *"Undone"* && $(git -C "$R" branch --show-current) == main && $(git -C "$R" branch | wc -l) -eq 1 ]] && grep -q "#ffd84a" "$R/src/hud.js"'
o=$("$BIN" --code-run "$R" "$ASK" --check false --model fake); t "failing check: fail, nothing kept" '[[ $o == *"\"state\":\"fail\""* && $(git -C "$R" branch | wc -l) -eq 1 && -z $(git -C "$R" status --porcelain) ]]'
echo "// x" >> "$R/src/hud.js"; o=$("$BIN" --code-run "$R" "$ASK" --model fake); t "dirty project refused" '[[ $o == *"aren"*"saved in git"* ]]'; git -C "$R" checkout -q -- src/hud.js
fake slow
o=$("$BIN" --code-run "$R" "$ASK" --model fake --stop-after 3); t "Stop: stopped, back on main, branch gone, clean" '[[ $o == *"\"state\":\"stopped\""* && $(git -C "$R" branch --show-current) == main && $(git -C "$R" branch | wc -l) -eq 1 && -z $(git -C "$R" status --porcelain) ]]'
kill $(cat $T/fake.pid) 2>/dev/null
echo "$ok passed, $bad failed"; [ $bad -eq 0 ]
