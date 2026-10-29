const $=id=>document.getElementById(id);
const nativeNet=(o)=>window.webkit.messageHandlers.net.postMessage(o);
let RID=0;const netC=o=>{const rid='r'+(++RID);S.curRid=rid;return nativeNet({...o,rid})}; // model requests the Stop button can cancel
const act=(op,engine,extra={})=>window.webkit.messageHandlers.act.postMessage({op,engine,...extra});
const ENGINES=[
 {id:'osaurus',name:'Osaurus',base:'http://127.0.0.1:1337/v1'},
 {id:'ollama',name:'Ollama',base:'http://127.0.0.1:11434/v1'},
 {id:'lmstudio',name:'LM Studio',base:'http://127.0.0.1:1234/v1'},
 {id:'magnitude',name:'Magnitude (fast)',base:'http://127.0.0.1:10100/inference/v1'},
 {id:'bonsai4b',name:'Bonsai 2 4B (Prism)',base:'http://127.0.0.1:8097/v1'},
 {id:'bonsai9b',name:'Bonsai 2 9B (Prism)',base:'http://127.0.0.1:8098/v1'},
 {id:'spark',name:'Spark X2.5 4B',base:'http://127.0.0.1:8095/v1'},
 {id:'bonsai27b',name:'Bonsai 2 27B (big: ~9 GB memory)',base:'http://127.0.0.1:8096/v1'},
 {id:'lfm3text',name:'LFM3 1.7B (Liquid AI)',base:'http://127.0.0.1:8110/v1'}, // Oct 28: own llama.cpp copy; started only when picked; thinking off; long documents up to ~100K tokens
 {id:'lfm3vl',name:'LFM3-VL 2B (Liquid AI)',base:'http://127.0.0.1:8111/v1'}, // sees pictures; Auto's FIRST picture reader since Oct 28 (see visionRoute), Bonsai 4B is the backup
 {id:'apple',name:'Apple (built-in)',base:'http://127.0.0.1:8100/v1'}, // Apple's on-device model via Apple Brain; Auto uses it only for plain, short chat (see appleCheck)
];
const S={collapsed:new Set(),auto:true,lastAuto:null,models:{},up:{},sel:null,startedByUs:new Set(),chat:null,chats:[],busy:false,switching:false,proxy:false};
const ALIAS={bonsai4b:'bonsai-2-4b',bonsai9b:'bonsai-2-9b',spark:'spark-x2.5-4b-mlx',bonsai27b:'bonsai-2-27b',apple:'apple-builtin',lfm3text:'lfm3-1.7b',lfm3vl:'lfm3-vl-2b'};
const UPSTREAM={spark:'/Users/madhatter2727/MLXModels/Spark-X2.5-4B-MLX-4bit'};
const up=(e,m)=>UPSTREAM[e]||m;
const isAgent=m=>/raptor|spark|bonsai-2-(4b|9b|27b)|^gemma4:e2b|^gemma-4-e2b|^ornith|qwen2\.5-coder/i.test(m); // badge = passed >=4 of 5 in bench/ (gemma2:2b: no tool support)
const isEmbed=m=>/embed/i.test(m)||m==='foundation';
const esc=s=>String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

async function getJSON(url,t=2){const r=await nativeNet({url,timeout:t});if(r.status!==200)return null;try{return JSON.parse(r.body)}catch{return null}}
async function refresh(){
 await Promise.all(ENGINES.map(async e=>{
  const j=await getJSON(e.base+'/models');
  if(j&&j.data){S.up[e.id]=true;let ids=j.data.map(m=>m.id).filter(m=>!isEmbed(m));
    if(ALIAS[e.id])ids=[ALIAS[e.id]];S.models[e.id]=ids.map(m=>({id:m,label:m}));
    // Magnitude: remember its list while it runs so the models still show (and can be picked) when it is off. Saved only when the list changes.
    if(e.id==='magnitude'){const k=ids.join('|');if(k&&S.magSaved!==k){S.magSaved=k;act('list','magnitude')}}}
  else{S.up[e.id]=false;if(e.id==='magnitude')S.magLoaded=null; // Magnitude stopped: whatever was loaded is gone, so load again on the next pick
   const r=await act('list',e.id);S.models[e.id]=(r.lines||[]).map(m=>({id:m,label:m}))}
 }));
 S.proxy=!!(await getJSON('http://127.0.0.1:7777/v1/models',2));
 render()}
const AUTOCUR='Auto · picks the best model for each message';
function agentUI(){if(S.auto){$('agent').disabled=true;const L=S.chat&&S.chat.lock;$('agentBox').className=L&&L.agent?'':'off';$('agent').checked=!!(L&&L.agent);
  $('agentNote').textContent=L?('Auto locked this chat to '+L.name+(L.agent?' with Agent mode (file and folder tools) on.':'.')+' Start a new chat for a fresh pick.'):'Auto picks a model on your first message, then keeps it for the whole chat.';return}
 const ok=S.sel&&isAgent(S.sel.m);$('agent').disabled=!ok;$('agentBox').className=ok?'':'off';if(!ok)$('agent').checked=false;
 $('agentNote').textContent=!S.sel?'':ok?(($('agent').checked)?'Agent mode is on: the model can look at your files. Anything that changes files asks you first. It cannot delete.':''):'Agent mode needs an agent-capable model (like Raptor). This one is chat-only.'}
$('agent').onchange=()=>{if(S.chat&&!S.auto){S.chat.agent=$('agent').checked;if(S.chat.messages.length)saveChat(S.chat)}agentUI()};
const thinkOff=(eid,body)=>{if(['bonsai4b','bonsai9b','spark','bonsai27b','lfm3text','lfm3vl'].includes(eid))body.chat_template_kwargs={enable_thinking:false};if(/raptor/i.test(body.model||''))body.reasoning_effort='none';return body};
// ---- context sizes (tokens) per engine; Bonsai runs with -c 65536 -np 1, Ollama with OLLAMA_CONTEXT_LENGTH=65536 ----
function ctxFor(eid,m){m=m||'';if(eid==='ollama')return /gemma2/i.test(m)?8192:65536;if(eid==='bonsai4b'||eid==='bonsai9b')return 65536;
 if(eid==='lfm3text')return 114688;if(eid==='lfm3vl')return 32768; // LFM3: llama-server -c 114688 (text) / 32768 (VL), see ~/Models/lfm3/start.sh
 if(eid==='bonsai27b'||/27b/i.test(m))return 16384;if(eid==='osaurus'||eid==='spark')return 32768;return 8192}
const tok=x=>Math.ceil((typeof x==='string'?x.length:JSON.stringify(x).replace(/data:image\/[a-z]+;base64,[A-Za-z0-9+\/=]+/g,'#'.repeat(S.sel&&S.sel.e==='lfm3vl'?12000:2400)).length)/3); // a picture counts as ~800 tokens (LFM3-VL: ~4,000 at full size), not its base64 size
const OUT_RESERVE=4096,TOOL_SCHEMA=2500;
function roomChars(eid,m,msgs){return Math.max(2000,(ctxFor(eid,m)-OUT_RESERVE-TOOL_SCHEMA-tok(msgs))*3)}
function maxOut(eid,m,msgs){return Math.max(1024,Math.min(16384,ctxFor(eid,m)-TOOL_SCHEMA-tok(msgs)))}
// History never gets silently cut: if it is too big for the model, the oldest tool results (then oldest turns) are swapped for a plain note saying so.
function fitHistory(api,eid,m,keepFrom){api=api.map(x=>({...x}));const lim=ctxFor(eid,m)-OUT_RESERVE-TOOL_SCHEMA;
 for(let i=1;i<keepFrom&&tok(api)>lim;i++){const x=api[i];if(x.role==='tool'&&x.content.length>400)x.content='[Earlier tool result ('+x.content.length+' characters) not re-sent: too big for this model together with the rest of the chat. Call the tool again if you need it.]'}
 let dropped=0;while(tok(api)>lim&&api.length>2&&1<keepFrom-dropped){const x=api[1];if(x.role==='system')break;api.splice(1,1);dropped++}
 if(dropped)api.splice(1,0,{role:'user',content:'[Note from the app: '+dropped+' earlier messages of this chat were not re-sent because the chat is longer than this model can hold. They are still saved in the chat.]'},{role:'assistant',content:'Understood.'});
 return api}
async function llm(eid,m,messages,maxTok){const e=ENGINES.find(x=>x.id===eid);
 const r=await netC({url:e.base+'/chat/completions',method:'POST',timeout:1800,body:JSON.stringify(thinkOff(eid,{model:up(eid,m),messages,stream:false,temperature:0.2,max_tokens:maxTok||1500,reasoning_effort:'none'}))});
 if(r.error==='cancelled'||S.stopAgent)throw new Error('stopped');if(r.status!==200)throw new Error('model error '+(r.status||'no connection'));return (JSON.parse(r.body).choices[0].message.content||'').trim()}
function splitChunks(text,size){const out=[];let i=0;while(i<text.length){let j=Math.min(text.length,i+size);if(j<text.length){const nl=text.lastIndexOf('\n',j);if(nl>i+size*0.6)j=nl+1}out.push([i,j]);i=j}return out}
// Reads ANY size: splits into parts that fit the model, takes notes on every part (same model), and repeats on the notes if they are still too big.
async function digest(text,label,question,eid,m,progress,depth=0){
 const size=Math.max(4000,(ctxFor(eid,m)-OUT_RESERVE-1500)*3);const parts=splitChunks(text,size);const notes=[];
 for(let k=0;k<parts.length;k++){if(S.stopAgent)throw new Error('stopped');const [a,b]=parts[k];progress&&progress('Reading '+label+': part '+(k+1)+' of '+parts.length+(depth?' (combining notes)':'')+'…');
  const sys='You read one part of a long '+(depth?'set of notes':'document')+' for the user. Their request: "'+question+'". Write short notes on everything in THIS part that matters for the request. Copy exact sentences when exact wording could matter (names, numbers, quotes, headings). Do not invent anything. If nothing in this part matters, write: Nothing relevant here.';
  const n=await llm(eid,m,[{role:'system',content:sys},{role:'user',content:'Part '+(k+1)+' of '+parts.length+' (characters '+a+'–'+b+' of '+text.length+'):\n\n'+text.slice(a,b)}],1200);
  notes.push('Part '+(k+1)+' (characters '+a+'–'+b+'): '+n)}
 let all=notes.join('\n\n');
 if(all.length>size&&depth<6)all=await digest(all,label,question,eid,m,progress,depth+1);
 return all}
function lockLabel(L){return 'Auto picked '+L.name+' ('+L.why+') · locked for this chat'}
// ---- Beauty M1: model look (icon colours + "good for" tags). Visual only: nothing here touches routing. ----
const BRANDS=[[/apple/i,'apple','#8DB8F0'],[/bonsai/i,'bonsai','#86CFAE'],[/raptor/i,'raptor','#B9A3EE'],[/spark/i,'spark','#F6B98A'],
 [/lfm3|liquid/i,'chip','#9CCBF0'],[/gemma/i,'gem','#F2D58A'],[/qwen/i,'qwen','#F0B0D2'],[/llama/i,'llama','#C9DC96'],[/ornith/i,'bird','#9ADBE0'],[/magnitude/i,'magnet','#E7C29A']];
const BRAND_DEFAULT='#DDD3C0';
function brandOf(t){t=String(t||'');for(const b of BRANDS)if(b[0].test(t))return{icon:b[1],c1:b[2]};return{icon:'chip',c1:BRAND_DEFAULT}}
const goodFor=m=>/apple/i.test(m)?'quick chat':/coder/i.test(m)?'codes':/bonsai-2-27b/i.test(m)?'heaviest thinker':/lfm3-1\.7b/i.test(m)?'long documents':'';
function render(){agentUI();
 $('engines').innerHTML='';
 const ad=document.createElement('div');ad.className='eng';ad.innerHTML='<div class="eh"><span class="dot on"></span>Auto</div><div class="sub">picks the best model for each message</div>';
 const ax=document.createElement('div');ax.className='m autorow on'+(S.auto?' sel':'');ax.innerHTML='<span class="mi" style="--c1:#F29A8A">'+IC('auto',20)+'</span><span class="mt"><span class="mn">Auto (recommended)</span><span class="mtags"><span class="badge agent">default</span></span></span><span class="led" title="Ready"></span>';ax.onclick=()=>{if(S.busy)return;S.auto=true;if(S.chat){S.chat.auto=true;S.chat.lock=null;if(S.chat.messages.length)saveChat(S.chat)}$('cur').textContent=AUTOCUR;showChat();render()};ad.appendChild(ax);$('engines').appendChild(ad);
 // Big multi-model servers keep their own heading; engines that list exactly ONE model go together under "Other".
 const MULTI=new Set(['osaurus','ollama','lmstudio']);
 const single=ENGINES.filter(e=>!MULTI.has(e.id)&&(S.models[e.id]||[]).length===1),singleIds=new Set(single.map(e=>e.id));
 const modelRow=(e,m,up,showEng)=>{const x=document.createElement('div');x.className='m '+(up?'on':'off')+(!S.auto&&S.sel&&S.sel.e===e.id&&S.sel.m===m.id?' sel':'');x.dataset.eid=e.id;
  const br=brandOf(m.id+' '+e.id),gf=goodFor(m.id);
  x.innerHTML=`<span class="mi" style="--c1:${br.c1}">${IC(br.icon,20)}</span><span class="mt"><span class="mn" title="${esc(m.label)}">${esc(m.label)}</span>${showEng?`<span class="msub">${esc(e.name)}</span>`:''}<span class="mtags">${gf?`<span class="badge use">${gf}</span>`:''}${isVision(m.id)?'<span class="badge see" title="Can see pictures you paste or attach">sees pictures</span>':''}<span class="badge ${isAgent(m.id)?'agent':'chat'}">${isAgent(m.id)?'agent-capable':'chat'}</span></span></span><span class="led" title="${up?'Ready':'Off (starts when you pick it)'}"></span>`;
  x.onclick=()=>pick(e.id,m.id);return x};
 for(const e of ENGINES){
  if(singleIds.has(e.id))continue;
  const d=document.createElement('div');d.className='eng';d.dataset.eid=e.id;const up=S.up[e.id];const ms=S.models[e.id]||[];
  const col=S.collapsed.has(e.id);const inUse=!S.auto&&S.sel&&S.sel.e===e.id;if(col)d.classList.add('collapsed');
  d.innerHTML=`<div class="eh" title="${col?'Show':'Hide'} these models"><button type="button" class="tog" aria-label="${col?'Expand':'Collapse'}">${IC(col?'chevR':'chevD',14,2.6)}</button><span class="dot ${up?'on':''}"></span>${e.name}${col?`<span class="cnt">${ms.length} model${ms.length===1?'':'s'}</span>`:''}</div><div class="sub">${up?'running':'off (starts when you pick a model)'}${col&&inUse?' · in use: '+esc(S.sel.m):''}</div>`;
  d.querySelector('.eh').onclick=()=>{if(S.collapsed.has(e.id))S.collapsed.delete(e.id);else S.collapsed.add(e.id);act('prefsSet','',{key:'collapsed',value:[...S.collapsed]});render()};
  if(col){$('engines').appendChild(d);continue}
  if(!ms.length){const s=document.createElement('div');s.className='sub';s.textContent='no chat models found';d.appendChild(s)}
  for(const m of ms)d.appendChild(modelRow(e,m,up,false));
  $('engines').appendChild(d)}
 if(single.length){
  const col=S.collapsed.has('other'),anyUp=single.some(e=>S.up[e.id]),inUse=!S.auto&&S.sel&&single.some(e=>e.id===S.sel.e);
  const d=document.createElement('div');d.className='eng other'+(col?' collapsed':'');
  d.innerHTML=`<div class="eh" title="${col?'Show':'Hide'} these models"><button type="button" class="tog" aria-label="${col?'Expand':'Collapse'}">${IC(col?'chevR':'chevD',14,2.6)}</button><span class="dot ${anyUp?'on':''}"></span>Other<span class="cnt">${single.length} model${single.length===1?'':'s'}</span></div><div class="sub">engines with just one model each${col&&inUse?' · in use: '+esc(S.sel.m):''}</div>`;
  d.querySelector('.eh').onclick=()=>{if(S.collapsed.has('other'))S.collapsed.delete('other');else S.collapsed.add('other');act('prefsSet','',{key:'collapsed',value:[...S.collapsed]});render()};
  if(!col)for(const e of single)d.appendChild(modelRow(e,S.models[e.id][0],S.up[e.id],true));
  $('engines').appendChild(d)}
 renderChats();updateChip();lightsWake();memSoon();
}
// status lights: green = ready, yellow = waking up (the app says "Starting X…"), hollow = off. Reads the status text only; nothing here starts or stops anything.
function lightsWake(){const t=($('status').textContent||'');const w=ENGINES.find(x=>t==='Starting '+x.name+'…');
 document.querySelectorAll('#engines [data-eid]').forEach(el=>el.classList.toggle('wake',!!w&&el.dataset.eid===w.id&&!el.classList.contains('on')))}
