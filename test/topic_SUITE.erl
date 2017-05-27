-module(topic_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile(export_all).

all() ->
    [creation, write, index_bug].

init_per_suite(Config) ->
    PrivDir = ?config(priv_dir, Config),
    lager:start(),
    %% clear env from other suites
    application:unload(vonnegut),
    application:load(vonnegut),
    application:load(partisan),
    application:set_env(partisan, partisan_peer_service_manager, partisan_default_peer_service_manager),
    application:set_env(vonnegut, log_dirs, [filename:join(PrivDir, "data")]),
    application:set_env(vonnegut, chain, [{discovery, local}]),
    application:set_env(vonnegut, client, [{endpoints, [{"127.0.0.1", 5555}]}]),
    {ok, _} = application:ensure_all_started(vonnegut),
    Config.

end_per_suite(Config) ->
    application:stop(vonnegut),
    Config.

init_per_testcase(_, Config) ->
    ok = vg_client_pool:start(),
    Topic = vg_test_utils:create_random_name(<<"topic_SUITE_default_topic">>),
    vg:create_topic(Topic),
    [{topic, Topic} | Config].

end_per_testcase(_, Config) ->
    vg_client_pool:stop(),
    Config.


creation(_Config) ->
    Topic = vg_test_utils:create_random_name(<<"creation_test_topic">>),
    Partition = 0,
    TopicPartitionDir = vg_utils:topic_dir(Topic, Partition),
    vg:create_topic(Topic),
    ?assert(filelib:is_dir(TopicPartitionDir)).

write(Config) ->
    Topic = ?config(topic, Config),
    Anarchist = <<"no gods no masters">>,
    [begin
         {ok, R} = vg_client:produce(Topic, Anarchist),
         ct:pal("reply: ~p", [R])
     end
     || _ <- lists:seq(1, rand:uniform(20))],
    Communist =  <<"from each according to their abilities, to "
                   "each according to their needs">>,
    {ok, R1} = vg_client:produce(Topic, Communist),
    ct:pal("reply: ~p", [R1]),
    {ok, #{record_set := Reply}} = vg_client:fetch(Topic, R1),
    ?assertMatch([#{record := Communist}], Reply),

    {ok, #{record_set := Reply1}} = vg_client:fetch(Topic, R1 - 1),
    ?assertMatch([#{record := Anarchist}, #{record := Communist}], Reply1).

index_bug(Config) ->
    Topic = ?config(topic, Config),

    %% write enough data to cause index creation but not two entries
    {ok, _}  = vg_client:produce(Topic,
                                 lists:duplicate(100, <<"123456789abcdef">>)),

    %% fetch from 0 to make sure that they're all there
    {ok, #{record_set := Reply}} = vg_client:fetch(Topic, 0),
    ?assertEqual(100, length(Reply)),

    %% now query for something before the first index marker
    {ok, #{record_set := Reply2,
           high_water_mark := HWM}} = vg_client:fetch(Topic, 10),

    ?assertEqual(99, HWM),

    %% this is a passing version before the bugfix
    %% ?assertEqual([], Reply2).

    ?assertEqual(90, length(Reply2)),

    %% write enough more data for another entry to hit the second clause
    {ok, _}  = vg_client:produce(Topic,
                                 lists:duplicate(100, <<"123456789abcdef">>)),

    {ok, #{record_set := Reply3}} = vg_client:fetch(Topic, 0),
    ?assertEqual(200, length(Reply3)),

    {ok, #{record_set := Reply4,
           high_water_mark := HWM4}} = vg_client:fetch(Topic, 10),

    ?assertEqual(199, HWM4),
    ?assertEqual(190, length(Reply4)).
