// ---------- Code mode (Nov 9) ----------
// Hand-pick only: never part of Auto. Three jobs, all run by the local coding harness with the Code model on Osaurus:
//  Small change: pick a project folder (git repo), type a change -> harness/project.js edits on a harness/<time> branch,
//                runs the check, keeps it only if it passes. Stop undoes. Undo = back to her branch + delete the harness branch.
//  Big change:   same folder picker + clean-repo check -> harness/build.js plans small steps on a harness/build-<time> branch.
//  New project:  a name -> ~/Projects/<name> (must not exist or be empty) + an idea -> harness/build.js builds it step by step.
//  build.js: exit 0 = all steps done, 1 = stopped partway (done steps kept; run again carries on), 130/Stop = stopped.
// The model is one setting (Port/CodeMode.swift defaultModel, or the Model menu here).
const CM={project:null,info:null,poll:null,next:0,cfg:null,last:null,job:'small',newOK:null};
const JOBS={small:{intro:'Pick a project and say what to change. A model on this Mac makes the edit on a separate branch, checks the project still works, and gives you an Undo. Your main version is never touched.',ph:'What should change? (e.g. make the points number bright green)',go:'Go'},
 big:{intro:'For a bigger change to an existing project. The model splits it into small steps and does them one at a time on a separate branch, checking each one. Your main version is never touched, and Undo removes the whole branch.',ph:'Describe the big change (e.g. add a pause menu with Resume and Quit buttons)',go:'Start'},
 new:{intro:'Start a brand-new project from an idea. It makes a new folder in Projects with a simple starter page, plans small steps, and builds them one at a time, checking each one.',ph:'What should it be? (e.g. a simple space shooter: arrow keys to move, space to shoot)',go:'Build it'}};
function codeShow(on){document.body.classList.toggle('code',on);$('codeView').hidden=!on;
 if(on){document.body.classList.remove('search','notes');$('searchView').hidden=true;$('notesView').hidden=true;codeOpen()}}
{const _n=notesShow;notesShow=function(on){if(on)codeShow(false);return _n(on)};
 const _s=searchShow;searchShow=function(on){if(on)codeShow(false);return _s(on)};
 const _nc=newChat;newChat=function(){codeShow(false);return _nc.apply(this,arguments)};
 const _oc=openChat;openChat=function(id){codeShow(false);return _oc(id)}}
$('codeBtn').onclick=()=>{if(S.busy)return;codeShow(!document.body.classList.contains('code'))};
const cState=t=>{$('cState').innerHTML=t||''};
const mName=id=>((CM.cfg&&CM.cfg.models)||[]).find(m=>m.id===id)?.name||id;
const cTime=s=>s<90?Math.round(s)+' s':Math.round(s/60)+' min';
const isBuild=s=>s&&(s.kind==='big'||s.kind==='new');
function setJob(j,save){CM.job=JOBS[j]?j:'small';const J=JOBS[CM.job];
 document.querySelectorAll('.cjob').forEach(b=>{const on=b.dataset.job===CM.job;b.classList.toggle('on',on);b.setAttribute('aria-selected',on)});
 $('cIntro').textContent=J.intro;$('cAsk').placeholder=J.ph;$('cGoTxt').textContent=J.go;
 $('cNewRow').hidden=CM.job!=='new';$('cProjRow').hidden=CM.job==='new';$('cProjNote').hidden=CM.job==='new';
 $('cCheckWrap').hidden=CM.job!=='small';$('cDryWrap').hidden=CM.job!=='small';if(CM.job!=='small')$('cDry').checked=false;
 if(CM.job==='new')codeCheckName();if(save)act('prefsSet','',{key:'codeJob',value:CM.job})}
