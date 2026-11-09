// Fake OpenAI-compatible model for Code mode's Big change / New project tests (no real model). Port 18931.
// Plan prompt -> 3 steps (a step containing "FAIL" if the idea says "partway"). Split prompt -> 2 smaller steps.
// Step prompt -> creates src/<slug>.js (empty SEARCH = new file); a step with FAIL in it gets an edit that never applies.
// MODE=slow waits 60 s on step edits (tests Stop). Every call is logged to stdout.
import http from 'http';
const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 30) || 'step';
let n = 0;
http.createServer((req, res) => {
  let b = ''; req.on('data', (c) => (b += c)); req.on('end', () => {
    if (req.url.endsWith('/models')) { res.end(JSON.stringify({ data: [{ id: 'fake' }] })); return; }
    n++; const msgs = JSON.parse(b || '{}').messages || []; const u = msgs[msgs.length - 1]?.content || ''; let content, slow = false;
    if (/Break the goal into/.test(u)) {
      const partway = /partway/i.test(u);
      content = partway ? '1. Draw a blue square\n2. Add a score label FAIL\n3. Make the background dark' : '1. Draw a blue square\n2. Add a score label\n3. Make the background dark';
      console.log(`call ${n}: plan (${partway ? 'with a failing step' : 'all good'})`);
    } else if (/Split it into/.test(u)) {
      content = /FAIL/.test(u) ? '1. Add an empty score label\n2. Fill the score label FAIL' : '1. Part one\n2. Part two';
      console.log(`call ${n}: split`);
    } else {
      const ask = (u.match(/Change request: (.*)/) || [])[1] || 'step';
      if (/FAIL/.test(ask)) content = '*** UPDATE: src/nope.js\n<<<<<<< SEARCH\nthis line is not there\n=======\nx\n>>>>>>> REPLACE';
      else content = `*** UPDATE: src/${slug(ask)}.js\n<<<<<<< SEARCH\n=======\n// ${ask}\nexport const done = true;\n>>>>>>> REPLACE`;
      slow = process.env.MODE === 'slow';
      console.log(`call ${n}: step "${ask}"${/FAIL/.test(ask) ? ' (bad edit)' : ''}`);
    }
    setTimeout(() => res.end(JSON.stringify({ choices: [{ message: { content }, finish_reason: 'stop' }] })), slow ? 60000 : 300);
  });
}).listen(18931, '127.0.0.1', () => console.log('fake build model on 127.0.0.1:18931'));
