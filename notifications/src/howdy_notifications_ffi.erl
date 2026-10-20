%% Live delivery for howdy/notifications: each user's events go to a `pg`
%% group in howdy's channel scope, so they reach subscribers on every
%% connected node, and a small relay process per subscriber hands them on.
-module(howdy_notifications_ffi).
-export([now_ms/0, subscribe/3, unsubscribe/1, broadcast/2, subscribers/1]).
-export([local_broadcast/2, local_subscribers/1, fan_out_name/0]).
-export([rescue/1]).

-define(TAG, howdy_notifications).

now_ms() ->
    erlang:system_time(millisecond).

group(User) -> {?TAG, User}.

%% Start a relay that passes the user's events to Send until Owner exits or
%% the relay is stopped. Returns once the relay is in the group, so nothing
%% broadcast after this returns is missed.
subscribe(User, Owner, Send) ->
    Caller = self(),
    Ready = make_ref(),
    Relay = spawn(fun() ->
        Watch = erlang:monitor(process, Owner),
        howdy_channel_ffi:channel_join(group(User), self()),
        Caller ! {Ready, self()},
        relay(Watch, Send)
    end),
    receive
        {Ready, Relay} -> Relay
    end.

relay(Watch, Send) ->
    receive
        {?TAG, Event} ->
            Send(Event),
            relay(Watch, Send);
        {'DOWN', Watch, process, _, _} ->
            ok;
        howdy_notifications_unsubscribe ->
            ok
    end.

unsubscribe(Relay) ->
    Relay ! howdy_notifications_unsubscribe,
    nil.

broadcast(User, Event) ->
    howdy_channel_ffi:channel_broadcast(group(User), ?TAG, Event).

subscribers(User) ->
    length(lists:usort(howdy_channel_ffi:channel_members(group(User)))).

%% The same, for subscribers on this node only: what `across_servers`
%% hears from PostgreSQL every node hears, so each passes it on to its own.
local_broadcast(User, Event) ->
    lists:foreach(
        fun(Pid) -> Pid ! {?TAG, Event} end,
        lists:usort(howdy_channel_ffi:channel_local_members(group(User)))
    ),
    nil.

local_subscribers(User) ->
    length(lists:usort(howdy_channel_ffi:channel_local_members(group(User)))).

%% The name the `across_servers` process is registered under, one per node.
fan_out_name() ->
    howdy_notifications_fan_out.

%% Run F, turning a crash into an error with a description, so one bad
%% notification cannot take the delivery worker down.
rescue(F) ->
    try F() of
        Value -> {ok, Value}
    catch
        Class:Reason ->
            {error, unicode:characters_to_binary(
                io_lib:format("~p: ~P", [Class, Reason, 20]))}
    end.
