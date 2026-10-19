// Browser tests for the interactive components, against the gallery.
//
//   cd examples/gallery && gleam run          # serves the gallery on :8791
//   node ui/browser_test/run.mjs [filter]
//
// Each test opens one gallery preview, `/ui/<entry>/preview/<index>`, in a
// fresh page. See harness.mjs for the page API.

import { setTimeout as sleep } from 'node:timers/promises';
import { equal, ok, focused, run } from './harness.mjs';

// The inline content of a rich text editor's paragraph, as it would post.
const richDoc = async (page, index) =>
  (await page.evaluate(`JSON.parse(q('[data-howdy-rich-text-value]').value)`)).content[index].content;

// Measure an editor while its code is held back, then once it has taken
// over. A page can only do this once: the code is cached after.
const sameHeightOnceReady = async (page, preview) => {
  const held = await page.hold('*_howdy/rich-text/*');
  await page.goto(`/rich_text/preview/${preview}`);
  const height = `Math.round(q('howdy-rich-text').getBoundingClientRect().height)`;
  const before = await page.evaluate(height);
  ok(!(await page.evaluate(`q('howdy-rich-text').hasAttribute('data-ready')`)), 'measured before the editor loaded');
  await held.release();
  await page.until(`q('howdy-rich-text')?.hasAttribute('data-ready')`, 5000);
  equal(await page.evaluate(height), before, 'height');
};

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

  async 'a rich text editor formats as you type and posts the document'(page) {
    await page.goto('/rich_text/preview/0');
    await page.until(`q('howdy-rich-text')?.hasAttribute('data-ready')`, 5000);
    equal(await page.evaluate(`document.querySelector('#comment-form').checkValidity()`), false, 'required and empty');
    await page.click('howdy-rich-text [contenteditable]');
    await page.type('Hello ');
    await page.press('b', 2);
    equal(await page.evaluate(`q('[data-command=bold]').getAttribute('aria-pressed')`), 'true', 'bold pressed');
    await page.type('world');
    await page.press('b', 2);
    await page.type('!');
    equal(await richDoc(page, 0), [{ type: 'text', text: 'Hello ' }, { type: 'text', marks: [{ type: 'bold' }], text: 'world' }, { type: 'text', text: '!' }], 'bold from the keyboard');
    equal(await page.evaluate(`document.querySelector('#comment-form').checkValidity()`), true, 'valid with text');
    // Markdown-like shortcuts.
    await page.press('Enter');
    await page.type('# Title');
    await page.press('Enter');
    await page.type('- one');
    await page.press('Enter');
    await page.type('two');
    await page.press('Enter');
    await page.press('Enter');
    await page.type('a `tick` and **strong**');
    const doc = await page.evaluate(`JSON.parse(q('[data-howdy-rich-text-value]').value)`);
    equal(doc.content.map((node) => node.type), ['paragraph', 'heading', 'bullet_list', 'paragraph'], 'blocks');
    equal(doc.content[1].attrs.level, 1, 'heading level');
    equal(doc.content[2].content.length, 2, 'two list items');
    equal(doc.content[3].content, [{ type: 'text', text: 'a ' }, { type: 'text', marks: [{ type: 'code' }], text: 'tick' }, { type: 'text', text: ' and ' }, { type: 'text', marks: [{ type: 'bold' }], text: 'strong' }], 'inline shortcuts');
    ok(!(await page.evaluate(`q('[data-command=undo]').disabled`)), 'undo enabled');
  },

  async 'mentions are suggested by the search endpoint and posted with their ids'(page) {
    await page.goto('/rich_text/preview/0');
    await page.until(`q('howdy-rich-text')?.hasAttribute('data-ready')`, 5000);
    await page.click('howdy-rich-text [contenteditable]');
    await page.type('Thanks @gr');
    const menuOpen = `q('[data-howdy-rich-text-menu]').matches(':popover-open')`;
    const labels = `[...document.querySelectorAll('[data-howdy-rich-text-options] [role=option] > span:nth-child(2)')].map((el) => el.textContent)`;
    await page.until(`${menuOpen} && ${labels}.length === 1`, 3000);
    equal(await page.evaluate(labels), ['Grace Hopper'], 'suggestions');
    equal(await page.evaluate(`q('[contenteditable]').getAttribute('aria-activedescendant')`), await page.evaluate(`q('[role=option]').id`), 'active option announced');
    await page.press('Enter');
    equal(await page.evaluate(menuOpen), false, 'closed once chosen');
    await page.type('and #4');
    await page.until(`${menuOpen} && ${labels}.length === 1`, 3000);
    await page.press('Tab');
    // Escape closes the list, and it stays closed for that mention.
    // Choosing adds a space after the mention.
    await page.type('@a');
    await page.until(`${menuOpen} && ${labels}.length > 1`, 3000);
    await page.press('ArrowDown');
    equal(await page.evaluate(`q('[role=option][aria-selected=true] > span:nth-child(2)').textContent`), await page.evaluate(`${labels}[1]`), 'arrow moves');
    await page.press('Escape');
    equal(await page.evaluate(menuOpen), false, 'escape closes');
    await page.type('d');
    await sleep(300);
    equal(await page.evaluate(menuOpen), false, 'stays closed');
    const inline = (await richDoc(page, 0)).filter((node) => node.type === 'mention').map((node) => node.attrs);
    equal(inline, [{ trigger: '@', kind: 'person', id: '3', label: 'Grace Hopper' }, { trigger: '#', kind: 'issue', id: '42', label: '42' }], 'mentions in the document');
    await page.click('#comment-form button[type=submit]');
    await page.until(`q('#rich-text-mentions')?.textContent === 'person:3 issue:42'`, 5000);
    equal(await page.evaluate(`q('#rich-text-plain').textContent`), 'Thanks @Grace Hopper and #42 @ad', 'plain text');
    equal(await page.evaluate(`q('#rich-text-shown a[data-mention=person]').getAttribute('href')`), '#person-3', 'drawn by the server');
  },

  async 'links are added from the toolbar, and unsafe ones refused'(page) {
    await page.goto('/rich_text/preview/2');
    await page.until(`q('howdy-rich-text')?.hasAttribute('data-ready')`, 5000);
    await page.click('howdy-rich-text [contenteditable]');
    await page.type('Read the docs');
    for (let i = 0; i < 4; i++) await page.press('ArrowLeft', 8);
    await page.click('[data-command=link]');
    ok(await page.evaluate(`q('[data-howdy-rich-text-link]').matches(':popover-open')`), 'link form open');
    ok(await page.evaluate(`document.activeElement.matches('[data-howdy-rich-text-link-input]')`), 'address focused');
    await page.type('javascript:alert(1)');
    await page.press('Enter');
    equal(await page.evaluate(`q('[data-howdy-rich-text-link-input]').validationMessage`), 'Enter a web address, such as https://example.com.', 'refused');
    await page.evaluate(`q('[data-howdy-rich-text-link-input]').value = ''`);
    await page.type('example.com/docs');
    await page.press('Enter');
    equal(await page.evaluate(`q('[data-howdy-rich-text-link]').matches(':popover-open')`), false, 'closed');
    equal(await richDoc(page, 0), [{ type: 'text', text: 'Read the ' }, { type: 'text', marks: [{ type: 'link', attrs: { href: 'https://example.com/docs' } }], text: 'docs' }], 'linked');
    equal(await page.evaluate(`q('[data-command=link]').getAttribute('aria-pressed')`), 'true', 'link pressed in a link');
    ok(await page.evaluate(`q('[contenteditable]').contains(document.activeElement) || document.activeElement.matches('[contenteditable]')`), 'focus back in the text');
  },

  async 'pasted HTML keeps only what a document can hold'(page) {
    await page.goto('/rich_text/preview/2');
    await page.until(`q('howdy-rich-text')?.hasAttribute('data-ready')`, 5000);
    await page.click('howdy-rich-text [contenteditable]');
    await page.evaluate(`(() => {
      const data = new DataTransfer();
      data.setData('text/html', '<p>Hi <b>bold</b> <a href="javascript:window.pwned=1">bad</a> <a href="https://ok.example/">good</a><script>window.pwned=1<\/script><img src=x onerror="window.pwned=1"></p><h1>Head</h1><table><tr><td>cell</td></tr></table>');
      data.setData('text/plain', 'Hi bold bad good');
      q('[contenteditable]').dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
    })()`);
    await sleep(200);
    const doc = await page.evaluate(`JSON.parse(q('[data-howdy-rich-text-value]').value)`);
    const json = JSON.stringify(doc);
    ok(!json.includes('javascript'), 'no javascript link');
    ok(json.includes('https://ok.example/'), 'the safe link is kept');
    ok(json.includes('"bold"'), 'bold is kept');
    ok(json.includes('cell') && json.includes('Head'), 'text from elsewhere is kept');
    ok(!/image|img|script|table/.test(json), 'nothing else');
    equal(await page.evaluate(`window.pwned`), undefined, 'nothing ran');
  },

  async 'an editor sends pasted and chosen files to storage and posts their keys'(page) {
    await page.goto('/rich_text/preview/1');
    await page.until(`q('howdy-rich-text')?.hasAttribute('data-ready')`, 5000);
    await page.click('howdy-rich-text [contenteditable] h2');
    await page.press('End');
    await page.chooseFiles('[data-howdy-rich-text-files]', [page.file('notes.txt', 'hello, storage')]);
    // A picture pasted from the clipboard.
    await page.evaluate(`(async () => {
      const canvas = document.createElement('canvas');
      canvas.width = canvas.height = 2;
      const blob = await new Promise((r) => canvas.toBlob(r, 'image/png'));
      const data = new DataTransfer();
      data.items.add(new File([blob], 'dot.png', { type: 'image/png' }));
      q('[contenteditable]').dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
    })()`);
    const files = `JSON.parse(q('[data-howdy-rich-text-value]').value).content.filter((node) => node.type === 'attachment').map((node) => node.attrs)`;
    await page.until(`${files}.length === 2`, 5000);
    const attached = await page.evaluate(files);
    ok(attached.every((file) => file.key.startsWith('uploads/')), 'keys from the start endpoint');
    equal(attached.map((file) => [file.name, file.content_type, file.size]).sort(), [['dot.png', 'image/png', attached.find((file) => file.name === 'dot.png').size], ['notes.txt', 'text/plain', 14]], 'what was attached');
    equal(await page.evaluate(`[...document.querySelectorAll('[contenteditable] figure [data-part=name]')].map((el) => el.textContent).sort()`), ['dot.png', 'notes.txt'], 'shown as attachments');
    ok(await page.evaluate(`[...document.querySelectorAll('[contenteditable] figure img')].some((img) => !img.hidden && img.src.startsWith('blob:'))`), 'the picture is shown');
    equal(await page.evaluate(`q('[data-howdy-rich-text-proxy]').validationMessage`), '', 'the form may submit');
    await page.click('#article-form button[type=submit]');
    await page.until(`q('#rich-text-attachments')?.textContent.split(' ').length === 2`, 5000);
    ok(await page.evaluate(`q('#rich-text-attachments').textContent.split(' ').every((entry) => entry.endsWith('=found'))`), 'stored');
    ok(await page.evaluate(`q('#rich-text-shown figure img').src.includes('/files/')`), 'the picture drawn from storage');
    await page.until(`q('howdy-rich-text')?.hasAttribute('data-ready')`, 5000);
    ok(await page.evaluate(`[...document.querySelectorAll('[contenteditable] figure img')].some((img) => !img.hidden && img.src.includes('/files/'))`), 'and in the editor again');
  },

  async 'removing an attachment takes it out of the document'(page) {
    await page.goto('/rich_text/preview/1');
    await page.until(`q('howdy-rich-text')?.hasAttribute('data-ready')`, 5000);
    await page.click('howdy-rich-text [contenteditable] h2');
    await page.chooseFiles('[data-howdy-rich-text-files]', [page.file('gone.txt', 'bye')]);
    const count = `JSON.parse(q('[data-howdy-rich-text-value]').value).content.filter((node) => node.type === 'attachment').length`;
    await page.until(`${count} === 1`, 5000);
    await page.click('[contenteditable] figure [data-part=remove]');
    equal(await page.evaluate(count), 0, 'removed');
    equal(await page.evaluate(`document.querySelectorAll('[contenteditable] figure').length`), 0, 'and not shown');
  },

  async 'nothing moves when an empty editor takes over from the server drawing'(page) {
    await sameHeightOnceReady(page, 0);
  },

  async 'nothing moves when a written editor takes over from the server drawing'(page) {
    await sameHeightOnceReady(page, 1);
  },

  async 'a required editor keeps an empty form from submitting'(page) {
    await page.goto('/rich_text/preview/0');
    await page.until(`q('howdy-rich-text')?.hasAttribute('data-ready')`, 5000);
    equal(await page.evaluate(`getComputedStyle(q('[contenteditable] p'), '::before').content`), '"Add a comment… type @ to mention someone"', 'placeholder shown');
    await page.click('#comment-form button[type=submit]');
    await sleep(200);
    ok(await page.evaluate(`location.pathname.startsWith('/ui/')`), 'still on the page');
    equal(await page.evaluate(`q('[data-howdy-rich-text-proxy]').validationMessage`), 'Write something.', 'why');
    // Spaces alone are still empty.
    await page.click('howdy-rich-text [contenteditable]');
    await page.type('   ');
    equal(await page.evaluate(`document.querySelector('#comment-form').checkValidity()`), false, 'spaces are empty');
    await page.type('ok');
    equal(await page.evaluate(`document.querySelector('#comment-form').checkValidity()`), true, 'then valid');
    // A label pointing at the editor's id focuses the editor.
    await page.evaluate(`(() => { const label = document.createElement('label'); label.htmlFor = q('[data-howdy-rich-text-proxy]').id; label.id = 'probe-label'; label.textContent = 'Comment'; document.body.prepend(label); document.activeElement.blur(); })()`);
    await page.click('#probe-label');
    await page.until(`document.activeElement.matches('[contenteditable]')`);
  },

  async 'the toolbar is one stop in the tab order'(page) {
    await page.goto('/rich_text/preview/2');
    await page.until(`q('howdy-rich-text')?.hasAttribute('data-ready')`, 5000);
    await page.focus('[data-command=bold]');
    await page.press('ArrowRight');
    equal(await page.evaluate(`document.activeElement.getAttribute('aria-label')`), 'Italic', 'arrow moves');
    equal(await page.evaluate(`[...document.querySelectorAll('[data-command]')].map((el) => el.tabIndex)`), [-1, 0, -1], 'one stop');
    await page.press('End');
    equal(await page.evaluate(`document.activeElement.getAttribute('aria-label')`), 'Link', 'end');
  },

  async 'a live view hears the editor when it loses focus, and can replace its document'(page) {
    await page.open('/lab');
    await page.until(`q('howdy-rich-text')?.hasAttribute('data-ready')`, 5000);
    await page.click('howdy-rich-text [contenteditable] p');
    await page.press('End');
    await page.type(' and me');
    const heard = `q('#lab-note-heard').textContent`;
    equal(await page.evaluate(heard), '0: Hello from the server', 'not heard while typing');
    await page.click('#lab-plan');
    await page.press('Escape');
    await page.until(`${heard} === '1: Hello from the server and me'`, 3000);
    equal(await page.evaluate(`q('howdy-rich-text [contenteditable]').textContent`), 'Hello from the server and me', 'the patch left the editor alone');
    // Mentions inside a shadow root.
    await page.click('howdy-rich-text [contenteditable] p');
    await page.press('End');
    await page.type(' @mar');
    await page.until(`q('[data-howdy-rich-text-menu]').matches(':popover-open') && q('[role=option]')`, 3000);
    await page.press('Enter');
    ok(await page.evaluate(`Boolean(q('[contenteditable] [data-howdy-mention=person][data-id="5"]'))`), 'mentioned in a live view');
    // The server clears it.
    await page.click('#lab-note-clear');
    await page.until(`q('howdy-rich-text [contenteditable]').textContent === ''`, 3000);
    equal(await page.evaluate(`JSON.parse(q('[data-howdy-rich-text-value]').value)`), { type: 'doc', content: [{ type: 'paragraph' }] }, 'empty value');
    await page.click('howdy-rich-text [contenteditable]');
    await page.type('again');
    await page.click('#lab-plan');
    await page.press('Escape');
    await page.until(`${heard}.endsWith(': again')`, 3000);
  },

  async 'a questionnaire shows its first question'(page) {
    await page.goto('/questionnaire/preview/0');
    equal(await page.evaluate(`document.querySelector('legend').textContent.trim()`), 'What do you mostly do?', 'prompt');
    equal(await page.evaluate(`[...document.querySelectorAll('form button')].map((el) => el.textContent.trim())`), ['Next'], 'only next on a required first question');
  },
};

await run(tests, { base: 'http://127.0.0.1:8791/ui' });