document.querySelectorAll('.cjob').forEach(b=>b.onclick=()=>{if(!CM.poll)setJob(b.dataset.job,true)});
let nameT=null;$('cName').addEventListener('input',()=>{clearTimeout(nameT);nameT=setTimeout(codeCheckName,250)});
async function codeCheckName(){const v=$('cName').value.trim(),n=$('cNewPath');CM.newOK=null;
 if(!v){n.className='sm';n.textContent='Makes a new folder in '+((CM.cfg&&CM.cfg.projectsRoot)||'~/Projects')+'.';return}
 const r=await act('codeInspectNew','',{name:v});if($('cName').value.trim()!==v)return;
 if(r&&r.ok){CM.newOK=r;n.className='sm';n.textContent='Will create '+r.display}else{n.className='sm bad';n.textContent=(r&&r.err)||'Can\'t use that name.'}}
async function codeOpen(){const c=await act('codeConfig','');CM.cfg=c||{};
 const sel=$('cModel');sel.innerHTML='';for(const m of (c&&c.models)||[]){const o=document.createElement('option');o.value=m.id;o.textContent=m.name+(m.id===c.defaultModel?' (default)':'');sel.appendChild(o)}
 if(c&&c.model&&![...sel.options].some(o=>o.value===c.model)){const o=document.createElement('option');o.value=c.model;o.textContent=c.model;sel.appendChild(o)}
 if(c)sel.value=c.model;
 if(c&&!c.harnessOK)cState('The coding harness isn\'t installed at '+esc(c.harness)+'.');
 else if(c&&!c.node)cState('Node isn\'t installed, and the harness needs it.');
 const pj=await act('prefsGet','',{key:'codeJob'});setJob((pj&&pj.value)||CM.job);
 if(!CM.project){const p=await act('prefsGet','',{key:'codeProject'});if(p&&p.value)await codeSetProject(p.value,true)}
 const st=await act('codeStatus','',{from:0});
 if(st&&(st.state==='running'||st.state==='starting')){CM.next=0;$('cLog').textContent='';setJob(st.kind||'small');codePoll()}
 else if(st&&st.state!=='none')codeShowResult(st);
 else if(c&&c.last&&c.last.state)codeShowResult(c.last)}
$('cModel').onchange=()=>act('prefsSet','',{key:'codeModel',value:$('cModel').value});
async function codeSetProject(path,quiet){const r=await act('codeInspect','',{path});codeProjUI(r,quiet)}
function codeProjUI(r,quiet){const n=$('cProjNote');n.className='sm';n.textContent='';
 if(!r||!r.path){if(!quiet){n.className='sm bad';n.textContent=(r&&r.err)||'Couldn\'t open that folder.'}return}
 CM.info=r;CM.project=r.ok?r.path:null;$('cProj').innerHTML='<b>'+esc(r.name)+'</b> · '+esc(r.path);$('cProj').title=r.path;
 if(!r.ok){n.className='sm bad';n.textContent=r.err;return}
 act('prefsSet','',{key:'codeProject',value:r.path});
 if(r.check&&!$('cCheck').value)$('cCheck').value=r.check;
 if(r.clean)n.textContent='On branch '+r.branch+' · no unsaved changes ✓';
 else{n.className='sm bad';n.textContent='On branch '+r.branch+' · has changes not saved in git yet. Commit or stash them before pressing '+JOBS[CM.job].go+'.'}}
$('cPick').onclick=async()=>{const r=await act('codePick','');if(!r||r.cancelled)return;codeProjUI(r)};
$('cAsk').addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();$('cForm').requestSubmit()}});
async function codeStart(p){const r=await act('codeStart','',p);if(!r||!r.ok){cState(esc((r&&r.err)||'Couldn\'t start.'));return false}
 $('cResult').hidden=true;$('cLog').textContent='';$('cSteps').hidden=true;CM.next=0;codePoll();return true}
$('cForm').onsubmit=async ev=>{ev.preventDefault();if(CM.poll)return;const ask=$('cAsk').value.trim(),job=CM.job;
 if(job==='new'){const nm=$('cName').value.trim();if(!nm){cState('Type a name for the new project first.');$('cName').focus();return}
  if(!ask){cState('Describe what to build first.');$('cAsk').focus();return}
  return codeStart({kind:'new',name:nm,ask,model:$('cModel').value})}
 if(!CM.project){cState('Choose a project folder first.');return}if(!ask){cState(job==='big'?'Describe the big change first.':'Type the change you want first.');$('cAsk').focus();return}
 codeStart({kind:job,project:CM.project,ask,dry:job==='small'&&$('cDry').checked,check:job==='small'?$('cCheck').value.trim():'',model:$('cModel').value})};
