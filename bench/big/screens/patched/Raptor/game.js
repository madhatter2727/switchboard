// Space Defender - game logic
const canvas = document.getElementById('game-canvas');
const ctx = canvas.getContext('2d');
const W = canvas.width = 800;
const H = canvas.height = 600;

// DOM elements
const startScreen = document.getElementById('start-screen');
const pauseScreen = document.getElementById('pause-screen');
const gameOverScreen = document.getElementById('game-over-screen');
const startBtn = document.getElementById('start-btn');
const resumeBtn = document.getElementById('resume-btn');
const restartBtn = document.getElementById('restart-btn');
const finalScoreEl = document.getElementById('final-score');
const highScoreEl = document.getElementById('high-score');

// Game state
let state = 'start'; // start, playing, paused, over
let score = 0;
let highScore = parseInt(localStorage.getItem('spaceDefenderHighScore') || '0', 10);
let lives = 3;
let wave = 1;
let waveTimer = 0;
let spawnTimer = 0;
let powerUpTimer = 0;
let powerUp = null;
let keys = {};
let player = {
  x: W / 2, y: H / 2, w: 36, h: 36, speed: 5,
  cooldown: 0, shootDir: 0,
  power: 1
};
let bullets = [];
let enemies = [];
let particles = [];

// Audio (WebAudio beeps)
let audioCtx = null;
function initAudio() {
  if (!audioCtx) {
    try { audioCtx = new (window.AudioContext || window.webkitAudioContext)(); } catch (e) { audioCtx = null; }
  }
}
function beep(freq, duration, type = 'square', vol = 0.08) {
  if (!audioCtx) return;
  const osc = audioCtx.createOscillator();
  const gain = audioCtx.createGain();
  osc.type = type;
  osc.frequency.value = freq;
  gain.gain.value = vol;
  osc.connect(gain);
  gain.connect(audioCtx.destination);
  osc.start();
  gain.gain.exponentialRampToValueAtTime(0.0001, audioCtx.currentTime + duration);
  osc.stop(audioCtx.currentTime + duration);
}

// Input
window.addEventListener('keydown', (e) => {
  keys[e.key.toLowerCase()] = true;
  if (e.key === ' ') { e.preventDefault(); }
  if (e.key.toLowerCase() === 'p' && state === 'playing') {
    state = 'paused';
    pauseScreen.classList.remove('hidden');
  } else if (e.key.toLowerCase() === 'p' && state === 'paused') {
    state = 'playing';
    pauseScreen.classList.add('hidden');
  }
});
window.addEventListener('keyup', (e) => { keys[e.key.toLowerCase()] = false; });

startBtn.addEventListener('click', () => { initAudio(); startGame(); });
resumeBtn.addEventListener('click', () => { state = 'playing'; pauseScreen.classList.add('hidden'); });
restartBtn.addEventListener('click', () => { startGame(); });

function startGame() {
  state = 'playing';
  score = 0;
  lives = 3;
  wave = 1;
  waveTimer = 0;
  spawnTimer = 0;
  powerUp = null;
  bullets = [];
  enemies = [];
  particles = [];
  player.x = W / 2; player.y = H / 2;
  player.cooldown = 0;
  player.power = 1;
  startScreen.classList.add('hidden');
  gameOverScreen.classList.add('hidden');
  updateHighScore();
}

function updateHighScore() {
  if (score > highScore) {
    highScore = score;
    localStorage.setItem('spaceDefenderHighScore', String(highScore));
  }
  highScoreEl.textContent = highScore;
}