function updateChip(){const el=$('curChip');if(!el)return;let k='auto',c='#F29A8A';
 if(!S.auto&&S.sel){const b=brandOf(S.sel.m+' '+S.sel.e);k=b.icon;c=b.c1}
 else if(S.auto&&S.chat&&S.chat.lock){const b=brandOf(S.chat.lock.m+' '+S.chat.lock.e);k=b.icon;c=b.c1}
 el.style.background=c;el.innerHTML=IC(k,20)}
const status=t=>{$('status').textContent=t||'';try{lightsWake()}catch{}};
// ---- Brain space: how much of the Mac's memory is in use. Read-only 'mem' question to the app (no engine is touched). ----
let memLast=0,memBusy=false,memTimer=null;
async function memUpdate(){if(memBusy||document.hidden||document.body.classList.contains('mini'))return;memBusy=true;memLast=Date.now();
 try{const r=await act('mem','');const box=$('mem');if(!r||!r.total||r.used==null){box.hidden=true;return}
  const G=1024*1024*1024,pct=Math.max(0,Math.min(100,r.used/r.total*100));
  box.hidden=false;box.classList.toggle('warn',pct>75&&pct<=90);box.classList.toggle('hot',pct>90);
  $('memFill').style.width=pct.toFixed(1)+'%';
  const tot=r.total/G;$('memTxt').textContent=(r.used/G).toFixed(1)+' of '+(Number.isInteger(tot)?tot:tot.toFixed(1))+' GB used';
  $('memBar').setAttribute('aria-valuenow',Math.round(pct));$('memBar').title=Math.round(pct)+'% of memory in use'+(pct>90?' (very full)':pct>75?' (getting full)':'')}
 catch{try{$('mem').hidden=true}catch{}}finally{memBusy=false}}
// after a model starts or stops (render runs after those): look again soon, and once more when its memory has settled. At most one look per 5 seconds.
function memSoon(){if(Date.now()-memLast<5000)return;clearTimeout(memTimer);memTimer=setTimeout(()=>{memUpdate();memTimer=setTimeout(memUpdate,7000)},1500)}
setInterval(memUpdate,10000);document.addEventListener('visibilitychange',()=>{if(!document.hidden)memUpdate()});


// ---- in-page dialogs (WKWebView has no confirm/prompt) ----
function dialog(text,{input=null,yes='OK',no='Cancel'}={}){return new Promise(res=>{
 $('myes').textContent=yes;$('mno').textContent=no;
 setDialogText(text);const mi=$('minput');mi.hidden=input===null;if(input!==null)mi.value=input;$('modal').hidden=false;
 if(input!==null)mi.focus();
 const done=v=>{$('modal').hidden=true;res(v)};
 $('myes').onclick=()=>done(input===null?true:mi.value);$('mno').onclick=()=>done(null);
 mi.onkeydown=e=>{if(e.key==='Enter')$('myes').click()};
 document.onkeydown=e=>{if(!$('modal').hidden&&e.key==='Escape'){e.preventDefault();$('mno').click()}}})}

// ---- chat history (saved to ~/Library/Application Support/Model Picker/chats) ----
async function loadChats(){const r=await act('listChats','');S.chats=(r.chats||[]).map(t=>{try{return JSON.parse(t)}catch{return null}}).filter(Boolean).sort((a,b)=>b.updated-a.updated)}
function saveChat(c){c.updated=Date.now();act('saveChat','',{id:c.id,json:JSON.stringify(c)});
 if(!S.chats.find(x=>x.id===c.id))S.chats.unshift(c);S.chats.sort((a,b)=>b.updated-a.updated);renderChats()}
function newChat(){S.chat={id:'c'+Date.now().toString(36)+Math.random().toString(36).slice(2,6),title:'New chat',created:Date.now(),updated:Date.now(),engine:S.sel?.e||null,model:S.sel?.m||null,auto:S.auto,lock:null,agent:S.sel?isAgent(S.sel.m):undefined,messages:[],saved:false};if(S.auto)$('cur').textContent=AUTOCUR;if(!S.auto&&S.sel)$('agent').checked=isAgent(S.sel.m);showChat();agentUI()}
function showChat(){const c=$('chat');c.innerHTML='';
 if(!S.chat||!S.chat.messages.length)c.innerHTML='<div class="empty"><div class="wlogo">'+LOGO(64)+'</div><h2>What shall we do today?</h2><p>'+(S.auto?'Ready. Just type what you want. Auto picks the right model for you.':S.sel?'Ready. Say hi to '+esc(S.sel.m)+'.':'Pick a model on the left, then say hi.')+'</p></div>';
 else{S.hist=true;try{S.chat.messages.forEach(m=>m.role==='step'?addStep(m):addMsg(m.role==='user'?'user':'assistant',m.content,m.via,m))}finally{S.hist=false}}renderChats();updateChip()}
function renderChats(){const box=$('chats');box.innerHTML='';
 if(!S.chats.length)box.innerHTML='<div class="sub" style="margin-left:0">No saved chats yet.</div>';
 for(const c of S.chats){const d=document.createElement('div');d.className='ch'+(S.chat&&S.chat.id===c.id?' sel':'');
  d.innerHTML=`<span class="ci">${IC('chat',15)}</span><span class="t" title="${esc(c.model||'')}">${esc(c.title)}</span><span class="when" title="${c.updated?esc(new Date(c.updated).toLocaleString()):''}">${esc(fmtChatWhen(c.updated))}</span><button class="ren" title="Rename" aria-label="Rename">${IC('pencil',14)}</button><button class="del" title="Delete" aria-label="Delete">${IC('trash',14)}</button>`;
  d.onclick=()=>openChat(c.id);
  d.querySelector('.ren').onclick=async ev=>{ev.stopPropagation();const n=await dialog('Rename chat',{input:c.title});if(n&&n.trim()){c.title=n.trim();saveChat(c)}};
  d.querySelector('.del').onclick=async ev=>{ev.stopPropagation();if(await dialog('Delete the chat "'+c.title+'"? It goes to the Trash.')){await act('trashChat','',{id:c.id});S.chats=S.chats.filter(x=>x.id!==c.id);if(S.chat&&S.chat.id===c.id)newChat();else renderChats()}};
  box.appendChild(d)}}
function openChat(id){if(S.busy)return;const c=S.chats.find(x=>x.id===id);if(!c)return;S.chat=c;S.auto=!!c.auto;
 if(S.auto&&!c.lock&&c.messages.length&&c.engine&&c.model)c.lock={e:c.engine,m:c.model,name:c.model,why:'earlier chat',agent:isAgent(c.model)};
 if(S.auto)$('cur').textContent=c.lock?('Auto · locked to '+c.lock.name+' for this chat'):AUTOCUR;
 if(S.auto&&c.lock)S.sel={e:c.lock.e,m:c.lock.m};
 if(!S.auto&&c.model)$('agent').checked=typeof c.agent==='boolean'?c.agent:isAgent(c.model);
 if(!S.auto&&c.engine&&c.model){S.sel={e:c.engine,m:c.model};writeState();const e=ENGINES.find(x=>x.id===c.engine);$('cur').textContent=(e?e.name:c.engine)+' · '+c.model}
 showChat()}
function writeState(){if(S.sel)act('state','',{json:JSON.stringify(S.sel)})}

async function waitUp(e,sec=300){for(let i=0;i<sec;i++){const j=await getJSON(e.base+'/models',2);if(j&&j.data)return true;await new Promise(r=>setTimeout(r,1000))}return false}
async function ensureEngine(eid,mid){
 const e=ENGINES.find(x=>x.id===eid);
 if(!(await getJSON(e.base+'/models'))){status('Starting '+e.name+'…');await act('start',eid);S.startedByUs.add(eid);
   if(!(await waitUp(e,(eid==='lfm3vl'||eid==='lfm3text')?60:300))){status('');return false}}
 if(eid==='magnitude'&&S.magLoaded!==mid){status('Loading model into Magnitude…');await act('load','magnitude',{model:mid});S.magLoaded=mid}
 status('');return true}
async function pick(eid,mid,keepAuto){
 if(S.busy||S.switching)return;S.switching=true;if(!keepAuto){S.auto=false;if(S.chat)S.chat.auto=false}
 try{
  const e=ENGINES.find(x=>x.id===eid);const prev=S.sel;
  if(prev&&prev.e!==eid){status('Stopping '+prev.e+'…');
   if(S.startedByUs.has(prev.e)){await act('stop',prev.e);S.startedByUs.delete(prev.e)}
   else if(prev.e==='magnitude'){await act('stop','magnitude');S.magLoaded=null}
   else if(prev.e==='ollama')await nativeNet({url:'http://127.0.0.1:11434/api/generate',method:'POST',body:JSON.stringify({model:prev.m,keep_alive:0}),timeout:10});}
  if(!(await ensureEngine(eid,mid))){if(!(eid==='lfm3vl'&&keepAuto))addMsg('err','Could not start '+e.name+'. Try opening it yourself once.');return}
  S.sel={e:eid,m:mid};writeState();
  if(!S.chat||S.chat.messages.length===0)newChat();
  if(!S.auto){$('cur').textContent=e.name+' · '+mid+(isAgent(mid)?'  (agent-capable)':'');
   const keep=S.chat&&S.chat.model===mid&&typeof S.chat.agent==='boolean';$('agent').checked=keep?S.chat.agent:isAgent(mid);if(S.chat)S.chat.agent=$('agent').checked}
  if(S.chat.messages.length===0){showChat()}
  S.chat.engine=eid;S.chat.model=mid;if(S.chat.messages.length)saveChat(S.chat);
  await refresh();
 }finally{S.switching=false}
}
function tagVia(d,via){if(!via)return;const v=document.createElement('div');v.className='via';v.textContent=via;d.appendChild(v);const b=brandOf(via);if(b.c1!==BRAND_DEFAULT)d.style.setProperty('--edge',b.c1);
 if(/^Auto picked/.test(via)){v.classList.add('cord');if(S.busy){try{const a=document.querySelector('#engines .autorow');if(a){a.classList.remove('pulse');void a.offsetWidth;a.classList.add('pulse');setTimeout(()=>a.classList.remove('pulse'),1800)}}catch{}}}}
// ---- times + copy (Oct 27) ----
const TFMT={hour:'numeric',minute:'2-digit'};
function fmtMsgTime(ts){if(!ts)return '';const d=new Date(ts),n=new Date();const t=d.toLocaleTimeString('en-US',TFMT);
 if(d.toDateString()===n.toDateString())return t;
 return d.toLocaleDateString('en-US',{weekday:'short',month:'short',day:'numeric',...(d.getFullYear()!==n.getFullYear()?{year:'numeric'}:{})})+' \u00b7 '+t}
function fmtChatWhen(ts){if(!ts)return '';const d=new Date(ts),n=new Date();if(d.toDateString()===n.toDateString())return d.toLocaleTimeString('en-US',TFMT);
 const y=new Date(n);y.setDate(n.getDate()-1);if(d.toDateString()===y.toDateString())return 'Yesterday';
 return d.toLocaleDateString('en-US',{month:'short',day:'numeric',...(d.getFullYear()!==n.getFullYear()?{year:'numeric'}:{})})}
async function copyText(t){t=String(t==null?'':t);
 try{const r=await act('copy','',{text:t});if(r&&r.copied)return true}catch{}
 try{await navigator.clipboard.writeText(t);return true}catch{}
 try{const ta=document.createElement('textarea');ta.value=t;ta.style.cssText='position:fixed;opacity:0;left:-9999px;top:0';document.body.appendChild(ta);ta.select();const ok=document.execCommand('copy');ta.remove();return !!ok}catch{return false}}
function rawOf(d){if(d._raw!=null)return d._raw;const c=d.cloneNode(true);c.querySelectorAll('.via,.mtime,.cpy,.attrow,.play,.frow').forEach(x=>x.remove());return c.textContent}
function decorate(d,ts,raw){d.querySelectorAll(':scope>.mtime,:scope>.cpy').forEach(x=>x.remove());if(raw!=null)d._raw=raw;
 const tm=fmtMsgTime(ts);if(tm){const t=document.createElement('div');t.className='mtime';t.textContent=tm;t.title=new Date(ts).toLocaleString();d.appendChild(t)}
 const b=document.createElement('button');b.type='button';b.className='cpy';b.title='Copy';b.setAttribute('aria-label','Copy this message');b.innerHTML=IC('copy',15);
 b.onclick=async e=>{e.stopPropagation();if(await copyText(rawOf(d))){b.classList.add('done');b.innerHTML=IC('check',15);b.title='Copied';setTimeout(()=>{b.classList.remove('done');b.innerHTML=IC('copy',15);b.title='Copy'},1400)}};d.appendChild(b)}
