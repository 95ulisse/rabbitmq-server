
-module(rabbit_fifo_dlx_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-export([
         ]).

% -include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("rabbit/src/rabbit_fifo.hrl").
-include_lib("rabbit/src/rabbit_fifo_dlx.hrl").

%%%===================================================================
%%% Common Test callbacks
%%%===================================================================

all() ->
    [
     {group, tests}
    ].


all_tests() ->
    [
     discard_no_dlx_consumer
    ].

groups() ->
    [
     {tests, [], all_tests()}
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%%===================================================================
%%% Test cases
%%%===================================================================

discard_no_dlx_consumer(_Config) ->
    S0 = rabbit_fifo_dlx:init(),
    ?assertMatch(#{num_discarded := 0}, rabbit_fifo_dlx:overview(S0)),
    S1 = rabbit_fifo_dlx:discard(make_msg(1), because, S0),
    ?assertMatch(#{num_discarded := 1}, rabbit_fifo_dlx:overview(S1)),
    ok.


make_msg(RaftIdx) ->
    ?INDEX_MSG(RaftIdx, ?DISK_MSG(1)).
