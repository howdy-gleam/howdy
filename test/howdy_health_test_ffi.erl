-module(howdy_health_test_ffi).
-export([mailbox_size/0]).

mailbox_size() ->
    {message_queue_len, Size} = erlang:process_info(self(), message_queue_len),
    Size.
