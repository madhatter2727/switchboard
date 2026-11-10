#!/usr/bin/env python3
"""Code mode jobs (Big change / New project): the real web page in headless Chromium with a MOCKED Swift bridge.
No app, no model, no files. Run: ~/Projects/harness-game-kit/.venv/bin/python test-sandbox/code-mode/mock-ui-build.py"""
import json, pathlib, sys
from playwright.sync_api import sync_playwright
HERE = pathlib.Path(__file__).resolve().parent
WEB = HERE.parent.parent / "web" / "index.html"
MOCK = r"""
(()=>{let calls=[],tick=0,run=null,undone=false;window.__starts=[];
 const STEPS=['Draw the ship at the bottom','Move it with the arrow keys','Shoot with space'];
 // scenario: final = done | partway | stopped; doneN = steps finished at the end
 const sim=(d)=>{const k=d.kind,fin=window.__final||'done',dn=fin==='done'?3:(window.__doneN??1);
  const L=[(k==='new'?'New project':'Big change')+' · model: ornith-1.5-9b-mlx-4bit','Planning the steps...','Plan:',...STEPS.map((s,i)=>'  '+(i+1)+'. [ ] '+s)];
  for(let i=0;i<Math.min(3,dn+1);i++){L.push('=== Step '+(i+1)+' of 3: '+STEPS[i],'');L.push('  try 1: '+(i<dn?'edit applied, checks passed':'checks failed'),'')}
  L.push(dn+' of 3 steps done (4 min). Project: /x (branch '+(k==='big'?'harness/build-2026-11-09T22-00-00':'main')+').');return L};
 const path=d=>d.kind==='new'?'/Users/test/Projects/'+d.name:'/Users/test/Scratch/demo-game';
 const res=(op,d)=>{calls.push(op);switch(op){
  case 'prefsGet':return {value:null};
  case 'listChats':return {chats:[]};
  case 'codeConfig':return {model:'ornith-1.5-9b-mlx-4bit',defaultModel:'ornith-1.5-9b-mlx-4bit',models:[{id:'ornith-1.5-9b-mlx-4bit',name:'Ornith 1.5 9B'},{id:'twil-8b-mlx-4bit',name:'TwIL-8B'}],harnessOK:true,buildOK:true,node:'/x/node',projectsRoot:'~/Projects',last:null};
  case 'codePick':case 'codeInspect':return {ok:true,path:'/Users/test/Scratch/demo-game',name:'demo-game',branch:'main',clean:true,check:'npm run build'};
  case 'codeInspectNew':return d.name==='taken'?{ok:false,err:'~/Projects/taken already exists and isn\'t empty. Pick another name.'}:{ok:true,path:'/Users/test/Projects/'+d.name,name:d.name,display:'~/Projects/'+d.name};
  case 'codeStart':window.__starts.push(d);run={d,L:sim(d)};tick=0;undone=false;return {ok:true};
  case 'codeStatus':{if(!run)return {state:'none'};tick++;const L=run.L,d=run.d;const n=Math.min(L.length,tick*2);const done=n>=L.length;const fin=window.__final||'done';
    const dn=fin==='done'?3:(window.__doneN??1);const shown=L.slice(0,n);const cur=[...shown].reverse().find(l=>l.startsWith('=== Step'));const step=cur?+cur.match(/Step (\d+)/)[1]:0;
    const passed=shown.filter(l=>l.includes('checks passed')).length;
    const steps=shown.includes('Plan:')?STEPS.map((t,i)=>({text:t,status:i<passed?'done':(!done&&i+1===step)?'running':(done&&fin!=='done'&&i===dn&&fin==='partway')?'failed':'todo'})):[];
    return {state:done?fin:'running',kind:d.kind,lines:L.slice(d.from||0,n).length?L.slice(run.from||0,n):[],next:n,project:path(d),name:d.kind==='new'?d.name:'demo-game',ask:d.ask,model:d.model,
     startBranch:d.kind==='big'?'main':'',branch:d.kind==='big'?'harness/build-2026-11-09T22-00-00':'',steps,step,total:steps.length?3:0,doneN:passed,
     files:done?['src/ship.js','main.js']:[],diff:done?' main.js | 4 ++++':'',secs:tick*30,undone,byHand:fin==='stopped',exitCode:done?{done:0,partway:1,stopped:130}[fin]:-1}}
  case 'codeUndo':undone=true;return {ok:true,text:'Undone. Back on main; the change on harness/build-2026-11-09T22-00-00 is gone.'};
  case 'codeStop':{window.__final='stopped';const n=Math.min(run.L.length,tick*2);const keep=run.L.slice(0,n);const k=keep.filter(l=>l.includes('checks passed')).length;
    run.L=keep.concat(['Stopped. Finished steps are kept; run again to carry on.',k+' of 3 steps done (1 min).']);window.__doneN=k;return {ok:true}}
  default:return {}}};
 // codeStatus "from" handling: only send new lines
 const _res=res;const wrap=(op,d)=>{if(op==='codeStatus'&&run){run.from=d.from||0}return _res(op,d)};
 window.webkit={messageHandlers:{act:{postMessage:m=>Promise.resolve(wrap(m.op,m))},net:{postMessage:m=>Promise.resolve({status:0,body:'',error:'unreachable'})},stream:{postMessage:()=>{}}}};
 window.__calls=calls})();
"""
checks = []
def wait_done(pg, secs=30):
    """Wait until the run is over (Stop hidden again, result card shown)."""
    for _ in range(secs * 10):
        if not pg.is_visible("#cStop") and pg.is_visible("#cResult"): return
        pg.wait_for_timeout(100)
