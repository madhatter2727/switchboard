// Space Defender - Game Logic
const canvas = document.getElementById('gameCanvas');
const ctx = canvas.getContext('2d');
const WIDTH = canvas.width = 800;
const HEIGHT = canvas.height = 600;

// Game state
let gameState = {
  running: false,
  paused: false,
  lives: 10,
  score: 0,
  highScore: localStorage.getItem('highScore') || 0,
  wave: 1,
  enemyCount: 0,
  enemies: [],
  projectiles: [],
  powerups: [],
  player: { x: WIDTH/2, y: HEIGHT - 100, width: 40, height: 40, speed: 7, angle: 0 }
};

// Input state
const keys = { ArrowUp: false, ArrowDown: false, ArrowLeft: false, ArrowRight: false,
  'w': false, 'a': false, 's': false, 'd': false, ' ': false, 'p': false };

// Enemy types
const enemyTypes = [
  { name: 'drone', color: '#ff4444', speed: 2, size: 20, pattern: 'straight' },
  { name: 'fighter', color: '#44ff44', speed: 3, size: 25, pattern: 'zigzag' },
  { name: 'bomber', color: '#ffff44', speed: 1.5, size: 30, pattern: 'circle' }
];

// Audio context for beeps
const audioCtx = new (window.AudioContext || window.webkitAudioContext)();

function playBeep(freq, duration, type) {
  if (audioCtx.state === 'suspended') audioCtx.resume();
  const osc = audioCtx.createOscillator();
  const gain = audioCtx.createGain();
  osc.frequency.setValueAtTime(freq, audioCtx.currentTime);
  gain.gain.setValueAtTime(0.1, audioCtx.currentTime);
  gain.gain.exponentialRampToValueAtTime(0.001, audioCtx.currentTime + duration);
  osc.connect(gain);
  osc.start();
  osc.stop(audioCtx.currentTime + duration);
}

function startGame() {
  gameState.running = true;
  gameState.paused = false;
  gameState.lives = 10;
  gameState.score = 0;
  gameState.highScore = Math.max(gameState.highScore, gameState.score);
  localStorage.setItem('highScore', gameState.highScore);
  gameState.wave = 1;
  gameState.enemies = [];
  gameState.projectiles = [];
  gameState.powerups = [];
  document.getElementById('startScreen').style.display = 'none';
  document.getElementById('gameScreen').style.display = 'block';
  document.getElementById('uiOverlay').style.display = 'block';
  document.getElementById('livesDisplay').textContent = `Lives: ${gameState.lives}`;
  document.getElementById('scoreDisplay').textContent = `Score: ${gameState.score}`;
  document.getElementById('highScoreDisplay').textContent = `High Score: ${gameState.highScore}`;
  document.getElementById('finalScore').textContent = '';
  updateScreen();
}

function gameOver() {
  gameState.running = false;
  document.getElementById('gameScreen').style.display = 'none';
  document.getElementById('gameOverScreen').style.display = 'block';
  document.getElementById('finalScore').textContent = gameState.score;
}

function updateScreen() {
  document.getElementById('livesDisplay').textContent = `Lives: ${gameState.lives}`;
  document.getElementById('scoreDisplay').textContent = `Score: ${gameState.score}`;
  document.getElementById('highScoreDisplay').textContent = `High Score: ${gameState.highScore}`;
}

function createEnemies() {
  const targetEnemies = Math.min(30 + gameState.wave * 5, 100);
  while (gameState.enemies.length < targetEnemies) {
    const typeIdx = Math.floor(Math.random() * enemyTypes.length);
    const enemy = {
      ...enemyTypes[typeIdx],
      x: Math.random() * (WIDTH - enemyTypes[typeIdx].size * 2),
      y: -50,
      vx: Math.random() * 2 - 1,
      vy: enemyTypes[typeIdx].speed,
      angle: Math.random() * Math.PI * 2,
      rotationSpeed: Math.random() * 0.05
    };
    gameState.enemies.push(enemy);
  }
}

function updateEnemies() {
  gameState.enemies.forEach(enemy => {
    if (gameState.paused) return;
    
    let dx = enemy.vx;
    let dy = enemy.vy;
    
    // Movement patterns
    if (enemy.pattern === 'straight') {
      enemy.x += dx;
    } else if (enemy.pattern === 'zigzag') {
      enemy.x += dx;
      enemy.y += Math.sin(Date.now() * 0.001 + enemy.angle) * 2;
    } else if (enemy.pattern === 'circle') {
      enemy.x += Math.cos(Date.now() * 0.001 + enemy.angle) * 1.5;
      enemy.y += Math.sin(Date.now() * 0.001 + enemy.angle) * 1.5;
    }
    
    // Bounce off walls
    if (enemy.x < 0 || enemy.x > WIDTH - enemyTypes[typeIdx].size) {
      enemy.vx *= -1;
    }
    if (enemy.y < 0) enemy.y = 0;
    if (enemy.y > HEIGHT) enemy.y = HEIGHT;
    
    // Remove if off screen
    if (enemy.y > HEIGHT + 50) gameState.enemies = gameState.enemies.filter(e => e !== enemy);
  });
}

