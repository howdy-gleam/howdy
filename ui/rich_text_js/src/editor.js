// The browser side of `howdy/ui/rich_text`: a ProseMirror editor mounted in
// each `<howdy-rich-text>` element that `howdy/ui/behaviour` finds.
//
// The server draws everything that is styled: the frame, the toolbar, the
// suggestion list and templates for what the editor adds, such as mention
// chips. This file only copies those, so the theme reaches all of it.
//
// The document goes into the hidden input as the JSON that
// `howdy/ui/rich_text/document` decodes. Its schema here and the decoder
// there must agree: a node the decoder does not know makes the whole
// document refused.

import { Schema, Fragment } from 'prosemirror-model';
import { EditorState, Plugin, PluginKey, TextSelection } from 'prosemirror-state';
import { EditorView, Decoration, DecorationSet } from 'prosemirror-view';
import { keymap } from 'prosemirror-keymap';
import { history, undo, redo, undoDepth, redoDepth } from 'prosemirror-history';
import { baseKeymap, toggleMark, setBlockType, wrapIn, lift, chainCommands, exitCode } from 'prosemirror-commands';
import { wrapInList, splitListItem, liftListItem, sinkListItem } from 'prosemirror-schema-list';
import { inputRules, wrappingInputRule, textblockTypeInputRule, InputRule, undoInputRule } from 'prosemirror-inputrules';
import { dropCursor } from 'prosemirror-dropcursor';
import { gapCursor } from 'prosemirror-gapcursor';

// -- Links -------------------------------------------------------------------

