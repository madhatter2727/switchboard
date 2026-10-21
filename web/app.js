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
];
const S={collapsed:new Set(),auto:true,lastAuto:null,models:{},up:{},sel:null,startedByUs:new Set(),chat:null,chats:[],busy:false,switching:false,proxy:false};
const ALIAS={bonsai4b:'bonsai-2-4b',bonsai9b:'bonsai-2-9b',spark:'spark-x2.5-4b-mlx',bonsai27b:'bonsai-2-27b'};
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
    if(ALIAS[e.id])ids=[ALIAS[e.id]];S.models[e.id]=ids.map(m=>({id:m,label:m}))}
  else{S.up[e.id]=false;const r=await act('list',e.id);S.models[e.id]=(r.lines||[]).map(m=>({id:m,label:m}))}
 }));
 S.proxy=!!(await getJSON('http://127.0.0.1:7777/v1/models',2));
 render()}
const AUTOCUR='Auto · picks the best model for each message';
function agentUI(){if(S.auto){$('agent').disabled=true;const L=S.chat&&S.chat.lock;$('agentBox').className=L&&L.agent?'':'off';$('agent').checked=!!(L&&L.agent);
  $('agentNote').textContent=L?('Auto locked this chat to '+L.name+(L.agent?' with Agent mode (file and folder tools) on.':'.')+' Start a new chat for a fresh pick.'):'Auto picks a model on your first message, then keeps it for the whole chat.';return}
 const ok=S.sel&&isAgent(S.sel.m);$('agent').disabled=!ok;$('agentBox').className=ok?'':'off';if(!ok)$('agent').checked=false;
 $('agentNote').textContent=!S.sel?'':ok?(($('agent').checked)?'Agent mode is on: the model can look at your files. Anything that changes files asks you first. It cannot delete.':''):'Agent mode needs an agent-capable model (like Raptor). This one is chat-only.'}
$('agent').onchange=()=>{if(S.chat&&!S.auto){S.chat.agent=$('agent').checked;if(S.chat.messages.length)saveChat(S.chat)}agentUI()};
const thinkOff=(eid,body)=>{if(['bonsai4b','bonsai9b','spark','bonsai27b'].includes(eid))body.chat_template_kwargs={enable_thinking:false};if(/raptor/i.test(body.model||''))body.reasoning_effort='none';return body};
// ---- context sizes (tokens) per engine; Bonsai runs with -c 65536 -np 1, Ollama with OLLAMA_CONTEXT_LENGTH=65536 ----
function ctxFor(eid,m){m=m||'';if(eid==='ollama')return /gemma2/i.test(m)?8192:65536;if(eid==='bonsai4b'||eid==='bonsai9b')return 65536;
 if(eid==='bonsai27b'||/27b/i.test(m))return 16384;if(eid==='osaurus'||eid==='spark')return 32768;return 8192}
