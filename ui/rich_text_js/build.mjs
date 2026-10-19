// Bundles src/editor.js and the ProseMirror packages it uses into
// ../priv/rich_text.js, and records the bundle's hash in
// ../src/howdy/ui/internal/rich_text_script.gleam, which names the URL it
// is served at. Both files are committed; CI rebuilds them and checks
// nothing changed.
//
//   cd ui/rich_text_js && npm ci && npm run build

import { build } from 'esbuild';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';

const here = (path) => new URL(path, import.meta.url);
const packages = JSON.parse(readFileSync(here('package.json'))).dependencies;

const banner = `/*! howdy/ui/rich_text: the browser side of the rich text editor.
 * Includes ProseMirror (${Object.entries(packages).map(([name, version]) => `${name} ${version}`).join(', ')}),
 * orderedmap, rope-sequence and w3c-keyname,
 * Copyright (C) 2015-2024 by Marijn Haverbeke <marijn@haverbeke.berlin> and others.
 * Released under the MIT licence: https://github.com/ProseMirror/prosemirror/blob/master/LICENSE
 */`;

const result = await build({
  entryPoints: [here('src/editor.js').pathname],
  bundle: true,
  format: 'esm',
  minify: true,
  target: 'es2022',
  legalComments: 'none',
  banner: { js: banner },
  write: false,
});

const code = result.outputFiles[0].contents;
writeFileSync(here('../priv/rich_text.js'), code);
const hash = createHash('sha256').update(code).digest('hex').slice(0, 16);
writeFileSync(
  here('../src/howdy/ui/internal/rich_text_script.gleam'),
  `//// Written by \`rich_text_js/build.mjs\` with the bundle it describes.

/// The start of the SHA-256 of \`priv/rich_text.js\`.
pub const hash = "${hash}"
`,
);
console.log(`priv/rich_text.js: ${code.length} bytes, ${hash}`);
