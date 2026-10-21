# Gallery example

howdy_ui components assembled into whole screens.

```sh
gleam run
```

It listens on 127.0.0.1:8791. Open <http://localhost:8791>.

- **Dashboard** (`/`): a collapsible sidebar that remembers its state in a
  cookie, stat cards, a bar and an area chart, and a live orders table you
  can sort, filter by status and due date, select, mark paid and page
  through. Marking orders paid shows a toast.
- **Chat** (`/chat`): a live view with a bot whose replies stream in a
  word at a time. The conversation stays on the newest line while a reply
  grows, and keeps its place if you scroll back.
- **Components** (`/components`): a line chart, a data table sorted with
  plain links, pagination, a calendar inside an ordinary form, a command
  menu, and a toast that stays until it is closed.
- **Sign in** and **Sign up** (`/sign-in`, `/sign-up`): centred forms. Sign
  up validates on the server and shows each problem beside its field.

- **howdy_ui reference** (`/ui`): every component, block and theme preset,
  with examples and their code, mounted with `gallery.controller`.

Press ⌘K or Ctrl+K anywhere in the app to search its pages.

The screens use howdy_ui's blocks: `app_shell`, `stat_card`, `sign_in` and
`sign_up`. `gleam run -m howdy/ui add sign_up` copies one into a project
with the components it uses. `src/howdy_gallery/orders.gleam` and
`src/howdy_gallery/chat.gleam` are the live views.