const tok=x=>Math.ceil((typeof x==='string'?x.length:JSON.stringify(x).replace(/data:image\/[a-z]+;base64,[A-Za-z0-9+\/=]+/g,'#'.repeat(2400)).length)/3); // a picture counts as ~800 tokens, not its base64 size
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
function render(){agentUI();
 $('proxy').innerHTML=S.proxy?'<span class="dot on" style="display:inline-block"></span> Fixed address for other apps:<br><b>http://127.0.0.1:7777/v1</b>':'<span class="dot" style="display:inline-block"></span> Fixed address (7777) is off';
 $('engines').innerHTML='';
 const ad=document.createElement('div');ad.className='eng';ad.innerHTML='<div class="eh"><span class="dot on"></span>Auto</div><div class="sub">picks the best model for each message</div>';
 const ax=document.createElement('div');ax.className='m'+(S.auto?' sel':'');ax.innerHTML='<span>Auto (recommended)</span><span class="badge agent">default</span>';ax.onclick=()=>{if(S.busy)return;S.auto=true;if(S.chat){S.chat.auto=true;S.chat.lock=null;if(S.chat.messages.length)saveChat(S.chat)}$('cur').textContent=AUTOCUR;showChat();render()};ad.appendChild(ax);$('engines').appendChild(ad);
 for(const e of ENGINES){
  const d=document.createElement('div');d.className='eng';const up=S.up[e.id];const ms=S.models[e.id]||[];
  const col=S.collapsed.has(e.id);const inUse=!S.auto&&S.sel&&S.sel.e===e.id;if(col)d.classList.add('collapsed');
  d.innerHTML=`<div class="eh" title="${col?'Show':'Hide'} these models"><button type="button" class="tog" aria-label="${col?'Expand':'Collapse'}">${col?'▸':'▾'}</button><span class="dot ${up?'on':''}"></span>${e.name}${col?`<span class="cnt">${ms.length} model${ms.length===1?'':'s'}</span>`:''}</div><div class="sub">${up?'running':'off (starts when you pick a model)'}${col&&inUse?' · in use: '+esc(S.sel.m):''}</div>`;
  d.querySelector('.eh').onclick=()=>{if(S.collapsed.has(e.id))S.collapsed.delete(e.id);else S.collapsed.add(e.id);act('prefsSet','',{key:'collapsed',value:[...S.collapsed]});render()};
  if(col){$('engines').appendChild(d);continue}
  if(!ms.length){const s=document.createElement('div');s.className='sub';s.textContent='no chat models found';d.appendChild(s)}
  for(const m of ms){const x=document.createElement('div');x.className='m'+(!S.auto&&S.sel&&S.sel.e===e.id&&S.sel.m===m.id?' sel':'');
   x.innerHTML=`<span>${esc(m.label)}</span><span class="badges">${isVision(m.id)?'<span class="badge see" title="Can see pictures you paste or attach">sees pictures</span>':''}<span class="badge ${isAgent(m.id)?'agent':'chat'}">${isAgent(m.id)?'agent-capable':'chat'}</span></span>`;
   x.onclick=()=>pick(e.id,m.id);d.appendChild(x)}
  $('engines').appendChild(d)}
 renderChats();
}
const status=t=>$('status').textContent=t||'';

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
 if(!S.chat||!S.chat.messages.length)c.innerHTML='<div class="empty">'+(S.auto?'Ready. Just type what you want. Auto picks the right model for you.':S.sel?'Ready. Say hi to '+esc(S.sel.m)+'.':'Pick a model on the left, then say hi.')+'</div>';
 else S.chat.messages.forEach(m=>m.role==='step'?addStep(m):addMsg(m.role==='user'?'user':'assistant',m.content,m.via,m));renderChats()}
