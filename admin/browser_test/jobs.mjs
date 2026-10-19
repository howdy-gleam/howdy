// Checks the admin's jobs pages through Chromium's DevTools protocol: the
// queues, the schedule and the jobs follow the database live, a note's
// digest job can be run at once and lands in the outbox, a queue can be
// paused and resumed, and a job's page shows it in full. Run the admin
// example first:
//
//   cd examples/admin && gleam dev
//   node admin/browser_test/jobs.mjs
//
// It writes a note through the admin's API pages, which queues the job.

import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

const BASE = process.env.BASE_URL || 'http://127.0.0.1:8787';
const CHROMIUM = process.env.CHROMIUM || 'chromium';
const SHOTS = process.env.SCREENSHOTS || '';

const HELPERS = `
window.live = () => document.querySelector('lustre-server-component')?.shadowRoot;
window.liveText = () => window.live()?.textContent || '';
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
  await send('Emulation.setDeviceMetricsOverride', { width: 1400, height: 1000, deviceScaleFactor: 1, mobile: false });
  const evaluate = async (expression) => {
    const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.text);
    return r.result.value;
  };
  const until = async (name, expression, ms = 8000) => {
    for (let i = 0; i < ms / 100; i++) {
      if (await evaluate(expression).catch(() => false)) { console.log('  ok    ' + name); return; }
      await sleep(100);
    }
    failed = true;
    console.log('  FAIL  ' + name + '\n        text: ' + JSON.stringify(await evaluate('document.body.innerText + liveText()')).slice(0, 800));
  };
  const shot = async (name) => {
    if (!SHOTS) return;
    const { data } = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
    writeFileSync(join(SHOTS, name + '.png'), Buffer.from(data, 'base64'));
    console.log('  saved ' + join(SHOTS, name + '.png'));
  };
  const navigate = async (path) => {
    await send('Page.navigate', { url: BASE + path });
    await sleep(400);
  };
  const text = 'document.body.innerText';

  // A user who writes a note, through the admin's own pages.
  const email = `jobs-${Date.now()}@example.com`;
  await fetch(`${BASE}/_howdy/users`, {
    method: 'POST', redirect: 'manual',
    // The admin refuses writes from other origins.
    headers: { 'content-type': 'application/x-www-form-urlencoded', origin: BASE },
    body: new URLSearchParams({ email }),
  });

  await navigate('/_howdy');
  await until('the overview has the jobs card', `${text}.includes('howdy_jobs') && ${text}.includes('Manage jobs')`);

  await navigate('/_howdy/jobs');
  await until('the queues and the schedule show', `liveText().includes('Queues') && liveText().includes('mail') && liveText().includes('notes.weekly_digests') && liveText().includes('0 8 * * mon')`);

  // Write a note as the user, which queues their digest a minute later.
  await navigate('/_howdy/api');
  const href = await evaluate(`[...document.querySelectorAll('a')].find(a => a.textContent === '/notes' && a.closest('tr').innerText.includes('Write a note')).getAttribute('href')`);
  await navigate(href);
  await until('the call form is ready', `[...(document.querySelector('select[name=as]')?.options || [])].some(o => o.textContent === '${email}')`);
  await evaluate(`(() => {
    const select = document.querySelector('select[name=as]');
    select.value = [...select.options].find(o => o.textContent === '${email}').value;
    document.querySelector('textarea[name=body]').value = '{"title": "Water the plants"}';
    document.querySelector('form button[type=submit]').click();
  })()`);
  await until('the note is written', `document.querySelector('#response')?.innerText.includes('201')`);

  await navigate('/_howdy/jobs');
  await until('the digest waits in the list without a reload', `[...live().querySelectorAll('tr')].some(r => r.innerText.includes('notes.digest') && r.innerText.includes('Scheduled'))`);
  await shot('jobs-index');

  // Pausing the mail queue keeps the job waiting even when it is due.
  await evaluate(`[...live().querySelectorAll('tr')].find(r => r.innerText.startsWith('mail')).querySelector('button').click()`);
  await until('the mail queue is paused', `[...live().querySelectorAll('tr')].find(r => r.innerText.startsWith('mail'))?.innerText.includes('paused')`);
  await evaluate(`[...live().querySelectorAll('tr')].find(r => r.innerText.includes('notes.digest') && r.innerText.includes('Scheduled')).querySelector('button').click()`);
  await until('run now makes it available', `[...live().querySelectorAll('tr')].some(r => r.innerText.includes('notes.digest') && r.innerText.includes('Available'))`);
  await sleep(1500);
  await until('a paused queue leaves it be', `[...live().querySelectorAll('tr')].some(r => r.innerText.includes('notes.digest') && r.innerText.includes('Available'))`);
  await evaluate(`[...live().querySelectorAll('tr')].find(r => r.innerText.startsWith('mail')).querySelector('button').click()`);
  await until('resumed, the digest is sent', `[...live().querySelectorAll('tr')].some(r => r.innerText.includes('notes.digest') && r.innerText.includes('Completed'))`, 10000);

  // Filtering by state.
  await evaluate(`(() => { const s = live().querySelector('select[name=state]'); s.value = 'failed'; s.dispatchEvent(new Event('change', { bubbles: true })); })()`);
  await until('filtering by failed hides it', `!liveText().includes('Water') && ![...live().querySelectorAll('tr')].some(r => r.innerText.includes('notes.digest') && r.innerText.includes('Completed'))`);
  await evaluate(`(() => { const s = live().querySelector('select[name=state]'); s.value = 'completed'; s.dispatchEvent(new Event('change', { bubbles: true })); })()`);
  await until('filtering by completed shows it', `[...live().querySelectorAll('tr')].some(r => r.innerText.includes('notes.digest') && r.innerText.includes('Completed'))`);

  // The job's own page.
  const job = await evaluate(`[...live().querySelectorAll('a')].find(a => a.textContent.includes('notes.digest')).getAttribute('href')`);
  await navigate(job);
  await until('the job page shows it in full', `${text}.includes('Arguments') && ${text}.includes('Completed') && ${text}.includes('Attempt') && ${text}.includes('1 of 5')`);
  await shot('jobs-job');

  await navigate('/_howdy/mail');
  await until('the digest reached the outbox', `liveText().includes('Your notes this week') && liveText().includes('${email}')`);

  if (errors.length) { failed = true; console.log('  FAIL  page errors: ' + errors.join('; ')); }
} finally {
  browser.close();
}
process.exit(failed ? 1 : 0);
