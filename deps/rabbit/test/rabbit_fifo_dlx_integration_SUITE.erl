-module(rabbit_fifo_dlx_integration_SUITE).

%% Integration tests for at-least-once dead-lettering comprising mainly
%% rabbit_fifo_dlx, rabbit_fifo_dlx_worker, rabbit_fifo_dlx_client
%% rabbit_quorum_queue, rabbit_fifo.

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("rabbitmq_ct_helpers/include/rabbit_assert.hrl").

-import(quorum_queue_utils, [wait_for_messages_ready/3,
                             dirty_query/3,
                             ra_name/1]).
-import(quorum_queue_SUITE, [publish/2,
                             consume/3]).

-compile([nowarn_export_all, export_all]).

all() ->
    [
     {group, single_node},
     {group, cluster_size_3}
    ].

groups() ->
    [
     {single_node, [], [
                        expired,
                        rejected,
                        delivery_limit,
                        target_queue_not_bound,
                        dlx_missing,
                        stats
                       ]},
     {cluster_size_3, [], [
                           many_target_queues
                          ]}
    ].

%% TODO add tests for:
%% * dlx_worker resends in various topology misconfigurations
%% * there is always single leader in 3 node cluster (check via supervisor:count_children and by killing one node)
%% * fall back to at-most-once works
%% * switching between at-most-once and at-least-once works including rabbit_fifo_dlx:cleanup

init_per_suite(Config0) ->
    rabbit_ct_helpers:log_environment(),
    Config1 = rabbit_ct_helpers:merge_app_env(
                Config0, {rabbit, [{quorum_tick_interval, 1000},
                                   {dead_letter_worker_consumer_prefetch, 2},
                                   {dead_letter_worker_publisher_confirm_timeout_ms, 1000}
                                  ]}),
    Config2 = rabbit_ct_helpers:merge_app_env(
                Config1, {aten, [{poll_interval, 1000}]}),
    rabbit_ct_helpers:run_setup_steps(Config2).

end_per_suite(Config) ->
    rabbit_ct_helpers:run_teardown_steps(Config).

init_per_group(single_node = Group, Config) ->
    init_per_group(Group, Config, 1);
init_per_group(cluster_size_3 = Group, Config) ->
    init_per_group(Group, Config, 3).

init_per_group(Group, Config, NodesCount) ->
    Config1 = rabbit_ct_helpers:set_config(Config,
                                           [{rmq_nodes_count, NodesCount},
                                            {rmq_nodename_suffix, Group},
                                            {tcp_ports_base},
                                            {net_ticktime, 10}]),
    Config2 =  rabbit_ct_helpers:run_steps(Config1,
                                           [fun merge_app_env/1 ] ++
                                           rabbit_ct_broker_helpers:setup_steps()),
    ok = rabbit_ct_broker_helpers:rpc(
           Config2, 0, application, set_env,
           [rabbit, channel_tick_interval, 100]),
    timer:sleep(1000),
    Config2.

end_per_group(_, Config) ->
    rabbit_ct_helpers:run_steps(Config,
                                rabbit_ct_broker_helpers:teardown_steps()).

merge_app_env(Config) ->
    rabbit_ct_helpers:merge_app_env(
      rabbit_ct_helpers:merge_app_env(Config,
                                      {rabbit, [{core_metrics_gc_interval, 100}]}),
      {ra, [{min_wal_roll_over_interval, 30000}]}).

init_per_testcase(Testcase, Config) ->
    Config1 = rabbit_ct_helpers:testcase_started(Config, Testcase),
    Q = rabbit_data_coercion:to_binary(Testcase),
    Config2 = rabbit_ct_helpers:set_config(Config1,
                                           [{source_queue, <<Q/binary, "_source">>},
                                            {dead_letter_exchange, <<Q/binary, "_dlx">>},
                                            {target_queue_1, <<Q/binary, "_target_1">>},
                                            {target_queue_2, <<Q/binary, "_target_2">>},
                                            {target_queue_3, <<Q/binary, "_target_3">>}
                                           ]),
    rabbit_ct_helpers:run_steps(Config2, rabbit_ct_client_helpers:setup_steps()).

