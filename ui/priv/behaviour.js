if (!window.howdyBehaviour) {
window.howdyBehaviour = true;
const hasCommands = 'command' in HTMLButtonElement.prototype;
const hasClosedBy = 'closedBy' in HTMLDialogElement.prototype;
const hasAnchors = CSS.supports('anchor-name: --a');
const openers = new WeakMap();
const watched = new WeakSet();
const tooltips = new WeakMap();
// Popovers closing because another is taking over, so focus stays put.
const handingOver = new WeakSet();
// Popovers opened by pointing, which should not take focus.
const quiet = new WeakSet();

const byId = (node, id) => (id ? node.getRootNode().getElementById(id) : null);
const inPath = (event, selector) =>
  event.composedPath().find((node) => node instanceof Element && node.matches(selector));
const enabled = (container, selector) =>
  [...container.querySelectorAll(selector)].filter((el) => !el.matches(':disabled, [aria-disabled=true]'));
const isOpen = (popover) => popover.matches(':popover-open');
// A menu's or listbox's own items, not those of a submenu inside it.
const ownItems = (popup) =>
  enabled(popup, '[role^=menuitem], [role=option]').filter((el) => el.closest('[role=menu], [role=listbox]') === popup);
// The menu a submenu, or its submenu, belongs to.
const outermost = (el) => {
  let menu = el.closest('[role=menu][popover]');
  while (menu?.parentElement?.closest('[role=menu][popover]')) menu = menu.parentElement.closest('[role=menu][popover]');
  return menu;
};
const wide = matchMedia('(min-width: 768px)');
// The document and the shadow roots of the live views on it.
const roots = () => [
  document,
  ...[...document.querySelectorAll('lustre-server-component')].map((host) => host.shadowRoot).filter(Boolean),
];
// Left and right as the reader sees them: swapped in right-to-left text.
const rtl = (el) => getComputedStyle(el).direction === 'rtl';
const logical = (key, el) => {
  if (!rtl(el)) return key;
  if (key === 'ArrowLeft') return 'ArrowRight';
  if (key === 'ArrowRight') return 'ArrowLeft';
  return key;
};
const deepFocus = () => {
  let focused = document.activeElement;
  while (focused?.shadowRoot?.activeElement) focused = focused.shadowRoot.activeElement;
  return focused;
};

// Without anchor positioning, put a floating element beside its anchor.
const place = (floating, anchor) => {
  if (hasAnchors) return;
  floating.style.visibility = '';
  // Context menus are placed at the pointer when they open.
  if (!anchor || floating.hasAttribute('data-howdy-at-pointer')) return;
  const a = anchor.getBoundingClientRect();
  const f = floating.getBoundingClientRect();
  const gap = 6;
  const above = floating.dataset.howdySide === 'top';
  let top = above ? a.top - f.height - gap : a.bottom + gap;
  if (!above && top + f.height > innerHeight) top = Math.max(gap, a.top - f.height - gap);
  if (above && top < 0) top = a.bottom + gap;
  let left = above ? a.left + (a.width - f.width) / 2 : a.left;
  left = Math.max(gap, Math.min(left, innerWidth - f.width - gap));
  Object.assign(floating.style, { inset: 'auto', margin: '0', top: top + 'px', left: left + 'px' });
};

// Anchor names come from data attributes rather than inline styles, which a
// strict Content Security Policy forbids: a popover with `data-howdy-anchored`
// is tied to the elements naming it in `data-howdy-anchor` each time it opens.
const anchor = (popover) => {
  const name = popover.dataset.howdyAnchored;
  if (!name) return;
  popover.style.setProperty('position-anchor', name);
  for (const el of popover.getRootNode().querySelectorAll(`[data-howdy-anchor='${CSS.escape(name)}']`)) {
    el.style.setProperty('anchor-name', name);
  }
};

// Popovers are watched from the first time something opens them.
const watch = (popover) => {
  if (watched.has(popover)) return;
  watched.add(popover);
  let hadFocus = false;
  popover.addEventListener('beforetoggle', (event) => {
    if (event.newState === 'open') anchor(popover);
    if (event.newState === 'open' && !hasAnchors) popover.style.visibility = 'hidden';
    if (event.newState === 'closed') hadFocus = popover.contains(deepFocus());
  });
  popover.addEventListener('toggle', (event) => {
    const opener = openers.get(popover);
    if (opener?.matches('[role=menubar] > *, [data-howdy-submenu-trigger]')) {
      opener.setAttribute('aria-expanded', String(event.newState === 'open'));
    }
    // Browsers put focus back on the shadow host, not the trigger, when a
    // popover in a live view closes, so put it back ourselves.
    if (event.newState === 'closed') {
      const focused = deepFocus();
      if (handingOver.delete(popover)) return;
      if (hadFocus && (!focused || focused === document.body || focused === popover.getRootNode().host || popover.contains(focused))) openers.get(popover)?.focus();
      return;
    }
    place(popover, openers.get(popover));
    if (quiet.delete(popover)) return;
    if (popover.matches('[role=menu], [role=listbox]')) {
      const items = ownItems(popover);
      (items.find((el) => el.getAttribute('aria-selected') === 'true') || items[0])?.focus();
      return;
    }
    popover.querySelector(`[data-howdy-command] > input, [data-howdy-calendar] [data-date][tabindex='0']`)?.focus();
    const command = popover.querySelector('[data-howdy-command]');
    if (command) activate(command, commandItems(command).find((el) => el.matches('[aria-selected=true]')) || commandItems(command)[0]);
  });
};

const open = (popover, opener) => {
  openers.set(popover, opener);
  watch(popover);
  if (!isOpen(popover)) popover.showPopover({ source: opener });
};

const close = (popover) => {
  if (isOpen(popover)) popover.hidePopover();
  openers.get(popover)?.focus();
};

const selectTab = (tab) => {
  for (const other of tab.closest('[role=tablist]').querySelectorAll('[role=tab]')) {
    const selected = other === tab;
    other.setAttribute('aria-selected', String(selected));
    other.tabIndex = selected ? 0 : -1;
    const panel = byId(other, other.getAttribute('aria-controls'));
    if (panel) panel.hidden = !selected;
  }
};

// Change a text node in place: live views patch the node they rendered.
const setText = (node, text) => {
  if (node.firstChild?.nodeType === Node.TEXT_NODE) node.firstChild.data = text;
  else node.textContent = text;
};

const setValue = (input, value) => {
  if (!input || input.value === value) return;
  input.value = value;
  input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
  input.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
};

// A select, combobox or date picker: show the choice, close, keep the value.
const settle = (root, value, label, from) => {
  setText(root.querySelector('[data-howdy-select-value]'), label);
  root.querySelector('[data-howdy-select-trigger]').removeAttribute('data-placeholder');
  const clear = root.querySelector('[data-howdy-select-clear]');
  if (clear) clear.hidden = false;
  close(from.closest('[popover]'));
  setValue(root.querySelector(':scope > input'), value);
};

// Show whatever options are chosen: their labels, or the placeholder. A
// multiple combobox shows chips instead, and sends one field per value by
// enabling that value's hidden input.
const showChosen = (root) => {
  const chosen = [...root.querySelectorAll('[role=option][aria-selected=true]')];
  if (root.hasAttribute('data-multiple')) {
    const values = chosen.map((o) => o.dataset.value);
    for (const chip of root.querySelectorAll('[data-howdy-chip]')) chip.hidden = !values.includes(chip.dataset.value);
    for (const input of root.querySelectorAll(':scope > input[data-howdy-choice]')) input.disabled = !values.includes(input.value);
    root.querySelector('[data-howdy-select-trigger]').toggleAttribute('data-placeholder', !values.length);
    const clear = root.querySelector('[data-howdy-select-clear]');
    if (clear) clear.hidden = !values.length;
    root.dispatchEvent(new CustomEvent('howdy-values', { bubbles: true, composed: true, detail: { name: root.dataset.name, values } }));
    return;
  }
  const value = root.querySelector('[data-howdy-select-value]');
  setText(value, chosen.length ? chosen.map((o) => o.textContent.trim()).join(', ') : value.dataset.howdyPlaceholder);
  root.querySelector('[data-howdy-select-trigger]').toggleAttribute('data-placeholder', !chosen.length);
  const clear = root.querySelector('[data-howdy-select-clear]');
  if (clear) clear.hidden = !chosen.length;
  setValue(root.querySelector(':scope > input'), chosen.map((o) => o.dataset.value).join(','));
};

const choose = (option) => {
  if (option.matches('[aria-disabled=true]')) return;
  const root = option.closest('[data-howdy-select]');
  // Choosing in a multiple combobox toggles the option and stays open.
  if (root.hasAttribute('data-multiple')) {
    option.setAttribute('aria-selected', String(option.getAttribute('aria-selected') !== 'true'));
    return showChosen(root);
  }
  for (const other of root.querySelectorAll('[role=option]')) {
    other.setAttribute('aria-selected', String(other === option));
  }
  settle(root, option.dataset.value, option.textContent.trim(), option);
};

// A day chosen in a calendar: one date, the start or end of a range, or one
// of several dates, kept in the hidden input as the server expects it.
const pickDay = (day) => {
  const calendar = day.closest('[data-howdy-calendar]');
  const picker = day.closest('[data-howdy-select]');
  const input = (picker || calendar).querySelector(':scope > input');
  const mode = calendar.dataset.mode || 'single';
  const date = day.dataset.date;
  const days = [...calendar.querySelectorAll('[data-date]')];
  const mark = (chosen, from, to) => {
    for (const other of days) {
      const it = other.dataset.date;
      other.setAttribute('aria-pressed', String(chosen.includes(it)));
      other.toggleAttribute('data-in-range', Boolean(from && to && it > from && it < to));
      other.tabIndex = other === day ? 0 : -1;
    }
  };
  if (mode === 'multiple') {
    const chosen = new Set((input?.value || '').split(',').filter(Boolean));
    if (chosen.has(date)) chosen.delete(date);
    else chosen.add(date);
    const value = [...chosen].sort();
    mark(value, null, null);
    if (picker) {
      const labels = value.map((it) => days.find((d) => d.dataset.date === it)?.dataset.label || it);
      setText(picker.querySelector('[data-howdy-select-value]'), labels.length ? labels.join(', ') : picker.querySelector('[data-howdy-select-value]').dataset.howdyPlaceholder);
      picker.querySelector('[data-howdy-select-trigger]').toggleAttribute('data-placeholder', !labels.length);
    }
    setValue(input, value.join(','));
    return;
  }
  if (mode === 'range') {
    let [from, to] = (input?.value || '/').split('/');
    if (!from || to) {
      from = date;
      to = '';
    } else if (date < from) {
      to = from;
      from = date;
    } else {
      to = date;
    }
    mark([from, to].filter(Boolean), from, to);
    if (picker) {
      // The start may be in a month no longer shown; remember its label.
      const labelOf = (it) =>
        days.find((d) => d.dataset.date === it)?.dataset.label ||
        (it === picker.dataset.fromDate ? picker.dataset.fromLabel : it);
      const text = labelOf(from) + ' – ' + (to ? labelOf(to) : '…');
      if (!to) {
        picker.dataset.fromDate = date;
        picker.dataset.fromLabel = day.dataset.label;
      }
      setText(picker.querySelector('[data-howdy-select-value]'), text);
      picker.querySelector('[data-howdy-select-trigger]').removeAttribute('data-placeholder');
      if (to) close(day.closest('[popover]'));
    }
    setValue(input, from + '/' + to);
    return;
  }
  mark([date], null, null);
  if (picker) settle(picker, date, day.dataset.label, day);
  else setValue(input, date);
};

const moveDay = (day, days) => {
  const calendar = day.closest('[data-howdy-calendar]');
  let next = day;
  do {
    const date = new Date(next.dataset.date + 'T00:00:00Z');
    date.setUTCDate(date.getUTCDate() + days);
    next = calendar.querySelector(`[data-date='${date.toISOString().slice(0, 10)}']`);
  } while (next?.disabled);
  return next;
};

const commandItems = (command) =>
  [...command.querySelectorAll('[role=option]')].filter((el) => !el.hidden && !el.matches('[aria-disabled=true]'));

// The option Enter would choose. Focus stays in the search box.
const activate = (command, item) => {
  const input = command.querySelector(':scope > input');
  for (const el of command.querySelectorAll('[data-active]')) el.removeAttribute('data-active');
  if (!item) return input.removeAttribute('aria-activedescendant');
  if (!item.id) item.id = input.id + '-option-' + [...command.querySelectorAll('[role=option]')].indexOf(item);
  item.setAttribute('data-active', '');
  input.setAttribute('aria-activedescendant', item.id);
  item.scrollIntoView({ block: 'nearest' });
};

const filter = (command) => {
  const input = command.querySelector(':scope > input');
  if (!input.hasAttribute('data-howdy-server-filtered')) {
    const words = input.value.toLowerCase().split(' ').filter(Boolean);
    for (const item of command.querySelectorAll('[role=option]')) {
      const text = ((item.dataset.keywords || '') + ' ' + item.textContent).toLowerCase();
      item.hidden = !words.every((word) => text.includes(word));
    }
    for (const group of command.querySelectorAll('[role=group]')) {
      group.hidden = !group.querySelector('[role=option]:not([hidden])');
    }
    const empty = command.querySelector('[data-howdy-command-empty]');
    if (empty) empty.hidden = !!command.querySelector('[role=option]:not([hidden])');
  }
  activate(command, commandItems(command)[0]);
};

const step = (items, current, key) => {
  const i = items.indexOf(current);
  if (key === 'Home') return items[0];
  if (key === 'End') return items[items.length - 1];
  if (key === 'ArrowDown' || key === 'ArrowRight') return items[(i + 1) % items.length];
  return items[(i - 1 + items.length) % items.length];
};

let typed = '';
let typedAt = 0;
const typeahead = (items, current, key) => {
  const now = Date.now();
  typed = (now - typedAt > 600 ? '' : typed) + key.toLowerCase();
  typedAt = now;
  const i = items.indexOf(current) + (typed.length > 1 ? 0 : 1);
  const ordered = [...items.slice(i), ...items.slice(0, i)];
  return ordered.find((el) => el.textContent.trim().toLowerCase().startsWith(typed));
};

// Tooltips and hover cards: shown after a pause on hover or focus, kept
// while the pointer or focus is on them.
const tooltip = (trigger) => {
  if (tooltips.has(trigger)) return tooltips.get(trigger);
  const card = trigger.hasAttribute('data-howdy-hover-card');
  const tip = byId(trigger, card ? trigger.dataset.howdyHoverCard : trigger.dataset.howdyTooltip);
  if (!tip) return null;
  const [openAfter, closeAfter] = card ? [500, 300] : [300, 100];
  let timer;
  const show = () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      if (isOpen(tip)) return;
      anchor(tip);
      if (!hasAnchors) tip.style.visibility = 'hidden';
      tip.showPopover();
      place(tip, trigger);
    }, openAfter);
  };
  const hide = () => {
    clearTimeout(timer);
    timer = setTimeout(() => isOpen(tip) && tip.hidePopover(), closeAfter);
  };
  trigger.addEventListener('pointerenter', show);
  trigger.addEventListener('pointerleave', hide);
  trigger.addEventListener('focus', show);
  trigger.addEventListener('blur', hide);
  trigger.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && isOpen(tip)) tip.hidePopover();
  });
  tip.addEventListener('pointerenter', () => clearTimeout(timer));
  tip.addEventListener('pointerleave', hide);
  tip.addEventListener('focusin', () => clearTimeout(timer));
  tip.addEventListener('focusout', hide);
  tip.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && isOpen(tip)) {
      tip.hidePopover();
      trigger.focus();
    }
  });
  tooltips.set(trigger, show);
  return show;
};

