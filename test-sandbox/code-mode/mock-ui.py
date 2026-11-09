#!/usr/bin/env python3
"""Code mode, Milestone 1: the real web page in headless Chromium with a MOCKED Swift bridge (no app, no model, no files).
Run: ~/Projects/harness-game-kit/.venv/bin/python test-sandbox/code-mode/mock-ui.py   -> shots in test-sandbox/code-mode/"""
import json, pathlib, sys
from playwright.sync_api import sync_playwright
HERE = pathlib.Path(__file__).resolve().parent
WEB = HERE.parent.parent / "web" / "index.html"
MOCK = r"""
(()=>{let calls=[],tick=0,state='none',undone=false;const L=['Model: ornith-1.5-9b-mlx-4bit · check: npm run build','On new branch harness/2026-11-09T21-00-00-000 (from main). Context ~900 tokens: src/hud.js, src/style.css','  try 1: edit did not apply (SEARCH not found in src/hud.js)','  try 2: edit applied, checks passed','PASS in 2 tries (95s). Committed abc1234 on harness/2026-11-09T21-00-00-000.','Log: runs/project_demo_x.json'];
 const res=(op,d)=>{calls.push(op);switch(op){
  case 'prefsGet':return {value:null};
  case 'listChats':return {chats:[]};
  case 'codeConfig':return {model:'ornith-1.5-9b-mlx-4bit',defaultModel:'ornith-1.5-9b-mlx-4bit',models:[{id:'ornith-1.5-9b-mlx-4bit',name:'Ornith 1.5 9B'},{id:'twil-8b-mlx-4bit',name:'TwIL-8B'}],harnessOK:true,node:'/x/node',last:null};
  case 'codePick':case 'codeInspect':return {ok:true,path:'/Users/test/Scratch/demo-game',name:'demo-game',branch:'main',clean:true,check:'npm run build'};
  case 'codeStart':state='running';tick=0;window.__started=d;return {ok:true};
  case 'codeStatus':{if(state==='none')return {state:'none'};tick++;const n=Math.min(L.length,tick);const from=d.from||0;const done=n>=L.length;if(done)state='pass';
    return {state:done?'pass':'running',lines:L.slice(from,n),next:n,project:'/Users/test/Scratch/demo-game',name:'demo-game',ask:window.__started.ask,model:window.__started.model,check:window.__started.check,startBranch:'main',
     branch:done?'harness/2026-11-09T21-00-00-000':'',files:done?['src/hud.js']:[],diff:done?' src/hud.js | 2 +-\n-  color: #ffd84a;\n+  color: #39ff14;':'',tries:done?2:0,secs:tick*19,undone,dry:false}}
  case 'codeUndo':undone=true;return {ok:true,text:'Undone. Back on main; the change on harness/2026-11-09T21-00-00-000 is gone.'};
  default:return {}}};
 window.webkit={messageHandlers:{act:{postMessage:m=>Promise.resolve(res(m.op,m))},net:{postMessage:m=>Promise.resolve({status:0,body:'',error:'unreachable'})},stream:{postMessage:()=>{}}}};
 window.__calls=calls})();
"""
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1100, "height": 820})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.add_init_script(MOCK)
    pg.goto(WEB.as_uri()); pg.wait_for_timeout(1200)
    pg.click("#codeBtn"); pg.wait_for_timeout(400)
    pg.click("#cPick"); pg.wait_for_timeout(300)
    pg.fill("#cAsk", "Make the points number in the score box bright green")
    pg.screenshot(path=str(HERE / "m1-ready.png"))
    pg.click("#cGo"); pg.wait_for_timeout(2600)
    mid = {"stopVisible": pg.is_visible("#cStop"), "goDisabled": pg.is_disabled("#cGo"), "state": pg.inner_text("#cState")}
    pg.screenshot(path=str(HERE / "m1-running.png"))
    pg.wait_for_timeout(5000)
    pg.screenshot(path=str(HERE / "m1-result.png"))
    res = pg.inner_text("#cResult")
    pg.once("dialog", lambda d: d.accept())
    pg.click("#cUndo"); pg.wait_for_timeout(300)
    pg.click("#myes"); pg.wait_for_timeout(600)
    after = pg.inner_text("#cResult")
    pg.screenshot(path=str(HERE / "m1-undone.png"))
    calls = pg.evaluate("window.__calls"); started = pg.evaluate("window.__started")
    out = {"errors": errs, "mid": mid, "result": res, "afterUndo": after, "started": started, "chatHidden": not pg.is_visible("#chat"),
           "usedOps": sorted(set(c for c in calls if c.startswith("code")))}
    print(json.dumps(out, indent=1))
    ok = not errs and mid["stopVisible"] and "Done in 2 tries" in res and "src/hud.js" in res and "harness/2026" in res and "Undone" in after and started["model"] == "ornith-1.5-9b-mlx-4bit"
    print("M1 MOCK UI:", "PASS" if ok else "FAIL"); b.close(); sys.exit(0 if ok else 1)
