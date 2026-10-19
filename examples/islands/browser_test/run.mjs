// Browser tests for the islands example, with the harness from
// ui/browser_test. Run against `gleam run` or an exported release:
//
//   gleam run                                  # serves the example on :8793
//   node browser_test/run.mjs [filter]
//
// ISLANDS_MODE=dev adds tests that edit the source and reload, which only
// development can serve; ISLANDS_MODE=release checks the page loads the
// bundle. browser_test/smoke.sh runs both, from a clean build.

import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { equal, ok, run } from '../../../ui/browser_test/harness.mjs';

const mode = process.env.ISLANDS_MODE;
const src = (path) => fileURLToPath(new URL(`../src/${path}`, import.meta.url));

// Every island on the page, in the page or inside a live view, is running.
const running = `qa('howdy-island').length > 0 && qa('howdy-island').every((el) => 'running' in el.dataset)`;
const text = (selector) => `q(${JSON.stringify(selector)}).textContent.replace(/\\s+/g, ' ').trim()`;
const errors = `q('[data-howdy-islands-errors]')?.textContent ?? null`;

async function open(page, path) {
  await page.open(path);
  await page.until(running, 10000).catch(async (error) => {
    throw new Error(`${error.message}; island errors: ${await page.evaluate(errors)}`);
  });
}

// Count the intervals the page has running, in window.intervals.
function trackIntervals(page) {
  return page.evaluate(`(() => {
    window.intervals = new Set();
    const set = window.setInterval, clear = window.clearInterval;
    window.setInterval = (...args) => { const id = set(...args); intervals.add(id); return id; };
    window.clearInterval = (id) => { intervals.delete(id); clear(id); };
  })()`);
}

// Have the live view show the next island, and wait for it to run.
async function swap(page, module) {
  await page.click('#swap');
  await page.until(`q('#swappable howdy-island')?.dataset.module === ${JSON.stringify(module)}`);
  await page.until(running, 10000);
}

async function noErrors(page) {
  equal(await page.evaluate(errors), null, 'island errors on the page');
}

// The border of a badge, which only shows if its class's CSS reached it.
const badgeStyle = (selector) => `(() => {
  const badge = q(${JSON.stringify(selector)});
  const style = getComputedStyle(badge);
  return style.borderTopStyle + ' ' + style.borderTopLeftRadius;
})()`;

const counter = (n) => `howdy-island[data-module$="islands/counter"]:nth-of-type(${n})`;
const tasks = 'howdy-island[data-module$="islands/tasks"]';
const rating = 'howdy-island[data-module$="islands/rating"]';

