// Browser side of howdy/ui/island. The boot module served by
// ui.islands() imports `boot` from here.

import { start } from "./island.mjs";
import { attach } from "./internal/stylesheet.ffi.mjs";
import { Result$isOk, Result$Error$0 } from "../../gleam.mjs";

export const identity = (value) => value;

// Make <howdy-island> a custom element that starts itself. The browser
// upgrades every one already in the document, including those inside live
// views' shadow roots, and any added later, such as by a live link.
// `modules` maps module paths to bundled files in a release; in
// development each module is served from the JavaScript build as is.
export function boot(base, { overlay, modules = {} }) {
  if (customElements.get("howdy-island")) return;
  customElements.define(
    "howdy-island",
    class extends HTMLElement {
      static observedAttributes = watched;

      connectedCallback() {
        // Wait for whoever is inserting the element to add its children.
        queueMicrotask(() => {
          if (this.isConnected) launch(this, base, overlay, modules);
        });
      }

      // Moving an element disconnects and reconnects it in one go, so
      // only stop an island still out of the page a moment later.
      disconnectedCallback() {
        queueMicrotask(() => {
          if (!this.isConnected) stop(this);
        });
      }

      // island.mount keys the element by these, so a page that changes
      // them gets a new element. Rewriting a running island in place
      // cannot work, so say so rather than leave it inert.
      attributeChangedCallback(name, before, after) {
        if (!("started" in this.dataset) || before === after) return;
        report(
          `the ${name} of a running island changed in place, so the page shows a different island than the one running. Render islands with island.mount.`,
          overlay,
        );
      }
    },
  );
}

const watched = ["data-package", "data-module", "data-function", "data-flags"];

// The current launch of each island element. Removing the element ends
// it, so a launch still loading its module when the element is removed,
// and perhaps put back with a launch of its own, knows not to start.
const launches = new WeakMap();

async function launch(root, base, overlay, modules) {
  if ("started" in root.dataset) return;
  root.dataset.started = "";
  const token = {};
  launches.set(root, token);
  const { package: pkg, module, function: name, flags, error } = root.dataset;
  const label = module ? `${module}.${name}` : "an island";
  if (error) return report(`could not start ${label}: ${error}`, overlay);
  attach(root);
  try {
    const file = modules[module] ?? `${pkg}/${module}.mjs`;
    const loaded = await import(base + file);
    const make = loaded[name];
    if (typeof make !== "function") {
      return report(`${module} has no public function ${name}`, overlay);
    }
    // Removed while its code loaded, and perhaps put back with a newer
    // launch: leave starting to that one.
    if (launches.get(root) !== token || !root.isConnected) return;
    const result = start(make(), root, flags);
    if (Result$isOk(result)) {
      root.dataset.running = "";
    } else {
      report(`could not start ${label}: ${Result$Error$0(result)}`, overlay);
    }
  } catch (e) {
    report(`could not start ${label}: ${e?.stack ?? e}`, overlay);
  }
}

// -- Lifetimes ---------------------------------------------------------------
//
// Lustre cannot stop an app, so island.start wraps the island's update and
// view to do nothing once its lifetime ends, and island.subscription
// registers effects to end with it. An island put back in the page starts
// again, with a new lifetime.

const lifetimes = new WeakMap();

// How long after an island stops a message means an effect is still
// running, rather than one last timeout firing.
const late = 5000;

export function begin_lifetime(root) {
  const { module, function: name } = root.dataset;
  const lifetime = { alive: true, cleanups: [], stopped: 0, warned: false, label: `${module}.${name}` };
  lifetimes.set(root, lifetime);
  return lifetime;
}

export const alive = (lifetime) => lifetime.alive;

export function accepts(lifetime) {
  if (lifetime.alive) return true;
  const after = performance.now() - lifetime.stopped;
  if (after > late && !lifetime.warned) {
    lifetime.warned = true;
    console.warn(
      `howdy islands: ${lifetime.label} was removed from the page ${Math.round(after / 1000)}s ago, but an effect it started still sends it messages, and keeps it in memory. Start effects that keep running, such as intervals and event listeners, with island.subscription or island.every, so they stop with the island.`,
    );
  }
  return false;
}

// Run `cleanup` when the island on `root` stops, or now if it already has.
// Outside an island, such as in a plain Lustre app, it never runs.
export function on_stop(root, cleanup) {
  const lifetime = lifetimes.get(root);
  if (!lifetime) return;
  if (lifetime.alive) lifetime.cleanups.push(cleanup);
  else end(cleanup, lifetime);
}

function stop(root) {
  launches.delete(root);
  delete root.dataset.started;
  delete root.dataset.running;
  const lifetime = lifetimes.get(root);
  if (!lifetime?.alive) return;
  lifetime.alive = false;
  lifetime.stopped = performance.now();
  for (const cleanup of lifetime.cleanups) end(cleanup, lifetime);
  lifetime.cleanups = [];
}

function end(cleanup, lifetime) {
  try {
    cleanup();
  } catch (e) {
    console.error(`howdy islands: stopping ${lifetime.label} failed:`, e);
  }
}

export const set_interval = (milliseconds, callback) => setInterval(callback, milliseconds);

export const clear_interval = (interval) => clearInterval(interval);

// A build that failed: show the compiler output.
export function failed(output, { overlay }) {
  report(output, overlay);
}

let panel;

function report(message, overlay) {
  console.error(`howdy islands: ${message}`);
  if (!overlay) return;
  if (!panel) {
    panel = document.createElement("div");
    panel.setAttribute(
      "style",
      "position:fixed;inset:auto 1rem 1rem 1rem;max-height:60vh;overflow:auto;" +
        "z-index:2147483647;padding:1rem;background:#7f1d1d;color:#fff;" +
        "font:13px/1.45 ui-monospace,monospace;border-radius:.5rem;white-space:pre-wrap",
    );
    panel.dataset.howdyIslandsErrors = "";
    const title = document.createElement("strong");
    title.textContent = "howdy islands";
    panel.append(title);
    document.body.append(panel);
  }
  const entry = document.createElement("div");
  entry.style.marginTop = ".5rem";
  entry.textContent = message;
  panel.append(entry);
}
