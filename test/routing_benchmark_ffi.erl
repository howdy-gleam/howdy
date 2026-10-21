-module(routing_benchmark_ffi).
-export([measure/3, run/3]).

measure(Label, Request, Cases) ->
    Count = Cases * 2000,
    run(Request, Cases * 20, Cases),
    Samples = [begin
        erlang:garbage_collect(),
        {Us, _} = timer:tc(?MODULE, run, [Request, Count, Cases]),
        Us
    end || _ <- lists:seq(1, 5)],
    Us = lists:nth(3, lists:sort(Samples)),
    %% Measure allocation separately: tracing must not affect throughput.
    Session = trace:session_create(routing_benchmark, undefined, []),
    Words = try
        1 = trace:function(Session, {?MODULE, run, 3}, true, [call_memory]),
        1 = trace:process(Session, self(), true, [call]),
        run(Request, Count, Cases),
        trace:function(Session, {?MODULE, run, 3}, pause, [call_memory]),
        {call_memory, Entries} = trace:info(Session, {?MODULE, run, 3}, call_memory),
        lists:sum([W || {_, _, W} <- Entries])
    after trace:session_destroy(Session)
    end,
    io:format("~s controllers: ~.1f requests/s, ~.2f us/request, ~.1f heap words/request (~.1f bytes)~n",
        [Label, Count * 1000000 / Us, Us / Count, Words / Count,
         Words * erlang:system_info(wordsize) / Count]),
    nil.

run(_, 0, _) -> ok;
run(Request, Remaining, Cases) ->
    Status = Request((Remaining - 1) rem Cases),
    true = is_integer(Status),
    run(Request, Remaining - 1, Cases).
