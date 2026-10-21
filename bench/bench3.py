import json, os, sys, time, subprocess, shutil, re, urllib.request
import bench as B, bench2 as B2
HOME=B.HOME; SB=B.SB
SPARK=False
WRITE={'type':'function','function':{'name':'write_file','description':'Write (replace) a plain text file inside Projects/mp-sandbox with the given full content. Test harness only.','parameters':{'type':'object','properties':{'path':{'type':'string','description':'File path.'},'content':{'type':'string','description':'Complete new file content.'}},'required':['path','content']}}}
TOOLS=B.TOOLS+[WRITE]; NAMES=B.NAMES|{'write_file'}
def write_file(a):
    p=B.subprocess.check_output(['bash','-c','true']) and None
    path=os.path.expanduser(a.get('path','')); 
    if not path.startswith('/'): path=HOME+'/'+path
    path=os.path.realpath(path)
    if not path.startswith(os.path.realpath(SB)+'/') or os.path.basename(path).startswith('test_'): return 'Not allowed (only files in the sandbox, and tests cannot be edited).'
    os.makedirs(os.path.dirname(path),exist_ok=True); open(path,'w').write(a.get('content','')); return 'Wrote %d characters to %s'%(len(a.get('content','')),a['path'])
def chat(model,msgs):
    body={'model':model,'messages':msgs,'tools':TOOLS,'tool_choice':'auto','stream':False,'temperature':0.3,'max_tokens':4000}
    if SPARK: body['chat_template_kwargs']={'enable_thinking':False}
    else: body['reasoning_effort']='none'
    r=urllib.request.Request('http://127.0.0.1:7777/v1/chat/completions',json.dumps(body).encode(),{'content-type':'application/json'})
    return json.loads(urllib.request.urlopen(r,timeout=400).read())['choices'][0]['message']
def agent(model,prompt,maxsteps=10):
    api=[{'role':'system','content':B.sysprompt()+'\nYou also have write_file to save a complete file (use it to fix or create code). You cannot run code; the user will run the tests.'},{'role':'user','content':prompt}]
    used=[];final='';err=None;t0=time.time()
    try:
        for _ in range(maxsteps):
            m=chat(model,api);calls=m.get('tool_calls') or [];c=m.get('content') or ''
            if not calls and c:
                tc=B.parse_text(c) or []
                if tc: calls=tc;c=''
            if not calls: final=c or '(no answer)';break
            api.append({'role':'assistant','content':c or None,'tool_calls':calls})
            for x in calls:
                n=x['function']['name']
                try: a=json.loads(x['function'].get('arguments') or '{}')
                except Exception: a={}
                used.append(n)
                if n=='write_file': out=write_file(a)
                elif n in B.NAMES: out=B.tool(n,a)
                else: out='Unknown tool'
                api.append({'role':'tool','tool_call_id':x['id'],'name':n,'content':str(out)[:6000]})
        else: final='(step limit)'
    except Exception as e: err=str(e)[:200]
    return {'final':final[:400],'tools':used,'steps':len(used),'secs':round(time.time()-t0,1),'error':err}
def mk(path,txt): os.makedirs(os.path.dirname(path),exist_ok=True); open(path,'w').write(txt)
def setup1():
    shutil.rmtree(SB,ignore_errors=True)
    mk(SB+'/proj1/calc.py','def sum_to(n):\n    """Return 1 + 2 + ... + n (inclusive)."""\n    total = 0\n    for i in range(n):\n        total += i\n    return total\n')
    mk(SB+'/proj1/test_calc.py','import unittest\nfrom calc import sum_to\n\nclass T(unittest.TestCase):\n    def test_five(self): self.assertEqual(sum_to(5), 15)\n    def test_zero(self): self.assertEqual(sum_to(0), 0)\n    def test_one(self): self.assertEqual(sum_to(1), 1)\n\nif __name__ == "__main__": unittest.main()\n')
def setup2():
    shutil.rmtree(SB,ignore_errors=True)
    mk(SB+'/proj2/test_textutils.py','import unittest\nfrom textutils import slugify, word_count\n\nclass T(unittest.TestCase):\n    def test_slug_basic(self): self.assertEqual(slugify("Hello World"), "hello-world")\n    def test_slug_punct(self): self.assertEqual(slugify("  Hi,   there!! "), "hi-there")\n    def test_slug_empty(self): self.assertEqual(slugify("***"), "")\n    def test_count(self): self.assertEqual(word_count("one two  three\\nfour"), 4)\n    def test_count_empty(self): self.assertEqual(word_count("   "), 0)\n\nif __name__ == "__main__": unittest.main()\n')
def runtests(d):
    try:
        p=subprocess.run(['python3','-m','unittest','-q'],cwd=SB+'/'+d,capture_output=True,timeout=30); return p.returncode==0
    except Exception: return False
