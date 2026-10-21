const canvas = document.getElementById('canvas');
const ctx = canvas.getContext('2d');
let width = canvas.width = window.innerWidth;
let height = canvas.height = window.innerHeight;
let player, enemies, particles, powerups, scores, lives, score, highScore, paused, gameOver, startScreen, overlay;

function resize() {
    width = canvas.width = window.innerWidth;
    height = canvas.height = window.innerHeight;
}
resize(); window.addEventListener('resize', resize);

function init() {
    player = { x: width/2 - 50, y: height - 100, w: 50, h: 50, dx: 0, dy: 0, color: '#0ff' };
    enemies = [];
    particles = [];
    powerups = [];
    scores = { player: 0, enemies: 0 };
    lives = 3;
    score = 0;
    highScore = localStorage.getItem('spaceDefenderHighScore') || '0';
    paused = false;
    gameOver = false;
    startScreen = true;
    overlay = document.getElementById('overlay');
    document.getElementById('start-screen').style.display = 'flex';
}

function createEnemy(type) {
    const types = {
        'basic': { speed: 2, pattern: 'random', hp: 1 },
        'fast': { speed: 4, pattern: 'chase', hp: 1 },
        'tank': { speed: 1, pattern: 'circle', hp: 3 }
    };
    const t = types[type] || types['basic'];
    let x, y;
    if (Math.random() > 0.5) {
        x = Math.random() < 0.5 ? 0 : width;
        y = Math.random() < 0.5 ? 0 : height;
    } else {
        x = Math.random() < 0.5 ? 0 : width;
        y = Math.random() < 0.5 ? 0 : height;
    }
    return { x, y, w: 30, h: 30, dx: 0, dy: 0, speed: t.speed, hp: t.hp, color: '#f00', type };
}

function spawnEnemies(waves) {
    const count = waves * 2;
    for (let i = 0; i < count; i++) {
        enemies.push(createEnemy('basic'));
    }
}

function update() {
    if (gameOver || startScreen || paused) return;
    player.dx = 0; player.dy = 0;
    if (keys['w']) { player.dy = -5; }
    else if (keys['s']) { player.dy = 5; }
    else if (keys['arrowup']) { player.dy = -5; }
    else if (keys['arrowdown']) { player.dy = 5; }
    if (keys['a']) { player.dx = -5; }
    else if (keys['d']) { player.dx = 5; }
    else if (keys['arrowleft']) { player.dx = -5; }
    else if (keys['arrowright']) { player.dx = 5; }
    player.x += player.dx; player.y += player.dy;
    player.x = Math.max(0, Math.min(width - player.w, player.x));
    player.y = Math.max(0, Math.min(height - player.h, player.y));

    const keys = { w: keys.w, s: keys.s, a: keys.a, d: keys.d, arrowup: keys.arrowup, arrowdown: keys.arrowdown, arrowleft: keys.arrowleft, arrowright: keys.arrowright, space: keys.space, p: keys.p };
    if (keys.space) {
        enemies.forEach(e => { e.y -= e.speed; });
        if (e.y < 0) { e.y = height; e.dx = (Math.random() - 0.5) * 4; score += 10; }
    }
    enemies.forEach(e => {
        e.y -= e.speed;
        if (e.y < 0) { e.y = height; e.dx = (Math.random() - 0.5) * 4; }
        if (Math.abs(e.x - player.x) < 20 && Math.abs(e.y - player.y) < 20) {
            player.hp--;
            if (player.hp <= 0) { gameOver = true; }
        }
    });

    if (score > parseInt(highScore)) {
        localStorage.setItem('spaceDefenderHighScore', score);
        highScore = score;
    }

    particles.forEach(p => {
        p.y += p.dy;
        if (p.y > height) particles = particles.filter(p => p.y < height);
    });

    powerups.forEach(p => {
        p.y += p.dy;
        if (p.y > height) powerups = powerups.filter(p => p.y < height);
    });

    if (score > 100 && Math.random() > 0.5) {
        powerups.push({ x: Math.random() * width, y: Math.random() * height, w: 30, h: 30, color: '#ff0', type: 'health' });
    }

    if (score > 200 && Math.random() > 0.5) {
        powerups.push({ x: Math.random() * width, y: Math.random() * height, w: 30, h: 30, color: '#0f0', type: 'speed' });
    }

    if (score > 300 && Math.random() > 0.5) {
        powerups.push({ x: Math.random() * width, y: Math.random() * height, w: 30, h: 30, color: '#fff', type: 'shield' });
    }

    for (let i = powerups.length - 1; i >= 0; i--) {
        const p = powerups[i];
        if (Math.abs(p.x - player.x) < 20 && Math.abs(p.y - player.y) < 20) {
            if (p.type === 'health') player.hp = Math.min(player.hp + 1, 3);
            else if (p.type === 'speed') player.dx = 5;
            else if (p.type === 'shield') player.hp = 2;
            powerups = powerups.filter(p => p !== p);
        } else {
            powerups = powerups.filter(p => p.y > height);
        }
    }

    for (let i = enemies.length - 1; i >= 0; i--) {
        const e = enemies[i];
        if (Math.abs(e.x - player.x) < 20 && Math.abs(e.y - player.y) < 20) {
            player.hp--;
            if (player.hp <= 0) { gameOver = true; }
            enemies = enemies.filter(p => p !== p);
        } else {
            enemies = enemies.filter(p => p.y > height);
        }
    }

    ctx.clearRect(0, 0, width, height);
    ctx.fillStyle = player.color; ctx.fillRect(player.x, player.y, player.w, player.h);
    enemies.forEach(e => { ctx.fillStyle = e.color; ctx.fillRect(e.x, e.y, e.w, e.h); });
    particles.forEach(p => { ctx.fillStyle = p.color; ctx.fillRect(p.x, p.y, 4, 4); });
    powerups.forEach(p => { ctx.fillStyle = p.color; ctx.fillRect(p.x, p.y, p.w, p.h); });
}

