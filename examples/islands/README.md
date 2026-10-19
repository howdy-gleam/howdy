# Islands example

Two Lustre counters rendered on the server and run in the browser.

```sh
gleam run   # or: gleam dev, for hot reload
```

It listens on 127.0.0.1:8793. The islands live in
`src/howdy_islands_example/islands`. `ui.islands()` builds them for
JavaScript when a page loads them, so editing an island and reloading
the page is enough, even under `gleam run`. Compile errors show on the page.

For a release, bundle the islands first; the export picks the bundle up
from `priv/howdy_islands`:

```sh
gleam run -m howdy/ui islands
gleam export erlang-shipment
```
