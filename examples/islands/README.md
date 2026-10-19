# Islands example

Lustre islands rendered on the server and run in the browser: two
counters, and a task list built from howdy_ui components. `/live` shows
islands inside a live view, which can swap one for another, including a
ticker whose timer stops when it is swapped out. The star rating is
shipped by a package, `library/`, from its own `islands` directory; the
app mounts it like its own islands.

```sh
gleam run   # or: gleam dev, for hot reload
```

It listens on 127.0.0.1:8793. The islands live in
`src/howdy_islands_example/islands`. `ui.islands()` builds them for
JavaScript when a page loads them, so editing an island and reloading
the page is enough, even under `gleam run`. Compile errors show on the page.

For a release, export with howdy_ui, which bundles the islands into
`priv/howdy_islands` and then runs `gleam export erlang-shipment`:

```sh
gleam run -m howdy/ui export
```

`browser_test/smoke.sh` runs the browser tests under `gleam run`, then
against a release exported from a clean build, and checks that a release
exported after a change, without bundling again, refuses its bundle.
