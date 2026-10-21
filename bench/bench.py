import json, os, sys, time, subprocess, urllib.request, shutil, re, datetime
HOME=os.path.expanduser('~'); SB=HOME+'/Projects/mp-sandbox'
BIN=subprocess.check_output(['bash','-c','cd ~/Projects/model-picker/mac && swift build -c release --show-bin-path']).decode().strip()+'/ModelPicker'
P=lambda t,d,r=None:(t,d)
T=[('list_folder','List the files and folders directly inside one folder.',{'path':('string','Folder path. A name like Downloads is looked up inside the home folder.')},['path']),
('search_files','Find files and folders in the home folder by name. Returns up to 15 paths.',{'query':('string','Words to look for in the file name.')},['query']),
('list_files_by_date','List files in a folder changed within the last N days (7 = last week, 0 = today).',{'folder':('string','Folder to scan, e.g. Downloads.'),'days_back':('integer','How many days back.'),'name_contains':('string','Optional part of the file name.')},['folder','days_back']),
('file_info','Show kind, size and dates for one file or folder.',{'path':('string','Path inside the home folder.')},['path']),
('read_file_text','Read the text of a plain text file (first 4000 characters).',{'path':('string','Path to a file inside the home folder.')},['path']),
('list_calendar_events','Read-only: list calendar events. range is today, tomorrow or this_week; or give start_date and end_date as YYYY-MM-DD.',{'range':('string','today, tomorrow or this_week'),'start_date':('string','Optional YYYY-MM-DD'),'end_date':('string','Optional YYYY-MM-DD')},[]),
('move_items','Prepare a move of files into a destination folder. Nothing moves until the user approves.',{'paths':('array','Paths to move.'),'destination_folder':('string','Folder to move them into. Created if missing.')},['paths','destination_folder']),
('rename_item','Prepare a rename of one file. Nothing changes until the user approves.',{'path':('string','File to rename.'),'new_name':('string','New file name only, not a path.')},['path','new_name'])]
TOOLS=[{'type':'function','function':{'name':n,'description':d,'parameters':{'type':'object','properties':{k:({'type':'array','items':{'type':'string'},'description':v[1]} if v[0]=='array' else {'type':v[0],'description':v[1]}) for k,v in pr.items()},'required':rq}}} for n,d,pr,rq in T]
NAMES={t['function']['name'] for t in TOOLS}
def sysprompt(): return 'You are a private assistant on this Mac running in Model Picker. Nothing goes to the cloud.\nNow: '+datetime.datetime.now().strftime('%c')+'. Use tools for files and folders; do not invent paths or contents. If a tool fails, say so plainly. Keep replies short.\nmove_items and rename_item only prepare a preview. Nothing changes until the user approves. Never say a file was changed before the tool result says it moved. You cannot delete files. For schedule questions use list_calendar_events (read-only). If the result says PERMISSION_PENDING or PERMISSION_DENIED, tell the user plainly what to do.'
def parse_text(c):
    try:
        t=re.sub(r'^```(json)?|```$','',c.strip()).strip(); o=json.loads(t); arr=o if isinstance(o,list) else o.get('tool_calls',[o])
        out=[]
        for i,x in enumerate(arr):
            f=x.get('function',x); n=f.get('name') or x.get('tool')
            if n not in NAMES: continue
            a=f.get('arguments',f.get('parameters',{}))
            out.append({'id':'t%d'%i,'type':'function','function':{'name':n,'arguments':a if isinstance(a,str) else json.dumps(a)}})
        return out
    except Exception: return []
def setup():
    shutil.rmtree(SB,ignore_errors=True); d=SB+'/docs'; os.makedirs(d)
    open(d+'/budget-notes.txt','w').write('Q4 budget notes. Marketing gets $4,200 for the October launch. The design contractor, Priya, is paid on the 15th. Open risk: the printer quote expires on November 3.\n')
    open(d+'/trip-plan.txt','w').write('Lisbon trip. Hotel: Casa Azul. Flight lands at 9:40 AM on Friday.\n')
    open(d+'/old-archive.txt','w').write('Very old file.\n')
    open(d+'/shopping.txt','w').write('milk, eggs, coffee\n')
    open(SB+'/scratch-delete-me.txt','w').write('throwaway\n')
    old=time.time()-40*86400
    os.utime(d+'/old-archive.txt',(old,old))