// The first hover or focus wires a tooltip up, then shows it.
const startTooltip = (event) => {
  const trigger = inPath(event, '[data-howdy-tooltip], [data-howdy-hover-card]');
  if (trigger && !tooltips.has(trigger)) tooltip(trigger)?.();
};
document.addEventListener('pointerover', startTooltip);
document.addEventListener('focusin', startTooltip);

document.addEventListener('pointerover', (event) => {
  const item = inPath(event, '[data-howdy-command] [role=option]');
  if (item && !item.matches('[aria-disabled=true]')) activate(item.closest('[data-howdy-command]'), item);
});

document.addEventListener('focusin', (event) => {
  const input = event.composedPath()[0];
  if (!(input instanceof HTMLInputElement) || !input.parentElement?.matches('[data-howdy-command]')) return;
  const command = input.parentElement;
  if (!command.querySelector('[data-active]:not([hidden])')) activate(command, commandItems(command)[0]);
});

document.addEventListener('input', (event) => {
  const input = event.composedPath()[0];
  if (input instanceof HTMLInputElement && input.parentElement?.matches('[data-howdy-command]')) filter(input.parentElement);
});

// A letter with Cmd or Ctrl opens the command dialog that claims it.
document.addEventListener('keydown', (event) => {
  if (!(event.metaKey || event.ctrlKey) || event.altKey || event.key.length !== 1) return;
  const selector = `dialog[data-howdy-shortcut='${CSS.escape(event.key.toLowerCase())}']`;
  for (const root of roots()) {
    const dialog = root.querySelector(selector);
    if (!dialog) continue;
    event.preventDefault();
    if (dialog.open) dialog.close();
    else dialog.showModal();
    return;
  }
});

