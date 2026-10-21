# Live example

A themed page with a private counter and a shared counter, both Lustre
server components running over howdy WebSockets.

```sh
gleam run
```

It listens on 127.0.0.1:8790. Open <http://localhost:8790> in two tabs. The theme button flips light and
dark without a reload and stores the choice in a `theme` cookie, which the
page reads on the next request so the first paint is already right.