function addMsg(cls,text,via,mo){const c=$('chat');if(c.querySelector('.empty'))c.innerHTML='';const d=document.createElement('div');d.className='msg '+cls;
 if(cls==='assistant'&&/```/.test(text||''))richText(d,text,mo);else d.textContent=text;
 if(mo&&mo.atts&&mo.atts.length){const r=document.createElement('div');r.className='attrow';mo.atts.forEach(a=>{const c=document.createElement('span');c.className='chip';c.innerHTML=IC(a.kind==='image'?'img':'doc',14);c.append(' '+a.name);r.appendChild(c)});d.appendChild(r)}
 if(mo&&mo.webFiles)mo.webFiles.forEach(p=>d.appendChild(playRow(p)));tagVia(d,via);
 if(cls==='user'||cls==='assistant'){let ts=mo&&mo.ts;if(!ts&&!S.hist){ts=Date.now();if(mo)mo.ts=ts}if(text||mo)decorate(d,ts,mo&&typeof mo.content==='string'?mo.content:text)}
 c.appendChild(d);c.scrollTop=c.scrollHeight;return d}
let SID=0;const pending={};
window.__stream=ev=>{const p=pending[ev.id];if(p)p(ev)};

// ---- Auto: simple keyword rules choose the model ----
// Oct 28: single everyday words no longer trigger by themselves. 'app', 'game', 'note' and 'find' only count in a real request (e.g. "build an app", "make a snake game", "my notes", "find the PDF"); 'code' skips area/zip/promo codes.
const CODE_RX=/(?<!\b(?:area|zip|postal|promo|country|dress|morse|discount|coupon|access|qr|bar|pin) )\b(?:code|coding|script|bug|debug|html|css|javascript|js|python|swift|function|program|snake|regex|compile|error in|sql|api|refactor|algorithm|for loop|while loop|snippet|stack ?trace|unit test|typescript|bash)\b|\b(?:build|make|create|write|develop|code|program)\b[^.?!]{0,25}\b(?:app|game)\b|\b(?:html|web|browser|video|text|python|javascript)\s+(?:app|game)\b/i;
const FILE_RX=/\b(?:pages|keynote|textedit|docx|txt|markdown|notes app|my notes|the notes|take (?:a )?notes?|add (?:a )?notes?|save (?:a )?notes?|file|files|folder|folders|directory|calendar|schedule|meeting|meetings|event|events|move|rename|search|downloads|desktop|documents|screenshot|screenshots|pdf|doc|docs|document|documents|open)\b/i;
function chatNote(t){const n=document.createElement('div');n.className='attnote';n.textContent=t;const c=$('chat');if(c.querySelector('.empty'))c.innerHTML='';c.appendChild(n);c.scrollTop=c.scrollHeight}
function haveModel(eid){return (S.models[eid]||[]).length>0}
// ---- Picture routing (Oct 27): with a picture attached Auto picks the BEST model that can see pictures, on any engine. ----
// Ranking, best first (only models that are installed/listed; an engine that is off still lists what it has, and Switchboard starts it on pick):
//   1 LFM3-VL 2B (Oct 28: first picture reader; fast, photos go at up to ~2048 px / ~4,000 picture tokens; skipped for the session if it fails to start or errors)
//   2 Bonsai 2 4B (backup; faster than 9B, same score in the m4 photo test)  3 Bonsai 2 9B  4 a Gemma 4 model on any engine  5 any other picture-capable model on any engine.
// Inside tier 4 or 5: a model whose engine is already running wins over one that must be started, then the bigger one wins.
// Photo Reader is only the last resort (no picture-capable model at all): see autoSwitch.
const hasPic=()=>S.att.some(a=>a.kind==='image');
const lfmOK=()=>!S.lfmDown&&!(S.chat&&S.chat.lfmFailed); // LFM3-VL is tried first; after one failure it is skipped (this session / this chat) and Bonsai takes over
function visionRoute(){
 const mk=(e,m,n)=>({e,m,name:n+' (can see pictures)',agent:false,why:'picture attached'});
 if(lfmOK()&&haveModel('lfm3vl'))return mk('lfm3vl',ALIAS.lfm3vl,'LFM3-VL 2B');
 if(haveModel('bonsai4b'))return mk('bonsai4b',ALIAS.bonsai4b,'Bonsai 4B');
 if(haveModel('bonsai9b'))return mk('bonsai9b',ALIAS.bonsai9b,'Bonsai 9B');
 const size=id=>{const x=/(\d+(?:\.\d+)?)b/i.exec(id);return x?parseFloat(x[1]):0};
 const c=[];ENGINES.forEach(e=>{if(ALIAS[e.id])return; // Bonsai handled above; Spark/Apple/27B do not see pictures
  (S.models[e.id]||[]).forEach(m=>{if(isVision(m.id))c.push({e:e.id,m:m.id,g4:/gemma-?4/i.test(m.id)?1:0,up:S.up[e.id]?1:0,sz:size(m.id)})})});
 c.sort((a,b)=>b.g4-a.g4||b.up-a.up||b.sz-a.sz);
 return c.length?mk(c[0].e,c[0].m,c[0].m):null}
function autoRoute(text){
 if(hasPic()){const v=visionRoute();if(v)return v} // no picture-capable model: fall through to the usual pick; Photo Reader describes the picture (autoSwitch adds a note)
 const raptor=(S.models.osaurus||[]).find(m=>/raptor/i.test(m.id));
 const R={e:'osaurus',m:raptor?raptor.id:'raptor-0.6-4b-jang_6m',name:'Raptor',agent:false};
 if(CODE_RX.test(text)){
  if(haveModel('bonsai9b'))return {e:'bonsai9b',m:ALIAS.bonsai9b,name:'Bonsai 9B',agent:false,why:'coding'};
  if(haveModel('spark'))return {e:'spark',m:ALIAS.spark,name:'Spark',agent:false,why:'coding'};
  return {...R,why:'coding (no coder installed)'}}
 if(FILE_RX.test(text))return {...R,agent:true,why:'files or calendar'};
 if(haveModel('bonsai4b'))return {e:'bonsai4b',m:ALIAS.bonsai4b,name:'Bonsai 4B',agent:false,why:'quick chat'};
 return {...R,why:'quick chat'}}
// ---- Auto may pick Apple (built-in) for plain, short chat only (Oct 22). Apple's model holds about 4,000 tokens. ----
const APPLE_BUDGET=2500,APPLE_REPLY=1000; // chat so far + this message + room for the reply must stay under ~2,500 tokens
const ACTION_RX=/\b(open|close|quit|launch|start|run|create|make|write|edit|change|update|save|delete|remove|trash|move|rename|copy|paste|install|download|upload|send|email|mail|text|message|remind|reminder|reminders|click|type|play|record|turn on|turn off|set up|setup|browser|safari|finder|terminal|apps?|website|url|link)\b/i;
const REASON_RX=/\b(step[- ]by[- ]step|in detail|detailed|in depth|thorough|thoroughly|prove|proof|derive|analy[sz]e|analysis|compare|comparison|pros and cons|plan|planning|strategy|research|essay|report|summari[sz]e|translate|calculate|solve|math|equation|reasoning|think through|evaluate|review|outline|itinerary|lesson)\b/i;
const estTok=s=>Math.ceil(String(s||'').length/3);
function chatTokens(ch){return (ch&&ch.messages||[]).reduce((n,m)=>n+4+estTok(typeof m.content==='string'?m.content:JSON.stringify(m.content))+(m.attText?estTok(m.attText):0),0)}
function appleCheck(text){
 if(!haveModel('apple'))return {ok:false,why:'Apple (built-in) not installed'};
 if(S.appleDown)return {ok:false,why:'Apple Brain did not start earlier'};
 if(S.chat&&S.chat.appleFailed)return {ok:false,why:'Apple had an error in this chat'};
 if(S.att.length)return {ok:false,why:'attachment'};
 if(S.chat&&(S.chat.messages||[]).some(m=>(m.atts&&m.atts.length)||Array.isArray(m.content)||m.role==='tool'))return {ok:false,why:'chat has attachments or tool results'};
 if(CODE_RX.test(text))return {ok:false,why:'coding'};
 if(FILE_RX.test(text)||ACTION_RX.test(text))return {ok:false,why:'files or app control'};
 if(REASON_RX.test(text))return {ok:false,why:'long reasoning'};
 if(text.length>500||text.split('\n').length>6)return {ok:false,why:'long message'};
 const t=chatTokens(S.chat)+estTok(text)+60+APPLE_REPLY;
 if(t>APPLE_BUDGET)return {ok:false,why:'chat too long for Apple (~'+t+' tokens)',tokens:t};
 return {ok:true,why:'plain short chat',tokens:t}}
const _autoRouteBase=autoRoute;
autoRoute=function(text){const base=_autoRouteBase(text);if(base.why!=='quick chat')return base; // pictures, coding and files keep their usual models
 const a=appleCheck(text);return a.ok?{e:'apple',m:ALIAS.apple,name:'Apple (built-in)',agent:false,why:'plain short chat'}:base};
function appleFallback(text,reason){const b=_autoRouteBase(text);return {...b,agent:!!b.agent||isAgent(b.m),why:b.why+(reason?' · '+reason:'')}}
async function autoSwitch(text){
 const ch=S.chat;let r=ch&&ch.lock;
 // A chat locked to Apple moves to the usual model once it stops being plain and short (Apple can't hold more).
 if(r&&r.e==='apple'){const a=appleCheck(text);if(!a.ok){ch.lock=null;r=appleFallback(text,'moved off Apple: '+a.why)}}
 if(r&&hasPic()&&!isVision(r.m)){const v=visionRoute();if(v){ch.lock=null;r=null}} // a chat locked to a text-only model moves to a picture-capable one when a picture arrives
 if(!r){r=autoRoute(text);r={...r,agent:!!r.agent||isAgent(r.m)}}
 const noVis=hasPic()&&!isVision(r.m); // note is added after pick(): picking into an empty chat redraws it
 S.lastAuto=r;
 if(!S.sel||S.sel.e!==r.e||S.sel.m!==r.m){status('Auto: switching to '+r.name+'…');await pick(r.e,r.m,true);status('')}
 if(r.e==='apple'&&(!S.sel||S.sel.e!=='apple')){ // Apple Brain didn't start: fall back once, and don't try Apple again this session
  S.appleDown=true;if(S.chat&&S.chat.lock&&S.chat.lock.e==='apple')S.chat.lock=null;
  r=appleFallback(text,'Apple did not start');S.lastAuto=r;status('Auto: switching to '+r.name+'…');await pick(r.e,r.m,true);status('')}
 if(r.e==='lfm3vl'&&(!S.sel||S.sel.e!=='lfm3vl')){ // LFM3-VL didn't start: use Bonsai (next in the picture ranking) and don't try LFM3-VL again this session
  S.lfmDown=true;if(S.chat&&S.chat.lock&&S.chat.lock.e==='lfm3vl')S.chat.lock=null;
  const v=visionRoute();r=v?{...v}:{...autoRoute(text)};r={...r,agent:!!r.agent||isAgent(r.m)};S.lastAuto=r;status('Auto: LFM3-VL did not start, switching to '+r.name+'…');await pick(r.e,r.m,true);status('')}
 if(!S.sel||S.sel.e!==r.e){return null}
 if(noVis)chatNote('No picture-capable model is available, so Photo Reader described it.');
 if(S.chat&&!S.chat.lock)S.chat.lock={e:r.e,m:r.m,name:r.name,why:r.why,agent:r.agent}; // after pick(): pick may swap in a fresh empty chat
 $('agent').checked=!!r.agent;$('cur').textContent='Auto · locked to '+r.name+' for this chat';agentUI();return r}
function showPreNote(){if(S.preNote){addMsg('assistant',S.preNote,'Instant command (no model)');S.preNote=null}}
window.__undoDone=m=>{if(!S.chat)newChat();addMsg('assistant',m)};
const UNDO_RX=/^\s*(please\s+)?undo(\s+(that|it|the\s+last(\s+(action|change|move))?|last(\s+(action|change|move))?))?\s*[.!]?\s*$/i;
async function localCommand(text){
 if(!S.chat)newChat();const ch=S.chat;
 const show=(reply,files)=>{ch.messages.push({role:'user',content:text});if(ch.messages.length===1)ch.title=text.slice(0,40);addMsg('user',text);
  const d=addMsg('assistant',reply,'Instant command (no model)');(files||[]).forEach(f=>{const r=document.createElement('div');r.className='frow';r.innerHTML='<span>'+esc(f)+'</span> ';
   [['Open','openPath'],['Reveal in Finder','revealPath']].forEach(([l,op])=>{const b=document.createElement('button');b.textContent=l;b.onclick=()=>act(op,'',{path:f});r.appendChild(b)});d.appendChild(r)});
  ch.messages.push({role:'assistant',content:reply,via:'Instant command (no model)',ts:Date.now()});saveChat(ch);return reply};
 if(UNDO_RX.test(text)){const r=await act('undoLast','');return show(r.text)}
 const pm=text.match(/^\s*(?:please\s+)?open\s+(?:the\s+(?:file|folder|document)\s+)?["'“]?([~\/][^"'”]*?)["'”]?\s*[.!]?\s*$/i);
 if(pm){const o=await act('toolRun','',{name:'open_item',args:JSON.stringify({target:pm[1]})});return show(o.text)}
 const r=await act('preroute','',{text});if(!r.handled){if(r.note){S.preNote=r.note;S.preHint=r.hint||null;S.needTools=true}return null}
 if(r.pending){const ok=await dialog('Please confirm:\n\n'+r.preview,{yes:'Approve',no:'Deny'});let msg;
  if(ok){const ap=await act('toolApply','',{pendingId:r.pendingId});msg=ap.text;show(msg+(ap.ok?'  (say "undo" to reverse it)':''))}
  else{act('toolCancelId','',{pendingId:r.pendingId});show('Cancelled. Nothing was changed.')}return 'handled'}
 return show(r.text||'Done.',r.files)}
// ---- Picture gate (Oct 27): runs before a message with a picture goes out. Never leaves a dead end at a stopped Photo Reader. ----
const PHOTO_DEAD='No model that can see pictures is available and Photo Reader is stopped. Pick a picture-capable model (LFM3-VL, Bonsai or Gemma 4) or start Photo Reader.';
const photoUp=async()=>!!(await getJSON('http://127.0.0.1:8093/v1/models',2)); // read-only look; never starts Photo Reader
async function pictureGate(cam){
 if(!hasPic()||S.busy||S.switching)return true; // busy: the normal send checks handle it
 const v=visionRoute();
 if(S.auto){ // autoSwitch picks a picture-capable model itself; only stop if nothing can see and Photo Reader is stopped too
  if(!v&&!(await photoUp())){addMsg('err',PHOTO_DEAD);return false}return true}
 if(S.sel&&isVision(S.sel.m))return true; // a picture-capable model she picked herself: keep it
 // text-only (or no) model picked: the camera button always moves to the best picture-capable model; the paperclip does too when Photo Reader is stopped
 if(v&&(cam||!S.sel||!(await photoUp()))){
  const was=S.sel?S.sel.m:null;let w=v;
  await pick(w.e,w.m);
  if((!S.sel||S.sel.m!==w.m)&&w.e==='lfm3vl'){S.lfmDown=true;const v2=visionRoute();if(v2){w=v2;await pick(w.e,w.m)}} // LFM3-VL did not start: Bonsai (next in the ranking)
  if(!S.sel||S.sel.m!==w.m)return false;
  chatNote((was?was+' can\'t see pictures, so ':'')+'switched to '+w.name+'.');return true}
 if(!v&&!(await photoUp())){addMsg('err',PHOTO_DEAD);return false}
 return true}
async function send(text){
 if(!S.chat)newChat();
 if(!S.busy&&!S.switching&&!S.att.length){const lc=await localCommand(text);if(lc!==null)return lc}
 if(!(await pictureGate(S.camSend)))return '';
 let via='';
 if(S.auto){S.chat.auto=true;if(S.busy||S.switching)return '';const r=await autoSwitch(text);if(!r){addMsg('err','Auto could not start a model. Try picking one yourself.');return ''}via=lockLabel(r)}
 else via='';
 S.via=via;
 if(!S.sel){addMsg('err','Pick a model first.');return ''}
 if(S.needTools){S.needTools=false;if(isAgent(S.sel.m)){$('agent').checked=true;agentUI()}}
 if($('agent').checked&&isAgent(S.sel.m))return sendAgent(text);
 S.busy=true;$('send').hidden=true;$('stop').hidden=false;
 if(!(await ensureEngine(S.sel.e,S.sel.m))){S.busy=false;$('send').hidden=false;$('stop').hidden=true;
  if(S.auto&&S.sel.e==='apple'&&!S.appleDown){S.appleDown=true;if(S.chat){S.chat.lock=null;S.chat.appleFailed=true}return send(text)} // Apple off: retry once on the usual model
  if(S.auto&&S.sel.e==='lfm3vl'&&!S.lfmDown){S.lfmDown=true;if(S.chat){S.chat.lock=null;S.chat.lfmFailed=true}return send(text)} // LFM3-VL off: retry once, Bonsai takes over
  addMsg('err','That engine is off and would not start.');return ''}
 const e=ENGINES.find(x=>x.id===S.sel.e);const ch=S.chat;
 ch.engine=S.sel.e;ch.model=S.sel.m;const um=await userMsg(text);ch.messages.push(um);
 if(ch.messages.length===1)ch.title=text.slice(0,40);
 saveChat(ch);const ub=addMsg('user',text,undefined,um);showPreNote();
 const out=addMsg('assistant','');out.innerHTML='<span class="think">Thinking…</span>';
 return new Promise(async resolve=>{try{
  const id=++SID;let acc='',gotAny=false,errored=false;S.cur=id;
  await loadImgs(ch.messages);let hist=ch.messages.filter(m=>m.role==='user'||m.role==='assistant').map(m=>({role:m.role,content:imgMsg(m,apiText(m))}));
  const room=roomChars(S.sel.e,S.sel.m,[]);
  if(text.length>room*0.7){out.innerHTML='<span class="think">Your message is long ('+text.length.toLocaleString()+' characters). Reading it in parts…</span>';S.stopAgent=false;
   const notes=await digest(text,'your message','Understand and answer the user\'s message; keep every instruction and question exactly',S.sel.e,S.sel.m,t=>out.firstChild.textContent=t);
   const edge=Math.min(3000,Math.floor(room*0.15));
   hist[hist.length-1]={role:'user',content:'[My message was '+text.length.toLocaleString()+' characters, more than you can hold at once, so the app read all of it in parts. Notes from every part, in order:]\n'+notes+'\n\n[Exact beginning:]\n'+text.slice(0,edge)+'\n\n[Exact ending:]\n'+text.slice(-edge)+(um.attText?'\n\n'+um.attText:'')}}
  hist=fitHistory([{role:'system',content:'You are a helpful assistant.'},...hist],S.sel.e,S.sel.m,hist.length).slice(1);
  const body={model:up(S.sel.e,S.sel.m),messages:hist,stream:true,temperature:0.7,max_tokens:maxOut(S.sel.e,S.sel.m,hist)};
  thinkOff(S.sel.e,body);
  pending[id]=ev=>{
   if(ev.type==='line'){const l=ev.text.trim();if(!l.startsWith('data:'))return;const j=l.slice(5).trim();if(j==='[DONE]')return;
     try{const o=JSON.parse(j);const dl=o.choices?.[0]?.delta||{};if(dl.content){acc+=dl.content;gotAny=true;if(!S.raf)S.raf=requestAnimationFrame(()=>{S.raf=0;if(pending[id]){out.textContent=acc;$('chat').scrollTop=1e9}})}}catch{}}
   else if(ev.type==='error'){errored=true;out.className='msg err';out.textContent=ev.text}
   else if(ev.type==='done'){delete pending[id];
     if(errored&&S.auto&&S.sel&&S.sel.e==='apple'&&ch.lock&&ch.lock.e==='apple'&&!ch.appleFailed&&!gotAny){ // Apple errored: redo this turn once on the usual model
       ch.appleFailed=true;ch.lock=null;const k=ch.messages.lastIndexOf(um);if(k>=0)ch.messages.splice(k,1);ub.remove();out.remove();S.busy=false;$('send').hidden=false;$('stop').hidden=true;
       status('Apple had a problem, trying '+appleFallback(text,'').name+'…');resolve(send(text));return}
     if(errored&&S.auto&&S.sel&&S.sel.e==='lfm3vl'&&ch.lock&&ch.lock.e==='lfm3vl'&&!ch.lfmFailed&&!gotAny&&(um.atts||[]).every(x=>x.kind==='image'&&S.imgCache[x.path])){ // LFM3-VL errored: redo this turn once on Bonsai, with the same pictures put back
       S.att=(um.atts||[]).map(x=>({...x,dataURL:S.imgCache[x.path]}));renderAtts();ch.lfmFailed=true;ch.lock=null;const k=ch.messages.lastIndexOf(um);if(k>=0)ch.messages.splice(k,1);ub.remove();out.remove();S.busy=false;$('send').hidden=false;$('stop').hidden=true;
       status('LFM3-VL had a problem, trying Bonsai…');resolve(send(text));return}
     if(!errored){if(!gotAny)out.textContent='(no answer came back)';else{const mo={role:'assistant',content:acc,via:via||undefined,ts:Date.now()};ch.messages.push(mo);if(/```/.test(acc)){out.textContent='';richText(out,acc,mo)}else out.textContent=acc;tagVia(out,via);decorate(out,mo.ts,acc);saveChat(ch)}}
     S.busy=false;$('send').hidden=false;$('stop').hidden=true;resolve(acc)}};
  window.webkit.messageHandlers.stream.postMessage({id,url:e.base+'/chat/completions',body:JSON.stringify(body)});}catch(err){out.className='msg err';out.textContent='Could not finish reading your long message: '+err.message;S.busy=false;$('send').hidden=false;$('stop').hidden=true;resolve('')}
 })}
