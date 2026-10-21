import json,os,re,subprocess,time,base64,io,sys,shutil,urllib.request,socket
import websocket
from PIL import Image, ImageChops
ROOT=os.path.expanduser('~/Projects/model-picker/bench/big/Raptor-v2'); WORK=ROOT+'/work'; SNAP=ROOT+'/snapshots'; SC=ROOT+'/screens'
for d in (WORK,SNAP,SC): os.makedirs(d,exist_ok=True)
T0=time.time(); CAP=31*60
CH='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
MODEL='raptor-0.6-4b-jang_6m'; URL='http://127.0.0.1:1337/v1/chat/completions'
STEPS=[
 (3,"Add ONE enemy type: enemies (red circles or squares about 24px) spawn at the top at a random x every ~1 second and fall straight down at a steady speed. Keep them in an array named enemies. Remove an enemy from the array when it leaves the bottom of the canvas. Do not add collisions or scoring yet."),
 (3.5,"Add collisions and score. (1) Bullet-vs-enemy: loop over bullets and enemies; if their axis-aligned bounding boxes overlap, remove BOTH and do score += 10, then update the #score text as 'Score: N'. (2) Ship-vs-enemy: if the ship's bounding box overlaps an enemy, remove the enemy and do lives -= 1, then update the #lives text as 'Lives: N'. Use a helper function overlaps(a,b) with x,y,w,h rectangles; store w and h on the ship, bullets and enemies."),
 (4,'Add lives (start with 3), a game over state and restart. When lives reach 0, stop the game and show the DOM overlay #gameover-screen (class overlay, show by removing class hidden) with the final score and a button #restart-btn; pressing the button or Enter restarts a fresh game and hides the overlay.'),(5,"Add waves and difficulty: show 'Wave: N' in an element with id wave; enemies spawn faster and fall faster each wave; the wave advances every 15 seconds or after a set number of kills."),(6,'Add 3 enemy types with different look/speed/health: a small fast one (1 hit), a normal one (2 hits), and a large slow one (4 hits) worth more points. Mix them as waves progress.'),(7,'Add power-ups that drop from destroyed enemies sometimes: rapid-fire (timed), shield (absorbs one hit), and extra life. Draw them differently and apply them when the ship touches them.'),(8,"Final polish: high score saved in localStorage shown in element id highscore ('High: N'); a DOM start screen #start-screen (class overlay) with a button #start-btn shown at load (the game starts only after Start or Enter); pause with P toggling DOM overlay #pause-screen; and short WebAudio beeps (create the AudioContext only after the first key press/click) on shooting, explosion and power-up.")]
SYS="""You are a careful game developer. You build 'Space Defender', a 2D browser shooter, as exactly three files: index.html, style.css, game.js, opened directly from disk (file://), no libraries, no network.
Rules:
- index.html must contain <canvas id="game"> , <link rel="stylesheet" href="style.css"> and <script src="game.js"></script> placed at the end of body.
- Every id/class you use in CSS or JS must exist in index.html. Overlays use class "overlay" and a class "hidden" defined in style.css as .hidden{display:none !important}.
- Keep the code simple and compact. Do not remove features from earlier steps.
- Reply with the COMPLETE contents of all three files, each in this exact format and nothing else of importance:
### FILE: index.html
```html
...
```
### FILE: style.css
```css
...
```
### FILE: game.js
```javascript
...
```"""
PJ=ROOT+'/progress.json'; LOG=ROOT+'/driver.log'
prog={'started':time.strftime('%H:%M:%S'),'steps':{},'last_good_step':2,'status':'running','current':None,'mem_free_pct':{}}
def log(m):
    open(LOG,'a').write('[%5.0fs] %s\n'%(time.time()-T0,m))
def save():
    prog['elapsed_s']=round(time.time()-T0); json.dump(prog,open(PJ,'w'),indent=1)
def memfree():
    try:
        o=subprocess.run(['memory_pressure'],capture_output=True,text=True).stdout
        return int(re.search(r'free percentage: (\d+)%',o).group(1))
    except Exception: return -1
def files():
    return {n:open(WORK+'/'+n).read() if os.path.exists(WORK+'/'+n) else '' for n in ('index.html','style.css','game.js')}