function draw() {
    ctx.clearRect(0, 0, width, height);
    ctx.fillStyle = player.color; ctx.fillRect(player.x, player.y, player.w, player.h);
    enemies.forEach(e => { ctx.fillStyle = e.color; ctx.fillRect(e.x, e.y, e.w, e.h); });
    particles.forEach(p => { ctx.fillStyle = p.color; ctx.fillRect(p.x, p.y, 4, 4); });
    powerups.forEach(p => { ctx.fillStyle = p.color; ctx.fillRect(p.x, p.y, p.w, p.h); });
}

function keys = { w: false, s: false, a: false, d: false, arrowup: false, arrowdown: false, arrowleft: false, arrowright: false, space: false, p: false };
window.addEventListener('keydown', e => {
    if (e.code === 'Space') keys.space = true;
    else if (e.code === 'KeyP') keys.p = true;
    else if (e.key === 'w') keys.w = true;
    else if (e.key === 's') keys.s = true;
    else if (e.key === 'a') keys.a = true;
    else if (e.key === 'd') keys.d = true;
    else if (e.key === 'ArrowUp') keys.arrowup = true;
    else if (e.key === 'ArrowDown') keys.arrowdown = true;
    else if (e.key === 'ArrowLeft') keys.arrowleft = true;
    else if (e.key === 'ArrowRight') keys.arrowright = true;
});
window.addEventListener('keyup', e => {
    if (e.code === 'Space') keys.space = false;
    else if (e.code === 'KeyP') keys.p = false;
    else if (e.key === 'w') keys.w = false;
    else if (e.key === 's') keys.s = false;
    else if (e.key === 'a') keys.a = false;
    else if (e.key === 'd') keys.d = false;
    else if (e.key === 'ArrowUp') keys.arrowup = false;
    else if (e.key === 'ArrowDown') keys.arrowdown = false;
    else if (e.key === 'ArrowLeft') keys.arrowleft = false;
    else if (e.key === 'ArrowRight') keys.arrowright = false;
});

function startGame() {
    startScreen = false;
    paused = false;
    gameOver = false;
    init();
    overlay.style.display = 'none';
    document.getElementById('start-screen').style.display = 'none';
    document.getElementById('game-over-screen').style.display = 'none';
    document.getElementById('pause-overlay').style.display = 'none';
}

function restartGame() {
    startGame();
}

function togglePause() {
    paused = !paused;
    if (paused) {
        document.getElementById('pause-overlay').style.display = 'flex';
        document.getElementById('game-over-screen').style.display = 'none';
        document.getElementById('start-screen').style.display = 'none';
    } else {
        document.getElementById('pause-overlay').style.display = 'none';
        if (gameOver) {
            startGame();
        }
    }
}

function audioBeep() {
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.frequency.value = 800;
    gain.gain.value = 0.1;
    osc.start();
    setTimeout(() => osc.stop(), 300);
}

function updateScreen() {
    if (startScreen) {
        document.getElementById('start-screen').style.display = 'flex';
        document.getElementById('game-over-screen').style.display = 'none';
        document.getElementById('pause-overlay').style.display = 'none';
    } else if (gameOver) {
        document.getElementById('game-over-screen').style.display = 'flex';
        document.getElementById('start-screen').style.display = 'none';
        document.getElementById('pause-overlay').style.display = 'none';
    } else if (paused) {
        document.getElementById('pause-overlay').style.display = 'flex';
        document.getElementById('game-over-screen').style.display = 'none';
        document.getElementById('start-screen').style.display = 'none';
    } else {
        document.getElementById('game-over-screen').style.display = 'none';
    }
}

function gameLoop() {
    update();
    draw();
    requestAnimationFrame(gameLoop);
}

function createKeys() {
    return keys;
}

function audioBeep() {
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.frequency.value = 800;
    gain.gain.value = 0.1;
    osc.start();
    setTimeout(() => osc.stop(), 300);
}

function load() {
    gameLoop();
}

function main() {
    init();
    updateScreen();
    load();
}
