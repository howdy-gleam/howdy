-module(howdy_admin_ffi).
-export([cells/1, cached_token/2, cache_token/3, forget_token/2]).

%% A database row as it came from the driver, as a list of optional strings.
%% pog rows are tuples and sqlight rows are lists; every value becomes text
%% so the admin can show any column without knowing its type.
cells(Row) when is_tuple(Row) -> cells(tuple_to_list(Row));
cells(Row) when is_list(Row) -> [cell(V) || V <- Row];
cells(Other) -> [cell(Other)].

cell(nil) -> none;
cell(null) -> none;
cell(undefined) -> none;
cell(true) -> {some, <<"true">>};
cell(false) -> {some, <<"false">>};
cell(V) when is_binary(V) -> {some, text(V)};
cell(V) when is_integer(V) -> {some, integer_to_binary(V)};
cell(V) when is_float(V) -> {some, float_to_binary(V, [short])};
cell(V) when is_atom(V) -> {some, atom_to_binary(V, utf8)};
cell({{Y, Mo, D}, {H, Mi, S}})
  when is_integer(Y), is_integer(Mo), is_integer(D),
       is_integer(H), is_integer(Mi) ->
    {some, iolist_to_binary([date(Y, Mo, D), " ", pad(H), ":", pad(Mi), ":", seconds(S)])};
cell({Y, Mo, D}) when is_integer(Y), is_integer(Mo), is_integer(D) ->
    {some, iolist_to_binary(date(Y, Mo, D))};
cell(V) ->
    {some, unicode:characters_to_binary(io_lib:format("~p", [V]))}.

text(B) ->
    case unicode:characters_to_binary(B, utf8, utf8) of
        B when byte_size(B) =/= 16 -> B;
        B -> maybe_uuid(B);
        _ when byte_size(B) =:= 16 -> uuid(B);
        _ -> <<"\\x", (binary:encode_hex(B))/binary>>
    end.

%% Sixteen valid UTF-8 bytes are almost always text, but a random UUID can
%% happen to be valid too; only treat it as a UUID when it is not printable.
maybe_uuid(B) ->
    case io_lib:printable_unicode_list(unicode:characters_to_list(B)) of
        true -> B;
        false -> uuid(B)
    end.

uuid(<<A:32, B:16, C:16, D:16, E:48>>) ->
    iolist_to_binary(io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [A, B, C, D, E])).

date(Y, Mo, D) -> [io_lib:format("~4..0b", [Y]), "-", pad(Mo), "-", pad(D)].

pad(N) -> io_lib:format("~2..0b", [N]).

seconds(S) when is_integer(S) -> pad(S);
seconds(S) when is_float(S) -> io_lib:format("~6.3.0f", [S]);
seconds(S) -> io_lib:format("~p", [S]).


%% Session tokens the API pages hold for the users they call as, so each
%% call does not open a new session. Development only, and rarely written,
%% which is what persistent_term suits. One map holds them all, keyed by
%% the Auth they were opened with as well as the user, so two auths never
%% hand out each other's tokens; it keeps the newest ?TOKEN_LIMIT, and an
%% entry goes when the admin revokes the user's sessions, deletes the user
%% or is told the token no longer works.
-define(TOKENS, howdy_admin_api_tokens).
-define(TOKEN_LIMIT, 32).

tokens() ->
    persistent_term:get(?TOKENS, #{}).

cached_token(Auth, UserId) ->
    case maps:find({Auth, UserId}, tokens()) of
        {ok, {_At, Token}} -> {ok, Token};
        error -> {error, nil}
    end.

cache_token(Auth, UserId, Token) ->
    Tokens = maps:remove({Auth, UserId}, tokens()),
    Trimmed = case map_size(Tokens) >= ?TOKEN_LIMIT of
        true -> drop_oldest(Tokens);
        false -> Tokens
    end,
    At = erlang:unique_integer([monotonic]),
    persistent_term:put(?TOKENS, Trimmed#{{Auth, UserId} => {At, Token}}),
    nil.

forget_token(Auth, UserId) ->
    Tokens = tokens(),
    case maps:is_key({Auth, UserId}, Tokens) of
        true -> persistent_term:put(?TOKENS, maps:remove({Auth, UserId}, Tokens));
        false -> ok
    end,
    nil.

drop_oldest(Tokens) ->
    {Oldest, _} = maps:fold(
        fun(Key, {At, _}, {_, Best}) when Best =:= undefined; At < Best -> {Key, At};
           (_, _, Acc) -> Acc
        end,
        {undefined, undefined},
        Tokens
    ),
    maps:remove(Oldest, Tokens).
