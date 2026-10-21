// Checks the telemetry pages through Chromium's DevTools protocol: the live
// list follows requests as they finish, searching and the admin toggle
// narrow it, a trace opens as a timeline whose spans unfold, and the logs
// page connects. Run the admin example first:
//
//   cd examples/admin && gleam dev
//   node admin/browser_test/telemetry.mjs
//
// SCREENSHOT=dir saves the list and a trace page there.

import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

const BASE = process.env.BASE_URL || 'http://127.0.0.1:8787';
const CHROMIUM = process.env.CHROMIUM || 'chromium';
const SHOTS = process.env.SCREENSHOT || '';

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
      if (await evaluate(expression)) { console.log('  ok    ' + name); return; }
      await sleep(100);
    }
    failed = true;
    console.log('  FAIL  ' + name + '\n        text: ' + JSON.stringify(await evaluate('liveText() || document.body.innerText')).slice(0, 600));
  };
  const shot = async (name) => {
    if (!SHOTS) return;
    const { data } = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
    writeFileSync(join(SHOTS, name), Buffer.from(data, 'base64'));
    console.log('  saved ' + join(SHOTS, name));
  };
  const navigate = async (path) => {
    await send('Page.navigate', { url: BASE + path });
    await sleep(300);
  };

  await navigate('/_howdy/telemetry');
  await until('the list connects', `liveText().includes('Hide admin requests')`);

  const stamp = Date.now().toString();
  await fetch(`${BASE}/`);
  await fetch(`${BASE}/notes`);
  await fetch(`${BASE}/nowhere-${stamp}`);
  await until('requests appear as they finish', `liveText().includes('GET /notes') && liveText().includes('401') && liveText().includes('/nowhere-${stamp}')`, 4000);
  await until('admin requests are hidden', `!liveText().includes('/_howdy/telemetry')`);

  await evaluate(`(() => { const i = live().querySelector('input[name=q]'); i.value = 'notes'; i.form.requestSubmit(); })()`);
  await until('searching narrows to matching traces', `liveText().includes('GET /notes') && !liveText().includes('/nowhere-${stamp}')`, 4000);
  await evaluate(`[...live().querySelectorAll('button')].find(b => b.textContent.trim() === 'Clear').click()`);
  await until('clearing the search brings the rest back', `liveText().includes('/nowhere-${stamp}')`, 4000);

  await evaluate(`(() => { const s = live().querySelector('select[name=tooling]'); s.value = 'yes'; s.dispatchEvent(new Event('change', { bubbles: true })); })()`);
  await until('admin requests can be shown', `liveText().includes('/_howdy/telemetry')`, 4000);
  await evaluate(`(() => { const s = live().querySelector('select[name=tooling]'); s.value = 'no'; s.dispatchEvent(new Event('change', { bubbles: true })); })()`);
  await shot('telemetry-list.png');

  const href = await evaluate(`[...live().querySelectorAll('a')].find(a => a.textContent === 'GET /notes').getAttribute('href')`);
  await navigate(href);
  await until('the trace page shows a timeline', `document.body.innerText.includes('Timeline') && document.body.innerText.includes('GET /notes')`);
  await until('auth refused the request inside it', `document.body.innerText.includes('401')`);
  await evaluate(`document.querySelector('[data-span] summary').click()`);
  await until('a span unfolds to its attributes', `document.querySelector('[data-span]').open && document.body.innerText.includes('http.route')`, 2000);
  await shot('telemetry-trace.png');

  await navigate('/_howdy/telemetry/logs');
  await until('the logs page connects', `liveText().includes('Every level')`);

  if (errors.length) { failed = true; console.log('  FAIL  page errors: ' + errors.join('; ')); }
} finally {
  browser.close();
}
process.exit(failed ? 1 : 0);