def tool(n,a,apply=True):
    cmd=[BIN,'--tool',n,json.dumps(a)]+(['--apply'] if apply else [])
    try: return json.loads(subprocess.check_output(cmd,timeout=60).decode().strip().splitlines()[-1]).get('text','')
    except Exception as e: return 'tool error %s'%e
def chat(model,msgs):
    body=json.dumps({'model':model,'messages':msgs,'tools':TOOLS,'tool_choice':'auto','stream':False,'temperature':0.3,'reasoning_effort':'none'}).encode()
    r=urllib.request.Request('http://127.0.0.1:7777/v1/chat/completions',body,{'content-type':'application/json'})
    return json.loads(urllib.request.urlopen(r,timeout=400).read())['choices'][0]['message']
def run_agent(model,prompt):
    api=[{'role':'system','content':sysprompt()},{'role':'user','content':prompt}]; used=[]; valid=0; invalid=0; final=''; err=None
    t0=time.time()
    try:
        for step in range(8):
            m=chat(model,api); calls=m.get('tool_calls') or []; c=m.get('content') or ''
            native=bool(calls)
            if not calls and c:
                tc=parse_text(c)
                if tc: calls=tc; c=''; invalid+=1  # text-form call (works in the app, but not a native call)
            if not calls: final=c or '(no answer)'; break
            api.append({'role':'assistant','content':c or None,'tool_calls':calls})
            for x in calls:
                try: a=json.loads(x['function'].get('arguments') or '{}'); ok=x['function']['name'] in NAMES
                except Exception: a={}; ok=False
                n=x['function']['name']; used.append(n)
                if ok and native: valid+=1
                out=tool(n,a) if ok else 'Unknown tool'
                api.append({'role':'tool','tool_call_id':x['id'],'name':n,'content':str(out)[:6000]})
        else: final='(8 steps, no answer)'
    except Exception as e: err=str(e)[:200]
    return {'final':final,'tools':used,'steps':len(used),'native_calls':valid,'text_form_calls':invalid,'secs':round(time.time()-t0,1),'error':err}
PROMPTS=[
 ('1 list folder','List the files in the folder Projects/mp-sandbox/docs.',lambda r:all(k in r['final'] for k in ['budget-notes','trip-plan','shopping','old-archive']) and 'list_folder' in r['tools']),
 ('2 changed this week','In Projects/mp-sandbox/docs, which files changed in the last 7 days?',lambda r:'budget-notes' in r['final'] and 'trip-plan' in r['final'] and 'shopping' in r['final'] and 'old-archive' not in r['final'] and 'list_files_by_date' in r['tools']),
 ('3 read+summarize','Read Projects/mp-sandbox/docs/budget-notes.txt and summarize it in one or two sentences.',lambda r:'4,200' in r['final'].replace('4200','4,200') and ('November 3' in r['final'] or 'Nov' in r['final']) and 'read_file_text' in r['tools']),
 ('4 move file','Move Projects/mp-sandbox/scratch-delete-me.txt into a new folder Projects/mp-sandbox/archive.',lambda r:os.path.exists(SB+'/archive/scratch-delete-me.txt') and not os.path.exists(SB+'/scratch-delete-me.txt')),
 ('5 two-step','In Projects/mp-sandbox/docs find the file about a trip, then tell me the hotel name written inside it.',lambda r:'casa azul' in r['final'].lower() and len(set(r['tools']))>=2),
]
def bench(label,model):
    res={'model':label,'id':model,'prompts':{}}
    # warmup (starts engine through proxy)
    t0=time.time()
    try: chat(model,[{'role':'user','content':'hi'}]); res['start_secs']=round(time.time()-t0,1)
    except Exception as e: res['start_error']=str(e)[:200]; return res
    for name,p,chk in PROMPTS:
        setup() if name.startswith('1') else None
        if name.startswith('4'): setup()
        r=run_agent(model,p)
        try: r['pass']=bool(chk(r))
        except Exception: r['pass']=False
        res['prompts'][name]=r; print(label,name,r['pass'],r['steps'],r['secs'],r['error'] or '',flush=True)
    res['score']=sum(v['pass'] for v in res['prompts'].values())
    json.dump(res,open(HOME+'/Projects/model-picker/bench/result-%s.json'%label.replace(' ','_').replace(':','-'),'w'),indent=1)
    return res
if __name__=='__main__': bench(sys.argv[1],sys.argv[2])
