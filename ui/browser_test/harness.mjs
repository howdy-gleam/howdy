// A small harness for browser tests, driven through Chromium's DevTools
// protocol with real mouse and keyboard input. No dependencies beyond
// Node 22+ and a Chromium binary. Used by run.mjs, for the gallery, and by
// examples/islands.
//
// BASE_URL and CHROMIUM override the defaults. Each test gets a fresh page.

import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

let BASE;
let ORIGIN;
// Files for tests to choose in file inputs.
let files;

// Installed in every page: q and qa find elements in the page or inside
// any live view's shadow root.
const HELPERS = `
window.q = (s) => document.querySelector(s) || [...document.querySelectorAll('lustre-server-component')].map((h) => h.shadowRoot?.querySelector(s)).find(Boolean) || null;
window.qa = (s) => [...document.querySelectorAll(s), ...[...document.querySelectorAll('lustre-server-component')].flatMap((h) => [...(h.shadowRoot?.querySelectorAll(s) || [])])];
`;
const CHROMIUM = process.env.CHROMIUM || 'chromium';

// -- Chromium and the protocol -----------------------------------------------

async function launch() {
  const profile = mkdtempSync(join(tmpdir(), 'howdy-browser-'));
  const child = spawn(CHROMIUM, [
    '--headless=new',
    '--remote-debugging-port=0',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-gpu',
    `--user-data-dir=${profile}`,
    'about:blank',
  ], { stdio: 'ignore' });
  const portFile = join(profile, 'DevToolsActivePort');
  for (let i = 0; i < 100 && !existsSync(portFile); i++) await sleep(100);
  const [port] = readFileSync(portFile, 'utf8').split('\n');
  const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
  const browser = await connect(version.webSocketDebuggerUrl);
  return {
    browser,
    // Chromium keeps writing its profile as it shuts down, so wait for it to
    // exit, and never fail the run over a leftover temporary directory.
    async close() {
      if (child.exitCode === null && child.signalCode === null) {
        const exited = new Promise((resolve) => child.once('exit', resolve));
        child.kill();
        await Promise.race([exited, sleep(5000)]);
      }
      try {
        rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
      } catch (error) {
        console.warn(`could not remove ${profile}: ${error.message}`);
      }
    },
  };
}