def check(name, ok):
    checks.append((name, bool(ok))); print(("PASS  " if ok else "FAIL  ") + name)
with sync_playwright() as p:
    b = p.chromium.launch(); pg = b.new_page(viewport={"width": 1100, "height": 900}); errs = []
    pg.on("pageerror", lambda e: errs.append(str(e))); pg.add_init_script(MOCK)
    pg.goto(WEB.as_uri()); pg.wait_for_timeout(1200); pg.click("#codeBtn"); pg.wait_for_timeout(400)
    check("three job buttons, Small change selected", pg.inner_text(".cjobs").count("change") == 2 and "New project" in pg.inner_text(".cjobs") and "small" == pg.get_attribute(".cjob.on", "data-job"))
    # ---- New project
    pg.click('.cjob[data-job="new"]'); pg.wait_for_timeout(200)
    check("New project: name row shown, folder row + check + preview hidden", pg.is_visible("#cName") and not pg.is_visible("#cPick") and not pg.is_visible("#cCheck") and not pg.is_visible("#cDry"))
    pg.fill("#cName", "taken"); pg.wait_for_timeout(600)
    check("existing non-empty folder is refused in the UI", "already exists" in pg.inner_text("#cNewPath"))
    pg.fill("#cName", "space-shooter"); pg.wait_for_timeout(600)
    check("shows where it will be created", "Will create ~/Projects/space-shooter" in pg.inner_text("#cNewPath"))
    pg.fill("#cAsk", "a simple space shooter"); pg.screenshot(path=str(HERE / "m3-new-ready.png"))
    pg.click("#cGo"); pg.wait_for_timeout(1500)
    plan_msg = pg.inner_text("#cState")
    for _ in range(40):
        if "▶" in (pg.inner_text("#cSteps") if pg.is_visible("#cSteps") else ""): break
        pg.wait_for_timeout(100)
    check("while planning it never says 'step 0'", "step 0" not in plan_msg)
    run_state, run_steps = pg.inner_text("#cState"), (pg.inner_text("#cSteps") if pg.is_visible("#cSteps") else "(steps hidden)")
    print("   status line:", run_state.replace("\n", " "), "| steps:", run_steps.replace("\n", " "))
    check("running: step plan with a running step, status says step N of 3", pg.is_visible("#cSteps") and "▶" in pg.inner_text("#cSteps") and "of 3" in pg.inner_text("#cState"))
    pg.screenshot(path=str(HERE / "m3-new-running.png"))
    wait_done(pg); r = pg.inner_text("#cResult")
    check("done card: all 3 steps done, folder, files, Show in Finder, no Undo", "All 3 steps done" in r and "/Users/test/Projects/space-shooter" in r and "src/ship.js" in r and pg.is_visible("#cReveal") and not pg.query_selector("#cUndo"))
    s0 = pg.evaluate("window.__starts[0]"); check("New project start sent kind=new + name + idea + default model", s0["kind"] == "new" and s0["name"] == "space-shooter" and s0["model"] == "ornith-1.5-9b-mlx-4bit")
    pg.screenshot(path=str(HERE / "m3-new-done.png"))
    # ---- Big change, stops partway
    pg.evaluate("window.__final='partway';window.__doneN=1"); pg.click('.cjob[data-job="big"]'); pg.wait_for_timeout(200)
    check("Big change: folder picker shown, name row hidden", pg.is_visible("#cPick") and not pg.is_visible("#cName"))
    pg.click("#cPick"); pg.wait_for_timeout(300); pg.fill("#cAsk", "add a pause menu"); pg.click("#cGo"); pg.wait_for_timeout(1500); wait_done(pg)
    r = pg.inner_text("#cResult")
    check("partway card: 1 of 3 done, Run again to continue, Undo, Show in Finder", "Stopped partway: 1 of 3" in r and pg.is_visible("#cAgain") and pg.is_visible("#cUndo") and pg.is_visible("#cReveal") and "harness/build-" in r)
    check("partway card lists the plan with the failed step", "✗" in r and "✓" in r)
    pg.screenshot(path=str(HERE / "m3-big-partway.png"))
    pg.evaluate("window.__final='done'"); pg.click("#cAgain"); pg.wait_for_timeout(1500); wait_done(pg)
    s2 = pg.evaluate("window.__starts[window.__starts.length-1]")
    check("Run again resends the same job with resume", s2["kind"] == "big" and s2["resume"] is True and s2["ask"] == "add a pause menu" and s2["project"] == "/Users/test/Scratch/demo-game")
    check("then: all done", "All 3 steps done" in pg.inner_text("#cResult"))
    pg.click("#cUndo"); pg.wait_for_timeout(300); pg.click("#myes"); pg.wait_for_timeout(600)
    check("Undo the whole change -> Undone card", "Undone" in pg.inner_text("#cResult") and "deleted" in pg.inner_text("#cResult"))
    # ---- Stop by hand
    pg.evaluate("window.__final='done';window.__doneN=1"); pg.fill("#cAsk", "add a pause menu"); pg.click("#cGo"); pg.wait_for_timeout(500)
    for _ in range(100):   # press Stop once the first step has passed
        if "✓" in (pg.inner_text("#cSteps") if pg.is_visible("#cSteps") else ""): break
        pg.wait_for_timeout(100)
    pg.click("#cStop"); pg.wait_for_timeout(500); wait_done(pg); r = pg.inner_text("#cResult")
    print("   stopped card:", r[:160].replace("\n", " | "), "| again:", pg.is_visible("#cAgain"))
    check("Stopped card: some steps kept, Run again to continue", "Stopped: " in r and "Stopped partway" not in r and " of 3 steps done" in r and "3 of 3" not in r and pg.is_visible("#cAgain"))
    pg.screenshot(path=str(HERE / "m3-big-stopped.png"))
    pg.click('.cjob[data-job="small"]'); pg.wait_for_timeout(200)
    check("back to Small change: check + preview shown again", pg.is_visible("#cCheck") and pg.is_visible("#cDry"))
    check("no page errors", not errs); print(errs)
    b.close()
bad = [n for n, ok in checks if not ok]; print(f"{len(checks)-len(bad)} passed, {len(bad)} failed"); sys.exit(1 if bad else 0)
