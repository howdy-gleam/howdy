-module(howdy_templates_ffi).
-export([hash/1]).

%% Eight hex digits: enough to tell one generated module from another.
hash(Text) ->
    <<Hash:32>> = <<(erlang:phash2(Text, 4294967296)):32>>,
    list_to_binary(io_lib:format("~8.16.0b", [Hash])).
