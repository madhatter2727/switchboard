// Space Defender - single-file game logic
const C=document.getElementById('c'),ctx=C.getContext('2d');
const W=600,H=700;
let state='start',score=0,lives=3,wave=1,highScore=+localStorage.getItem('sd_hs')||0,hpWave=1;

// audio context for beeps
let ac=null;function beep(freq,dur){try{if(!ac)ac=new AudioContext();const o=ac.createOscillator(),g=ac.createGain();o.connect(g);g.connect(ac.destination);o.frequency.value=freq;o.type='square';o.start();g.gain.setValueAtTime(.08,ac.currentTime);g.gain.exponentialRampToValueAtTime(.001,ac.currentTime+dur);o.stop(ac.currentTime+dur)}catch(e){}}

// keys
const KEYS={};document.addEventListener('keydown',e=>{KEYS[e.key]=true;if(['ArrowUp','ArrowDown','ArrowLeft','ArrowRight',' '].includes(e.key))e.preventDefault();if(e.key==='p'||e.key==='P'){togglePause()}},false);document.addEventListener('keyup',e=>{KEYS[e.key]=false});

let paused=false;function togglePause(){if(state!=='playing')return;if(paused){paused=false;displayMsg('Paused');}else{paused=true;displayMsg('Paused - press P to resume');}}}

// player
const p={x:W/2,y:H-60,speed:5,ship:[],bullets:[],w=32,h=32};
function initPlayer(){p.x=W/2;p.y=H-60;updateShip();}
function updateShip(){for(let i=p.ship.length-1;i>=0;i--){if(p.ship[i].y<p.h)p.ship.splice(i,1)}}

// enemies - 3 types
const ENEMY_TYPES={chaser:{hp:2,speed:2,color:'#ff4466',score:100},weaver:{hp:1,speed:1.5,color:'#44cc88',score:80},drone:{hp:3,speed:.8,color:'#ffaa00',score:200}};
let enemies=[],enemyBullets=[];

function spawnEnemy(type){const t=ENEMY_TYPES[type]||ENEMY_TYPES.chaser;enemies.push({x:t.x||Math.random()*W,t.y:-16,tx:t.tx||Math.random()*W-.5*W,tw:t.tw||Math.random()*.5+W,type,typeData:{hp:t.hp,speed:t.speed,color:t.color,score:t.score},t:0});}

// powerups
let powerups=[];const PU_TYPES={heal:{color:'#44ff88',name:'HEAL'},bomb:{color:'#ff44ff',name:'BOMB'},shield:{color:'#44ffff',name:'SHIELD'}};

function spawnPowerup(){if(Math.random()>.52)return;if(Math.random()>.96){powerups.push({x:Math.random()*W,y:-16,tx:Math.random()*W-.3*W,tw:.3*W+10,type:'heal',t:0});}else if(Math.random()>.48){powerups.push({x:Math.random()*W,y:-16,tx:Math.random()*W-.25*W,tw:.25*W+8,type:'bomb',t:0});}else{powerups.push({x:Math.random()*W,y:-16,tx:Math.random()*W-.35*W,tw:.35*W+6,type:'shield',t:0});}}}

// waves
function nextWave(){hpWave++;const n=Math.min(4+wave,20);for(let i=0;i<n;i++){if(i<1)spawnEnemy('chaser');else if(i<4)spawnEnemy('weaver');else spawnEnemy('drone')}};wave++;beep(600,.05);

// draw ship
function drawShip(){ctx.save();const c=p.ship[0]?.color||'#33ccff';ctx.fillStyle=c;for(let i=0;i<p.ship.length;i++){const s=p.ship[i];ctx.beginPath();ctx.moveTo(s.x,s.y-s.h/2);ctx.lineTo(s.x+s.w/2,s.y+s.h/2);ctx.lineTo(s.x-s.w/2,s.y+s.h/2);ctx.closePath();ctx.fill()}ctx.restore()}