// A sidebar opened over a narrow screen closes when the screen widens.
wide.addEventListener('change', () => {
  if (!wide.matches) return;
  for (const root of roots()) {
    for (const sidebar of root.querySelectorAll('[data-howdy-sidebar-layout] > aside:popover-open')) sidebar.hidePopover();
  }
});

// Move a resizable handle by `delta`, in the same shares as the panels'
// sizes. No panel goes below a tenth of the group.
// A panel's share; a collapsed panel's is 0, not missing.
const grow = (panel) => {
  const share = parseFloat(panel.style.flexGrow);
  return Number.isNaN(share) ? 1 : share;
};
const shares = (group) =>
  [...group.children]
    .filter((el) => el.getAttribute('role') !== 'separator')
    .reduce((sum, el) => sum + grow(el), 0);
const minShare = (panel, all) =>
  panel.hasAttribute('data-collapsed') ? 0 : ((parseFloat(panel.dataset.min) || 10) / 100) * all;
const resizeBy = (handle, delta) => {
  const before = handle.previousElementSibling;
  const after = handle.nextElementSibling;
  if (!before || !after) return;
  const a = grow(before);
  const b = grow(after);
  const all = shares(handle.parentElement);
  const next = Math.min(Math.max(a + delta, minShare(before, all)), a + b - minShare(after, all));
  before.style.flexGrow = String(next);
  after.style.flexGrow = String(a + b - next);
  handle.setAttribute('aria-valuenow', String(Math.round((next / all) * 100)));
};
// Remembered groups keep their sizes in a cookie, for the next page.
const remember = (group) => {
  const id = group.dataset.howdyRemember;
  if (!id) return;
  const sizes = [...group.children]
    .filter((el) => el.getAttribute('role') !== 'separator')
    .map((el) => Math.round(parseFloat(el.style.flexGrow) || 0));
  document.cookie = 'resizable-' + id + '=' + sizes.join('_') + ';path=/;max-age=31536000;samesite=lax';
};
// A collapsible panel folds away into its neighbour, and back.
const collapse = (handle) => {
  const before = handle.previousElementSibling;
  const after = handle.nextElementSibling;
  if (!before?.hasAttribute('data-collapsible') || !after) return;
  const a = parseFloat(before.style.flexGrow) || 0;
  const b = parseFloat(after.style.flexGrow) || 0;
  if (before.hasAttribute('data-collapsed')) {
    const back = parseFloat(before.dataset.restore) || 25;
    before.removeAttribute('data-collapsed');
    before.style.flexGrow = String(back);
    after.style.flexGrow = String(Math.max(b - back, 0));
  } else {
    before.dataset.restore = String(a);
    before.setAttribute('data-collapsed', '');
    before.style.flexGrow = '0';
    after.style.flexGrow = String(a + b);
  }
  resizeBy(handle, 0);
  remember(handle.parentElement);
};
document.addEventListener('dblclick', (event) => {
  const handle = inPath(event, '[data-howdy-resizable] > [role=separator]');
  if (handle) collapse(handle);
});

document.addEventListener('pointerdown', (event) => {
  const handle = inPath(event, '[data-howdy-resizable] > [role=separator]');
  if (!handle || event.button !== 0) return;
  event.preventDefault();
  handle.focus();
  const group = handle.parentElement;
  const vertical = group.dataset.howdyResizable === 'vertical';
  const size = vertical ? group.clientHeight : group.clientWidth;
  const all = shares(group);
  let last = vertical ? event.clientY : event.clientX;
  // Keep receiving moves when the pointer leaves the thin handle.
  try {
    handle.setPointerCapture(event.pointerId);
  } catch {}
  const move = (moved) => {
    const now = vertical ? moved.clientY : moved.clientX;
    const flip = !vertical && rtl(group) ? -1 : 1;
    resizeBy(handle, ((now - last) / size) * all * flip);
    last = now;
  };
  const stop = () => {
    remember(group);
    handle.removeEventListener('pointermove', move);
    handle.removeEventListener('pointerup', stop);
    handle.removeEventListener('pointercancel', stop);
  };
  handle.addEventListener('pointermove', move);
  handle.addEventListener('pointerup', stop);
  handle.addEventListener('pointercancel', stop);
});

// A right click, or the context menu key, in an area opens its menu there.
document.addEventListener('contextmenu', (event) => {
  const area = inPath(event, '[data-howdy-context-menu]');
  if (!area) return;
  const popup = byId(area, area.dataset.howdyContextMenu);
  if (!popup) return;
  event.preventDefault();
  const focused = deepFocus();
  openers.set(popup, focused && area.contains(focused) ? focused : null);
  watch(popup);
  if (isOpen(popup)) popup.hidePopover();
  let x = event.clientX;
  let y = event.clientY;
  if (!x && !y) {
    const r = (focused && area.contains(focused) ? focused : area).getBoundingClientRect();
    x = r.left;
    y = r.bottom;
  }
  Object.assign(popup.style, { inset: 'auto', margin: '0', left: x + 'px', top: y + 'px' });
  popup.showPopover();
  const r = popup.getBoundingClientRect();
  if (r.right > innerWidth) popup.style.left = Math.max(4, innerWidth - r.width - 4) + 'px';
  if (r.bottom > innerHeight) popup.style.top = Math.max(4, y - r.height) + 'px';
});

// Pointing at a submenu's item opens it, without taking focus; pointing at
// another item of the same menu closes it.
document.addEventListener('pointerover', (event) => {
  const item = inPath(event, '[role=menu][popover] [role^=menuitem]');
  if (!item) return;
  const menu = item.closest('[role=menu][popover]');
  for (const sub of menu.querySelectorAll('[role=menu][popover]')) {
    if (sub.parentElement.closest('[role=menu][popover]') === menu && isOpen(sub) && !sub.contains(item) && openers.get(sub) !== item) {
      sub.hidePopover();
    }
  }
  if (item.hasAttribute('data-howdy-submenu-trigger')) {
    const sub = byId(item, item.getAttribute('popovertarget'));
    if (sub && !isOpen(sub)) {
      quiet.add(sub);
      open(sub, item);
    }
  }
});

// Once a menubar menu is open, pointing at another button opens its menu.
document.addEventListener('pointerover', (event) => {
  const button = inPath(event, '[role=menubar] > [data-howdy-menu-trigger]');
  if (!button) return;
  const buttons = [...button.parentElement.querySelectorAll(':scope > [data-howdy-menu-trigger]')];
  const openOne = buttons.find((other) => other !== button && isOpen(byId(other, other.getAttribute('popovertarget'))));
  if (!openOne) return;
  const popover = byId(button, button.getAttribute('popovertarget'));
  if (!popover) return;
  handingOver.add(byId(openOne, openOne.getAttribute('popovertarget')));
  for (const other of buttons) other.tabIndex = other === button ? 0 : -1;
  open(popover, button);
});

