// Space Defender - browser game
const canvas = document.getElementById('game');
const ctx = canvas.getContext('2d');
const overlay = document.getElementById('overlay');
const overlayText = document.getElementById('overlay-text');
const overlaySub = document.getElementById('overlay-sub');
const overlayBtn = document.getElementById('overlay-btn');
const startScreen = document.getElementById('start-screen');
const gameOverScreen = document.getElementById('game-over-screen');
const highScoreEl = document.getElementById('high-score');

const W = 480, H = 640;
canvas.width = W; canvas.height = H;

// State
let state = 'start'; // start, play, paused, over
let score = 0, lives = 3, highScore = parseInt(localStorage.getItem('spaceDefenderHigh') || '0', 10);
let wave = 0, waveActive = false, waveTimer = 0, spawnQueue = [];
let powerUps = [];
let bullets = [];
let enemies = [];
let particles = [];
let player = { x: W/2, y: H-70, speed: 5, cooldown: 0, size: 18, invuln: 0 };
let keys = {};
let audioCtx = null;

// Enemy types
const ENEMY_TYPES = {
  grunt: { size: 16, hp: 2, speed: 1.2, color: '#ff6b6b', pattern: 'straight' },
  zigzag: { size: 14, hp: 1, speed: 1.6, color: '#ffd93d', pattern: 'zigzag' },
  swarm:  { size: 12, hp: 1, speed: 1.0, color: '#6bcf97', pattern: 'sine' }
};

// Audio
function initAudio() {
  try { audioCtx = new (window.AudioContext || window.webkitAudioContext)(); } catch (e) { audioCtx = null; }
}
function beep(freq, dur, type = 'square', vol = 0.08) {
  if (!audioCtx) return;
  const o = audioCtx.createOscillator(), g = audioCtx.createGain();
  o.type = type; o.frequency.value = freq;
  g.gain.value = vol;
  o.connect(g); g.connect(audioCtx.destination);
  o.start();
  g.gain.exponentialRampToValueAtTime(0, audioCtx.currentTime + dur);
  o.stop(audio is undefined ? audioCtx.currentTime + dur : audioCtx.currentTime + dur);
}
const sfx = {
  shoot: () => beep(880, 0.08, 'square', 0.05),
  hit: () => beep(220, 0.12, 'sawtooth', 0.08),
  power: () => beep(660, 0.15, 'triangle', 0.08),
  over: () => beep(160, 0.4, 'sawtooth', 0.1),
  wave: () => beep(440, 0.2, 'square', 0.06)
};

// Input
window.addEventListener('keydown', e => {
  keys[e.key.toLowerCase()] = true;
  if ([' ','p'].includes(e.key.toLowerCase())) e.preventDefault();
  if (e.key === ' ' && state === 'start') startGame();
  if (e.key === 'p' && (state === 'play' || state === 'paused')) togglePause();
});
window.addEventListener('keyup', e => { keys[e.key.toLowerCase()] = false; });

function startGame() {
  initAudio();
  score = 0; lives = 3; wave = 0; waveActive = false;
  powerUps = []; bullets = []; enemies = []; particles = [];
  player = { x: W/2, y: H-70, speed: 5, cooldown: 0, size: 18, invuln: 0 };
  state = 'play';
  overlay.style.display = 'none';
  spawnWave(0);
  gameLoop();
}

function togglePause() {
  if (state === 'play') { state = 'paused'; overlayText.textContent = 'Paused'; overlaySub.textContent = 'Press P to resume'; }
  else if (state === 'pausd') { state = 'play'; }
}

function spawnWave(w) {
  wave = w;
  waveActive = true;
  waveTimer = 0;
  sfx.wave();
  const count = 3 + w;
  for (let i = 0; i < count; i++) spawnEnemy();
  // initial powerup
  if (w >= 2) {
    powerUps.push({ type: 'health', x: W/2, y: H/2, size: 22, life: 120, bob: 0 });
  }
}

function spawnEnemy() {
  const types = ['grunt', 'zigzad', 'swarm'];
  let type = types[Math.floor(Math.random() * types.length)];
  let cfg = ENEMY_TYPES[type];
  const x = 30 + Math.random() * (W - 60);
  const y = H - 40 - Math.random() * 60;
  enemies.push({
    type, x, y, size: cfg.size, hp: cfg.hp, maxHp: cfg.hp, speed: cfg.speed,
    color: cfg.color, pattern: cfg.pattern,
    baseX: x, baseY: y, t: Math.random() * 6.28, dir: Math.random() < 0.5 ? 1 : -1
  });
}