end_per_testcase(Testcase, Config) ->
    Server = rabbit_ct_broker_helpers:get_node_config(Config, 0, nodename),
    Ch = rabbit_ct_client_helpers:open_channel(Config, Server),
    #'queue.delete_ok'{message_count = 0} = amqp_channel:call(Ch, #'queue.delete'{queue = ?config(source_queue, Config)}),
    #'queue.delete_ok'{} = amqp_channel:call(Ch, #'queue.delete'{queue = ?config(target_queue_1, Config)}),
    #'queue.delete_ok'{} = amqp_channel:call(Ch, #'queue.delete'{queue = ?config(target_queue_2, Config)}),
    #'queue.delete_ok'{} = amqp_channel:call(Ch, #'queue.delete'{queue = ?config(target_queue_3, Config)}),
    #'exchange.delete_ok'{} = amqp_channel:call(Ch, #'exchange.delete'{exchange = ?config(dead_letter_exchange, Config)}),
    Config1 = rabbit_ct_helpers:run_steps(
                Config,
                rabbit_ct_client_helpers:teardown_steps()),
    rabbit_ct_helpers:testcase_finished(Config1, Testcase).

declare_topology(Config, AdditionalQArgs) ->
    Server = rabbit_ct_broker_helpers:get_node_config(Config, 0, nodename),
    Ch = rabbit_ct_client_helpers:open_channel(Config, Server),
    SourceQ = ?config(source_queue, Config),
    TargetQ = ?config(target_queue_1, Config),
    DLX = ?config(dead_letter_exchange, Config),
    QArgs = [
             {<<"x-dead-letter-exchange">>, longstr, DLX},
             {<<"x-dead-letter-routing-key">>, longstr, <<"k1">>},
             {<<"x-dead-letter-strategy">>, longstr, <<"at-least-once">>},
             {<<"x-overflow">>, longstr, <<"reject-publish">>},
             {<<"x-queue-type">>, longstr, <<"quorum">>}
            ],
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{
                                                     queue     = SourceQ,
                                                     durable   = true,
                                                     arguments = lists:keymerge(1, AdditionalQArgs, QArgs)}),
    #'exchange.declare_ok'{} = amqp_channel:call(Ch, #'exchange.declare'{exchange = DLX}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = TargetQ}),
    #'queue.bind_ok'{} = amqp_channel:call(Ch, #'queue.bind'{
                                                  queue = TargetQ,
                                                  exchange = DLX,
                                                  routing_key = <<"k1">>
                                                 }),
    {Server, Ch, SourceQ, TargetQ}.

