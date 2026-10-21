import sys; sys.argv=['x']; 
exec(open('shots.py').read().split("if __name__")[0])
import json,subprocess,time,urllib.request,websocket
p=subprocess.Popen([CH,'--headless=new','--disable-gpu','--no-first-run','--user-data-dir=/tmp/mpshot-dbg','--remote-debugging-port=9335','--remote-allow-origins=http://127.0.0.1:9335','--window-size=1000,800','about:blank'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
try:
    for _ in range(40):
        try: tabs=json.loads(urllib.request.urlopen('http://127.0.0.1:9335/json').read()); break
        except Exception: time.sleep(.5)
    ws=websocket.create_connection([t for t in tabs if t['type']=='page'][0]['webSocketDebuggerUrl'],timeout=30); n=[0]
    def cmd(m,**a):
        n[0]+=1; ws.send(json.dumps({'id':n[0],'method':m,'params':a}))
        while True:
            r=json.loads(ws.recv())
            if r.get('id')==n[0]: return r.get('result',{})
    cmd('Page.navigate',url='file:///Users/madhatter2727/Projects/model-picker/bench/big/Raptor/index.html'); time.sleep(2)
    cmd('Page.navigate',url='file:///Users/madhatter2727/Projects/model-picker/bench/big/Bonsai-9B/index.html'); time.sleep(2)
    ev=lambda js:cmd('Runtime.evaluate',expression=js,returnByValue=True)['result'].get('value')
    a=cmd('Page.captureScreenshot',format='png')['data']
    print(ev("(()=>{const b=document.getElementById('startBtn');try{startGame()}catch(e){return 'ERR '+e.message+' '+(e.stack||'').split('\\n')[1]};return document.getElementById('startScreen').style.display+'/'+document.getElementById('gameScreen').style.display})()"))
    time.sleep(2); b=cmd('Page.captureScreenshot',format='png')['data']; print('same',a==b)
    open('/tmp/dbg-b.png','wb').write(__import__('base64').b64decode(b))
finally: p.terminate()
