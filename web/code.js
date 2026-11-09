// ---------- Code mode (Nov 9) ----------
// Hand-pick only: never part of Auto. Pick a project folder (a git repo), type a change, press Go.
// Switchboard runs the local coding harness (harness/project.js "real projects" mode) with the Code model on Osaurus.
// The harness edits on a new harness/<time> branch, runs the check, and keeps the change only if it passes; Stop undoes.
// Undo = back to her branch + delete the harness branch. The model is one setting (Port/CodeMode.swift defaultModel, or the menu here).
const CM={project:null,info:null,poll:null,next:0,cfg:null,last:null};
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
async function codeOpen(){const c=await act('codeConfig','');CM.cfg=c||{};
 const sel=$('cModel');sel.innerHTML='';for(const m of (c&&c.models)||[]){const o=document.createElement('option');o.value=m.id;o.textContent=m.name+(m.id===c.defaultModel?' (default)':'');sel.appendChild(o)}
 if(c&&c.model&&![...sel.options].some(o=>o.value===c.model)){const o=document.createElement('option');o.value=c.model;o.textContent=c.model;sel.appendChild(o)}
 if(c)sel.value=c.model;
 if(c&&!c.harnessOK)cState('The coding harness isn\'t installed at '+esc(c.harness)+'.');
 else if(c&&!c.node)cState('Node isn\'t installed, and the harness needs it.');
 if(!CM.project){const p=await act('prefsGet','',{key:'codeProject'});if(p&&p.value)await codeSetProject(p.value,true)}
 const st=await act('codeStatus','',{from:0});
 if(st&&(st.state==='running'||st.state==='starting')){CM.next=0;$('cLog').textContent='';codePoll()}
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
 else{n.className='sm bad';n.textContent='On branch '+r.branch+' · has changes not saved in git yet. Commit or stash them before pressing Go.'}}
$('cPick').onclick=async()=>{const r=await act('codePick','');if(!r||r.cancelled)return;codeProjUI(r)};
$('cAsk').addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();$('cForm').requestSubmit()}});
$('cForm').onsubmit=async ev=>{ev.preventDefault();if(CM.poll)return;const ask=$('cAsk').value.trim();
 if(!CM.project){cState('Choose a project folder first.');return}if(!ask){cState('Type the change you want first.');$('cAsk').focus();return}
 const dry=$('cDry').checked;
 const r=await act('codeStart','',{project:CM.project,ask,dry,check:$('cCheck').value.trim(),model:$('cModel').value});
 if(!r||!r.ok){cState(esc((r&&r.err)||'Couldn\'t start.'));return}
 $('cResult').hidden=true;$('cLog').textContent='';CM.next=0;codePoll()};
$('cStop').onclick=async()=>{$('cStop').disabled=true;await act('codeStop','');cState('Stopping… undoing any half-done edit.')};
function codeBusy(on){$('cGo').disabled=on;$('cStop').hidden=!on;$('cStop').disabled=false;$('cPick').disabled=on;$('cModel').disabled=on;$('cCheck').disabled=on;$('cDry').disabled=on}
function codePoll(){if(CM.poll)return;codeBusy(true);$('cLogBox').hidden=false;$('cLogBox').open=true;
 const tick=async()=>{const s=await act('codeStatus','',{from:CM.next});if(!s)return;
  if(s.lines&&s.lines.length){const L=$('cLog');const atEnd=L.scrollTop+L.clientHeight>=L.scrollHeight-30;L.textContent+=s.lines.join('\n')+'\n';if(atEnd)L.scrollTop=L.scrollHeight}
  CM.next=s.next||CM.next;
  if(s.state==='running'||s.state==='starting'){const tryM=[...$('cLog').textContent.matchAll(/try (\d+):/g)].pop();
   cState('<b>'+(s.dry?'Previewing':'Working')+'</b> on '+esc(s.name)+' with '+esc(mName(s.model))+' · '+cTime(s.secs)+(tryM?' · try '+tryM[1]+' of 3 done, trying again':s.dry?'':' · try 1 of 3')+(s.dry?'':' <span class="sm">(small models can take a few minutes per try)</span>'));return}
  clearInterval(CM.poll);CM.poll=null;codeBusy(false);cState('');codeShowResult(s);codeSetProject(s.project,true)};
 CM.poll=setInterval(tick,1000);tick()}
function codeShowResult(s){CM.last=s;const b=$('cResult');b.hidden=false;b.className='';const k=s.undone?'undone':s.state;b.classList.add(k);
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
 b.innerHTML=h;const u=$('cUndo');
 if(u)u.onclick=async()=>{if(!(await dialog('Undo this change? '+s.name+' goes back to '+s.startBranch+' and the branch '+s.branch+' is deleted.')))return;
  const r=await act('codeUndo','',{project:s.project,branch:s.branch,startBranch:s.startBranch});
  if(!r||!r.ok){cState(esc((r&&r.err)||'Couldn\'t undo.'));return}cState(esc(r.text||'Undone.'));s.undone=true;codeShowResult(s);codeSetProject(s.project,true)};
 const rv=$('cReveal');if(rv)rv.onclick=()=>act('revealPath','',{path:s.project})}
// selftest code (Nov 9): opens Code, picks the test project, presses Go with a test ask; waits for the result. Needs SB_CODE_* test env.
const _stCode=window.__selftest;window.__selftest=async(m,e,x)=>{if(m!=='code')return _stCode(m,e,x);await boot;codeShow(true);await sleep(800);
 const [proj,ask,dry]=(x||'||').split('||');if(proj)await codeSetProject(proj);$('cAsk').value=ask||'make the score green';$('cDry').checked=dry==='dry';$('cForm').requestSubmit();
 await sleep(1500);for(let i=0;i<600&&CM.poll;i++)await sleep(500);await sleep(300);
 return JSON.stringify({state:CM.last&&CM.last.state,branch:CM.last&&CM.last.branch,files:CM.last&&CM.last.files,result:$('cResult').textContent,log:$('cLog').textContent.slice(-800)})};
