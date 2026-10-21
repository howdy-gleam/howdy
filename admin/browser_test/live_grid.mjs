// Checks the live grid follows a change made outside the app, through
// Chromium's DevTools protocol. Run the admin example first:
//
//   cd examples/admin && gleam dev
//   node admin/browser_test/live_grid.mjs
//
// It updates and inserts rows in the example's SQLite file with sqlite3, or
// with psql when PSQL_URL names the PostgreSQL server the example runs on,
// and expects the grid to show them, marked "changed", within a few seconds.

import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

const BASE = process.env.BASE_URL || 'http://127.0.0.1:8787';
const DATABASE = process.env.DATABASE || 'examples/admin/admin_example.sqlite';
const PSQL_URL = process.env.PSQL_URL || '';
const CHROMIUM = process.env.CHROMIUM || 'chromium';
const SHOT = process.env.SCREENSHOT || '';

const HELPERS = `
window.grid = () => document.querySelector('lustre-server-component')?.shadowRoot;
window.gridText = () => window.grid()?.textContent || '';
`;

async function launch() {
  const profile = mkdtempSync(join(tmpdir(), 'howdy-admin-'));
  const child = spawn(CHROMIUM, ['--headless=new', '--remote-debugging-port=0', '--no-first-run',
    '--no-default-browser-check', '--disable-gpu', `--user-data-dir=${profile}`, 'about:blank'], { stdio: 'ignore' });
  const portFile = join(profile, 'DevToolsActivePort');
  for (let i = 0; i < 100 && !existsSync(portFile); i++) await sleep(100);
  const [port] = readFileSync(portFile, 'utf8').split('\n');
  const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
  const socket = new WebSocket(version.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  let next = 1;
  const pending = new Map();
  const listeners = new Set();
  socket.onmessage = ({ data }) => {
    const message = JSON.parse(data);
    if (message.id && pending.has(message.id)) {
      const { resolve, reject } = pending.get(message.id);
      pending.delete(message.id);
      message.error ? reject(new Error(message.error.message)) : resolve(message.result);
    } else for (const listener of listeners) listener(message);
  };
  const send = (method, params = {}, sessionId) => {
    const id = next++;
    socket.send(JSON.stringify({ id, method, params, sessionId }));
    return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
  };
  return { send, on: (l) => listeners.add(l), close() { child.kill(); rmSync(profile, { recursive: true, force: true }); } };
}

const browser = await launch();
let failed = false;
try {
  const { targetId } = await browser.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await browser.send('Target.attachToTarget', { targetId, flatten: true });
  const send = (method, params) => browser.send(method, params, sessionId);
  const errors = [];
  browser.on((m) => { if (m.sessionId === sessionId && m.method === 'Runtime.exceptionThrown') errors.push(m.params.exceptionDetails.text); });
  await send('Page.enable');
  await send('Runtime.enable');
  await send('Page.addScriptToEvaluateOnNewDocument', { source: HELPERS });
  await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });
  const evaluate = async (expression) => {
    const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.text);
    return r.result.value;
  };
  const until = async (name, expression, ms = 8000) => {
    for (let i = 0; i < ms / 100; i++) {
      if (await evaluate(expression)) { console.log('  ok    ' + name); return; }
      await sleep(100);
    }
    failed = true;
    console.log('  FAIL  ' + name + '\n        grid text: ' + JSON.stringify(await evaluate('gridText()')).slice(0, 400));
  };
  const sql = (s) => PSQL_URL ? execFileSync('psql', [PSQL_URL, '-q', '-c', s]) : execFileSync('sqlite3', [DATABASE, s]);

  const stamp = Date.now().toString();
  sql(`INSERT INTO notes_notes (user_id, title, stars) SELECT id, 'seed ${stamp}', 1 FROM howdy_auth_users LIMIT 1`);
  await send('Page.navigate', { url: `${BASE}/_howdy/data/notes_notes` });
  await until('grid connects and shows the seeded row', `gridText().includes('seed ${stamp}')`);
  await until(PSQL_URL ? 'the grid says it follows NOTIFY' : 'the grid says it polls', PSQL_URL ? `gridText().includes('NOTIFY')` : `gridText().includes('every second')`);
  await until('the first load marks nothing as changed', `!gridText().includes('changed')`);

  sql(`UPDATE notes_notes SET title = 'renamed ${stamp}', stars = 9 WHERE title = 'seed ${stamp}'`);
  await until('an external UPDATE appears within a second', `gridText().includes('renamed ${stamp}')`, 4000);
  await until('the updated row is marked changed', `gridText().includes('changed')`, 2000);

  sql(`INSERT INTO notes_notes (user_id, title) SELECT id, 'inserted ${stamp}' FROM howdy_auth_users LIMIT 1`);
  await until('an external INSERT appears', `gridText().includes('inserted ${stamp}')`, 4000);
  await until('the mark clears after a few refreshes', `!gridText().includes('changed')`, 10000);

  const before = await evaluate(`(gridText().match(/(\\d+) rows/) || [])[1]`);
  await evaluate(`[...grid().querySelectorAll('tr')].find(tr => tr.textContent.includes('inserted ${stamp}')).querySelector('button').click()`);
  await until('deleting from the grid removes the row', `!gridText().includes('inserted ${stamp}')`, 4000);
  await until('the row count follows', `gridText().includes((${before} - 1) + ' rows')`, 4000);

  // Searching narrows the grid to the matching row; sorting by title puts
  // it first or last; clearing restores everything.
  sql(`INSERT INTO notes_notes (user_id, title) SELECT id, 'zz ${stamp}' FROM howdy_auth_users LIMIT 1`);
  await until('a second row for the search check appears', `gridText().includes('zz ${stamp}')`, 4000);
  await evaluate(`(() => { const i = grid().querySelector('input[name=q]'); i.value = 'zz ${stamp}'; i.form.requestSubmit(); })()`);
  await until('searching shows only the matching row', `gridText().includes('1 matching rows') && !gridText().includes('renamed ${stamp}')`, 4000);
  await evaluate(`[...grid().querySelectorAll('button')].find(b => b.textContent.trim() === 'Clear').click()`);
  await until('clearing the search brings the rest back', `gridText().includes('renamed ${stamp}')`, 4000);
  await evaluate(`[...grid().querySelectorAll('th button')].find(b => b.textContent.trim() === 'title').click()`);
  await until('sorting by title descending puts zz first', `gridText().includes('title ▲') || gridText().includes('title ▼')`, 4000);
  await evaluate(`[...grid().querySelectorAll('th button')].find(b => b.textContent.trim().startsWith('title')).click()`);
  await until('the second click sorts descending', `gridText().includes('title ▼') && [...grid().querySelectorAll('tbody tr')][0].textContent.includes('zz ${stamp}')`, 4000);
  await evaluate(`(() => { const f = grid().querySelector('select[name=column]').form; f.querySelector('select[name=column]').value = 'stars'; f.querySelector('select[name=operator]').value = 'gt'; f.querySelector('input[name=value]').value = '5'; f.requestSubmit(); })()`);
  await until('a filter narrows to rows with more than five stars', `gridText().includes('stars > 5') && gridText().includes('renamed ${stamp}') && !gridText().includes('zz ${stamp}')`, 4000);
  await evaluate(`grid().querySelector('button[aria-label="Remove filter"]').click()`);
  await until('removing the filter widens again', `gridText().includes('zz ${stamp}')`, 4000);

  sql(`DELETE FROM notes_notes WHERE title LIKE '%${stamp}'`);
  if (SHOT) {
    const { data } = await send('Page.captureScreenshot', { format: 'png' });
    writeFileSync(SHOT, Buffer.from(data, 'base64'));
    console.log('  saved ' + SHOT);
  }
  if (errors.length) { failed = true; console.log('  FAIL  page errors: ' + errors.join('; ')); }
} finally {
  browser.close();
}
process.exit(failed ? 1 : 0);