async function connect(url) {
  const socket = new WebSocket(url);
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = reject;
  });
  let next = 1;
  const pending = new Map();
  const listeners = new Set();
  socket.onmessage = ({ data }) => {
    const message = JSON.parse(data);
    if (message.id && pending.has(message.id)) {
      const { resolve, reject } = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) reject(new Error(message.error.message));
      else resolve(message.result);
    } else {
      for (const listener of listeners) listener(message);
    }
  };
  return {
    send(method, params = {}, sessionId) {
      const id = next++;
      socket.send(JSON.stringify({ id, method, params, sessionId }));
      return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
    },
    on(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}

// A page: navigation, evaluation and input.
async function newPage(browser) {
  const { targetId } = await browser.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await browser.send('Target.attachToTarget', { targetId, flatten: true });
  const send = (method, params) => browser.send(method, params, sessionId);
  const errors = [];
  browser.on((message) => {
    if (message.sessionId !== sessionId) return;
    if (message.method === 'Runtime.exceptionThrown') errors.push(message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text);
  });
  await send('Page.enable');
  await send('Runtime.enable');
  await send('Page.addScriptToEvaluateOnNewDocument', { source: HELPERS });
  await send('Emulation.setDeviceMetricsOverride', { width: 1024, height: 768, deviceScaleFactor: 1, mobile: false });

  const evaluate = async (expression) => {
    const result = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
    return result.result.value;
  };

  const keys = {
    ArrowDown: 40, ArrowUp: 38, ArrowLeft: 37, ArrowRight: 39, Enter: 13, Escape: 27,
    Home: 36, End: 35, Tab: 9, ' ': 32, PageUp: 33, PageDown: 34, Backspace: 8,
  };

  const page = {
    errors,
    evaluate,
    // A page of the gallery app itself, rather than a component preview.
    open(path) {
      return page.navigate(ORIGIN + path);
    },
    goto(path) {
      return page.navigate(BASE + path);
    },
    async navigate(url) {
      const loaded = new Promise((resolve) => {
        const off = browser.on((message) => {
          if (message.sessionId === sessionId && message.method === 'Page.loadEventFired') {
            off();
            resolve();
          }
        });
      });
      await send('Page.navigate', { url });
      await loaded;
      // Module scripts run before load; give layout a frame.
      await evaluate('new Promise((r) => requestAnimationFrame(() => r()))');
    },
    // The centre of the first element matching `selector`, in viewport
    // coordinates.
    async centre(selector) {
      const box = await evaluate(`(() => {
        const el = q(${JSON.stringify(selector)});
        if (!el) return null;
        el.scrollIntoView({ block: 'nearest' });
        const r = el.getBoundingClientRect();
        return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
      })()`);
      if (!box) throw new Error(`no element matches ${selector}`);
      return box;
    },
    async mouse(type, x, y, extra = {}) {
      await send('Input.dispatchMouseEvent', { type, x, y, button: 'left', buttons: type === 'mouseReleased' ? 0 : 1, clickCount: 1, pointerType: 'mouse', ...extra });
    },
    async click(selector) {
      const { x, y } = await page.centre(selector);
      await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y });
      await page.mouse('mousePressed', x, y);
      await page.mouse('mouseReleased', x, y);
      await sleep(50);
    },
    async hover(selector) {
      const { x, y } = await page.centre(selector);
      await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y });
      await sleep(50);
    },
    async drag(selector, dx, dy) {
      const { x, y } = await page.centre(selector);
      await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y });
      await page.mouse('mousePressed', x, y);
      const steps = 8;
      for (let i = 1; i <= steps; i++) {
        await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: x + (dx * i) / steps, y: y + (dy * i) / steps, button: 'left', buttons: 1 });
      }
      await page.mouse('mouseReleased', x + dx, y + dy);
      await sleep(50);
    },
    // Park the pointer in the bottom-left corner, away from the previews
    // and from toasts.
    async leave() {
      await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 5, y: 760 });
      await sleep(50);
    },
    // `modifiers` add up: 1 Alt, 2 Control, 4 Meta, 8 Shift.
    async press(key, modifiers = 0) {
      const code = keys[key] ?? key.toUpperCase().charCodeAt(0);
      const typed = key === 'Enter' ? '\r' : key.length === 1 ? key : undefined;
      // A key held with Control or Meta types nothing.
      const text = modifiers & 6 ? undefined : typed;
      const name = key === ' ' ? 'Space' : key.length === 1 ? `Key${key.toUpperCase()}` : key;
      await send('Input.dispatchKeyEvent', { type: text ? 'keyDown' : 'rawKeyDown', key, code: name, windowsVirtualKeyCode: code, text, modifiers });
      await send('Input.dispatchKeyEvent', { type: 'keyUp', key, code: name, windowsVirtualKeyCode: code, modifiers });
      await sleep(30);
    },
    async type(text) {
      for (const char of text) await send('Input.insertText', { text: char });
      await sleep(30);
    },
    focus(selector) {
      return evaluate(`q(${JSON.stringify(selector)}).focus()`);
    },
    // A file of `content` in a temporary folder, for `chooseFiles`.
    file(name, content) {
      const path = join(files, name);
      writeFileSync(path, content);
      return path;
    },
    // Choose files in a file input, as the file chooser would.
    async chooseFiles(selector, paths) {
      const { result } = await send('Runtime.evaluate', { expression: `q(${JSON.stringify(selector)})` });
      await send('DOM.setFileInputFiles', { files: paths, objectId: result.objectId });
      await sleep(50);
    },
    // Send uploads at this many bytes a second.
    async slowUploads(bytesPerSecond) {
      await send('Network.enable');
      await send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: bytesPerSecond });
    },
    // Hold requests whose URL matches `pattern` (`*` is a wildcard) until
    // `release` is called. `held` counts those caught so far.
    async hold(pattern) {
      const paused = [];
      const off = browser.on((message) => {
        if (message.sessionId === sessionId && message.method === 'Fetch.requestPaused') paused.push(message.params.requestId);
      });
      await send('Fetch.enable', { patterns: [{ urlPattern: pattern }] });
      return {
        held: () => paused.length,
        async release() {
          off();
          for (const requestId of paused) await send('Fetch.continueRequest', { requestId });
          await send('Fetch.disable');
        },
      };
    },
    // Watch the server-sent events the page receives from now on. Call it
    // before `goto`, so none are missed; `until(name)` waits for one.
    async serverEvents() {
      const names = [];
      browser.on((message) => {
        if (message.sessionId === sessionId && message.method === 'Network.eventSourceMessageReceived') names.push(message.params.eventName);
      });
      await send('Network.enable');
      return {
        names,
        async until(name, timeout = 2000) {
          const end = Date.now() + timeout;
          while (Date.now() < end) {
            if (names.includes(name)) return;
            await sleep(40);
          }
          throw new Error(`timed out waiting for a server-sent ${name} event`);
        },
      };
    },
    // Wait until `expression` is true, for animations and smooth scrolling.
    async until(expression, timeout = 2000) {
      const end = Date.now() + timeout;
      while (Date.now() < end) {
        // A page navigating away has no context to evaluate in for a moment.
        if (await evaluate(expression).catch(() => false)) return;
        await sleep(40);
      }
      throw new Error(`timed out waiting for ${expression}`);
    },
    close: () => browser.send('Target.closeTarget', { targetId }),
  };
  return page;
}

export function equal(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

export function ok(value, what) {
  if (!value) throw new Error(what);
}

export const focused = `(() => { let f = document.activeElement; while (f?.shadowRoot?.activeElement) f = f.shadowRoot.activeElement; return f?.textContent.trim() || f?.getAttribute('aria-label') || f?.tagName; })()`;

// -- Running -----------------------------------------------------------------

// Run each test, a function of a page, in a fresh page, and exit with the
// result. Paths given to `page.goto` are under `base`; `page.open` takes
// paths from its origin. The first command-line argument filters tests by
// name.
export async function run(tests, { base }) {
  const only = process.argv[2];
  BASE = process.env.BASE_URL || base;
  ORIGIN = new URL(BASE).origin;
  const { browser, close } = await launch();
  files = mkdtempSync(join(tmpdir(), 'howdy-uploads-'));
  let failed = 0;
  let ran = 0;
  try {
    for (const [name, test] of Object.entries(tests)) {
      if (only && !name.includes(only)) continue;
      ran++;
      const page = await newPage(browser);
      try {
        await test(page);
        if (page.errors.length) throw new Error('page errors: ' + page.errors.join('; '));
        console.log(`  ok    ${name}`);
      } catch (error) {
        failed++;
        console.log(`  FAIL  ${name}\n        ${error.message}`);
      } finally {
        await page.close().catch(() => {});
      }
    }
  } finally {
    await close();
    rmSync(files, { recursive: true, force: true });
  }
  console.log(`\n${ran - failed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
}
