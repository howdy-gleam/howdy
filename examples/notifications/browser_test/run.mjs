// End-to-end check of the notifications example in headless Chromium, over
// the DevTools protocol: Ana and Bo sign in from separate browser contexts,
// Ana sends Bo a mention, and Bo's open page hears it without reloading.
//
//   cd examples/notifications && gleam run      # serves on :8792
//   node examples/notifications/browser_test/run.mjs
//
// BASE_URL and CHROMIUM override the defaults. Needs Node 22+.

import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const BASE = process.env.BASE_URL || 'http://localhost:8792';
const CHROMIUM = process.env.CHROMIUM || 'chromium';
const MAIL = join(dirname(fileURLToPath(import.meta.url)), '..', 'tmp', 'mail');

const profile = mkdtempSync(join(tmpdir(), 'howdy-notifications-'));
const child = spawn(CHROMIUM, ['--headless=new', '--remote-debugging-port=0', '--no-first-run', '--no-default-browser-check', '--disable-gpu', `--user-data-dir=${profile}`, 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
let chromiumLog = '';
child.stderr.on('data', (chunk) => { chromiumLog += chunk; });
// A cold Chromium on a CI runner can take well over ten seconds to write its
// port file, so allow a minute, and give up early if it exits instead.
const portFile = join(profile, 'DevToolsActivePort');
for (let i = 0; i < 600 && !existsSync(portFile) && child.exitCode === null && child.signalCode === null; i++) await sleep(100);
if (!existsSync(portFile)) {
  console.error(`${CHROMIUM} did not start (exit ${child.exitCode ?? child.signalCode ?? 'none, timed out'})\n${chromiumLog}`);
  child.kill();
  process.exit(1);
}
const [port] = readFileSync(portFile, 'utf8').split('\n');
const { webSocketDebuggerUrl } = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();

const socket = new WebSocket(webSocketDebuggerUrl);
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
const send = (method, params = {}, sessionId) =>
  new Promise((resolve, reject) => {
    const id = next++;
    pending.set(id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params, sessionId }));
  });

// A page in a browser context of its own, so each user has their own cookies.
async function newUser() {
  const { browserContextId } = await send('Target.createBrowserContext');
  const { targetId } = await send('Target.createTarget', { url: 'about:blank', browserContextId });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  const errors = [];
  listeners.add((message) => {
    if (message.sessionId === sessionId && message.method === 'Runtime.exceptionThrown')
      errors.push(message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text);
  });
  await send('Page.enable', {}, sessionId);
  await send('Runtime.enable', {}, sessionId);
  const evaluate = async (expression) => {
    const result = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId);
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
    return result.result.value;
  };
  const loaded = () =>
    new Promise((resolve) => {
      const listener = (message) => {
        if (message.sessionId === sessionId && message.method === 'Page.loadEventFired') {
          listeners.delete(listener);
          resolve();
        }
      };
      listeners.add(listener);
    });
  return {
    errors,
    evaluate,
    async goto(path) {
      const done = loaded();
      await send('Page.navigate', { url: BASE + path }, sessionId);
      await done;
    },
    // Click something that loads a new page, and wait for it.
    async submit(selector) {
      const done = loaded();
      await evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
      await done;
    },
    async until(expression, timeout = 5000) {
      const end = Date.now() + timeout;
      while (Date.now() < end) {
        if (await evaluate(expression).catch(() => false)) return;
        await sleep(50);
      }
      throw new Error(`timed out waiting for ${expression}`);
    },
  };
}

function equal(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected))
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

const toastTexts = `[...document.querySelectorAll('[data-howdy-toast-region] [data-howdy-toast]:not([hidden])')].map((t) => t.textContent)`;
const count = `document.querySelector('[data-howdy-bell-count]')`;
const feed = `document.querySelector('lustre-server-component')?.shadowRoot`;
const mailTo = (who) => (existsSync(MAIL) ? readdirSync(MAIL).filter((f) => f.endsWith('.eml')).map((f) => readFileSync(join(MAIL, f), 'utf8')).filter((m) => m.includes(`${who}@example.com`)) : []);