$('form').onsubmit=ev=>{ev.preventDefault();let t=$('input').value.trim();if(S.busy||S.attLoading)return;if(!t&&S.att.length)t=S.att.some(a=>a.kind==='image')?'What is in this picture?':'Please read the attached file and tell me what it is about.';if(!t)return;$('input').value='';send(t)};
$('input').onkeydown=ev=>{if(ev.key==='Enter'&&!ev.shiftKey){ev.preventDefault();$('form').requestSubmit()}};
$('stop').onclick=()=>window.webkit.messageHandlers.stream.postMessage({id:S.cur,cmd:'cancel'});
$('delAll').onclick=async()=>{if(S.busy)return;const n=S.chats.length;if(!n){await dialog('There are no saved chats to delete.',{yes:'OK',no:'Close'});return}
 if(!(await dialog('Delete all '+n+' chat'+(n===1?'':'s')+'? They go to the Trash.',{yes:'Delete all',no:'Cancel'})))return;
 const r=await act('trashAllChats','');await loadChats();newChat();renderChats();
 if(!r.ok)addMsg('err','Moved '+r.moved+' chats to the Trash, but '+r.failed+' could not be moved.');else status('Moved '+r.moved+' chats to the Trash.');setTimeout(()=>status(''),5000)};
$('refresh').onclick=refresh;$('newChat').onclick=()=>{if(!S.busy)newChat()};
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
window.__selftest=async(mode,eid,mid)=>{
 await boot;
 if(mode==='chat'){await pick(eid,mid);const t=Date.now();const reply=await send(eid==='stoptest'?'':'Say hello in five words.');return JSON.stringify({chatId:S.chat.id,title:S.chat.title,reply,ms:Date.now()-t,saved:S.chats.length})}
 if(mode==='stop'){await pick(eid,mid);const p=send('Write a very long story about a dragon, at least 800 words.');await sleep(2500);$('stop').click();const r=await p;await sleep(300);
   return JSON.stringify({partialChars:r.length,busyAfter:S.busy,sendVisible:!$('send').hidden,stopHidden:$('stop').hidden})}
 if(mode==='reopen'){const n=S.chats.length;const c=S.chats[0];if(c)openChat(c.id);await sleep(500);
   return JSON.stringify({chatsOnDisk:n,titles:S.chats.map(x=>x.title),opened:c&&c.title,messages:c&&c.messages.length,shown:document.querySelectorAll('#chat .msg').length,model:c&&c.model,header:$('cur').textContent})}
 if(mode==='rename'){const c=S.chats[0];c.title='Renamed by test';saveChat(c);return 'ok'}
 if(mode==='delete'){const c=S.chats[S.chats.length-1];await act('trashChat','',{id:c.id});S.chats=S.chats.filter(x=>x.id!==c.id);return 'trashed '+c.title}
};
window.__selftest_auto=async(qs)=>{await boot;const out=[];
 for(const q of qs){newChat();const t=Date.now();let reply;
  const p=send(q);
  // auto-approve nothing: file tasks here are read-only questions
  reply=await p;out.push({q,picked:S.lastAuto&&S.lastAuto.name,why:S.lastAuto&&S.lastAuto.why,engine:S.sel&&S.sel.e,agent:$('agent').checked,label:(document.querySelector('#chat .msg.assistant .via')||{}).textContent||null,reply:String(reply).slice(0,160),ms:Date.now()-t})}
 return JSON.stringify(out,null,1)};
const boot=(async()=>{try{const p=await act('prefsGet','',{key:'collapsed'});if(Array.isArray(p.value))S.collapsed=new Set(p.value)}catch{}await loadChats();newChat();await refresh()})();
setInterval(()=>{if(!S.switching&&!S.busy)refresh()},6000);

// ---------- Agent mode ----------
const TOOLS=[
 ['list_folder','List the files and folders directly inside one folder. Very big folders come in pages; the result says how to get the next page.',{path:['string','Folder path. A name like Downloads is looked up inside the home folder.'],offset:['integer','Optional: start at this item number (from a MORE note).']},['path']],
 ['search_files','Find files and folders in the home folder by name. Many results come in pages; the result says how to get the next page.',{query:['string','Words to look for in the file name.'],offset:['integer','Optional: start at this result number (from a MORE note).']},['query']],
 ['list_files_by_date','List files in a folder changed within the last N days (7 = last week, 0 = today).',{folder:['string','Folder to scan, e.g. Downloads.'],days_back:['integer','How many days back.'],name_contains:['string','Optional part of the file name.']},['folder','days_back']],
 ['file_info','Show kind, size and dates for one file or folder.',{path:['string','Path inside the home folder.']},['path']],
 ['read_file_text','Read the WHOLE text of a document: plain text, Markdown, code, PDF, Word (.docx/.doc), RTF, ODT or HTML. No size limit. If the file is bigger than you can hold at once, the app reads every part for you and returns notes on each part plus the exact opening and ending. Read it once with just the path; do not page it yourself.',{path:['string','Path to a file inside the home folder.'],offset:['integer','Optional: only to jump to a later character position named in a MORE note.']},['path']],
 ['list_calendar_events','Read-only: list calendar events. range is today, tomorrow or this_week; or give start_date and end_date as YYYY-MM-DD.',{range:['string','today, tomorrow or this_week'],start_date:['string','Optional YYYY-MM-DD'],end_date:['string','Optional YYYY-MM-DD']},[]],
 ['copy_items','Prepare a copy of files or folders into a destination folder. Nothing is copied until the user approves.',{paths:['array','Paths to copy.'],destination_folder:['string','Folder to copy them into. Created if missing.']},['paths','destination_folder']],
 ['create_folder','Prepare a new folder. Nothing is created until the user approves.',{path:['string','Folder to create, e.g. Desktop/Archive.']},['path']],
 ['trash_items','Prepare moving files or folders to the Trash (never a permanent delete). Nothing moves until the user approves.',{paths:['array','Paths to move to the Trash.']},['paths']],
 ['open_item','Open a file, a folder, an app by name, or a web link, like double-clicking it. Does not change anything.',{target:['string','A path, an app name like Calendar, or a URL.']},['target']],
 ['reminders','List reminders that are not completed. Read-only.',{},[]],
 ['create_calendar_event','Prepare a new calendar event. Nothing is added until the user approves.',{title:['string','Event title.'],start:['string','Start, ISO 8601 local time, like 2026-10-14T15:00:00.'],end:['string','End, ISO 8601 local time.']},['title','start','end']],
 ['ask_photo_reader','Ask the local Photo Reader about one image file (jpg, png, heic, gif, webp, tiff). Stays on this Mac.',{path:['string','Path of the image.'],question:['string','What to ask about the image.']},['path','question']],
 ['move_items','Prepare a move of files into a destination folder. Nothing moves until the user approves.',{paths:['array','Paths to move.'],destination_folder:['string','Folder to move them into. Created if missing.']},['paths','destination_folder']],
 ['rename_item','Prepare a rename of one file. Nothing changes until the user approves.',{path:['string','File to rename.'],new_name:['string','New file name only, not a path.']},['path','new_name']],
 ['create_file','CREATE A NEW FILE and write text into it, right now. Use this whenever the user asks you to make, write, save or create a note, document, text file, Markdown file, Word document (.docx) or code file. You do the writing yourself; never tell the user how to do it. Works for .txt, .md, .docx, .rtf, .html and code files. A plain name goes on the Desktop. Will not overwrite an existing file (use edit_file for that).',{path:['string','Where to save it, with the file name and extension, e.g. Desktop/Shopping list.txt or Documents/Letter.docx.'],content:['string','The full text to put in the file.']},['path','content']],
 ['edit_file','CHANGE AN EXISTING FILE: add text to the end (append), add text at the top (prepend), replace some exact text (replace, give find + text), or rewrite the whole file (overwrite). Use this whenever the user asks you to edit, update, add to, fix or change a file. You do the editing yourself; never tell the user how. The user sees an Approve card first; a backup is kept and Undo puts the old version back. Works for .txt, .md, .docx, .rtf, .html and code files (read_file_text first if you need the exact current words).',{path:['string','The file to change.'],mode:['string','append, prepend, replace or overwrite'],text:['string','The new text (for replace: what to put instead).'],find:['string','For replace only: the exact text to find in the file.']},['path','mode','text']],
 ['pages_new_document','OPEN A NEW BLANK PAGES DOCUMENT AND TYPE TEXT INTO IT, right now. Use this whenever the user mentions Pages and wants something written in it, e.g. "open a blank Pages doc and write Test at the top". You do the typing yourself; never tell the user to type it. Optional save_path saves it as a .pages file.',{text:['string','Exactly what to type into the document. For "write Test at the top", this is: Test'],save_path:['string','Optional: where to save it, e.g. Desktop/Notes.pages. Leave out to just leave it open in Pages.']},['text']],
].map(([name,description,props,required])=>({type:'function',function:{name,description,parameters:{type:'object',properties:Object.fromEntries(Object.entries(props).map(([k,[t,d]])=>[k,t==='array'?{type:'array',items:{type:'string'},description:d}:{type:t,description:d}])),required}}}));
// Auto approve (when ON): these steps may skip the Approve dialog. Every one keeps its safety net: files are only touched inside the folders Agent mode is already allowed to use (the app refuses anything else before a dialog even exists), edits keep a backup + Undo, copy/move/rename never overwrite.
// NEVER auto-approved, even when ON: trash_items (moving to the Trash / deleting). Instant-command confirmations (typed requests like "move my screenshots...") also always ask.
const AUTO_OK=['edit_file','copy_items','create_folder','move_items','rename_item','create_calendar_event'];
const CHANGING=['move_items','rename_item','copy_items','create_folder','trash_items','create_calendar_event','edit_file'];
function sysPrompt(){return 'You are a private assistant on this Mac running in Switchboard. Nothing goes to the cloud.\nNow: '+new Date().toString()+'. Use tools for files and folders; do not invent paths or contents. If a tool fails, say so plainly. Keep replies short.\nmove_items and rename_item only prepare a preview. Nothing changes until the user approves. Never say a file was changed before the tool result says it moved. You can never permanently delete files; trash_items only moves to the Trash after the user approves. Use open_item to open a file or app, reminders for open reminders, ask_photo_reader for questions about an image, and create_calendar_event (needs approval) to add an event. For schedule questions use list_calendar_events (read-only). If the result says PERMISSION_PENDING or PERMISSION_DENIED, tell the user plainly what to do.\nYOU CAN WRITE FILES. When the user asks you to write, type, create, save or change something in a file or document, DO IT with a tool: create_file for a new text, Markdown or Word file; edit_file to change an existing file (the user approves first, Undo is available); pages_new_document to open a new Pages document and type text into it. Never answer with instructions for the user to do it themselves, and never just open an app and stop. Only say it is done after the tool result says DONE.\nWEB PAGES AND GAMES: when asked for a web page, browser game or web app, write ONE complete .html file (HTML, CSS and JavaScript together; every function you call must exist) with create_file in Documents/Switchboard Creations/, then call open_item on it: that opens it in the web browser so it runs, and the app shows the user a Play button. To fix a bug, use edit_file with mode replace on the exact broken lines; never paste the whole file back with overwrite. If the user says a page shows code instead of running, read the file with read_file_text to check it before answering.'}
function describe(n,a){const p=x=>(x||'').toString();
 return {list_folder:'Looking in '+p(a.path)+'…',search_files:'Searching for “'+p(a.query)+'”…',list_files_by_date:'Finding files in '+p(a.folder||'Desktop')+' from the last '+(a.days_back??7)+' day(s)…',file_info:'Checking '+p(a.path)+'…',read_file_text:'Reading '+p(a.path)+'…',list_calendar_events:'Checking your calendar for '+p(a.range||((a.start_date||'')+' '+(a.end_date||'')).trim()||'today')+'…',copy_items:'Preparing to copy '+(Array.isArray(a.paths)?a.paths.length:1)+' item(s) to '+p(a.destination_folder)+'…',create_folder:'Preparing a new folder '+p(a.path)+'…',trash_items:'Preparing to move '+(Array.isArray(a.paths)?a.paths.length:1)+' item(s) to the Trash…',open_item:'Opening '+p(a.target)+'…',reminders:'Checking your reminders…',create_calendar_event:'Preparing to add “'+p(a.title)+'” to your calendar…',ask_photo_reader:'Asking Photo Reader about '+p(a.path)+'…',move_items:'Preparing to move '+(Array.isArray(a.paths)?a.paths.length:1)+' item(s) to '+p(a.destination_folder)+'…',rename_item:'Preparing to rename '+p(a.path)+'…',create_file:'Creating '+p(a.path)+'…',edit_file:'Preparing to edit '+p(a.path)+' ('+p(a.mode||'append')+')…',pages_new_document:'Opening a new Pages document and typing “'+p(a.text).slice(0,60)+'”…'}[n]||'Using '+n+'…'}
function addStep(st){const c=$('chat');if(c.querySelector('.empty'))c.innerHTML='';const d=document.createElement('div');d.className='step '+(st.status||'')+(st.auto?' auto':'');
 const R=st.result?String(st.result):'';d.innerHTML=(st.auto?'<span class="autotag">'+IC('shield',13,2.4)+'Auto-approved:</span> ':'<span class="stool">'+IC('tool',15)+'</span> ')+esc(st.auto?st.text.replace(/ approved \(auto\)$/,''):st.text)+(st.auto&&st.ts?'<span class="stime">'+esc(fmtMsgTime(st.ts))+'</span>':'')+(R?(R.length>600?'<details class="res"><summary>'+esc(R.slice(0,600))+'… (show all '+R.length.toLocaleString()+' characters)</summary>'+esc(R)+'</details>':'<div class="res">'+esc(R)+'</div>'):'');
 if(st.status!=='denied'&&['create_file','edit_file','open_item'].includes(st.tool)){const wp=(st.args||{}).path||(st.args||{}).target;if(wp&&/\.html?$/i.test(wp)&&/DONE|Opened|approved/.test(String(st.result)+st.text))d.appendChild(playRow(wp))}
 if(st.undoId&&!st.undone){const b=document.createElement('button');b.textContent='Undo';b.className='undo';b.onclick=async()=>{b.disabled=true;const r=await act('undoLast','');if(r.ok)st.undone=true;d.querySelector('.res').textContent+='\n'+r.text;if(r.ok)b.remove();else b.disabled=false;if(S.chat)saveChat(S.chat)};d.appendChild(b)}
 c.appendChild(d);c.scrollTop=c.scrollHeight;return d}
function parseTextCalls(content){ // small models sometimes print the call as JSON text
 try{const t=content.trim();const o=JSON.parse(t.replace(/^```(json)?|```$/g,'').trim());const arr=Array.isArray(o)?o:o.tool_calls||[o];
  return arr.map((x,i)=>{const f=x.function||x;const n=f.name||x.tool;if(!n||!TOOLS.find(t=>t.function.name===n))return null;let a=f.arguments??f.parameters??{};return{id:'t'+i,type:'function',function:{name:n,arguments:typeof a==='string'?a:JSON.stringify(a)}}}).filter(Boolean)}catch{return[]}}
