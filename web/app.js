const $=id=>document.getElementById(id);
const nativeNet=(o)=>window.webkit.messageHandlers.net.postMessage(o);
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
const S={auto:true,lastAuto:null,models:{},up:{},sel:null,startedByUs:new Set(),chat:null,chats:[],busy:false,switching:false,proxy:false};
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
function lockLabel(L){return 'Auto picked '+L.name+' ('+L.why+') · locked for this chat'}
function render(){agentUI();
 $('proxy').innerHTML=S.proxy?'<span class="dot on" style="display:inline-block"></span> Fixed address for other apps:<br><b>http://127.0.0.1:7777/v1</b>':'<span class="dot" style="display:inline-block"></span> Fixed address (7777) is off';
 $('engines').innerHTML='';
 const ad=document.createElement('div');ad.className='eng';ad.innerHTML='<div class="eh"><span class="dot on"></span>Auto</div><div class="sub">picks the best model for each message</div>';
 const ax=document.createElement('div');ax.className='m'+(S.auto?' sel':'');ax.innerHTML='<span>Auto (recommended)</span><span class="badge agent">default</span>';ax.onclick=()=>{if(S.busy)return;S.auto=true;if(S.chat){S.chat.auto=true;S.chat.lock=null;if(S.chat.messages.length)saveChat(S.chat)}$('cur').textContent=AUTOCUR;showChat();render()};ad.appendChild(ax);$('engines').appendChild(ad);
 for(const e of ENGINES){
  const d=document.createElement('div');d.className='eng';const up=S.up[e.id];const ms=S.models[e.id]||[];
  d.innerHTML=`<div class="eh"><span class="dot ${up?'on':''}"></span>${e.name}</div><div class="sub">${up?'running':'off (starts when you pick a model)'}</div>`;
  if(!ms.length){const s=document.createElement('div');s.className='sub';s.textContent='no chat models found';d.appendChild(s)}
  for(const m of ms){const x=document.createElement('div');x.className='m'+(!S.auto&&S.sel&&S.sel.e===e.id&&S.sel.m===m.id?' sel':'');
   x.innerHTML=`<span>${esc(m.label)}</span><span class="badge ${isAgent(m.id)?'agent':'chat'}">${isAgent(m.id)?'agent-capable':'chat'}</span>`;
   x.onclick=()=>pick(e.id,m.id);d.appendChild(x)}
  $('engines').appendChild(d)}
 renderChats();
}
const status=t=>$('status').textContent=t||'';

// ---- in-page dialogs (WKWebView has no confirm/prompt) ----
function dialog(text,{input=null,yes='OK',no='Cancel'}={}){return new Promise(res=>{
 $('myes').textContent=yes;$('mno').textContent=no;
 $('mtext').textContent=text;const mi=$('minput');mi.hidden=input===null;if(input!==null)mi.value=input;$('modal').hidden=false;
 if(input!==null)mi.focus();
 const done=v=>{$('modal').hidden=true;res(v)};
 $('myes').onclick=()=>done(input===null?true:mi.value);$('mno').onclick=()=>done(null);
 mi.onkeydown=e=>{if(e.key==='Enter')$('myes').click()}})}

// ---- chat history (saved to ~/Library/Application Support/Model Picker/chats) ----
async function loadChats(){const r=await act('listChats','');S.chats=(r.chats||[]).map(t=>{try{return JSON.parse(t)}catch{return null}}).filter(Boolean).sort((a,b)=>b.updated-a.updated)}
function saveChat(c){c.updated=Date.now();act('saveChat','',{id:c.id,json:JSON.stringify(c)});
 if(!S.chats.find(x=>x.id===c.id))S.chats.unshift(c);S.chats.sort((a,b)=>b.updated-a.updated);renderChats()}