def ask(prompt,tmo):
    body={'model':MODEL,'messages':[{'role':'system','content':SYS},{'role':'user','content':prompt}],'max_tokens':9000,'temperature':0.2,'reasoning_effort':'none','stream':False}
    r=urllib.request.Request(URL,json.dumps(body).encode(),{'content-type':'application/json'})
    return json.loads(urllib.request.urlopen(r,timeout=tmo).read())['choices'][0]['message']['content']
def parse(txt):
    out={}
    for m in re.finditer(r'###\s*FILE:\s*([\w.\-]+)\s*\n```[a-zA-Z]*\n(.*?)```',txt,re.S):
        out[m.group(1).strip()]=m.group(2)
    return out
def static_check():
    f=files(); p=[]
    h=f['index.html']
    if not re.search(r'<script[^>]+src=["\']game\.js["\']',h): p.append('index.html has no <script src="game.js">')
    if not re.search(r'<link[^>]+style\.css',h): p.append('index.html has no link to style.css')
    if 'id="game"' not in h and "id='game'" not in h: p.append('no <canvas id="game">')
    css=f['style.css']; js=f['game.js']
    for kind,name in set(re.findall(r'([#.])([A-Za-z_][\w-]*)\s*[{,:\s>.#\[]',re.sub(r'/\*.*?\*/','',css,flags=re.S)+' ')):
        if re.match(r'^\d',name): continue
        if kind=='#' and not re.search(r'id=["\']%s["\']'%re.escape(name),h) and name not in js: p.append('css #%s missing in html'%name)
        if kind=='.' and not re.search(r'class=["\'][^"\']*\b%s\b'%re.escape(name),h) and name not in js and name not in ('hidden',): p.append('css .%s unused/missing'%name)
    if 'hidden' in h and not re.search(r'\.hidden\s*\{[^}]*display\s*:\s*none',css): p.append('.hidden class not defined as display:none')
    for i in set(re.findall(r'getElementById\(\s*[\'"]([\w-]+)[\'"]\s*\)',js)):
        if not re.search(r'id=["\']%s["\']'%re.escape(i),h): p.append('JS getElementById("%s") has no element'%i)
    if step_ctx[0]>=3:
        if not re.search(r'enemies\s*=\s*\[|enemies\s*:\s*\[',js): p.append('there is no global array named enemies (declare let enemies = [])')
        if not re.search(r'enemies[^;]*\.splice|enemies\s*=\s*enemies\.filter',js): p.append('enemies are never removed from the enemies array')
    if step_ctx[0]>=3.5:
        if not re.search(r'for[^{]*(enemies|bullets)[^{]*\{[^}]*?for[^{]*(bullets|enemies)|forEach[^{]*\{[^}]*?(bullets|enemies)\.forEach',js,re.S): p.append('there is no bullet-vs-enemy collision loop (nested loop over bullets and enemies)')
        if not re.search(r'score\s*\+=\s*10|score\s*=\s*score\s*\+\s*10',js): p.append('score is never increased by 10')
        if not re.search(r'lives\s*(-=\s*1|--)|lives\s*=\s*lives\s*-\s*1',js): p.append('lives is never decreased on a ship hit')
        for m in re.finditer(r'(\w+(?:\.\w+)?)\s*<\s*([^&|;)]+?)\s*&&\s*\1\s*>\s*([^&|;)]+)',js): p.append('the ship-hit/overlap condition "%s" is impossible (x < a && x > b with a<b): use a proper AABB overlap test'%m.group(0)[:90])
    return p