// A menubar is one stop in the tab order: the button last focused.
document.addEventListener('focusin', (event) => {
  const button = event.composedPath()[0];
  if (!(button instanceof Element) || !button.matches('[role=menubar] > [data-howdy-menu-trigger]')) return;
  for (const other of button.parentElement.querySelectorAll(':scope > [data-howdy-menu-trigger]')) {
    other.tabIndex = other === button ? 0 : -1;
  }
});

// A resizable handle announces the size of the panel before it.
document.addEventListener('focusin', (event) => {
  const handle = event.composedPath()[0];
  if (handle instanceof Element && handle.matches('[data-howdy-resizable] > [role=separator]')) resizeBy(handle, 0);
});

// One-time codes keep out what cannot be part of them: anything but
// digits for a numeric code, spaces otherwise. Pasted codes are cleaned.
const codeAllows = (input, char) =>
  input.inputMode === 'numeric' ? char >= '0' && char <= '9' : char.trim() !== '';
document.addEventListener('beforeinput', (event) => {
  const input = event.composedPath()[0];
  if (!(input instanceof HTMLInputElement) || !input.hasAttribute('data-howdy-otp')) return;
  const text = event.data ?? event.dataTransfer?.getData('text') ?? '';
  if (!text || [...text].every((char) => codeAllows(input, char))) return;
  event.preventDefault();
  const clean = [...text].filter((char) => codeAllows(input, char)).join('');
  const start = input.selectionStart ?? input.value.length;
  const end = input.selectionEnd ?? start;
  const room = Math.max(0, input.maxLength - (input.value.length - (end - start)));
  input.setRangeText(clean.slice(0, room), start, end, 'end');
  input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
});

// Checkboxes marked partly checked on a page rendered once.
for (const box of document.querySelectorAll('[data-howdy-indeterminate]')) box.indeterminate = true;

// A range with several thumbs: none can pass its neighbours, and the fill
// runs from the first to the last.
document.addEventListener('input', (event) => {
  const thumb = event.composedPath()[0];
  const range = thumb instanceof HTMLInputElement ? thumb.parentElement : null;
  if (!range?.matches('[data-howdy-range]')) return;
  const thumbs = [...range.querySelectorAll(':scope > input')];
  const i = thumbs.indexOf(thumb);
  const floor = i > 0 ? Number(thumbs[i - 1].value) : -Infinity;
  const ceiling = i < thumbs.length - 1 ? Number(thumbs[i + 1].value) : Infinity;
  const value = Number(thumb.value);
  if (value < floor) thumb.value = String(floor);
  if (value > ceiling) thumb.value = String(ceiling);
  const min = Number(thumb.min);
  const span = Number(thumb.max) - min || 1;
  const at = (input) => ((Number(input.value) - min) / span) * 100 + '%';
  range.style.setProperty('--low', at(thumbs[0]));
  range.style.setProperty('--high', at(thumbs[thumbs.length - 1]));
});

// Carousels: the buttons move one slide, or loop round at the ends; the
// carousel says which slide is in view when it changes.
const carousels = new WeakSet();
const slideIndex = (viewport) => {
  const vertical = viewport.parentElement.dataset.orientation === 'vertical';
  const style = getComputedStyle(viewport);
  const gap = parseFloat(vertical ? style.rowGap : style.columnGap) || 0;
  const size = (vertical ? viewport.clientHeight : viewport.clientWidth) + gap;
  return Math.round(Math.abs(vertical ? viewport.scrollTop : viewport.scrollLeft) / size);
};
const watchCarousel = (carousel) => {
  if (carousels.has(carousel)) return;
  carousels.add(carousel);
  const viewport = carousel.querySelector(':scope > [id]');
  let timer;
  const settled = () => {
    const index = slideIndex(viewport);
    if (String(index) === carousel.dataset.index) return;
    carousel.dataset.index = String(index);
    carousel.dispatchEvent(new CustomEvent('howdy-slide', { bubbles: true, composed: true, detail: { index } }));
  };
  viewport.addEventListener('scroll', () => {
    clearTimeout(timer);
    timer = setTimeout(settled, 120);
  });
};
const slide = (button) => {
  const viewport = byId(button, button.getAttribute('aria-controls'));
  if (!viewport) return;
  const carousel = viewport.parentElement;
  watchCarousel(carousel);
  const vertical = carousel.dataset.orientation === 'vertical';
  const forward = button.hasAttribute('data-howdy-carousel-next');
  const flip = !vertical && rtl(viewport) ? -1 : 1;
  const behavior = matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth';
  const size = vertical ? viewport.clientHeight : viewport.clientWidth;
  const extent = (vertical ? viewport.scrollHeight : viewport.scrollWidth) - size;
  const position = Math.abs(vertical ? viewport.scrollTop : viewport.scrollLeft);
  const axis = vertical ? 'top' : 'left';
  const loops = carousel.hasAttribute('data-loop');
  if (loops && forward && position >= extent - 2) viewport.scrollTo({ [axis]: 0, behavior });
  else if (loops && !forward && position <= 2) viewport.scrollTo({ [axis]: extent * flip, behavior });
  else viewport.scrollBy({ [axis]: (forward ? size : -size) * flip, behavior });
};
// Carousels that play by themselves. One timer serves every carousel on
// the page and in its live views, so one rendered later starts too.
const lastMoved = new WeakMap();
const stillPreferred = matchMedia('(prefers-reduced-motion: reduce)');
const setPlaying = (carousel, playing) => {
  carousel.toggleAttribute('data-paused', !playing);
  const button = carousel.querySelector('[data-howdy-carousel-play]');
  button?.setAttribute('aria-label', playing ? 'Pause slides' : 'Play slides');
  // Announce slides only when someone is moving them.
  carousel.querySelector(':scope > [id]')?.setAttribute('aria-live', playing ? 'off' : 'polite');
};
// Conversations that restore a place or open at a message start as soon
// as they are found, in the page or in a live view rendered later.
const findConversations = () => {
  for (const root of roots()) {
    for (const frame of root.querySelectorAll('[data-howdy-conversation]')) {
      if (frame.firstElementChild?.matches('[data-howdy-remember], [data-howdy-start-at]')) watchConversation(frame);
    }
  }
};
setInterval(() => {
  findConversations();
  if (document.hidden) return;
  const now = Date.now();
  for (const root of roots()) {
    for (const carousel of root.querySelectorAll('[data-howdy-carousel][data-autoplay]')) {
      if (!lastMoved.has(carousel)) {
        lastMoved.set(carousel, now);
        setPlaying(carousel, !stillPreferred.matches);
        continue;
      }
      if (carousel.hasAttribute('data-paused') || carousel.matches(':hover, :focus-within')) {
        lastMoved.set(carousel, now);
        continue;
      }
      if (now - lastMoved.get(carousel) < Number(carousel.dataset.autoplay)) continue;
      lastMoved.set(carousel, now);
      const next = carousel.querySelector('[data-howdy-carousel-next]');
      watchCarousel(carousel);
      // Wrap round at the end, looping or not.
      const loops = carousel.hasAttribute('data-loop');
      carousel.setAttribute('data-loop', '');
      if (next) slide(next);
      if (!loops) carousel.removeAttribute('data-loop');
    }
  }
}, 250);

const startCarousel = (event) => {
  const carousel = inPath(event, '[data-howdy-carousel]');
  if (carousel) watchCarousel(carousel);
};
document.addEventListener('pointerover', startCarousel);
document.addEventListener('focusin', startCarousel);