// draw enemies
function drawEnemies(){for(let e of enemies){const d=e.typeData;ctx.fillStyle=d.color;if(d.hp>1)ctx.globalAlpha=.5;ctx.beginPath();ctx.arc(e.x,e.ty,d.w||8,0,Math.PI*2);ctx.fill();if(d.hp<=1&&d.hp>0)ctx.strokeStyle='#ff0';ctx.lineWidth=1.5;ctx.stroke()}ctx.globalAlpha=1}

// draw powerups
function drawPowerups(){for(let pu of powerups){const d=PU_TYPES[pu.type];ctx.fillStyle=d.color;ctx.beginPath();ctx.arc(pu.x,pu.ty,d.w||6,0,Math.PI*2);ctx.fill()}}

// main loop
let lastT=0;function tick(now){if(state!=='playing')return;const dt=Math.min((now-lastT)/1000,.04);lastT=now;update(dt);draw();requestAnimationFrame(tick)}

function update(dt){
  // player movement (arrows + WASD)
  if(KEYS['ArrowUp']||KEYS['w'])p.y-=p.speed;if(KEYS['ArrowDown']||KEYS['s'])p.y+=p.speed;
  if(KEYS['ArrowLeft']||KEYS['a'])p.x-=p.speed;if(KEYS['ArrowRight']||KEYS['d'])p.x+=p.speed;
  p.x=Math.max(12,p.x);p.x=Math.min(W-12,p.x);p.y=Math.max(12,p.y);p.y=Math.min(H-8,p.y);

  // shoot on space
  if(KEYS[' ']||KEYS['Spacebar']){shoot();KEYS[' ']=false;KEYS['Spacebar']=false;}

  // update ship parts
  for(let s of p.ship){s.x+=s.vx;s.y+=s.vy}updateShip();

  // bullets
  for(let b of p.bullets){b.x+=b.vx;b.y-=b.vy;if(b.y<-10||b.x<0||b.x>W)p.bullets.splice(p.bullets.indexOf(b),1)}

  // enemies - chaser moves toward player, weaver sine wave, drone slow straight
  for(let i=enemies.length-1;i>=0;i--){const e=enemies[i];e.t+=dt;if(e.type==='chaser'){e.x+=(p.x-e.x)*.025;e.ty+=e.speed*dt}if(e.type==='weaver'){e.ty+=e.speed*dt;e.x+=Math.sin(e.t*3)*1.8}if(e.type==='drone'){e.x+=e.speed*Math.cos(e.t);e.ty+=e.speed*dt}
  if(e.ty>H+20){enemies.splice(i,1);score-=50;if(score<0)score=0;beep(200,.04)}

  // enemy bullets
  for(let i=enemyBullets.length-1;i>=0;i--){const b=enemyBullets[i];b.x+=b.vx;b.y+=b.vy;if(b.y>H+20||b.x<0||b.x>W)enemyBullets.splice(i,1)}

  // powerups
  for(let i=powerups.length-1;i>=0;i--){const pu=powerups[i];pu.t+=dt;pu.x+=(pu.tx-pu.x)*.025;pu.ty+=pu.speed*dt;if(pu.ty>H+20)powerups.splice(i,1)}

  // collisions: bullet vs enemy
  for(let i=enemies.length-1;i>=0;i--){const e=enemies[i];for(let j=p.bullets.length-1;j>=0;j--){const b=p.bullets[j];if(Math.hypot(b.x-e.x,b.y-e.ty)<e.w+3){p.bullets.splice(j,1);enemies.splice(i,1);score+=e.typeData.score;beep(800,.06)}}}

  // collisions: enemy bullet vs player
  for(let i=enemyBullets.length-1;i>=0;i--){const b=enemyBullets[i];if(Math.hypot(b.x-p.x,b.y-p.y)<p.w/2+4){lives--;beep(150,.1);enemyBullets.splice(i,1);if(lives<=0)gameOver()}}

  // collisions: enemy vs player
  for(let i=enemies.length-1;i>=0;i--){const e=enemies[i];if(Math.hypot(e.x-p.x,e.ty-p.y)<e.w/2+4){enemies.splice(i,1);lives--;beep(150,.1);if(lives<=0)gameOver()}}

  // collisions: powerup vs player
  for(let i=powerups.length-1;i>=0;i--){const pu=powerups[i];if(Math.hypot(pu.x-p.x,pu.ty-p.y)<pu.w/2+4){powerups.splice(i,1);applyPowerup(pu.type)}}

  // spawn enemies
  if(enemies.length<Math.min(3+wave*2,30)){nextWave()}

  // spawn powerups occasionally
  if(Math.random()>.98)spawnPowerup();
}

function shoot(){const b={x:p.x,y:p.y,vx:0,vy:-10,w:3,h:12,color:'#ffff44'};p.bullets.push(b);beep(1200,.05)}

function applyPowerup(type){if(type==='heal'){lives=Math.min(lives+1,5);beep(900,.08)}if(type==='bomb'){score+=500;for(let e of enemies)enemies.splice(enemies.indexOf(e),1);beep(2000,.04)}if(type==='shield'){p.ship.push({x:p.x,y:p.y,vx:0,vy:0,color:'#44ffff',w:30,h:30})}}

function draw(){
  ctx.fillStyle='#0b0d30';ctx.fillRect(0,0,W,H);
  // stars
  for(let i=0;i<50;i++){const s=Math.random()*2+.5;ctx.fillStyle=`rgba(255,255,255,.${.1+.05*Math.sin(Date.now()/1000+i)})`;ctx.fillRect(Math.random()*W,Math.random()*H,s,s)}
  drawShip();
  for(let e of enemies){const d=e.typeData;ctx.fillStyle=d.color;if(d.hp>1)ctx.globalAlpha=.6;ctx.beginPath();ctx.arc(e.x,e.ty,d.w||8,0,Math.PI*2);ctx.fill()}ctx.globalAlpha=1
  for(let b of p.bullets){ctx.strokeStyle=b.color||'#ffff44';ctx.lineWidth=2;ctx.beginPath();ctx.moveTo(b.x-b.w/2,b.y-b.h/2);ctx.lineTo(b.x+b.w/2,b.y+b.h/2);ctx.stroke()}
  for(let b of enemyBullets){ctx.strokeStyle='#ff6644';ctx.lineWidth=1.5;ctx.beginPath();ctx.arc(b.x,b.y,3,0,Math.PI*2);ctx.fill()}
  for(let pu of powerups){const d=PU_TYPES[pu.type];ctx.fillStyle=d.color||'white';ctx.beginPath();ctx.arc(pu.x,pu.ty,d.w||6,0,Math.PI*2);ctx.fill()}}

  // HUD
  ctx.fillStyle='#fff';ctx.font='14px Courier New';ctx.fillText(`Score: ${score}`,10,20);ctx.fillText(`Wave: ${wave}`,W-80,20);ctx.fillText(`Lives: ${lives}`,10,H-25);
  if(p.ship.length>1){ctx.fillStyle='#44ffff';ctx.font='bold 12px Courier New';ctx.fillText('SHIELD',W-70,H-25)}

  // overlay text
  const o=document.getElementById('overlay');if(state==='start'){o.style.display='flex';document.getElementById('op2').textContent=`Score: ${score} | Wave: ${wave}`;document.getElementById('ohint').textContent='Press any key to start'}else if(state==='gameover'){o.style.display='flex';document.getElementById('op2').textContent=`Game Over! Score: ${score}`;document.getElementById('ohint').textContent=highScore<score?(highScore=score,'High Score!',false):''}
  else if(paused){o.style.display='flex';document.getElementById('op2').textContent='PAUSED';document.getElementById('ohint').textContent='Press P to resume'}else o.style.display='none'
}

function gameOver(){state='gameover';beep(100,.5)}

// start screen
initPlayer();draw();requestAnimationFrame(tick);
