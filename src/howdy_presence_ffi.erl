%% Helpers for howdy/websocket/presence that are not the tracker itself.
-module(howdy_presence_ffi).
-export([diff_parts/1, client_source/0]).

diff_parts({howdy_presence_diff, _Name, _Topic, Joins, Leaves}) ->
    {Joins, Leaves}.

-define(SOURCE, {howdy, presence_client}).

%% The client script from this package's priv directory and its ETag, read
%% once and kept in memory.
client_source() ->
    case persistent_term:get(?SOURCE, undefined) of
        undefined ->
            Path = filename:join(code:priv_dir(howdy), "presence.js"),
            case file:read_file(Path) of
                {ok, Source} ->
                    Digest = binary:encode_hex(crypto:hash(sha256, Source), lowercase),
                    Loaded = {Source, <<"\"", (binary:part(Digest, 0, 16))/binary, "\"">>},
                    persistent_term:put(?SOURCE, Loaded),
                    Loaded;
                {error, Reason} ->
                    erlang:error({howdy_presence_client_missing, Path, Reason})
            end;
        Loaded ->
            Loaded
    end.
