//// Named groups of sockets to broadcast to.
////
//// A socket joins a topic, and anything running anywhere in the program can
//// send a frame to every socket on that topic: an HTTP handler, a service,
//// a background job, or another socket.
////
//// ```gleam
//// import howdy/websocket
//// import howdy/websocket/channel
////
//// websocket.new(fn(socket) {
////   channel.join(socket, "room:" <> room)
////   Nil
//// })
//// |> websocket.on_text(fn(_socket, state, text) {
////   channel.broadcast_text("room:" <> room, text)
////   websocket.continue(state)
//// })
//// ```
////
//// Topics live in an Erlang `pg` scope that howdy starts on first use.
//// Membership is tied to the socket process, so a socket that closes or
//// crashes is removed from every topic automatically. If the app runs on
//// several connected nodes, a broadcast reaches sockets on all of them.

import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/json.{type Json}
import gleam/list
import howdy/websocket.{type Frame, type Socket}

@external(erlang, "howdy_channel_ffi", "channel_join")
fn join_pid(topic: String, pid: Pid) -> Nil

@external(erlang, "howdy_channel_ffi", "channel_leave")
fn leave_pid(topic: String, pid: Pid) -> Nil

@external(erlang, "howdy_channel_ffi", "channel_members")
fn members(topic: String) -> List(Pid)

@external(erlang, "howdy_channel_ffi", "channel_broadcast")
fn send_all(topic: String, tag: Atom, frame: Frame) -> Nil

/// Subscribe a socket to a topic. Joining a topic twice has no extra effect.
pub fn join(socket: Socket(msg), topic: String) -> Nil {
  join_pid(topic, websocket.pid(socket))
}

/// Unsubscribe a socket from a topic. Leaving a topic the socket is not on
/// does nothing.
pub fn leave(socket: Socket(msg), topic: String) -> Nil {
  leave_pid(topic, websocket.pid(socket))
}

/// Send a frame to every socket on a topic. The frames go out from each
/// socket's own process, so this returns at once and never blocks the
/// caller on a slow client.
pub fn broadcast(topic: String, frame: Frame) -> Nil {
  send_all(topic, atom.create(websocket.channel_tag), frame)
}

/// Send a text frame to every socket on a topic.
pub fn broadcast_text(topic: String, text: String) -> Nil {
  broadcast(topic, websocket.Text(text))
}

/// Send JSON as a text frame to every socket on a topic.
pub fn broadcast_json(topic: String, body: Json) -> Nil {
  broadcast_text(topic, json.to_string(body))
}

/// How many sockets are on a topic.
pub fn size(topic: String) -> Int {
  members(topic) |> list.unique |> list.length
}
