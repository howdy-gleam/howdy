// Browser tests for the interactive components, driven through Chromium's
// DevTools protocol with real mouse and keyboard input. No dependencies
// beyond Node 22+ and a Chromium binary.
//
//   cd examples/gallery && gleam run          # serves the gallery on :8791
//   node ui/browser_test/run.mjs [filter]
//
// BASE_URL and CHROMIUM override the defaults. Each test opens one gallery
// preview, `/ui/<entry>/preview/<index>`, in a fresh page.

import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

const BASE = process.env.BASE_URL || 'http://127.0.0.1:8791/ui';
const ORIGIN = new URL(BASE).origin;

// Installed in every page: q and qa find elements in the page or inside
// any live view's shadow root.
const HELPERS = `
window.q = (s) => document.querySelector(s) || [...document.querySelectorAll('lustre-server-component')].map((h) => h.shadowRoot?.querySelector(s)).find(Boolean) || null;
window.qa = (s) => [...document.querySelectorAll(s), ...[...document.querySelectorAll('lustre-server-component')].flatMap((h) => [...(h.shadowRoot?.querySelectorAll(s) || [])])];
`;
const CHROMIUM = process.env.CHROMIUM || 'chromium';
const only = process.argv[2];

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
    async press(key) {
      const code = keys[key] ?? key.toUpperCase().charCodeAt(0);
      const text = key === 'Enter' ? '\r' : key.length === 1 ? key : undefined;
      const name = key === ' ' ? 'Space' : key.length === 1 ? `Key${key.toUpperCase()}` : key;
      await send('Input.dispatchKeyEvent', { type: text ? 'keyDown' : 'rawKeyDown', key, code: name, windowsVirtualKeyCode: code, text });
      await send('Input.dispatchKeyEvent', { type: 'keyUp', key, code: name, windowsVirtualKeyCode: code });
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

function equal(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function ok(value, what) {
  if (!value) throw new Error(what);
}

const focused = `(() => { let f = document.activeElement; while (f?.shadowRoot?.activeElement) f = f.shadowRoot.activeElement; return f?.textContent.trim() || f?.getAttribute('aria-label') || f?.tagName; })()`;

// -- Tests -------------------------------------------------------------------

const tests = {
  async 'menus choose a radio item and close'(page) {
    await page.goto('/menu/preview/1');
    await page.click('[popovertarget=example-view-menu]');
    equal(await page.evaluate(focused), 'Newest', 'focus on opening');
    await page.click('[role=menuitemradio]:nth-of-type(2)');
    equal(await page.evaluate(`[...document.querySelectorAll('[role=menuitemradio]')].map((el) => el.getAttribute('aria-checked'))`), ['false', 'true'], 'radio state');
    equal(await page.evaluate(`document.getElementById('example-view-menu').matches(':popover-open')`), false, 'menu closed');
  },

  async 'submenus open with the arrow keys and close back to their item'(page) {
    await page.goto('/menu/preview/1');
    await page.click('[popovertarget=example-view-menu]');
    await page.press('End');
    equal(await page.evaluate(focused), 'Share', 'focus on the submenu item');
    await page.press('ArrowRight');
    await page.until(`document.getElementById('example-share-menu').matches(':popover-open')`);
    equal(await page.evaluate(focused), 'Copy link', 'focus in the submenu');
    equal(await page.evaluate(`document.querySelector('[data-howdy-submenu-trigger]').getAttribute('aria-expanded')`), 'true', 'expanded');
    await page.press('ArrowLeft');
    equal(await page.evaluate(`document.getElementById('example-share-menu').matches(':popover-open')`), false, 'submenu closed');
    equal(await page.evaluate(focused), 'Share', 'focus back on its item');
    ok(await page.evaluate(`document.getElementById('example-view-menu').matches(':popover-open')`), 'the parent menu stays open');
  },

  async 'choosing in a submenu closes every menu'(page) {
    await page.goto('/menu/preview/1');
    await page.click('[popovertarget=example-view-menu]');
    await page.hover('[data-howdy-submenu-trigger]');
    await page.until(`document.getElementById('example-share-menu').matches(':popover-open')`);
    await page.click('#example-share-menu [role=menuitem]');
    equal(await page.evaluate(`[...document.querySelectorAll('[popover]')].filter((el) => el.matches(':popover-open')).length`), 0, 'open popovers');
  },

  async 'a range calendar picks a start and an end'(page) {
    await page.goto('/calendar/preview/2');
    await page.click('[data-date="2026-09-10"]');
    equal(await page.evaluate(`document.querySelector('[data-howdy-calendar] > input').value`), '2026-09-10/', 'after the start');
    await page.click('[data-date="2026-10-03"]');
    equal(await page.evaluate(`document.querySelector('[data-howdy-calendar] > input').value`), '2026-09-10/2026-10-03', 'after the end');
    ok(await page.evaluate(`document.querySelector('[data-date="2026-09-30"]').hasAttribute('data-in-range')`), 'days between are marked');
    ok(!(await page.evaluate(`document.querySelector('[data-date="2026-09-09"]').hasAttribute('data-in-range')`)), 'days before are not');
    await page.click('[data-date="2026-09-05"]');
    equal(await page.evaluate(`document.querySelector('[data-howdy-calendar] > input').value`), '2026-09-05/', 'a third click starts again');
  },

  async 'a multiple combobox sends one field per value, with chips'(page) {
    await page.goto('/command/preview/2');
    const sent = `qa('[data-howdy-select] > input[name=toppings]:not(:disabled)').map((el) => el.value)`;
    const chips = `qa('[data-howdy-chip]:not([hidden])').map((el) => el.textContent.replace('×', '').trim())`;
    equal(await page.evaluate(sent), ['basil'], 'at first');
    await page.click('[data-howdy-select-trigger]');
    await page.click('[role=option][data-value=olives]');
    await page.click('[role=option][data-value="chilli, sliced"]');
    equal(await page.evaluate(sent), ['basil', 'olives', 'chilli, sliced'], 'commas kept');
    ok(await page.evaluate(`q('[data-howdy-select] [popover]').matches(':popover-open')`), 'stays open');
    equal(await page.evaluate(chips), ['Basil', 'Olives', 'Chilli, sliced'], 'chips');
    await page.press('Escape');
    await page.click('[data-howdy-chip][data-value=olives] [data-howdy-chip-remove]');
    equal(await page.evaluate(sent), ['basil', 'chilli, sliced'], 'removed by its chip');
    equal(await page.evaluate(focused), 'Add toppings', 'focus back on the button');
    await page.press('Backspace');
    equal(await page.evaluate(sent), ['basil'], 'Backspace removes the last');
    await page.click('[data-howdy-select-clear]');
    equal(await page.evaluate(sent), [], 'cleared');
    equal(await page.evaluate(chips), [], 'no chips');
  },

  async 'the combobox search filters its options'(page) {
    await page.goto('/command/preview/1');
    await page.click('[data-howdy-select-trigger]');
    await page.type('ger');
    equal(await page.evaluate(`[...document.querySelectorAll('[role=option]')].filter((el) => !el.hidden).map((el) => el.textContent.trim())`), ['Germany'], 'visible options');
    await page.press('Enter');
    equal(await page.evaluate(`document.querySelector('[data-howdy-select] > input').value`), 'de', 'chosen by Enter');
  },

  async 'a drawer opens at its first snap and moves between them'(page) {
    await page.goto('/drawer/preview/0');
    await page.click('[commandfor=example-drawer]');
    await page.until(`document.getElementById('example-drawer').open`);
    const height = `Math.round(document.getElementById('example-drawer').getBoundingClientRect().height / innerHeight * 100)`;
    await page.until(`${height} === 45`);
    await page.focus('[data-howdy-drawer-handle]');
    await page.press('ArrowUp');
    equal(await page.evaluate(height), 90, 'taller');
    await page.press('ArrowDown');
    equal(await page.evaluate(height), 45, 'shorter');
    await page.press('ArrowDown');
    equal(await page.evaluate(`document.getElementById('example-drawer').open`), false, 'closed from the lowest snap');
  },

  async 'dragging a drawer down closes it'(page) {
    await page.goto('/drawer/preview/0');
    await page.click('[commandfor=example-drawer]');
    await page.until(`document.getElementById('example-drawer').open`);
    await sleep(300);
    await page.drag('[data-howdy-drawer-handle]', 0, 300);
    equal(await page.evaluate(`document.getElementById('example-drawer').open`), false, 'closed');
  },

  async 'dragging a drawer part way settles at the nearest snap'(page) {
    await page.goto('/drawer/preview/0');
    await page.click('[commandfor=example-drawer]');
    await page.until(`document.getElementById('example-drawer').open`);
    await sleep(300);
    await page.drag('[data-howdy-drawer-handle]', 0, -300);
    equal(await page.evaluate(`Math.round(document.getElementById('example-drawer').getBoundingClientRect().height / innerHeight * 100)`), 90, 'snapped up');
  },

  async 'a toggle group moves with the arrows, mirrored right to left'(page) {
    await page.goto('/direction/preview/0');
    ok(await page.evaluate(`getComputedStyle(document.querySelector('[data-howdy-toggle-group]')).direction === 'rtl'`), 'right to left');
    await page.focus('[data-howdy-toggle][aria-pressed=true]');
    // In right-to-left text, the left arrow moves forward.
    await page.press('ArrowLeft');
    equal(await page.evaluate(focused), 'وسط', 'moved to the next toggle');
    equal(await page.evaluate(`[...document.querySelectorAll('[data-howdy-toggle]')].map((el) => el.tabIndex)`), [-1, 0, -1], 'one tab stop');
    await page.press(' ');
    equal(await page.evaluate(`[...document.querySelectorAll('[data-howdy-toggle]')].map((el) => el.getAttribute('aria-pressed'))`), ['false', 'true', 'false'], 'pressed');
  },

  async 'breadcrumb separators point the other way right to left'(page) {
    await page.goto('/direction/preview/0');
    const separator = await page.evaluate(`getComputedStyle(document.querySelector('nav li:nth-child(2)'), '::before').content`);
    ok(separator.includes('‹'), `separator was ${separator}`);
  },

  async 'vertical tabs follow the up and down arrows'(page) {
    await page.goto('/tabs/preview/1');
    await page.focus('[role=tab][aria-selected=true]');
    await page.press('ArrowRight');
    equal(await page.evaluate(focused), 'General', 'right does nothing');
    await page.press('ArrowDown');
    equal(await page.evaluate(focused), 'Security', 'down moves');
    equal(await page.evaluate(`[...document.querySelectorAll('[role=tabpanel]')].map((el) => el.hidden)`), [true, false], 'panel follows');
  },

  async 'a one-time code keeps out letters'(page) {
    await page.goto('/input_otp/preview/0');
    await page.focus('input[data-howdy-otp]');
    await page.type('1a2b3');
    equal(await page.evaluate(`document.querySelector('input[data-howdy-otp]').value`), '123', 'digits only');
  },

  async 'range slider thumbs cannot pass each other'(page) {
    await page.goto('/slider/preview/1');
    await page.focus('[data-howdy-range] > input:first-of-type');
    for (let i = 0; i < 3; i++) await page.press('End');
    const values = `[...document.querySelectorAll('[data-howdy-range] input')].map((el) => Number(el.value))`;
    const [low, high] = await page.evaluate(values);
    ok(low <= high, `low ${low} passed high ${high}`);
    equal(high, 320, 'high unmoved');
    ok(await page.evaluate(`document.querySelector('[data-howdy-range]').style.getPropertyValue('--low') !== ''`), 'fill follows');
  },

  async 'a looping vertical carousel wraps round'(page) {
    await page.goto('/carousel/preview/1');
    const top = `document.querySelector('[data-howdy-carousel] > [id]').scrollTop`;
    const extent = `(() => { const v = document.querySelector('[data-howdy-carousel] > [id]'); return v.scrollHeight - v.clientHeight; })()`;
    await page.click('[data-howdy-carousel-previous]');
    await page.until(`${top} >= ${extent} - 2`);
    const end = await page.evaluate(top);
    await page.click('[data-howdy-carousel-next]');
    await page.until(`${top} === 0`);
    await page.click('[data-howdy-carousel-next]');
    await page.until(`${top} > 10`);
    await sleep(600);
    ok((await page.evaluate(top)) < end, 'one slide on');
  },

  async 'resizable panels keep a minimum, collapse and are remembered'(page) {
    await page.goto('/resizable/preview/0');
    await page.focus('[data-howdy-resizable] > [role=separator]');
    await page.press('Home');
    const grow = `Number(document.querySelector('[data-howdy-resizable] > :first-child').style.flexGrow)`;
    equal(Math.round(await page.evaluate(grow)), 20, 'held at the minimum');
    await page.press('Enter');
    equal(await page.evaluate(grow), 0, 'collapsed');
    await page.press('Enter');
    equal(Math.round(await page.evaluate(grow)), 20, 'restored');
    ok((await page.evaluate('document.cookie')).includes('resizable-mail=20_80'), 'remembered in a cookie');
  },

  async 'an indeterminate progress bar animates'(page) {
    await page.goto('/progress/preview/1');
    ok(await page.evaluate(`[...document.querySelectorAll('[role=progressbar] *')].some((el) => getComputedStyle(el).animationName !== 'none')`), 'animated');
    ok(!(await page.evaluate(`document.querySelector('[role=progressbar]').hasAttribute('aria-valuenow')`)), 'no value');
  },

  async 'several thumbs keep their order, upright too'(page) {
    await page.goto('/slider/preview/2');
    const values = (i) => `[...qa('[data-howdy-range]')[${i}].querySelectorAll('input')].map((el) => Number(el.value))`;
    await page.focus('[data-howdy-range] > input:nth-of-type(2)');
    await page.press('End');
    equal(await page.evaluate(values(0)), [9, 17, 17], 'the middle stops at its neighbour');
    await page.press('Home');
    equal(await page.evaluate(values(0)), [9, 9, 17], 'and at the other');
    await page.press('ArrowUp');
    equal(await page.evaluate(values(0)), [9, 10, 17], 'up raises an upright thumb');
    const box = await page.evaluate(`(() => { const r = q('[data-howdy-range]').getBoundingClientRect(); return [r.width, r.height]; })()`);
    ok(box[1] > box[0] * 4, `upright: ${box}`);
  },

  async 'icon buttons are square at every size'(page) {
    await page.goto('/button/preview/1');
    const sizes = await page.evaluate(`qa('button[aria-label=Add]').map((el) => [el.offsetWidth, el.offsetHeight])`);
    equal(sizes.length, 4, 'four icon buttons');
    for (const [w, h] of sizes) equal(w, h, 'square');
    ok(sizes[0][0] < sizes[1][0], 'extra small is smallest');
  },

  async 'an autoplaying carousel moves on, pauses when hovered and by its button'(page) {
    await page.goto('/carousel/preview/2');
    const left = `q('[data-howdy-carousel] > [id]').scrollLeft`;
    await page.leave();
    await page.until(`${left} > 10`, 5000);
    // Let the smooth scroll settle.
    await sleep(1000);
    await page.hover('[data-howdy-carousel] > [id]');
    const held = await page.evaluate(left);
    await sleep(3600);
    equal(await page.evaluate(left), held, 'held while hovered');
    await page.click('[data-howdy-carousel-play]');
    equal(await page.evaluate(`q('[data-howdy-carousel-play]').getAttribute('aria-label')`), 'Play slides', 'paused by the button');
    await page.leave();
    await sleep(3600);
    equal(await page.evaluate(left), held, 'stays paused');
    equal(await page.evaluate(`q('[data-howdy-carousel] > [id]').getAttribute('aria-live')`), 'polite', 'announces when paused');
  },

  async 'a conversation opens at a message and remembers its place'(page) {
    await page.goto('/chat/preview/1');
    const top = `(() => { const s = q('[data-howdy-conversation] > div').getBoundingClientRect(); return Math.round(q('#example-history-12').getBoundingClientRect().top - s.top); })()`;
    ok(Math.abs(await page.evaluate(top)) < 20, 'message 12 at the top');
    await page.evaluate(`q('[data-howdy-conversation] > div').scrollTop = -300`);
    await sleep(400);
    await page.goto('/chat/preview/1');
    await page.until(`Math.round(Math.abs(q('[data-howdy-conversation] > div').scrollTop)) === 300`);
  },

  async 'a live view hears a multiple combobox as a list'(page) {
    await page.open('/lab');
    await page.until(`q('#lab-toppings-heard') !== null`, 5000);
    await page.click('#lab-toppings');
    await page.click('#lab-toppings-popover [role=option][data-value="chilli, sliced"]');
    await page.until(`q('#lab-toppings-heard').textContent === 'basil | chilli, sliced'`);
    await page.press('Escape');
    await page.click('[data-howdy-chip][data-value=basil] [data-howdy-chip-remove]');
    await page.until(`q('#lab-toppings-heard').textContent === 'chilli, sliced'`);
    // The server's rerender agrees with the browser.
    equal(await page.evaluate(`qa('[data-howdy-chip]:not([hidden])').map((el) => el.dataset.value)`), ['chilli, sliced'], 'chips after the patch');
  },

  async 'a live view hears selects and keyboard tab changes'(page) {
    await page.open('/lab');
    await page.until(`q('#lab-plan') !== null`, 5000);
    await page.click('#lab-plan');
    await page.press('ArrowDown');
    await page.press('Enter');
    await page.until(`q('#lab-plan-heard').textContent === 'pro'`);
    ok(await page.evaluate(`q('#lab-locked').disabled`), 'the locked select is disabled');
    equal(await page.evaluate(`getComputedStyle(q('#lab-locked')).borderTopColor === getComputedStyle(q('#lab-plan')).borderTopColor`), false, 'and drawn as invalid');
    await page.focus('#lab-tabs [role=tab][aria-selected=true]');
    await page.press('ArrowRight');
    await page.until(`q('#lab-tab-heard').textContent === 'two'`);
    equal(await page.evaluate(`q('#lab-tabs [role=tabpanel]:not([hidden])').textContent`), 'Second', 'panel after the patch');
  },

  async 'toasts in a live view leave when they fade, not while hovered'(page) {
    await page.open('/lab');
    await page.until(`q('#lab-notify') !== null`, 5000);
    const count = `q('#lab-toast-count').textContent`;
    await page.click('#lab-notify');
    await page.until(`${count} === '1'`);
    await page.hover('[data-howdy-toast]');
    await sleep(6500);
    equal(await page.evaluate(count), '1', 'kept while hovered');
    await page.leave();
    // The rest of the countdown runs once the pointer leaves.
    await page.until(`${count} === '0'`, 6000);
  },

  async 'an updated toast starts its countdown again'(page) {
    await page.open('/lab');
    await page.until(`q('#lab-save') !== null`, 5000);
    const count = `q('#lab-toast-count').textContent`;
    await page.click('#lab-save');
    await page.leave();
    await page.until(`q('[data-howdy-toast]')?.textContent.includes('Saving')`);
    await page.until(`q('[data-howdy-toast]')?.textContent.includes('Saved')`);
    await sleep(4000);
    equal(await page.evaluate(count), '1', 'still there four seconds after saving');
    await page.until(`${count} === '0'`, 2500);
  },

  async 'a toast held open outlasts server cleanup, however long'(page) {
    await page.open('/lab');
    await page.until(`q('#lab-notify') !== null`, 5000);
    const count = `q('#lab-toast-count').textContent`;
    await page.click('#lab-notify');
    await page.until(`${count} === '1'`);
    // Hold it open with focus, then let the lab's clock run two, then four,
    // minutes ahead while its cleanup runs every second.
    await page.focus('[data-howdy-toast-close]');
    await sleep(500);
    await page.evaluate(`q('#lab-skip').click()`);
    await sleep(1500);
    equal(await page.evaluate(count), '1', 'kept two minutes on');
    await page.evaluate(`q('#lab-skip').click()`);
    await sleep(1500);
    equal(await page.evaluate(count), '1', 'kept four minutes on');
    // Let go: the countdown carries on and the toast leaves.
    await page.focus('#lab-notify');
    await page.until(`${count} === '0'`, 6000);
  },

  async 'server cleanup still removes a toast nobody closed'(page) {
    await page.open('/lab');
    await page.until(`q('#lab-notify') !== null`, 5000);
    const count = `q('#lab-toast-count').textContent`;
    await page.click('#lab-notify');
    await page.until(`${count} === '1'`);
    await page.leave();
    await page.evaluate(`q('#lab-skip').click()`);
    await page.until(`${count} === '0'`, 1000);
  },

  async 'a success toast updated to success starts its countdown again'(page) {
    await page.open('/lab');
    await page.until(`q('#lab-remind') !== null`, 5000);
    const count = `q('#lab-toast-count').textContent`;
    await page.click('#lab-remind');
    await page.leave();
    await page.until(`q('[data-howdy-toast]')?.textContent.includes('Reminder again')`, 4000);
    // Without a restart it would go 2.5 seconds after the update.
    await sleep(4000);
    equal(await page.evaluate(count), '1', 'still there four seconds after the update');
    await page.until(`${count} === '0'`, 2500);
  },

  async 'older history loads above without moving the reader'(page) {
    await page.open('/lab');
    await page.until(`q('#lab-conversation') !== null`, 5000);
    // Start from the newest, whatever an earlier run left behind.
    await page.evaluate(`sessionStorage.clear(); q('#lab-conversation').scrollTop = 0`);
    await sleep(200);
    await page.evaluate(`q('#lab-conversation').scrollTop = -100000`);
    await page.until(`q('#lab-oldest').textContent === '21'`);
    await sleep(300);
    const shown = `(() => { const s = q('#lab-conversation').getBoundingClientRect(); return Math.round(q('#lab-message-31').getBoundingClientRect().top - s.top); })()`;
    ok(Math.abs(await page.evaluate(shown)) < 40, 'message 31 is still where the reader was');
    ok(await page.evaluate(`q('#lab-message-21') !== null`), 'older messages are there');
  },

  async 'a questionnaire in a live view runs to the end'(page) {
    await page.open('/lab');
    await page.until(`q('#lab-questionnaire') !== null`, 5000);
    await page.click('#lab-questionnaire button[value=next]');
    await page.until(`q('#lab-questionnaire [role=alert]') !== null`);
    await page.click('#lab-questionnaire input[value=build]');
    await page.click('#lab-questionnaire button[value=next]');
    await page.until(`q('#lab-questionnaire legend').textContent.includes('recommend')`);
    await page.click('#lab-questionnaire button[value=back]');
    await page.until(`q('#lab-questionnaire input[value=build]')?.checked`);
    await page.click('#lab-questionnaire button[value=next]');
    await page.until(`q('#lab-questionnaire input[name=score]') !== null`);
    await page.click('#lab-questionnaire input[name=score][value="4"]');
    await page.click('#lab-questionnaire button[value=next]');
    await page.until(`q('#lab-answers')?.textContent === 'role=build score=4'`);
  },

  async 'a questionnaire posted as a plain form runs to the end'(page) {
    await page.open('/survey');
    await page.click('form button[value=next]');
    await page.until(`q('[role=alert]')?.textContent === 'Answer this to go on.'`);
    await page.click('input[value=design]');
    await page.click('form button[value=next]');
    await page.until(`q('legend')?.textContent.includes('recommend')`);
    await page.click('input[name=score][value="3"]');
    await page.click('form button[value=next]');
    await page.until(`q('#survey-answers')?.textContent === 'role=design score=3'`);
  },

  async 'a notification bell follows its inbox live'(page) {
    await page.goto('/bell/preview/0');
    const button = '[data-howdy-bell-button]';
    equal(await page.evaluate(`q('[data-howdy-bell-count]').textContent`), '2', 'count drawn with the page');
    equal(await page.evaluate(`q('${button}').getAttribute('aria-label')`), 'Notifications, 2 unread', 'label');
    await page.click(button);
    await page.until(`q('[data-howdy-bell-panel]').matches(':popover-open')`);
    const entries = `[...document.querySelectorAll('[data-howdy-bell-list] > [data-howdy-bell-entry]')]`;
    await page.until(`${entries}.length === 3`);
    equal(await page.evaluate(`${entries}.map((e) => e.hasAttribute('data-unread'))`), [true, true, false], 'unread marks');
    equal(await page.evaluate(`${entries}[0].querySelector('[data-howdy-bell-title]').textContent`), 'Ana commented on your post', 'title');
    equal(await page.evaluate(`${entries}[0].querySelector('[data-howdy-bell-link]').getAttribute('href')`), '#n3', 'link');
    ok((await page.evaluate(`${entries}[0].querySelector('time').textContent`)).includes('2'), 'relative time');
    // Mark one read with its dot.
    await page.click('[data-howdy-bell-list] > [data-howdy-bell-entry] [data-howdy-bell-mark]');
    await page.until(`!${entries}[0].hasAttribute('data-unread')`);
    equal(await page.evaluate(`${entries}[0].querySelector('[data-howdy-bell-mark]').getAttribute('aria-label')`), 'Mark as unread', 'mark label');
    equal(await page.evaluate(`q('[data-howdy-bell-count]').textContent`), '1', 'count from the server');
    await page.click('[data-howdy-bell-read-all]');
    await page.until(`q('[data-howdy-bell-count]').hidden`);
    equal(await page.evaluate(`${entries}.some((e) => e.hasAttribute('data-unread'))`), false, 'all read');
    equal(await page.evaluate(`q('${button}').getAttribute('aria-label')`), 'Notifications', 'label with none unread');
    // The pretend inbox announces a notification five seconds after the
    // stream opens.
    await page.until(`${entries}.length === 4`, 8000);
    equal(await page.evaluate(`${entries}[0].querySelector('[data-howdy-bell-title]').textContent`), 'Order #3 was placed', 'live entry first');
    equal(await page.evaluate(`q('[data-howdy-bell-count]').textContent`), '3', 'live count');
    const toast = `document.querySelector('[data-howdy-toast-region] [data-howdy-bell-toast]')`;
    await page.until(`${toast} !== null`);
    equal(await page.evaluate(`${toast}.querySelector('a').textContent`), 'Order #3 was placed', 'toast title');
    equal(await page.evaluate(`${toast}.querySelector('a').getAttribute('href')`), '#live3', 'toast link');
    equal(await page.evaluate(`getComputedStyle(${toast}).position`), 'relative', 'toast styled by its class');
  },

  async 'an uploader sends a file to storage and the form posts its key'(page) {
    await page.goto('/uploader/preview/1');
    // Required, so the form will not submit empty.
    equal(await page.evaluate(`document.querySelector('#document-form').checkValidity()`), false, 'empty form invalid');
    const file = page.file('notes.txt', 'hello, storage');
    await page.chooseFiles('[data-howdy-upload-input]', [file]);
    await page.until(`q('[data-howdy-upload-item]:not(template *)')?.dataset.state === 'done'`, 5000);
    const item = `document.querySelector('[data-howdy-upload-list] > [data-howdy-upload-item]')`;
    equal(await page.evaluate(`${item}.querySelector('[data-howdy-upload-name]').textContent`), 'notes.txt', 'name');
    equal(await page.evaluate(`${item}.querySelector('[data-howdy-upload-detail]').textContent`), 'TXT · 14 B', 'detail');
    equal(await page.evaluate(`${item}.querySelector('[data-howdy-upload-progress]').hidden`), true, 'progress hidden when done');
    const key = await page.evaluate(`${item}.querySelector('input[name=document]:not([disabled])').value`);
    ok(key.startsWith('uploads/') && key.endsWith('.txt'), `a key under uploads/: ${key}`);
    equal(await page.evaluate(`document.querySelector('#document-form').checkValidity()`), true, 'valid once uploaded');
    await page.click('#document-form button[type=submit]');
    await page.until(`q('#uploaded-keys')?.textContent === ${JSON.stringify(key + '=found')}`, 5000);
  },

  async 'an uploader refuses files it was told not to take'(page) {
    await page.goto('/uploader/preview/1');
    const items = `[...document.querySelectorAll('[data-howdy-upload-list] > [data-howdy-upload-item]')]`;
    await page.chooseFiles('[data-howdy-upload-input]', [page.file('cat.png', 'PNG')]);
    equal(await page.evaluate(`${items}.map((item) => [item.dataset.state, item.querySelector('[role=alert]').textContent])`), [['failed', 'This type of file is not accepted.']], 'wrong type');
    equal(await page.evaluate(`${items}[0].querySelector('[data-howdy-upload-retry]').hidden`), true, 'no point retrying');
    ok(await page.evaluate(`${items}[0].firstElementChild.hasAttribute('data-failed')`), 'marked as failed');
    // One file at a time: the next replaces it.
    await page.chooseFiles('[data-howdy-upload-input]', [page.file('big.txt', 'x'.repeat(1_200_000))]);
    equal(await page.evaluate(`${items}.map((item) => item.querySelector('[role=alert]').textContent)`), ['Too large: the limit is 1 MB.'], 'too large');
    await page.click('[data-howdy-upload-remove]');
    equal(await page.evaluate(`${items}.length`), 0, 'removed');
    ok(await page.evaluate(`document.activeElement.matches('[data-howdy-upload-input]')`), 'focus back on the file input');
    equal(await page.evaluate(`document.querySelector('[data-howdy-upload-input]').validationMessage`), 'Choose a file.', 'still required');
  },

  async 'an uploader holds the form while a file is on its way'(page) {
    await page.goto('/uploader/preview/1');
    await page.slowUploads(200_000);
    await page.chooseFiles('[data-howdy-upload-input]', [page.file('slow.txt', 'y'.repeat(600_000))]);
    const progress = `document.querySelector('[data-howdy-upload-list] [role=progressbar]')`;
    await page.until(`Number(${progress}.getAttribute('aria-valuenow')) > 0`, 5000);
    equal(await page.evaluate(`${progress}.getAttribute('aria-label')`), 'Uploading slow.txt', 'progress named');
    equal(await page.evaluate(`document.querySelector('[data-howdy-upload-input]').validationMessage`), 'Wait for the files to finish uploading.', 'submit held');
    await page.click('#document-form button[type=submit]');
    equal(await page.evaluate(`location.pathname`), '/ui/uploader/preview/1', 'did not submit');
    await page.until(`document.querySelector('[data-howdy-upload-list] > li')?.dataset.state === 'done'`, 10000);
    equal(await page.evaluate(`document.querySelector('#document-form').checkValidity()`), true, 'free to submit');
  },

  async 'photos dropped on an uploader show as thumbnails, up to the limit'(page) {
    await page.goto('/uploader/preview/0');
    await page.evaluate(`window.heard = []; document.addEventListener('howdy-values', (event) => heard.push(event.detail))`);
    const drop = (names) => page.evaluate(`(async () => {
      const png = await (await fetch('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')).blob();
      const data = new DataTransfer();
      for (const name of ${JSON.stringify(names)}) data.items.add(new File([png], name, { type: 'image/png' }));
      const zone = document.querySelector('[data-howdy-upload-drop]');
      zone.dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true, composed: true, dataTransfer: data }));
      const dragging = zone.hasAttribute('data-dragging');
      zone.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, composed: true, dataTransfer: data }));
      return dragging && !zone.hasAttribute('data-dragging');
    })()`);
    const states = `[...document.querySelectorAll('[data-howdy-upload-list] > li:not([hidden])')].map((item) => item.dataset.state || 'stored')`;
    ok(await drop(['a.png', 'b.png']), 'the drop zone lights up while dragging');
    await page.until(`JSON.stringify(${states}) === ${JSON.stringify(JSON.stringify(['stored', 'done', 'done']))}`, 5000);
    ok(await page.evaluate(`[...document.querySelectorAll('[data-howdy-upload-list] > li[data-state] img')].every((img) => img.src.startsWith('blob:') && img.complete && img.naturalWidth === 1)`), 'thumbnails shown');
    ok(await page.evaluate(`[...document.querySelectorAll('[data-howdy-upload-list] > li[data-state] [data-howdy-upload-icon]')].every((icon) => icon.hidden)`), 'icons hidden behind thumbnails');
    // One stored and two uploaded: room for one more of four.
    await drop(['c.png', 'd.png']);
    await page.until(`JSON.stringify(${states}) === ${JSON.stringify(JSON.stringify(['stored', 'done', 'done', 'done', 'failed']))}`, 5000);
    equal(await page.evaluate(`document.querySelector('[data-howdy-upload-list] > li[data-state=failed] [role=alert]').textContent`), 'Too many files: the limit is 4.', 'too many');
    // The stored file is hidden, not removed, and no longer posted.
    await page.click('[data-howdy-upload-list] > li:first-child [data-howdy-upload-remove]');
    equal(await page.evaluate(`[document.querySelector('[data-howdy-upload-list] > li').hidden, document.querySelector('[data-howdy-upload-list] > li input[name=photos]').disabled]`), [true, true], 'stored file hidden and dropped');
    const last = await page.evaluate(`heard.at(-1)`);
    equal(last.name, 'photos', 'event names the field');
    equal(last.values.length, 3, 'three keys left');
    ok(last.values.every((key) => key.startsWith('uploads/')), 'only the uploaded keys');
  },

  async 'a questionnaire shows its first question'(page) {
    await page.goto('/questionnaire/preview/0');
    equal(await page.evaluate(`document.querySelector('legend').textContent.trim()`), 'What do you mostly do?', 'prompt');
    equal(await page.evaluate(`[...document.querySelectorAll('form button')].map((el) => el.textContent.trim())`), ['Next'], 'only next on a required first question');
  },
};

// -- Running -----------------------------------------------------------------

const { browser, close } = await launch();
// Files for the uploader tests to choose.
const files = mkdtempSync(join(tmpdir(), 'howdy-uploads-'));
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
