# howdy_templates

HTML templates for [Lustre](https://hexdocs.pm/lustre/), written like React
components, to be compiled to typed Gleam. Templates and Gleam components
will use each other freely: layouts, pages and components can be either.

Work in progress: templates generate into a project, and compiler errors
can be pointed back at them. Regenerating under `gleam dev` comes next.

## A template

```html
---
import gleam/list
import shop/orders.{type Order, status_badge}
import shop/templates/layout.{layout}

props(orders: List(Order))
---
<Layout title="Orders">
  {...list.map(orders, fn(order) {
    <section class="order">
      <h2>{order.title}</h2>
      <StatusBadge status={order.status} />
    </section>
  })}
</Layout>
```

- The header is Gleam: imports, helpers, and `props(...)` for the
  template's labelled arguments.
- Lowercase tags are HTML. Capitalised tags call functions:
  `<StatusBadge>` calls `status_badge`, `<orders.StatusBadge>` calls
  `orders.status_badge`.
- `{expression}` is Gleam. Markup can start wherever a Gleam expression
  can, `{...list}` spreads a list of elements, and `{children}` puts in
  what the template was given.
- `{// a note}` is a comment, as in JSX.

## Tools

- `gleam run -m howdy/templates` generates every module, formatted, into
  `src/<package>/templates/`, which holds generated modules only and ignores
  itself in git. `-- check` fails if one is out of date.
- `gleam build 2>&1 | gleam run -m howdy/templates -- rewrite` points
  compiler errors at the template line.

## Development

```sh
gleam test
```