$('cStop').onclick=async()=>{$('cStop').disabled=true;await act('codeStop','');cState(CM.job==='small'?'Stopping… undoing any half-done edit.':'Stopping… the step in progress is undone; finished steps are kept.')};
function codeBusy(on){$('cGo').disabled=on;$('cStop').hidden=!on;$('cStop').disabled=false;$('cPick').disabled=on;$('cModel').disabled=on;$('cCheck').disabled=on;$('cDry').disabled=on;$('cName').disabled=on;
 document.querySelectorAll('.cjob').forEach(b=>b.disabled=on)}
const STEPI={done:'✓',running:'▶',failed:'✗',todo:'○'};
function stepsHTML(steps,tag){return '<'+tag+'>'+(steps||[]).map((x,i)=>'<li class="'+esc(x.status||'todo')+'"><span class="i">'+(STEPI[x.status]||'○')+'</span><span>'+(i+1)+'. '+esc(x.text)+'</span></li>').join('')+'</'+tag+'>'}
function codeSteps(s){const b=$('cSteps');if(!isBuild(s)||!(s.steps&&s.steps.length)){b.hidden=true;return}
 b.hidden=false;b.innerHTML='<div class="h">The plan · '+(s.doneN||0)+' of '+(s.total||s.steps.length)+' steps done</div>'+stepsHTML(s.steps,'ol')}
function codePoll(){if(CM.poll)return;codeBusy(true);$('cLogBox').hidden=false;$('cLogBox').open=true;
 const tick=async()=>{const s=await act('codeStatus','',{from:CM.next});if(!s)return;
  if(s.lines&&s.lines.length){const L=$('cLog');const atEnd=L.scrollTop+L.clientHeight>=L.scrollHeight-30;L.textContent+=s.lines.join('\n')+'\n';if(atEnd)L.scrollTop=L.scrollHeight}
  CM.next=s.next||CM.next;
  if(s.state==='running'||s.state==='starting'){
   if(isBuild(s)){codeSteps(s);const what=s.kind==='new'?'Building <b>'+esc(s.name)+'</b>':'Big change on <b>'+esc(s.name)+'</b>';
    cState(what+' with '+esc(mName(s.model))+' · '+cTime(s.secs)+' · '+(!s.total?'planning the steps…':!s.step?'plan ready ('+s.total+' steps), starting step 1…':'step '+s.step+' of '+s.total+(s.splitting?' · that step was too big, splitting it into smaller ones…':''))+' <span class="sm">(each step can take a few minutes)</span>');return}
   const tryM=[...$('cLog').textContent.matchAll(/try (\d+):/g)].pop();
   cState('<b>'+(s.dry?'Previewing':'Working')+'</b> on '+esc(s.name)+' with '+esc(mName(s.model))+' · '+cTime(s.secs)+(tryM?' · try '+tryM[1]+' of 3 done, trying again':s.dry?'':' · try 1 of 3')+(s.dry?'':' <span class="sm">(small models can take a few minutes per try)</span>'));return}
  clearInterval(CM.poll);CM.poll=null;codeBusy(false);cState('');codeShowResult(s);if(s.kind!=='new'&&s.project)codeSetProject(s.project,true)};
 CM.poll=setInterval(tick,1000);tick()}