step_ctx=[0]
# ---------- browser
class B:
    def __init__(s,port,label):
        s.errs=[];s.n=0;s.label=label
        s.p=subprocess.Popen([CH,'--headless=new','--disable-gpu','--no-first-run','--disable-backgrounding-occluded-windows','--disable-renderer-backgrounding','--disable-background-timer-throttling','--user-data-dir=/tmp/mpv2-'+label,'--remote-debugging-port=%d'%port,'--remote-allow-origins=http://127.0.0.1:%d'%port,'--window-size=1000,800','about:blank'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        for _ in range(40):
            try: tabs=json.loads(urllib.request.urlopen('http://127.0.0.1:%d/json'%port).read()); break
            except Exception: time.sleep(0.5)
        s.ws=websocket.create_connection([t for t in tabs if t['type']=='page'][0]['webSocketDebuggerUrl'],timeout=30)
        s.cmd('Runtime.enable');s.cmd('Page.enable');s.cmd('Page.bringToFront');s.cmd('Emulation.setFocusEmulationEnabled',enabled=True);s.cmd('Emulation.setDeviceMetricsOverride',width=1000,height=800,deviceScaleFactor=1,mobile=False)
    def cmd(s,m,**a):
        s.n+=1;s.ws.send(json.dumps({'id':s.n,'method':m,'params':a}))
        while True:
            r=json.loads(s.ws.recv())
            if r.get('method')=='Runtime.exceptionThrown':
                d=r['params']['exceptionDetails']; s.errs.append((d.get('text','')+' '+str(d.get('exception',{}).get('description',''))[:160]).strip())
            if r.get('method')=='Runtime.consoleAPICalled' and r['params']['type']=='error': s.errs.append('console.error '+str(r['params']['args'])[:120])
            if r.get('id')==s.n: return r.get('result',{})
    def ev(s,js): return s.cmd('Runtime.evaluate',expression=js,returnByValue=True).get('result',{}).get('value')
    def shot(s,name=None):
        d=base64.b64decode(s.cmd('Page.captureScreenshot',format='png',fromSurface=True)['data'])
        if name: open(SC+'/'+name+'.png','wb').write(d)
        return Image.open(io.BytesIO(d)).convert('RGB')
    def key(s,k,code,vk,down=True,text=None):
        s.cmd('Input.dispatchKeyEvent',type='keyDown' if down else 'keyUp',key=k,code=code,windowsVirtualKeyCode=vk,**({'text':text} if text and down else {}))
    def hold(s,k,code,vk,t,text=None):
        s.key(k,code,vk,True,text);time.sleep(t);s.key(k,code,vk,False)
    def tap(s,k,code,vk,text=None): s.hold(k,code,vk,0.08,text)
    def text(s): return s.ev("document.body.innerText") or ''
    def close(s):
        try: s.ws.close()
        except Exception: pass
        s.p.terminate();time.sleep(0.8)
def diff(a,b): 
    d=ImageChops.difference(a,b).convert('L').point(lambda v:255 if v>25 else 0)
    return sum(1 for v in d.getdata() if v)
def start_game(b):
    b.tap('Enter','Enter',13,text='\r');time.sleep(0.3)
    b.ev("(()=>{const x=document.getElementById('start-btn')||Array.from(document.querySelectorAll('button')).find(b=>b.offsetParent!==null&&/start|play|begin/i.test(b.textContent));if(x)x.click()})()");time.sleep(0.6)
def verify(step,tag):
    res={'errors':[],'checks':{},'problems':[]}
    step_ctx[0]=step;sp=static_check(); res['problems']+=sp
    port=9340+int(time.time())%400
    b=B(port,tag)
    try:
        b.cmd('Page.navigate',url='file://'+WORK+'/index.html');time.sleep(2)
        c=res['checks']
        if step>=8:
            c['start_screen_visible']=bool(re.search(r'start',b.text(),re.I)); b.shot('step%s-%s-start'%(step,tag))
            if not c['start_screen_visible']: res['problems'].append('no visible start screen at load')
        start_game(b)
        s0=b.shot('step%s-%s-0idle'%(step,tag))
        b.hold('ArrowRight','ArrowRight',39,0.9); s1=b.shot()
        b.hold('a','KeyA',65,0.9,text='a'); s2=b.shot()
        c['move_diff_right']=diff(s0,s1); c['move_diff_left_a']=diff(s1,s2)
        if step==1:
            if c['move_diff_right']<120: res['problems'].append('ArrowRight did not visibly change the canvas (diff %d)'%c['move_diff_right'])
            if c['move_diff_left_a']<120: res['problems'].append('A key did not visibly change the canvas (diff %d)'%c['move_diff_left_a'])
        elif c['move_diff_right']<120: res['problems'].append('screen looks frozen after start (diff %d)'%c['move_diff_right'])
        if step>=2:
            if step==2: pre=b.shot()
            sc0=b.text()
            for _ in range(4): b.tap(' ','Space',32,text=' ');time.sleep(0.12)
            b.key(' ','Space',32,True,' ');time.sleep(0.25);sh=b.shot('step%s-%s-shooting'%(step,tag));b.key(' ','Space',32,False)
            if step==2:
                c['shoot_diff']=diff(pre,sh)
                if c['shoot_diff']<60: res['problems'].append('Space did not change the canvas (no visible bullets)')
        def num(t,lab):
            m=re.search(lab+r'\s*:?\s*(\d+)',t,re.I); return int(m.group(1)) if m else None
        if step>=3:
            k0=b.shot();time.sleep(3.0);k1=b.shot('step%s-%s-enemies'%(step,tag));c['enemy_fall_diff']=diff(k0,k1)
            lens=[]
            for _ in range(2):
                time.sleep(8);lens.append(b.ev("typeof enemies!=='undefined'&&Array.isArray(enemies)?enemies.length:-1"))
            c['enemies_len_samples']=lens
            if c['enemy_fall_diff']<60: res['problems'].append('no visible movement on screen after 3s with no input: enemies are not spawning/falling (diff %d)'%c['enemy_fall_diff'])
            if lens[0]==-1: res['problems'].append('global array "enemies" not found')
            elif max(lens)>25: res['problems'].append('enemies array grows without bound (%s): enemies are not removed when off-screen'%lens)
            t=b.text()
            if step>=3.5 and num(t,'score') is None: res['problems'].append('no "Score: N" text found in page')
        if step>=3.5:
            sc_a=num(b.text(),'score');lv_a=num(b.text(),'lives');rose=False
            end=time.time()+32
            while time.time()<end and not rose:
                for k,code,vk,dur in (('ArrowLeft','ArrowLeft',37,0.9),('ArrowRight','ArrowRight',39,1.8),('ArrowLeft','ArrowLeft',37,0.9)):
                    b.key(' ','Space',32,True,' ');b.hold(k,code,vk,dur);b.key(' ','Space',32,False)
                    sn=num(b.text(),'score')
                    if sn is not None and sc_a is not None and sn>sc_a: rose=True;break
                    if time.time()>end: break
            b.shot('step%s-%s-score'%(step,tag));c['score_before']=sc_a;c['score_after']=num(b.text(),'score');c['score_rose']=rose
            if not rose: res['problems'].append('Score did not rise: bullets shot at enemies for 32s but score stayed %s'%c['score_after'])
            lv_now=num(b.text(),'lives');dropped=lv_now is not None and lv_a is not None and lv_now<lv_a
            end=time.time()+35;side=0
            while time.time()<end and not dropped:
                for k,code,vk,dur in (('ArrowLeft','ArrowLeft',37,1.5),('ArrowRight','ArrowRight',39,3.0)):
                    b.hold(k,code,vk,dur);ln=num(b.text(),'lives')
                    if ln is not None and ln<(lv_now if lv_now is not None else 99): dropped=True;break
                    if time.time()>end or re.search(r'game\s*over',b.text(),re.I): break
                if re.search(r'game\s*over',b.text(),re.I): break
            b.shot('step%s-%s-lives'%(step,tag));c['lives_before']=lv_a;c['lives_after']=num(b.text(),'lives');c['lives_dropped']=dropped or bool(re.search(r'game\s*over',b.text(),re.I))
            if not c['lives_dropped']: res['problems'].append('Lives did not drop: ship swept across the field for 35s without shooting but lives stayed %s'%c['lives_after'])
        if step>=4:
            if num(b.text(),'lives') is None: res['problems'].append('no "Lives: N" text')
            over=False;end=time.time()+(70 if step==4 else 55)
            while time.time()<end:
                if re.search(r'game\s*over',b.text(),re.I): over=True;break
                time.sleep(2)
            c['game_over_seen']=over
            if over:
                b.shot('step%s-%s-gameover'%(step,tag))
                b.tap('Enter','Enter',13,text='\r');time.sleep(0.5)
                b.ev("(()=>{const x=document.getElementById('restart-btn');if(x)x.click()})()");time.sleep(0.8)
                still=bool(re.search(r'game\s*over',b.text(),re.I)); c['restart_cleared_gameover']=not still
                if still: res['problems'].append('after Enter/#restart-btn the game over text is still visible')
                else: b.shot('step%s-%s-restarted'%(step,tag))
            else: res['problems'].append('game over never appeared within idle wait (lives not decreasing / no gameover overlay)')
        if step>=8:
            start_game(b);time.sleep(0.5)
            a=b.shot();b.tap('p','KeyP',80,text='p');time.sleep(0.5);pt=b.text();c['pause_text']=bool(re.search(r'paus',pt,re.I));b.shot('step%s-%s-pause'%(step,tag));b.tap('p','KeyP',80,text='p')
            if not c['pause_text']: res['problems'].append('P did not show a pause screen text')
        js=files()['game.js']
        kw={5:[r'wave'],6:[r'type|kind'],7:[r'power|shield|rapid'],8:[r'localStorage',r'AudioContext']}
        for k in range(5,int(step)+1):
            for pat in kw.get(k,[]):
                if not re.search(pat,js,re.I): res['problems'].append('game.js lacks %s (step %s)'%(pat,k))
        if step==5 and not re.search(r'wave\s*:?\s*\d',b.text(),re.I): res['problems'].append('no "Wave: N" text')
        res['errors']=list(dict.fromkeys(b.errs))[:6]
        if res['errors']: res['problems'].append('JS errors: '+'; '.join(res['errors'][:3]))
    except Exception as e:
        res['problems'].append('verify crashed: %r'%e); res['errors']=list(dict.fromkeys(b.errs))[:6]
    finally: b.close()
    res['ok']=not res['problems']; return res
def apply(txt):
    fs=parse(txt); got=[n for n in ('index.html','style.css','game.js') if n in fs and len(fs[n].strip())>20]
    for n in got: open(WORK+'/'+n,'w').write(fs[n])
    return got
def main():
    prog['mem_free_pct']['start']=memfree(); save()
    log('start mem free %s%%'%prog['mem_free_pct']['start'])
    if prog['mem_free_pct']['start']<25: prog['status']='aborted: low memory';save();return
    minmem=100
    for si,goal in STEPS:
        st={'attempts':[],'goal':goal};prog['steps'][str(si)]=st;prog['current']=si
        fails=0
        while fails<3:
            left=CAP-(time.time()-T0)
            if left<90: prog['status']='stopped: 45-min cap reached during step %s'%si;save();return finish()
            f=files()
            cur=''.join('### FILE: %s\n```\n%s\n```\n'%(n,f[n]) for n in f) if True else ''
            if fails==0:
                prompt=('Current files:\n'+cur+'\n' if cur else 'There are no files yet.\n')+'STEP %s GOAL: %s\nOutput the complete three files.'%(si,goal)
            else:
                prompt='Current files (they do NOT work yet):\n'+cur+'\nSTEP %s GOAL: %s\nProblems found by an automatic test:\n- %s\nFix these problems, keep everything else, output the complete three files.'%(si,goal,'\n- '.join(last['problems']))
            if fails: shutil.copytree(WORK,ROOT+'/failed-step%s-try%d'%(si,fails),dirs_exist_ok=True) if False else None
            t=time.time();at={'try':fails+1}
            try:
                txt=ask(prompt,min(420,left-30))
            except Exception as e:
                at['model_error']=repr(e);st['attempts'].append(at);fails+=1;last={'problems':['model request failed']};log('model err %r'%e);save();continue
            at['model_s']=round(time.time()-t);open(ROOT+'/raw-step%s-try%d.txt'%(si,fails+1),'w').write(txt)
            got=apply(txt);at['files_written']=got
            m=memfree();minmem=min(minmem,m if m>=0 else 100);prog['mem_free_pct']['min_seen']=minmem
            if len(got)<3 and not got:
                last={'problems':['reply had no parsable files; use the ### FILE format']}
            else:
                last=verify(si,'t%d'%(fails+1))
            at['verify']=last;st['attempts'].append(at);log('step %s try %d ok=%s problems=%s model=%ss mem=%s%%'%(si,fails+1,last['ok'],last['problems'],at['model_s'],m));save()
            if last['ok']:
                shutil.copytree(WORK,SNAP+'/step%s'%si,dirs_exist_ok=True);prog['last_good_step']=si;st['result']='pass';save();break
            fails+=1
            if m>=0 and m<12: prog['status']='aborted: low memory';save();return finish()
        else:
            st['result']='FAILED 3 times';prog['status']='stopped: step %s failed 3 times'%si;save();return finish()
    prog['status']='completed all 8 steps';save();finish()
def finish():
    g=prog['last_good_step']
    if g and os.path.isdir(SNAP+'/step%s'%g):
        for n in ('index.html','style.css','game.js'): shutil.copy(SNAP+'/step%s/%s'%(g,n),ROOT+'/'+n)
    prog['mem_free_pct']['end']=memfree();prog['finished']=time.strftime('%H:%M:%S');prog['current']=None;save();log('FINISHED '+prog['status'])
    open(ROOT+'/DONE','w').write(prog['status'])
if __name__=='__main__':
    try: main()
    except Exception as e:
        prog['status']='driver crashed: %r'%e;save();log('crash %r'%e);open(ROOT+'/DONE','w').write(prog['status'])