function renderChats(){const box=$('chats');box.innerHTML='';
 if(!S.chats.length)box.innerHTML='<div class="sub" style="margin-left:0">No saved chats yet.</div>';
 for(const c of S.chats){const d=document.createElement('div');d.className='ch'+(S.chat&&S.chat.id===c.id?' sel':'');
  d.innerHTML=`<span class="t" title="${esc(c.model||'')}">${esc(c.title)}</span><button class="ren" title="Rename">✎</button><button class="del" title="Delete">🗑</button>`;
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
   if(!(await waitUp(e))){status('');return false}}
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
  if(!(await ensureEngine(eid,mid))){addMsg('err','Could not start '+e.name+'. Try opening it yourself once.');return}
  S.sel={e:eid,m:mid};writeState();
  if(!S.chat||S.chat.messages.length===0)newChat();
  if(!S.auto){$('cur').textContent=e.name+' · '+mid+(isAgent(mid)?'  (agent-capable)':'');
   const keep=S.chat&&S.chat.model===mid&&typeof S.chat.agent==='boolean';$('agent').checked=keep?S.chat.agent:isAgent(mid);if(S.chat)S.chat.agent=$('agent').checked}
  if(S.chat.messages.length===0){showChat()}
  S.chat.engine=eid;S.chat.model=mid;if(S.chat.messages.length)saveChat(S.chat);
  await refresh();
 }finally{S.switching=false}
}
function tagVia(d,via){if(!via)return;const v=document.createElement('div');v.className='via';v.textContent=via;d.appendChild(v)}
function addMsg(cls,text,via,mo){const c=$('chat');if(c.querySelector('.empty'))c.innerHTML='';const d=document.createElement('div');d.className='msg '+cls;
 if(cls==='assistant'&&/```/.test(text||''))richText(d,text,mo);else d.textContent=text;
 if(mo&&mo.atts&&mo.atts.length){const r=document.createElement('div');r.className='attrow';mo.atts.forEach(a=>{const c=document.createElement('span');c.className='chip';c.textContent=(a.kind==='image'?'🖼 ':'📄 ')+a.name;r.appendChild(c)});d.appendChild(r)}
 if(mo&&mo.webFiles)mo.webFiles.forEach(p=>d.appendChild(playRow(p)));tagVia(d,via);c.appendChild(d);c.scrollTop=c.scrollHeight;return d}
let SID=0;const pending={};
window.__stream=ev=>{const p=pending[ev.id];if(p)p(ev)};

// ---- Auto: simple keyword rules choose the model ----
const CODE_RX=/\b(code|coding|script|bug|debug|html|css|javascript|js|python|swift|function|program|app|game|snake|regex|compile|error in|sql|api|refactor|algorithm)\b/i;
const FILE_RX=/\b(pages|keynote|textedit|docx|txt|markdown|note|notes|file|files|folder|folders|directory|calendar|schedule|meeting|meetings|event|events|move|rename|find|search|downloads|desktop|documents|screenshot|screenshots|pdf|doc|docs|document|documents|open)\b/i;
function haveModel(eid){return (S.models[eid]||[]).length>0}
function autoRoute(text){
 if(S.att.some(a=>a.kind==='image')){if(haveModel('bonsai4b'))return {e:'bonsai4b',m:ALIAS.bonsai4b,name:'Bonsai 4B (can see pictures)',agent:false,why:'picture attached'};
  const g=(S.models.ollama||[]).find(m=>isVision(m.id));if(g)return {e:'ollama',m:g.id,name:g.id+' (can see pictures)',agent:false,why:'picture attached'}}
 const raptor=(S.models.osaurus||[]).find(m=>/raptor/i.test(m.id));
 const R={e:'osaurus',m:raptor?raptor.id:'raptor-0.6-4b-jang_6m',name:'Raptor',agent:false};
 if(CODE_RX.test(text)){
  if(haveModel('bonsai9b'))return {e:'bonsai9b',m:ALIAS.bonsai9b,name:'Bonsai 9B',agent:false,why:'coding'};
  if(haveModel('spark'))return {e:'spark',m:ALIAS.spark,name:'Spark',agent:false,why:'coding'};
  return {...R,why:'coding (no coder installed)'}}
 if(FILE_RX.test(text))return {...R,agent:true,why:'files or calendar'};
 if(haveModel('bonsai4b'))return {e:'bonsai4b',m:ALIAS.bonsai4b,name:'Bonsai 4B',agent:false,why:'quick chat'};
 return {...R,why:'quick chat'}}
async function autoSwitch(text){
 const ch=S.chat;let r=ch&&ch.lock;
 if(!r){r=autoRoute(text);r={...r,agent:!!r.agent||isAgent(r.m)}}
 S.lastAuto=r;
 if(!S.sel||S.sel.e!==r.e||S.sel.m!==r.m){status('Auto: switching to '+r.name+'…');await pick(r.e,r.m,true);status('')}
 if(!S.sel||S.sel.e!==r.e){return null}
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
  ch.messages.push({role:'assistant',content:reply,via:'Instant command (no model)'});saveChat(ch);return reply};
 if(UNDO_RX.test(text)){const r=await act('undoLast','');return show(r.text)}
 const pm=text.match(/^\s*(?:please\s+)?open\s+(?:the\s+(?:file|folder|document)\s+)?["'“]?([~\/][^"'”]*?)["'”]?\s*[.!]?\s*$/i);
 if(pm){const o=await act('toolRun','',{name:'open_item',args:JSON.stringify({target:pm[1]})});return show(o.text)}
 const r=await act('preroute','',{text});if(!r.handled){if(r.note){S.preNote=r.note;S.preHint=r.hint||null;S.needTools=true}return null}
 if(r.pending){const ok=await dialog('Please confirm:\n\n'+r.preview,{yes:'Approve',no:'Deny'});let msg;
  if(ok){const ap=await act('toolApply','',{pendingId:r.pendingId});msg=ap.text;show(msg+(ap.ok?'  (say "undo" to reverse it)':''))}
  else{act('toolCancelId','',{pendingId:r.pendingId});show('Cancelled. Nothing was changed.')}return 'handled'}
 return show(r.text||'Done.',r.files)}
async function send(text){
 if(!S.chat)newChat();
 if(!S.busy&&!S.switching&&!S.att.length){const lc=await localCommand(text);if(lc!==null)return lc}
 let via='';
 if(S.auto){S.chat.auto=true;if(S.busy||S.switching)return '';const r=await autoSwitch(text);if(!r){addMsg('err','Auto could not start a model. Try picking one yourself.');return ''}via=lockLabel(r)}
 else via='';
 S.via=via;
 if(!S.sel){addMsg('err','Pick a model first.');return ''}
 if(S.needTools){S.needTools=false;if(isAgent(S.sel.m)){$('agent').checked=true;agentUI()}}
 if($('agent').checked&&isAgent(S.sel.m))return sendAgent(text);
 S.busy=true;$('send').hidden=true;$('stop').hidden=false;
 if(!(await ensureEngine(S.sel.e,S.sel.m))){S.busy=false;$('send').hidden=false;$('stop').hidden=true;addMsg('err','That engine is off and would not start.');return ''}
 const e=ENGINES.find(x=>x.id===S.sel.e);const ch=S.chat;
 ch.engine=S.sel.e;ch.model=S.sel.m;const um=await userMsg(text);ch.messages.push(um);
 if(ch.messages.length===1)ch.title=text.slice(0,40);
 saveChat(ch);addMsg('user',text,undefined,um);showPreNote();
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
     if(!errored){if(!gotAny)out.textContent='(no answer came back)';else{const mo={role:'assistant',content:acc,via:via||undefined};ch.messages.push(mo);if(/```/.test(acc)){out.textContent='';richText(out,acc,mo)}else out.textContent=acc;tagVia(out,via);saveChat(ch)}}
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
const CHANGING=['move_items','rename_item','copy_items','create_folder','trash_items','create_calendar_event','edit_file'];
function sysPrompt(){return 'You are a private assistant on this Mac running in Switchboard. Nothing goes to the cloud.\nNow: '+new Date().toString()+'. Use tools for files and folders; do not invent paths or contents. If a tool fails, say so plainly. Keep replies short.\nmove_items and rename_item only prepare a preview. Nothing changes until the user approves. Never say a file was changed before the tool result says it moved. You can never permanently delete files; trash_items only moves to the Trash after the user approves. Use open_item to open a file or app, reminders for open reminders, ask_photo_reader for questions about an image, and create_calendar_event (needs approval) to add an event. For schedule questions use list_calendar_events (read-only). If the result says PERMISSION_PENDING or PERMISSION_DENIED, tell the user plainly what to do.\nYOU CAN WRITE FILES. When the user asks you to write, type, create, save or change something in a file or document, DO IT with a tool: create_file for a new text, Markdown or Word file; edit_file to change an existing file (the user approves first, Undo is available); pages_new_document to open a new Pages document and type text into it. Never answer with instructions for the user to do it themselves, and never just open an app and stop. Only say it is done after the tool result says DONE.\nWEB PAGES AND GAMES: when asked for a web page, browser game or web app, write ONE complete .html file (HTML, CSS and JavaScript together; every function you call must exist) with create_file in Documents/Switchboard Creations/, then call open_item on it: that opens it in the web browser so it runs, and the app shows the user a Play button. To fix a bug, use edit_file with mode replace on the exact broken lines; never paste the whole file back with overwrite. If the user says a page shows code instead of running, read the file with read_file_text to check it before answering.'}
function describe(n,a){const p=x=>(x||'').toString();
 return {list_folder:'Looking in '+p(a.path)+'…',search_files:'Searching for “'+p(a.query)+'”…',list_files_by_date:'Finding files in '+p(a.folder||'Desktop')+' from the last '+(a.days_back??7)+' day(s)…',file_info:'Checking '+p(a.path)+'…',read_file_text:'Reading '+p(a.path)+'…',list_calendar_events:'Checking your calendar for '+p(a.range||((a.start_date||'')+' '+(a.end_date||'')).trim()||'today')+'…',copy_items:'Preparing to copy '+(Array.isArray(a.paths)?a.paths.length:1)+' item(s) to '+p(a.destination_folder)+'…',create_folder:'Preparing a new folder '+p(a.path)+'…',trash_items:'Preparing to move '+(Array.isArray(a.paths)?a.paths.length:1)+' item(s) to the Trash…',open_item:'Opening '+p(a.target)+'…',reminders:'Checking your reminders…',create_calendar_event:'Preparing to add “'+p(a.title)+'” to your calendar…',ask_photo_reader:'Asking Photo Reader about '+p(a.path)+'…',move_items:'Preparing to move '+(Array.isArray(a.paths)?a.paths.length:1)+' item(s) to '+p(a.destination_folder)+'…',rename_item:'Preparing to rename '+p(a.path)+'…',create_file:'Creating '+p(a.path)+'…',edit_file:'Preparing to edit '+p(a.path)+' ('+p(a.mode||'append')+')…',pages_new_document:'Opening a new Pages document and typing “'+p(a.text).slice(0,60)+'”…'}[n]||'Using '+n+'…'}
