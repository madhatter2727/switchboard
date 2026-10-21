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

function gameLoop() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    updateShip();
    drawShip();
    requestAnimationFrame(gameLoop);
}

window.addEventListener('keydown', (e) => {
    keys[e.key] = true;
});

window.addEventListener('keyup', (e) => {
    keys[e.key] = false;
});

scoreEl.textContent = 'Score: ' + score;
livesEl.textContent = 'Lives: ' + lives;

gameLoop();
