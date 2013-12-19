%% @doc
%% This module implements a riak_test to exercise the Active
%% Anti-Entropy Fullsync replication.  It sets up two clusters, runs a
%% fullsync over all partitions, and verifies the missing keys were
%% replicated to the sink cluster.

-module(repl_aae_fullsync).
-behavior(riak_test).
-export([confirm/0]).
-include_lib("eunit/include/eunit.hrl").

confirm() ->
    NumNodesWanted = 6,         %% total number of nodes needed
    ClusterASize = 3,           %% how many to allocate to cluster A
    NumKeysAOnly = 10000,       %% how many keys on A that are missing on B
    NumKeysBoth = 10000,        %% number of common keys on both A and B
    Conf = [                    %% riak configuration
            {riak_core,
                [
                 {ring_creation_size, 8},
                 {default_bucket_props, [{n_val, 1}]}
                ]
            },
            {riak_kv,
                [
                 %% Specify fast building of AAE trees
                 {anti_entropy, {on, []}},
                 {anti_entropy_build_limit, {100, 1000}},
                 {anti_entropy_concurrency, 100}
                ]
            },
            {riak_repl,
             [
              {fullsync_strategy, aae},
              {fullsync_on_connect, false},
              {fullsync_interval, disabled}
             ]}
           ],

    %% build clusters
    {ANodes, BNodes} = repl_aae_fullsync_util:make_clusters(
            NumNodesWanted, ClusterASize, Conf),

    %% run normal aae repl test
    aae_fs_test(NumKeysAOnly, NumKeysBoth, ANodes, BNodes),

    pass.

aae_fs_test(NumKeysAOnly, NumKeysBoth, ANodes, BNodes) ->
    %% populate them with data
    TestHash =  list_to_binary([io_lib:format("~2.16.0b", [X]) ||
                <<X>> <= erlang:md5(term_to_binary(os:timestamp()))]),

    TestBucket = <<TestHash/binary, "-systest_a">>,
    repl_aae_fullsync_util:prepare_cluster_data(TestBucket,
                                                NumKeysAOnly,
                                                NumKeysBoth,
                                                ANodes,
                                                BNodes),

    AFirst = hd(ANodes),
    BFirst = hd(BNodes),
    AllNodes = ANodes ++ BNodes,
    LeaderA = rpc:call(AFirst, riak_core_cluster_mgr, get_leader, []),

    %%---------------------------------------------------------
    %% TEST: fullsync, check that non-RT'd keys get repl'd to B
    %% keys: 1..NumKeysAOnly
    %%---------------------------------------------------------

    rt:log_to_nodes(AllNodes,
                    "Test fullsync from cluster A leader ~p to cluster B",
                    [LeaderA]),
    lager:info("Test fullsync from cluster A leader ~p to cluster B",
               [LeaderA]),
    repl_util:enable_fullsync(LeaderA, "B"),
    rt:wait_until_ring_converged(ANodes),

    TargetA = hd(ANodes -- [LeaderA]),
    %% find out how many indices the first node owns
    NumIndicies = length(rpc:call(TargetA, riak_core_ring, my_indices,
                    [rt:get_ring(TargetA)])),

    lager:info("~p owns ~p indices", [TargetA, NumIndicies]),

    %% Before enabling fullsync, ensure trees on one source node return
    %% not_built to defer fullsync process.
    ok = rt_intercept:add(TargetA, {riak_kv_index_hashtree, [{{get_lock, 2}, not_built}]}),

    check_fullsync(LeaderA, NumIndicies),

    reboot(TargetA),

    %% Before enabling fullsync, ensure trees on one source node return
    %% not_built to defer fullsync process.
    ok = rt_intercept:add(TargetA, {riak_kv_index_hashtree, [{{get_lock, 2},
                                                              already_locked}]}),

    check_fullsync(LeaderA, NumIndicies),

    reboot(TargetA),

    %% emulate the partitoons are changing ownership
    ok = rt_intercept:add(TargetA, {riak_kv_vnode, [{{hashtree_pid, 1},
                                                     wrong_node}]}),

    check_fullsync(LeaderA, NumIndicies),

    reboot(TargetA),

    repl_util:wait_until_aae_trees_built([TargetA]),

    check_fullsync(LeaderA, 0),

    %% verify data is replicated to B
    rt:log_to_nodes(AllNodes,
                    "Verify: Reading ~p keys repl'd from A(~p) to B(~p)",
                    [NumKeysAOnly, LeaderA, BFirst]),
    lager:info("Verify: Reading ~p keys repl'd from A(~p) to B(~p)",
               [NumKeysAOnly, LeaderA, BFirst]),
    ?assertEqual(0, repl_util:wait_for_reads(
            BFirst, 1, NumKeysAOnly, TestBucket, 1)),

    ok.

check_fullsync(Node, ExpectedFailures) ->
    {Time,_} = timer:tc(repl_util,
                        start_and_wait_until_fullsync_complete,
                        [Node]),
    lager:info("Fullsync completed in ~p seconds", [Time/1000/1000]),

    Status = rpc:call(Node, riak_repl_console, status, [quiet]),
    [{_Name, Props}] = proplists:get_value(fullsync_coordinator, Status),
    %% check that the expected number of partitions failed to sync
    ?assertEqual(ExpectedFailures, proplists:get_value(error_exits, Props)),
    %% check that we retried each of them 5 times
    ?assert(proplists:get_value(retry_exits, Props) >= ExpectedFailures * 5),
    ok.

reboot(Node) ->
    rt:stop_and_wait(Node),
    rt:start_and_wait(Node),
    rt:wait_for_service(Node, riak_kv).