// Conversations: a button to the newest message appears once scrolled
// back from it. Laid out from the bottom, the newest is at scroll 0.
const conversations = new WeakSet();
const watchConversation = (frame) => {
  if (conversations.has(frame)) return;
  conversations.add(frame);
  const scroller = frame.firstElementChild;
  const latest = frame.querySelector(':scope > [data-howdy-latest]');
  // Laid out from the bottom: scrollTop is 0 at the newest message and
  // grows negative going back.
  const back = () => Math.abs(scroller.scrollTop);
  const key = scroller.dataset.howdyRemember && 'howdy-chat-' + scroller.dataset.howdyRemember;
  const saved = key ? sessionStorage.getItem(key) : null;
  if (saved !== null) scroller.scrollTop = -Number(saved);
  else if (scroller.dataset.howdyStartAt) byId(scroller, scroller.dataset.howdyStartAt)?.scrollIntoView({ block: 'start' });
  latest.hidden = back() < 80;
  // Keep the reader's place when messages are added above it, such as
  // older history: note the first message in view, by id where it has one
  // since a patch may reuse elements, and put it back where it was.
  const log = scroller.firstElementChild;
  let anchor = null;
  let anchorId = '';
  let offset = 0;
  const top = () => scroller.getBoundingClientRect().top;
  const note = () => {
    const edge = top();
    anchor = [...log.children].find((el) => el.getBoundingClientRect().bottom > edge) || null;
    anchorId = anchor?.id || '';
    offset = anchor ? anchor.getBoundingClientRect().top - edge : 0;
  };
  new ResizeObserver(() => {
    const el = anchorId ? byId(scroller, anchorId) : anchor;
    if (!el?.isConnected || back() < 80) return note();
    const moved = el.getBoundingClientRect().top - top() - offset;
    if (Math.abs(moved) > 1) scroller.scrollTop += moved;
    note();
  }).observe(log);
  let asked = false;
  let height = scroller.scrollHeight;
  let timer;
  const scrolled = () => {
    note();
    latest.hidden = back() < 80;
    if (key) {
      clearTimeout(timer);
      timer = setTimeout(() => sessionStorage.setItem(key, String(Math.round(back()))), 150);
    }
    // Ask once for older messages, and again after some arrive.
    if (scroller.scrollHeight !== height) {
      height = scroller.scrollHeight;
      asked = false;
    }
    if (!asked && scroller.scrollHeight - scroller.clientHeight - back() < 80) {
      asked = true;
      scroller.dispatchEvent(new CustomEvent('howdy-older', { bubbles: true, composed: true }));
    }
  };
  scroller.addEventListener('scroll', scrolled);
  // Found already scrolled back, such as by a restored place: act on it.
  if (back() >= 80) scrolled();
};
findConversations();
const startConversation = (event) => {
  const frame = inPath(event, '[data-howdy-conversation]');
  if (frame) watchConversation(frame);
};
document.addEventListener('pointerover', startConversation);
document.addEventListener('focusin', startConversation);

// Drawers: snap heights, dragging the handle, and closing by dragging it
// down far enough.
const snaps = (drawer) =>
  (drawer.dataset.snaps || '')
    .split(',')
    .map(Number)
    .filter((it) => it > 0)
    .sort((a, b) => a - b)
    .map((it) => (it / 100) * innerHeight);
const setDrawerHeight = (drawer, px) => drawer.style.setProperty('--howdy-drawer-height', px + 'px');
const openDrawer = (drawer) => {
  drawer.style.setProperty('--howdy-drawer-drag', '0px');
  const heights = snaps(drawer);
  if (heights.length) setDrawerHeight(drawer, heights[0]);
};
const closeDrawer = (drawer) => {
  drawer.close();
  drawer.style.setProperty('--howdy-drawer-drag', '0px');
};
document.addEventListener('pointerdown', (event) => {
  const handle = inPath(event, '[data-howdy-drawer-handle]');
  if (!handle || event.button !== 0) return;
  event.preventDefault();
  const drawer = handle.closest('[data-howdy-drawer]');
  const heights = snaps(drawer);
  const start = event.clientY;
  const height = drawer.getBoundingClientRect().height;
  drawer.setAttribute('data-dragging', '');
  try {
    handle.setPointerCapture(event.pointerId);
  } catch {}
  let moved = 0;
  const move = (e) => {
    moved = e.clientY - start;
    if (heights.length) {
      setDrawerHeight(drawer, Math.min(Math.max(height - moved, 0), heights[heights.length - 1]));
    } else {
      drawer.style.setProperty('--howdy-drawer-drag', Math.max(0, moved) + 'px');
    }
  };
  const stop = () => {
    handle.removeEventListener('pointermove', move);
    handle.removeEventListener('pointerup', stop);
    handle.removeEventListener('pointercancel', stop);
    drawer.removeAttribute('data-dragging');
    if (heights.length) {
      const now = height - moved;
      if (now < heights[0] * 0.6) return closeDrawer(drawer);
      const nearest = heights.reduce((best, it) => (Math.abs(it - now) < Math.abs(best - now) ? it : best));
      setDrawerHeight(drawer, nearest);
    } else if (moved > height * 0.3) {
      closeDrawer(drawer);
    } else {
      drawer.style.setProperty('--howdy-drawer-drag', '0px');
    }
  };
  handle.addEventListener('pointermove', move);
  handle.addEventListener('pointerup', stop);
  handle.addEventListener('pointercancel', stop);
});
document.addEventListener('keydown', (event) => {
  const handle = event.composedPath()[0];
  if (!(handle instanceof Element) || !handle.matches('[data-howdy-drawer-handle]')) return;
  if (event.key !== 'ArrowUp' && event.key !== 'ArrowDown') return;
  event.preventDefault();
  const drawer = handle.closest('[data-howdy-drawer]');
  const heights = snaps(drawer);
  const now = drawer.getBoundingClientRect().height;
  if (event.key === 'ArrowUp') {
    const taller = heights.find((it) => it > now + 1);
    if (taller) setDrawerHeight(drawer, taller);
  } else {
    const shorter = [...heights].reverse().find((it) => it < now - 1);
    if (shorter) setDrawerHeight(drawer, shorter);
    else closeDrawer(drawer);
  }
});

// Capture, so popovers are watched before the browser opens them.
document.addEventListener('click', (event) => {
  const invoker = inPath(event, '[popovertarget], [commandfor]');
  if (!invoker) return;
  const target = byId(invoker, invoker.getAttribute('popovertarget') || invoker.getAttribute('commandfor'));
  if (!target) return;
  if (target.hasAttribute('popover')) {
    openers.set(target, invoker);
    watch(target);
  }
  if (target.hasAttribute('data-howdy-drawer') && invoker.getAttribute('command') === 'show-modal') openDrawer(target);
  if (!hasCommands && invoker.hasAttribute('commandfor')) {
    const command = invoker.getAttribute('command');
    if (command === 'show-modal' && !target.open) target.showModal();
    if (command === 'close' && target.open) target.close();
  }
}, true);