function update() {
  if (state !== 'playing') return;

  // Player movement
  let dx = 0, dy = 0;
  if (keys['arrowleft'] || keys['a']) dx -= 1;
  if (keys['arrowright'] || keys['d']) dx += 1;
  if (keys['arrowup'] || keys['w']) dy -= 1;
  if (keys['arrowdown'] || keys['s']) dy += 1;
  if (dx !== 0 && dy !== 0) { dx *= 0.707; dy *= 0.707; }
  player.x += dx * player.speed;
  player.y += dy * player.speed;
  player.x = Math.max(player.w / 2, Math.min(W - player.w / 2, player.x));
  player.y = Math.max(player.h / 2, Math.min(H - player.h / 2, player.y));

  // Shooting
  player.cooldown--;
  if ((keys[' '] || keys['space']) && player.cooldown <= 0) {
    player.cooldown = player.power === 1 ? 12 : 8;
    player.shootDir = dx !== 0 ? (dx > 0 ? 1 : -1) : 0;
    if (player.power === 1) {
      bullets.push({ x: player.x, y: player.y - player.h / 2, w: 6, h: 14, speed: 10, power: 1 });
    } else {
      bullets.push({ x: player.x, y: player.y - player.h / 2, w: 10, h: 18, speed: 12, power: 2 });
    }
    beep(660, 0.08, 'square', 0.06);
  }

  // Bullets
  for (let i = bullets.length - 1; i >= 0; i--) {
    const b = bullets[i];
    b.y -= b.speed;
    if (b.y < -b.h) bullets.splice(i, 1);
  }

  // Waves
  waveTimer++;
  if (waveTimer > 120) {
    wave++;
    waveTimer = 0;
    beep(440, 0.15, 'sine', 0.08);
  }

  // Spawning enemies
  spawnTimer++;
  const enemyCount = 2 + wave;
  if (spawnTimer >= 60 && enemies.length < enemyCount) {
    spawnTimer = 0;
    spawnEnemy();
  }

  // Power ups
  powerUpTimer++;
  if (powerUpTimer > 1800 && !powerUp) {
    powerUpTimer = 0;
    powerUp = { x: W / 2, y: H / 2, type: 'power', w: 24, h: 24, timer: 120 };
  }

  // Enemies
  for (let i = enemies.length - 1; i >= 0; i--) {
    const e = enemies[i];
    e.timer++;
    e.x += e.vx;
    e.y += e.vy;
    if (e.type === 'straight') {
      if (e.x < e.w / 2 || e.x > W - e.w / 2) e.vy *= -1;
    } else if (e.type === 'sine') {
      e.y += Math.sin(e.timer * 0.05) * 1.5;
    } else if (e.type === 'zigzag') {
      e.x += e.vx;
      e.y += e.vy;
      if (e.x < e.w / 2 || e.x > W - e.w / 2) { e.vx *= -1; e.y += 20; }
    }
    // Collision with bullets
    for (let j = bullets.length - 1; j >= 0; j--) {
      const b = bullets[j];
      if (Math.abs(b.x - e.x) < (b.w + e.w) / 2 && Math.abs(b.y - e.y) < (b.h + e.h) / 2) {
        bullets.splice(j, 1);
        e.hit = true;
        break;
      }
    }
    if (e.hit) {
      enemies.splice(i, 1);
      score += e.type === 'zigzag' ? 20 : 15;
      beep(330, 0.1, 'triangle', 0.07);
      addParticles(e.x, e.y, e.type === 'zigzag' ? '#ff66cc' : '#ffaa44', 12);
    } else if (e.x < -e.w / 2 || e.x > W + e.w / 2 || e.y < -e.h / 2 || e.y > H + e.h / 2) {
      enemies.splice(i, 1);
      lives--;
      beep(150, 0.2, 'sawtooth', 0.1);
      if (lives <= 0) {
        gameOver();
      }
    }
  }

  // Power up
  if (powerUp) {
    powerUp.timer--;
    if (powerUp.timer <= 0) {
      powerUp = null;
      player.power = 2;
      beep(880, 0.2, 'sine', 0.08);
    }
  }

  // Particles
  for (let i = particles.length - 1; i >= 0; i--) {
    const p = particles[i];
    p.x += p.vx;
    p.y += p.vy;
    p.vy += 0.1;
    p.life--;
    if (p.life <= 0) particles.splice(i, 1);
  }

  updateHighScore();
}

function spawnEnemy() {
  const types = ['straight', 'sine', 'zigzag'];
  const type = types[Math.floor(Math.random() * Math.min(types.length, wave))];
  let e;
  if (type === 'straight') {
    e = { type: 'straight', x: Math.random() * (W - 40) + 20, y: -30, w: 32, h: 32, vx: (Math.random() - 0.5) * 2, vy: 1.5, timer: 0 };
  } else if (type === 'sine') {
    e = { type: 'sine', x: Math.random() * (W - 40) + 20, y: H + 30, w: 30, h: 30, vx: 1, vy: 0, timer: 0 };
  } else {
    e = { type: 'zigzag', x: Math.random() * (W - 40) + 20, y: H + 30, w: 30, h: 30, vx: 1.5, vy: 1, timer: 0 };
  }
  enemies.push(e);
}

function addParticles(x, y, color, count) {
  for (let i = 0; i < count; i++) {
    particles.push({ x, y, vx: (Math.random() - 0.5) * 4, vy: (Math.random() - 0.5) * 4, life: 20, color });
  }
}

function gameOver() {
  state = 'over';
  finalScoreEl.textContent = score;
  gameOverScreen.classList.remove('hidden');
  beep(120, 0.4, 'sawtooth', 0.1);
}

function draw() {
  // Background
  ctx.fillStyle = '#05060f';
  ctx.fillRect(0, 0, W, H);

  // Stars
  ctx.fillStyle = '#3a4a8a';
  for (let i = 0; i < 50; i++) {
    const sx = (i * 137) % W;
    const sy = (i * 89) % H;
    ctx.fillRect(sx, sy, 2, 2);
  }

  // Power up
  if (powerUp) {
    ctx.fillStyle = powerUp.type === 'power' ? '#ffd166' : '#6ea8ff';
    ctx.beginPath();
    ctx.arc(powerUp.x, powerUp.y, powerUp.w / 2, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = '#fff';
    ctx.font = '14px sans-serif';
    ctx.fillText(powerUp.type === 'power' ? 'POWER' : 'POWER', powerUp.x - 10, powerUp.y + 5);
  }

  // Bullets
  ctx.fillStyle = '#6ea8ff';
  for (const b of bullets) {
    ctx.fillRect(b.x - b.w / 2, b.y - b.h / 2, b.w, b.h);
  }

  // Enemies
  for (const e of enemies) {
    ctx.fillStyle = e.type === 'straight' ? '#ff6666' : e.type === 'sine' ? '#cc66ff' : '#ffaa44';
    ctx.beginPath();
    ctx.arc(e.x, e.y, e.w / 2, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = '#fff';
    ctx.font = '12px sans-serif';
    ctx.fillText(e.type, e.x - 10, e.y + 4);
  }

  // Player
  ctx.fillStyle = '#6ea8ff';
  ctx.fillRect(player.x - player.w / 2, player.y - player.h / 2, player.w, player.h);
  ctx.fillStyle = '#fff';
  ctx.fillRect(player.x - player.w / 2 + 6, player.y - player.h / 2 + 6, player.w - 12, player.h - 12);

  // Particles
  for (const p of particles) {
    ctx.globalAlpha = p.life / 20;
    ctx.fillStyle = p.color;
    ctx.fillRect(p.x - 2, p.y - 2, 4, 4);
  }
  ctx.globalAlpha = 1;
}

function loop() {
  update();
  draw();
  requestAnimationFrame(loop);
}

loop();