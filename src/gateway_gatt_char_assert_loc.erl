-module(gateway_gatt_char_assert_loc).

-include("gateway_gatt.hrl").
-include("gateway_config.hrl").
-include("pb/gateway_gatt_char_assert_loc_pb.hrl").

-behavior(gatt_characteristic).

-define(H3_LATLON_RESOLUTION, 12).

-export([
    init/2,
    uuid/1,
    flags/1,
    read_value/2,
    write_value/2,
    start_notify/1,
    stop_notify/1
]).

-record(state, {
    path :: ebus:object_path(),
    proxy :: ebus:proxy(),
    notify = false :: boolean(),
    value = <<"init">> :: binary()
}).

uuid(_) ->
    ?UUID_GATEWAY_GATT_CHAR_ASSERT_LOC.

flags(_) ->
    [read, write, notify].

init(Path, [Proxy]) ->
    Descriptors = [
        {gatt_descriptor_cud, 0, ["Assert Location"]},
        {gatt_descriptor_pf, 1, [opaque]}
    ],
    {ok, Descriptors, #state{path = Path, proxy = Proxy}}.

read_value(State = #state{value = Value}, #{"offset" := Offset}) ->
    {ok, binary:part(Value, Offset, byte_size(Value) - Offset), State};
read_value(State = #state{}, _) ->
    {ok, State#state.value, State}.

write_value(State = #state{}, Bin) ->
    try gateway_gatt_char_assert_loc_pb:decode_msg(Bin, gateway_assert_loc_v1_pb) of
        #gateway_assert_loc_v1_pb{
            lat = Lat,
            lon = Lon,
            owner = Owner,
            nonce = Nonce,
            fee = Fee,
            amount = Amount,
            payer = Payer
        } ->
            H3Index = h3:from_geo({Lat, Lon}, ?H3_LATLON_RESOLUTION),
            H3String = h3:to_string(H3Index),
            lager:info(
                "Requesting assert_loc_txn for lat/lon/acc: {~p, ~p, ~p} index: ~p",
                [Lat, Lon, ?H3_LATLON_RESOLUTION, H3String]
            ),
            Value =
                case
                    ebus_proxy:call(
                        State#state.proxy,
                        "/",
                        ?MINER_OBJECT(?MINER_MEMBER_ASSERT_LOC),
                        [string, string, uint64, uint64, uint64, string],
                        [H3String, Owner, Nonce, Amount, Fee, Payer]
                    )
                of
                    {ok, [BinTxn]} ->
                        BinTxn;
                    {error, Error} ->
                        lager:warning("Failed to get assert_loc txn: ~p", [Error]),
                        case Error of
                            "org.freedesktop.DBus.Error.ServiceUnknown" -> <<"wait">>;
                            ?MINER_ERROR_BADARGS -> <<"badargs">>;
                            ?MINER_ERROR_INTERNAL -> <<"error">>;
                            _ -> <<"unknown">>
                        end
                end,
            {ok, maybe_notify_value(State#state{value = Value})}
    catch
        _What:Why ->
            lager:warning("Failed to decode assert_loc request: ~p", [Why]),
            {ok, maybe_notify_value(State#state{value = <<"badargs">>})}
    end.

start_notify(State = #state{notify = true}) ->
    %% Already notifying
    {ok, State};
start_notify(State = #state{}) ->
    {ok, maybe_notify_value(State#state{notify = true})}.

stop_notify(State = #state{notify = false}) ->
    %% Already not notifying
    {ok, State};
stop_notify(State = #state{}) ->
    {ok, State#state{notify = false}}.

%%
%% Internal
%%

maybe_notify_value(State = #state{notify = false}) ->
    State;
maybe_notify_value(State = #state{}) ->
    gatt_characteristic:value_changed(
        State#state.path,
        State#state.value
    ),
    State.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

uuid_test() ->
    {ok, _, Char} = ?MODULE:init("", [proxy]),
    ?assertEqual(?UUID_GATEWAY_GATT_CHAR_ASSERT_LOC, ?MODULE:uuid(Char)),
    ok.

flags_test() ->
    {ok, _, Char} = ?MODULE:init("", [proxy]),
    ?assertEqual([read, write, notify], ?MODULE:flags(Char)),
    ok.

success_test() ->
    {ok, _, Char} = ?MODULE:init("", [proxy]),
    BinTxn = <<"txn">>,

    meck:new(ebus_proxy, [passthrough]),
    meck:expect(
        ebus_proxy,
        call,
        fun(
            proxy,
            "/",
            ?MINER_OBJECT(?MINER_MEMBER_ASSERT_LOC),
            [string, string, uint64, uint64, uint64, string],
            [_Loc, _OwnerB58, _Nonce, _Amount, _Fee, _Payer]
        ) ->
            {ok, [BinTxn]}
        end
    ),
    meck:new(gatt_characteristic, [passthrough]),
    meck:expect(
        gatt_characteristic,
        value_changed,
        fun
            ("", <<"init">>) ->
                ok;
            ("", V) when V == BinTxn ->
                ok
        end
    ),

    {ok, Char1} = ?MODULE:start_notify(Char),
    %% Calling start_notify again has no effect
    ?assertEqual({ok, Char1}, ?MODULE:start_notify(Char1)),

    Req = #gateway_assert_loc_v1_pb{lat = 10.0, lon = 11.0},
    ReqBin = gateway_gatt_char_assert_loc_pb:encode_msg(Req),
    {ok, Char2} = ?MODULE:write_value(Char1, ReqBin),
    ?assertEqual({ok, BinTxn, Char2}, ?MODULE:read_value(Char2, #{})),

    {ok, Char3} = ?MODULE:stop_notify(Char2),
    ?assertEqual({ok, Char3}, ?MODULE:stop_notify(Char3)),

    ?assert(meck:validate(ebus_proxy)),
    meck:unload(ebus_proxy),
    ?assert(meck:validate(gatt_characteristic)),
    meck:unload(gatt_characteristic),

    ok.

error_test() ->
    {ok, _, Char} = ?MODULE:init("", [proxy]),

    meck:new(ebus_proxy, [passthrough]),
    meck:expect(
        ebus_proxy,
        call,
        fun(
            proxy,
            "/",
            ?MINER_OBJECT(?MINER_MEMBER_ASSERT_LOC),
            [string, string, uint64, uint64, uint64, string],
            [_Loc, _OwnerB58, _Nonce, _Amount, _Fee, _Payer]
        ) ->
            ErrorName = get({?MODULE, meck_error}),
            {error, ErrorName}
        end
    ),

    Req = #gateway_assert_loc_v1_pb{lat = 10.0, lon = 11.0},
    ReqBin = gateway_gatt_char_assert_loc_pb:encode_msg(Req),

    Char2 = lists:foldl(
        fun({ErrorName, Value}, State) ->
            put({?MODULE, meck_error}, ErrorName),
            {ok, NewState} = ?MODULE:write_value(State, ReqBin),
            ?assertEqual({ok, Value, NewState}, ?MODULE:read_value(NewState, #{})),
            NewState
        end,
        Char,
        [
            {?MINER_ERROR_BADARGS, <<"badargs">>},
            {?MINER_ERROR_INTERNAL, <<"error">>},
            {"org.freedesktop.DBus.Error.ServiceUnknown", <<"wait">>},
            {"com.unknown.Error", <<"unknown">>}
        ]
    ),

    InvalidReqBin = <<"invalid">>,
    {ok, Char3} = ?MODULE:write_value(Char2, InvalidReqBin),
    ?assertEqual({ok, <<"badargs">>, Char3}, ?MODULE:read_value(Char3, #{})),

    ?assert(meck:validate(ebus_proxy)),
    meck:unload(ebus_proxy),

    ok.

-endif.
