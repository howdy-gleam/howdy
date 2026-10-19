// Browser side of howdy/ui/island. The boot module served by
// ui.islands() imports `boot` from here.

import { start } from "./island.mjs";
import { Result$isOk, Result$Error$0 } from "../../gleam.mjs";

export const identity = (value) => value;

// Start every island on the page that has not been started yet.
// `modules` maps module paths to bundled files in a release; in
// development each module is served from the JavaScript build as is.
export async function boot(base, { overlay, modules = {} }) {
  const islands = document.querySelectorAll("howdy-island:not([data-started])");
  await Promise.all(
    Array.from(islands, async (root) => {
      root.dataset.started = "";
      const { package: pkg, module, function: name, flags, error } = root.dataset;
      const label = module ? `${module}.${name}` : "an island";
      if (error) return report(`could not start ${label}: ${error}`, overlay);
      try {
        const file = modules[module] ?? `${pkg}/${module}.mjs`;
        const loaded = await import(base + file);
        const make = loaded[name];
        if (typeof make !== "function") {
          return report(`${module} has no public function ${name}`, overlay);
        }
        const result = start(make(), root, flags);
        if (!Result$isOk(result)) {
          report(`could not start ${label}: ${Result$Error$0(result)}`, overlay);
        }
      } catch (e) {
        report(`could not start ${label}: ${e?.stack ?? e}`, overlay);
      }
    }),
  );
}

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