function newChat(){S.chat={id:'c'+Date.now().toString(36)+Math.random().toString(36).slice(2,6),title:'New chat',created:Date.now(),updated:Date.now(),engine:S.sel?.e||null,model:S.sel?.m||null,auto:S.auto,lock:null,agent:S.sel?isAgent(S.sel.m):undefined,messages:[],saved:false};if(S.auto)$('cur').textContent=AUTOCUR;if(!S.auto&&S.sel)$('agent').checked=isAgent(S.sel.m);showChat();agentUI()}
function showChat(){const c=$('chat');c.innerHTML='';
 if(!S.chat||!S.chat.messages.length)c.innerHTML='<div class="empty">'+(S.auto?'Ready. Just type what you want. Auto picks the right model for you.':S.sel?'Ready. Say hi to '+esc(S.sel.m)+'.':'Pick a model on the left, then say hi.')+'</div>';
 else S.chat.messages.forEach(m=>m.role==='step'?addStep(m):addMsg(m.role==='user'?'user':'assistant',m.content,m.via));renderChats()}
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
function addMsg(cls,text,via){const c=$('chat');if(c.querySelector('.empty'))c.innerHTML='';const d=document.createElement('div');d.className='msg '+cls;d.textContent=text;tagVia(d,via);c.appendChild(d);c.scrollTop=c.scrollHeight;return d}
let SID=0;const pending={};
window.__stream=ev=>{const p=pending[ev.id];if(p)p(ev)};

// ---- Auto: simple keyword rules choose the model ----
const CODE_RX=/\b(code|coding|script|bug|debug|html|css|javascript|js|python|swift|function|program|app|game|snake|regex|compile|error in|sql|api|refactor|algorithm)\b/i;
const FILE_RX=/\b(file|files|folder|folders|directory|calendar|schedule|meeting|meetings|event|events|move|rename|find|search|downloads|desktop|documents|screenshot|screenshots|pdf)\b/i;
function haveModel(eid){return (S.models[eid]||[]).length>0}
function autoRoute(text){
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
 const r=await act('preroute','',{text});if(!r.handled)return null;
 if(r.pending){const ok=await dialog('Please confirm:\n\n'+r.preview,{yes:'Approve',no:'Deny'});let msg;
  if(ok){const ap=await act('toolApply','',{pendingId:r.pendingId});msg=ap.text;show(msg+(ap.ok?'  (say "undo" to reverse it)':''))}
  else{act('toolCancelId','',{pendingId:r.pendingId});show('Cancelled. Nothing was changed.')}return 'handled'}
 return show(r.text||'Done.',r.files)}
async function send(text){
 if(!S.chat)newChat();
 if(!S.busy&&!S.switching){const lc=await localCommand(text);if(lc!==null)return lc}
 let via='';
 if(S.auto){S.chat.auto=true;if(S.busy||S.switching)return '';const r=await autoSwitch(text);if(!r){addMsg('err','Auto could not start a model. Try picking one yourself.');return ''}via=lockLabel(r)}
 else via='';
 S.via=via;
 if(!S.sel){addMsg('err','Pick a model first.');return ''}
 if($('agent').checked&&isAgent(S.sel.m))return sendAgent(text);
 S.busy=true;$('send').hidden=true;$('stop').hidden=false;
 if(!(await ensureEngine(S.sel.e,S.sel.m))){S.busy=false;$('send').hidden=false;$('stop').hidden=true;addMsg('err','That engine is off and would not start.');return ''}
 const e=ENGINES.find(x=>x.id===S.sel.e);const ch=S.chat;
 ch.engine=S.sel.e;ch.model=S.sel.m;ch.messages.push({role:'user',content:text});
 if(ch.messages.length===1)ch.title=text.slice(0,40);
 saveChat(ch);addMsg('user',text);
 const out=addMsg('assistant','');out.innerHTML='<span class="think">Thinking…</span>';
 return new Promise(resolve=>{
  const id=++SID;let acc='',gotAny=false,errored=false;S.cur=id;
  const body={model:up(S.sel.e,S.sel.m),messages:ch.messages.filter(m=>m.role==='user'||m.role==='assistant').map(m=>({role:m.role,content:m.content})),stream:true,temperature:0.7};
  thinkOff(S.sel.e,body);
  pending[id]=ev=>{
   if(ev.type==='line'){const l=ev.text.trim();if(!l.startsWith('data:'))return;const j=l.slice(5).trim();if(j==='[DONE]')return;
     try{const o=JSON.parse(j);const dl=o.choices?.[0]?.delta||{};if(dl.content){acc+=dl.content;out.textContent=acc;gotAny=true;$('chat').scrollTop=1e9}}catch{}}
   else if(ev.type==='error'){errored=true;out.className='msg err';out.textContent=ev.text}
   else if(ev.type==='done'){delete pending[id];
     if(!errored){if(!gotAny)out.textContent='(no answer came back)';else{tagVia(out,via);ch.messages.push({role:'assistant',content:acc,via:via||undefined});saveChat(ch)}}
     S.busy=false;$('send').hidden=false;$('stop').hidden=true;resolve(acc)}};
  window.webkit.messageHandlers.stream.postMessage({id,url:e.base+'/chat/completions',body:JSON.stringify(body)});
 })}