function shoot() {
  if (player.cooldown > 0 || state !== 'play') return;
  player.cooldown = 12;
  bullets.push({ x: player.x, y: player.y - player.size, vy: -7, size: 4, life: 100 });
  sfx.shoot();
}

function update(dt) {
  // Player movement
  let mx = 0, my = 0;
  if (keys['arrowleft'] || keys['a']) mx -= 1;
  if (keys['arrowright'] || keys['d']) mx += 1;
  if (keys['arrowup'] || keys['w']) my -= 1;
  if (keys['arrowdown'] || keys['s']) my += 1;
  if (mx || my) {
    const len = Math.hypot(mx, my) || 1;
    player.x += (mx / len) * player.speed * dt;
    player.y += (my / len) * player.speed * dt;
  }
  player.x = Math.max(10, Math.min(W - 10, player.x));
  player.y = Math.max(10, Math.min(H - 10, player.y));
  if (player.cooldown > 0) player.cooldown -= dt;
  if (player.invuln > 0) player.invuln -= dt;

  // Shooting
  if (keys[' ']) shoot();

  // Bullets
  for (let i = bullets.length - 1; i >= 0; i--) {
    const b = bullets[i];
    b.y += b.vy; b.life -= 1;
    if (b.y < 0 || b.life <= 0) bullets.splice(i, 1);
  }

  // Enemies
  for (let i = enemies.length - 1; i >= 0; i--) {
    const e = enemies[i];
    e.t += dt * 0.02;
    const pat = e.pattern;
    if (pat === 'straight') {
      e.y += e.speed * dt;
      if (e.y > H - 20) e.y = H - 20;
    } else if (pat === 'zigzag') {
      e.x = e.baseX + Math.sin(e.t) * 30;
      e.y += e.speed * dt;
      if (e.y > H - 20) e.y = H - 20;
    } else if (pat === 'sine') {
      e.x = e.baseX + Math.sin(e.t) * 25;
      e.y += e.speed * dt;
      if (e.y > H - 20) e.y = H - 20;
    }
    // collision with bullets
    for (let j = bullets.length - 1; j >= 0; j--) {
      const b = bullets[j];
      if (Math.hypot(e.x - b.x, e.y - b.y) < (e.size + b.size) / 2) {
        e.hp -= 1;
        bullets.splice(j, 1);
        sfx.hit();
        if (e.hp <= 0) {
          score += 10 * (wave + 1);
          addParticles(e.x, e.y, e.color, 8);
          enemies.splice(i, 1);
        }
        break;
      }
    }
    // off screen
    if (e.y < -30) enemies.splice(i, 1);
  }

  // Powerups
  for (let i = powerUps.length - 1; i >= 0; i--) {
    const p = powerUps[i];
    p.bob += 0.05;
    p.life -= 1;
    if (p.life <= 0 || p.y < -20) { powerUps.splice(i, 1); continue; }
    // collect
    if (Math.hypot(player.x - p.x, player.y - p.y) < 30) {
      if (p.type === 'health') { lives = Math.min(5, lives + 1); }
      else if (p.type === 'score') { score += 50; }
      powerUps.splice(i, 1);
      sfx.power();
      addParticles(p.x, p.y, '#fff', 12);
    }
  }

  // Waves
  if (waveActive) {
    waveTimer += 1;
    // spawn enemies over time
    const interval = 60 - wave * 4;
    if (waveTimer >= interval && enemies.length < 8 + wave * 2) {
      spawnEnemy();
      waveTimer = 0;
    }
    if (waveTimer > 120) {
      // wave ends
      waveActive = false;
      wave++;
      if (wave >= 3) {
        // bonus
        score += 200;
      }
    }
  }

  // Particles
  for (let i = particles.length - 1; i >= 0; i--) {
    const p = particles[i];
    p.x += p.vx; p.y += p.vy; p.vy += 0.1; p.life -= 1;
    if (p.life <= 0) particles.splice(i, 1);
  }

  // Check lives
  if (lives <= 0) {
    state = 'over';
    sfx.over();
    if (score > highScore) {
      highScore = score;
      localStorage.setItem('spaceDefenderHigh', String(highScore));
    }
    document.getElementById('game-over-score').textContent = score;
    document.getElementById('game-over-high').textContent = highScore;
    overlay.style.display = 'flex';
    overlaySub.textContent = 'Game Over';
    overlayText.textContent = 'Final Score: ' + score;
    overlayBtn.textContent = 'Play Again';
    overlayBtn.onclick = startGame;
  }
}