function buildResult(s){const k=s.undone?'undone':s.state;const t=s.secs?' ('+cTime(s.secs)+')':'';const N=s.total||(s.steps||[]).length,D=s.doneN||0;
 const where=s.kind==='new'?'<b>'+esc(s.name)+'</b> · <code>'+esc(s.project)+'</code>':'<b>'+esc(s.name)+'</b>';let h='',cls=k;
 if(s.state==='done'&&!s.undone)h+='<div class="big">✅ All '+N+' step'+(N===1?'':'s')+' done'+t+'</div>';
 else if(s.undone)h+='<div class="big">↩︎ Undone</div><div>'+esc(s.name)+' is back on <code>'+esc(s.startBranch)+'</code>; the branch <code>'+esc(s.branch)+'</code> is deleted.</div>';
 else if(s.state==='partway'){cls='partway';h+='<div class="big">⏸ Stopped partway: '+D+' of '+N+' steps done'+t+'</div><div>A step didn\'t work even after splitting it into smaller ones. What\'s done is kept. Press <b>Run again to continue</b> to carry on from the next step, or reword the idea.</div>'}
 else if(s.state==='stopped')h+='<div class="big">⏹ Stopped'+(N?': '+D+' of '+N+' steps done':'')+'</div><div>'+(D?'Finished steps are kept; the step in progress was undone. Press <b>Run again to continue</b> to carry on.':'Nothing was built yet.'+(s.kind==='new'?'':' Your project is unchanged.'))+'</div>';
 else return ['<div class="big">⚠️ Couldn\'t run</div><div>'+esc(s.err||'Something went wrong.')+'</div>','error'];
 h+='<div>“'+esc(s.ask)+'” · '+where+' with '+esc(mName(s.model))+'</div>';
 if(s.kind==='big'&&s.branch&&!s.undone)h+='<div>Branch: <code>'+esc(s.branch)+'</code> · your <code>'+esc(s.startBranch)+'</code> branch is unchanged</div>';
 if(s.steps&&s.steps.length)h+='<details'+(s.state==='done'?'':' open')+'><summary>The plan</summary>'+stepsHTML(s.steps,'ol')+'</details>';
 if(!s.undone&&s.files&&s.files.length){h+='<div>Files '+(s.kind==='new'?'added or changed after the starter page':'changed')+':</div><ul>'+s.files.slice(0,30).map(f=>'<li><code>'+esc(f)+'</code></li>').join('')+(s.files.length>30?'<li>… and '+(s.files.length-30)+' more</li>':'')+'</ul>';
  if(s.diff)h+='<details><summary>See the exact changes</summary><pre>'+esc(s.diff)+'</pre></details>'}
 if(!s.undone)h+='<div class="warn">Each step was checked to still load and build. That doesn\'t prove it does what you meant, so try it.</div>';
 h+='<div class="nrow">'+(!s.undone&&(s.state==='partway'||s.state==='stopped')&&!(s.state==='stopped'&&!D&&s.kind==='big')?'<button type="button" id="cAgain">Run again to continue</button>':'')
  +'<button type="button" id="cReveal">Show in Finder</button>'+(s.kind==='big'&&s.branch&&!s.undone?'<button type="button" id="cUndo">Undo the whole change</button>':'')+'</div>';
 return [h,cls]}
