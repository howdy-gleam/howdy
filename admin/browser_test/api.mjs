// Checks the API pages through Chromium's DevTools protocol: the admin
// finds the document the app serves, lists its endpoints, and calls a
// guarded one, refused anonymously and let through as a user it signs in
// as. Run the admin example first:
//
//   cd examples/admin && gleam dev
//   node admin/browser_test/api.mjs
//
// SCREENSHOT=dir saves the endpoint list and a call's response there.

import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

const BASE = process.env.BASE_URL || 'http://127.0.0.1:8787';
const CHROMIUM = process.env.CHROMIUM || 'chromium';
const SHOTS = process.env.SCREENSHOT || '';

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
  await send('Emulation.setDeviceMetricsOverride', { width: 1400, height: 1000, deviceScaleFactor: 1, mobile: false });
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
    console.log('  FAIL  ' + name + '\n        text: ' + JSON.stringify(await evaluate('document.body.innerText')).slice(0, 600));
  };
  const shot = async (name) => {
    if (!SHOTS) return;
    const { data } = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
    writeFileSync(join(SHOTS, name), Buffer.from(data, 'base64'));
    console.log('  saved ' + join(SHOTS, name));
  };
  const navigate = async (path) => {
    await send('Page.navigate', { url: BASE + path });
    await sleep(400);
  };
  const text = 'document.body.innerText';

  // A user to call as, created through the admin itself.
  const email = `api-${Date.now()}@example.com`;
  await fetch(`${BASE}/_howdy/users`, {
    method: 'POST', redirect: 'manual',
    // The admin refuses writes from other origins.
    headers: { 'content-type': 'application/x-www-form-urlencoded', origin: BASE },
    body: new URLSearchParams({ email }),
  });

  await navigate('/_howdy');
  await until('the overview found the API', `${text}.includes('howdy_openapi') && ${text}.includes('3 endpoints')`);

  await navigate('/_howdy/api');
  await until('the endpoints are listed by tag', `${text}.includes('Your notes') && ${text}.includes('Write a note') && ${text}.includes('needs session')`);
  await shot('api-index.png');

  const href = await evaluate(`[...document.querySelectorAll('a')].find(a => a.textContent === '/notes' && a.closest('tr').innerText.includes('Write a note')).getAttribute('href')`);
  await navigate(href);
  await until('the form starts with an example body', `document.querySelector('textarea[name=body]').value.includes('"title"')`);

  // Anonymously, the guard refuses.
  await evaluate(`document.querySelector('form button[type=submit]').click()`);
  await until('anonymous calls are refused', `document.querySelector('#response')?.innerText.includes('401')`);

  // As the user, the note is written.
  await evaluate(`(() => {
    const select = document.querySelector('select[name=as]');
    select.value = [...select.options].find(o => o.textContent === '${email}').value;
    document.querySelector('textarea[name=body]').value = '{"title": "  Written from the admin  "}';
    document.querySelector('form button[type=submit]').click();
  })()`);
  await until('calls as a user get through', `document.querySelector('#response')?.innerText.includes('201') && document.querySelector('#response').innerText.includes('Written from the admin') && document.querySelector('#response').innerText.includes('as ${email}')`);
  await until('the chosen user stays selected', `document.querySelector('select[name=as]').selectedOptions[0].textContent === '${email}'`);
  await shot('api-call.png');

  if (errors.length) { failed = true; console.log('  FAIL  page errors: ' + errors.join('; ')); }
} finally {
  browser.close();
}
process.exit(failed ? 1 : 0);