function addParticles(x, y, color, n) {
  for (let i = 0; i < n; i++) {
    particles.push({
      x, y,
      vx: (Math.random() - 0.5) * 4,
      vy: (Math.random() - 0.5) * 4,
      life: 20 + Math.random() * 20,
      color
    });
  }
}

// Render
function draw() {
  ctx.clearRect(0, 0, W, H);

  // Background
  ctx.fillStyle = '#0a0e27';
  ctx.fillRect(0, 0, W, H);
  // stars
  ctx.fillStyle = '#ffffff';
  for (let i = 0; i < 30; i++) {
    const x = (i * 137) % W, y = (i * 211) % H;
    ctx.globalAlpha = 0.3 + (i % 5) * 0.1;
    ctx.fillRect(x, y, 2, 2);
  }
  ctx.globalAlpha = 1;

  // Powerups
  powerUps.forEach(p => {
    ctx.save();
    ctx.translate(p.x, p.y + Math.sin(p.bob) * 3);
    ctx.fillStyle = p.type === 'health' ? '#4dabf7' : '#ffd93d';
    ctx.beginPath();
    ctx.arc(0, 0, p.size, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = 'rgba(255,255,255,0.5)';
    ctx.beginPath();
    ctx.arc(-p.size*0.3, -p.size*0.3, p.size*0.4, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
  });

  // Bullets
  ctx.fillStyle = '#ffe66d';
  bullets.forEach(b => {
    ctx.beginPath();
    ctx.arc(b.x, b.y, b.size, 0, Math.PI * 2);
    ctx.fill();
  });

  // Enemies
  enemies.forEach(e => {
    ctx.fillStyle = e.color;
    ctx.beginPath();
    ctx.arc(e.x, e.y, e.size, 0, Math.PI * 2);
    ctx.fill();
    // hp indicator
    if (e.hp < e.maxHp) {
      ctx.fillStyle = '#ff4757';
      ctx.beginPath();
      ctx.arc(e.x, e.y, e.size + 2, 0, Math.PI * 2);
      ctx.globalAlpha = 0.5;
      ctx.fill();
      ctx.globalAlpha = 1;
    }
  });

  // Particles
  ctx.fillStyle = '#fff';
  particles.forEach(p => {
    ctx.globalAlpha = p.life / 40;
    ctx.fillRect(p.x, p.y, 3, 3);
  });
  ctx.globalAlpha = 1;

  // Player
  if (state === 'play' || state === 'paused') {
    const blink = state === 'paused' ? (Math.floor(Date.now() / 200) % 2 === 0) : true;
    if (blink) {
      ctx.fillStyle = '#00ff9d';
      ctx.beginPath();
      ctx.arc(player.x, player.y, player.size, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = '#ffffff';
      ctx.beginPath();
      ctx.arc(player.x - 3, player.y - 3, 3, 0, Math.PI * 2);
      ctx.arc(player.x + 3, player.y + 3, 3, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  // UI
  ctx.fillStyle = '#fff';
  ctx.font = '14px monospace';
  ctx.textAlign = 'left';
  ctx.fillText('Score: ' + score, 10, 20);
  ctx.fillText('Lives: ' + lives, 10, 40);
  ctx.fillText('Wave: ' + wave, 10, 60);
  ctx.fillText('High: ' + highScore, 10, 80);
  ctx.textAlign = 'right';
  ctx.fillText('Wave ' + wave + (waveActive ? ' active' : ''), W - 10, H - 10);
}

// Main loop
let last = 0;
function gameLoop(ts) {
  const dt = last ? (ts - last) / 16.67 : 1;
  last = ts;
  if (state === 'play') {
    update(dt);
    draw();
  } else if (state === 'paused') {
    draw();
  } else {
    draw();
  }
  requestAnimationFrame(gameLoop);
}

// Init
highScoreEl.textContent = highScore;
overlay.style.display = 'flex';
overlayText.textContent = 'Space Defender';
overlaySub.textContent = 'Arrow keys / WASD to move, Space to shoot, P to pause';
overlayBtn.textContent = 'Start';
overlayBtn.onclick = startGame;
gameLoop(0);