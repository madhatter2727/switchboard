#!/bin/bash
# usage: readtest.sh NAME ENGINE "MODEL@@msg"   (ENGINE=auto for Auto)
cd ~/Projects/model-picker
rm -f selftest.json selftest.png
open -n "$HOME/Applications/Model Picker.app" --args --selftest convo "$2" "$3"
for i in $(seq 1 900); do [ -s selftest.json ] && break; sleep 2; done
sleep 3; cp selftest.json bench/toolcheck/R-$1.json; cp selftest.png bench/toolcheck/R-$1.png 2>/dev/null
pkill -f "ModelPicker --selftest"
python3 -c "
import json;d=json.load(open('bench/toolcheck/R-$1.json'))
for t in d['turns']: print('$1',t['model'],'| steps:',[s[:90] for s in t['steps']],'| REPLY:',t['reply'][:400].replace(chr(10),' '))"