const tests = {
  async 'the browser takes over server-rendered islands without re-rendering them'(page) {
    await open(page, '/');
    // The HTML the server sent for each island is what the running island
    // shows: hydration kept it.
    const same = await page.evaluate(`(async () => {
      const html = await (await fetch('/')).text();
      const sent = new DOMParser().parseFromString(html, 'text/html').querySelectorAll('howdy-island');
      const now = document.querySelectorAll('howdy-island');
      return sent.length === now.length && [...sent].every((el, i) => el.innerHTML === now[i].innerHTML);
    })()`);
    ok(same, 'the islands show the HTML the server sent');
    await page.click(`${counter(1)} button:last-of-type`);
    await page.click(`${counter(1)} button:last-of-type`);
    equal(await page.evaluate(text(`${counter(1)} output`)), 'Count: 7', 'first counter');
    equal(await page.evaluate(text(`${counter(2)} output`)), 'Count: 100', 'second counter untouched');
    await noErrors(page);
  },

  async 'an island built from howdy_ui components styles what it renders'(page) {
    await open(page, '/');
    const items = `qa('${tasks} [role=tabpanel]:not([hidden]) li').map((li) => li.textContent.replace(/\\s+/g, ' ').trim())`;
    await page.click(`${tasks} input`);
    await page.type('Try islands');
    await page.click(`${tasks} button[type=submit]`);
    equal(await page.evaluate(items), ['Open Write the docs Done', 'Open Ship it Done', 'Open Try islands Done'], 'after adding');
    // Done renders the Outline badge, a class the server never rendered.
    const before = await page.evaluate(`q('${tasks} li span').className`);
    await page.click(`${tasks} li button`);
    ok(before !== (await page.evaluate(`q('${tasks} li span').className`)), 'the badge changed class');
    equal(await page.evaluate(badgeStyle(`${tasks} li span`)), 'solid 999px', 'the new badge class is styled');
    equal(await page.evaluate(text(`${tasks} p`)), '2 open', 'open count');
    // The browser keeps the chosen tab across the island's re-renders.
    await page.click(`${tasks} [role=tab]:nth-of-type(2)`);
    await page.click(`${tasks} input`);
    await page.type('Another');
    await page.click(`${tasks} button[type=submit]`);
    equal(await page.evaluate(`q('${tasks} [role=tab][aria-selected=true]').textContent.trim()`), 'Done', 'tab kept');
    equal(await page.evaluate(items), ['Done Write the docs Reopen'], 'the Done tab');
    await page.click(`${tasks} [command=show-modal]`);
    await page.until(`q('${tasks} dialog').open`);
    await page.click(`${tasks} dialog button:last-of-type`);
    await page.until(`!q('${tasks} dialog').open`);
    equal(await page.evaluate(text(`${tasks} p`)), '0 open', 'cleared');
    await noErrors(page);
  },

  async 'an island shipped by a package runs like the app’s own'(page) {
    await open(page, '/');
    equal(await page.evaluate(`q('${rating}').dataset.package`), 'howdy_islands_library', 'package');
    await page.click(`${rating} [aria-label="Rate 5"]`);
    equal(await page.evaluate(text(`${rating} output`)), '5 out of 5', 'rated 5');
    await page.click(`${rating} [aria-label="Rate 1"]`);
    equal(await page.evaluate(`qa('${rating} [aria-pressed=true]').length`), 1, 'one star pressed');
    await noErrors(page);
  },

  async 'islands in a live view run in the browser and survive server re-renders'(page) {
    await open(page, '/live');
    await page.click(`#swappable howdy-island button:last-of-type`);
    await page.click(`#swappable howdy-island button:last-of-type`);
    equal(await page.evaluate(text('#swappable output')), 'Count: 5', 'island count');
    equal(await page.evaluate(text('#server-count')), 'Server count: 0', 'the server heard nothing');
    await page.click('#bump');
    await page.until(`q('#server-count').textContent === 'Server count: 1'`);
    equal(await page.evaluate(text('#swappable output')), 'Count: 5', 'island state kept');
    await noErrors(page);
  },

  async 'islands in a live view get the CSS for classes first used in the browser'(page) {
    await open(page, '/live');
    await page.click(`${tasks} li button`);
    equal(await page.evaluate(badgeStyle(`${tasks} li span`)), 'solid 999px', 'the new badge class is styled');
    // A server re-render keeps it.
    await page.click('#bump');
    await page.until(`q('#server-count').textContent === 'Server count: 1'`);
    equal(await page.evaluate(badgeStyle(`${tasks} li span`)), 'solid 999px', 'still styled');
    await noErrors(page);
  },

  async 'a live view swapping one island for another starts the new one'(page) {
    await open(page, '/live');
    await swap(page, 'library/islands/rating');
    await page.click(`#swappable [aria-label="Rate 5"]`);
    equal(await page.evaluate(text('#swappable output')), '5 out of 5', 'the rating responds');
    await swap(page, 'howdy_islands_example/islands/ticker');
    await swap(page, 'howdy_islands_example/islands/counter');
    await page.click(`#swappable howdy-island button:last-of-type`);
    equal(await page.evaluate(text('#swappable output')), 'Count: 4', 'the counter responds');
    await noErrors(page);
  },

  async 'a removed island stops, timers included'(page) {
    await open(page, '/live');
    await trackIntervals(page);
    await swap(page, 'library/islands/rating');
    await swap(page, 'howdy_islands_example/islands/ticker');
    await page.until(`Number(q('#swappable output').textContent) >= 3`);
    equal(await page.evaluate(`intervals.size`), 1, 'the ticker’s interval');
    await page.evaluate(`window.removed = q('#swappable howdy-island')`);
    await swap(page, 'howdy_islands_example/islands/counter');
    const ticks = await page.evaluate(`removed.querySelector('output')?.textContent ?? 'cleared'`);
    await new Promise((resolve) => setTimeout(resolve, 400));
    equal(await page.evaluate(`removed.querySelector('output')?.textContent ?? 'cleared'`), ticks, 'the removed ticker no longer counts');
    equal(await page.evaluate(`intervals.size`), 0, 'its interval was cleared');
    ok(!(await page.evaluate(`'running' in removed.dataset`)), 'no longer marked running');
    // Round and round: nothing accumulates.
    for (let round = 0; round < 3; round++) {
      await swap(page, 'library/islands/rating');
      await swap(page, 'howdy_islands_example/islands/ticker');
      await swap(page, 'howdy_islands_example/islands/counter');
    }
    equal(await page.evaluate(`intervals.size`), 0, 'intervals after three rounds');
    await noErrors(page);
  },

  async 'an island removed and put back while its code loads starts once'(page) {
    await open(page, '/live');
    await trackIntervals(page);
    await swap(page, 'library/islands/rating');
    const held = await page.hold('*islands/ticker*');
    await page.click('#swap');
    await page.until(`q('#swappable howdy-island')?.dataset.module === 'howdy_islands_example/islands/ticker'`);
    for (let i = 0; i < 100 && held.held() === 0; i++) await new Promise((resolve) => setTimeout(resolve, 20));
    ok(held.held() > 0, 'the ticker module is held');
    // Out of the page long enough to stop, then back in the same place.
    await page.evaluate(`(async () => {
      const island = q('#swappable howdy-island');
      const parent = island.parentNode, next = island.nextSibling;
      island.remove();
      await new Promise((resolve) => setTimeout(resolve, 50));
      parent.insertBefore(island, next);
    })()`);
    await held.release();
    await page.until(running, 10000);
    await page.until(`Number(q('#swappable output').textContent) >= 2`);
    equal(await page.evaluate(`intervals.size`), 1, 'one ticker interval');
    await swap(page, 'howdy_islands_example/islands/counter');
    equal(await page.evaluate(`intervals.size`), 0, 'none once it is removed');
    await noErrors(page);
  },

};

