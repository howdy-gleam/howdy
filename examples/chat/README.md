# Chat example

A chat room built on `howdy/websocket`, `howdy/websocket/channel` and
`howdy/websocket/presence`.

```sh
cd examples/chat
gleam run
```

It listens on 127.0.0.1:**8789**. Open http://localhost:8789 in two browser tabs,
pick a name and a room, and talk.

Each room is a channel topic. A socket joins the room when it opens and pg
drops it when the connection ends.

The "Here" list comes from presence. Every socket tracks its person in the
room, keyed by name, and watches the room; the page keeps the list with the
client script served at `/howdy/presence.js`. Open two tabs with the same
name and you are listed once, typing while either tab is, and you only
leave when the last tab closes. Anything that knows the room name can
broadcast to it, so the HTTP routes below reach the same sockets:

```sh
curl http://localhost:8789/rooms/lobby                                   # {"room":"lobby","members":2}, people not tabs
curl -i -X POST http://localhost:8789/rooms/lobby/announce -d '{"text":"Server restarting soon"}'   # 202, shows in every tab
curl -i 'http://localhost:8789/chat/lobby'                               # 400, the name is checked before the upgrade
```

With [websocat](https://github.com/vi/websocat) you can join from a terminal
and type JSON lines:

```sh
websocat 'ws://localhost:8789/chat/lobby?name=Ada'
{"text":"hello from the terminal"}
{"typing":true}
```

Run the HTTP routes as tests, without a server:

```sh
gleam test
```