%% Test that at-least-once dead-lettering works for message dead-lettered due to message TTL.
expired(Config) ->
    {_Server, Ch, SourceQ, TargetQ} = declare_topology(Config, []),
    Msg = <<"msg">>,
    ok = amqp_channel:cast(Ch,
                           #'basic.publish'{routing_key = SourceQ},
                           #amqp_msg{props   = #'P_basic'{expiration = <<"0">>},
                                     payload = Msg}),
    {_, #amqp_msg{props = #'P_basic'{headers = Headers,
                                     expiration = undefined}}} =
    ?awaitMatch({#'basic.get_ok'{}, #amqp_msg{payload = Msg}},
                amqp_channel:call(Ch, #'basic.get'{queue = TargetQ}),
                1000),
    assert_dlx_headers(Headers, <<"expired">>, SourceQ).

%% Test that at-least-once dead-lettering works for message dead-lettered due to rejected by consumer.
rejected(Config) ->
    {Server, Ch, SourceQ, TargetQ} = declare_topology(Config, []),
    publish(Ch, SourceQ),
    wait_for_messages_ready([Server], ra_name(SourceQ), 1),
    DelTag = consume(Ch, SourceQ, false),
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DelTag,
                                        multiple     = false,
                                        requeue      = false}),
    {_, #amqp_msg{props = #'P_basic'{headers = Headers}}} =
    ?awaitMatch({#'basic.get_ok'{}, #amqp_msg{payload = <<"msg">>}},
                amqp_channel:call(Ch, #'basic.get'{queue = TargetQ}),
                1000),
    assert_dlx_headers(Headers, <<"rejected">>, SourceQ).

%% Test that at-least-once dead-lettering works for message dead-lettered due to delivery-limit exceeded.
delivery_limit(Config) ->
    {Server, Ch, SourceQ, TargetQ} = declare_topology(Config, [{<<"x-delivery-limit">>, long, 0}]),
    publish(Ch, SourceQ),
    wait_for_messages_ready([Server], ra_name(SourceQ), 1),
    DelTag = consume(Ch, SourceQ, false),
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DelTag,
                                        multiple     = false,
                                        requeue      = true}),
    {_, #amqp_msg{props = #'P_basic'{headers = Headers}}} =
    ?awaitMatch({#'basic.get_ok'{}, #amqp_msg{payload = <<"msg">>}},
                amqp_channel:call(Ch, #'basic.get'{queue = TargetQ}),
                1000),
    assert_dlx_headers(Headers, <<"delivery_limit">>, SourceQ).

assert_dlx_headers(Headers, Reason, SourceQ) ->
    ?assertEqual({longstr, Reason}, rabbit_misc:table_lookup(Headers, <<"x-first-death-reason">>)),
    ?assertEqual({longstr, SourceQ}, rabbit_misc:table_lookup(Headers, <<"x-first-death-queue">>)),
    ?assertEqual({longstr, <<>>}, rabbit_misc:table_lookup(Headers, <<"x-first-death-exchange">>)),
    {array, [{table, Death}]} = rabbit_misc:table_lookup(Headers, <<"x-death">>),
    ?assertEqual({longstr, SourceQ}, rabbit_misc:table_lookup(Death, <<"queue">>)),
    ?assertEqual({longstr, Reason}, rabbit_misc:table_lookup(Death, <<"reason">>)),
    ?assertEqual({longstr, <<>>}, rabbit_misc:table_lookup(Death, <<"exchange">>)),
    ?assertEqual({long, 1}, rabbit_misc:table_lookup(Death, <<"count">>)),
    ?assertEqual({array, [{longstr, SourceQ}]}, rabbit_misc:table_lookup(Death, <<"routing-keys">>)),
    case Reason of
        <<"expired">> ->
            ?assertEqual({longstr, <<"0">>}, rabbit_misc:table_lookup(Death, <<"original-expiration">>));
        _ ->
            ok
    end.

%% Test that message is not lost despite no route from dead-letter exchange to target queue.
%% Once, the route becomes available, the message is delivered to the target queue
%% and acked to the source quorum queue.
target_queue_not_bound(Config) ->
    Server = rabbit_ct_broker_helpers:get_node_config(Config, 0, nodename),
    Ch = rabbit_ct_client_helpers:open_channel(Config, Server),
    SourceQ = ?config(source_queue, Config),
    TargetQ = ?config(target_queue_1, Config),
    DLX = <<"dead-ex">>,
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{
                                                     queue     = SourceQ,
                                                     durable   = true,
                                                     arguments = [
                                                                  {<<"x-dead-letter-exchange">>, longstr, DLX},
                                                                  {<<"x-dead-letter-routing-key">>, longstr, <<"k1">>},
                                                                  {<<"x-dead-letter-strategy">>, longstr, <<"at-least-once">>},
                                                                  {<<"x-overflow">>, longstr, <<"reject-publish">>},
                                                                  {<<"x-queue-type">>, longstr, <<"quorum">>}
                                                                 ]
                                                    }),
    #'exchange.declare_ok'{} = amqp_channel:call(Ch, #'exchange.declare'{exchange = DLX}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = TargetQ}),
    Msg = <<"msg">>,
    ok = amqp_channel:cast(Ch,
                           #'basic.publish'{routing_key = SourceQ},
                           #amqp_msg{props   = #'P_basic'{expiration = <<"0">>},
                                     payload = Msg}),
    RaName = ra_name(SourceQ),
    %% Binding from target queue to DLX is missing.
    %% Therefore, 1 message should be kept in discards queue.
    eventually(?_assertMatch([{1, _}],
                             dirty_query([Server], RaName, fun rabbit_fifo:query_stat_dlx/1))),
    consistently(?_assertMatch([{1, _}],
                               dirty_query([Server], RaName, fun rabbit_fifo:query_stat_dlx/1))),
    %% Fix dead-letter toplology misconfiguration.
    #'queue.bind_ok'{} = amqp_channel:call(Ch, #'queue.bind'{
                                                  queue = TargetQ,
                                                  exchange = DLX,
                                                  routing_key = <<"k1">>
                                                 }),
    %% Binding from target queue to DLX is now present.
    %% Therefore, message should be delivered to target queue and acked to source queue.
    eventually(?_assertEqual([{0, 0}],
                             dirty_query([Server], RaName, fun rabbit_fifo:query_stat_dlx/1)),
               500, 10),
    ?assertMatch({#'basic.get_ok'{}, #amqp_msg{props = #'P_basic'{expiration = undefined},
                                               payload = Msg}},
                 amqp_channel:call(Ch, #'basic.get'{queue = TargetQ})).

%% Test that message is not lost when configured dead-letter exchange does not exist.
%% Once, the exchange gets declared, the message is delivered to the target queue
%% and acked to the source quorum queue.
dlx_missing(Config) ->
    Server = rabbit_ct_broker_helpers:get_node_config(Config, 0, nodename),
    Ch = rabbit_ct_client_helpers:open_channel(Config, Server),
    SourceQ = ?config(source_queue, Config),
    TargetQ = ?config(target_queue_1, Config),
    DLX = <<"dead-ex">>,
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{
                                                     queue     = SourceQ,
                                                     durable   = true,
                                                     arguments = [
                                                                  {<<"x-dead-letter-exchange">>, longstr, DLX},
                                                                  {<<"x-dead-letter-routing-key">>, longstr, <<"k1">>},
                                                                  {<<"x-dead-letter-strategy">>, longstr, <<"at-least-once">>},
                                                                  {<<"x-overflow">>, longstr, <<"reject-publish">>},
                                                                  {<<"x-queue-type">>, longstr, <<"quorum">>}
                                                                 ]
                                                    }),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = TargetQ}),
    Msg = <<"msg">>,
    ok = amqp_channel:cast(Ch,
                           #'basic.publish'{routing_key = SourceQ},
                           #amqp_msg{props   = #'P_basic'{expiration = <<"0">>},
                                     payload = Msg}),
    RaName = ra_name(SourceQ),
    %% DLX is missing. Therefore, 1 message should be kept in discards queue.
    eventually(?_assertMatch([{1, _}],
                             dirty_query([Server], RaName, fun rabbit_fifo:query_stat_dlx/1))),
    consistently(?_assertMatch([{1, _}],
                               dirty_query([Server], RaName, fun rabbit_fifo:query_stat_dlx/1))),
    %% Fix dead-letter toplology misconfiguration.
    #'exchange.declare_ok'{} = amqp_channel:call(Ch, #'exchange.declare'{exchange = DLX}),
    #'queue.bind_ok'{} = amqp_channel:call(Ch, #'queue.bind'{
                                                  queue = TargetQ,
                                                  exchange = DLX,
                                                  routing_key = <<"k1">>
                                                 }),
    %% DLX is now present.
    %% Therefore, message should be delivered to target queue and acked to source queue.
    eventually(?_assertEqual([{0, 0}],
                             dirty_query([Server], RaName, fun rabbit_fifo:query_stat_dlx/1)),
               500, 10),
    ?assertMatch({#'basic.get_ok'{}, #amqp_msg{props = #'P_basic'{expiration = undefined},
                                               payload = Msg}},
                 amqp_channel:call(Ch, #'basic.get'{queue = TargetQ})).


%% Test that rabbit_fifo_dlx tracks statistics correctly.
stats(Config) ->
    Server = rabbit_ct_broker_helpers:get_node_config(Config, 0, nodename),
    Ch = rabbit_ct_client_helpers:open_channel(Config, Server),
    SourceQ = ?config(source_queue, Config),
    TargetQ = ?config(target_queue_1, Config),
    DLX = <<"dead-ex">>,
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{
                                                     queue     = SourceQ,
                                                     durable   = true,
                                                     arguments = [
                                                                  {<<"x-dead-letter-exchange">>, longstr, DLX},
                                                                  {<<"x-dead-letter-routing-key">>, longstr, <<"k1">>},
                                                                  {<<"x-dead-letter-strategy">>, longstr, <<"at-least-once">>},
                                                                  {<<"x-max-in-memory-length">>, long, 1},
                                                                  {<<"x-overflow">>, longstr, <<"reject-publish">>},
                                                                  {<<"x-queue-type">>, longstr, <<"quorum">>}
                                                                 ]
                                                    }),
    #'exchange.declare_ok'{} = amqp_channel:call(Ch, #'exchange.declare'{exchange = DLX}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = TargetQ}),
    Msg = <<"12">>, %% 2 bytes per message
    [ok = amqp_channel:cast(Ch,
                            #'basic.publish'{routing_key = SourceQ},
                            #amqp_msg{props   = #'P_basic'{expiration = <<"0">>},
                                      payload = Msg})
     || _ <- lists:seq(1, 10)], %% 10 messages in total
    RaName = ra_name(SourceQ),
    %% Binding from target queue to DLX is missing. Therefore
    %% * 10 msgs should be discarded (i.e. in discards queue or checked out to dlx_worker)
    %% * 20 bytes (=10msgs*2bytes) should be discarded (i.e. in discards queue or checked out to dlx_worker)
    eventually(?_assertEqual([{10, 20}],
                             dirty_query([Server], RaName, fun rabbit_fifo:query_stat_dlx/1))),
    ?assertMatch([#{
                    %% 2 msgs (=Prefetch) should be checked out to dlx_worker
                    num_discard_checked_out := 2,
                    %% 4 bytes (=2msgs*2bytes) should be checked out to dlx_worker
                    discard_checkout_message_bytes := 4,
                    %% 8 msgs (=10-2) should be in discards queue
                    num_discarded := 8,
                    %% 16 bytes (=8msgs*2bytes) should be in discards queue
                    discard_message_bytes := 16,
                    %% 10 msgs in total
                    num_messages := 10,
                    %% 1 msg (=x-max-in-memory-length) should be in-memory
                    num_in_memory_ready_messages := 1,
                    %% 2 bytes (1msg) should be in-memory
                    in_memory_message_bytes := 2
                   }],
                 dirty_query([Server], RaName, fun rabbit_fifo:overview/1)),
    %% Fix dead-letter toplology misconfiguration.
    #'queue.bind_ok'{} = amqp_channel:call(Ch, #'queue.bind'{
                                                  queue = TargetQ,
                                                  exchange = DLX,
                                                  routing_key = <<"k1">>
                                                 }),
    %% Binding from target queue to DLX is now present.
    %% Therefore, all messages should be delivered to target queue and acked to source queue.
    %% Therefore, all stats should be decremented back to 0.
    eventually(?_assertEqual([{0, 0}],
                             dirty_query([Server], RaName, fun rabbit_fifo:query_stat_dlx/1)),
               500, 10),
    ?assertMatch([#{
                    num_discard_checked_out := 0,
                    discard_checkout_message_bytes := 0,
                    num_discarded := 0,
                    discard_message_bytes := 0,
                    num_messages := 0,
                    num_in_memory_ready_messages := 0,
                    in_memory_message_bytes := 0
                   }],
                 dirty_query([Server], RaName, fun rabbit_fifo:overview/1)),
    [?assertMatch({#'basic.get_ok'{}, #amqp_msg{props = #'P_basic'{expiration = undefined},
                                                payload = Msg}},
                  amqp_channel:call(Ch, #'basic.get'{queue = TargetQ})) || _ <- lists:seq(1, 10)].

%% Test that
%% 1. Message is only acked to source queue once publisher confirms got received from **all** target queues.
%% 2. Target queue can be classic queue, quorum queue, or stream queue.
%%
%% Lesson learnt by writing this test:
%% If there are multiple target queues, messages will not be sent to target non-mirrored classic queues
%% it their host node is temporarily down because these queues get (temporarily) deleted. See:
%% https://github.com/rabbitmq/rabbitmq-server/blob/cf76b479300b767b8ea450293d096cbf729ed734/deps/rabbit/src/rabbit_amqqueue.erl#L1955-L1964
many_target_queues(Config) ->
    [Server1, Server2, Server3] = rabbit_ct_broker_helpers:get_node_configs(Config, nodename),
    Ch = rabbit_ct_client_helpers:open_channel(Config, Server1),
    SourceQ = ?config(source_queue, Config),
    RaName = ra_name(SourceQ),
    TargetQ1 = ?config(target_queue_1, Config),
    TargetQ2 = ?config(target_queue_2, Config),
    TargetQ3 = ?config(target_queue_3, Config),
    DLX = ?config(dead_letter_exchange, Config),
    DLRKey = <<"k1">>,
    %% Create topology:
    %% * source quorum queue with 1 replica on node 1
    %% * target non-mirrored classic queue on node 1
    %% * target quorum queue with 3 replicas
    %% * target stream queue with 3 replicas
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{
                                                     queue     = SourceQ,
                                                     durable   = true,
                                                     arguments = [
                                                                  {<<"x-dead-letter-exchange">>, longstr, DLX},
                                                                  {<<"x-dead-letter-routing-key">>, longstr, DLRKey},
                                                                  {<<"x-dead-letter-strategy">>, longstr, <<"at-least-once">>},
                                                                  {<<"x-overflow">>, longstr, <<"reject-publish">>},
                                                                  {<<"x-queue-type">>, longstr, <<"quorum">>},
                                                                  {<<"x-quorum-initial-group-size">>, long, 1}
                                                                 ]
                                                    }),
    #'exchange.declare_ok'{} = amqp_channel:call(Ch, #'exchange.declare'{exchange = DLX}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = TargetQ1}),
    #'queue.bind_ok'{} = amqp_channel:call(Ch, #'queue.bind'{
                                                  queue = TargetQ1,
                                                  exchange = DLX,
                                                  routing_key = DLRKey
                                                 }),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{
                                                     queue     = TargetQ2,
                                                     durable   = true,
                                                     arguments = [
                                                                  {<<"x-queue-type">>, longstr, <<"quorum">>},
                                                                  {<<"x-quorum-initial-group-size">>, long, 3}
                                                                 ]
                                                    }),
    #'queue.bind_ok'{} = amqp_channel:call(Ch, #'queue.bind'{
                                                  queue = TargetQ2,
                                                  exchange = DLX,
                                                  routing_key = DLRKey
                                                 }),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{
                                                     queue     = TargetQ3,
                                                     durable   = true,
                                                     arguments = [
                                                                  {<<"x-queue-type">>, longstr, <<"stream">>},
                                                                  {<<"x-initial-cluster-size">>, long, 3}
                                                                 ]
                                                    }),
    #'queue.bind_ok'{} = amqp_channel:call(Ch, #'queue.bind'{
                                                  queue = TargetQ3,
                                                  exchange = DLX,
                                                  routing_key = DLRKey
                                                 }),
    Msg1 = <<"m1">>,
    ok = amqp_channel:cast(Ch,
                           #'basic.publish'{routing_key = SourceQ},
                           #amqp_msg{props   = #'P_basic'{expiration = <<"5">>},
                                     payload = Msg1}),
    eventually(?_assertMatch({#'basic.get_ok'{}, #amqp_msg{payload = Msg1}},
                             amqp_channel:call(Ch, #'basic.get'{queue = TargetQ1}))),
    eventually(?_assertMatch({#'basic.get_ok'{}, #amqp_msg{payload = Msg1}},
                             amqp_channel:call(Ch, #'basic.get'{queue = TargetQ2}))),
    %% basic.get not supported by stream queues
    #'basic.qos_ok'{} = amqp_channel:call(Ch, #'basic.qos'{prefetch_count = 2}),
    CTag = <<"ctag">>,
    amqp_channel:subscribe(
      Ch,
      #'basic.consume'{queue = TargetQ3,
                       consumer_tag = CTag,
                       arguments = [{<<"x-stream-offset">>, long, 0}]},
      self()),
    receive
        #'basic.consume_ok'{consumer_tag = CTag} ->
            ok
    after 2000 ->
              exit(consume_ok_timeout)
    end,
    receive
        {#'basic.deliver'{consumer_tag = CTag},
         #amqp_msg{payload = Msg1}} ->
            ok
    after 2000 ->
              exit(deliver_timeout)
    end,
    eventually(?_assertEqual([{0, 0}],
                             dirty_query([Server1], RaName, fun rabbit_fifo:query_stat_dlx/1))),
    ok = rabbit_ct_broker_helpers:kill_node(Config, Server3),
    ok = rabbit_ct_broker_helpers:kill_node(Config, Server2),
    Msg2 = <<"m2">>,
    ok = amqp_channel:cast(Ch,
                           #'basic.publish'{routing_key = SourceQ},
                           #amqp_msg{props   = #'P_basic'{expiration = <<"1">>},
                                     payload = Msg2}),
    %% Nodes 2 and 3 are down.
    %% rabbit_fifo_dlx_worker should wait until all queues confirm the message
    %% before acking it to the source queue.
    eventually(?_assertEqual([{1, 2}],
                             dirty_query([Server1], RaName, fun rabbit_fifo:query_stat_dlx/1))),
    consistently(?_assertEqual([{1, 2}],
                               dirty_query([Server1], RaName, fun rabbit_fifo:query_stat_dlx/1))),
    ?assertMatch({#'basic.get_ok'{}, #amqp_msg{payload = Msg2}},
                 amqp_channel:call(Ch, #'basic.get'{queue = TargetQ1})),
    ok = rabbit_ct_broker_helpers:start_node(Config, Server2),
    ok = rabbit_ct_broker_helpers:start_node(Config, Server3),
    eventually(?_assertEqual([{0, 0}],
                             dirty_query([Server1], RaName, fun rabbit_fifo:query_stat_dlx/1)), 500, 6),
    ?assertMatch({#'basic.get_ok'{}, #amqp_msg{payload = Msg2}},
                 amqp_channel:call(Ch, #'basic.get'{queue = TargetQ2})),
    receive
        {#'basic.deliver'{consumer_tag = CTag},
         #amqp_msg{payload = Msg2}} ->
            ok
    after 0 ->
              exit(deliver_timeout)
    end.
    %%TODO By end of this test, there will be many duplicate dead-letter messages in the target quorum queue and
    %% target stream queue since both their queue clients and rabbit_fifo_dlx_worker re-try.
    %% Possible solution is to have rabbit_fifo_dlx_worker only resend for classic target queues?

%%TODO move to rabbitmq_ct_helpers/include/rabbit_assert.hrl
consistently(TestObj) ->
    consistently(TestObj, 200, 5).

consistently(_, _, 0) ->
    ok;
consistently({_Line, Assertion} = TestObj, PollInterval, PollCount) ->
    Assertion(),
    timer:sleep(PollInterval),
    consistently(TestObj, PollInterval, PollCount - 1).

eventually(TestObj) ->
    eventually(TestObj, 200, 5).

eventually({Line, _}, _, 0) ->
    erlang:error({assert_timeout,
                  [{file, ?FILE},
                   {line, ?LINE},
                   {assertion_line, Line}
                  ]});
eventually({Line, Assertion} = TestObj, PollInterval, PollCount) ->
    case catch Assertion() of
        ok ->
            ok;
        Err ->
            ct:pal(?LOW_IMPORTANCE,
                   "Retrying in ~b ms for ~b more times in file ~s, line ~b due to failed assertion in line ~b: ~p",
                   [PollInterval, PollCount - 1, ?FILE, ?LINE, Line, Err]),
            timer:sleep(PollInterval),
            eventually(TestObj, PollInterval, PollCount - 1)
    end.
