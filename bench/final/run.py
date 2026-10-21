import json,os,sys,time,subprocess,urllib.request,re,shutil
sys.path.insert(0,os.path.expanduser('~/Projects/model-picker/bench'))
import bench as B
HOME=os.path.expanduser('~'); D=HOME+'/Projects/model-picker/bench/final/'; RAW=D+'raw/'; os.makedirs(RAW,exist_ok=True)
CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
START=time.time(); DEADLINE=START+float(os.environ.get('CAP','2000'))
PROMPTS={1:"Write a casual X post in my voice, under 280 characters: I spent the weekend building a Mac app that lets me pick any local AI model and chat with it. Learning in public, a little excited, no hashtags.",
2:"Explain to a non-technical person what a debt service coverage ratio is, in 4 sentences, with a simple example using a small apartment building.",
3:"I have 3 boxes labeled Apples, Oranges, and Mixed. All labels are wrong. I pick one fruit from the box labeled Mixed and it's an apple. What is in each box? Show your steps briefly.",
4:"Look in my Projects folder and tell me which 3 folders were changed most recently, with their dates. Don't move or change anything.",
5:"Write a single HTML file with a button that picks a random motivational quote and shows it on the page."}
OS="http://127.0.0.1:1337/v1"
MODELS=[
 dict(k='bonsai4b',name='Bonsai 4B',base='http://127.0.0.1:8097/v1',model='4b/Ternary-Bonsai-2-4B-PQ2_0.gguf',port=8097,started=False,extra={'chat_template_kwargs':{'enable_thinking':False}}),
 dict(k='gemma2',name='Gemma2 2B',base='http://127.0.0.1:11434/v1',model='gemma2:2b',port=11434,ollama=True,extra={}),
 dict(k='qwen35_2b',name='Qwen3.5 2B',base='http://127.0.0.1:8082/v1',model='qwen3.5-2b',port=8082,extra={'chat_template_kwargs':{'enable_thinking':False}}),
 dict(k='gemma4',name='Gemma 4 E2B',base='http://127.0.0.1:11434/v1',model='gemma4:e2b',port=11434,ollama=True,extra={'reasoning_effort':'none'}),
 dict(k='foundation',name='Apple Foundation',base=OS,model='foundation',port=1337,extra={}),
 dict(k='raptor',name='Raptor 0.6',base=OS,model='raptor-0.6-4b-jang_6m',port=1337,extra={'reasoning_effort':'none'}),
 dict(k='spark',name='Spark X2.5',base='http://127.0.0.1:8095/v1',model=HOME+'/MLXModels/Spark-X2.5-4B-MLX-4bit',port=8095,start=[HOME+'/.askmymac/run-spark.sh'],extra={'chat_template_kwargs':{'enable_thinking':False}},big=4000),
 dict(k='qwencoder',name='Qwen2.5-Coder 7B',base='http://127.0.0.1:11434/v1',model='qwen2.5-coder:7b',port=11434,ollama=True,extra={}),
 dict(k='bonsai9b',name='Bonsai 9B',base='http://127.0.0.1:8098/v1',model='9b/Ternary-Bonsai-2-9B-PQ2_0.gguf',port=8098,start=[HOME+'/Models/bonsai2/start.sh','9b'],stop_pid=HOME+'/Models/bonsai2/9b.pid',extra={'chat_template_kwargs':{'enable_thinking':False}}),
 dict(k='ornith',name='ornith 9B',base='http://127.0.0.1:11434/v1',model='ornith:9b',port=11434,ollama=True,extra={'reasoning_effort':'none'}),
]
only=os.environ.get('ONLY'); 
if only: MODELS=[m for m in MODELS if m['k'] in only.split(',')]
def sh(c,t=30):
    try: return subprocess.run(c,shell=True,capture_output=True,text=True,timeout=t).stdout.strip()
    except Exception as e: return ''
