import json, os, sys, time, subprocess, shutil, re, urllib.request
import bench as B, bench2 as B2
HOME=B.HOME; BIG=HOME+'/Projects/model-picker/bench/big'
SPARK=False; MAXTOK=6000; DIR=''
def tools():
    def t(n,d,props,req): return {'type':'function','function':{'name':n,'description':d,'parameters':{'type':'object','properties':props,'required':req}}}
    return B.TOOLS+[t('write_file','Save a COMPLETE text file (replaces it) in the game folder. Test harness only.',{'path':{'type':'string','description':'File name such as index.html, game.js or style.css.'},'content':{'type':'string','description':'Complete file content.'}},['path','content']),
                    t('read_code','Read one of the game files you saved (up to 9000 characters).',{'path':{'type':'string','description':'File name such as game.js'}},['path'])]
TOOLS=tools(); NAMES=B.NAMES|{'write_file','read_code'}
def rp(p):
    p=os.path.expanduser(p or '')
    if not p.startswith('/'): p=DIR+'/'+os.path.basename(p) if '/' not in p else HOME+'/'+p
    p=os.path.realpath(p)
    return p if p.startswith(os.path.realpath(DIR)+'/') else None
def exec_tool(n,a):
    if n=='write_file':
        p=rp(a.get('path'));  c=a.get('content','')
        if not p or not isinstance(c,str): return 'Not allowed: only files directly in the game folder.'
        open(p,'w').write(c); return 'Saved %s (%d characters, %d lines).'%(os.path.basename(p),len(c),c.count('\n')+1)
    if n=='read_code':
        p=rp(a.get('path'))
        return open(p).read()[:9000] if p and os.path.exists(p) else 'No such file in the game folder.'
    return B.tool(n,a)
def chat(model,msgs):
    body={'model':model,'messages':msgs,'tools':TOOLS,'tool_choice':'auto','stream':False,'temperature':0.4,'max_tokens':MAXTOK}
    if SPARK: body['chat_template_kwargs']={'enable_thinking':False}
    else: body['reasoning_effort']='none'
    r=urllib.request.Request('http://127.0.0.1:7777/v1/chat/completions',json.dumps(body).encode(),{'content-type':'application/json'})
    return json.loads(urllib.request.urlopen(r,timeout=600).read())['choices'][0]['message']
FEATS={
 'controls_arrows_wasd':lambda s:bool(re.search(r'Arrow(Left|Right)',s)) and bool(re.search(r"['\"]a['\"]|KeyA|keyCode\s*===?\s*65",s,re.I)),
 'space_shoot':lambda s:bool(re.search(r"Space|' '|\" \"|keyCode\s*===?\s*32",s)),
 'three_enemy_types':lambda s:len(set(re.findall(r'zigzag|sine|diagonal|chaser|chase|homing|strafe|tank|swarm|dive|fast|shooter|kamikaze|drifter',s,re.I)))>=3,
 'waves':lambda s:bool(re.search(r'wave',s,re.I)),
 'powerups':lambda s:bool(re.search(r'power-?up',s,re.I)),
 'lives':lambda s:bool(re.search(r'lives|life',s,re.I)),
 'score':lambda s:bool(re.search(r'score',s,re.I)),
 'high_score_localstorage':lambda s:'localStorage' in s and bool(re.search(r'high',s,re.I)),
 'start_screen':lambda s:bool(re.search(r'start',s,re.I)),
 'game_over_screen':lambda s:bool(re.search(r'game ?over',s,re.I)),
 'webaudio_beeps':lambda s:bool(re.search(r'AudioContext',s)) and bool(re.search(r'oscillator',s,re.I)),
 'pause_key':lambda s:bool(re.search(r'pause',s,re.I)),
}
def snapshot():
    files={f:open(DIR+'/'+f).read() for f in os.listdir(DIR) if os.path.isfile(DIR+'/'+f)}
    allsrc='\n'.join(files.values()); feats={k:f(allsrc) for k,f in FEATS.items()}
    return files,feats
def jserrors():
    p=DIR+'/index.html'
    if not os.path.exists(p): return None,['index.html missing']
    try:
        r=subprocess.run(['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome','--headless=new','--disable-gpu','--no-first-run','--user-data-dir=/tmp/mpchrome','--virtual-time-budget=5000','--enable-logging=stderr','--v=0','--dump-dom','file://'+p],capture_output=True,timeout=60)
        errs=[re.sub(r'^\[[^\]]*\]\s*','',l) for l in r.stderr.decode(errors='ignore').splitlines() if 'CONSOLE' in l and re.search(r'error|uncaught|exception|failed',l,re.I)]
        # also: referenced files exist?
        html=files_html=open(p).read(); miss=[m for m in re.findall(r'(?:src|href)=["\']([^"\':]+)["\']',html) if not os.path.exists(DIR+'/'+m)]
        errs+=['Missing file referenced by index.html: '+m for m in miss]
        return len(errs),errs
    except Exception as e: return None,['chrome check failed: '+str(e)[:100]]
