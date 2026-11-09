// Fake OpenAI-compatible model for Code mode tests (no real model). Port 18931.
// Reply 1 per run has a wrong SEARCH (tests the retry); later replies make the score green. MODE=slow waits 60 s (tests Stop).
import http from 'http';
let n = 0;
const good = "*** UPDATE: src/hud.js\n<<<<<<< SEARCH\n  scoreColor: '#ffd84a', // points number in the score box (yellow)\n=======\n  scoreColor: '#39ff14', // points number in the score box (bright green)\n>>>>>>> REPLACE";
const bad = "*** UPDATE: src/hud.js\n<<<<<<< SEARCH\n  scoreColour: 'yellow',\n=======\n  scoreColour: 'green',\n>>>>>>> REPLACE";
http.createServer((req, res) => {
  let b = ''; req.on('data', (c) => (b += c)); req.on('end', () => {
    if (req.url.endsWith('/models')) { res.end(JSON.stringify({ data: [{ id: 'fake' }] })); return; }
    n++; const body = JSON.parse(b || '{}'); const fresh = !/previous attempt failed/.test(JSON.stringify(body.messages || ''));
    const content = fresh ? bad : good;
    const send = () => res.end(JSON.stringify({ choices: [{ message: { content }, finish_reason: 'stop' }] }));
    console.log(`call ${n} (${fresh ? 'first try: wrong SEARCH' : 'retry: good edit'})`);
    process.env.MODE === 'slow' ? setTimeout(send, 60000) : setTimeout(send, 1500);
  });
}).listen(18931, '127.0.0.1', () => console.log('fake model on 127.0.0.1:18931'));