def freepct():
    m=re.search(r'(\d+)%',sh('memory_pressure | tail -1')); return int(m.group(1)) if m else -1
def rss(port):
    p=sh('lsof -ti tcp:%d -sTCP:LISTEN'%port).split()
    return round(sum(int(sh('ps -o rss= -p %s'%x) or 0) for x in p)/1024) if p else None
def up(m):
    try: urllib.request.urlopen(m['base'].replace('/v1','')+('/api/tags' if m.get('ollama') else '/v1/models'),timeout=3); return True
    except Exception: return False
def stream(m,msgs,maxtok=900,tools=None):
    body={'model':m['model'],'messages':msgs,'stream':True,'temperature':0.3,'max_tokens':m.get('big',maxtok)}
    body.update(m.get('extra',{}))
    if tools: body['tools']=tools; body['tool_choice']='auto'; body['stream']=False
    r=urllib.request.Request(m['base']+'/chat/completions',json.dumps(body).encode(),{'content-type':'application/json'})
    t0=time.time(); first=None; txt=''; n=0
    resp=urllib.request.urlopen(r,timeout=240)
    if tools:
        j=json.loads(resp.read()); return j['choices'][0]['message'],time.time()-t0
    for line in resp:
        line=line.decode().strip()
        if not line.startswith('data:') or line.endswith('[DONE]'): continue
        try: d=json.loads(line[5:])['choices'][0].get('delta',{})
        except Exception: continue
        c=d.get('content') or ''
        if c:
            if first is None: first=time.time()-t0
            txt+=c
        if time.time()-t0>200: break
    tot=time.time()-t0; w=len(txt.split())
    return dict(text=txt,first=round(first,2) if first else None,total=round(tot,1),words=w,wps=round(w/max(tot-(first or 0),.01),1) if first else 0)
def agent(m,prompt):
    api=[{'role':'system','content':B.sysprompt()},{'role':'user','content':prompt}]; used=[];final='';err=None;t0=time.time();first=None;native=0
    try:
        for _ in range(6):
            if time.time()-t0>150: final='(time limit)';break
            msg,dt=stream(m,api,maxtok=1200,tools=B.TOOLS)
            if first is None: first=dt
            calls=msg.get('tool_calls') or [];c=msg.get('content') or ''
            if calls: native+=len(calls)
            if not calls and c:
                tc=B.parse_text(c) or []
                if tc: calls=tc;c=''
            if not calls: final=c or '(no answer)';break
            api.append({'role':'assistant','content':c or None,'tool_calls':calls})
            for x in calls:
                n=x['function']['name']
                try: a=json.loads(x['function'].get('arguments') or '{}')
                except Exception: a={}
                used.append((n,a))
                out=B.tool(n,a,apply=False) if n in B.NAMES else 'Unknown tool'
                api.append({'role':'tool','tool_call_id':x.get('id','t'),'name':n,'content':str(out)[:6000]})
        else: final='(step limit)'
    except urllib.error.HTTPError as e:
        err='HTTP %d %s'%(e.code,e.read()[:200].decode('utf8','ignore'))
    except Exception as e: err=str(e)[:200]
    return dict(text=final,tools=used,native=native,total=round(time.time()-t0,1),first=round(first,2) if first else None,words=len(final.split()),error=err)
def extract_html(t):
    mm=re.search(r'```(?:html)?\s*\n(.*?)```',t,re.S)
    if mm: return mm.group(1)
    mm=re.search(r'(<!DOCTYPE.*|<html.*)',t,re.S|re.I)
    if mm: return mm.group(1)
    return t if '<' in t else ''
