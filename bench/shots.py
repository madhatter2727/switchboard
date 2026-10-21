import json,subprocess,time,base64,sys,os,urllib.request,websocket
CH='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'; OUT=os.path.expanduser('~/Projects/model-picker/bench/big/screens/')
def run(label,path,port):
    p=subprocess.Popen([CH,'--headless=new','--disable-gpu','--no-first-run','--disable-backgrounding-occluded-windows','--disable-renderer-backgrounding','--disable-background-timer-throttling','--user-data-dir=/tmp/mpshot-'+label,'--remote-debugging-port=%d'%port,'--remote-allow-origins=http://127.0.0.1:%d'%port,'--window-size=1000,800','about:blank'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    notes=[]
    try:
        for _ in range(40):
            try: tabs=json.loads(urllib.request.urlopen('http://127.0.0.1:%d/json'%port).read()); break
            except Exception: time.sleep(0.5)
        ws=websocket.create_connection([t for t in tabs if t['type']=='page'][0]['webSocketDebuggerUrl'],timeout=30); n=[0]; errs=[]
        def cmd(m,**a):
            n[0]+=1; ws.send(json.dumps({'id':n[0],'method':m,'params':a}))
            while True:
                r=json.loads(ws.recv())
                if r.get('method')=='Runtime.exceptionThrown': errs.append(r['params']['exceptionDetails'].get('text','')+str(r['params']['exceptionDetails'].get('exception',{}).get('description',''))[:120])
                if r.get('id')==n[0]: return r.get('result',{})
        ev=lambda js:cmd('Runtime.evaluate',expression=js,returnByValue=True).get('result',{}).get('value')
        def shot(name):
            ev('document.body.offsetHeight');notes.append(name+':'+str(ev("Array.from(document.querySelectorAll('.overlay')).map(e=>e.id+':'+e.className).join(' | ')")));d=cmd('Page.captureScreenshot',format='png',fromSurface=True)['data']; open(OUT+'%s-%s.png'%(label,name),'wb').write(base64.b64decode(d))
        def key(k,code,vk,down=True,text=None):
            cmd('Input.dispatchKeyEvent',type='keyDown' if down else 'keyUp',key=k,code=code,windowsVirtualKeyCode=vk,**({'text':text} if text and down else {}))
        def tap(k,code,vk,hold=0.1,text=None): key(k,code,vk,True,text); time.sleep(hold); key(k,code,vk,False)
        cmd('Runtime.enable'); cmd('Page.enable'); cmd('Page.bringToFront'); cmd('Emulation.setFocusEmulationEnabled',enabled=True); cmd('Emulation.setDeviceMetricsOverride',width=1000,height=800,deviceScaleFactor=1,mobile=False)
        cmd('Page.navigate',url='file://'+path); time.sleep(2.5)
        shot('1-start')
        visible=lambda s:ev("Array.from(document.querySelectorAll('button,div,h1,h2,p')).some(e=>e.offsetParent!==null&&getComputedStyle(e).display!=='none'&&getComputedStyle(e).visibility!=='hidden'&&/%s/i.test(e.childNodes.length&&Array.from(e.childNodes).filter(c=>c.nodeType==3).map(c=>c.textContent).join('')))"%s)
        # start: Enter, Space, then click a start-like button if still on start screen
        tap('Enter','Enter',13,text='\r'); time.sleep(0.5); tap(' ','Space',32,text=' '); time.sleep(0.5)
        ev("(()=>{const b=Array.from(document.querySelectorAll('button')).find(b=>b.offsetParent!==null&&/start|play|begin/i.test(b.textContent));if(b)b.click();return !!b})()")
        time.sleep(0.8)
        for i in range(6):
            key('ArrowLeft','ArrowLeft',37); time.sleep(0.25); key('ArrowLeft','ArrowLeft',37,False)
            key('ArrowRight','ArrowRight',39); time.sleep(0.35); key('ArrowRight','ArrowRight',39,False)
            key(' ','Space',32,True,' '); time.sleep(0.3); key(' ','Space',32,False)
        key(' ','Space',32,True,' '); time.sleep(1.5); shot('2-gameplay'); key(' ','Space',32,False)
        tap('p','KeyP',80,text='p'); time.sleep(0.6); shot('3-pause'); tap('p','KeyP',80,text='p')
        # idle until game over (up to 70 s), shoot nothing
        over=False
        for i in range(35):
            time.sleep(2)
            if visible('game over'): over=True; break
        time.sleep(0.5); shot('4-gameover' if over else '4-after70s')
        notes.append('gameover_seen=%s'%over); notes.append('runtime_errors=%s'%errs[:3])
        ws.close()
    finally: p.terminate(); time.sleep(1)
    return notes
if __name__=='__main__':
    print(sys.argv[1],run(sys.argv[1],sys.argv[2],int(sys.argv[3])))