function updatePlayer() {
  if (gameState.paused) return;
  
  if (keys.ArrowUp || keys.w) {
    gameState.player.y = Math.max(0, gameState.player.y - gameState.player.speed);
  }
  if (keys.ArrowDown || keys.s) {
    gameState.player.y = Math.min(HEIGHT - gameState.player.height, gameState.player.y + gameState.player.speed);
  }
  if (keys.ArrowLeft || keys.a) {
    gameState.player.x = Math.max(0, gameState.player.x - gameState.player.speed);
  }
  if (keys.ArrowRight || keys.d) {
    gameState.player.x = Math.min(WIDTH - gameState.player.width, gameState.player.x + gameState.player.speed);
  }
  
  // Shoot on spacebar
  if (keys.space && gameState.running && !gameState.paused) {
    gameState.projectiles.push({
      x: gameState.player.x,
      y: gameState.player.y - gameState.player.height,
      vx: Math.cos(gameState.player.angle) * 8,
      vy: Math.sin(gameState.player.angle) * 8,
      life: 60
    });
  }
}

function updateProjectiles() {
  gameState.projectiles.forEach(proj => {
    proj.x += proj.vx;
    proj.y += proj.vy;
    proj.life--;
    
    // Remove if off screen
    if (proj.x < 0 || proj.x > WIDTH || proj.y < 0 || proj.y > HEIGHT) {
      gameState.projectiles = gameState.projectiles.filter(p => p !== proj);
      return;
    }
    
    // Check collisions with enemies
    gameState.enemies.forEach(enemy => {
      if (enemy.y > proj.y && enemy.y < proj.y + 50 &&
          enemy.x > proj.x && enemy.x < proj.x + 50) {
        eliminateEnemy(enemy);
        gameState.score += 100;
        playBeep(800, 0.1, 'shoot');
        return;
      }
    });
  });
}

function eliminateEnemy(enemy) {
  gameState.enemies = gameState.enemies.filter(e => e !== enemy);
  gameState.score += 100;
  playBeep(800, 0.1, 'shoot');
  updateScreen();
  
  // Increase difficulty
  if (gameState.enemies.length === 0) {
    gameState.wave++;
    createEnemies();
  }
}

function updatePowerups() {
  gameState.powerups.forEach(powerup => {
    powerup.x += powerup.vx;
    powerup.y += powerup.vy;
    powerup.life--;
    
    if (powerup.type === 'health' && Math.random() < 0.01) {
      gameState.lives = Math.min(10, gameState.lives + 1);
      playBeep(1000, 0.2, 'powerup');
    }
    
    if (powerup.type === 'rapid' && Math.random() < 0.01) {
      gameState.player.speed = 12;
      playBeep(1000, 0.2, 'powerup');
    }
    
    // Remove if off screen
    if (powerup.y > HEIGHT + 50) {
      gameState.powerups = gameState.powerups.filter(p => p !== powerup);
      return;
    }
  });
}

function checkCollisions() {
  gameState.projectiles.forEach(proj => {
    gameState.enemies.forEach(enemy => {
      const dx = proj.x - enemy.x;
      const dy = proj.y - enemy.y;
      const dist = Math.sqrt(dx*dx + dy*dy);
      
      if (dist < proj.life + enemyTypes[enemyTypes.indexOf(enemy)].size) {
        eliminateEnemy(enemy);
      }
    });
  });
}

function draw() {
  // Clear screen
  ctx.fillStyle = '#000';
  ctx.fillRect(0, 0, WIDTH, HEIGHT);
  
  // Draw player
  ctx.fillStyle = '#00ffff';
  ctx.fillRect(gameState.player.x - gameState.player.width/2, gameState.player.y - gameState.player.height/2, 
               gameState.player.width, gameState.player.height);
  
  // Draw enemies
  gameState.enemies.forEach(enemy => {
    ctx.fillStyle = enemyTypes[enemyTypes.indexOf(enemy)].color;
    ctx.fillRect(enemy.x - enemyTypes[enemyTypes.indexOf(enemy)].size/2, enemy.y - enemyTypes[enemyTypes.indexOf(enemy)].size/2,
                 enemyTypes[enemyTypes.indexOf(enemy)].size, enemyTypes[enemyTypes.indexOf(enemy)].size);
  });
  
  // Draw projectiles
  gameState.projectiles.forEach(proj => {
    ctx.fillStyle = '#ffff00';
    ctx.fillRect(proj.x - 3, proj.y - 3, 6, 6);
  });
  
  // Draw powerups
  gameState.powerups.forEach(powerup => {
    ctx.fillStyle = powerup.type === 'health' ? '#00ff00' : '#ff00ff';
    ctx.fillRect(powerup.x - 10, powerup.y - 10, 20, 20);
  });
}

function loop() {
  if (gameState.running) {
    if (!gameState.paused) {
      updatePlayer();
      updateEnemies();
      updateProjectiles();
      updatePowerups();
      checkCollisions();
      draw();
      requestAnimationFrame(loop);
    }
  }
}

// Event listeners
document.getElementById('startBtn').addEventListener('click', startGame);
document.getElementById('restartBtn').addEventListener('click', startGame);
document.addEventListener('keydown', e => {
  keys[e.key] = true;
  if (e.key === 'p') {
    gameState.paused = !gameState.paused;
    if (gameState.paused) {
      document.getElementById('uiOverlay').style.display = 'block';
      document.getElementById('livesDisplay').textContent = `Lives: ${gameState.lives}`;
      document.getElementById('scoreDisplay').textContent = `Score: ${gameState.score}`;
      document.getElementById('highScoreDisplay').textContent = `High Score: ${gameState.highScore}`;
    } else {
      document.getElementById('uiOverlay').style.display = 'none';
    }
  }
  if (e.key === ' ' && gameState.running) {
    if (gameState.paused) {
      gameState.paused = false;
      document.getElementById('uiOverlay').style.display = 'none';
    } else {
      startGame();
    }
  }
});
document.addEventListener('keyup', e => keys[e.key] = false);

// Start the game loop
loop();