$('form').onsubmit=ev=>{ev.preventDefault();const t=$('input').value.trim();if(!t||S.busy)return;$('input').value='';send(t)};
$('input').onkeydown=ev=>{if(ev.key==='Enter'&&!ev.shiftKey){ev.preventDefault();$('form').requestSubmit()}};
$('stop').onclick=()=>window.webkit.messageHandlers.stream.postMessage({id:S.cur,cmd:'cancel'});
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
const boot=(async()=>{await loadChats();newChat();await refresh()})();
setInterval(()=>{if(!S.switching&&!S.busy)refresh()},6000);

// ---------- Agent mode ----------
const TOOLS=[
 ['list_folder','List the files and folders directly inside one folder.',{path:['string','Folder path. A name like Downloads is looked up inside the home folder.']},['path']],
 ['search_files','Find files and folders in the home folder by name. Returns up to 15 paths.',{query:['string','Words to look for in the file name.']},['query']],
 ['list_files_by_date','List files in a folder changed within the last N days (7 = last week, 0 = today).',{folder:['string','Folder to scan, e.g. Downloads.'],days_back:['integer','How many days back.'],name_contains:['string','Optional part of the file name.']},['folder','days_back']],
 ['file_info','Show kind, size and dates for one file or folder.',{path:['string','Path inside the home folder.']},['path']],
 ['read_file_text','Read the text of a plain text file (first 4000 characters).',{path:['string','Path to a file inside the home folder.']},['path']],
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
].map(([name,description,props,required])=>({type:'function',function:{name,description,parameters:{type:'object',properties:Object.fromEntries(Object.entries(props).map(([k,[t,d]])=>[k,t==='array'?{type:'array',items:{type:'string'},description:d}:{type:t,description:d}])),required}}}));
const CHANGING=['move_items','rename_item','copy_items','create_folder','trash_items','create_calendar_event'];
function sysPrompt(){return 'You are a private assistant on this Mac running in Model Picker. Nothing goes to the cloud.\nNow: '+new Date().toString()+'. Use tools for files and folders; do not invent paths or contents. If a tool fails, say so plainly. Keep replies short.\nmove_items and rename_item only prepare a preview. Nothing changes until the user approves. Never say a file was changed before the tool result says it moved. You can never permanently delete files; trash_items only moves to the Trash after the user approves. Use open_item to open a file or app, reminders for open reminders, ask_photo_reader for questions about an image, and create_calendar_event (needs approval) to add an event. For schedule questions use list_calendar_events (read-only). If the result says PERMISSION_PENDING or PERMISSION_DENIED, tell the user plainly what to do.'}
function describe(n,a){const p=x=>(x||'').toString();
 return {list_folder:'Looking in '+p(a.path)+'…',search_files:'Searching for “'+p(a.query)+'”…',list_files_by_date:'Finding files in '+p(a.folder||'Desktop')+' from the last '+(a.days_back??7)+' day(s)…',file_info:'Checking '+p(a.path)+'…',read_file_text:'Reading '+p(a.path)+'…',list_calendar_events:'Checking your calendar for '+p(a.range||((a.start_date||'')+' '+(a.end_date||'')).trim()||'today')+'…',copy_items:'Preparing to copy '+(Array.isArray(a.paths)?a.paths.length:1)+' item(s) to '+p(a.destination_folder)+'…',create_folder:'Preparing a new folder '+p(a.path)+'…',trash_items:'Preparing to move '+(Array.isArray(a.paths)?a.paths.length:1)+' item(s) to the Trash…',open_item:'Opening '+p(a.target)+'…',reminders:'Checking your reminders…',create_calendar_event:'Preparing to add “'+p(a.title)+'” to your calendar…',ask_photo_reader:'Asking Photo Reader about '+p(a.path)+'…',move_items:'Preparing to move '+(Array.isArray(a.paths)?a.paths.length:1)+' item(s) to '+p(a.destination_folder)+'…',rename_item:'Preparing to rename '+p(a.path)+'…'}[n]||'Using '+n+'…'}