let failed = false;
try {
  const ana = await newUser();
  const bo = await newUser();

  await ana.goto('/');
  await ana.submit('button[name=user][value=ana]');
  await ana.until(`${toastTexts}.some((t) => t.includes('Signed in as Ana'))`);

  await bo.goto('/');
  await bo.submit('button[name=user][value=bo]');
  // Start from an empty inbox, whatever earlier runs left.
  await bo.evaluate(`fetch('/notifications/read', { method: 'POST' })`);
  await bo.goto('/');
  const mailed = { bo: mailTo('bo').length, cy: mailTo('cy').length };
  equal(await bo.evaluate(`${count}.hidden`), true, "Bo's count starts hidden");
  await bo.until(`${feed}?.textContent.includes('Unread: 0')`);
  // The events stream is open before Ana sends.
  await sleep(300);

  await ana.evaluate(`document.querySelector('#to').value = 'bo'; document.querySelector('#kind').value = 'mention'; document.querySelector('#message').value = 'See the plan?'`);
  await ana.submit('form[action="/send"] button[type=submit]');
  await ana.until(`${toastTexts}.some((t) => t.includes('Sent to Bo'))`);

  // Bo hears it without reloading: the bell, a toast and the live view.
  await bo.until(`!${count}.hidden && ${count}.textContent === '1'`);
  await bo.until(`${toastTexts}.some((t) => t.includes('Ana mentioned you') && t.includes('See the plan?'))`);
  await bo.until(`${feed}.textContent.includes('Ana mentioned you') && ${feed}.textContent.includes('Unread: 1')`);
  equal(await bo.evaluate(`document.querySelector('[data-howdy-bell-button]').getAttribute('aria-label')`), 'Notifications, 1 unread', 'label');

  // Opening the bell lists it; following it marks it read.
  await bo.evaluate(`document.querySelector('[data-howdy-bell-button]').click()`);
  await bo.until(`document.querySelectorAll('[data-howdy-bell-list] > [data-howdy-bell-entry][data-unread]').length === 1`);
  await bo.until(`!document.querySelector('[data-howdy-bell-push]').hidden`);
  await bo.submit('[data-howdy-bell-list] [data-howdy-bell-link]');
  equal(await bo.evaluate(`location.pathname`), '/inbox', 'followed the link');
  await bo.until(`${count}.hidden`);
  equal(await bo.evaluate(`document.body.textContent.includes('Mark unread')`), true, 'read in the inbox page');

  // The inbox works as plain forms too.
  await bo.submit('form[action$="/unread?next=/inbox"] button');
  equal(await bo.evaluate(`location.pathname`), '/inbox', 'redirected back');
  await bo.until(`${count}.textContent === '1'`);
  await bo.submit('form[action$="/read?next=/inbox"]:not([action="/notifications/read?next=/inbox"]) button');
  await bo.until(`${count}.hidden`);

  // A mention nobody reads is emailed after thirty seconds; Bo's, read in
  // time, is not.
  await ana.evaluate(`document.querySelector('#to').value = 'cy'; document.querySelector('#kind').value = 'mention'; document.querySelector('#message').value = 'For Cy'`);
  await ana.submit('form[action="/send"] button[type=submit]');
  const deadline = Date.now() + 50_000;
  while (mailTo('cy').length === mailed.cy && Date.now() < deadline) await sleep(1000);
  equal(mailTo('cy').length - mailed.cy, 1, 'one email to Cy');
  equal(mailTo('bo').length - mailed.bo, 0, 'no email to Bo, who read it first');

  for (const [who, page] of [['ana', ana], ['bo', bo]]) equal(page.errors, [], `${who}'s page threw`);
  console.log('ok    notifications reach an open page, the inbox and email');
} catch (error) {
  failed = true;
  console.error(`FAIL  ${error.message}`);
} finally {
  child.kill();
  await sleep(300);
  try { rmSync(profile, { recursive: true, force: true }); } catch {}
}
process.exit(failed ? 1 : 0);
