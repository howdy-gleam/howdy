-module(howdy_openapi_ffi).
-export([wrap/2, unwrap/2]).

%% Routes carry annotations as Dynamic. howdy/openapi tags what it stores
%% with the key it is stored under, so a value is only ever read back as the
%% type that key holds. See howdy/openapi/internal/annotation.
wrap(Key, Value) -> {howdy_openapi_annotation, Key, Value}.

unwrap({howdy_openapi_annotation, Key, Value}, Key) -> {ok, Value};
unwrap(_, _) -> {error, nil}.
