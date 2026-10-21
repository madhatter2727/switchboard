import json,os,re,sys,time,shutil,urllib.request,subprocess
import bench5 as T, bench2 as B2
D=T.D; HOME=T.HOME
SYS='You write compact, correct browser game code. Reply with COMPLETE files only. For each file you change, write a line "=== FILE: name ===" followed by one fenced code block with the entire file. Only include files that change. No explanations.'
SPEC='''Game: "Space Defender", a canvas game in 3 files: index.html (a <canvas id="game" width="800" height="600">, <link rel="stylesheet" href="style.css"> and <script src="game.js"></script> at the end of body), style.css, game.js. Rules for the code: draw EVERYTHING on the canvas (all text with ctx.fillText, exactly in the formats "Score: 0", "Lives: 3", "Wave: 1"); game.js must use only element ids that exist in index.html; use requestAnimationFrame; keys: ArrowLeft/ArrowRight or A/D move the ship, Space shoots; use e.key (so ' ' is space) and track pressed keys in an object. No external libraries or images. Dark background (#000), bright coloured shapes (fillRect).'''
STEPS=[
 'Step 1 goal: index.html + style.css + game.js. Draw a bright ship (a rectangle or triangle near the bottom centre) that moves left and right with the arrow keys or A/D and stays on screen. Nothing else yet.',
 'Step 2 goal: pressing and holding Space fires bullets upward from the ship (small bright rectangles, at most one every 150 ms); remove bullets that leave the screen.',
 'Step 3 goal: add ONE enemy type: red squares that spawn at random x at the top and fall down. A bullet hitting an enemy destroys both and adds 10 to the score. Draw "Score: N" at the top-left with fillText.',
 'Step 4 goal: add lives. Start with 3 lives, draw "Lives: N" at the top-right. If an enemy reaches the bottom or touches the ship, lose a life and remove it. At 0 lives stop the game and draw "GAME OVER" with "Final score" and "Press Enter to restart"; Enter (or Space) restarts with score 0 and 3 lives.',
 'Step 5 goal: add waves. Draw "Wave: N" under the score. The wave number goes up by 1 every 15 seconds, and each wave enemies spawn faster and fall faster. Reset the wave on restart.',
 'Step 6 goal: add 3 enemy types with different colours and movement, each with a "type" field: type "basic" (red, falls straight), type "zigzag" (orange, falls while moving side to side with Math.sin), type "fast" (yellow, small, falls twice as fast). Spawn them randomly.',
 'Step 7 goal: add power-ups. When an enemy is destroyed there is a 25% chance it drops a green falling square. Catching it with the ship gives rapid fire for 8 seconds (shoot every 60 ms) and shows the text "POWER-UP: RAPID FIRE" at the top centre for 2 seconds.',
 'Step 8 goal: (a) a start screen drawn on the canvas with the text "SPACE DEFENDER" and "Press Enter to start" - the game does not run until Enter is pressed; (b) pressing P pauses and resumes, drawing "PAUSED" while paused (everything freezes); (c) save the high score in localStorage under the key "highScore" whenever a game ends and draw "High: N" at the bottom-left; (d) WebAudio beeps using an AudioContext and createOscillator: a short beep when shooting and a lower beep when an enemy is destroyed (create the AudioContext after the first key press).'
]
def files_now(): return {f:open(D+'/'+f).read() for f in ('index.html','style.css','game.js') if os.path.exists(D+'/'+f)}
def ask(prompt):
    body={'model':'bonsai-2-9b','messages':[{'role':'system','content':SYS},{'role':'user','content':prompt}],'max_tokens':4000,'temperature':0.3,'stream':True}
    r=urllib.request.Request('http://127.0.0.1:7777/v1/chat/completions',json.dumps(body).encode(),{'content-type':'application/json'})
    t0=time.time(); text=''
    try:
        for line in urllib.request.urlopen(r,timeout=300):
            if time.time()-t0>900: break
            line=line.decode(errors='ignore').strip()
            if line.startswith('data:') and '[DONE]' not in line:
                try: text+=json.loads(line[5:])['choices'][0]['delta'].get('content') or ''
                except Exception: pass
    except Exception as e: text+='\n[request error %s]'%e
    return text,round(time.time()-t0,1)
def apply(text,step):
    got={}
    for m in re.finditer(r'=== FILE:\s*([\w.]+)\s*===\s*```[\w]*\n(.*?)(?:```|\Z)',text,re.S): got[m.group(1)]=m.group(2)
    if not got:
        m=re.findall(r'```[\w]*\n(.*?)```',text,re.S)
        if m and step>1: got['game.js']=max(m,key=len)
    for k,v in got.items():
        if k in ('index.html','style.css','game.js'): open(D+'/'+k,'w').write(v)
    return list(got)
def show(files): return '\n\n'.join('--- %s ---\n%s'%(k,v) for k,v in files.items())
def main(start=1):
    log=[]; last_ok=start-1; t_all=time.time(); minfree=100; port=9400
    for step in range(start,9):
        goal=STEPS[step-1]; ok=False; tries=[]
        for attempt in (1,2,3):
            if B2.free_pct()<20: log.append({'abort':'memory under 20%'}); json.dump(log,open(HOME+'/Projects/model-picker/bench/result5.json','w'),indent=1); return log,last_ok
            cur=files_now()
            if attempt==1: prompt=SPEC+'\n\n'+(('Current files (working):\n'+show(cur)+'\n\n') if cur else '')+goal+'\nKeep everything that already works.'
            else: prompt=SPEC+'\n\nCurrent files:\n'+show(cur)+'\n\n'+goal+'\n\nI ran it in Chrome and checked it. It is NOT working yet:\n- '+'\n- '.join(tries[-1]['problems'][:5])+'\nFix exactly these problems and reply with the complete corrected files that change.'
            text,secs=ask(prompt); changed=apply(text,step)
            port+=1; res=T.judge(step,files_now(),'s%d'%step,port); res.update({'attempt':attempt,'model_secs':secs,'changed':changed,'free':B2.free_pct()}); tries.append(res); minfree=min(minfree,res['free'])
            print('step',step,'attempt',attempt,'pass',res['pass'],'changed',changed,'secs',secs,'problems',res['problems'][:3],'free',res['free'],flush=True)
            if res['pass']:
                ok=True; sd=D+'/steps/step%d'%step; shutil.rmtree(sd,ignore_errors=True); os.makedirs(sd)
                for f,v in files_now().items(): open(sd+'/'+f,'w').write(v)
                last_ok=step; break
        log.append({'step':step,'pass':ok,'tries':tries})
        json.dump({'log':log,'last_ok':last_ok,'min_free':minfree,'secs':round(time.time()-t_all)},open(HOME+'/Projects/model-picker/bench/result5.json','w'),indent=1)
        if not ok:
            if last_ok:
                for f,v in {f:open(D+'/steps/step%d/%s'%(last_ok,f)).read() for f in os.listdir(D+'/steps/step%d'%last_ok)}.items(): open(D+'/'+f,'w').write(v)
            break
        time.sleep(15)
    json.dump({'log':log,'last_ok':last_ok,'min_free':minfree,'secs':round(time.time()-t_all),'done':True},open(HOME+'/Projects/model-picker/bench/result5.json','w'),indent=1)
    return log,last_ok
if __name__=='__main__': main(int(sys.argv[1]) if len(sys.argv)>1 else 1)