document.addEventListener('click', (event) => {
  const first = event.composedPath()[0];
  if (!hasClosedBy && first instanceof HTMLDialogElement && first.open && first.getAttribute('closedby') === 'any') {
    const r = first.getBoundingClientRect();
    const outside = event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom;
    if (outside) first.close();
  }
  const tab = inPath(event, '[data-howdy-tabs] [role=tab]');
  if (tab) selectTab(tab);
  const option = inPath(event, '[data-howdy-select] [role=option]');
  if (option) choose(option);
  // A chip's remove button unchooses its option.
  const removeChip = inPath(event, '[data-howdy-chip-remove]');
  if (removeChip) {
    const root = removeChip.closest('[data-howdy-select]');
    const value = removeChip.closest('[data-howdy-chip]').dataset.value;
    for (const option of root.querySelectorAll('[role=option]')) {
      if (option.dataset.value === value) option.setAttribute('aria-selected', 'false');
    }
    showChosen(root);
    root.querySelector('[data-howdy-select-trigger]').focus();
  }
  const clearButton = inPath(event, '[data-howdy-select-clear]');
  if (clearButton) {
    const root = clearButton.closest('[data-howdy-select]');
    for (const other of root.querySelectorAll('[role=option]')) other.setAttribute('aria-selected', 'false');
    showChosen(root);
    root.querySelector('[data-howdy-select-trigger]').focus();
  }
  const item = inPath(event, '[role=menu] [role^=menuitem]');
  // Choosing an item closes its menu, and any menu it opened from. A
  // checkbox item flips its tick first, and a radio item takes the dot.
  if (item && !item.matches('[aria-disabled=true]') && !item.hasAttribute('data-howdy-submenu-trigger')) {
    const role = item.getAttribute('role');
    if (role === 'menuitemcheckbox') item.setAttribute('aria-checked', String(item.getAttribute('aria-checked') !== 'true'));
    if (role === 'menuitemradio') {
      const group = item.closest('[role=group]') || item.closest('[role=menu]');
      for (const other of group.querySelectorAll('[role=menuitemradio]')) other.setAttribute('aria-checked', String(other === item));
    }
    close(outermost(item));
  }
  const day = inPath(event, '[data-howdy-calendar] [data-date]');
  if (day) pickDay(day);
  const command = inPath(event, 'dialog [data-howdy-command] [role=option]');
  if (command && !command.matches('[aria-disabled=true]')) command.closest('dialog').close();
  const toggle = inPath(event, '[data-howdy-toggle]');
  if (toggle && !toggle.disabled) {
    const pressed = toggle.getAttribute('aria-pressed') !== 'true';
    const group = toggle.closest('[data-howdy-toggle-group=single]');
    if (group && pressed) {
      for (const other of group.querySelectorAll('[data-howdy-toggle]')) other.setAttribute('aria-pressed', 'false');
    }
    toggle.setAttribute('aria-pressed', String(pressed));
  }
  const play = inPath(event, '[data-howdy-carousel-play]');
  if (play) {
    const carousel = play.closest('[data-howdy-carousel]');
    setPlaying(carousel, carousel.hasAttribute('data-paused'));
  }
  const slideButton = inPath(event, '[data-howdy-carousel-previous], [data-howdy-carousel-next]');
  if (slideButton) slide(slideButton);
  const still = matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth';
  const latest = inPath(event, '[data-howdy-latest]');
  if (latest) {
    latest.parentElement.firstElementChild.scrollTo({ top: 0, behavior: still });
    latest.hidden = true;
  }
  // A jump scrolls to a message, picks it out for a moment and moves focus
  // there, so a screen reader follows.
  const jump = inPath(event, '[data-howdy-jump]');
  if (jump) {
    const message = byId(jump, jump.dataset.howdyJump);
    if (message) {
      message.scrollIntoView({ block: 'center', behavior: still });
      if (!message.hasAttribute('tabindex')) message.tabIndex = -1;
      message.focus({ preventScroll: true });
      message.setAttribute('data-flash', '');
      setTimeout(() => message.removeAttribute('data-flash'), 1600);
    }
  }
  const toast = inPath(event, '[data-howdy-toast-close]');
  if (toast) toast.closest('[data-howdy-toast]').hidden = true;
  // On a wide screen the sidebar trigger collapses the sidebar instead of
  // opening it over the page, and the choice is kept for the next page.
  const sidebarTrigger = inPath(event, '[data-howdy-sidebar-trigger]');
  if (sidebarTrigger && wide.matches) {
    event.preventDefault();
    const layout = byId(sidebarTrigger, sidebarTrigger.getAttribute('popovertarget'))?.closest('[data-howdy-sidebar-layout]');
    if (layout) {
      layout.dataset.state = layout.dataset.state === 'collapsed' ? 'expanded' : 'collapsed';
      document.cookie = 'sidebar=' + layout.dataset.state + ';path=/;max-age=31536000;samesite=lax';
    }
  }
});

document.addEventListener('keydown', (event) => {
  const target = event.composedPath()[0];
  if (!(target instanceof Element)) return;
  const key = logical(event.key, target);
  const arrows = ['ArrowDown', 'ArrowUp', 'Home', 'End'];

  const popup = target.closest('[role=menu][popover], [role=listbox][popover]');
  if (popup) {
    const items = ownItems(popup);
    // A submenu opens with the right arrow, Enter or Space, and closes
    // with the left arrow, back to its item.
    if (target.hasAttribute('data-howdy-submenu-trigger') && ['ArrowRight', 'Enter', ' '].includes(key)) {
      event.preventDefault();
      const sub = byId(target, target.getAttribute('popovertarget'));
      if (sub) open(sub, target);
      return;
    }
    if (key === 'ArrowLeft' && popup.parentElement?.closest('[role=menu][popover]')) {
      event.preventDefault();
      popup.hidePopover();
      return;
    }
    // In a menubar, left and right go to the neighbouring menu.
    const opener = openers.get(popup);
    const bar = opener?.closest('[role=menubar]');
    if (bar && (key === 'ArrowLeft' || key === 'ArrowRight')) {
      event.preventDefault();
      const buttons = enabled(bar, ':scope > [data-howdy-menu-trigger]');
      const next = step(buttons, opener, key);
      const menu = byId(next, next.getAttribute('popovertarget'));
      handingOver.add(popup);
      popup.hidePopover();
      for (const button of buttons) button.tabIndex = button === next ? 0 : -1;
      if (menu) open(menu, next);
      return;
    }
    if (arrows.includes(key)) {
      event.preventDefault();
      step(items, target, key)?.focus();
    } else if (key === 'Tab') {
      popup.hidePopover();
    } else if ((key === 'Enter' || key === ' ') && target.matches('[role=option]')) {
      event.preventDefault();
      choose(target);
    } else if (key.length === 1 && key !== ' ' && !event.ctrlKey && !event.metaKey && !event.altKey) {
      typeahead(items, target, key)?.focus();
    }
    return;
  }

  const command = target.matches('[data-howdy-command] > input') ? target.parentElement : null;
  if (command) {
    const items = commandItems(command);
    const current = command.querySelector('[data-active]');
    if (key === 'ArrowDown' || key === 'ArrowUp') {
      event.preventDefault();
      activate(command, current && items.includes(current) ? step(items, current, key) : items[0]);
    } else if (key === 'Enter' && current) {
      event.preventDefault();
      current.click();
    }
    return;
  }

  const handle = target.closest('[data-howdy-resizable] > [role=separator]');
  if (handle) {
    const all = shares(handle.parentElement);
    const moves = {
      ArrowLeft: -all / 20,
      ArrowUp: -all / 20,
      ArrowRight: all / 20,
      ArrowDown: all / 20,
      // As far as the panels' minimums allow.
      Home: -all,
      End: all,
    };
    if (Object.hasOwn(moves, key)) {
      event.preventDefault();
      resizeBy(handle, moves[key]);
      remember(handle.parentElement);
    } else if (key === 'Enter') {
      event.preventDefault();
      collapse(handle);
    }
    return;
  }

  const barButton = target.closest('[role=menubar] > [data-howdy-menu-trigger]');
  if (barButton && ['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(key)) {
    event.preventDefault();
    const next = step(enabled(barButton.parentElement, ':scope > [data-howdy-menu-trigger]'), barButton, key);
    next.focus();
    return;
  }

  const day = target.closest('[data-howdy-calendar] [data-date]');
  if (day) {
    const moves = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 };
    let next = null;
    if (Object.hasOwn(moves, key)) {
      next = moveDay(day, moves[key]);
    } else if (key === 'Home' || key === 'End') {
      const week = enabled(day.closest('tr'), '[data-date]');
      next = key === 'Home' ? week[0] : week[week.length - 1];
    } else if (key === 'PageUp' || key === 'PageDown') {
      event.preventDefault();
      const which = key === 'PageUp' ? 'previous' : 'next';
      day.closest('[data-howdy-calendar]').querySelector(`[data-howdy-calendar-${which}]`)?.click();
      return;
    }
    if (next) {
      event.preventDefault();
      for (const other of day.closest('[data-howdy-calendar]').querySelectorAll('[data-date]')) {
        other.tabIndex = other === next ? 0 : -1;
      }
      next.focus();
    }
    return;
  }

  // Backspace on a multiple combobox's button removes the last chip.
  if (key === 'Backspace' && target.matches('[data-multiple] [data-howdy-select-trigger]')) {
    const chips = [...target.closest('[data-howdy-select]').querySelectorAll('[data-howdy-chip]:not([hidden]) [data-howdy-chip-remove]')];
    if (chips.length) {
      event.preventDefault();
      chips[chips.length - 1].click();
    }
    return;
  }

  const trigger = target.closest('[data-howdy-menu-trigger], [data-howdy-select-trigger]');
  if (trigger && (key === 'ArrowDown' || key === 'ArrowUp')) {
    const popover = byId(trigger, trigger.getAttribute('popovertarget'));
    if (popover) {
      event.preventDefault();
      open(popover, trigger);
    }
    return;
  }

  // Tabs follow focus. The change is a click, so a live view hears it the
  // same way whether the mouse or the keyboard made it.
  const tab = target.closest('[data-howdy-tabs] [role=tab]');
  if (tab) {
    const list = tab.closest('[role=tablist]');
    const vertical = list.getAttribute('aria-orientation') === 'vertical';
    const keys = vertical ? ['ArrowUp', 'ArrowDown', 'Home', 'End'] : ['ArrowLeft', 'ArrowRight', 'Home', 'End'];
    if (!keys.includes(key)) return;
    event.preventDefault();
    const next = step(enabled(list, '[role=tab]'), tab, key);
    next.focus();
    if (next !== tab) next.click();
    return;
  }

  // A toggle group is one stop in the tab order; the arrows move within it.
  const toggleButton = target.closest('[data-howdy-toggle-group] [data-howdy-toggle]');
  if (toggleButton) {
    const group = toggleButton.closest('[data-howdy-toggle-group]');
    const vertical = group.getAttribute('aria-orientation') === 'vertical';
    const keys = vertical ? ['ArrowUp', 'ArrowDown', 'Home', 'End'] : ['ArrowLeft', 'ArrowRight', 'Home', 'End'];
    if (!keys.includes(key)) return;
    event.preventDefault();
    const next = step(enabled(group, '[data-howdy-toggle]'), toggleButton, key);
    next.focus();
  }
});

