%% pg-backed topics for howdy/websocket/channel.
-module(howdy_channel_ffi).
-export([channel_join/2, channel_leave/2, channel_members/1, channel_local_members/1,
         channel_broadcast/3, tuple_second/1]).

%% -- WebSocket channels ------------------------------------------------------
%%
%% Topics are `pg` groups in a scope owned by howdy. Members are the socket
%% processes; `pg` monitors them and drops them when they exit, so a socket
%% that dies never needs to leave.

-define(CHANNEL_SCOPE, howdy_websocket_channels).

%% The scope is a child of the howdy application's supervisor (see
%% howdy_app), started at boot or on first use, and restarted if it dies.
channel_scope() ->
    howdy_app:ensure_started(),
    ?CHANNEL_SCOPE.

channel_join(Topic, Pid) ->
    ok = pg:join(channel_scope(), Topic, Pid),
    nil.

channel_leave(Topic, Pid) ->
    _ = pg:leave(channel_scope(), Topic, Pid),
    nil.

channel_members(Topic) ->
    pg:get_members(channel_scope(), Topic).

%% The members on this node only.
channel_local_members(Topic) ->
    pg:get_local_members(channel_scope(), Topic).

%% Send `{Tag, Message}` to every member of Topic. Duplicates arise when a
%% process joined more than once, so they are sent to once.
channel_broadcast(Topic, Tag, Message) ->
    lists:foreach(
        fun(Pid) -> Pid ! {Tag, Message} end,
        lists:usort(channel_members(Topic))
    ),
    nil.

tuple_second(Tuple) ->
    element(2, Tuple).

