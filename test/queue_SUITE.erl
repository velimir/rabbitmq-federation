%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at https://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ Federation.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2017 Pivotal Software, Inc.  All rights reserved.
%%

-module(queue_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-compile(export_all).

-import(rabbit_federation_test_util,
        [expect/3, expect/4,
         set_upstream/4, set_upstream/5, clear_upstream/3, set_policy/5, clear_policy/3,
         set_policy_pattern/5, set_policy_upstream/5, set_policy_upstreams/4, q/1, with_ch/3,
         declare_queue/2, delete_queue/2]).

all() ->
    [
      {group, without_disambiguate},
      {group, with_disambiguate}
    ].

groups() ->
    [
      {without_disambiguate, [], [
          {cluster_size_1, [], [
              simple,
              multiple_upstreams,
              multiple_upstreams_pattern,
              multiple_downstreams,
              bidirectional,
              dynamic_reconfiguration,
              federate_unfederate,
              dynamic_plugin_stop_start
            ]}
        ]},
      {with_disambiguate, [], [
          {cluster_size_2, [], [
              restart_upstream
            ]}
        ]}
    ].

%% -------------------------------------------------------------------
%% Testsuite setup/teardown.
%% -------------------------------------------------------------------

init_per_suite(Config) ->
    rabbit_ct_helpers:log_environment(),
    rabbit_ct_helpers:run_setup_steps(Config).

end_per_suite(Config) ->
    rabbit_ct_helpers:run_teardown_steps(Config).

init_per_group(without_disambiguate, Config) ->
    rabbit_ct_helpers:set_config(Config,
      {disambiguate_step, []});
init_per_group(with_disambiguate, Config) ->
    rabbit_ct_helpers:set_config(Config,
      {disambiguate_step, [fun rabbit_federation_test_util:disambiguate/1]});
init_per_group(cluster_size_1 = Group, Config) ->
    Config1 = rabbit_ct_helpers:set_config(Config, [
        {rmq_nodes_count, 1}
      ]),
    init_per_group1(Group, Config1);
init_per_group(cluster_size_2 = Group, Config) ->
    Config1 = rabbit_ct_helpers:set_config(Config, [
        {rmq_nodes_count, 2}
      ]),
    init_per_group1(Group, Config1).

init_per_group1(Group, Config) ->
    SetupFederation = case Group of
        cluster_size_1 -> [fun rabbit_federation_test_util:setup_federation/1];
        cluster_size_2 -> []
    end,
    Disambiguate = ?config(disambiguate_step, Config),
    Suffix = rabbit_ct_helpers:testcase_absname(Config, "", "-"),
    Config1 = rabbit_ct_helpers:set_config(Config, [
        {rmq_nodename_suffix, Suffix},
        {rmq_nodes_clustered, false}
      ]),
    rabbit_ct_helpers:run_steps(Config1,
      rabbit_ct_broker_helpers:setup_steps() ++
      rabbit_ct_client_helpers:setup_steps() ++
      SetupFederation ++ Disambiguate).

end_per_group(without_disambiguate, Config) ->
    Config;
end_per_group(with_disambiguate, Config) ->
    Config;
end_per_group(_, Config) ->
    rabbit_ct_helpers:run_steps(Config,
      rabbit_ct_client_helpers:teardown_steps() ++
      rabbit_ct_broker_helpers:teardown_steps()).

init_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_started(Config, Testcase).

end_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_finished(Config, Testcase).

%% -------------------------------------------------------------------
%% Testcases.
%% -------------------------------------------------------------------

simple(Config) ->
    with_ch(Config,
      fun (Ch) ->
              expect_federation(Ch, <<"upstream">>, <<"fed.downstream">>)
      end, upstream_downstream()).

multiple_upstreams(Config) ->
    with_ch(Config,
      fun (Ch) ->
              expect_federation(Ch, <<"upstream">>, <<"fed12.downstream">>),
              expect_federation(Ch, <<"upstream2">>, <<"fed12.downstream">>)
      end, [q(<<"upstream">>),
            q(<<"upstream2">>),
            q(<<"fed12.downstream">>)]).

multiple_upstreams_pattern(Config) ->
    set_upstream(Config, 0, <<"local453x">>,
        rabbit_ct_broker_helpers:node_uri(Config, 0), [
        {<<"exchange">>, <<"upstream">>},
        {<<"queue">>, <<"upstream">>}]),

    set_upstream(Config, 0, <<"zzzzzZZzz">>,
        rabbit_ct_broker_helpers:node_uri(Config, 0), [
        {<<"exchange">>, <<"upstream-zzz">>},
        {<<"queue">>, <<"upstream-zzz">>}]),

    set_upstream(Config, 0, <<"local3214x">>,
        rabbit_ct_broker_helpers:node_uri(Config, 0), [
        {<<"exchange">>, <<"upstream2">>},
        {<<"queue">>, <<"upstream2">>}]),

    set_policy_pattern(Config, 0, <<"pattern">>, <<"^pattern\.">>, <<"local\\d+x">>),

    Timeout = 60000,
    with_ch(Config,
      fun (Ch) ->
              expect_federation(Ch, <<"upstream">>, <<"pattern.downstream">>, Timeout),
              expect_federation(Ch, <<"upstream2">>, <<"pattern.downstream">>, Timeout)
      end, [q(<<"upstream">>),
            q(<<"upstream2">>),
            q(<<"pattern.downstream">>)]),

    clear_upstream(Config, 0, <<"local453x">>),
    clear_upstream(Config, 0, <<"local3214x">>),
    clear_policy(Config, 0, <<"pattern">>).

multiple_downstreams(Config) ->
    with_ch(Config,
      fun (Ch) ->
              expect_federation(Ch, <<"upstream">>, <<"fed.downstream">>),
              expect_federation(Ch, <<"upstream">>, <<"fed.downstream2">>)
      end, upstream_downstream() ++ [q(<<"fed.downstream2">>)]).

bidirectional(Config) ->
    with_ch(Config,
      fun (Ch) ->
              publish_expect(Ch, <<>>, <<"one">>, <<"one">>, <<"first one">>),
              publish_expect(Ch, <<>>, <<"two">>, <<"two">>, <<"first two">>),
              Seq = lists:seq(1, 100),
              [publish(Ch, <<>>, <<"one">>, <<"bulk">>) || _ <- Seq],
              [publish(Ch, <<>>, <<"two">>, <<"bulk">>) || _ <- Seq],
              expect(Ch, <<"one">>, repeat(150, <<"bulk">>)),
              expect(Ch, <<"two">>, repeat(50, <<"bulk">>)),
              expect_empty(Ch, <<"one">>),
              expect_empty(Ch, <<"two">>)
      end, [q(<<"one">>),
            q(<<"two">>)]).

dynamic_reconfiguration(Config) ->
    with_ch(Config,
      fun (Ch) ->
              expect_federation(Ch, <<"upstream">>, <<"fed.downstream">>),

              %% Test that clearing connections works
              clear_upstream(Config, 0, <<"localhost">>),
              expect_no_federation(Ch, <<"upstream">>, <<"fed.downstream">>),

              %% Test that readding them and changing them works
              set_upstream(Config, 0,
                <<"localhost">>, rabbit_ct_broker_helpers:node_uri(Config, 0)),
              %% Do it twice so we at least hit the no-restart optimisation
              URI = rabbit_ct_broker_helpers:node_uri(Config, 0, [use_ipaddr]),
              set_upstream(Config, 0, <<"localhost">>, URI),
              set_upstream(Config, 0, <<"localhost">>, URI),
              expect_federation(Ch, <<"upstream">>, <<"fed.downstream">>)
      end, upstream_downstream()).

federate_unfederate(Config) ->
    with_ch(Config,
      fun (Ch) ->
              expect_no_federation(Ch, <<"upstream">>, <<"downstream">>),
              expect_no_federation(Ch, <<"upstream2">>, <<"downstream">>),

              %% Federate it
              set_policy(Config, 0, <<"dyn">>,
                <<"^downstream\$">>, <<"upstream">>),
              expect_federation(Ch, <<"upstream">>, <<"downstream">>),
              expect_no_federation(Ch, <<"upstream2">>, <<"downstream">>),

              %% Change policy - upstream changes
              set_policy(Config, 0, <<"dyn">>,
                <<"^downstream\$">>, <<"upstream2">>),
              expect_no_federation(Ch, <<"upstream">>, <<"downstream">>),
              expect_federation(Ch, <<"upstream2">>, <<"downstream">>),

              %% Unfederate it - no federation
              clear_policy(Config, 0, <<"dyn">>),
              expect_no_federation(Ch, <<"upstream2">>, <<"downstream">>)
      end, [q(<<"upstream">>),
            q(<<"upstream2">>),
            q(<<"downstream">>)]).

dynamic_plugin_stop_start(Config) ->
    Q1 = <<"dyn.q1">>,
    Q2 = <<"dyn.q2">>,
    U = <<"upstream">>,
    with_ch(Config,
      fun (Ch) ->
              set_policy(Config, 0, <<"dyn">>, <<"^dyn\\.">>, U),
              %% Declare federated queue - get link
              expect_federation(Ch, U, Q1),

              %% Disable plugin, link goes
              ok = rabbit_ct_broker_helpers:disable_plugin(Config, 0,
                "rabbitmq_federation"),
              expect_no_federation(Ch, U, Q1),

              %% Create exchange then re-enable plugin, links appear
              declare_queue(Ch, q(Q2)),
              ok = rabbit_ct_broker_helpers:enable_plugin(Config, 0,
                "rabbitmq_federation"),
              expect_federation(Ch, U, Q1),
              expect_federation(Ch, U, Q2),

              clear_policy(Config, 0, <<"dyn">>),
              expect_no_federation(Ch, U, Q1),
              expect_no_federation(Ch, U, Q2),
              delete_queue(Ch, Q2)
      end, [q(Q1), q(U)]).

restart_upstream(Config) ->
    [Rabbit, Hare] = rabbit_ct_broker_helpers:get_node_configs(Config,
      nodename),
    set_policy_upstream(Config, Rabbit, <<"^test$">>,
      rabbit_ct_broker_helpers:node_uri(Config, Hare), []),

    Downstream = rabbit_ct_client_helpers:open_channel(Config, Rabbit),
    Upstream   = rabbit_ct_client_helpers:open_channel(Config, Hare),

    declare_queue(Upstream, q(<<"test">>)),
    declare_queue(Downstream, q(<<"test">>)),
    Seq = lists:seq(1, 100),
    [publish(Upstream, <<>>, <<"test">>, <<"bulk">>) || _ <- Seq],
    expect(Upstream, <<"test">>, repeat(25, <<"bulk">>)),
    expect(Downstream, <<"test">>, repeat(25, <<"bulk">>)),

    rabbit_ct_client_helpers:close_channels_and_connection(Config, Hare),
    ok = rabbit_ct_broker_helpers:restart_node(Config, Hare),
    Upstream2 = rabbit_ct_client_helpers:open_channel(Config, Hare),

    expect(Upstream2, <<"test">>, repeat(25, <<"bulk">>)),
    expect(Downstream, <<"test">>, repeat(25, <<"bulk">>)),
    expect_empty(Upstream2, <<"test">>),
    expect_empty(Downstream, <<"test">>),

    ok.

%upstream_has_no_federation(Config) ->
%    %% TODO
%    ok.

%%----------------------------------------------------------------------------
repeat(Count, Item) -> [Item || _ <- lists:seq(1, Count)].

%%----------------------------------------------------------------------------

publish(Ch, X, Key, Payload) when is_binary(Payload) ->
    publish(Ch, X, Key, #amqp_msg{payload = Payload});

publish(Ch, X, Key, Msg = #amqp_msg{}) ->
    amqp_channel:call(Ch, #'basic.publish'{exchange    = X,
                                           routing_key = Key}, Msg).

publish_expect(Ch, X, Key, Q, Payload) ->
    publish(Ch, X, Key, Payload),
    expect(Ch, Q, [Payload]).

publish_expect(Ch, X, Key, Q, Payload, Timeout) ->
    publish(Ch, X, Key, Payload),
    expect(Ch, Q, [Payload], Timeout).

%% Doubled due to our strange basic.get behaviour.
expect_empty(Ch, Q) ->
    rabbit_federation_test_util:expect_empty(Ch, Q),
    rabbit_federation_test_util:expect_empty(Ch, Q).

expect_federation(Ch, UpstreamQ, DownstreamQ) ->
    publish_expect(Ch, <<>>, UpstreamQ, DownstreamQ, <<"HELLO">>).

expect_federation(Ch, UpstreamQ, DownstreamQ, Timeout) ->
    publish_expect(Ch, <<>>, UpstreamQ, DownstreamQ, <<"HELLO">>, Timeout).

expect_no_federation(Ch, UpstreamQ, DownstreamQ) ->
    publish(Ch, <<>>, UpstreamQ, <<"HELLO">>),
    expect_empty(Ch, DownstreamQ),
    expect(Ch, UpstreamQ, [<<"HELLO">>]).

upstream_downstream() ->
    [q(<<"upstream">>), q(<<"fed.downstream">>)].