// Roving focus: the toggle last focused is the group's stop in the tab order.
document.addEventListener('focusin', (event) => {
  const focused = event.composedPath()[0];
  if (!(focused instanceof Element) || !focused.matches('[data-howdy-toggle-group] [data-howdy-toggle]')) return;
  for (const other of focused.closest('[data-howdy-toggle-group]').querySelectorAll('[data-howdy-toggle]')) {
    other.tabIndex = other === focused ? 0 : -1;
  }
});

// A theme toggle switches the document between the two themes it names and
// remembers the choice in a `theme` cookie.
document.addEventListener('click', (event) => {
  const toggle = inPath(event, '[data-howdy-theme-toggle]');
  if (!toggle) return;
  const root = document.documentElement;
  const current = root.dataset.theme || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
  const next = current === toggle.dataset.howdyThemeFrom ? toggle.dataset.howdyThemeTo : toggle.dataset.howdyThemeFrom;
  root.dataset.theme = next;
  document.cookie = `theme=${encodeURIComponent(next)};path=/;max-age=31536000;samesite=lax`;
});

// Whether a toast in a live view's queue is held open, as its countdown
// sees it: pointed at or focused inside. Checked once the pointer or focus
// has settled, since focus moving within a toast leaves it and enters it
// again, and reported only when it changes. Heard on each root, below: the
// pointer or focus moving between two elements of a live view leaves an
// event that stops at the view's host.
const toastHeld = (event) => {
  const toast = inPath(event, '[data-howdy-toast-queue] [data-howdy-toast]');
  if (!toast) return;
  setTimeout(() => {
    const held = toast.isConnected && toast.matches(':hover, :focus-within');
    if (String(held) === (toast.dataset.held || 'false')) return;
    toast.dataset.held = String(held);
    toast.dispatchEvent(new CustomEvent('howdy-toast-hold', { bubbles: true, composed: true, detail: { held } }));
  });
};

// A toast that has faded is closed as if its close button were pressed, so
// a live view keeping toasts in its model hears it. The fade waits while the
// toast is hovered or focused, so it goes when the reader is done.
const toastFaded = (event) => {
  const toast = event.composedPath()[0];
  if (!(toast instanceof Element) || !toast.matches('[data-howdy-toast]') || !event.animationName.startsWith('howdy-toast-out')) return;
  const close = toast.querySelector('[data-howdy-toast-close]');
  if (close) close.click();
  else toast.hidden = true;
};

// An image marked `data-howdy-on-error="remove"` steps aside when it does
// not load, such as an avatar for the initials behind it.
const broken = (image) => image instanceof Element && image.matches('img[data-howdy-on-error=remove]');
const imageFailed = (event) => {
  const image = event.composedPath()[0];
  if (broken(image)) image.remove();
};

// -- Uploaders ----------------------------------------------------------------
// A file dropped on or chosen in an uploader goes straight to storage. The
// app's start endpoint says where, XMLHttpRequest sends it, since fetch
// cannot report progress, and then a hidden input holds the file's key.
// Rows the server drew are only hidden when removed, since a live view may
// still patch them; rows this script added are its own to remove.
const uploads = new WeakMap();
const uploaderOf = (node) => node?.closest('[data-howdy-uploader]');
const uploadItems = (uploader) =>
  [...uploader.querySelectorAll('[data-howdy-upload-list] > [data-howdy-upload-item]')].filter((item) => !item.hidden);
const uploadPart = (item, name) => item.querySelector(`[data-howdy-upload-${name}]`);

// The same as `uploader.file_size` and `attachment` in Gleam.
const fileSize = (bytes) => {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let amount = Math.max(bytes, 0);
  let unit = 0;
  while (unit < units.length - 1 && amount >= (unit === 0 ? 1000 : 999.5)) {
    amount /= 1000;
    unit += 1;
  }
  if (unit === 0) return `${Math.round(amount)} B`;
  return `${amount < 9.95 ? Math.round(amount * 10) / 10 : Math.round(amount)} ${units[unit]}`;
};
const extension = (name) => {
  const parts = name.split('.');
  return parts.length > 1 ? parts.at(-1).slice(0, 4).toUpperCase() : 'FILE';
};
const describe = (name, size) => (extension(name) === 'FILE' ? fileSize(size) : `${extension(name)} · ${fileSize(size)}`);

// Whether a file is one the input's `accept` attribute allows.
const accepts = (input, file) => {
  const types = (input.getAttribute('accept') || '').split(',').map((type) => type.trim().toLowerCase()).filter(Boolean);
  const name = file.name.toLowerCase();
  const type = file.type.toLowerCase();
  return !types.length || types.some((allowed) => {
    if (allowed.startsWith('.')) return name.endsWith(allowed);
    if (allowed.endsWith('/*')) return type.startsWith(allowed.slice(0, -1));
    return type === allowed;
  });
};

// Keep the form from submitting while a file is on its way, or without one
// when one is required, and tell a live view the keys when they change.
const syncUploader = (uploader, changed) => {
  const input = uploader.querySelector('[data-howdy-upload-input]');
  const items = uploadItems(uploader);
  const values = items.map((item) => uploadPart(item, 'key')).filter((key) => !key.disabled).map((key) => key.value);
  const missing = uploader.dataset.required === 'true' && !values.length;
  input.required = false;
  if (items.some((item) => item.dataset.state === 'uploading')) input.setCustomValidity(uploader.dataset.textWait);
  else input.setCustomValidity(missing ? uploader.dataset.textMissing : '');
  if (changed) {
    uploader.dispatchEvent(new CustomEvent('howdy-values', { bubbles: true, composed: true, detail: { name: uploader.dataset.name, values } }));
  }
};

const showProgress = (item, percent) => {
  const done = Math.max(0, Math.min(100, Math.round(percent)));
  const progress = uploadPart(item, 'progress');
  progress.setAttribute('aria-valuenow', String(done));
  progress.firstElementChild.style.width = `${done}%`;
};

const showUpload = (item, state, message = '', retryable = false) => {
  item.dataset.state = state;
  item.firstElementChild.toggleAttribute('data-failed', state === 'failed');
  uploadPart(item, 'progress').hidden = state !== 'uploading';
  if (state === 'uploading') showProgress(item, 0);
  uploadPart(item, 'retry').hidden = !(state === 'failed' && retryable);
  // Shown before it is filled, so the alert is announced.
  const error = uploadPart(item, 'error');
  error.hidden = state !== 'failed';
  setText(error, message);
};

const failUpload = (uploader, item, message, retryable) => {
  showUpload(item, 'failed', message, retryable);
  syncUploader(uploader, false);
};