function histWithTools(msgs){const out=[];msgs.forEach((m,i)=>{
  if(m.role==='user'||m.role==='assistant'){out.push({role:m.role,content:imgMsg(m,apiText(m))});return}
  if(m.role==='step'&&m.tool&&m.result!=null){const id='h'+i;out.push({role:'assistant',content:null,tool_calls:[{id,type:'function',function:{name:m.tool,arguments:JSON.stringify(m.args||{})}}]});
   out.push({role:'tool',tool_call_id:id,name:m.tool,content:String(m.result)})}});return out}
// read_file_text without offset: get the whole file; if it does not fit the model, read it in parts (nothing skipped).
async function readWhole(a,question,api,prog){
 const r=await act('toolRun','',{name:'read_file_text',args:JSON.stringify({path:a.path})});
 if(r.total==null)return r.text||'Cannot read that file.';
 const room=roomChars(S.sel.e,S.sel.m,api);if(r.text.length<=room)return r.text;
 const body=r.text.slice(r.text.indexOf('\n')+1).replace(/\n\[END OF FILE\]$/,'');
 const notes=await digest(body,r.path,question,S.sel.e,S.sel.m,prog);
 const edge=Math.max(400,Math.min(3000,Math.floor((room-notes.length)/2)));
 const lines=body.replace(/\s+$/,'').split('\n');const first=(lines.find(l=>l.trim())||'').trim(),last=lines[lines.length-1].trim();
 return 'FILE '+r.path+': '+r.total.toLocaleString()+' characters. That is more than this model can hold at once (about '+room.toLocaleString()+' characters), so the app read ALL of it in parts. Nothing was skipped.\n\nFIRST LINE OF THE FILE (exact): '+first+'\nLAST LINE OF THE FILE (exact): '+last+'\n\nEXACT OPENING (character for character):\n'+body.slice(0,edge)+'\n\nEXACT ENDING (character for character):\n'+body.slice(-edge)+'\n\nHELPER NOTES ON EVERY PART, IN ORDER (for meaning only; their wording may be off, never quote from them):\n'+notes+'\n\n(To see the exact text of a part, call read_file_text with the start of that part as offset.)'}
// Lists that come in pages: fetch the next pages automatically while they fit; otherwise leave the MORE note so the model can ask.
async function morePages(n,a,out,api){let guard=0;
 while(guard++<1000){const mm=/MORE: call again with offset (\d+)/.exec(out);if(!mm)break;
  if(out.length>roomChars(S.sel.e,S.sel.m,api)*0.8)break;
  const nx=await act('toolRun','',{name:n,args:JSON.stringify({...a,offset:Number(mm[1])})});
  out=out.replace(/\n\[Items [^\]]*\]$/,'')+'\n'+(nx.text||'')}
 return out}
async function sendAgent(text){
 S.busy=true;$('send').hidden=true;$('stop').hidden=false;S.stopAgent=false;S.nudged=false;S.sig={};S.repeats=0;
 if(!(await ensureEngine(S.sel.e,S.sel.m))){S.busy=false;$('send').hidden=false;$('stop').hidden=true;addMsg('err','That engine is off and would not start.');return ''}
 const e=ENGINES.find(x=>x.id===S.sel.e);const ch=S.chat;ch.engine=S.sel.e;ch.model=S.sel.m;
 const um=await userMsg(text);ch.messages.push(um);if(ch.messages.length===1)ch.title=text.slice(0,40);saveChat(ch);addMsg('user',text,undefined,um);showPreNote();
 const hint=S.preHint;S.preHint=null;await loadImgs(ch.messages);const api=[{role:'system',content:sysFor(ch)+(hint?'\n\n'+hint:'')},...histWithTools(ch.messages)];const turnStart=api.length-1;
 let final='';const wait=addMsg('assistant','');wait.innerHTML='<span class="think working">Working…</span><span class="elapsed"></span>';const turnFrom=ch.messages.length;
 const t0=Date.now(),tick=setInterval(()=>{const el=wait.querySelector('.elapsed');if(el)el.textContent=' · '+Math.round((Date.now()-t0)/1000)+' s · press Stop to cancel'},1000);
 try{
  const MAXSTEP=30;const prog=t=>{wait.firstChild.textContent=t;$('chat').scrollTop=1e9};
  for(let step=0;step<MAXSTEP;step++){
   wait.firstChild.textContent='Working… (step '+(step+1)+')';$('chat').appendChild(wait);$('chat').scrollTop=1e9;
   if(S.stopAgent){final='(stopped)';break}
   const r=await netC({url:e.base+'/chat/completions',method:'POST',timeout:1800,body:S.lastBody=JSON.stringify(thinkOff(S.sel.e,{model:up(S.sel.e,S.sel.m),messages:fitHistory(api,S.sel.e,S.sel.m,turnStart),tools:toolsFor(ch),tool_choice:'auto',stream:false,temperature:0.3,max_tokens:maxOut(S.sel.e,S.sel.m,api),reasoning_effort:'none'}))});
   if(S.stopAgent||r.error==='cancelled'){final='(stopped)';break}
   if(r.status!==200){final='The model could not answer ('+(r.status||'no connection')+').';break}
   let msg;try{msg=JSON.parse(r.body).choices[0].message}catch{final='I could not read the model reply.';break}
   let calls=msg.tool_calls||[];let content=msg.content||'';
   if(!calls.length&&content){const tc=parseTextCalls(content);if(tc.length){calls=tc;content=''}}
   if(!calls.length&&!content.trim()&&step>0&&!S.nudged){S.nudged=true;api.push({role:'user',content:'(Answer my request now in plain words, using the tool results above.)'});continue} // some models (Gemma 4 on Ollama 0.30) stop with an empty reply right after a tool result
   if(!calls.length){final=content||'(no answer came back)';break}
   api.push({role:'assistant',content:content||null,tool_calls:calls});
   for(const c of calls){
    let a={};try{a=JSON.parse(c.function.arguments||'{}')}catch{}
    const n=c.function.name;const sig=n+JSON.stringify(a);S.sig[sig]=(S.sig[sig]||0)+1;
    if(S.sig[sig]>2){S.repeats++;api.push({role:'tool',tool_call_id:c.id,name:n,content:'You already ran '+n+' with exactly these arguments twice for this request. Do not repeat it. Answer the user now with what you have.'});continue} // loop guard
    const st={role:'step',tool:n,args:a,text:describe(n,a),status:'',ts:Date.now()};const el=addStep(st);
    let res,out;
    if(n==='read_file_text'&&!(Number(a.offset)>0)){out=await readWhole(a,text,api,prog);res={}}
    else if(n==='read_file_text'){res=await act('toolRun','',{name:n,args:JSON.stringify({path:a.path,offset:Number(a.offset),max_chars:Math.max(Number(a.max_chars)||0,roomChars(S.sel.e,S.sel.m,api))})});out=res.text||''}
    else{res=await act('toolRun','',{name:n,args:JSON.stringify(a)});out=res.text||'';if(res.undoId){st.undoId=res.undoId;st.status='done'}
     if(!res.pending&&n!=='read_file_text')out=await morePages(n,a,out,api)}
    if(res.pending){
      const auto=!!S.autoApprove&&AUTO_OK.includes(n)&&!!res.pendingId;
      const ok=auto||await dialog('The assistant wants to change something:\n\n'+res.preview,{yes:'Approve',no:'Deny'});
      if(ok){const ap=await act('toolApply','',{name:n,args:JSON.stringify(a),pendingId:res.pendingId||''});out=ap.text;st.status='done';st.text+=auto?' approved (auto)':' approved';if(auto){st.auto=true;st.ts=Date.now()}if(ap.undoId)st.undoId=ap.undoId}
      else{if(res.pendingId)act('toolCancelId','',{pendingId:res.pendingId});out='The user denied this action. Nothing was changed.';st.status='denied';st.text+=' denied'}}
    st.result=out;ch.messages.push(st);saveChat(ch);el.replaceWith(addStep(st));
    api.push({role:'tool',tool_call_id:c.id,name:n,content:String(out)});
   }
   if(S.repeats>=3){final='I stopped because the model kept repeating the same step. Try asking again in different words, or pick another model.';break}
   if(step===MAXSTEP-1)final='I used '+MAXSTEP+' tool steps in a row and paused so I do not loop forever. Say "continue" and I will keep going.';
  }
 }finally{
  clearInterval(tick);wait.remove();const mo={role:'assistant',content:final,via:S.via||undefined,ts:Date.now()};const wf=webFilesOf(ch.messages.slice(turnFrom));if(wf.length)mo.webFiles=wf;
  addMsg('assistant',final,S.via,mo);ch.messages.push(mo);saveChat(ch);
  S.busy=false;$('send').hidden=false;$('stop').hidden=true}
 return final}
$('stop').onclick=()=>{S.stopAgent=true;window.webkit.messageHandlers.stream.postMessage({id:S.cur,cmd:'cancel'});if(S.curRid)act('netCancel','',{rid:S.curRid});status('Stopping…');setTimeout(()=>status(''),3000)};
const _st0=window.__selftest;
window.__selftest=async(mode,eid,mid)=>{
 if(mode!=='cal')return _st0(mode,eid,mid);
 const Q=mid.split('|')[1]||"What's on my calendar today?";mid=mid.split('|')[0];
 await boot;await pick(eid,mid);$('agent').checked=true;agentUI();
 const q=send(Q);
 let sawWorking=false;for(let i=0;i<20;i++){await sleep(200);if(document.querySelector('.working'))sawWorking=true}
 const r=await q;return JSON.stringify({sawWorking,reply:r,steps:S.chat.messages.filter(m=>m.role==='step').map(m=>m.text+' -> '+String(m.result).slice(0,300))},null,1)};
const _st=window.__selftest;
window.__selftest=async(mode,eid,mid)=>{
 if(mode!=='agent')return _st(mode,eid,mid);
 const F=(mid.split('|')[1]||'Downloads');mid=mid.split('|')[0];await boot;await pick(eid,mid);$('agent').checked=true;agentUI();
 const out={note:$('agentNote').textContent};
 // 1) read-only
 let t=Date.now();out.readReply=await send('Find the files in my '+F+' folder from this week.');out.readMs=Date.now()-t;
 out.readSteps=S.chat.messages.filter(m=>m.role==='step').map(m=>m.text+' -> '+String(m.result).slice(0,150));
 // 2) approved move of a throwaway file
 newChat();t=Date.now();const p=send('Move the file '+F+'/mp-test-file.txt into a new folder '+F+'/mp-test-folder.');
 let seen=null;for(let i=0;i<300&&!seen;i++){await sleep(500);if(!$('modal').hidden)seen=$('mtext').textContent}
 out.dialogShown=seen;if(seen)$('myes').click();out.moveReply=await p;out.moveMs=Date.now()-t;
 out.moveSteps=S.chat.messages.filter(m=>m.role==='step').map(m=>m.text+' -> '+String(m.result).slice(0,150));
 // 3) denied rename
 newChat();const q=send('Rename '+F+'/mp-test-folder/mp-test-file.txt to mp-renamed.txt');
 seen=null;for(let i=0;i<300&&!seen;i++){await sleep(500);if(!$('modal').hidden)seen=$('mtext').textContent}
 out.dialog2=seen;if(seen)$('mno').click();out.denyReply=await q;
 out.denySteps=S.chat.messages.filter(m=>m.role==='step').map(m=>m.text);
 return JSON.stringify(out,null,1)};
const _st2=window.__selftest;
window.__selftest=async(mode,eid,mid)=>{if(mode!=='auto')return _st2(mode,eid,mid);return window.__selftest_auto(mid.split('||'))};
// ---- selftest: instant commands / undo, no model needed. mid = "text||approve(yes|no|none)" ----
const _st3=window.__selftest;
window.__selftest=async(mode,eid,mid)=>{
 if(mode!=='local')return _st3(mode,eid,mid);
 await boot;let steps;const outs=[];if(eid){const [mm,rest]=mid.split('@@');await pick(eid,mm);$('agent').checked=true;agentUI();steps=rest.split('##')}else steps=mid.split('##');
 for(const one of steps){const [text,ap]=one.split('||');newChat();
  const p=send(text);let seen=null,fin=false;p.then(()=>fin=true,()=>fin=true);
  for(let i=0;i<(eid?400:200)&&!seen&&!fin;i++){await sleep(250);if(!$('modal').hidden)seen=$('mtext').textContent}
  if(seen){if(ap==='no')$('mno').click();else $('myes').click()}
  const r=await p;outs.push({text,dialog:seen,reply:r,screen:[...document.querySelectorAll('#chat .msg,#chat .step')].map(x=>x.innerText.replace(/\n+/g,' | ')).join(' ## ')});
  S.chat=null}
 return JSON.stringify(outs,null,1)};

// ---------- Ported from Ask My Mac: settings, voice, Photo Reader, quick chat, suggestion chips ----------
if(window.__MINI){document.body.classList.add('mini');$('miniOpen').onclick=()=>act('openMain','');$('miniQuit').onclick=()=>act('quitApp','');
 window.__miniOpen=()=>{if(!S.busy&&S.chat&&S.chat.messages.length)newChat();$('input').focus()}}
// suggestion chips on the empty chat (same ones Ask My Mac shows)
const TRIES=[['cal','What is on my calendar today?'],['search','Find my resume'],['star','Tell me a fun fact about space'],['bulb','Help me plan a relaxed Saturday']];
const _showChat=showChat;showChat=function(){_showChat();const e=$('chat').querySelector('.empty');
 if(e){const d=document.createElement('div');d.className='tries';TRIES.forEach(([ic,t])=>{const b=document.createElement('button');b.type='button';b.className='try';b.innerHTML='<span class="ti">'+IC(ic,18)+'</span><span></span>';b.lastChild.textContent=t;
  b.onclick=()=>{const x=$('input');x.value=t;x.focus();x.setSelectionRange(t.length,t.length)};d.appendChild(b)});e.appendChild(d)}};
showChat();
// voice: click the mic to start, click again to stop. No time limit, no silence stop. Speech stays on this Mac.
let micDown=false;
let micWait=false,warnTimer=null;
// a voice warning shows for a few seconds, then clears itself (also on the next mic press, send or new chat)
function voiceWarn(t){clearTimeout(warnTimer);status(t);$('status').classList.add('warn');warnTimer=setTimeout(clearVoiceWarn,6000)}
function clearVoiceWarn(){clearTimeout(warnTimer);if($('status').classList.contains('warn')){$('status').classList.remove('warn');status('')}$('mic').title='Click to talk, click again to stop'}
window.__speech=ev=>{const m=$('mic');m.classList.toggle('on',!!ev.listening);
 if(ev.text&&(micDown||micWait||ev.listening))$('input').value=ev.text;
 if(ev.text&&micWait&&!ev.listening){micWait=false;status('')}
 if(ev.warning){m.title=ev.warning;if(micDown||micWait){micDown=false;micWait=false;voiceWarn(ev.warning)}}else if(!micDown&&!micWait)clearVoiceWarn()};
const micStart=()=>{if(S.busy||micDown)return;clearVoiceWarn();micDown=true;$('mic').title='Click to stop';status('Listening… click the mic again to stop');act('speechDown','',{draft:$('input').value})};
const micStop=()=>{if(!micDown)return;micDown=false;micWait=true;status('Finishing…');act('speechUp','');setTimeout(()=>{if(micWait){micWait=false;if(!$('status').classList.contains('warn'))status('')}},8000)};
const _nc=newChat;newChat=function(){clearVoiceWarn();return _nc()};
const _send=send;send=function(t){clearVoiceWarn();if(micDown||micWait){micDown=false;micWait=false;act('speechUp','')}return _send(t)};
// Toggle, not hold: holding a trackpad click for a whole sentence lets go early and cut the words off.
$('mic').onmousedown=e=>e.preventDefault();$('mic').onclick=e=>{e.preventDefault();micDown?micStop():micStart()};
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&micDown)micStop()});
act('speechInfo','').then(r=>{if(!r.available){$('mic').style.opacity=.35;$('mic').title=r.hint}});
// Photo Reader
// The camera button sends the picture to the best picture-capable model (same ranking as Auto, see visionRoute); Photo Reader only if none exists.
$('photo').onclick=async()=>{if(S.busy||S.switching)return;const r=await act('pickImage','');if(!r.path)return;
 const q=await dialog('Ask about this picture\n'+r.path+'\n\nWhat do you want to know?',{input:'Describe this image.',yes:'Ask'});if(!q)return;
 const a=await act('attachPath','',{path:r.path});if(!a||a.ok===false||a.err){addMsg('err',(a&&a.err)||'That picture could not be opened.');return}
 addAtt(a);S.camSend=true;try{await send(q)}finally{S.camSend=false}};