function addStep(st){const c=$('chat');if(c.querySelector('.empty'))c.innerHTML='';const d=document.createElement('div');d.className='step '+(st.status||'');
 d.innerHTML='🔧 '+esc(st.text)+(st.result?'<div class="res">'+esc(String(st.result).slice(0,600))+'</div>':'');
 if(st.undoId&&!st.undone){const b=document.createElement('button');b.textContent='Undo';b.className='undo';b.onclick=async()=>{b.disabled=true;const r=await act('undoLast','');if(r.ok)st.undone=true;d.querySelector('.res').textContent+='\n'+r.text;if(r.ok)b.remove();else b.disabled=false;if(S.chat)saveChat(S.chat)};d.appendChild(b)}
 c.appendChild(d);c.scrollTop=c.scrollHeight;return d}
function parseTextCalls(content){ // small models sometimes print the call as JSON text
 try{const t=content.trim();const o=JSON.parse(t.replace(/^```(json)?|```$/g,'').trim());const arr=Array.isArray(o)?o:o.tool_calls||[o];
  return arr.map((x,i)=>{const f=x.function||x;const n=f.name||x.tool;if(!n||!TOOLS.find(t=>t.function.name===n))return null;let a=f.arguments??f.parameters??{};return{id:'t'+i,type:'function',function:{name:n,arguments:typeof a==='string'?a:JSON.stringify(a)}}}).filter(Boolean)}catch{return[]}}
function histWithTools(msgs){const out=[];msgs.forEach((m,i)=>{
  if(m.role==='user'||m.role==='assistant'){out.push({role:m.role,content:m.content});return}
  if(m.role==='step'&&m.tool&&m.result!=null){const id='h'+i;out.push({role:'assistant',content:null,tool_calls:[{id,type:'function',function:{name:m.tool,arguments:JSON.stringify(m.args||{})}}]});
   out.push({role:'tool',tool_call_id:id,name:m.tool,content:String(m.result).slice(0,4000)})}});return out}