const sendUpload = async (uploader, item) => {
  const upload = uploads.get(item);
  const current = () => item.isConnected && uploads.get(item) === upload;
  showUpload(item, 'uploading');
  syncUploader(uploader, false);
  try {
    const { file } = upload;
    const started = await fetch(uploader.dataset.start, {
      method: 'POST',
      headers: { 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({ name: file.name, type: file.type || 'application/octet-stream', size: file.size }),
    });
    const answer = await started.json().catch(() => ({}));
    if (!current()) return;
    if (!started.ok) {
      const message = answer.fields?.[0]?.message || answer.error || uploader.dataset.textFailed;
      return failUpload(uploader, item, message, started.status >= 500 || started.status === 429);
    }
    const { key, upload: target } = answer;
    if (typeof key !== 'string' || typeof target?.url !== 'string') return failUpload(uploader, item, uploader.dataset.textFailed, true);
    await new Promise((resolve, reject) => {
      const request = new XMLHttpRequest();
      upload.request = request;
      request.open(target.method || 'PUT', target.url);
      for (const [name, value] of Object.entries(target.headers || {})) request.setRequestHeader(name, value);
      request.upload.onprogress = (event) => {
        if (event.lengthComputable && current()) showProgress(item, (event.loaded / event.total) * 100);
      };
      request.onload = () => (request.status < 300 ? resolve() : reject(new Error(`status ${request.status}`)));
      request.onerror = () => reject(new Error('network'));
      request.onabort = () => reject(new Error('aborted'));
      request.send(file);
    });
    upload.request = null;
    if (!current()) return;
    const input = uploadPart(item, 'key');
    input.value = key;
    input.disabled = false;
    showUpload(item, 'done');
    syncUploader(uploader, true);
  } catch {
    upload.request = null;
    if (current()) failUpload(uploader, item, uploader.dataset.textFailed, true);
  }
};

const removeUpload = (item) => {
  const upload = uploads.get(item);
  if (!upload) {
    item.hidden = true;
    uploadPart(item, 'key').disabled = true;
    return;
  }
  uploads.delete(item);
  upload.request?.abort();
  if (upload.thumbnail) URL.revokeObjectURL(upload.thumbnail);
  item.remove();
};

const newUpload = (uploader, file) => {
  const template = uploader.querySelector('[data-howdy-upload-blank]');
  const item = (template.content.firstElementChild || template.firstElementChild).cloneNode(true);
  setText(uploadPart(item, 'name'), file.name);
  setText(uploadPart(item, 'detail'), describe(file.name, file.size));
  const icon = uploadPart(item, 'icon');
  setText(icon, extension(file.name));
  uploadPart(item, 'remove').setAttribute('aria-label', `${uploader.dataset.textRemove} ${file.name}`);
  const retry = uploadPart(item, 'retry');
  retry.setAttribute('aria-label', `${retry.dataset.label} ${file.name}`);
  uploadPart(item, 'progress').setAttribute('aria-label', `${uploader.dataset.textUploading} ${file.name}`);
  const upload = { file, request: null, thumbnail: null };
  if (file.type.startsWith('image/')) {
    const media = uploadPart(item, 'media');
    const image = media.querySelector('img');
    upload.thumbnail = URL.createObjectURL(file);
    image.onerror = () => {
      media.hidden = true;
      icon.hidden = false;
    };
    image.src = upload.thumbnail;
    media.hidden = false;
    icon.hidden = true;
  }
  uploads.set(item, upload);
  uploader.querySelector('[data-howdy-upload-list]').append(item);
  return item;
};

const addUploads = (uploader, files) => {
  const max = Number(uploader.dataset.maxFiles) || 1;
  if (max === 1) {
    files = files.slice(0, 1);
    if (files.length) for (const item of uploadItems(uploader)) removeUpload(item);
  }
  const input = uploader.querySelector('[data-howdy-upload-input]');
  const maxSize = Number(uploader.dataset.maxSize) || Infinity;
  for (const file of files) {
    const taken = uploadItems(uploader).filter((item) => item.dataset.state !== 'failed').length;
    const item = newUpload(uploader, file);
    if (taken >= max) showUpload(item, 'failed', uploader.dataset.textTooMany);
    else if (!accepts(input, file)) showUpload(item, 'failed', uploader.dataset.textWrongType);
    else if (file.size > maxSize) showUpload(item, 'failed', uploader.dataset.textTooLarge);
    else sendUpload(uploader, item);
  }
  syncUploader(uploader, files.length > 0);
};

// Heard on each root, below: `change` does not leave a live view.
const uploadChosen = (event) => {
  const input = event.composedPath()[0];
  if (!(input instanceof HTMLInputElement) || !input.matches('[data-howdy-upload-input]')) return;
  const files = [...input.files];
  // Emptied so that choosing the same file again is a change.
  input.value = '';
  addUploads(uploaderOf(input), files);
};

document.addEventListener('click', (event) => {
  const button = inPath(event, '[data-howdy-upload-remove], [data-howdy-upload-retry]');
  const item = button?.closest('[data-howdy-upload-item]');
  const uploader = uploaderOf(item);
  if (!uploader) return;
  if (button.matches('[data-howdy-upload-retry]')) {
    if (uploads.has(item)) sendUpload(uploader, item);
    return;
  }
  // Focus moves to a neighbour, or back to the file input.
  const items = uploadItems(uploader);
  const index = items.indexOf(item);
  const neighbour = items[index + 1] || items[index - 1];
  removeUpload(item);
  syncUploader(uploader, true);
  (neighbour ? uploadPart(neighbour, 'remove') : uploader.querySelector('[data-howdy-upload-input]')).focus();
});

const dropZone = (event) => {
  const zone = inPath(event, '[data-howdy-upload-drop]');
  return zone && event.dataTransfer?.types.includes('Files') ? zone : null;
};
document.addEventListener('dragover', (event) => {
  const zone = dropZone(event);
  if (!zone) return;
  event.preventDefault();
  event.dataTransfer.dropEffect = 'copy';
  zone.toggleAttribute('data-dragging', true);
});
document.addEventListener('dragleave', (event) => {
  const zone = inPath(event, '[data-howdy-upload-drop]');
  if (zone && !zone.contains(event.relatedTarget)) zone.removeAttribute('data-dragging');
});
document.addEventListener('drop', (event) => {
  const zone = dropZone(event);
  if (!zone) return;
  event.preventDefault();
  zone.removeAttribute('data-dragging');
  addUploads(uploaderOf(zone), [...event.dataTransfer.files]);
});

// Events that do not leave a live view's shadow root, whether they never
// bubble or stop at its host, are heard on each root: the document now, and
// a live view's shadow root once it has mounted. Images that failed before
// this script ran are caught up with.
const heard = new WeakSet();
const hear = (root) => {
  if (!root || heard.has(root)) return;
  heard.add(root);
  for (const type of ['pointerover', 'pointerout', 'focusin', 'focusout']) root.addEventListener(type, toastHeld);
  root.addEventListener('animationend', toastFaded);
  root.addEventListener('change', uploadChosen);
  root.addEventListener('error', imageFailed, true);
  for (const image of root.querySelectorAll('img[data-howdy-on-error=remove]')) {
    if (image.complete && image.naturalWidth === 0) image.remove();
  }
};
for (const root of roots()) hear(root);
document.addEventListener('lustre:mount', (event) => hear(event.target.shadowRoot), true);

// Rich text editors load their code, from the URL each names, the first
// time one is on the page. A custom element is upgraded wherever it is,
// including in a live view's shadow root and when a patch adds it later.
// An element that is moved stays the same editor; one that is removed for
// good is taken down.
if (!customElements.get('howdy-rich-text')) {
  customElements.define('howdy-rich-text', class extends HTMLElement {
    connectedCallback() {
      // Its children may still be on their way.
      queueMicrotask(() => {
        if (!this.isConnected || this.editor || this.loading) return;
        this.loading = true;
        import(this.dataset.script)
          .then(({ mount }) => {
            if (this.isConnected && !this.editor) this.editor = mount(this);
          })
          .catch((error) => {
            this.setAttribute('data-failed', '');
            console.error(`howdy: the rich text editor could not load from ${this.dataset.script}. Mount ui.rich_text() in the app.`, error);
          })
          .finally(() => (this.loading = false));
      });
    }
    disconnectedCallback() {
      queueMicrotask(() => {
        if (this.isConnected || !this.editor) return;
        this.editor.destroy();
        this.editor = null;
      });
    }
  });
}
}
