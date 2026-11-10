#!/bin/bash
# Code mode Big change / New project: the real Swift runner + real harness/build.js with a STAND-IN model (port 18931),
# only in throwaway folders under ~/Scratch/code-mode-test. Never calls Osaurus, never touches a real project or the real harness.
# Needs: mac/.build/release/ModelPicker and a harness copy at $T/harness-kit (632789c or newer).
set -u; T=${T:-$HOME/Scratch/code-mode-test}; HERE="$(cd "$(dirname "$0")" && pwd)"; BIN="$HERE/../../mac/.build/release/ModelPicker"
export SB_CODE_HARNESS=$T/harness-kit SB_CODE_MODEL_URL=http://127.0.0.1:18931/v1 SB_CODE_DIR=$T/state SB_CODE_PROJECTS=$T/projects
[ -f "$T/harness-kit/harness/build.js" ] || { echo "need a harness copy (with build.js) at $T/harness-kit"; exit 1; }
FLAG=$T/fail-flag; mkdir -p $T/projects
fake(){ kill $(cat $T/fb.pid 2>/dev/null) 2>/dev/null; sleep 0.3; MODE=${1:-} FAIL_FLAG=$FLAG node "$HERE/fake-build-model.mjs" >> $T/fb.log 2>&1 & echo $! > $T/fb.pid; sleep 0.8; }
ok=0; bad=0; t(){ if eval "$2"; then echo "PASS  $1"; ok=$((ok+1)); else echo "FAIL  $1"; bad=$((bad+1)); echo "      $(echo "$o" | grep RESULT | cut -c1-300)"; fi; }
js(){ echo "$o" | grep '^RESULT ' | sed 's/^RESULT //' | python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }
br(){ git -C "$R" branch --show-current; }
# throwaway repo for Big change
R=$T/big-game; rm -rf "$R"; mkdir -p "$R/src"; cd "$R" && git init -q -b main
echo '{ "name": "big-game", "private": true, "scripts": { "build": "node build-check.js" } }' > package.json
echo "const fs=require('fs');for(const f of fs.readdirSync('src'))if(f.endsWith('.js'))new Function(fs.readFileSync('src/'+f,'utf8').replace(/^export /gm,''));console.log('build ok')" > build-check.js
printf "export const HUD = { scoreColor: '#ffd84a' };\n" > src/hud.js
git add -A && git -c user.name=test -c user.email=test@localhost commit -q -m "big game"; MAIN=$(git rev-parse HEAD)
rm -rf $T/projects/space-e2e $T/harness-kit/runs/plans; fake
# --- New project
o=$("$BIN" --code-run space-e2e "a simple space shooter" --kind new --model fake)
t "New project: done, exit 0, 3 of 3 steps, files listed" '[[ $(js "d[\"state\"],d[\"exitCode\"],d[\"doneN\"],d[\"total\"],len(d[\"files\"])") == "('"'"'done'"'"', 0, 3, 3, 3)" ]]'
t "New project: folder made with starter page + git history" '[[ -f $T/projects/space-e2e/index.html && $(git -C $T/projects/space-e2e rev-list --count HEAD) -eq 4 ]]'
o=$("$BIN" --code-run space-e2e "another idea" --kind new --model fake)
t "New project: an existing non-empty folder is refused" '[[ $o == *"already exists and isn"* ]]'
# --- Big change, stops partway (a step fails even after splitting)
touch $FLAG
o=$("$BIN" --code-run "$R" "add a score panel partway" --kind big --model fake)
t "Big change partway: state partway, exit 1, some steps kept" '[[ $(js "d[\"state\"],d[\"exitCode\"],d[\"doneN\"]>=1,d[\"doneN\"]<d[\"total\"]") == "('"'"'partway'"'"', 1, True, True)" ]]'
t "Big change partway: on a harness/build- branch, main unchanged, repo clean" '[[ $(br) == harness/build-* && $(git -C "$R" rev-parse main) == $MAIN && -z $(git -C "$R" status --porcelain --untracked-files=no) ]]'
t "Big change partway: plan shows a failed step" '[[ $(js "[s[\"status\"] for s in d[\"steps\"]].count(\"failed\")") -ge 1 ]]'
# --- Run again to continue (the failing step works now)
rm -f $FLAG
o=$("$BIN" --code-run "$R" "add a score panel partway" --kind big --model fake --resume)
t "Run again: carries on and finishes (done, exit 0, all steps)" '[[ $(js "d[\"state\"],d[\"exitCode\"],d[\"doneN\"]==d[\"total\"]") == "('"'"'done'"'"', 0, True)" ]]'
t "Run again: carried on from the saved plan" '[[ $o == *"Carrying on with the saved plan"* ]]'
t "Big change done: branch + start branch reported, files changed" '[[ $(js "d[\"branch\"].startswith(\"harness/build-\"),d[\"startBranch\"],len(d[\"files\"])>0") == "(True, '"'"'main'"'"', True)" ]]'
# --- Undo the whole change, then the same idea again starts fresh
o=$("$BIN" --code-undo)
t "Undo the whole change: back on main, build branch deleted" '[[ $o == *"Undone"* && $(br) == main && $(git -C "$R" branch | wc -l) -eq 1 && $(git -C "$R" rev-parse HEAD) == $MAIN ]]'
o=$("$BIN" --code-run "$R" "add a score panel partway" --kind big --model fake)
t "Same idea after Undo: starts fresh (new plan) and finishes" '[[ $o != *"Carrying on"* && $(js "d[\"state\"]") == done ]]'
o=$("$BIN" --code-undo); [[ $(br) == main ]] || echo "      (undo 2 failed: $o)"
# --- Stop by hand after one finished step, then Run again
fake slow
o=$("$BIN" --code-run "$R" "add a pause menu" --kind big --model fake --stop-after 5)
t "Stop: state stopped, exit 130, 1 finished step kept" '[[ $(js "d[\"state\"],d[\"exitCode\"],d[\"byHand\"],d[\"doneN\"]") == "('"'"'stopped'"'"', 130, True, 1)" ]]'
t "Stop: half-done step undone (repo clean, on build branch, no stray step branch)" '[[ -z $(git -C "$R" status --porcelain) && $(br) == harness/build-* && $(git -C "$R" branch | grep -c "harness/2") -eq 0 ]]'
fake
o=$("$BIN" --code-run "$R" "add a pause menu" --kind big --model fake --resume)
t "Run again after Stop: finishes the rest" '[[ $o == *"Carrying on"* && $(js "d[\"state\"],d[\"doneN\"]==d[\"total\"]") == "('"'"'done'"'"', True)" ]]'
o=$("$BIN" --code-undo); t "final Undo: back to the original main" '[[ $(br) == main && $(git -C "$R" rev-parse HEAD) == $MAIN ]]'
kill $(cat $T/fb.pid) 2>/dev/null
echo "$ok passed, $bad failed"; [ $bad -eq 0 ]