function addStep(st){const c=$('chat');if(c.querySelector('.empty'))c.innerHTML='';const d=document.createElement('div');d.className='step '+(st.status||'');
 const R=st.result?String(st.result):'';d.innerHTML='🔧 '+esc(st.text)+(R?(R.length>600?'<details class="res"><summary>'+esc(R.slice(0,600))+'… (show all '+R.length.toLocaleString()+' characters)</summary>'+esc(R)+'</details>':'<div class="res">'+esc(R)+'</div>'):'');
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
    const st={role:'step',tool:n,args:a,text:describe(n,a),status:''};const el=addStep(st);
    let res,out;
    if(n==='read_file_text'&&!(Number(a.offset)>0)){out=await readWhole(a,text,api,prog);res={}}
    else if(n==='read_file_text'){res=await act('toolRun','',{name:n,args:JSON.stringify({path:a.path,offset:Number(a.offset),max_chars:Math.max(Number(a.max_chars)||0,roomChars(S.sel.e,S.sel.m,api))})});out=res.text||''}
    else{res=await act('toolRun','',{name:n,args:JSON.stringify(a)});out=res.text||'';if(res.undoId){st.undoId=res.undoId;st.status='done'}
     if(!res.pending&&n!=='read_file_text')out=await morePages(n,a,out,api)}
    if(res.pending){
      const ok=await dialog('The assistant wants to change something:\n\n'+res.preview,{yes:'Approve',no:'Deny'});
      if(ok){const ap=await act('toolApply','',{name:n,args:JSON.stringify(a),pendingId:res.pendingId||''});out=ap.text;st.status='done';st.text+=' approved';if(ap.undoId)st.undoId=ap.undoId}
      else{if(res.pendingId)act('toolCancelId','',{pendingId:res.pendingId});out='The user denied this action. Nothing was changed.';st.status='denied';st.text+=' denied'}}
    st.result=out;ch.messages.push(st);saveChat(ch);el.replaceWith(addStep(st));
    api.push({role:'tool',tool_call_id:c.id,name:n,content:String(out)});
   }
   if(S.repeats>=3){final='I stopped because the model kept repeating the same step. Try asking again in different words, or pick another model.';break}
   if(step===MAXSTEP-1)final='I used '+MAXSTEP+' tool steps in a row and paused so I do not loop forever. Say "continue" and I will keep going.';
  }
 }finally{
  clearInterval(tick);wait.remove();const mo={role:'assistant',content:final,via:S.via||undefined};const wf=webFilesOf(ch.messages.slice(turnFrom));if(wf.length)mo.webFiles=wf;
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
const CHIPS=['Find my resume','What is on my calendar today?','Move last week\u2019s screenshots to an Archive folder','Open the PDF about\u2026'];
const _showChat=showChat;showChat=function(){_showChat();const e=$('chat').querySelector('.empty');
 if(e){const d=document.createElement('div');d.className='chips';CHIPS.forEach(t=>{const b=document.createElement('button');b.type='button';b.textContent=t;
  b.onclick=()=>{const x=$('input');if(t.endsWith('\u2026')){x.value='Open the PDF about ';x.focus()}else{x.value=t.replace('\u2019',"'");$('form').requestSubmit()}};d.appendChild(b)});e.appendChild(d)}};
showChat();
// voice: hold the mic button, speech stays on this Mac
let micDown=false;
let micWait=false,warnTimer=null;
// a voice warning shows for a few seconds, then clears itself (also on the next mic press, send or new chat)
function voiceWarn(t){clearTimeout(warnTimer);status(t);$('status').classList.add('warn');warnTimer=setTimeout(clearVoiceWarn,6000)}
function clearVoiceWarn(){clearTimeout(warnTimer);if($('status').classList.contains('warn')){$('status').classList.remove('warn');status('')}$('mic').title='Hold to talk'}
window.__speech=ev=>{const m=$('mic');m.classList.toggle('on',!!ev.listening);
 if(ev.text&&(micDown||micWait||ev.listening))$('input').value=ev.text;
 if(ev.text&&micWait&&!ev.listening){micWait=false;status('')}
 if(ev.warning){m.title=ev.warning;if(micDown||micWait){micDown=false;micWait=false;voiceWarn(ev.warning)}}else if(!micDown&&!micWait)clearVoiceWarn()};
const micStart=()=>{if(S.busy)return;clearVoiceWarn();micDown=true;status('Listening… release to stop');act('speechDown','',{draft:$('input').value})};
const micStop=()=>{if(!micDown)return;micDown=false;micWait=true;status('Finishing…');act('speechUp','');setTimeout(()=>{if(micWait){micWait=false;if(!$('status').classList.contains('warn'))status('')}},8000)};
const _nc=newChat;newChat=function(){clearVoiceWarn();return _nc()};
const _send=send;send=function(t){clearVoiceWarn();return _send(t)};
$('mic').onmousedown=micStart;window.addEventListener('mouseup',micStop);$('mic').onmouseleave=()=>{};
act('speechInfo','').then(r=>{if(!r.available){$('mic').style.opacity=.35;$('mic').title=r.hint}});
// Photo Reader
$('photo').onclick=async()=>{if(S.busy)return;const r=await act('pickImage','');if(!r.path)return;
 const q=await dialog('Ask Photo Reader about\n'+r.path+'\n\nWhat do you want to know?',{input:'Describe this image.',yes:'Ask'});if(!q)return;
 if(!S.chat)newChat();const ch=S.chat;ch.messages.push({role:'user',content:'[Photo] '+q+'  ('+r.path+')'});if(ch.messages.length===1)ch.title='Photo: '+q.slice(0,30);addMsg('user','[Photo] '+q+'  ('+r.path+')');
 const st={role:'step',tool:'ask_photo_reader',args:{path:r.path,question:q},text:'Asking Photo Reader about '+r.path+'…',status:''};const el=addStep(st);
 const res=await act('toolRun','',{name:'ask_photo_reader',args:JSON.stringify(st.args)});st.result=res.text;st.status='done';el.replaceWith(addStep(st));ch.messages.push(st);
 const ans=(res.text||'').split('\n').slice(1).join('\n')||res.text;ch.messages.push({role:'assistant',content:ans,via:'Photo Reader'});addMsg('assistant',ans,'Photo Reader');saveChat(ch)};
// Settings (only what applies here: model choice lives on the left, calendars and permissions here)
async function openSettings(){const b=$('sbody');$('settings').hidden=false;
 const cur=S.auto?'Auto (picks the best model for each message)':(S.sel?(ENGINES.find(x=>x.id===S.sel.e)||{}).name+' · '+S.sel.m:'none picked yet');
 const ph=await getJSON('http://127.0.0.1:8093/v1/models',2);
 let h='<h3>Engine and model</h3><div class="row">Now using: <b>'+esc(cur)+'</b></div><div class="note">Pick an engine or model on the left, or choose Auto. The fixed address for other apps is http://127.0.0.1:7777/v1.</div>'
  +'<div class="row"><label><input type="checkbox" id="sAuto" '+(S.auto?'checked':'')+'> Use Auto for new chats</label></div>'
  +'<h3>Calendars to read</h3><div id="calBox" class="note">Checking calendar access… (if macOS asks, click Allow Full Access)</div>'
  +'<h3>Photo Reader</h3><div class="row">'+(ph?'Running on this Mac (port 8093)':'Not running. Open Photo Reader first, then use the 📷 button.')+'</div>'
  +'<h3>Voice</h3><div class="note">Hold the 🎙 button to talk. macOS asks once for Microphone and Speech Recognition. Everything stays on this Mac.</div>'
  +'<h3>Safety</h3><div class="note">Anything that changes files or your calendar asks you first. Nothing is ever permanently deleted (Trash only). Undo Last Action is in the Edit menu, the menu bar icon, or just type “undo”.</div>';
 b.innerHTML=h;
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
  micStart();await sleep(Number(mid)||8000);micStop();await sleep(5000);const r={events:ev.slice(-8),mic:$('mic').title,input:$('input').value,status:$('status').textContent};await sleep(7000);r.statusAfter7s=$('status').textContent;return JSON.stringify(r,null,1)}
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
 const cp=document.createElement('button');cp.type='button';cp.textContent='Copy';cp.onclick=()=>{navigator.clipboard.writeText(code).then(()=>{cp.textContent='Copied';setTimeout(()=>cp.textContent='Copy',1500)},()=>{})};bar.appendChild(cp);
 if(isWebCode(lang,code)){const pb=document.createElement('button');pb.type='button';pb.className='playbtn';pb.textContent='▶ Play / Open in browser';
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
const isVision=m=>/gemma4|gemma-4|gemma3|llava|-vl\b|vision|minicpm-v|moondream|qwen2\.5vl|qwen3-vl|bonsai-2-(4b|9b)/i.test(m||''); // Bonsai 2 4B/9B see pictures since Oct 21 (mmproj added in start.sh)
const apiText=m=>m.attText?(m.content+'\n\n'+m.attText):m.content;
function kb(n){return n>1048576?(n/1048576).toFixed(1)+' MB':Math.max(1,Math.round(n/1024))+' KB'}
function renderAtts(){const b=$('atts');b.innerHTML='';
 S.att.forEach(a=>{const c=document.createElement('span');c.className='chip'+(a.err?' bad':'');
  if(a.kind==='image'&&a.dataURL){const i=document.createElement('img');i.src=a.dataURL;c.appendChild(i)}else c.append(a.kind==='image'?'🖼 ':'📄 ');
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
async function userMsg(text){const m={role:'user',content:text};const A=S.att;S.att=[];S.turnImages=[];renderAtts();if(!A.length)return m;
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