// The same rule as `document.is_safe_link` in Gleam.
export const isSafeLink = (href) => {
  if (typeof href !== 'string' || !href.length || [...href].length > 2048) return false;
  for (const char of href) {
    const code = char.codePointAt(0);
    if (code <= 32 || code === 127) return false;
  }
  const colon = href.indexOf(':');
  if (colon < 0) return true;
  const before = href.slice(0, colon);
  if (/[/?#]/.test(before)) return true;
  return ['http', 'https', 'mailto', 'tel'].includes(before.toLowerCase());
};

// What someone typed as a link, made into one: a bare domain gets https, a
// bare address mailto, and spaces are encoded.
const linkFrom = (typed) => {
  let href = typed.trim().replace(/ /g, '%20');
  if (!href) return '';
  const hasScheme = /^[a-z][a-z0-9+.-]*:/i.test(href);
  if (!hasScheme && /^[^/?#@]+@[^/?#@]+\.[^/?#@]+$/.test(href)) href = `mailto:${href}`;
  else if (!hasScheme && !/^[/?#.]/.test(href) && /^[^/?#]+\.[^/?#]+/.test(href)) href = `https://${href}`;
  return href;
};

// -- Schema ------------------------------------------------------------------

const template = (root, name) => {
  const el = root.querySelector(`template[data-howdy-rich-text-${name}]`);
  return el && (el.content.firstElementChild || el.firstElementChild);
};

const makeSchema = (root) => {
  const chip = template(root, 'mention');
  return new Schema({
    nodes: {
      doc: { content: 'block+' },
      paragraph: {
        content: 'inline*',
        group: 'block',
        parseDOM: [{ tag: 'p' }],
        toDOM: () => ['p', 0],
      },
      heading: {
        attrs: { level: { default: 2 } },
        content: 'inline*',
        group: 'block',
        defining: true,
        parseDOM: [1, 2, 3, 4, 5, 6].map((level) => ({ tag: `h${level}`, attrs: { level } })),
        toDOM: (node) => [`h${node.attrs.level}`, 0],
      },
      blockquote: {
        content: 'block+',
        group: 'block',
        defining: true,
        parseDOM: [{ tag: 'blockquote' }],
        toDOM: () => ['blockquote', 0],
      },
      code_block: {
        content: 'text*',
        marks: '',
        group: 'block',
        code: true,
        defining: true,
        parseDOM: [{ tag: 'pre', preserveWhitespace: 'full' }],
        toDOM: () => ['pre', ['code', 0]],
      },
      horizontal_rule: {
        group: 'block',
        parseDOM: [{ tag: 'hr' }],
        toDOM: () => ['hr'],
      },
      bullet_list: {
        content: 'list_item+',
        group: 'block',
        parseDOM: [{ tag: 'ul' }],
        toDOM: () => ['ul', 0],
      },
      ordered_list: {
        attrs: { order: { default: 1 } },
        content: 'list_item+',
        group: 'block',
        parseDOM: [{ tag: 'ol', getAttrs: (dom) => ({ order: dom.hasAttribute('start') ? Number(dom.getAttribute('start')) || 1 : 1 }) }],
        toDOM: (node) => (node.attrs.order === 1 ? ['ol', 0] : ['ol', { start: node.attrs.order }, 0]),
      },
      list_item: {
        content: 'paragraph block*',
        defining: true,
        parseDOM: [{ tag: 'li' }],
        toDOM: () => ['li', 0],
      },
      attachment: {
        group: 'block',
        atom: true,
        selectable: true,
        draggable: true,
        // `upload` is this page's own handle on a file still being sent;
        // it is never posted.
        attrs: { key: { default: '' }, name: { default: '' }, content_type: { default: '' }, size: { default: 0 }, url: { default: null }, upload: { default: null } },
        parseDOM: [{
          tag: 'figure[data-howdy-attachment]',
          getAttrs: (dom) => {
            try {
              const attrs = JSON.parse(dom.getAttribute('data-howdy-attachment'));
              return typeof attrs.key === 'string' && attrs.key ? { key: attrs.key, name: String(attrs.name || ''), content_type: String(attrs.content_type || ''), size: Number(attrs.size) || 0, url: null } : false;
            } catch {
              return false;
            }
          },
        }],
        toDOM: (node) => ['figure', { 'data-howdy-attachment': JSON.stringify({ key: node.attrs.key, name: node.attrs.name, content_type: node.attrs.content_type, size: node.attrs.size }) }, node.attrs.name],
      },
      text: { group: 'inline' },
      mention: {
        inline: true,
        group: 'inline',
        atom: true,
        selectable: false,
        attrs: { trigger: {}, kind: {}, id: {}, label: {} },
        parseDOM: [{
          tag: 'span[data-howdy-mention]',
          getAttrs: (dom) => {
            const { howdyMention: kind, id, trigger, label } = dom.dataset;
            return kind && id && trigger && label ? { kind, id, trigger, label } : false;
          },
        }],
        toDOM: (node) => {
          const el = chip ? chip.cloneNode(true) : document.createElement('span');
          el.textContent = node.attrs.trigger + node.attrs.label;
          el.contentEditable = 'false';
          el.dataset.howdyMention = node.attrs.kind;
          el.dataset.id = node.attrs.id;
          el.dataset.trigger = node.attrs.trigger;
          el.dataset.label = node.attrs.label;
          return el;
        },
      },
      hard_break: {
        inline: true,
        group: 'inline',
        selectable: false,
        parseDOM: [{ tag: 'br' }],
        toDOM: () => ['br'],
      },
    },
    // In this order, links outermost and code innermost, as Gleam draws them.
    marks: {
      link: {
        attrs: { href: {} },
        inclusive: false,
        parseDOM: [{
          tag: 'a[href]',
          getAttrs: (dom) => {
            const href = dom.getAttribute('href');
            return isSafeLink(href) ? { href } : false;
          },
        }],
        toDOM: (mark) => ['a', { href: mark.attrs.href, rel: 'noopener noreferrer nofollow' }, 0],
      },
      bold: {
        parseDOM: [
          { tag: 'strong' },
          // Google Docs wraps everything in a normal-weight <b>.
          { tag: 'b', getAttrs: (dom) => dom.style.fontWeight !== 'normal' && null },
          { style: 'font-weight=400', clearMark: (mark) => mark.type.name === 'bold' },
          { style: 'font-weight', getAttrs: (value) => /^(bold(er)?|[5-9]\d{2,})$/.test(value) && null },
        ],
        toDOM: () => ['strong', 0],
      },
      italic: {
        parseDOM: [{ tag: 'i' }, { tag: 'em' }, { style: 'font-style=italic' }, { style: 'font-style=normal', clearMark: (mark) => mark.type.name === 'italic' }],
        toDOM: () => ['em', 0],
      },
      strike: {
        parseDOM: [{ tag: 's' }, { tag: 'del' }, { tag: 'strike' }, { style: 'text-decoration=line-through' }, { style: 'text-decoration-line=line-through' }],
        toDOM: () => ['s', 0],
      },
      code: {
        parseDOM: [{ tag: 'code' }],
        toDOM: () => ['code', 0],
      },
    },
  });
};

// -- The posted document -----------------------------------------------------

// The document as the server reads it: files still on their way are left
// out, and so is everything only this page needs.
const posted = (doc) => {
  const clean = (json) => {
    if (json.type === 'attachment') {
      if (!json.attrs.key) return null;
      const { key, name, content_type, size } = json.attrs;
      return { type: 'attachment', attrs: { key, name, content_type, size } };
    }
    if (json.content) json.content = json.content.map(clean).filter(Boolean);
    return json;
  };
  return JSON.stringify(clean(doc.toJSON()));
};

// The same as `document.is_empty` in Gleam.
const isEmpty = (doc) => {
  let empty = true;
  doc.descendants((node) => {
    if (!empty) return false;
    if (node.isText && node.text.trim()) empty = false;
    if (['mention', 'horizontal_rule', 'attachment'].includes(node.type.name)) empty = false;
    return empty;
  });
  return empty;
};

// -- Commands ----------------------------------------------------------------

const markActive = (state, type) => {
  const { from, $from, to, empty } = state.selection;
  if (empty) return Boolean(type.isInSet(state.storedMarks || $from.marks()));
  return state.doc.rangeHasMark(from, to, type);
};

const ancestor = (state, test) => {
  const { $from } = state.selection;
  for (let depth = $from.depth; depth > 0; depth--) {
    if (test($from.node(depth))) return { node: $from.node(depth), depth, pos: $from.before(depth) };
  }
  return null;
};

const nearestList = (state) => ancestor(state, (node) => ['bullet_list', 'ordered_list'].includes(node.type.name));

// A list button: lift out of a list of its kind, switch a list of the
// other kind, or make one.
const toggleList = (schema, type) => (state, dispatch) => {
  const list = nearestList(state);
  if (list?.node.type === type) return liftListItem(schema.nodes.list_item)(state, dispatch);
  if (list) {
    if (dispatch) dispatch(state.tr.setNodeMarkup(list.pos, type));
    return true;
  }
  return wrapInList(type)(state, dispatch);
};

const toggleBlock = (schema, type, attrs) => (state, dispatch) => {
  const { $from } = state.selection;
  const active = $from.parent.type === type && (!attrs || $from.parent.attrs.level === attrs.level);
  return active ? setBlockType(schema.nodes.paragraph)(state, dispatch) : setBlockType(type, attrs)(state, dispatch);
};

const toggleQuote = (schema) => (state, dispatch) =>
  ancestor(state, (node) => node.type === schema.nodes.blockquote) ? lift(state, dispatch) : wrapIn(schema.nodes.blockquote)(state, dispatch);

const insertDivider = (schema) => (state, dispatch) => {
  if (dispatch) {
    const tr = state.tr.replaceSelectionWith(schema.nodes.horizontal_rule.create());
    // Somewhere to keep typing after it.
    const after = tr.selection.$from;
    if (!after.nodeAfter || !after.nodeAfter.isTextblock) {
      tr.insert(after.pos, schema.nodes.paragraph.create());
      tr.setSelection(TextSelection.create(tr.doc, after.pos + 1));
    }
    dispatch(tr.scrollIntoView());
  }
  return true;
};

const insertBreak = (schema) => (state, dispatch) => {
  if (dispatch) dispatch(state.tr.replaceSelectionWith(schema.nodes.hard_break.create()).scrollIntoView());
  return true;
};

// The range of the link around the cursor, if there is one.
const linkRange = (state) => {
  const { $from, from, to, empty } = state.selection;
  const type = state.schema.marks.link;
  if (!empty) return { from, to, href: linkAt(state, from, to) };
  const mark = type.isInSet($from.marks()) || type.isInSet($from.nodeBefore?.marks || []) || type.isInSet($from.nodeAfter?.marks || []);
  if (!mark) return { from, to, href: '' };
  // The run of text carrying this link that the cursor is in.
  const start = $from.start();
  let run = null;
  let range = null;
  $from.parent.forEach((child, offset) => {
    const childFrom = start + offset;
    const childTo = childFrom + child.nodeSize;
    if (!mark.isInSet(child.marks)) {
      run = null;
      return;
    }
    run ??= childFrom;
    if (range && range.to === childFrom) range.to = childTo;
    else if (!range && run <= from && from <= childTo) range = { from: run, to: childTo };
  });
  return { ...(range || { from, to }), href: mark.attrs.href };
};

const linkAt = (state, from, to) => {
  let href = '';
  state.doc.nodesBetween(from, to, (node) => {
    const mark = state.schema.marks.link.isInSet(node.marks);
    if (mark && !href) href = mark.attrs.href;
  });
  return href;
};

// -- Markdown-like shortcuts -------------------------------------------------

const markRule = (regexp, type) =>
  new InputRule(regexp, (state, match, start, end) => {
    const text = match[match.length - 1];
    const before = state.doc.resolve(start).marks();
    const tr = state.tr.replaceWith(start, end, state.schema.text(text, type.create().addToSet(before)));
    return tr.removeStoredMark(type);
  });

const rules = (schema) =>
  inputRules({
    rules: [
      textblockTypeInputRule(/^(#{1,6})\s$/, schema.nodes.heading, (match) => ({ level: match[1].length })),
      wrappingInputRule(/^\s*>\s$/, schema.nodes.blockquote),
      wrappingInputRule(/^\s*([-+*])\s$/, schema.nodes.bullet_list),
      wrappingInputRule(/^(\d+)\.\s$/, schema.nodes.ordered_list, (match) => ({ order: Number(match[1]) }), (match, node) => node.childCount + node.attrs.order === Number(match[1])),
      textblockTypeInputRule(/^```$/, schema.nodes.code_block),
      new InputRule(/^(?:---|___|\*\*\*)$/, (state, match, start, end) => {
        const $start = state.doc.resolve(start);
        if ($start.parent.type !== schema.nodes.paragraph || $start.parent.content.size !== end - start) return null;
        const tr = state.tr.replaceRangeWith($start.before(), $start.after(), schema.nodes.horizontal_rule.create());
        const after = tr.mapping.map($start.after());
        tr.insert(after, schema.nodes.paragraph.create());
        return tr.setSelection(TextSelection.create(tr.doc, after + 1));
      }),
      markRule(/(?<![*\w])\*\*([^*\s](?:[^*]*[^*\s])?)\*\*$/, schema.marks.bold),
      markRule(/(?<![_\w])__([^_\s](?:[^_]*[^_\s])?)__$/, schema.marks.bold),
      markRule(/(?<![*\w])\*([^*\s](?:[^*]*[^*\s])?)\*$/, schema.marks.italic),
      markRule(/(?<![_\w])_([^_\s](?:[^_]*[^_\s])?)_$/, schema.marks.italic),
      markRule(/(?<!~)~~([^~\s](?:[^~]*[^~\s])?)~~$/, schema.marks.strike),
      markRule(/(?<!`)`([^`]+)`$/, schema.marks.code),
    ],
  });

// -- Placeholder -------------------------------------------------------------

const placeholder = (text) =>
  new Plugin({
    props: {
      decorations: (state) => {
        const { doc } = state;
        const first = doc.firstChild;
        if (!text || doc.childCount !== 1 || !first.isTextblock || first.content.size) return null;
        return DecorationSet.create(doc, [Decoration.node(0, first.nodeSize, { 'data-placeholder': text })]);
      },
    },
  });

// -- The text being linked ---------------------------------------------------

// While the link form has the focus, the text it will link stays marked.
const pendingKey = new PluginKey('howdy-link-pending');
const pendingLink = () =>
  new Plugin({
    key: pendingKey,
    state: {
      init: () => null,
      apply: (tr, range) => {
        const meta = tr.getMeta(pendingKey);
        if (meta !== undefined) return meta;
        return range && { from: tr.mapping.map(range.from), to: tr.mapping.map(range.to) };
      },
    },
    props: {
      decorations: (state) => {
        const range = pendingKey.getState(state);
        if (!range || range.from === range.to) return null;
        return DecorationSet.create(state.doc, [Decoration.inline(range.from, range.to, { 'data-howdy-link-pending': '' })]);
      },
    },
  });

// -- Mentions ----------------------------------------------------------------

const mentionKey = new PluginKey('howdy-mentions');

// What is being typed after a trigger, if anything: the source it belongs
// to, where it starts and the query so far.
const typedMention = (state, sources) => {
  const { $from, empty } = state.selection;
  if (!empty || !sources.length || $from.parent.type.spec.code || !$from.parent.inlineContent) return null;
  if (state.schema.marks.code.isInSet($from.marks())) return null;
  const before = $from.parent.textBetween(Math.max(0, $from.parentOffset - 60), $from.parentOffset, null, '￼');
  for (const source of sources) {
    const trigger = source.trigger.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const match = new RegExp(`(?:^|[\\s(\\[{"'])${trigger}([^\\s${trigger}\\ufffc]{0,40})$`).exec(before);
    if (match) {
      const query = match[1];
      return { source, query, from: $from.pos - query.length - source.trigger.length, to: $from.pos };
    }
  }
  return null;
};

const mentionPlugin = (sources, schema, menu, options, emptyNote, optionTemplate) => {
  const idBase = menu.id;
  let timer = 0;
  let controller = null;
  const cache = new Map();

  const plugin = new Plugin({
    key: mentionKey,
    state: {
      init: () => ({ typed: null, items: [], active: 0, dismissed: null, searched: false }),
      apply: (tr, value, _old, state) => {
        const meta = tr.getMeta(mentionKey) || {};
        const typed = typedMention(state, sources);
        const same = typed && value.typed && typed.from === value.typed.from && typed.query === value.typed.query && typed.source === value.typed.source;
        let { items, active, searched, dismissed } = same ? value : { ...value, items: [], active: 0, searched: false };
        // Once dismissed, the list stays shut while that mention is typed.
        if (!typed || typed.from !== dismissed) dismissed = null;
        if (meta.dismiss && typed) dismissed = typed.from;
        if (meta.items && typed && meta.query === typed.query && meta.source === typed.source) {
          items = meta.items;
          active = 0;
          searched = true;
        }
        if (typeof meta.active === 'number' && items.length) active = (meta.active + items.length) % items.length;
        return { typed, items, active, searched, dismissed };
      },
    },
    props: {
      handleKeyDown: (view, event) => {
        const value = mentionKey.getState(view.state);
        if (!open(value)) return false;
        const has = value.items.length > 0;
        if (has && (event.key === 'ArrowDown' || event.key === 'ArrowUp')) {
          const by = event.key === 'ArrowDown' ? 1 : -1;
          view.dispatch(view.state.tr.setMeta(mentionKey, { active: value.active + by }));
        } else if (has && (event.key === 'Enter' || event.key === 'Tab')) {
          choose(view, value.active);
        } else if (event.key === 'Escape') {
          view.dispatch(view.state.tr.setMeta(mentionKey, { dismiss: true }));
        } else {
          return false;
        }
        event.preventDefault();
        return true;
      },
      attributes: (state) => {
        const value = mentionKey.getState(state);
        if (!sources.length) return {};
        const attrs = { 'aria-autocomplete': 'list', 'aria-controls': idBase, 'aria-expanded': String(open(value)) };
        if (open(value) && value.items.length) attrs['aria-activedescendant'] = `${idBase}-option-${value.active}`;
        return attrs;
      },
    },
    view: (view) => ({
      update: (view, previous) => {
        const value = mentionKey.getState(view.state);
        const before = mentionKey.getState(previous);
        const typing = value.typed && (!before.typed || value.typed.query !== before.typed.query || value.typed.source !== before.typed.source);
        if (typing && value.dismissed === null) search(view, value.typed);
        if (!value.typed) {
          clearTimeout(timer);
          controller?.abort();
        }
        draw(view, value);
      },
      destroy: () => {
        clearTimeout(timer);
        controller?.abort();
        if (menu.matches(':popover-open')) menu.hidePopover();
      },
    }),
  });

  const open = (value) => Boolean(value.typed && value.dismissed === null && (value.items.length || value.searched));

  const search = (view, typed) => {
    clearTimeout(timer);
    controller?.abort();
    const key = `${typed.source.trigger}\u0000${typed.query}`;
    const deliver = (items) => view.dispatch(view.state.tr.setMeta(mentionKey, { items, query: typed.query, source: typed.source }));
    if (cache.has(key)) return queueMicrotask(() => !view.isDestroyed && deliver(cache.get(key)));
    timer = setTimeout(async () => {
      controller = new AbortController();
      const url = typed.source.search + (typed.source.search.includes('?') ? '&' : '?') + `q=${encodeURIComponent(typed.query)}`;
      try {
        const response = await fetch(url, { headers: { accept: 'application/json' }, signal: controller.signal });
        const answer = response.ok ? await response.json() : [];
        const items = (Array.isArray(answer) ? answer : [])
          .filter((item) => item && (typeof item.id === 'string' || typeof item.id === 'number') && typeof item.label === 'string' && item.label)
          .slice(0, 20)
          .map((item) => ({ id: String(item.id), label: item.label, detail: typeof item.detail === 'string' ? item.detail : '', image: typeof item.image === 'string' ? item.image : '' }));
        cache.set(key, items);
        if (!view.isDestroyed) deliver(items);
      } catch (error) {
        if (error.name !== 'AbortError' && !view.isDestroyed) deliver([]);
      }
    }, 120);
  };

  const choose = (view, index) => {
    const value = mentionKey.getState(view.state);
    const item = value.items[index];
    if (!value.typed || !item) return;
    const { typed } = value;
    const node = schema.nodes.mention.create({ trigger: typed.source.trigger, kind: typed.source.kind, id: item.id, label: item.label });
    const tr = view.state.tr.replaceWith(typed.from, typed.to, Fragment.from([node, schema.text(' ')]));
    view.dispatch(tr.scrollIntoView());
    view.focus();
  };

  const initials = (label) =>
    label
      .split(/\s+/)
      .filter(Boolean)
      .slice(0, 2)
      .map((word) => [...word][0].toUpperCase())
      .join('');

  let drawn = null;
  const draw = (view, value) => {
    const show = open(value) && view.hasFocus();
    if (!show) {
      drawn = null;
      if (menu.matches(':popover-open')) menu.hidePopover();
      return;
    }
    if (drawn !== value.items) {
      drawn = value.items;
      options.replaceChildren(
        ...value.items.map((item, index) => {
          const option = optionTemplate.cloneNode(true);
          option.id = `${idBase}-option-${index}`;
          const [avatar, label, detail] = option.children;
          const img = avatar.querySelector('img');
          if (item.image) {
            img.src = item.image;
            img.hidden = false;
            img.addEventListener('error', () => (img.hidden = true), { once: true });
          }
          avatar.prepend(document.createTextNode(initials(item.label)));
          label.textContent = item.label;
          detail.textContent = item.detail;
          detail.hidden = !item.detail;
          option.addEventListener('pointerdown', (event) => event.preventDefault());
          option.addEventListener('click', () => choose(view, index));
          option.addEventListener('pointermove', () => {
            const now = mentionKey.getState(view.state);
            if (now.active !== index) view.dispatch(view.state.tr.setMeta(mentionKey, { active: index }));
          });
          return option;
        }),
      );
      emptyNote.hidden = value.items.length > 0;
    }
    options.querySelectorAll('[role=option]').forEach((option, index) => {
      const active = index === value.active;
      option.setAttribute('aria-selected', String(active));
      option.toggleAttribute('data-active', active);
      if (active) option.scrollIntoView({ block: 'nearest' });
    });
    if (!menu.matches(':popover-open')) menu.showPopover();
    placeBelow(menu, view.coordsAtPos(value.typed.from));
  };

  return plugin;
};

// Put a floating element under a point in the text, or above it when there
// is no room below, and inside the window.
const placeBelow = (floating, at) => {
  const gap = 6;
  const box = floating.getBoundingClientRect();
  let top = at.bottom + gap;
  if (top + box.height > innerHeight - gap && at.top - gap - box.height > 0) top = at.top - gap - box.height;
  const left = Math.max(gap, Math.min(at.left, innerWidth - box.width - gap));
  Object.assign(floating.style, { position: 'fixed', top: `${top}px`, left: `${left}px` });
};

// -- Attachments -------------------------------------------------------------

// The same as `uploader.file_size` in Gleam, and the uploader's script.
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
// The same list as `document.is_image` in Gleam.
const isImage = (type) => ['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/avif', 'image/svg+xml'].includes((type || '').toLowerCase());

const accepts = (input, file) => {
  const types = (input?.getAttribute('accept') || '').split(',').map((type) => type.trim().toLowerCase()).filter(Boolean);
  const name = file.name.toLowerCase();
  const type = file.type.toLowerCase();
  return !types.length || types.some((allowed) => {
    if (allowed.startsWith('.')) return name.endsWith(allowed);
    if (allowed.endsWith('/*')) return type.startsWith(allowed.slice(0, -1));
    return type === allowed;
  });
};

class AttachmentView {
  constructor(node, view, getPos, editor) {
    this.node = node;
    this.view = view;
    this.getPos = getPos;
    this.editor = editor;
    const blank = template(editor.root, 'attachment');
    this.dom = blank ? blank.cloneNode(true) : document.createElement('figure');
    this.parts = Object.fromEntries([...this.dom.querySelectorAll('[data-part]')].map((el) => [el.dataset.part, el]));
    this.parts.remove?.addEventListener('click', () => this.remove());
    this.parts.image?.addEventListener('error', () => {
      this.parts.image.hidden = true;
      this.parts.card.hidden = false;
    });
    this.draw();
  }

  draw() {
    const { name, content_type, size, url, upload } = this.node.attrs;
    const state = upload ? this.editor.uploads.get(upload) : null;
    const source = url || state?.preview || '';
    const image = isImage(content_type) && source;
    const failed = state?.state === 'failed';
    const uploading = state?.state === 'uploading';
    const { image: img, card, icon, name: nameEl, detail, progress, error, remove } = this.parts;
    if (img) {
      if (image && img.getAttribute('src') !== source) img.src = source;
      img.alt = name;
      img.hidden = !image;
    }
    if (card) card.hidden = Boolean(image) && !uploading && !failed;
    card?.toggleAttribute('data-failed', failed);
    this.dom.toggleAttribute('data-uploading', uploading);
    if (icon) icon.textContent = extension(name);
    if (nameEl) nameEl.textContent = name;
    if (detail) detail.textContent = describe(name, size);
    if (progress) {
      progress.hidden = !uploading;
      const done = Math.round(state?.progress || 0);
      progress.setAttribute('aria-valuenow', String(done));
      progress.setAttribute('aria-label', `${this.editor.text('uploading')} ${name}`);
      if (progress.firstElementChild) progress.firstElementChild.style.width = `${done}%`;
    }
    if (error) {
      error.hidden = !failed;
      error.textContent = failed ? state.message : '';
    }
    remove?.setAttribute('aria-label', `${this.editor.text('remove')} ${name}`);
    if (remove) remove.disabled = !this.view.editable;
  }

  remove() {
    const pos = this.getPos();
    if (typeof pos !== 'number') return;
    this.view.dispatch(this.view.state.tr.delete(pos, pos + this.node.nodeSize));
    this.view.focus();
  }

  update(node) {
    if (node.type !== this.node.type) return false;
    this.node = node;
    this.draw();
    return true;
  }

  stopEvent(event) {
    return Boolean(event.target.closest?.('button'));
  }

  ignoreMutation() {
    return true;
  }
}

// -- The editor --------------------------------------------------------------

class Editor {
  constructor(root) {
    this.root = root;
    this.uploads = new Map();
    const part = (name) => root.querySelector(`[data-howdy-rich-text-${name}]`);
    this.input = part('value');
    this.proxy = part('proxy');
    this.mount = part('mount');
    this.toolbar = part('toolbar');
    this.files = part('files');
    this.linkForm = part('link');
    this.linkInput = part('link-input');
    const menu = part('menu');
    const schema = (this.schema = makeSchema(root));
    let sources = [];
    try {
      sources = JSON.parse(root.dataset.mentions || '[]').filter((source) => source.trigger && source.kind && source.search);
    } catch {}

    let doc;
    try {
      doc = schema.nodeFromJSON(JSON.parse(this.input.value));
      doc.check();
    } catch {
      doc = schema.node('doc', null, [schema.node('paragraph')]);
    }

    const marks = schema.marks;
    const nodes = schema.nodes;
    const mac = /Mac|iPhone|iPad/.test(navigator.platform);
    const keys = {
      'Mod-z': undo,
      'Shift-Mod-z': redo,
      'Mod-b': toggleMark(marks.bold),
      'Mod-i': toggleMark(marks.italic),
      'Mod-Shift-s': toggleMark(marks.strike),
      'Mod-e': toggleMark(marks.code),
      'Mod-k': () => (this.openLink(), true),
      'Shift-Enter': chainCommands(exitCode, insertBreak(schema)),
      'Mod-Enter': chainCommands(exitCode, insertBreak(schema)),
      Enter: splitListItem(nodes.list_item),
      'Mod-[': liftListItem(nodes.list_item),
      'Mod-]': sinkListItem(nodes.list_item),
      // Only inside a list, so Tab still leaves the editor elsewhere.
      Tab: sinkListItem(nodes.list_item),
      'Shift-Tab': liftListItem(nodes.list_item),
      'Mod-Alt-0': setBlockType(nodes.paragraph),
      'Mod-Shift-7': toggleList(schema, nodes.ordered_list),
      'Mod-Shift-8': toggleList(schema, nodes.bullet_list),
      Backspace: undoInputRule,
    };
    if (!mac) keys['Mod-y'] = redo;
    for (const level of [1, 2, 3, 4, 5, 6]) keys[`Mod-Alt-${level}`] = setBlockType(nodes.heading, { level });

    const plugins = [];
    if (sources.length && menu) {
      plugins.push(mentionPlugin(sources, schema, menu, part('options'), part('empty'), template(root, 'option')));
    }
    plugins.push(
      rules(schema),
      keymap(keys),
      keymap(baseKeymap),
      history(),
      dropCursor({ color: 'currentColor', width: 2 }),
      gapCursor(),
      placeholder(root.dataset.placeholder || ''),
      pendingLink(),
    );

    this.disabled = root.hasAttribute('data-disabled');
    this.lastPosted = posted(doc);
    this.lastChanged = this.lastPosted;
    this.view = new EditorView(this.mount, {
      state: EditorState.create({ doc, plugins }),
      editable: () => !this.disabled,
      attributes: {
        role: 'textbox',
        'aria-multiline': 'true',
        ...(root.hasAttribute('data-required') ? { 'aria-required': 'true' } : {}),
        ...(root.hasAttribute('data-invalid') ? { 'aria-invalid': 'true' } : {}),
      },
      nodeViews: { attachment: (node, view, getPos) => new AttachmentView(node, view, getPos, this) },
      dispatchTransaction: (tr) => this.dispatch(tr),
      handlePaste: (view, event) => this.takeFiles(event.clipboardData?.files, null),
      handleDrop: (view, event, slice, moved) => {
        if (moved || !event.dataTransfer?.files?.length) return false;
        const at = view.posAtCoords({ left: event.clientX, top: event.clientY });
        return this.takeFiles(event.dataTransfer.files, at ? at.pos : null);
      },
      handleDOMEvents: {
        blur: () => {
          this.changed();
          queueMicrotask(() => this.drawMenu());
          return false;
        },
      },
    });

    this.label();
    this.wire();
    this.sync(false);
    this.drawToolbar();
    root.setAttribute('data-ready', '');
    root.removeAttribute('data-failed');
  }

  text(name) {
    return this.root.dataset[`text${name.replace(/(^|-)(\w)/g, (_, __, c) => c.toUpperCase())}`] || '';
  }

  // The label pointing at the proxy names the editor.
  label() {
    const labels = this.proxy?.labels;
    const label = labels?.length ? labels[0].textContent.trim() : '';
    if (label) this.view.dom.setAttribute('aria-label', label);
  }

  wire() {
    const { root, view } = this;
    this.listeners = [];
    const listen = (target, type, handler, options) => {
      target?.addEventListener(type, handler, options);
      this.listeners.push(() => target?.removeEventListener(type, handler, options));
    };

    // Toolbar buttons act on the editor without taking its focus.
    listen(this.toolbar, 'mousedown', (event) => {
      if (event.target.closest('[data-command]')) event.preventDefault();
    });
    listen(this.toolbar, 'click', (event) => {
      const button = event.target.closest('[data-command]');
      if (button && !button.disabled) this.command(button.dataset.command);
    });
    // One stop in the tab order; the arrow keys move along the toolbar.
    listen(this.toolbar, 'keydown', (event) => {
      const buttons = [...this.toolbar.querySelectorAll('[data-command]')].filter((button) => !button.disabled);
      const index = buttons.indexOf(event.target.closest('[data-command]'));
      if (index < 0) return;
      const rtl = getComputedStyle(this.toolbar).direction === 'rtl';
      const next = { ArrowRight: rtl ? -1 : 1, ArrowLeft: rtl ? 1 : -1 }[event.key];
      let target = null;
      if (next) target = buttons[(index + next + buttons.length) % buttons.length];
      if (event.key === 'Home') target = buttons[0];
      if (event.key === 'End') target = buttons.at(-1);
      if (!target) return;
      event.preventDefault();
      this.rove(target);
      target.focus();
    });
    listen(this.toolbar, 'focusin', (event) => {
      const button = event.target.closest('[data-command]');
      if (button) this.rove(button);
    });

    // A label's click, or the form's check, lands on the proxy: send the
    // focus on to the editor, unless the browser is showing why the form
    // will not submit.
    // A submit that fails focuses the proxy in the same task as `invalid`.
    let complaining = false;
    listen(this.proxy, 'invalid', () => {
      complaining = true;
      setTimeout(() => (complaining = false));
    });
    listen(this.proxy, 'focus', () => {
      // Once the label's click is over, or it takes the focus back.
      if (!complaining) setTimeout(() => this.proxy.matches(':focus') && view.focus());
    });
    // Clicking the frame's padding still puts the cursor in the text.
    listen(this.mount, 'mousedown', (event) => {
      if (event.target === this.mount) {
        event.preventDefault();
        view.focus();
      }
    });

    listen(this.files, 'change', () => {
      this.takeFiles(this.files.files, null);
      this.files.value = '';
    });

    // The link form.
    listen(this.linkInput, 'keydown', (event) => {
      if (event.key === 'Enter') {
        event.preventDefault();
        this.applyLink();
      }
    });
    listen(this.linkInput, 'input', () => this.linkInput.setCustomValidity(''));
    listen(root.querySelector('[data-howdy-rich-text-link-apply]'), 'click', () => this.applyLink());
    listen(root.querySelector('[data-howdy-rich-text-link-remove]'), 'click', () => this.removeLink());
    listen(this.linkForm, 'toggle', (event) => {
      if (event.newState !== 'closed') return;
      // Never leave a value behind that the form would check.
      this.linkInput.value = '';
      this.linkInput.setCustomValidity('');
      if (this.linkForm.contains(this.root.getRootNode().activeElement) || this.restoreFocus) view.focus();
      this.restoreFocus = false;
      view.dispatch(view.state.tr.setMeta(pendingKey, null));
    });

    // A live view setting a new value replaces what is in the editor, but
    // the value it set from this editor's own last change, coming back
    // after more typing, does not.
    this.observer = new MutationObserver(() => this.outside());
    this.observer.observe(this.input, { attributes: true, attributeFilter: ['value', 'disabled'] });
  }

  rove(target) {
    for (const button of this.toolbar.querySelectorAll('[data-command]')) button.tabIndex = button === target ? 0 : -1;
  }

  outside() {
    const value = this.input.value;
    if (this.input.disabled !== this.disabled) {
      this.disabled = this.input.disabled;
      this.root.toggleAttribute('data-disabled', this.disabled);
      this.view.setProps({});
      this.drawToolbar();
    }
    const current = posted(this.view.state.doc);
    if (value === current) return;
    if (value === this.lastChanged) {
      this.input.value = current;
      return;
    }
    let doc;
    try {
      doc = this.schema.nodeFromJSON(JSON.parse(value));
      doc.check();
    } catch {
      this.input.value = current;
      return;
    }
    const state = this.view.state;
    const tr = state.tr.replaceWith(0, state.doc.content.size, doc.content).setMeta('addToHistory', false);
    this.lastChanged = posted(doc);
    this.view.dispatch(tr);
  }

  dispatch(tr) {
    const state = this.view.state.apply(tr);
    this.view.updateState(state);
    if (tr.docChanged) {
      this.sync(true);
      this.sweep();
    }
    this.drawToolbar();
  }

  // Keep the posted value, and what the form checks, up to date.
  sync(changed) {
    const doc = this.view.state.doc;
    const value = posted(doc);
    if (value !== this.input.value) this.input.value = value;
    if (changed && value !== this.lastPosted) {
      this.lastPosted = value;
      this.input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    }
    if (!this.proxy) return;
    const empty = isEmpty(doc);
    this.proxy.value = empty ? '' : 'filled';
    const uploading = [...this.uploads.values()].some((upload) => upload.state === 'uploading');
    if (uploading) this.proxy.setCustomValidity(this.text('wait'));
    else this.proxy.setCustomValidity(this.root.hasAttribute('data-required') && empty ? this.text('missing') : '');
  }

  // Like a text area, the editor says it changed when it loses focus.
  changed() {
    const value = posted(this.view.state.doc);
    if (value === this.lastChanged) return;
    this.lastChanged = value;
    this.input.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
  }

  drawMenu() {
    // The mention list follows the focus: redraw it once the editor loses it.
    if (!this.view.isDestroyed) this.view.dispatch(this.view.state.tr);
  }

  drawToolbar() {
    if (!this.toolbar) return;
    const { state } = this.view;
    const { schema } = this;
    const { $from } = state.selection;
    const list = nearestList(state);
    for (const button of this.toolbar.querySelectorAll('[data-command]')) {
      const command = button.dataset.command;
      let pressed = null;
      if (['bold', 'italic', 'strike', 'code'].includes(command)) pressed = markActive(state, schema.marks[command]);
      else if (command === 'link') pressed = markActive(state, schema.marks.link);
      else if (command.startsWith('heading-')) pressed = $from.parent.type === schema.nodes.heading && $from.parent.attrs.level === Number(command.slice(8));
      else if (command === 'quote') pressed = Boolean(ancestor(state, (node) => node.type === schema.nodes.blockquote));
      else if (command === 'bullet-list') pressed = list?.node.type === schema.nodes.bullet_list;
      else if (command === 'numbered-list') pressed = list?.node.type === schema.nodes.ordered_list;
      else if (command === 'code-block') pressed = $from.parent.type === schema.nodes.code_block;
      if (pressed !== null) button.setAttribute('aria-pressed', String(pressed));
      let enabled = !this.disabled;
      if (command === 'undo') enabled &&= undoDepth(state) > 0;
      if (command === 'redo') enabled &&= redoDepth(state) > 0;
      if (button.disabled === enabled) button.disabled = !enabled;
    }
  }

  command(name) {
    const { schema, view } = this;
    const { marks, nodes } = schema;
    const run = (command) => {
      command(view.state, view.dispatch);
      view.focus();
    };
    if (['bold', 'italic', 'strike', 'code'].includes(name)) return run(toggleMark(marks[name]));
    if (name.startsWith('heading-')) return run(toggleBlock(schema, nodes.heading, { level: Number(name.slice(8)) }));
    switch (name) {
      case 'link':
        return this.openLink();
      case 'quote':
        return run(toggleQuote(schema));
      case 'bullet-list':
        return run(toggleList(schema, nodes.bullet_list));
      case 'numbered-list':
        return run(toggleList(schema, nodes.ordered_list));
      case 'code-block':
        return run(toggleBlock(schema, nodes.code_block));
      case 'divider':
        return run(insertDivider(schema));
      case 'attach':
        return this.files?.click();
      case 'undo':
        return run(undo);
      case 'redo':
        return run(redo);
    }
  }

  // -- Links ----------------------------------------------------------------

  openLink() {
    if (!this.linkForm || this.disabled) return;
    const { state } = this.view;
    this.linkRange = linkRange(state);
    this.linkInput.value = this.linkRange.href;
    this.linkInput.setCustomValidity('');
    this.root.querySelector('[data-howdy-rich-text-link-remove]').hidden = !this.linkRange.href;
    this.view.dispatch(state.tr.setMeta(pendingKey, { from: this.linkRange.from, to: this.linkRange.to }));
    this.linkForm.showPopover();
    // Under the text being linked, so it stays in view.
    const start = this.view.coordsAtPos(this.linkRange.from);
    const end = this.view.coordsAtPos(this.linkRange.to);
    placeBelow(this.linkForm, { top: start.top, bottom: Math.max(start.bottom, end.bottom), left: start.left });
    this.linkInput.focus();
    this.linkInput.select();
  }

  applyLink() {
    const href = linkFrom(this.linkInput.value);
    if (!href) return this.removeLink();
    if (!isSafeLink(href)) {
      this.linkInput.setCustomValidity(this.text('bad-link'));
      this.linkInput.reportValidity();
      return;
    }
    const { schema } = this;
    const type = schema.marks.link;
    const { from, to } = this.linkRange || this.view.state.selection;
    let tr = this.view.state.tr;
    if (from === to) {
      const node = schema.text(href, [type.create({ href })]);
      tr = tr.replaceWith(from, to, node);
      tr.setSelection(TextSelection.create(tr.doc, from + node.nodeSize));
    } else {
      tr = tr.removeMark(from, to, type).addMark(from, to, type.create({ href }));
    }
    this.view.dispatch(tr.removeStoredMark(type).scrollIntoView());
    this.closeLink();
  }

  removeLink() {
    const { from, to } = this.linkRange || this.view.state.selection;
    if (from !== to) this.view.dispatch(this.view.state.tr.removeMark(from, to, this.schema.marks.link));
    this.closeLink();
  }

  closeLink() {
    this.restoreFocus = true;
    if (this.linkForm.matches(':popover-open')) this.linkForm.hidePopover();
    else this.view.focus();
  }

  // -- Attachments ----------------------------------------------------------

  // Put files into the document at `pos`, or where the selection is, and
  // send each to storage. Says whether it took them.
  takeFiles(list, pos) {
    const files = [...(list || [])];
    const start = this.root.dataset.uploadStart;
    if (!files.length || !start || this.disabled) return false;
    const type = this.schema.nodes.attachment;
    const maxSize = Number(this.root.dataset.maxSize) || Infinity;
    const nodes = files.map((file) => {
      const id = `upload-${Math.random().toString(36).slice(2)}`;
      const upload = { file, state: 'uploading', progress: 0, message: '', preview: isImage(file.type) ? URL.createObjectURL(file) : '' };
      if (!accepts(this.files, file)) Object.assign(upload, { state: 'failed', message: this.text('wrong-type') });
      else if (file.size > maxSize) Object.assign(upload, { state: 'failed', message: this.text('too-large') });
      this.uploads.set(id, upload);
      return type.create({ name: file.name, content_type: file.type || 'application/octet-stream', size: file.size, upload: id });
    });
    let tr = this.view.state.tr;
    if (typeof pos === 'number') tr = tr.setSelection(TextSelection.near(tr.doc.resolve(pos)));
    for (const node of nodes) tr = tr.replaceSelectionWith(node);
    this.view.dispatch(tr.scrollIntoView());
    this.view.focus();
    for (const node of nodes) {
      if (this.uploads.get(node.attrs.upload).state === 'uploading') this.send(node.attrs.upload, start);
    }
    return true;
  }

  // Find the node for an upload and change its attributes, or just redraw.
  updateUpload(id, attrs) {
    const { state } = this.view;
    let tr = null;
    state.doc.descendants((node, pos) => {
      if (node.type.name === 'attachment' && node.attrs.upload === id) {
        tr = (tr || state.tr).setNodeMarkup(pos, null, { ...node.attrs, ...attrs });
        return false;
      }
      return true;
    });
    if (tr) this.view.dispatch(tr.setMeta('addToHistory', false));
    else this.uploads.delete(id);
  }

  async send(id, start) {
    const upload = this.uploads.get(id);
    const fail = (message) => {
      Object.assign(upload, { state: 'failed', message: message || this.text('failed'), request: null });
      this.updateUpload(id, {});
      this.sync(false);
    };
    this.sync(false);
    try {
      const { file } = upload;
      const started = await fetch(start, {
        method: 'POST',
        headers: { 'content-type': 'application/json', accept: 'application/json' },
        body: JSON.stringify({ name: file.name, type: file.type || 'application/octet-stream', size: file.size }),
      });
      const answer = await started.json().catch(() => ({}));
      if (!this.uploads.has(id)) return;
      if (!started.ok) return fail(answer.fields?.[0]?.message || answer.error);
      const { key, upload: target } = answer;
      if (typeof key !== 'string' || !key || typeof target?.url !== 'string') return fail();
      await new Promise((resolve, reject) => {
        const request = new XMLHttpRequest();
        upload.request = request;
        request.open(target.method || 'PUT', target.url);
        for (const [name, value] of Object.entries(target.headers || {})) request.setRequestHeader(name, value);
        request.upload.onprogress = (event) => {
          if (event.lengthComputable) {
            upload.progress = (event.loaded / event.total) * 100;
            this.updateUpload(id, {});
          }
        };
        request.onload = () => (request.status < 300 ? resolve() : reject(new Error(`status ${request.status}`)));
        request.onerror = () => reject(new Error('network'));
        request.onabort = () => reject(new Error('aborted'));
        request.send(file);
      });
      Object.assign(upload, { state: 'done', progress: 100, request: null });
      this.updateUpload(id, { key });
      this.sync(false);
    } catch {
      if (this.uploads.has(id)) fail();
    }
  }

  // Uploads whose nodes have gone, such as by undo or removal, stop.
  sweep() {
    const live = new Set();
    this.view.state.doc.descendants((node) => {
      if (node.type.name === 'attachment' && node.attrs.upload) live.add(node.attrs.upload);
    });
    for (const [id, upload] of this.uploads) {
      if (!live.has(id) && upload.state !== 'done') {
        upload.request?.abort();
        if (upload.preview) URL.revokeObjectURL(upload.preview);
        this.uploads.delete(id);
      }
    }
  }

  destroy() {
    this.observer?.disconnect();
    for (const stop of this.listeners || []) stop();
    for (const upload of this.uploads.values()) {
      upload.request?.abort();
      if (upload.preview) URL.revokeObjectURL(upload.preview);
    }
    this.view.destroy();
    this.root.removeAttribute('data-ready');
  }
}

// Called by `howdy/ui/behaviour` for each editor on the page.
export const mount = (root) => new Editor(root);