function codeShowResult(s){CM.last=s;const b=$('cResult');b.hidden=false;b.className='';$('cSteps').hidden=true;
 if(isBuild(s)){const [h,cls]=buildResult(s);b.classList.add(cls);b.innerHTML=h;wireResult(s);return}
 const k=s.undone?'undone':s.state;b.classList.add(k);
 const tries=s.tries?' in '+s.tries+' tr'+(s.tries>1?'ies':'y'):'';const t=s.secs?' ('+cTime(s.secs)+')':'';let h='';
 if(s.state==='pass'){h+='<div class="big">'+(s.undone?'↩︎ Undone':'✅ Done'+tries+t)+'</div><div>“'+esc(s.ask)+'” in <b>'+esc(s.name)+'</b> with '+esc(mName(s.model))+'</div>';
  h+='<div>Branch: <code>'+esc(s.branch)+'</code>'+(s.undone?' (deleted)':'')+' · you started on <code>'+esc(s.startBranch)+'</code></div>';
  if(!s.undone){h+='<div>Files changed:</div><ul>'+(s.files||[]).map(f=>'<li><code>'+esc(f)+'</code></li>').join('')+'</ul>';
   if(s.diff)h+='<details><summary class="sm">See the exact change</summary><pre>'+esc(s.diff)+'</pre></details>';
   h+='<div class="warn">Passing means the project still '+(s.check?'passes “'+esc(s.check)+'”':'loads')+'. It doesn\'t prove the change is right, so look at it first. The project is now on the new branch.</div>';
   h+='<div class="nrow"><button type="button" id="cUndo">Undo this change</button><button type="button" id="cReveal">Show in Finder</button></div>'}}
 else if(s.state==='preview')h='<div class="big">👀 Preview</div><div>This is what the model would read for “'+esc(s.ask)+'”. Nothing was changed. Untick Preview only and press Go to make the change.</div>';
 else if(s.state==='stopped')h='<div class="big">⏹ Stopped</div><div>Nothing was kept. '+esc(s.name)+' is back on <code>'+esc(s.startBranch)+'</code>.</div>';
 else if(s.state==='fail')h='<div class="big">❌ Didn\'t work'+tries+t+'</div><div>The model couldn\'t make “'+esc(s.ask)+'” work. Nothing was kept; '+esc(s.name)+' is back on <code>'+esc(s.startBranch)+'</code>. Try wording it more exactly (name the thing on screen, or the file).</div>';
 else h='<div class="big">⚠️ Couldn\'t run</div><div>'+esc(s.err||'Something went wrong.')+'</div>';
 b.innerHTML=h;wireResult(s)}
function wireResult(s){const u=$('cUndo');
 if(u)u.onclick=async()=>{const msg=isBuild(s)?'Undo the whole change? '+s.name+' goes back to '+s.startBranch+' and the branch '+s.branch+' (all '+(s.doneN||0)+' finished steps) is deleted.':'Undo this change? '+s.name+' goes back to '+s.startBranch+' and the branch '+s.branch+' is deleted.';
  if(!(await dialog(msg)))return;
  const r=await act('codeUndo','',{project:s.project,branch:s.branch,startBranch:s.startBranch});
  if(!r||!r.ok){cState(esc((r&&r.err)||'Couldn\'t undo.'));return}cState(esc(r.text||'Undone.'));s.undone=true;codeShowResult(s);codeSetProject(s.project,true)};
 const rv=$('cReveal');if(rv)rv.onclick=()=>act('revealPath','',{path:s.project});
 const ag=$('cAgain');if(ag)ag.onclick=()=>{setJob(s.kind);codeStart({kind:s.kind,project:s.project,name:s.name,ask:s.ask,model:s.model||$('cModel').value,resume:true})}}
// selftest code (Nov 9): opens Code, picks the test project, presses Go with a test ask; waits for the result. Needs SB_CODE_* test env.
// x = "small||PROJECT||ASK||dry" or "big||PROJECT||IDEA" or "new||NAME||IDEA" (old form "PROJECT||ASK||dry" = small).
const _stCode=window.__selftest;window.__selftest=async(m,e,x)=>{if(m!=='code')return _stCode(m,e,x);await boot;codeShow(true);await sleep(800);
 let parts=(x||'||').split('||');if(!JOBS[parts[0]])parts=['small',...parts];const [job,proj,ask,dry]=parts;setJob(job);
 if(job==='new'){$('cName').value=proj;await codeCheckName()}else if(proj)await codeSetProject(proj);
 $('cAsk').value=ask||'make the score green';$('cDry').checked=dry==='dry';$('cForm').requestSubmit();
 await sleep(1500);for(let i=0;i<1200&&CM.poll;i++)await sleep(500);await sleep(300);
 return JSON.stringify({state:CM.last&&CM.last.state,kind:CM.last&&CM.last.kind,branch:CM.last&&CM.last.branch,files:CM.last&&CM.last.files,steps:CM.last&&CM.last.steps,result:$('cResult').textContent,log:$('cLog').textContent.slice(-800)})};