if (mode === 'release') {
  tests['a release serves the bundle, not the JavaScript build'] = async (page) => {
    await open(page, '/');
    const scripts = await page.evaluate(`performance.getEntriesByType('resource').map((r) => new URL(r.name).pathname).filter((p) => p.startsWith('/_howdy/islands/'))`);
    ok(scripts.includes('/_howdy/islands/boot.mjs'), 'loads the boot module');
    const others = scripts.filter((path) => path !== '/_howdy/islands/boot.mjs');
    ok(others.length > 0 && others.every((path) => /-[A-Z0-9]{8}\.js$/.test(path)), `only hashed bundle files: ${others.join(', ')}`);
  };
}

if (mode === 'dev') {
  tests['development serves an edited island on the next page load'] = async (page) => {
    const file = src('howdy_islands_example/format.gleam');
    const original = readFileSync(file, 'utf8');
    try {
      writeFileSync(file, original.replace('"Count: "', '"Total: "'));
      await open(page, '/');
      // The server still renders with the code it started with; the
      // browser runs the edit.
      await page.click(`${counter(1)} button:last-of-type`);
      equal(await page.evaluate(text(`${counter(1)} output`)), 'Total: 6', 'the edited island');
    } finally {
      writeFileSync(file, original);
    }
  };

  // Effects started with plain Lustre, which island.subscription does not
  // know about: a timeout that re-arms on each update stops with the
  // island, and an interval, which cannot be stopped, is reported.
  tests['a removed island ignores plain Lustre effects, and reports one still running'] = async (page) => {
    const file = src('howdy_islands_example/islands/counter.gleam');
    const ffi = src('howdy_islands_example/islands/timers_ffi.mjs');
    const original = readFileSync(file, 'utf8');
    try {
      writeFileSync(ffi, `
export const every = (ms, f) => { setInterval(f, ms); };
export const after = (ms, f) => { window.armed = (window.armed ?? 0) + 1; setTimeout(f, ms); };
`);
      writeFileSync(file, `
import gleam/dynamic/decode
import gleam/int
import gleam/json
import howdy/ui/island
import lustre/effect
import lustre/element.{text}
import lustre/element/html

pub fn island() {
  island.application(init:, update:, view:, flags: decode.int, encode: json.int)
}

pub type Msg {
  Tick
  Chain
}

@external(javascript, "./timers_ffi.mjs", "every")
fn every(ms: Int, f: fn() -> Nil) -> Nil

@external(javascript, "./timers_ffi.mjs", "after")
fn after(ms: Int, f: fn() -> Nil) -> Nil

fn chain() {
  effect.from(fn(dispatch) { after(20, fn() { dispatch(Chain) }) })
}

fn init(n) {
  #(n, effect.batch([effect.from(fn(dispatch) { every(20, fn() { dispatch(Tick) }) }), chain()]))
}

fn update(n, msg) {
  case msg {
    Tick -> #(n + 1, effect.none())
    Chain -> #(n, chain())
  }
}

fn view(n) {
  html.p([], [html.output([], [text(int.to_string(n))])])
}
`);
      await open(page, '/live');
      await page.evaluate(`(() => {
        window.warnings = [];
        const warn = console.warn;
        console.warn = (...args) => { warnings.push(args.join(' ')); warn(...args); };
      })()`);
      await page.until(`Number(q('#swappable output').textContent) >= 3 && window.armed >= 3`);
      await page.evaluate(`window.removed = q('#swappable howdy-island')`);
      await swap(page, 'library/islands/rating');
      const before = await page.evaluate(`[removed.querySelector('output')?.textContent ?? 'cleared', window.armed]`);
      await new Promise((resolve) => setTimeout(resolve, 300));
      const after = await page.evaluate(`[removed.querySelector('output')?.textContent ?? 'cleared', window.armed]`);
      equal(after[0], 'cleared', 'the removed island no longer renders');
      ok(after[1] <= before[1] + 1, `the timeout chain stopped: armed ${before[1]}, then ${after[1]}`);
      await page.until(`warnings.length > 0`, 8000);
      const warning = await page.evaluate(`warnings[0]`);
      ok(warning.includes('howdy_islands_example/islands/counter.island') && warning.includes('island.subscription'), `the warning: ${warning}`);
    } finally {
      writeFileSync(file, original);
      rmSync(ffi, { force: true });
    }
  };

  tests['development shows an island’s compile error on the page'] = async (page) => {
    const file = src('howdy_islands_example/islands/broken.gleam');
    try {
      writeFileSync(file, 'pub fn island() { 1 + "one" }\n');
      await page.open('/');
      await page.until(`q('[data-howdy-islands-errors]') !== null`, 10000);
      const shown = await page.evaluate(errors);
      ok(shown.includes('broken.gleam'), `names the file: ${shown}`);
    } finally {
      rmSync(file, { force: true });
    }
    // Fixed, the page works again.
    await open(page, '/');
    await noErrors(page);
  };
}

await run(tests, { base: 'http://127.0.0.1:8793' });