TASKS=[('A1 fix bug',setup1,'proj1','The test Projects/mp-sandbox/proj1/test_calc.py is failing. Read calc.py and the test, find the bug, and fix calc.py by saving the corrected file with write_file. Do not change the test.'),
 ('A2 write module from spec',setup2,'proj2','Create Projects/mp-sandbox/proj2/textutils.py with two functions. slugify(text): lowercase the text, replace every run of non-letter/non-digit characters with a single hyphen, and strip hyphens from both ends. word_count(text): number of whitespace-separated words. First read the tests in Projects/mp-sandbox/proj2/test_textutils.py, then save the module with write_file so the tests pass.')]
SHOOT=GAME='Write a complete simple space shooter game as ONE single-file HTML page (HTML, CSS and JavaScript in one file, no external libraries, use a canvas). The player ship moves left and right with the arrow keys or A/D, and the space bar shoots bullets upward. Enemies descend from the top; bullets destroy them and add to the score, which is shown on screen. If an enemy reaches the bottom or hits the ship, show Game Over with a way to restart. Reply with only the full HTML code in one code block.'
def extract(text):
    m=re.search(r'```(?:html)?\s*\n(.*?)(```|$)',text,re.S); h=m.group(1) if m else text
    m2=re.search(r'<!DOCTYPE.*?</html>|<html.*?</html>',h,re.S|re.I); return (m2.group(0) if m2 else h).strip()
def gen(model,msgs,cap=360):
    body={'model':model,'messages':msgs,'stream':True,'max_tokens':12000 if SPARK else 8000,'temperature':0.3}
    if SPARK: body['chat_template_kwargs']={'enable_thinking':False}
    else: body['reasoning_effort']='none'
    r=urllib.request.Request('http://127.0.0.1:7777/v1/chat/completions',json.dumps(body).encode(),{'content-type':'application/json'})
    t0=time.time();text='';timed=False;err=None
    try:
        for line in urllib.request.urlopen(r,timeout=120):
            if time.time()-t0>cap: timed=True;break
            line=line.decode(errors='ignore').strip()
            if line.startswith('data:') and '[DONE]' not in line:
                try: text+=json.loads(line[5:])['choices'][0]['delta'].get('content') or ''
                except Exception: pass
    except Exception as e: err=str(e)[:150]
    return text,round(time.time()-t0,1),timed,err
def check(path):
    c=B2.chrome_check(path); s=open(path).read()
    c['shoot']=bool(re.search(r"Space|' '|\" \"|keyCode\s*===?\s*32|code\s*===?\s*['\"]Space",s)); c['enemies']=bool(re.search(r'enem',s,re.I))
    c['pass']=bool(c['valid_html'] and c['js_errors']==0 and c['loop'] and c['keys'] and c['shoot'] and c['score'] and c['enemies']); return c
def shooter(label,model):
    path=HOME+'/Projects/model-picker/bench/games/shooter-%s.html'%label
    msgs=[{'role':'user','content':SHOOT}]; res={'attempts':[]}
    for attempt in (1,2):
        text,secs,timed,err=gen(model,msgs); html=extract(text); open(path,'w').write(html)
        c=check(path); c.update({'secs':secs,'timed_out':timed,'error':err,'chars':len(html)}); res['attempts'].append(c)
        print(label,'B attempt',attempt,c['pass'],secs,c.get('js_errors'),flush=True)
        if c['pass'] or attempt==2: break
        why=(c.get('js_error_sample') or [''])[0][-300:] if c.get('js_errors') else ('You returned no HTML code.' if not html else 'The game is missing: '+', '.join(k for k in ['loop','keys','shoot','score','enemies'] if not c.get(k)))
        msgs=[msgs[0],{'role':'assistant','content':text[:12000] or '(empty)'},{'role':'user','content':'When I opened it in Chrome this problem was reported: '+why+'\nPlease fix it and reply with the complete corrected HTML in one code block.'}]
    res['pass']=res['attempts'][-1]['pass']; res['tries']=len(res['attempts']); res['path']=path; return res
def run(label,model):
    global SPARK; SPARK=(label=='Spark')
    out={'model':label,'id':model,'free_before':B2.free_pct()}
    t0=time.time()
    try: chat(model,[{'role':'user','content':'hi'}]); out['start_secs']=round(time.time()-t0,1)
    except Exception as e: out['start_error']=str(e)[:200]; return out
    out['free_after_load']=free=B2.free_pct(); out['A']={}
    for name,setup,d,prompt in TASKS:
        tries=[]
        for t in (1,2,3):
            setup(); r=agent(model,prompt); r['pass']=runtests(d); tries.append(r)
            print(label,name,'try',t,r['pass'],r['steps'],r['secs'],r['error'] or '',flush=True)
            if r['pass']: break
        out['A'][name]={'pass':tries[-1]['pass'],'tries':len(tries),'secs':round(sum(x['secs'] for x in tries),1),'detail':tries}
    out['free_mid']=B2.free_pct()
    out['B']=shooter(label,model); out['free_end']=B2.free_pct()
    json.dump(out,open(HOME+'/Projects/model-picker/bench/result3-%s.json'%label,'w'),indent=1)
if __name__=='__main__': run(sys.argv[1],sys.argv[2])