INJ='''<script>window.addEventListener('load',function(){setTimeout(function(){var R=[];var b=document.querySelector('button,[role=button],input[type=button],input[type=submit]');var o={btn:!!b,before:document.body.innerText.trim()};
if(b){for(var i=0;i<%d;i++){try{b.click()}catch(e){}R.push(document.body.innerText.trim())}}o.after=R;var p=document.createElement('pre');p.id='__r';p.textContent='@@'+JSON.stringify(o)+'@@';document.body.appendChild(p)},300)})</script>'''
def chrome(path,clicks=8,shot=None):
    h=open(path).read(); h=h+INJ%clicks; tp='/tmp/finaltmp/inj_%d.html'%clicks; open(tp,'w').write(h)
    cmd=[CHROME,'--headless=new','--disable-gpu','--no-first-run','--user-data-dir=/tmp/finaltmp/prof','--virtual-time-budget=4000','--window-size=900,600']
    if shot: cmd+=['--screenshot='+shot]; 
    else: cmd+=['--dump-dom']
    cmd.append('file://'+tp)
    r=subprocess.run(cmd,capture_output=True,text=True,timeout=60)
    if shot: return None
    mm=re.search(r'<pre id="__r">@@(.*?)@@</pre>',r.stdout,re.S)
    if not mm: return None
    import html as H
    try: return json.loads(H.unescape(mm.group(1)))
    except Exception: return None
def main():
    res=json.load(open(D+'results.json')) if os.path.exists(D+'results.json') else {}
    for m in MODELS:
        if time.time()>DEADLINE: res[m['k']]={'name':m['name'],'skipped':'time cap'}; continue
        R={'name':m['name'],'tests':{}}; res[m['k']]=R
        for _ in range(12):
            if freepct()>=30: break
            time.sleep(5)
        R['free_before']=freepct(); started=False
        if not up(m):
            if m.get('start'):
                subprocess.Popen(m['start'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True); started=True
                for _ in range(60):
                    time.sleep(2)
                    if up(m): break
            if not up(m): R['skipped']='engine did not start'; json.dump(res,open(D+'results.json','w'),indent=1); continue
        R['started']=started; print('==',m['name'],flush=True)
        try:
            for t in (1,2,3):
                try: o=stream(m,[{'role':'user','content':PROMPTS[t]}])
                except Exception as e: o={'error':str(e)[:200]}
                R['tests'][t]=o; open(RAW+'%s_t%d.txt'%(m['k'],t),'w').write(json.dumps(o,indent=1)); print(t,o.get('first'),o.get('wps'),o.get('total'),flush=True)
            o=agent(m,PROMPTS[4]); R['tests'][4]=o; open(RAW+'%s_t4.txt'%m['k'],'w').write(json.dumps(o,indent=1)); print(4,o.get('total'),o.get('error'),flush=True)
            try: o=stream(m,[{'role':'user','content':PROMPTS[5]}],maxtok=1800)
            except Exception as e: o={'error':str(e)[:200]}
            R['tests'][5]=o
            if o.get('text'):
                h=extract_html(o['text']); fp=D+'html_%s.html'%m['k']; open(fp,'w').write(h)
                try: o['chrome']=chrome(fp)
                except Exception as e: o['chrome']={'err':str(e)[:100]}
            open(RAW+'%s_t5.txt'%m['k'],'w').write(json.dumps(o,indent=1)); print(5,o.get('first'),o.get('wps'),o.get('total'),o.get('chrome'),flush=True)
            R['free_after']=freepct(); R['rss_mb']=rss(m['port'])
            if m.get('ollama'): R['ollama_ps']=sh('ollama ps')
        finally:
            if m.get('ollama'): sh('ollama stop '+m['model'])
            if started:
                if m.get('stop_pid') and os.path.exists(m['stop_pid']): sh('kill %s'%open(m['stop_pid']).read().strip())
                else: sh('kill $(lsof -ti tcp:%d -sTCP:LISTEN)'%m['port'])
                R['stopped']=True
            time.sleep(3); R['free_after_stop']=freepct()
            json.dump(res,open(D+'results.json','w'),indent=1)
    json.dump(res,open(D+'results.json','w'),indent=1); print('DONE',round(time.time()-START))
main()
