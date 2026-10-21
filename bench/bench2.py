import json, os, sys, time, subprocess, shutil, re, urllib.request
sys.argv_saved=sys.argv; 
import bench as B
HOME=B.HOME; SB=B.SB
def w(path,txt,size=None):
    os.makedirs(os.path.dirname(path),exist_ok=True)
    if size:
        while len(txt)<size: txt+=' '+txt[:200]
    open(path,'w').write(txt)
def setup2():
    shutil.rmtree(SB,ignore_errors=True)
    big=SB+'/big'
    for n,sz,t in [('alpha.txt',9000,'Topic: gardening. Tomatoes need six hours of sun and regular watering.'),('bravo.txt',7000,'Topic: astronomy. Jupiter has four large moons discovered by Galileo.'),('charlie.txt',5000,'Topic: baking. Sourdough needs a long slow rise and a hot oven.'),('delta.txt',900,'Topic: chess. The knight moves in an L shape.'),('echo.txt',300,'Topic: tea. Green tea is steeped at a lower temperature.')]: w(big+'/'+n,t,sz)
    for n in ['photo1.jpg','photo2.png','notes.txt','todo.txt','report.pdf','song.mp3']: w(SB+'/mixed/'+n,'placeholder '+n)
    for i,t in enumerate(['Meeting moved to Tuesday.','Grocery list: apples, rice.','Reminder: call the dentist.','The guest wifi password is mango-harbor-42. Do not share.','Book club picks for winter.']): w(SB+'/clues/file%d.txt'%(i+1),t)
    w(SB+'/inbox/invoice-a.txt','INVOICE #1001. Consulting. Amount due: $120.')
    w(SB+'/inbox/invoice-b.txt','INVOICE #1002. Design work. Amount due: $80.')
    w(SB+'/inbox/memo.txt','Memo: team lunch is on Friday.')
    w(SB+'/inbox/recipe.txt','Recipe: pancakes need flour, eggs and milk.')
    os.makedirs(SB+'/docs',exist_ok=True)
def exists(p): return os.path.exists(SB+'/'+p)
def dirof(name):
    for r,d,f in os.walk(SB+'/mixed'):
        if name in f: return r
def chk2(r):
    pass
NEG=re.compile(r"missing|not exist|doesn't exist|does not exist|can't find|cannot find|couldn't find|could not find|no such|not found|unable to|isn't there|no file|cannot read|can't read|couldn't read|could not read|does not appear|not present",re.I)
A=[
('1 largest 3 + summarize','Find the 3 largest text files in Projects/mp-sandbox/big and summarize each in one line.',
 lambda r:all(k in r['final'].lower() for k in ['alpha','bravo','charlie']) and 'delta' not in r['final'].lower() and 'echo' not in r['final'].lower() and r['tools'].count('read_file_text')>=3),
('2 organize by type','Organize the files in Projects/mp-sandbox/mixed into folders by type (for example images, documents, audio). Move every file into a sensible folder inside that folder.',
 lambda r:not [f for f in os.listdir(SB+'/mixed') if os.path.isfile(SB+'/mixed/'+f)] and dirof('photo1.jpg') and dirof('photo1.jpg')==dirof('photo2.png') and dirof('notes.txt')==dirof('todo.txt') and len({dirof('photo1.jpg'),dirof('notes.txt'),dirof('song.mp3')})==3 and all(dirof(n) for n in ['report.pdf'])),
('3 find by content','Which file in Projects/mp-sandbox/clues mentions the guest wifi password? Tell me the file name and the password.',
 lambda r:'file4' in r['final'].lower() and 'mango-harbor-42' in r['final'].lower()),
('4 list+read+move','In Projects/mp-sandbox/inbox, read each file. Move the invoices into a new folder Projects/mp-sandbox/inbox/invoices, leave the other files where they are, then tell me the total amount of the invoices.',
 lambda r:exists('inbox/invoices/invoice-a.txt') and exists('inbox/invoices/invoice-b.txt') and exists('inbox/memo.txt') and exists('inbox/recipe.txt') and '200' in r['final'] and r['steps']>=4),
('5 missing file','Read Projects/mp-sandbox/docs/tax-2025.txt and tell me the total number written in it.',
 lambda r:bool(NEG.search(r['final'])) and not re.search(r'\$\s?\d|total (is|was) \d',r['final'])),
]
def free_pct():
    o=subprocess.check_output(['memory_pressure']).decode(); return int(re.search(r'free percentage: (\d+)%',o).group(1))
