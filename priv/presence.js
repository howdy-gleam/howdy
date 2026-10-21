// The browser half of howdy/websocket/presence.
//
// A socket watching a topic is sent the topic's presences once, as a
// "state" message, then a "diff" of joins and leaves after every change.
// Hand each parsed message to `receive`, which keeps the list and returns
// whether the message was one of these:
//
//   import { Presence } from "/howdy/presence.js"
//
//   const users = new Presence({ name: "users", topic: "room:lobby" })
//   users.onSync((list) => render(list))
//   socket.onmessage = (event) => {
//     const message = JSON.parse(event.data)
//     if (users.receive(message)) return
//     // the app's own messages
//   }
//
// `name` and `topic` are optional; without them a Presence takes every
// presence message. The list is [{ key, metas }], ordered by key, with each
// key's metas oldest first. A key stays listed until its last meta leaves,
// so someone with two tabs open is listed once.
//
// After a reconnect the server sends a new state, and the difference from
// the old one is reported as joins and leaves.

export class Presence {
  #name
  #topic
  #entries = new Map()
  #onSync = []
  #onJoin = []
  #onLeave = []

  constructor({ name, topic } = {}) {
    this.#name = name
    this.#topic = topic
  }

  // Handle a parsed message. Returns true if it was a presence message for
  // this Presence, false if it is someone else's to handle.
  receive(message) {
    if (message === null || typeof message !== "object") return false
    if (message.presence !== "state" && message.presence !== "diff") return false
    if (this.#name !== undefined && message.name !== this.#name) return false
    if (this.#topic !== undefined && message.topic !== this.#topic) return false
    if (message.presence === "state") this.#replace(message.entries ?? [])
    else this.#apply(message.joins ?? [], message.leaves ?? [])
    const list = this.list()
    for (const callback of this.#onSync) callback(list)
    return true
  }

  // Everyone present, as [{ key, metas }].
  list() {
    return [...this.#entries.keys()]
      .sort()
      .map((key) => ({ key, metas: this.#entries.get(key).map((meta) => meta.meta) }))
  }

  // The metas for one key, or undefined if the key is not present.
  get(key) {
    return this.#entries.get(key)?.map((meta) => meta.meta)
  }

  // Run `callback(list)` after every state or diff.
  onSync(callback) {
    this.#onSync.push(callback)
    return this
  }

  // Run `callback(key, current, joined)` for each key that gains metas.
  // `current` is the key's metas before, undefined for a new arrival.
  onJoin(callback) {
    this.#onJoin.push(callback)
    return this
  }

  // Run `callback(key, remaining, left)` for each key that loses metas.
  // `remaining` is empty when the key has gone.
  onLeave(callback) {
    this.#onLeave.push(callback)
    return this
  }

  #replace(entries) {
    const incoming = new Map(entries.map((entry) => [entry.key, entry.metas]))
    const joins = []
    const leaves = []
    for (const [key, metas] of incoming) {
      const known = new Set((this.#entries.get(key) ?? []).map((meta) => meta.ref))
      const added = metas.filter((meta) => !known.has(meta.ref))
      if (added.length > 0) joins.push({ key, metas: added })
    }
    for (const [key, metas] of this.#entries) {
      const kept = new Set((incoming.get(key) ?? []).map((meta) => meta.ref))
      const removed = metas.filter((meta) => !kept.has(meta.ref))
      if (removed.length > 0) leaves.push({ key, metas: removed })
    }
    this.#apply(joins, leaves)
  }

  // Joins first, so a meta replaced in one diff never makes its key vanish.
  #apply(joins, leaves) {
    for (const { key, metas } of joins) {
      const before = this.#entries.get(key)
      const known = new Set((before ?? []).map((meta) => meta.ref))
      const added = metas.filter((meta) => !known.has(meta.ref))
      if (added.length === 0) continue
      this.#entries.set(key, [...(before ?? []), ...added])
      const current = before?.map((meta) => meta.meta)
      for (const callback of this.#onJoin) callback(key, current, added.map((meta) => meta.meta))
    }
    for (const { key, metas } of leaves) {
      const before = this.#entries.get(key)
      if (before === undefined) continue
      const gone = new Set(metas.map((meta) => meta.ref))
      const left = before.filter((meta) => gone.has(meta.ref))
      if (left.length === 0) continue
      const remaining = before.filter((meta) => !gone.has(meta.ref))
      if (remaining.length === 0) this.#entries.delete(key)
      else this.#entries.set(key, remaining)
      for (const callback of this.#onLeave) {
        callback(key, remaining.map((meta) => meta.meta), left.map((meta) => meta.meta))
      }
    }
  }
}