async function sendAgent(text){
 S.busy=true;$('send').hidden=true;$('stop').hidden=false;S.stopAgent=false;S.nudged=false;
 if(!(await ensureEngine(S.sel.e,S.sel.m))){S.busy=false;$('send').hidden=false;$('stop').hidden=true;addMsg('err','That engine is off and would not start.');return ''}
 const e=ENGINES.find(x=>x.id===S.sel.e);const ch=S.chat;ch.engine=S.sel.e;ch.model=S.sel.m;
 ch.messages.push({role:'user',content:text});if(ch.messages.length===1)ch.title=text.slice(0,40);saveChat(ch);addMsg('user',text);
 const api=[{role:'system',content:sysPrompt()},...histWithTools(ch.messages)];
 let final='';const wait=addMsg('assistant','');wait.innerHTML='<span class="think working">Working…</span>';
 try{
  for(let step=0;step<8;step++){
   wait.firstChild.textContent='Working… (step '+(step+1)+' of up to 8)';$('chat').appendChild(wait);$('chat').scrollTop=1e9;
   if(S.stopAgent){final='(stopped)';break}
   const r=await nativeNet({url:e.base+'/chat/completions',method:'POST',timeout:300,body:JSON.stringify(thinkOff(S.sel.e,{model:up(S.sel.e,S.sel.m),messages:api,tools:TOOLS,tool_choice:'auto',stream:false,temperature:0.3,reasoning_effort:'none'}))});
   if(r.status!==200){final='The model could not answer ('+(r.status||'no connection')+').';break}
   let msg;try{msg=JSON.parse(r.body).choices[0].message}catch{final='I could not read the model reply.';break}
   let calls=msg.tool_calls||[];let content=msg.content||'';
   if(!calls.length&&content){const tc=parseTextCalls(content);if(tc.length){calls=tc;content=''}}
   if(!calls.length&&!content.trim()&&step>0&&!S.nudged){S.nudged=true;api.push({role:'user',content:'(Answer my request now in plain words, using the tool results above.)'});continue} // some models (Gemma 4 on Ollama 0.30) stop with an empty reply right after a tool result
   if(!calls.length){final=content||'(no answer came back)';break}
   api.push({role:'assistant',content:content||null,tool_calls:calls});
   for(const c of calls){
    let a={};try{a=JSON.parse(c.function.arguments||'{}')}catch{}
    const n=c.function.name;const st={role:'step',tool:n,args:a,text:describe(n,a),status:''};const el=addStep(st);
    const res=await act('toolRun','',{name:n,args:JSON.stringify(a)});let out=res.text||'';
    if(res.pending){
      const ok=await dialog('The assistant wants to change something:\n\n'+res.preview,{yes:'Approve',no:'Deny'});
      if(ok){const ap=await act('toolApply','',{name:n,args:JSON.stringify(a),pendingId:res.pendingId||''});out=ap.text;st.status='done';st.text+=' approved';if(ap.undoId)st.undoId=ap.undoId}
      else{if(res.pendingId)act('toolCancelId','',{pendingId:res.pendingId});out='The user denied this action. Nothing was changed.';st.status='denied';st.text+=' denied'}}
    st.result=out;ch.messages.push(st);saveChat(ch);el.replaceWith(addStep(st));
    api.push({role:'tool',tool_call_id:c.id,name:n,content:String(out).slice(0,6000)});
   }
   if(step===7)final='I stopped after 8 steps. Ask me to continue if you want more.';
  }
 }finally{
  wait.remove();addMsg('assistant',final,S.via);ch.messages.push({role:'assistant',content:final,via:S.via||undefined});saveChat(ch);
  S.busy=false;$('send').hidden=false;$('stop').hidden=true}
 return final}
$('stop').onclick=()=>{S.stopAgent=true;window.webkit.messageHandlers.stream.postMessage({id:S.cur,cmd:'cancel'})};
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
window.__speech=ev=>{const m=$('mic');m.classList.toggle('on',!!ev.listening);
 if(ev.text&&micDown||ev.text&&ev.listening)$('input').value=ev.text;
 if(ev.warning){m.title=ev.warning;if(micDown){micDown=false;status(ev.warning)}}};
const micStart=()=>{if(S.busy)return;micDown=true;status('Listening… release to stop');act('speechDown','',{draft:$('input').value})};
const micStop=()=>{if(!micDown)return;micDown=false;act('speechUp','');setTimeout(()=>status(''),1500)};
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
  micStart();await sleep(Number(mid)||8000);micStop();await sleep(1500);return JSON.stringify({events:ev.slice(0,12),mic:$('mic').title},null,1)}
 if(mode==='settings'){await boot;openSettings();await sleep(2500);return $('sbody').innerText}
 return _st4(mode,eid,mid)};
const _st5=window.__selftest;
window.__selftest=async(mode,eid,mid)=>{
 if(mode==='toolpreview'){await boot;const [n,a]=mid.split('|');const r=await act('toolRun','',{name:n,args:a||'{}'});
  if(r.pendingId)await act('toolCancelId','',{pendingId:r.pendingId});return JSON.stringify({pending:!!r.pending,preview:r.preview,text:r.text},null,1)}
 if(mode==='photoui'){await boot;$('photo').click();await sleep(4000);return 'clicked'}
 return _st5(mode,eid,mid)};

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