// Settings (only what applies here: model choice lives on the left, calendars and permissions here)
async function openSettings(){const b=$('sbody');$('settings').hidden=false;
 const cur=S.auto?'Auto (picks the best model for each message)':(S.sel?(ENGINES.find(x=>x.id===S.sel.e)||{}).name+' · '+S.sel.m:'none picked yet');
 const ph=await getJSON('http://127.0.0.1:8093/v1/models',2);
 let h='<h3>Engine and model</h3><div class="row">Now using: <b>'+esc(cur)+'</b></div><div class="note">Pick an engine or model on the left, or choose Auto. The fixed address for other apps is http://127.0.0.1:7777/v1.</div>'
  +'<div class="row"><label><input type="checkbox" id="sAuto" '+(S.auto?'checked':'')+'> Use Auto for new chats</label></div>'
  +'<h3>Address for other apps</h3><div class="row"><span class="addr">http://127.0.0.1:7777/v1</span><button type="button" id="sCopyAddr" class="smallcopy" title="Copy this address">'+IC('copy',14)+' Copy</button></div><div class="note">Other apps on this Mac can use this fixed address ('+(S.proxy?'running now':'off right now')+').</div>'
  +'<h3>Calendars to read</h3><div id="calBox" class="note">Checking calendar access… (if macOS asks, click Allow Full Access)</div>'
  +'<h3>Photo Reader</h3><div class="row">'+(ph?'Running on this Mac (port 8093)':'Photo Reader is stopped (only used as a last resort). Picture-capable models handle photos.')+'</div>'
  +'<h3>Voice</h3><div class="note">Click the mic button to start talking and click it again when you are done (or press Esc). There is no time limit. Words go into the box; nothing is sent until you press Send. macOS asks once for Microphone and Speech Recognition. Everything stays on this Mac.</div>'
  +'<h3>Safety</h3><div class="note">Anything that changes files or your calendar asks you first, unless <b>Auto approve</b> is ON. Then file edits and other steps (copy, move, rename, new folder, adding a calendar event) run without asking, and each one is logged in the chat. Moving to the Trash always asks. Nothing is ever permanently deleted (Trash only). Undo Last Action is in the Edit menu, the menu bar icon, or just type “undo”.</div>'
  +'<h3>Saving memory</h3><div class="note">Switchboard\'s own models (LFM3, Bonsai, Spark, Apple) stop by themselves after 15 minutes with no messages, and start again when you next use them. Osaurus, Ollama, LM Studio, Magnitude and your other apps are never stopped by this.</div>';
 b.innerHTML=h;
 $('sCopyAddr').onclick=async e=>{const b=e.currentTarget;if(await copyText('http://127.0.0.1:7777/v1')){b.innerHTML=IC('check',14)+' Copied';setTimeout(()=>{b.innerHTML=IC('copy',14)+' Copy'},1400)}};
 $('sAuto').onchange=e=>{S.auto=e.target.checked;if(S.chat){S.chat.auto=S.auto}if(S.auto)$('cur').textContent=AUTOCUR;render()};
 const cal=await act('calList','');const box=$('calBox');if(!box)return;
 if(cal.denied){box.textContent=cal.text;return}
 let c='<div class="note">Only ticked calendars are read, and new events go into a ticked calendar that allows changes.</div>';
 (cal.calendars||[]).forEach(x=>{c+='<div class="row"><label><input type="checkbox" class="cal" data-id="'+esc(x.id)+'" '+(x.on?'checked':'')+'> '+esc(x.title)+' <span class="note">'+esc(x.source)+'</span></label></div>'});
 box.className='';box.innerHTML=c;box.querySelectorAll('.cal').forEach(x=>x.onchange=()=>act('calSet','',{id:x.dataset.id,on:x.checked}))}
window.__openSettings=openSettings;$('gear').onclick=openSettings;$('sclose').onclick=()=>$('settings').hidden=true;
// ---- selftest: single tool call (no model), mic probe, settings screenshot ----
const _st4=window.__selftest;
window.__selftest=async(mode,eid,mid)=>{
 if(mode==='tool'){await boot;const [n,a]=mid.split('|');const r=await act('toolRun','',{name:n,args:a||'{}'});
  if(r.pending){const ap=await act('toolApply','',{name:n,args:a,pendingId:r.pendingId});return JSON.stringify({preview:r.preview,applied:ap},null,1)}
  return JSON.stringify(r,null,1)}
 if(mode==='mic'){await boot;const ev=[];const old=window.__speech;window.__speech=e=>{ev.push(JSON.stringify(e));old(e)};
  $('mic').click();await sleep(Number(mid)||8000);const live=$('input').value;$('mic').click();await sleep(5000);ev.push('LIVE_BEFORE_STOP '+live.split(' ').length+' words');const r={events:ev.slice(-8),mic:$('mic').title,input:$('input').value,status:$('status').textContent};await sleep(7000);r.statusAfter7s=$('status').textContent;return JSON.stringify(r,null,1)}
 if(mode==='settings'){await boot;openSettings();await sleep(2500);return $('sbody').innerText}
 return _st4(mode,eid,mid)};
const _st5=window.__selftest;
window.__selftest=async(mode,eid,mid)=>{
 if(mode==='toolpreview'){await boot;const [n,a]=mid.split('|');const r=await act('toolRun','',{name:n,args:a||'{}'});
  if(r.pendingId)await act('toolCancelId','',{pendingId:r.pendingId});return JSON.stringify({pending:!!r.pending,preview:r.preview,text:r.text},null,1)}
 if(mode==='photoui'){await boot;$('photo').click();await sleep(4000);return 'clicked'}
 return _st5(mode,eid,mid)};

const _st5b=window.__selftest;window.__selftest=async(m,e,x)=>{if(m!=='delall')return _st5b(m,e,x);await boot;const before=S.chats.length;$('delAll').click();await sleep(800);const txt=$('mtext').textContent;
 if(x==='no'){await sleep(5000);$('mno').click();await sleep(800);await loadChats();return JSON.stringify({before,dialog:txt,after:S.chats.length})}
 $('myes').click();await sleep(2000);return JSON.stringify({before,dialog:txt,after:S.chats.length,shown:document.querySelectorAll('#chats .ch').length,status:$('status').textContent})};
const _st6=window.__selftest;window.__selftest=async(m,e,x)=>{if(m==='perm'){await boot;return JSON.stringify(await act('permInfo',''))}return _st6(m,e,x)};

// ---- selftest: multi-turn chat in ONE chat. eid 'auto' => Auto; else manual pick (Agent box NOT touched). mid = "[model@@]msg1##msg2" ----
const _st7=window.__selftest;
window.__selftest=async(mode,eid,mid)=>{
 if(mode!=='convo')return _st7(mode,eid,mid);
 await boot;let msgs=mid;
 if(eid==='auto'){S.auto=true;S.chat=null;newChat()}
 else{const [mm,rest]=mid.split('@@');msgs=rest;S.chat=null;newChat();await pick(eid,mm)}
 const turns=[];
 for(const q of msgs.split('##')){const n0=S.chat.messages.length;const reply=await send(q);
  const added=S.chat.messages.slice(n0);
  turns.push({q,engine:S.sel&&S.sel.e,model:S.sel&&S.sel.m,agentBox:$('agent').checked,header:$('cur').textContent,
   label:(added.filter(m=>m.role==='assistant').pop()||{}).via||null,
   steps:added.filter(m=>m.role==='step').map(m=>m.text+' -> '+String(m.result).slice(0,120)),reply:String(reply).slice(0,500)})}
 return JSON.stringify({chatId:S.chat.id,lock:S.chat.lock||null,note:$('agentNote').textContent,turns},null,1)};

// ---- M2 (Oct 21): code shows collapsed, web pages and games get a Play button that opens them in the browser ----
function setDialogText(text){const m=$('mtext');m.innerHTML='';text=String(text);
 if(text.length<=1500){m.textContent=text;return}
 const head=document.createElement('div');head.textContent=text.slice(0,700)+' …';m.appendChild(head);
 const det=document.createElement('details');const sm=document.createElement('summary');sm.textContent='Show the full text ('+text.length.toLocaleString()+' characters)';
 const pre=document.createElement('pre');pre.textContent=text;det.append(sm,pre);m.appendChild(det)}
const isWebCode=(lang,code)=>/^(html?|xhtml|svg)$/i.test(lang)||(/^(|text)$/i.test(lang)&&/<(!doctype html|html|canvas|body)[\s>]/i.test(code));
function webFilesOf(msgs){const out=[];msgs.forEach(m=>{if(m.role!=='step'||m.status==='denied')return;
  const p=(m.args||{}).path||(m.args||{}).target;if(['create_file','edit_file','open_item'].includes(m.tool)&&p&&/\.html?$/i.test(p)&&/DONE|Opened|approved/.test(String(m.result)+m.text)&&!out.includes(p))out.push(p)});return out}
function playRow(path){const r=document.createElement('div');r.className='play';
 const b=document.createElement('button');b.type='button';b.className='playbtn';b.textContent='▶ Play / Open in browser';
 b.onclick=async()=>{const o=await act('openInBrowser','',{path});status(o.ok?'Opened in '+o.browser+'.':'Could not find '+path+'.');setTimeout(()=>status(''),4000)};
 const f=document.createElement('button');f.type='button';f.textContent='Show in Finder';f.onclick=async()=>{const o=await act('openInBrowser','',{path,dry:1});act('revealPath','',{path:(o&&o.path)||path})};
 const t=document.createElement('span');t.className='sub';t.textContent=' '+path;r.append(b,f,t);return r}
function richText(d,text,mo){const rx=/```([\w+#.-]*)[^\n]*\n([\s\S]*?)(?:```|$)/g;let last=0,m,k=0;
 while((m=rx.exec(text))){if(m.index>last){const s=document.createElement('span');s.textContent=text.slice(last,m.index);d.appendChild(s)}
  d.appendChild(codeBlock(m[1]||'',m[2],mo,k++));last=rx.lastIndex}
 if(last<text.length){const s=document.createElement('span');s.textContent=text.slice(last);d.appendChild(s)}}
function codeBlock(lang,code,mo,idx){const lines=code.split('\n').length;const box=document.createElement('div');box.className='code';
 const bar=document.createElement('div');bar.className='codebar';const lab=document.createElement('span');lab.textContent=(lang||'code')+' · '+lines.toLocaleString()+' lines';bar.appendChild(lab);
 const cp=document.createElement('button');cp.type='button';cp.title='Copy just this code';cp.innerHTML=IC('copy',13)+' Copy';cp.onclick=async()=>{if(await copyText(code)){cp.innerHTML=IC('check',13)+' Copied';setTimeout(()=>{cp.innerHTML=IC('copy',13)+' Copy'},1500)}};bar.appendChild(cp);
 if(isWebCode(lang,code)){const pb=document.createElement('button');pb.type='button';pb.className='playbtn';pb.innerHTML=IC('play',13,2.4)+' Play / Open in browser';
  pb.onclick=async()=>{mo=mo||{};mo.saved=mo.saved||{};let p=mo.saved[idx];
   if(!p){const r=await act('saveCreation','',{name:(S.chat&&S.chat.title)||'creation',html:code});if(!r.ok){status('Could not save the page.');return}p=r.path;mo.saved[idx]=p;if(S.chat&&S.chat.messages.includes(mo))saveChat(S.chat)}
   const o=await act('openInBrowser','',{path:p});status(o.ok?'Saved as '+p.replace(/^\/Users\/[^/]+/,'~')+' and opened in '+o.browser+'.':'Could not open '+p);setTimeout(()=>status(''),6000)};bar.appendChild(pb)}
 const pre=document.createElement('pre');pre.textContent=code;
 if(lines>20){const det=document.createElement('details');const sm=document.createElement('summary');sm.textContent='Show the code ('+lines.toLocaleString()+' lines)';det.append(sm,pre);box.append(bar,det)}
 else box.append(bar,pre);return box}
// ---- selftest m2: agent makes an HTML game + Play; chat-mode code block collapsed + Play; Stop during an agent request ----
const _st8=window.__selftest;
window.__selftest=async(mode,eid,mid)=>{
 if(mode!=='m2')return _st8(mode,eid,mid);await boot;const out={};
 S.chat=null;newChat();await pick(eid,mid);$('agent').checked=true;agentUI();
 let t=Date.now();out.agentReply=await send('Make me a tiny HTML browser game: a square moves around a canvas and I click it to score points. Save it and open it.');out.agentMs=Date.now()-t;
 out.agentSteps=S.chat.messages.filter(m=>m.role==='step').map(m=>m.text+' -> '+String(m.result).slice(0,140));
 out.playButtons=document.querySelectorAll('#chat .playbtn').length;
 const pb=[...document.querySelectorAll('#chat .playbtn')].pop();if(pb){pb.click();await sleep(1500);out.afterPlayStatus=$('status').textContent}
 await sleep(1500);
 S.chat=null;newChat();$('agent').checked=false;agentUI();t=Date.now();
 out.chatReplyChars=(await send('Write a complete small HTML page with a canvas where a ball bounces. Reply with just one html code block.')).length;out.chatMs=Date.now()-t;
 out.codeBlocks=document.querySelectorAll('#chat .code').length;out.collapsed=document.querySelectorAll('#chat .code details:not([open])').length;out.chatPlay=document.querySelectorAll('#chat .code .playbtn').length;
 const cb=document.querySelector('#chat .code .playbtn');if(cb){cb.click();await sleep(2000);out.chatPlayStatus=$('status').textContent}
 await sleep(800);
 S.chat=null;newChat();$('agent').checked=true;agentUI();t=Date.now();
 const p=send('Write a very long detailed essay about the history of video games, at least 3000 words, then save it as a file.');await sleep(4000);$('stop').click();out.stopReply=await p;out.stopMs=Date.now()-t;
 out.busyAfterStop=S.busy;return JSON.stringify(out,null,1)};
// ---- selftest show: open the saved chat whose title contains mid (for screenshots) ----
const _st9=window.__selftest;
window.__selftest=async(mode,eid,mid)=>{if(mode!=='show')return _st9(mode,eid,mid);await boot;const c=S.chats.find(x=>x.title.toLowerCase().includes(mid.toLowerCase()));if(c)openChat(c.id);
 await sleep(800);if(eid==='expand')document.querySelectorAll('#chat details').forEach(d=>d.open=false);$('chat').scrollTop=1e9;return JSON.stringify({opened:c&&c.title,play:document.querySelectorAll('#chat .playbtn').length})};

// ---- M3 (Oct 21): attachments. Paste (Cmd+V), drag and drop, or 📎. Pictures go to models that can see; documents are read in full. ----
S.att=[];
const isVision=m=>/gemma4|gemma-4|gemma3|llava|-vl\b|vision|minicpm-v|moondream|qwen2\.5vl|qwen3-vl|lfm3-vl|bonsai-2-(4b|9b)/i.test(m||''); // Bonsai 2 4B/9B see pictures since Oct 21 (mmproj added in start.sh)
const apiText=m=>m.attText?(m.content+'\n\n'+m.attText):m.content;
function kb(n){return n>1048576?(n/1048576).toFixed(1)+' MB':Math.max(1,Math.round(n/1024))+' KB'}
function renderAtts(){const b=$('atts');b.innerHTML='';
 S.att.forEach(a=>{const c=document.createElement('span');c.className='chip'+(a.err?' bad':'');
  if(a.kind==='image'&&a.dataURL){const i=document.createElement('img');i.src=a.dataURL;c.appendChild(i)}else c.insertAdjacentHTML('beforeend',IC(a.kind==='image'?'img':'doc',14));
  const t=document.createElement('span');t.textContent=a.name+(a.err?' (can\'t read: '+a.err+')':a.chars!=null?' · '+a.chars.toLocaleString()+' characters':a.bytes?' · '+kb(a.bytes):'');c.appendChild(t);
  const x=document.createElement('button');x.type='button';x.className='x';x.title='Remove';x.textContent='×';x.onclick=()=>{S.att=S.att.filter(y=>y!==a);renderAtts()};c.appendChild(x);b.appendChild(c)});
 if(S.attLoading){const c=document.createElement('span');c.className='chip';c.textContent='Adding…';b.appendChild(c)}
 const im=S.att.some(a=>a.kind==='image');const sel=S.auto?(S.chat&&S.chat.lock):S.sel;
 if(im&&sel&&!isVision(sel.m)){const n=document.createElement('div');n.className='attnote';n.textContent=sel.m+' can\'t see pictures, so Photo Reader (on this Mac) will describe the picture to it in words.';b.appendChild(n)}}
