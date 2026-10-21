%% Tests decode with gen_smtp's mimemail, which converts charsets with the
%% iconv NIF. Everything howdy/mail writes is UTF-8, so passing the bytes
%% through stands in for it.
-module(iconv).
-export([convert/3]).

convert(From, _To, Data) ->
    case string:lowercase(From) of
        <<"utf-8">> -> Data;
        <<"us-ascii">> -> Data;
        Other -> erlang:error({unexpected_charset, Other})
    end.