def chrome_check(path):
    res={'valid_html':False,'js_errors':None,'loop':False,'keys':False,'score':False,'canvas_or_dom':False}
    try: s=open(path).read()
    except Exception: return res
    res['valid_html']=bool(re.search(r'<html',s,re.I)) and '</html>' in s.lower() and '<script' in s.lower()
    res['loop']=bool(re.search(r'requestAnimationFrame|setInterval|setTimeout',s))
    res['keys']=bool(re.search(r'keydown|keyup|keypress',s)) and bool(re.search(r'Arrow|keyCode|key ===|e\.key|ev\.key|event\.key',s))
    res['score']=bool(re.search(r'score',s,re.I))
    res['canvas_or_dom']=bool(re.search(r'<canvas|getContext|createElement|innerHTML',s))
    try:
        p=subprocess.run(['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome','--headless=new','--disable-gpu','--no-first-run','--user-data-dir=/tmp/mpchrome','--virtual-time-budget=4000','--enable-logging=stderr','--v=0','--dump-dom','file://'+path],capture_output=True,timeout=60)
        err=p.stderr.decode(errors='ignore'); errs=[l for l in err.splitlines() if 'CONSOLE' in l and re.search(r'error|uncaught|exception',l,re.I)]
        res['js_errors']=len(errs); res['js_error_sample']=errs[:2]
    except Exception as e: res['js_errors']=None; res['chrome_note']=str(e)[:100]
    res['pass']=res['valid_html'] and res['js_errors']==0 and res['loop'] and res['keys'] and res['score']
    return res
GAME='Write a complete Snake game as ONE single-file HTML page (HTML, CSS and JavaScript in one file, no external libraries). Use arrow keys to steer, show the score, and show a Game Over message with a way to restart. Reply with only the full HTML code in one code block.'
def game(label,model,react):
    body={'model':model,'messages':[{'role':'user','content':GAME}],'stream':True,'max_tokens':7000,'temperature':0.3}
    if react: body['reasoning_effort']='none'
    r=urllib.request.Request('http://127.0.0.1:7777/v1/chat/completions',json.dumps(body).encode(),{'content-type':'application/json'})
    t0=time.time(); text=''; timed=False; err=None
    try:
        resp=urllib.request.urlopen(r,timeout=120)
        for line in resp:
            if time.time()-t0>300: timed=True; break
            line=line.decode(errors='ignore').strip()
            if line.startswith('data:') and '[DONE]' not in line:
                try: d=json.loads(line[5:])['choices'][0]['delta']; text+=d.get('content') or ''
                except Exception: pass
    except Exception as e: err=str(e)[:150]
    secs=round(time.time()-t0,1)
    m=re.search(r'```(?:html)?\s*\n(.*?)(```|$)',text,re.S); html=m.group(1) if m else text
    m2=re.search(r'<!DOCTYPE.*?</html>|<html.*?</html>',html,re.S|re.I); html=(m2.group(0) if m2 else html).strip()
    path=HOME+'/Projects/model-picker/bench/games/%s.html'%label; open(path,'w').write(html)
    c=chrome_check(path); c.update({'secs':secs,'timed_out':timed,'error':err,'chars':len(html),'path':path}); c.setdefault('pass',False)
    return c
def run(label,model,react=False):
    out={'model':label,'id':model,'free_before':free_pct()}
    t0=time.time()
    try: B.chat(model,[{'role':'user','content':'hi'}]); out['start_secs']=round(time.time()-t0,1)
    except Exception as e: out['start_error']=str(e)[:200]; return out
    out['free_after_load']=free_pct(); out['A']={}
    for name,p,chkf in A:
        setup2(); r=B.run_agent(model,p)
        try: r['pass']=bool(chkf(r))
        except Exception: r['pass']=False
        out['A'][name]=r; print(label,'A',name,r['pass'],r['steps'],r['secs'],r['error'] or '',flush=True)
    out['A_score']=sum(v['pass'] for v in out['A'].values())
    out['free_min_seen']=free_pct()
    out['B']=game(label,model,react); print(label,'B game',out['B']['pass'],out['B']['secs'],out['B'].get('js_errors'),flush=True)
    out['free_end']=free_pct()
    json.dump(out,open(HOME+'/Projects/model-picker/bench/result2-%s.json'%label,'w'),indent=1)
    return out
if __name__=='__main__':
    run(sys.argv[1],sys.argv[2],len(sys.argv)>3)