function addAtt(r){if(!r)return;if(r.files){r.files.forEach(addAtt);return}S.att.push({...r,id:Math.random()});renderAtts()}
const b64=f=>new Promise((res,rej)=>{const fr=new FileReader();fr.onload=()=>res(String(fr.result).split(',')[1]||'');fr.onerror=rej;fr.readAsDataURL(f)});
async function addFiles(files){S.attLoading=true;renderAtts();
 try{for(const f of files){let name=f.name||'pasted.png';if(!/\.[a-z0-9]+$/i.test(name)&&/^image\//.test(f.type))name='pasted-'+new Date().toTimeString().slice(0,8).replace(/:/g,'')+'.'+(f.type.split('/')[1]||'png');
   addAtt(await act('attachSave','',{name,b64:await b64(f)}))}}finally{S.attLoading=false;renderAtts()}}
$('clip').onclick=async()=>{if(S.busy)return;S.attLoading=true;renderAtts();try{addAtt(await act('attachPick',''))}finally{S.attLoading=false;renderAtts()}};
$('input').addEventListener('paste',ev=>{const cd=ev.clipboardData;let fs=[...(cd&&cd.files||[])];
 if(!fs.length&&cd)fs=[...cd.items].filter(i=>i.kind==='file').map(i=>i.getAsFile()).filter(Boolean);
 if(fs.length){ev.preventDefault();addFiles(fs);return}
 const types=cd?[...cd.types]:[];if(!types.includes('text/plain')||types.includes('Files')){ev.preventDefault();S.attLoading=true;renderAtts();act('attachClipboard','').then(r=>{S.attLoading=false;addAtt(r);renderAtts()},()=>{S.attLoading=false;renderAtts()})}});
// dropping a file must never navigate the app window away
['dragover','dragenter'].forEach(t=>window.addEventListener(t,e=>{e.preventDefault();document.body.classList.add('dropping')}));
window.addEventListener('dragleave',e=>{if(!e.relatedTarget)document.body.classList.remove('dropping')});
window.addEventListener('drop',e=>{e.preventDefault();document.body.classList.remove('dropping');const fs=[...(e.dataTransfer&&e.dataTransfer.files||[])];if(fs.length)addFiles(fs)});
function withImages(arr,i){if(!S.turnImages||!S.turnImages.length||!arr[i]||arr[i].role!=='user')return;
 arr[i]={role:'user',content:[{type:'text',text:String(arr[i].content)},...S.turnImages.map(u=>({type:'image_url',image_url:{url:u}}))]}}
async function userMsg(text){const m={role:'user',content:text,ts:Date.now()};const A=S.att;S.att=[];S.turnImages=[];renderAtts();if(!A.length)return m;
 m.atts=A.map(a=>({name:a.name,kind:a.kind,path:a.path,chars:a.chars}));const vis=isVision(S.sel.m);const parts=[];
 let budget=Math.floor(roomChars(S.sel.e,S.sel.m,[])*0.7)-text.length;
 for(const a of A){
  if(a.err){parts.push('[Attached file '+a.name+': it could not be read ('+a.err+'). Tell the user plainly.]');continue}
  if(a.kind==='image'){
   if(vis&&a.dataURL){S.imgCache[a.path]=a.dataURL;parts.push('[Picture attached: '+a.name+']');continue}
   status('Photo Reader is describing '+a.name+' for '+S.sel.m+'…');const r=await act('describeImage','',{path:a.path,question:'Describe this picture in detail. Copy any text in it exactly.'});status('');
   parts.push(r.ok?'[Attached picture: '+a.name+'. You cannot see pictures, so a local picture model (Photo Reader) described it for you. Say so if it matters:]\n'+r.text
     :'[Attached picture: '+a.name+'. You cannot see pictures, and Photo Reader is not running, so nobody could describe it. Tell the user plainly that this model cannot see pictures and they can pick a model marked "can see pictures" (like gemma4:e2b) or open Photo Reader.]');continue}
  const t=a.text||'';const where=a.real?' It is saved at '+a.path+'.':'';
  if(t.length<=budget){budget-=t.length;parts.push('[Attached file: '+a.name+', '+t.length.toLocaleString()+' characters, the WHOLE file.'+where+']\n'+t+'\n[END OF '+a.name+']');continue}
  S.stopAgent=false;const notes=await digest(t,a.name,text,S.sel.e,S.sel.m,x=>status(x));status('');const edge=Math.max(400,Math.min(3000,Math.floor(budget/3)));
  parts.push('[Attached file: '+a.name+', '+t.length.toLocaleString()+' characters. That is more than this model can hold at once, so the app read ALL of it in parts. Nothing was skipped.'+where+']\nEXACT OPENING:\n'+t.slice(0,edge)+'\n\nEXACT ENDING:\n'+t.slice(-edge)+'\n\nNOTES ON EVERY PART, IN ORDER:\n'+notes)}
 m.attText=parts.join('\n\n');return m}

// ---- selftest m3: paste a picture (real paste event) + attach a PDF ----
const _st10=window.__selftest;
window.__selftest=async(mode,eid,mid)=>{if(mode!=='m3')return _st10(mode,eid,mid);await boot;const out={};
 const mk=async()=>{const cv=document.createElement('canvas');cv.width=400;cv.height=200;const g=cv.getContext('2d');g.fillStyle='#ffeb3b';g.fillRect(0,0,400,200);g.fillStyle='#d32f2f';g.beginPath();g.arc(80,100,50,0,7);g.fill();g.fillStyle='#000';g.font='bold 48px Helvetica';g.fillText('HELLO 42',150,115);
  const bl=await new Promise(r=>cv.toBlob(r,'image/png'));return new File([bl],'image.png',{type:'image/png'})};
 const paste=async()=>{const f=await mk();try{const dt=new DataTransfer();dt.items.add(f);$('input').dispatchEvent(new ClipboardEvent('paste',{clipboardData:dt,bubbles:true,cancelable:true}));out.pasteEvent='ok'}catch(e){out.pasteEvent='fallback: '+e.message;await addFiles([f])}
  for(let i=0;i<40&&(S.attLoading||!S.att.length);i++)await sleep(250)};
 // 1) Auto + picture -> a model that can see
 S.auto=true;S.chat=null;newChat();await paste();out.chips1=[...document.querySelectorAll('#atts .chip')].map(c=>c.textContent);
 let t=Date.now();out.visionReply=await send('What words and shapes are in this picture?');out.visionMs=Date.now()-t;out.visionModel=S.sel&&S.sel.m;
 // 2) model that cannot see -> Photo Reader describes
 S.chat=null;newChat();await pick(eid,mid);$('agent').checked=false;agentUI();await paste();out.note2=($('atts').querySelector('.attnote')||{}).textContent||null;
 t=Date.now();out.blindReply=await send('What words are in this picture?');out.blindMs=Date.now()-t;out.blindAttText=(S.chat.messages.find(m=>m.atts)||{}).attText;
 // 3) PDF attached in full + remove x works
 S.chat=null;newChat();addAtt(await act('attachPath','',{path:'/Users/madhatter2727/Projects/model-picker/test-sandbox/docs/big-60kb.pdf'}));addAtt(await act('attachPath','',{path:'/Users/madhatter2727/Projects/model-picker/test-sandbox/docs/big-60kb.pdf'}));out.chipsBeforeRemove=S.att.length;
 document.querySelector('#atts .chip .x').click();out.chipsAfterRemove=S.att.length;out.pdfChars=S.att[0]&&S.att[0].chars;
 t=Date.now();out.pdfReply=await send('What is this document about? Also quote its very last sentence.');out.pdfMs=Date.now()-t;
 const um=S.chat.messages.find(m=>m.atts);out.pdfAttTextHead=um&&um.attText.slice(0,200);out.pdfAttTextLen=um&&um.attText.length;
 return JSON.stringify(out,null,1)};

// ---- selftest m4: collapse groups, check saved state ----
const _st11=window.__selftest;
window.__selftest=async(mode,eid,mid)=>{if(mode!=='m4')return _st11(mode,eid,mid);await boot;await sleep(500);const out={startCollapsed:[...S.collapsed]};
 if(mid==='set'){for(const id of eid.split(',')){const h=[...document.querySelectorAll('#engines .eng')].find(x=>x.textContent.includes((ENGINES.find(e=>e.id===id)||{}).name));if(h&&!S.collapsed.has(id))h.querySelector('.eh').click();await sleep(200)}}
 if(mid==='clear'){for(const id of [...S.collapsed]){const h=[...document.querySelectorAll('#engines .eng')].find(x=>x.textContent.includes((ENGINES.find(e=>e.id===id)||{}).name));if(h)h.querySelector('.eh').click();await sleep(200)}}
 out.nowCollapsed=[...S.collapsed];out.autoVisible=!!document.querySelector('#engines .eng .m');out.autoHasToggle=!!document.querySelector('#engines .eng:first-child .tog');
 out.groups=[...document.querySelectorAll('#engines .eng')].map(x=>x.querySelector('.eh').textContent.trim()+' -> '+x.querySelectorAll('.m').length+' rows');
 out.saved=(await act('prefsGet','',{key:'collapsed'})).value;return JSON.stringify(out,null,1)};

const _st12=window.__selftest;window.__selftest=async(m,e,x)=>{if(m!=='clip')return _st12(m,e,x);await boot;S.chat=null;newChat();addAtt(await act('attachClipboard',''));await sleep(300);
 return JSON.stringify({chips:[...document.querySelectorAll('#atts .chip')].map(c=>c.textContent),kinds:S.att.map(a=>a.kind),hasImage:S.att.some(a=>!!a.dataURL)})};

// ---- selftest img: attach a real photo by path (like the paperclip), ask on Auto (or a picked model), optional follow-up ----
const _st13=window.__selftest;window.__selftest=async(m,e,x)=>{if(m!=='img')return _st13(m,e,x);await boot;const [path,agent,follow]=x.split('|');const out={};
 S.chat=null;if(e==='auto'){S.auto=true;newChat()}else{const [eid,mid]=e.split('@');newChat();await pick(eid,mid);$('agent').checked=agent!=='off';agentUI()}
 addAtt(await act('attachPath','',{path}));out.chip=[...document.querySelectorAll('#atts .chip')].map(c=>c.textContent);
 let t=Date.now();out.reply=await send('What is in this picture?');out.ms=Date.now()-t;out.model=S.sel&&S.sel.m;out.agent=$('agent').checked;
 out.steps=S.chat.messages.filter(m=>m.role==='step').map(m=>m.text+' -> '+String(m.result).slice(0,100));
 out.lastBodyImages=(S.lastBody||'').split('image_url').length-1;out.lastBodyLen=(S.lastBody||'').length;
 if(follow){t=Date.now();out.followReply=await send(follow);out.followMs=Date.now()-t;out.followBodyImages=(S.lastBody||'').split('image_url').length-1}
 out.bodyImages=(S.lastBody||"").split("image_url").length-1;return JSON.stringify(out,null,1)};

// ---- Picture fix (Oct 21, 3:10 PM): vision models get the picture in EVERY request of the chat (follow-ups too), image first,
// and in agent mode they are told they can see it and are not offered ask_photo_reader (gemma4 refused to look when the
// agent prompt said pictures go through that tool). Pictures are re-read from their saved file, scaled copies only for sending. ----
S.imgCache={};
const chatHasPics=ch=>!!(ch&&ch.messages.some(m=>m.role==='user'&&(m.atts||[]).some(a=>a.kind==='image')));
const visNow=()=>!!(S.sel&&isVision(S.sel.m));
async function loadImgs(msgs){if(!visNow())return;for(const m of msgs)if(m.role==='user')for(const a of (m.atts||[]))
 if(a.kind==='image'&&a.path&&!S.imgCache[a.path]){try{const r=await act('attachPath','',{path:a.path});if(r&&r.dataURL)S.imgCache[a.path]=r.dataURL}catch{}}}
function imgMsg(m,content){if(m.role!=='user'||!visNow())return content;const urls=(m.atts||[]).filter(a=>a.kind==='image'&&S.imgCache[a.path]).map(a=>S.imgCache[a.path]);
 if(!urls.length)return content;return [...urls.map(u=>({type:'image_url',image_url:{url:u}})),{type:'text',text:String(content)}]}
function sysFor(ch){const p=sysPrompt();if(!(visNow()&&chatHasPics(ch)))return p;
 return p.replace(/,?\s*ask_photo_reader for questions about an image/,'')+'\nPICTURES: you can see pictures. When the user attaches a picture it is part of their message: look at it and answer directly from what you see. Never say you cannot see it, and never use a tool to view it.'}
function toolsFor(ch){return visNow()&&chatHasPics(ch)?TOOLS.filter(t=>t.function.name!=='ask_photo_reader'):TOOLS}

// ---- selftest "route": asks Auto which model it WOULD pick for sample requests. Starts nothing, sends nothing. ----
const _stRoute=window.__selftest;window.__selftest=async(m,e,x)=>{if(m!=='route')return _stRoute(m,e,x);await boot;const out=[];
 const long=Array.from({length:14},(_,i)=>({role:i%2?'assistant':'user',content:'We talked about the weather and weekend plans, turn '+i+'. '+'x'.repeat(420)}));
 const L={e:'apple',m:'apple-builtin',name:'Apple (built-in)',why:'plain short chat'};
 const cases=[
  {name:'short chat',text:'Hi! How are you today?'},
  {name:'short chat 2',text:'What is a good name for a golden retriever puppy?'},
  {name:'long chat history',text:'And what do you think about that?',hist:long},
  {name:'long message',text:'Tell me something nice. '.repeat(30)},
  {name:'image attached',text:'What is in this picture?',att:[{kind:'image',name:'cat.png'}]},
  {name:'file attached',text:'What is this about?',att:[{kind:'file',name:'notes.txt'}]},
  {name:'file command',text:'Open my Downloads folder and find the PDF from yesterday'},
  {name:'app command',text:'Make a new Pages document called Ideas'},
  {name:'coding ask',text:'Write a python script that renames photos'},
  {name:'long reasoning',text:'Compare the pros and cons of renting vs buying, step by step'},
  {name:'Apple-locked chat turns into coding',text:'Can you debug this javascript function?',lock:L},
  {name:'Apple-locked chat still short',text:'Thanks, and one more fun fact?',lock:L}];
 const keepChat=S.chat,keepAtt=S.att,keepDown=S.appleDown;
 try{
 for(const c of cases){S.chat={id:'route-test',messages:c.hist||[],lock:c.lock||null};S.att=c.att||[];
  let r=S.chat.lock;let moved='';if(r&&r.e==='apple'){const a=appleCheck(c.text);if(!a.ok){r=null;moved=' (moved off Apple: '+a.why+')'}}
  if(!r)r=autoRoute(c.text);const a=appleCheck(c.text);
  out.push({case:c.name,picked:r.name+moved,engine:r.e,why:r.why,appleRule:a.ok?'ok':'no: '+a.why,tokens:a.tokens||null})}
 S.appleDown=true;S.chat={id:'route-test',messages:[]};S.att=[];const r2=autoRoute('Hi! How are you today?');out.push({case:'short chat after Apple failed to start',picked:r2.name,engine:r2.e,why:r2.why});
 }finally{S.chat=keepChat;S.att=keepAtt;S.appleDown=keepDown}
 return JSON.stringify({appleInstalled:haveModel('apple'),bonsai4bInstalled:haveModel('bonsai4b'),results:out},null,1)};

// ---- Auto approve toggle (default OFF, remembered between launches) ----
function autoUI(){const on=!!S.autoApprove;$('autoAp').checked=on;$('autoBox').classList.toggle('on',on);$('autoBox').querySelector('span').textContent=on?'Auto approve ON':'Auto approve';$('autoNote').hidden=!on}
$('autoAp').onchange=()=>{S.autoApprove=$('autoAp').checked;act('prefsSet','',{key:'autoApprove',value:S.autoApprove});autoUI()};
(async()=>{try{const p=await act('prefsGet','',{key:'autoApprove'});S.autoApprove=p&&p.value===true}catch{}autoUI()})();
// selftest: copy through the real app (the caller restores the clipboard afterwards)
const _stCopy=window.__selftest;window.__selftest=async(mode,eid,mid)=>{if(mode==='sidebottom'){await boot;await new Promise(r=>setTimeout(r,2500));document.querySelector('aside').scrollTop=1e5;await new Promise(r=>setTimeout(r,600));return 'scrolled'}if(mode==='copytest'){await boot;const ok=await copyText('Switchboard copy test 123');return JSON.stringify({ok})}return _stCopy(mode,eid,mid)};

// ---------- Read a document + ask about it (Oct 29) ----------
// A PDF chip gets a "Read pages" button. Switchboard turns each page into a picture and LightOnOCR-3 (its own engine on
// port 8114, started only while reading) reads it. Progress shows in the chat; Stop keeps the pages read so far
// (reading again skips them). Afterwards questions in this chat go to LFM3 1.7B (port 8110) with the best-matching
// pages, and the answer cites page numbers. Only one of the two models is loaded at a time.
const isPdf=a=>a&&a.kind==='doc'&&/\.pdf$/i.test(a.name||'');
function docRow(f){const r=document.createElement('div');r.className='frow';r.innerHTML='<span>'+esc(f)+'</span> ';
 [['Open text','openPath'],['Show in Finder','revealPath']].forEach(([l,op])=>{const b=document.createElement('button');b.type='button';b.textContent=l;b.onclick=()=>act(op,'',{path:f});r.appendChild(b)});return r}
const _addMsgD=addMsg;addMsg=function(cls,text,via,mo){const d=_addMsgD(cls,text,via,mo);if(mo&&mo.docOpen)d.appendChild(docRow(mo.docOpen));return d};
const _renderAttsD=renderAtts;renderAtts=function(){_renderAttsD();
 [...$('atts').querySelectorAll('.chip')].forEach((c,i)=>{const a=S.att[i];if(!isPdf(a)||c.querySelector('.readpg'))return;
  const b=document.createElement('button');b.type='button';b.className='readpg';b.title='Read every page with LightOnOCR on this Mac, then ask questions about it';b.textContent='Read pages';
  b.onclick=ev=>{ev.stopPropagation();if(S.busy)return;S.att=S.att.filter(y=>y!==a);renderAtts();readDoc(a.path,a.name)};c.insertBefore(b,c.querySelector('.x'))})};
const mins=s=>s<90?Math.round(s)+' s':Math.round(s/60)+' min';
async function readDoc(path,name){
 if(S.busy||S.switching)return;if(!S.chat)newChat();const ch=S.chat;
 const st=await act('docRead','',{path});if(!st||!st.ok){addMsg('err',(st&&st.err)||'That PDF could not be read.');return}
 S.busy=true;S.docReading=true;$('send').hidden=true;$('stop').hidden=false;
 const um={role:'user',content:'Read the document "'+name+'"',ts:Date.now()};ch.messages.push(um);if(ch.messages.length===1)ch.title=('Read: '+name).slice(0,40);saveChat(ch);addMsg('user',um.content,undefined,um);
 const out=addMsg('assistant','');out.innerHTML='<span class="think working">Starting the document reader…</span>';
 let s;try{for(;;){await new Promise(r=>setTimeout(r,1000));s=await act('docStatus','');
   if(s.state==='reading'){const left=(s.last-s.current+1)*(s.avgSecs||18);out.firstChild.textContent='Reading page '+s.current+' of '+s.total+'…'+(s.avgSecs?' (about '+Math.round(s.avgSecs)+' s a page, ~'+mins(left)+' left)':'')+' Press Stop to pause; pages read so far are kept.'}
   else if(s.state==='starting')out.firstChild.textContent=s.note||'Starting the document reader…';
   else break}}
 finally{S.busy=false;S.docReading=false;$('send').hidden=false;$('stop').hidden=true}
 out.remove();const r=s.result||{};
 if(s.state==='error'&&!r.read){addMsg('err',s.note||'The document reader could not read it.');return}
 const msg=(s.state==='stopped'?'Stopped. ':'Done. ')+'Read '+(r.read||0)+' of '+(r.pages||s.total)+' pages of "'+name+'"'+(s.avgSecs?' (about '+Math.round(s.avgSecs)+' s a page)':'')+(s.failed?'. '+s.failed+' pages could not be read':'')+'. The text is saved, and you can open it below.\n\nAsk me anything about it in this chat. I\'ll answer from the pages and say which page each fact is on.'+(s.preview?'\n\nStart of the text:\n'+s.preview+(s.preview.length>=1500?' …':''):'');
 const am={role:'assistant',content:msg,via:'LightOnOCR-3 (document reader, on this Mac)',ts:Date.now(),docOpen:r.openMd};
 ch.messages.push(am);ch.doc={id:s.id,name,path,read:r.read,pages:r.pages};saveChat(ch);addMsg('assistant',msg,am.via,am)}
const _stopD=$('stop').onclick;$('stop').onclick=()=>{if(S.docReading){act('docStop','');status('Stopping after this page…');setTimeout(()=>status(''),4000);return}if(_stopD)_stopD()};
async function sendDoc(text){
 const ch=S.chat;const doc=ch.doc;
 await act('stop','ocr'); // only one of the reader and LFM3 is loaded at a time
 if(!S.sel||S.sel.e!=='lfm3text'){status('Starting LFM3 for questions about the document…');await pick('lfm3text',ALIAS.lfm3text,true);status('')}
 if(!S.sel||S.sel.e!=='lfm3text'){addMsg('err','LFM3 1.7B did not start, so I can\'t answer about the document right now.');return ''}
 ch.lock={e:'lfm3text',m:ALIAS.lfm3text,name:'LFM3 1.7B',why:'questions about '+doc.name,agent:false};
 const pr=await act('docPrompt','',{id:doc.id,question:text});if(!pr||!pr.ok){addMsg('err',(pr&&pr.err)||'Could not load the document text.');return ''}
 S.busy=true;$('send').hidden=true;$('stop').hidden=false;
 if(!(await ensureEngine('lfm3text',ALIAS.lfm3text))){S.busy=false;$('send').hidden=false;$('stop').hidden=true;addMsg('err','LFM3 1.7B would not start.');return ''}
 const um={role:'user',content:text,ts:Date.now()};ch.messages.push(um);saveChat(ch);addMsg('user',text,undefined,um);
 const prev=ch.messages.slice(0,-1).filter(m=>(m.role==='user'||m.role==='assistant')&&m.docQ).slice(-6).map(m=>({role:m.role,content:String(m.content)}));
 um.docQ=true;
 const body={model:ALIAS.lfm3text,messages:[{role:'system',content:pr.system},...prev,{role:'user',content:text}],stream:true,temperature:0.2,max_tokens:2048,chat_template_kwargs:{enable_thinking:false}};
 const out=addMsg('assistant','');out.innerHTML='<span class="think">Reading '+(pr.pages.length>8?pr.pages.length+' pages':'page'+(pr.pages.length>1?'s ':' ')+pr.pages.join(', '))+'…</span>';
 const via='LFM3 1.7B · "'+doc.name+'" · '+pr.how+(pr.pages.length<=12?' (p. '+pr.pages.join(', ')+')':'');
 return new Promise(resolve=>{const id=++SID;let acc='',err='';S.cur=id;
  pending[id]=ev=>{
   if(ev.type==='line'){const l=ev.text.trim();if(!l.startsWith('data:'))return;const j=l.slice(5).trim();if(j==='[DONE]')return;
    try{const o=JSON.parse(j);const c=o.choices?.[0]?.delta?.content;if(c){acc+=c;out.textContent=acc;$('chat').scrollTop=1e9}}catch{}}
   else if(ev.type==='error')err=ev.text;
   else if(ev.type==='done'){delete pending[id];S.busy=false;$('send').hidden=false;$('stop').hidden=true;out.remove();
    if(!acc&&err){addMsg('err',err);resolve('');return}
    const am={role:'assistant',content:acc||'(no answer)',via,ts:Date.now(),docQ:true};ch.messages.push(am);saveChat(ch);addMsg('assistant',am.content,via,am);resolve(acc)}};
  window.webkit.messageHandlers.stream.postMessage({id,url:'http://127.0.0.1:8110/v1/chat/completions',body:JSON.stringify(body)})})}
const _sendDoc0=send;send=function(t){if(S.chat&&S.chat.doc&&!S.att.length&&!S.busy&&!S.switching)return sendDoc(t);return _sendDoc0(t)};
// selftest docchip: attach a PDF (like the paperclip) and show its "Read pages" button. Reads nothing, sends nothing.
const _stDoc=window.__selftest;window.__selftest=async(m,e,x)=>{if(m!=='docchip')return _stDoc(m,e,x);await boot;S.chat=null;newChat();addAtt(await act('attachPath','',{path:x}));await sleep(800);
 return JSON.stringify({chips:[...document.querySelectorAll('#atts .chip')].map(c=>c.textContent),readButton:!!document.querySelector('#atts .readpg')})};

// ---------- Notes tab (Oct 29) ----------
// Switchboard's OWN voice notes (the Bark Voice Notes app is separate and untouched). Record -> Stop -> Underdog Bark 3.0
// Clean (Switchboard's own speech engine on port 8115, started when needed, stopped after 15 idle minutes) writes it
// down -> saved note. List, search, edit, delete (to the Trash, always asks). "Ask about my notes" goes to LFM3 1.7B (8110).
const N={notes:[],cur:null,rec:false,busy:false,timer:null};
const ndate=t=>new Date((t||0)*1000).toLocaleString([], {month:'short',day:'numeric',year:'numeric',hour:'numeric',minute:'2-digit'});
const nState=t=>{$('nState').textContent=t||''};
function notesShow(on){document.body.classList.toggle('notes',on);$('notesView').hidden=!on;if(on)notesLoad()}
$('notesBtn').onclick=()=>{if(S.busy)return;notesShow(!document.body.classList.contains('notes'))};
const _newChatN=newChat;newChat=function(){notesShow(false);return _newChatN.apply(this,arguments)};
const _openChatN=openChat;openChat=function(id){notesShow(false);return _openChatN(id)};
async function notesLoad(keepId){const r=await act('noteList','');N.notes=(r&&r.notes)||[];
 if(keepId)N.cur=N.notes.find(n=>n.id===keepId)||null;else if(N.cur)N.cur=N.notes.find(n=>n.id===N.cur.id)||null;
 notesList();notesEdit()}
function notesMatch(n,q){if(!q)return true;const h=((n.title||'')+' '+(n.text||'')).toLowerCase();return q.toLowerCase().split(/\s+/).filter(Boolean).every(w=>h.includes(w))}
function notesList(){const box=$('nList');box.innerHTML='';const q=$('nSearch').value.trim();const ns=N.notes.filter(n=>notesMatch(n,q));
 if(!N.notes.length){box.innerHTML='<div class="sm">No notes yet.</div>';return}
 if(!ns.length){box.innerHTML='<div class="sm">No notes match "'+esc(q)+'".</div>';return}
 for(const n of ns){const d=document.createElement('div');d.className='nitem'+(N.cur&&N.cur.id===n.id?' sel':'');
  d.innerHTML='<b>'+esc(n.title||'Voice note')+'</b><span class="sm">'+esc(ndate(n.created))+' · '+esc((n.text||'').slice(0,80))+'</span>';
  d.onclick=async()=>{await notesSaveIfChanged();N.cur=n;notesList();notesEdit()};box.appendChild(d)}}
$('nSearch').oninput=()=>notesList();
function notesEdit(){const e=$('nEdit');const n=N.cur;
 if(!n){e.innerHTML='<div class="nempty">'+(N.notes.length?'Pick a note on the left, or press Record for a new one.':'Press Record and say what\'s on your mind. When you press Stop, it becomes a note here.')+'</div>';return}
 e.innerHTML='<input id="nTitle" aria-label="Title"><div class="sm" id="nWhen"></div><textarea id="nText" aria-label="Note text"></textarea><div class="nrow"><button type="button" id="nSave">Save</button><button type="button" id="nOpen">Open file</button><button type="button" id="nFind">Show in Finder</button><span style="flex:1"></span><button type="button" class="ndel" id="nDel"><span class="bi" data-ic="trash" data-s="13"></span> Delete</button></div>';
 $('nTitle').value=n.title||'';$('nText').value=n.text||'';
 $('nWhen').textContent=ndate(n.created)+(n.updated&&n.updated-n.created>5?' · edited '+ndate(n.updated):'')+(n.audioSeconds?' · '+Math.round(n.audioSeconds)+' s recording':'');
 e.querySelectorAll('.bi').forEach(x=>{x.innerHTML=IC(x.dataset.ic,+x.dataset.s||18)});
 $('nSave').onclick=()=>notesSaveIfChanged(true);$('nTitle').onblur=()=>notesSaveIfChanged();$('nText').onblur=()=>notesSaveIfChanged();
 $('nOpen').onclick=()=>act('openPath','',{path:n.md});$('nFind').onclick=()=>act('revealPath','',{path:n.md});
 $('nDel').onclick=async()=>{if(!(await dialog('Delete the note "'+(n.title||'Voice note')+'"? It goes to the Trash (with its recording), so you can still get it back.')))return;
  const r=await act('noteTrash','',{id:n.id});if(!r||!r.ok){nState('Could not move that note to the Trash.');return}N.cur=null;nState('Moved to the Trash.');notesLoad()}}
async function notesSaveIfChanged(force){const n=N.cur;if(!n||!$('nTitle'))return;const t=$('nTitle').value.trim(),x=$('nText').value;
 if(!force&&t===(n.title||'')&&x===(n.text||''))return;const r=await act('noteSave','',{id:n.id,title:t,text:x});
 if(r&&r.ok){nState('Saved.');setTimeout(()=>{if($('nState').textContent==='Saved.')nState('')},2000);await notesLoad(r.id)}else nState((r&&r.err)||'Could not save.')}
$('nRec').onclick=async()=>{if(N.busy)return;
 if(!N.rec){await notesSaveIfChanged();const r=await act('noteRecStart','');if(!r||!r.ok){nState((r&&r.err)||'Could not start recording.');return}
  N.rec=true;$('nRec').classList.add('on');$('nRecTxt').textContent='Stop';nState('Listening… press Stop when you\'re done.');
  N.timer=setInterval(async()=>{const l=await act('noteRecLevel','');if(l&&l.recording){const s=Math.floor(l.secs);nState('Listening… '+Math.floor(s/60)+':'+String(s%60).padStart(2,'0')+'  (press Stop when you\'re done)')}},500);return}
 clearInterval(N.timer);N.rec=false;N.busy=true;$('nRec').classList.remove('on');$('nRecTxt').textContent='Record';$('nRec').disabled=true;
 const st=await act('noteRecStop','');if(!st||!st.ok){N.busy=false;$('nRec').disabled=false;nState('Recording failed.');return}
 if(st.secs<0.7){N.busy=false;$('nRec').disabled=false;nState('That was too short to hear anything. Try again.');return}
 nState('Writing it down with Underdog Bark (on this Mac)…');const t0=Date.now();
 const r=await act('noteFromAudio','',{path:st.path});N.busy=false;$('nRec').disabled=false;
 if(!r||!r.ok){nState((r&&r.err)||'Could not turn the recording into text. The recording is kept.');return}
 nState(r.text?'Saved a new note ('+((Date.now()-t0)/1000).toFixed(1)+' s). You can fix the title or text below.':'Saved, but no words were heard. You can type the note yourself.');
 $('nSearch').value='';await notesLoad(r.id)};
$('nAskF').onsubmit=async ev=>{ev.preventDefault();const q=$('nAsk').value.trim();if(!q||N.asking)return;await notesSaveIfChanged();
 const pr=await act('notePrompt','',{question:q});const a=$('nAns');a.hidden=false;if(!pr||!pr.ok){a.textContent=(pr&&pr.err)||'Could not read your notes.';return}
 N.asking=true;$('nAskB').disabled=true;a.textContent='Starting LFM3…';
 await act('stop','notes'); // free the speech engine's memory first
 if(!(await ensureEngine('lfm3text',ALIAS.lfm3text))){N.asking=false;$('nAskB').disabled=false;a.textContent='LFM3 1.7B would not start, so I can\'t answer right now.';return}
 a.textContent='Reading '+pr.how+'…';
 const body={model:ALIAS.lfm3text,messages:[{role:'system',content:pr.system},{role:'user',content:q}],stream:true,temperature:0.2,max_tokens:1024,chat_template_kwargs:{enable_thinking:false}};
 const via='LFM3 1.7B · '+pr.how;
 await new Promise(resolve=>{const id=++SID;let acc='',err='';
  pending[id]=ev=>{if(ev.type==='line'){const l=ev.text.trim();if(!l.startsWith('data:'))return;const j=l.slice(5).trim();if(j==='[DONE]')return;
    try{const o=JSON.parse(j);const c=o.choices?.[0]?.delta?.content;if(c){acc+=c;a.textContent=acc}}catch{}}
   else if(ev.type==='error')err=ev.text;
   else if(ev.type==='done'){delete pending[id];a.textContent=acc||err||'(no answer)';const v=document.createElement('span');v.className='via';v.textContent=via;a.appendChild(v);resolve()}};
  window.webkit.messageHandlers.stream.postMessage({id,url:'http://127.0.0.1:8110/v1/chat/completions',body:JSON.stringify(body)})});
 N.asking=false;$('nAskB').disabled=false};
// selftest notes: open the Notes tab and pick the newest note. Records nothing, sends nothing.
const _stNotes=window.__selftest;window.__selftest=async(m,e,x)=>{if(m!=='notes')return _stNotes(m,e,x);await boot;notesShow(true);await sleep(900);if(N.notes.length){N.cur=N.notes[N.notes.length>1?1:0];notesList();notesEdit()}
 if(x){$('nAsk').value=x}await sleep(500);
 const mic=await act('noteMic','');return JSON.stringify({notes:N.notes.length,titles:N.notes.map(n=>n.title),view:!$('notesView').hidden,mic:mic&&mic.status})};
