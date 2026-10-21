import json,subprocess,time,base64,sys,os,re,shutil,urllib.request,websocket
import bench2 as B2
HOME=os.path.expanduser('~'); D=HOME+'/Projects/model-picker/bench/big/Bonsai-9B-v2'; OUT=D+'/proof/'; os.makedirs(OUT,exist_ok=True); os.makedirs(D+'/steps',exist_ok=True)
CH='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
HOOK='''window.__t=[];window.__osc=0;
for(const k of ['fillText','strokeText']){const o=CanvasRenderingContext2D.prototype[k];CanvasRenderingContext2D.prototype[k]=function(t){window.__t.push(String(t));if(window.__t.length>300)window.__t.splice(0,150);return o.apply(this,arguments)}}
for(const C of [window.AudioContext,window.webkitAudioContext]){if(C){const co=C.prototype.createOscillator;C.prototype.createOscillator=function(){window.__osc++;return co.apply(this,arguments)}}}
window.__px=function(){const c=document.querySelector('canvas');if(!c)return null;const w=200,h=150,t=document.createElement('canvas');t.width=w;t.height=h;const x=t.getContext('2d');x.drawImage(c,0,0,w,h);const d=x.getImageData(0,0,w,h).data;
const bg=[d[0],d[1],d[2]];let n=0,sx=0,sy=0,minY=h,maxY=-1,top=0,cols={},rows={};
for(let y=0;y<h;y++)for(let i=0;i<w;i++){const p=(y*w+i)*4,r=d[p],g=d[p+1],b=d[p+2];if(Math.abs(r-bg[0])+Math.abs(g-bg[1])+Math.abs(b-bg[2])>120&&(r+g+b)>200){n++;sx+=i;sy+=y;rows[y]=(rows[y]||0)+1;if(y<h*0.4)top++;cols[(r>>6)+','+(g>>6)+','+(b>>6)]=1}}
for(const y in rows){if(+y>=30&&rows[y]>=2){minY=Math.min(minY,+y);maxY=Math.max(maxY,+y)}}
return {n:n,cx:n?sx/n:-1,cy:n?sy/n:-1,minY:minY,maxY:maxY,top:top,cols:Object.keys(cols),hash:Array.from(d.filter((v,i)=>i%97==0)).join('').slice(0,400)}};'''
class Page:
    def __init__(s,port,label):
        s.p=subprocess.Popen([CH,'--headless=new','--disable-gpu','--no-first-run','--disable-backgrounding-occluded-windows','--disable-renderer-backgrounding','--user-data-dir=/tmp/mpv2-'+label,'--remote-debugging-port=%d'%port,'--remote-allow-origins=http://127.0.0.1:%d'%port,'--window-size=1000,800','about:blank'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        for _ in range(40):
            try: tabs=json.loads(urllib.request.urlopen('http://127.0.0.1:%d/json'%port).read()); break
            except Exception: time.sleep(.5)
        s.ws=websocket.create_connection([t for t in tabs if t['type']=='page'][0]['webSocketDebuggerUrl'],timeout=60); s.n=0; s.errs=[]
        s.cmd('Runtime.enable'); s.cmd('Page.enable'); s.cmd('Page.bringToFront'); s.cmd('Emulation.setDeviceMetricsOverride',width=1000,height=800,deviceScaleFactor=1,mobile=False)
        s.cmd('Page.addScriptToEvaluateOnNewDocument',source=HOOK)
    def cmd(s,m,**a):
        s.n+=1; s.ws.send(json.dumps({'id':s.n,'method':m,'params':a}))
        while True:
            r=json.loads(s.ws.recv()); me=r.get('method')
            if me=='Runtime.exceptionThrown':
                d=r['params']['exceptionDetails']; s.errs.append((d.get('exception',{}).get('description') or d.get('text',''))[:200])
            elif me=='Runtime.consoleAPICalled' and r['params']['type']=='error': s.errs.append('console.error: '+' '.join(str(a.get('value',a.get('description',''))) for a in r['params']['args'])[:200])
            elif me=='Log.entryAdded' and r['params']['entry']['level']=='error': s.errs.append('log: '+r['params']['entry']['text'][:200]+' '+r['params']['entry'].get('url','')[-40:])
            if r.get('id')==s.n: return r.get('result',{})
    def ev(s,js):
        r=s.cmd('Runtime.evaluate',expression=js,returnByValue=True); 
        if 'exceptionDetails' in r: return None
        return r.get('result',{}).get('value')
    def key(s,k,code,vk,down=True):
        a={'text':' ' if k==' ' else k} if (down and len(k)==1) else {}
        s.cmd('Input.dispatchKeyEvent',type='keyDown' if down else 'keyUp',key=k,code=code,windowsVirtualKeyCode=vk,**a)
    def hold(s,k,code,vk,t): s.key(k,code,vk,True); time.sleep(t); s.key(k,code,vk,False)
    def shot(s,name):
        d=s.cmd('Page.captureScreenshot',format='png')['data']; open(OUT+name+'.png','wb').write(base64.b64decode(d))
    def px(s): return s.ev('window.__px&&window.__px()')
    def text(s): return s.ev("(window.__t||[]).slice(-80).join(' | ')+' || '+document.body.innerText") or ''
    def close(s):
        try: s.ws.close()
        except Exception: pass
        s.p.terminate(); time.sleep(1)
def num(txt,word):
    m=re.findall(word+r'\D{0,6}(\d+)',txt,re.I); return int(m[-1]) if m else None
KEYS={'L':('ArrowLeft','ArrowLeft',37),'R':('ArrowRight','ArrowRight',39),'S':(' ','Space',32),'E':('Enter','Enter',13),'P':('p','KeyP',80),'a':('a','KeyA',65),'d':('d','KeyD',68)}
def sweep(pg,secs,restart=True,log=None):
    t0=time.time(); best={'score':0,'wave':0,'lives':None}; pg.key(*KEYS['S']); seen=[]; cols=set(); i=0
    while time.time()-t0<secs:
        k=KEYS['L'] if i%2==0 else KEYS['R']; pg.hold(*k,0.9); i+=1
        t=pg.text(); sc=num(t,'score'); wv=num(t,'wave'); lv=num(t,'lives')
        if sc is not None: best['score']=max(best['score'],sc)
        if wv is not None: best['wave']=max(best['wave'],wv)
        if lv is not None: best['lives']=lv
        if re.search(r'power',t,re.I): best['power_text']=True
        if re.search(r'game ?over',t,re.I) and restart: pg.hold(*KEYS['E'],0.1); pg.hold(*KEYS['S'],0.15); pg.key(*KEYS['S'])
        p=pg.px()
        if p: cols.update(p['cols'])
    pg.key(*KEYS['S'],down=False); best['colors']=len(cols); return best
def start_game(pg):
    pg.hold(*KEYS['E'],0.1); time.sleep(.3); pg.hold(*KEYS['S'],0.1); time.sleep(.3)
    pg.ev("(()=>{const b=Array.from(document.querySelectorAll('button')).find(b=>b.offsetParent!==null&&/start|play/i.test(b.textContent));if(b)b.click()})()")
def load(label,port):
    pg=Page(port,label); pg.cmd('Page.navigate',url='file://'+D+'/index.html'); time.sleep(2.5); return pg
def static_checks(files):
    probs=[]; html=files.get('index.html',''); js=files.get('game.js',''); css=files.get('style.css','')
    if not re.search(r'<script[^>]+src=["\']game\.js["\']',html): probs.append('index.html has no <script src="game.js"> tag')
    if not re.search(r'<link[^>]+style\.css',html): probs.append('index.html does not link style.css')
    if '<canvas' not in html: probs.append('index.html has no <canvas>')
    ids=set(re.findall(r'id=["\']([\w-]+)["\']',html)); classes=set(c for m in re.findall(r'class=["\']([^"\']+)["\']',html) for c in m.split())
    for m in re.findall(r'getElementById\(["\']([\w-]+)["\']\)',js):
        if m not in ids: probs.append('game.js uses id "%s" that does not exist in index.html'%m)
    for m in re.findall(r'querySelector(?:All)?\(["\']#([\w-]+)["\']\)',js):
        if m not in ids: probs.append('game.js queries #%s which does not exist'%m)
    for m in re.findall(r'(?<![\w.])#([a-zA-Z][\w-]*)\s*[{,:]',css):
        if m not in ids: probs.append('style.css styles #%s but index.html has no such id'%m)
    for m in re.findall(r'(?<![\w#])\.([a-zA-Z][\w-]*)\s*[{,:]',css):
        if m not in classes and not re.search(r'classList|className',js) : probs.append('style.css uses .%s but it is never used'%m)
    return probs
def judge(step,files,label,port):
    r={'step':step,'problems':[],'obs':{}}
    pr=static_checks(files); r['problems']+=pr
    pg=load(label,port)
    try:
        base=pg.px(); r['obs']['idle_pixels']=base['n'] if base else None; pg.shot('step%d-1-load'%step)
        if not base or base['n']<5: r['problems'].append('Nothing is drawn on the canvas after loading (no ship visible).')
        if step>=8:
            t=pg.text(); r['obs']['start_text']=bool(re.search(r'start',t,re.I))
            if not r['obs']['start_text']: r['problems'].append('No start screen: the text "start" is not shown before pressing a key.')
        if step>=2 or step==8: pass
        if step>=1 and step<8 or step==8:
            start_game(pg) if step>=8 else None
            time.sleep(.6); a=pg.px() or base
            pg.hold(*KEYS['R'],0.7); time.sleep(.1); b=pg.px() or a; pg.hold(*KEYS['L'],1.4); time.sleep(.1); c=pg.px() or b
            pg.hold(*KEYS['d'],0.8); time.sleep(.1); d=pg.px() or c
            r['obs']['cx']=[round(x['cx'],1) for x in (a,b,c,d)]
            if step==1 or True:
                if not (b['cx']-a['cx']>=3 or b['cx']-a['cx']<=-3 and False): 
                    if not (b['cx']-a['cx']>=3): r['problems'].append('ArrowRight does not move the ship right (centre x %.1f -> %.1f).'%(a['cx'],b['cx']))
                if not (c['cx']-b['cx']<=-3): r['problems'].append('ArrowLeft does not move the ship left (centre x %.1f -> %.1f).'%(b['cx'],c['cx']))
                if not (d['cx']-c['cx']>=3): r['problems'].append('The D key (WASD) does not move the ship right.')
            pg.shot('step%d-2-moved'%step)
        if step>=2:
            pg.hold(*KEYS['L'],0.3); time.sleep(.5); before=pg.px(); mins=[]; ns=[]; t0=time.time(); pg.key(*KEYS['S'])
            while time.time()-t0<1.2: p=pg.px(); mins.append(p['minY']); ns.append(p['n']); time.sleep(.12)
            pg.shot('step%d-3-shooting'%step); pg.key(*KEYS['S'],down=False)
            r['obs']['ship_top']=before['minY']; r['obs']['top_while_shooting']=min(mins)
            if step==2 and not (min(mins)<=before['minY']-8): r['problems'].append('Space does not create bullets above the ship (topmost drawn row stayed at %s).'%before['minY'])
        if step>=3:
            sw=sweep(pg,22 if step<5 else 40); r['obs']['sweep']=sw; pg.shot('step%d-4-play'%step)
            t=pg.text(); r['obs']['text']=t[:160]
            if step==3:
                if sw['score']<=0: r['problems'].append('Score never went above 0 during 22 seconds of moving and shooting (is there a "Score: N" drawn with fillText, and do bullets hit enemies?).')
            if step>=4:
                if sw['lives'] is None: r['problems'].append('No "Lives: N" text is drawn on the canvas.')
        if step==4:
            pg.close(); pg=load(label,port); start_game(pg); t0=time.time(); over=False; initial=num(pg.text(),'lives')
            while time.time()-t0<75:
                time.sleep(2)
                if re.search(r'game ?over',pg.text(),re.I): over=True; break
            r['obs']['game_over_seen']=over; r['obs']['lives_initial']=initial
            if over:
                pg.shot('step4-5-gameover'); pg.hold(*KEYS['E'],0.1); time.sleep(.5); pg.hold(*KEYS['S'],0.1); time.sleep(1.5)
                t=pg.px(); tx=pg.text(); ok=not re.search(r'game ?over',tx.split('||')[0][-300:],re.I) and t and t['n']>5
                r['obs']['restarted']=bool(ok)
                if not ok: r['problems'].append('Pressing Enter/Space on the game over screen does not restart the game.')
            else: r['problems'].append('With no input for 75 seconds, "Game Over" never appeared (lives should run out when enemies reach the bottom).')
        if step>=5:
            wv=r['obs']['sweep']['wave']
            if wv<2: r['problems'].append('The wave number never reached 2 in 40 seconds (draw "Wave: N", increase it every 15 seconds).')
        if step>=6:
            types=set(re.findall(r'type\s*[:=]\s*[\'"]?(\w+)',files.get('game.js','')))-{'string','number'}
            r['obs']['types_in_code']=sorted(types)[:6]
            if len(types)<3 and len(re.findall(r'zigzag|sine|diagonal|chase|homing|strafe',files.get('game.js',''),re.I))<2: r['problems'].append('Fewer than 3 distinct enemy types found in the code.')
            if r['obs']['sweep']['colors']<4: r['problems'].append('Only %d distinct colours seen on screen; 3 enemy types should look different.'%r['obs']['sweep']['colors'])
        if step==7 and not r['obs']['sweep'].get('power_text'): r['problems'].append('No power-up was observed during 40 s of play. Show text like "POWER-UP: RAPID FIRE" for 2 seconds when one is collected.')
        if step==8:
            hs=pg.ev("JSON.stringify(Object.fromEntries(Object.keys(localStorage).map(k=>[k,localStorage[k]])))"); r['obs']['localStorage']=hs
            if not (hs and re.search(r'high',hs,re.I)): r['problems'].append('Nothing saved in localStorage with "high" in the key.')
            r['obs']['oscillators']=pg.ev('window.__osc'); 
            if not r['obs']['oscillators']: r['problems'].append('No WebAudio oscillator beep was created (play a beep when shooting).')
            pg.key(*KEYS['S'],down=False); time.sleep(.5); pg.hold(*KEYS['P'],0.1); time.sleep(.8); h1=pg.px(); tp=pg.text(); time.sleep(1.2); h2=pg.px()
            r['obs']['pause_text']=bool(re.search(r'paus',tp,re.I)); r['obs']['frozen']=bool(h1 and h2 and h1['hash']==h2['hash']); pg.shot('step8-6-paused')
            if not r['obs']['pause_text']: r['problems'].append('Pressing P does not show "PAUSED".')
            if not r['obs']['frozen']: r['problems'].append('Pressing P does not freeze the game (screen kept changing).')
            pg.hold(*KEYS['P'],0.1)
        r['errors']=list(dict.fromkeys(pg.errs))[:3]
        for e in r['errors']: r['problems'].append('JavaScript error: '+e)
    finally: pg.close()
    r['pass']=not r['problems']; return r
