-module(blockchain_test_utils).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

-export([
    init/1, init/2,
    init_chain/2, init_chain/3, init_chain/4,
    generate_keys/1, generate_keys/2,
    wait_until/1, wait_until/3,
    create_block/2, create_block/3, create_block/4,
    nonl/1,
    create_payment_transaction/5,
    atomic_save/2
]).

-define(BASE_TMP_DIR, "./_build/test/tmp").
-define(BASE_TMP_DIR_TEMPLATE, "XXXXXXXXXX").

init(BaseDir) ->
    #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ecc_compact),
    init(BaseDir, {PrivKey, PubKey}).

init(BaseDir, {PrivKey, PubKey}) ->
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    ECDHFun = libp2p_crypto:mk_ecdh_fun(PrivKey),
    Opts = [
        {key, {PubKey, SigFun, ECDHFun}},
        {seed_nodes, []},
        {port, 0},
        {num_consensus_members, 7},
        {base_dir, BaseDir}
    ],
    {ok, Sup} = blockchain_sup:start_link(Opts),
    ?assert(erlang:is_pid(blockchain_swarm:swarm())),
    {ok, Sup, {PrivKey, PubKey}, Opts}.

init_chain(Balance, Keys) ->
    init_chain(Balance, Keys, true, #{}).

init_chain(Balance, {PrivKey, PubKey}, InConsensus, ExtraVars) ->
    % Generate fake blockchains (just the keys)
    GenesisMembers =
        case InConsensus of
            true ->
                RandomKeys = blockchain_test_utils:generate_keys(10),
                Address = blockchain_swarm:pubkey_bin(),
                [
                    {Address, {PubKey, PrivKey, libp2p_crypto:mk_sig_fun(PrivKey)}}
                ] ++ RandomKeys;
            false ->
                blockchain_test_utils:generate_keys(11)
        end,
    init_chain(Balance, GenesisMembers, ExtraVars).

init_chain(Balance, Keys, InConsensus) when is_tuple(Keys), is_boolean(InConsensus) ->
    init_chain(Balance, Keys, InConsensus, #{});
init_chain(Balance, GenesisMembers, ExtraVars) when is_list(GenesisMembers), is_map(ExtraVars) ->
    % Create genesis block
    {InitialVars, Keys} = create_vars(ExtraVars),

    GenPaymentTxs = [
        blockchain_txn_coinbase_v1:new(Addr, Balance)
        || {Addr, _} <- GenesisMembers
    ],

    GenSecPaymentTxs = [
        blockchain_txn_security_coinbase_v1:new(Addr, Balance)
        || {Addr, _} <- GenesisMembers
    ],

    Addresses = [Addr || {Addr, _} <- GenesisMembers],

    Locations = lists:foldl(
        fun(I, Acc) ->
            [h3:from_geo({37.780586, -122.469470 + I / 100}, 12) | Acc]
        end,
        [],
        lists:seq(1, length(Addresses))
    ),
    InitialGatewayTxn = [
        blockchain_txn_gen_gateway_v1:new(Addr, Addr, Loc, 0)
        || {Addr, Loc} <- lists:zip(Addresses, Locations)
    ],

    ConsensusMembers = lists:sublist(GenesisMembers, 7),
    GenConsensusGroupTx = blockchain_txn_consensus_group_v1:new(
        [Addr || {Addr, _} <- ConsensusMembers],
        <<"proof">>,
        1,
        0
    ),
    Txs =
        InitialVars ++
            GenPaymentTxs ++
            GenSecPaymentTxs ++
            InitialGatewayTxn ++
            [GenConsensusGroupTx],
    lager:info("initial transactions: ~p", [Txs]),

    GenesisBlock = blockchain_block:new_genesis_block(Txs),
    ok = blockchain_worker:integrate_genesis_block(GenesisBlock),

    Chain = blockchain_worker:blockchain(),
    {ok, HeadBlock} = blockchain:head_block(Chain),
    ok = blockchain_test_utils:wait_until(fun() -> {ok, 1} =:= blockchain:height(Chain) end),

    ?assertEqual(blockchain_block:hash_block(GenesisBlock), blockchain_block:hash_block(HeadBlock)),
    ?assertEqual({ok, GenesisBlock}, blockchain:head_block(Chain)),
    ?assertEqual({ok, blockchain_block:hash_block(GenesisBlock)}, blockchain:genesis_hash(Chain)),
    ?assertEqual({ok, GenesisBlock}, blockchain:genesis_block(Chain)),
    ?assertEqual({ok, 1}, blockchain:height(Chain)),
    {ok, GenesisMembers, GenesisBlock, ConsensusMembers, Keys}.

generate_keys(N) ->
    generate_keys(N, ecc_compact).

generate_keys(N, Type) ->
    lists:foldl(
        fun(_, Acc) ->
            #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(Type),
            SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
            [{libp2p_crypto:pubkey_to_bin(PubKey), {PubKey, PrivKey, SigFun}} | Acc]
        end,
        [],
        lists:seq(1, N)
    ).

create_vars(Vars) ->
    #{secret := Priv, public := Pub} =
        libp2p_crypto:generate_keys(ecc_compact),

    Vars1 = raw_vars(Vars),
    ct:pal("vars ~p", [Vars1]),

    BinPub = libp2p_crypto:pubkey_to_bin(Pub),

    Txn = blockchain_txn_vars_v1:new(Vars1, 2, #{master_key => BinPub}),
    Proof = blockchain_txn_vars_v1:create_proof(Priv, Txn),
    Txn1 = blockchain_txn_vars_v1:key_proof(Txn, Proof),
    {[Txn1], {master_key, {Priv, Pub}}}.

raw_vars(Vars) ->
    DefVars = #{
        ?chain_vars_version => 2,
        ?vars_commit_delay => 10,
        ?election_version => 2,
        ?election_restart_interval => 5,
        ?election_replacement_slope => 20,
        ?election_replacement_factor => 4,
        ?election_selection_pct => 70,
        ?election_removal_pct => 85,
        ?election_cluster_res => 8,
        ?block_version => v1,
        ?predicate_threshold => 0.85,
        ?num_consensus_members => 7,
        ?monthly_reward => 50000 * 1000000,
        ?securities_percent => 0.35,
        ?poc_challengees_percent => 0.19 + 0.16,
        ?poc_challengers_percent => 0.09 + 0.06,
        ?poc_witnesses_percent => 0.02 + 0.03,
        ?consensus_percent => 0.10,
        ?min_assert_h3_res => 12,
        ?max_staleness => 100000,
        ?alpha_decay => 0.007,
        ?beta_decay => 0.0005,
        ?block_time => 30000,
        ?election_interval => 30,
        ?poc_challenge_interval => 30,
        ?h3_exclusion_ring_dist => 2,
        ?h3_max_grid_distance => 13,
        ?h3_neighbor_res => 12,
        ?min_score => 0.15,
        ?reward_version => 1,
        ?allow_zero_amount => false,
        ?poc_version => 8,
        ?poc_good_bucket_low => -132,
        ?poc_good_bucket_high => -80,
        ?poc_v5_target_prob_randomness_wt => 1.0,
        ?poc_v4_target_prob_edge_wt => 0.0,
        ?poc_v4_target_prob_score_wt => 0.0,
        ?poc_v4_prob_rssi_wt => 0.0,
        ?poc_v4_prob_time_wt => 0.0,
        ?poc_v4_randomness_wt => 0.5,
        ?poc_v4_prob_count_wt => 0.0,
        ?poc_centrality_wt => 0.5,
        ?poc_max_hop_cells => 2000,
        ?poc_path_limit => 7,
        ?poc_typo_fixes => true,
        ?poc_target_hex_parent_res => 5,
        ?witness_refresh_interval => 10,
        ?witness_refresh_rand_n => 100,
        ?max_open_sc => 2,
        ?min_expire_within => 10,
        ?max_xor_filter_size => 1024 * 100,
        ?max_xor_filter_num => 5,
        ?max_subnet_size => 65536,
        ?min_subnet_size => 8,
        ?max_subnet_num => 20,
        ?dc_payload_size => 24
    },

    maps:merge(DefVars, Vars).

wait_until(Fun) ->
    wait_until(Fun, 100, 100).

wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        true ->
            ok;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry - 1, Delay)
    end.

create_block(ConsensusMembers, Txs) ->
    %% Run validations by default
    create_block(ConsensusMembers, Txs, #{}, true).

create_block(ConsensusMembers, Txs, Override) ->
    %% Run validations by default
    create_block(ConsensusMembers, Txs, Override, true).

create_block(ConsensusMembers, Txs, Override, RunValidation) ->
    Blockchain = blockchain_worker:blockchain(),
    STxs = lists:sort(fun blockchain_txn:sort/2, Txs),
    case RunValidation of
        false ->
            %% Just make a block without validation
            {ok, make_block(Blockchain, ConsensusMembers, STxs, Override)};
        true ->
            case blockchain_txn:validate(STxs, Blockchain) of
                {_, []} ->
                    {ok, make_block(Blockchain, ConsensusMembers, STxs, Override)};
                {_, Invalid} ->
                    {error, {invalid_txns, Invalid}}
            end
    end.

make_block(Blockchain, ConsensusMembers, STxs, Override) ->
    {ok, HeadBlock} = blockchain:head_block(Blockchain),
    {ok, PrevHash} = blockchain:head_hash(Blockchain),
    Height = blockchain_block:height(HeadBlock) + 1,
    Time = blockchain_block:time(HeadBlock) + 1,
    lager:info("creating block ~p", [STxs]),
    Default = #{
        prev_hash => PrevHash,
        height => Height,
        transactions => STxs,
        signatures => [],
        time => Time,
        hbbft_round => 0,
        election_epoch => 1,
        epoch_start => 0,
        seen_votes => [],
        bba_completion => <<>>
    },
    Block0 = blockchain_block_v1:new(maps:merge(Default, Override)),
    BinBlock = blockchain_block:serialize(Block0),
    Signatures = signatures(ConsensusMembers, BinBlock),
    Block1 = blockchain_block:set_signatures(Block0, Signatures),
    lager:info("block ~p", [Block1]),
    Block1.

signatures(ConsensusMembers, BinBlock) ->
    lists:foldl(
        fun
            ({A, {_, _, F}}, Acc) ->
                Sig = F(BinBlock),
                [{A, Sig} | Acc];
            %% NOTE: This clause matches the consensus members generated for the dist suite
            ({A, _, F}, Acc) ->
                Sig = F(BinBlock),
                [{A, Sig} | Acc]
        end,
        [],
        ConsensusMembers
    ).

nonl([$\n | T]) -> nonl(T);
nonl([H | T]) -> [H | nonl(T)];
nonl([]) -> [].

create_payment_transaction(Payer, PayerPrivKey, Amount, Nonce, Recipient) ->
    Tx = blockchain_txn_payment_v1:new(Payer, Recipient, Amount, Nonce),
    SigFun = libp2p_crypto:mk_sig_fun(PayerPrivKey),
    blockchain_txn_payment_v1:sign(Tx, SigFun).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%-------------------------------------------------------------------
-spec atomic_save(file:filename_all(), binary() | string()) -> ok | {error, any()}.
atomic_save(File, Bin) ->
    ok = filelib:ensure_dir(File),
    TmpFile = File ++ "-tmp",
    ok = file:write_file(TmpFile, Bin),
    file:rename(TmpFile, File).
