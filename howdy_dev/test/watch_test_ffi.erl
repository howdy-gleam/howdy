-module(watch_test_ffi).
-export([mtime_seconds/1, set_mtime_seconds/2]).
-include_lib("kernel/include/file.hrl").

%% Whole seconds, matching what simplifile reports.
mtime_seconds(Path) ->
    {ok, #file_info{mtime = Mtime}} = file:read_file_info(Path, [{time, posix}]),
    Mtime.

set_mtime_seconds(Path, Seconds) ->
    ok = file:write_file_info(Path, #file_info{mtime = Seconds, atime = Seconds},
                              [{time, posix}]),
    nil.
