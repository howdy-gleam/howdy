// Checks the admin's mail pages through Chromium's DevTools protocol: the
// outbox list follows new mail live, a message renders in its sandboxed
// frame with working links, and a preview can be sent to the outbox. Run
// the admin example first:
//
//   cd examples/admin && gleam dev
//   node admin/browser_test/mail.mjs
//
// It registers an address through the example's auth API, which sends the
// registration email to the outbox.

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
  await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 1000, deviceScaleFactor: 1, mobile: false });
  const evaluate = async (expression) => {
    const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.text + ' in ' + expression);
    return r.result.value;
  };
  const until = async (name, expression, ms = 8000) => {
    for (let i = 0; i < ms / 100; i++) {
      if (await evaluate(expression).catch(() => false)) { console.log('  ok    ' + name); return; }
      await sleep(100);
    }
    failed = true;
    console.log('  FAIL  ' + name + '\n        page text: ' + JSON.stringify(await evaluate('document.body.innerText + liveText()')).slice(0, 400));
  };
  // The frame's sandbox gives it an opaque origin, so the page cannot read
  // it, and Chromium runs it in its own process. Attach to it as a target
  // of its own and evaluate there.
  let frameSession = null;
  browser.on((m) => {
    if (m.method === 'Target.attachedToTarget' && m.params.targetInfo.type === 'iframe') {
      frameSession = m.params.sessionId;
      browser.send('Runtime.runIfWaitingForDebugger', {}, frameSession).catch(() => {});
    }
  });
  await send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true });
  const inFrame = async (expression) => {
    if (!frameSession) return false;
    const r = await browser.send('Runtime.evaluate', { expression, returnByValue: true }, frameSession);
    return r.exceptionDetails ? false : r.result.value;
  };
  const untilFrame = async (name, expression, ms = 8000) => {
    for (let i = 0; i < ms / 100; i++) {
      if (await inFrame(expression).catch(() => false)) { console.log('  ok    ' + name); return; }
      await sleep(100);
    }
    failed = true;
    console.log('  FAIL  ' + name + '\n        frame text: ' + JSON.stringify(await inFrame('document.body?.innerText')).slice(0, 400));
  };
  const shot = async (name) => {
    if (!SHOTS) return;
    const { data } = await send('Page.captureScreenshot', { format: 'png' });
    writeFileSync(join(SHOTS, name + '.png'), Buffer.from(data, 'base64'));
    console.log('  saved ' + join(SHOTS, name + '.png'));
  };
  const navigate = async (path) => {
    frameSession = null;
    await send('Page.navigate', { url: BASE + path });
    await until('loaded ' + path, `document.readyState === 'complete'`);
  };

  await navigate('/_howdy/mail');
  await evaluate(`(() => { const b = [...(live()?.querySelectorAll('button') || [])].find(b => b.textContent.includes('Clear all')); if (b) b.click(); return true; })()`);
  await until('the outbox connects and starts empty', `liveText().includes('No mail yet')`);

  const email = `ada.${Date.now()}@example.com`;
  const res = await fetch(BASE + '/api/auth/register', {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email }),
  });
  console.log('  register answered ' + res.status);
  await until('the registration email appears without a reload', `liveText().includes('Confirm your Notes account') && liveText().includes('${email}')`, 5000);
  await until('it is tagged auth.registration', `liveText().includes('auth.registration')`);
  await shot('outbox');

  const href = await evaluate(`[...live().querySelectorAll('a')].find(a => a.textContent.includes('Confirm your Notes account')).getAttribute('href')`);
  await navigate(href);
  await until('the message page shows the envelope', `document.body.innerText.includes('${email}') && document.body.innerText.includes('Notes <notes@localhost>')`);
  await untilFrame('the HTML renders in the frame', `document.body.innerText.includes('Welcome to Notes')`);
  await untilFrame('the frame has the sign-in button linking to the pages', `[...document.querySelectorAll('a')].some(a => a.href.startsWith('http://localhost:8787/auth/login#token='))`);
  await untilFrame('links in the frame open a new tab', `document.querySelector('base')?.target === '_blank'`);
  await until('the page cannot reach into the frame', `document.querySelector('iframe').contentDocument === null`);
  await until('scripts cannot run in the frame', `!document.querySelector('iframe').sandbox.contains('allow-scripts')`);
  await shot('message-html');
  await evaluate(`[...document.querySelectorAll('[role=tab]')].find(t => t.textContent.trim() === 'Text').click()`);
  await until('the Text tab links the sign-in URL', `[...document.querySelectorAll('[role=tabpanel] a')].some(a => a.href.startsWith('http://localhost:8787/auth/login#token=') && a.offsetParent !== null)`);
  await shot('message-text');
  await evaluate(`[...document.querySelectorAll('[role=tab]')].find(t => t.textContent.trim() === 'Source').click()`);
  await until('the Source tab shows the MIME message', `[...document.querySelectorAll('pre')].some(p => p.offsetParent !== null && p.textContent.includes('Content-Type: multipart/alternative'))`);

  await navigate(href + '?width=mobile');
  await until('the mobile width narrows the frame', `document.querySelector('iframe').getBoundingClientRect().width === 375`);

  await navigate('/_howdy/mail/previews');
  await until('previews list the app and auth emails', `document.body.innerText.includes('Weekly digest') && document.body.innerText.includes('Email change approval') && document.body.innerText.includes('MFA code')`);
  const approval = await evaluate(`[...document.querySelectorAll('a')].find(a => a.textContent.trim() === 'Email change approval').getAttribute('href')`);
  await navigate(approval);
  await untilFrame('choosing a preview renders it', `document.body.innerText.includes('Approve the email change')`);
  await navigate('/_howdy/mail/previews?p=notes.weekly-digest');
  await untilFrame('the digest preview renders its sample notes', `document.body.innerText.includes('Call the plumber')`);
  await shot('preview');
  await evaluate(`[...document.querySelectorAll('button')].find(b => b.textContent.includes('Send to outbox')).click()`);
  await until('sending a preview opens it in the outbox', `location.pathname.startsWith('/_howdy/mail/message/') && document.body.innerText.includes('notes.digest')`);

  await navigate('/_howdy/mail');
  await until('the outbox now holds both messages', `liveText().includes('2 messages')`);
  if (errors.length) { failed = true; console.log('  FAIL  page errors: ' + errors.join('; ')); }
} finally {
  browser.close();
}
process.exit(failed ? 1 : 0);