TASK='Build a multi-file browser game called "Space Defender" in the folder Projects/model-picker/bench/big/%s/ (save files with write_file using just the file name). Files: index.html (loads style.css and game.js, has a canvas and overlay screens), game.js, style.css. Features: player ship moved with arrow keys or WASD, space bar shoots; 3 different enemy types with different movement patterns; waves that get harder; power-ups; lives and score; high score saved in localStorage; a start screen and a game-over screen; simple sound beeps using WebAudio; a pause key (P). No external libraries or images. Write each file completely with write_file, one file per call. Keep the code compact but working.'
def run_turn(model,label,prompt,deadline,minfree):
    api=[{'role':'system','content':B.sysprompt()+'\nYou also have write_file (save a complete file) and read_code (read a saved game file). You cannot run code; the user opens the game in Chrome and tells you about errors.'},{'role':'user','content':prompt}]
    steps=0;final='';err=None;aborted=None
    for _ in range(8):
        if time.time()>deadline: aborted='time cap'; break
        if B2.free_pct()<minfree: aborted='memory under %d%%'%minfree; break
        try: m=chat(model,api)
        except Exception as e: err=str(e)[:200]; break
        calls=m.get('tool_calls') or [];c=m.get('content') or ''
        if not calls and c:
            tc=B.parse_text(c) or []
            if tc: calls=tc;c=''
        if not calls: final=c[:300];break
        keep=[]
        for x in calls:
            n=x['function']['name']
            try: a=json.loads(x['function'].get('arguments') or '{}')
            except Exception: a={}
            steps+=1; out=exec_tool(n,a) if n in NAMES else 'Unknown tool'
            xs=json.loads(json.dumps(x))
            if n=='write_file' and isinstance(a,dict): xs['function']['arguments']=json.dumps({'path':a.get('path'),'content':'[saved]'})
            keep.append(xs); api_tool={'role':'tool','tool_call_id':x['id'],'name':n,'content':str(out)[:9000]}
            api.append({'role':'assistant','content':None,'tool_calls':[xs]}); api.append(api_tool)
    return {'steps':steps,'final':final,'error':err,'aborted':aborted}
def run(label,model):
    global SPARK,MAXTOK,DIR
    SPARK=(label=='Spark'); MAXTOK=3000 if label.startswith('Bonsai') else 8000 if not SPARK else 12000
    DIR=BIG+'/'+label; shutil.rmtree(DIR,ignore_errors=True); os.makedirs(DIR)
    out={'model':label,'id':model,'free_before':B2.free_pct(),'turns':[]}
    t0=time.time(); deadline=t0+1200; minfree=20
    if label=='ornith-9b' and out['free_before']<55: out['skipped']='not enough free memory to start'; return out
    try: chat(model,[{'role':'user','content':'hi'}]); out['start_secs']=round(time.time()-t0,1)
    except Exception as e: out['start_error']=str(e)[:200]; return out
    out['free_after_load']=B2.free_pct(); t0=time.time(); deadline=t0+1200
    prompt=TASK%label; minfree_seen=100
    for turn in range(1,7):
        r=run_turn(model,label,prompt,deadline,minfree); files,feats=snapshot(); n,errs=jserrors()
        fr=B2.free_pct(); minfree_seen=min(minfree_seen,fr)
        r.update({'turn':turn,'secs':round(time.time()-t0,1),'files':{k:v.count('\n')+1 for k,v in files.items()},'js_errors':n,'js_error_sample':errs[:3],'features':sum(feats.values()),'free':fr}); out['turns'].append(r)
        print(label,'turn',turn,'files',list(files),'js_errors',n,'features',sum(feats.values()),'/12','secs',r['secs'],'free',fr,r['aborted'] or '',r['error'] or '',flush=True)
        if r['aborted'] or r['error']: break
        missing=[k for k,v in feats.items() if not v]
        if n==0 and not missing and {'index.html','game.js','style.css'}<=set(files): break
        if time.time()>deadline: break
        listing=', '.join('%s (%d lines)'%(k,v.count('\n')+1) for k,v in files.items()) or 'no files yet'
        prompt=('Continue building "Space Defender" in Projects/model-picker/bench/big/%s/ (original brief: %s)\n\nFiles saved so far: %s.\n'%(label,TASK%label,listing))
        if not {'index.html','game.js','style.css'}<=set(files): prompt+='Still missing files: %s. Create them with write_file.\n'%', '.join({'index.html','game.js','style.css'}-set(files))
        if n: prompt+='When I opened index.html in Chrome these errors were reported:\n'+'\n'.join(errs[:3])+'\nUse read_code to look at the file, then fix it by saving the complete corrected file with write_file.\n'
        if missing: prompt+='Features still missing (as far as I can tell): '+', '.join(missing)+'. Add them.\n'
    files,feats=snapshot(); n,errs=jserrors()
    out.update({'final_files':{k:v.count('\n')+1 for k,v in files.items()},'final_loc':sum(v.count('\n')+1 for v in files.values()),'final_js_errors':n,'final_js_error_sample':errs[:3],'features':feats,'features_count':sum(feats.values()),'total_secs':round(time.time()-t0,1),'free_min_seen':minfree_seen,'free_end':B2.free_pct(),'path':DIR+'/index.html'})
    json.dump(out,open(HOME+'/Projects/model-picker/bench/result4-%s.json'%label,'w'),indent=1)
    return out
if __name__=='__main__':
    o=run(sys.argv[1],sys.argv[2])
    if 'features_count' not in o: json.dump(o,open(HOME+'/Projects/model-picker/bench/result4-%s.json'%sys.argv[1],'w'),indent=1)
