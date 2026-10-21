// The browser side of howdy/ui/internal/stylesheet, used when components
// render inside an island. The server keeps the registry in ETS; here it
// is a Map. A class rendered by the server already has its CSS on the
// page, so only classes first seen in the browser are added, to a <style>
// element of their own.
//
// Islands inside a live view render in its shadow root, which the page's
// styles do not reach. The live view's own <style> holds only the classes
// its latest server render used, so those islands get every class seen in
// the browser, in a stylesheet adopted by each such shadow root.

import { Ok, Error, toList } from "../../../gleam.mjs";

const classes = new Map();
// Keyed by Sketch's description of the styles: components build a new
// Class on every render, so identity would never hit.
const names = new Map();
const scopes = [];
let sheet;
let onPage;
let shadowSheet;
const shadowRules = [];
let flushing = false;

export function known(name) {
  return classes.has(name);
}

export function register(name, css) {
  if (classes.has(name)) return;
  classes.set(name, css);
  if (typeof document === "undefined") return;
  if (shadowSheet) {
    shadowRules.push(css);
    flushSoon();
  }
  if (pageHas(name)) return;
  if (!sheet) {
    sheet = document.createElement("style");
    sheet.dataset.howdyUiIslands = "";
    document.head.append(sheet);
  }
  sheet.append(document.createTextNode(css + "\n\n"));
}

// Called with each island's root element before it starts.
export function attach(element) {
  const root = element.getRootNode();
  if (!(root instanceof ShadowRoot)) return;
  if (!shadowSheet) {
    shadowSheet = new CSSStyleSheet();
    shadowRules.push(...classes.values());
    flushSoon();
  }
  // Checked on every start: a live view resets its adopted stylesheets
  // when it reconnects, and starts its islands again.
  if (!root.adoptedStyleSheets.includes(shadowSheet)) {
    root.adoptedStyleSheets = [...root.adoptedStyleSheets, shadowSheet];
  }
}

// Classes are registered one at a time while a view renders; parse them
// together once it is done, before the browser paints.
function flushSoon() {
  if (flushing) return;
  flushing = true;
  queueMicrotask(() => {
    flushing = false;
    shadowSheet.replaceSync(shadowRules.join("\n\n"));
  });
}

export function name_of(cls) {
  const name = names.get(cls.as_string);
  return name === undefined ? new Error(undefined) : new Ok(name);
}

export function remember_name(cls, name) {
  names.set(cls.as_string, name);
}

export function all_css() {
  return [...classes.values()].join("\n\n");
}

export function css_for(wanted) {
  const set = new Set(wanted.toArray());
  return [...classes]
    .filter(([name]) => set.has(name))
    .map(([, css]) => css)
    .join("\n\n");
}

export function scope_begin() {
  scopes.push([]);
}

export function scope_end() {
  return toList(scopes.pop() ?? []);
}

export function note(name) {
  scopes.at(-1)?.push(name);
}

// Whether the page's own stylesheets already define `name`, as a class or
// a named block such as @keyframes. Read once, on the first registration.
function pageHas(name) {
  if (!onPage) {
    onPage = new Set();
    for (const styles of document.styleSheets) {
      if (styles.ownerNode === sheet) continue;
      try {
        collect(styles.cssRules);
      } catch {
        // A cross-origin stylesheet cannot be read; its rules get added again.
      }
    }
  }
  return onPage.has(name);
}

function collect(rules) {
  for (const rule of rules) {
    if (rule.selectorText) {
      for (const [, name] of rule.selectorText.matchAll(/\.([\w-]+)/g)) onPage.add(name);
    }
    if (rule.name) onPage.add(rule.name);
    if (rule.cssRules) collect(rule.cssRules);
  }
}
