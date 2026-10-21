const canvas = document.getElementById('game');
const ctx = canvas.getContext('2d');
const scoreEl = document.getElementById('score');
const livesEl = document.getElementById('lives');

let score = 0;
let lives = 3;
let shipX = canvas.width / 2 - 15;
let shipY = canvas.height - 60;
let speed = 5;
let keys = {};
let bullets = [];
let enemies = [];
let shootCooldown = 0;
const shootInterval = 15;
let enemySpawnTimer = 0;
const enemySpawnInterval = 60;

function drawShip() {
    ctx.fillStyle = '#00ff00';
    ctx.beginPath();
    ctx.moveTo(shipX, shipY);
    ctx.lineTo(shipX - 20, shipY + 15);
    ctx.lineTo(shipX + 20, shipY + 15);
    ctx.closePath();
    ctx.fill();
}

function updateShip() {
    if (keys['ArrowLeft'] || keys['a'] || keys['A']) {
        shipX -= speed;
    }
    if (keys['ArrowRight'] || keys['d'] || keys['D']) {
        shipX += speed;
    }
    if (keys['ArrowUp'] || keys['w'] || keys['W']) {
        shipY -= speed;
    }
    if (keys['ArrowDown'] || keys['s'] || keys['S']) {
        shipY += speed;
    }
    if (shipX < 0) shipX = 0;
    if (shipX > canvas.width) shipX = canvas.width;
    if (shipY < 0) shipY = 0;
    if (shipY > canvas.height) shipY = canvas.height;
}

function shoot() {
    bullets.push({ x: shipX, y: shipY - 25, speed: 10 });
}

function updateBullets() {
    for (let i = bullets.length - 1; i >= 0; i--) {
        const b = bullets[i];
        b.y -= b.speed;
        if (b.y < 0) {
            bullets.splice(i, 1);
        }
    }
}

function drawBullets() {
    ctx.fillStyle = '#ffff00';
    for (const b of bullets) {
        ctx.beginPath();
        ctx.arc(b.x, b.y, 3, 0, Math.PI * 2);
        ctx.fill();
    }
}

function spawnEnemy() {
    const x = Math.random() * (canvas.width - 30) + 15;
    enemies.push({ x: x, y: -30, speed: 2 + Math.random() * 2 });
}

function drawEnemies() {
    ctx.fillStyle = '#ff0000';
    for (const e of enemies) {
        ctx.beginPath();
        ctx.arc(e.x, e.y, 10, 0, Math.PI * 2);
        ctx.fill();
    }
}

function updateEnemies() {
    for (let i = enemies.length - 1; i >= 0; i--) {
        const e = enemies[i];
        e.y += e.speed;

        if (e.y > canvas.height) {
            enemies.splice(i, 1);
        } else if (e.x < shipX - 20 && e.x > shipX + 20 && e.y < shipY + 15) {
            enemies.splice(i, 1);
            lives--;
            livesEl.textContent = 'Lives: ' + lives;
            if (lives <= 0) {
                lives = 0;
                livesEl.textContent = 'Lives: ' + lives;
            }
        }
    }
}

function gameLoop() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    updateShip();
    drawShip();
    updateBullets();
    drawBullets();
    updateEnemies();
    drawEnemies();

    if (shootCooldown > 0) {
        shootCooldown--;
    }
    if (keys[' '] && shootCooldown === 0) {
        shoot();
        shootCooldown = shootInterval;
    }

    enemySpawnTimer++;
    if (enemySpawnTimer >= enemySpawnInterval) {
        spawnEnemy();
        enemySpawnTimer = 0;
    }

    requestAnimationFrame(gameLoop);
}

window.addEventListener('keydown', (e) => {
    keys[e.key] = true;
    if (e.key === ' ' && !e.repeat) {
        e.preventDefault();
    }
});

window.addEventListener('keyup', (e) => {
    keys[e.key] = false;
});

scoreEl.textContent = 'Score: ' + score;
livesEl.textContent = 'Lives: ' + lives;

gameLoop();
