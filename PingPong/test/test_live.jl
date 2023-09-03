using Python
using Lang: @lget!
using Test
using Mocking
using Suppressor: @capture_err

mockapp(f, args...; kwargs...) = Mocking.apply(f, args...; kwargs...)

macro live_setup!()
    ex = quote
        reset!(s)
        ai = s[m"btc"]
        eid = exchangeid(ai)
    end
    esc(ex)
end

function _live_load()
    @eval begin
        using PingPong
        @environment!
        using .inst: MarginInstance, raw, cash, cash!
        using .Python:
            PyException,
            pyisinstance,
            pybuiltins,
            @pystr,
            pytryfloat,
            pytruth,
            pyconvert,
            PyDict
        using .Python.PythonCall: pyisTrue, Py, pyisnone
        using .Misc.Lang: @lget!, Option
        using .ect.OrderTypes: ByPos
        using .ect: committed, marginmode, update_leverage!, liqprice!, update_maintenance!
        using .ect.Instruments: qc, bc
        using .ect.Instruments.Derivatives: sc
        using .ect.OrderTypes
    end
end

function live_strat(name)
    s = backtest_strat(name; config_attrs=(; skip_watcher=true), mode=Live())
    lm.exc_live_funcs!(s)
    s
end

live_stubs_file(name) = begin
    d = joinpath(@__DIR__, "stubs", "live")
    mkpath(d)
    joinpath(d, name)
end

live_dump_fetch_orders_json(s) = begin
    ai = s[m"btc"]
    v = lm.fetch_orders(s, ai)
    j = pyimport("json").dumps(v)
    write(live_stubs_file("fetch_orders.json"), string(j))
end

function live_dump_fetch_positions_json(s)
    ai = s[m"btc"]
    v = lm.fetch_positions(s, [s[m"btc"], s[m"eth"]])
    j = pyimport("json").dumps(v)
    write(live_stubs_file("fetch_positions.json"), string(j))
end

function live_dump_my_trades_json(s)
    ai = s[m"btc"]
    v = lm.fetch_my_trades(s, ai)
    j = pyimport("json").dumps(v)
    write(live_stubs_file("mytrades.json"), string(j))
end

function live_dump_order_trades_json(s)
    ai = s[m"btc"]
    v = lm.fetch_closed_orders(s, ai)
    id = last(PyList(v)).get("id")
    v = lm.fetch_order_trades(s, raw(ai), s)
    j = pyimport("json").dumps(v)
    write(live_stubs_file("ordertrades.json"), string(j))
end

function test_live_fetch_orders(s)
    Mocking.activate()
    patch = @patch function Python._mockable_pyfetch(f::Py, args...; kwargs...)
        _pyjson("fetch_orders.json")
    end
    @live_setup!
    Mocking.apply(patch) do
        let resp = lm.fetch_orders(s, ai)
            @test length(resp) == 15
            @test all(string(o["symbol"]) == "BTC/USDT:USDT" for o in resp)
        end
        let resp = lm.fetch_orders(s, ai; side=Buy)
            @test length(resp) == 1
            @test all(string(o.get("side")) == "buy" for o in resp) #
        end
        let resp = lm.fetch_orders(s, ai; side=Sell)
            @test length(resp) == 14
            @test all(string(o.get("side")) == "sell" for o in resp)
        end
        let ids = [
                "96ed6ff5-92a9-47e3-a4cc-c56648559856",
                "f734049a-152d-49fe-a411-fd1c1f676d6a",
            ],
            resp = lm.fetch_orders(s, ai; ids)

            @test length(resp) == 2
            @test all(string(o.get("id")) in ids for o in resp)
        end
    end
end

function test_live_fetch_positions(s)
    Mocking.activate()
    patch = @patch function Python._mockable_pyfetch(f::Py, args...; kwargs...)
        _pyjson("fetch_positions.json")
    end
    @live_setup!
    ais = [s[m"btc"], s[m"eth"]]
    Mocking.apply(patch) do
        resp = lm.fetch_positions(s, ais)
        @test length(resp) == 2
        syms = getindex.(resp, "symbol") .|> string
        @test "ETH/USDT:USDT" ∈ syms && "BTC/USDT:USDT" ∈ syms
        resp = lm.fetch_positions(s, ais; side=Short())
        @test length(resp) == 1
        @test string(resp[0]["symbol"]) == "BTC/USDT:USDT"
        resp = lm.fetch_positions(s, ais; side=Long())
        @test length(resp) == 1
        @test string(resp[0]["symbol"]) == "ETH/USDT:USDT"
        resp
    end
end

function test_live_cancel_orders(s)
    Mocking.activate()
    resps = []
    patch = @patch function Python._mockable_pyfetch(f::Py, args...; kwargs...)
        if string(f.__name__) in
            ("cancel_order", "cancel_orders", "cancel_order_ws", "cancel_orders_ws")
            push!(resps, (args, kwargs))
        else
            _pyjson("fetch_orders.json")
        end
    end
    @live_setup!
    Mocking.apply(patch) do
        lm.cancel_orders(s, ai)
        @test string(resps[1][1][1]) == "5fdd5248-0621-470b-b5df-e9c6bbe89860"
        @test length(resps[1][2]) == 1
        @test first(resps[1][2]) == (:symbol => raw(ai))
        empty!(resps)
        lm.cancel_orders(s, ai; side=Buy)
        @test string(resps[1][1][1]) == "5fdd5248-0621-470b-b5df-e9c6bbe89860"
        @test length(resps[1][2]) == 1
        @test resps[1][2][1] == raw(ai)
        empty!(resps)
        lm.cancel_orders(s, ai; side=Sell)
        @test isempty(resps)
    end
end

function _has_patch()
    disabled = Ref{Any}(())
    patch = @patch function exs.ExchangeTypes._mockable_has(exc::exs.CcxtExchange, sym)
        if sym in disabled[]
            false
        else
            exs.ExchangeTypes._has(exc, sym)
        end
    end
    (patch, disabled)
end

function test_live_cancel_all_orders(s)
    Mocking.activate()
    resps = []
    patch1 = @patch function Python._mockable_pyfetch(f::Py, args...; kwargs...)
        if startswith(string(f.__name__), "cancel")
            push!(resps, (args, kwargs))
        else
            _pyjson("fetch_orders.json")
        end
    end
    patch2, disabled = _has_patch()
    disabled[] = (:cancelAllOrdersWs, :cancelAllOrders)
    @live_setup!
    Mocking.apply([patch1, patch2]) do
        lm.exc_live_funcs!(s)
        lm.cancel_all_orders(s, ai)
        @test length(resps[1]) == 2
        @test string(resps[1][1][1]) == "5fdd5248-0621-470b-b5df-e9c6bbe89860"
        @test string(resps[1][2][1]) == raw(ai) #
        empty!(resps)
        disabled[] = ()
        lm.exc_live_funcs!(s)
        lm.cancel_all_orders(s, ai)
        @test length(resps[1][1]) == 1
        @test string(resps[1][1][1]) == raw(ai)
        @test isempty(resps[1][2])
    end
    lm.exc_live_funcs!(s)
end

function test_live_position(s)
    Mocking.activate()
    resps = []
    patch1 = @patch function Python._mockable_pyfetch(f::Py, args...; kwargs...)
        if occursin("position", string(f.__name__))
            _pyjson("fetch_positions.json")
        else
            Python._pyfetch(f, args...; kwargs...)
        end
    end
    @live_setup!
    Mocking.apply([patch1]) do
        update = lm.live_position(s, ai, Short(); force=true)
        @test update.date <= now()
        @test !update.read[]
        @test !update.closed[]
        @test update.notify isa Base.GenericCondition
        v = update.resp
        @test pyisinstance(v, pybuiltins.dict)
        @test string(v.get("symbol")) == raw(ai)
        @test "info" ∈ v.keys()
        @test string(v.get("side")) == "short"
        v = lm.live_position(s, ai, Long())
        @test isnothing(v)
        v = lm.live_position(s, ai, Short();).resp
        @test pyisinstance(v.get("info"), pybuiltins.dict)
    end
end

function test_live_position_sync(s)
    Mocking.activate()
    resps = []
    patch2 = @patch function Python._mockable_pyfetch(f::Py, args...; kwargs...)
        if occursin("position", string(f.__name__))
            _pyjson("fetch_positions.json")
        else
            Python._pyfetch(f, args...; kwargs...)
        end
    end
    @live_setup!
    Mocking.apply([patch2]) do
        # set some parameters for testing
        commits = true
        p = Short()
        resp = lm.fetch_positions(s, ai; side=p)[0]
        update = lm._posupdate(now(), resp)::lm.PositionUpdate7

        # test if sync! returns a Position object with the correct attributes
        reset!(ai.shortpos)
        reset!(ai.longpos)
        pos = lm.live_sync_position!(s, ai, p, update; commits=commits)
        @test typeof(pos) <: ect.Position{Short}
        @test pos.timestamp[] <= lm.resp_position_timestamp(resp, eid)
        @test pos.status[] == ect.PositionOpen()
        @test pos.leverage[] == lm.get_float(resp, "leverage")
        @test pos.notional[] == lm.get_float(resp, lm.Pos.notional)
        @test pos.liquidation_price[] == lm.get_float(resp, lm.Pos.liquidationPrice)
        @test pos.initial_margin[] ≈ lm.get_float(resp, lm.Pos.initialMargin) atol = 1
        @test pos.maintenance_margin[] ≈ lm.get_float(resp, lm.Pos.maintenanceMargin) atol =
            1
        @test inst.committed(pos) == inst.committed(s, ai, inst.posside(p))

        # test hedged mode mismatch
        resp[lm.Pos.side] = lm._ccxtposside(opposite(lm.posside(p)))
        @test_throws AssertionError lm.live_sync_position!(
            s, ai, p, update; commits=commits
        )

        # test if sync! throws an exception if the position side does not match the resp side
        patch_hedged = @patch function inst.ishedged(::MarginMode)
            true
        end

        Mocking.apply(patch_hedged) do
            @test_throws AssertionError lm.live_sync_position!(
                s, ai, p, update; commits=commits
            )
            reset!(ai)
            ep = resp.get(lm.Pos.entryPrice)
            try
                pos = lm.live_sync_position!(
                    s, ai, p, update; amount=0.01, ep_in=ep, commits=false
                )
            catch e
                @test occursin("can't be higher", e.msg)
            end
            pos = Ref{Any}()
            ep_d = pytofloat(ep * 2)
            out = @capture_err let
                pos[] = lm.live_sync_position!(
                    s, ai, p, update; amount=0.01, ep_in=ep_d, commits=false
                )
            end
            pos = pos[]
            @test occursin("hedged mode mismatch", out)
            @test pos.cash[] == 0.01
            @test pos.entryprice[] == ep_d
        end
    end
end
function test_live_pnl(s)
    Mocking.activate()
    upnl = Ref{Any}(nothing)
    patch1 = @patch function Python._mockable_pyfetch(f::Py, args...; kwargs...)
        if occursin("position", string(f.__name__))
            _pyjson("fetch_positions.json")
        else
            Python._pyfetch(f, args...; kwargs...)
        end
    end
    @live_setup!
    Mocking.apply([patch1]) do
        # set some parameters for testing
        p = Short()
        lp = lm.fetch_positions(s, ai; side=p)[0]
        @test !isnothing(lp)
        update = lm.PositionUpdate7(lm._posupdate(now(), lp))
        pos = lm.live_sync_position!(s, ai, p, update; commits=false)
        price = lp.get(lm.Pos.lastPrice) |> pytofloat

        # test if live_pnl returns the correct unrealized pnl from the live position
        let resp = lm.live_position(s, ai, p; force=true).resp
            pnl = lm.live_pnl(s, ai, p; force_resync=:no, verbose=false)
            @test pnl == lm.resp_position_unpnl(resp, eid)
        end
        return nothing

        lp[lm.Pos.unrealizedPnl] = 0.0
        pnl = lm.live_pnl(s, ai, p; resp=lp, force_resync=:no, verbose=false)
        @test pnl ≈ 124.992 atol = 1e-2
        lm.entryprice!(pos, 0.0)
        pnl = lm.live_pnl(s, ai, p; resp=lp, force_resync=:no, verbose=false)
        @test pnl ≈ -9299 atol = 1
        pnl = lm.live_pnl(s, ai, p; resp=lp, force_resync=:auto, verbose=false)
        @test pnl ≈ 124.992 atol = 1e-2
    end
end

function test_live_send_order(s)
    Mocking.activate()
    doerror = Ref(false)
    tries = Ref(0)
    patch1 = @patch function Python._mockable_pyfetch(f::Py, args...; kwargs...)
        doerror[] && begin
            tries[] += 1
            return ErrorException("")
        end
        if occursin("create_order", string(f.__name__))
            _pyjson("create_order.json")
        else
            Python._pyfetch(f, args...; kwargs...)
        end
    end
    @live_setup!
    Mocking.apply(patch1) do
        cash!(ai, 0.123, Long())
        resp = lm.live_send_order(s, ai, ect.GTCOrder{Sell}; amount=0.123, price=60000.0)
        @test pyisinstance(resp, pybuiltins.dict)
        @test string(resp.get("id")) == "997477f8-3857-45f6-b20b-8bae58ab28d9"
        doerror[] = true
        resp = lm.live_send_order(s, ai, ect.GTCOrder{Sell}; amount=0.123, price=60000)
        @test resp isa ErrorException
        tries[] = 0
        resp = lm.live_send_order(
            s, ai, ect.GTCOrder{Sell}; amount=0.123, price=60000, retries=3
        )
        @test tries[] == 4
        @test resp isa ErrorException
        cash!(ai, 0, Long())
        resp = lm.live_send_order(s, ai, ect.GTCOrder{Sell}; amount=0.123, price=60000.0)
        @test isnothing(resp)
    end
end

function test_live_my_trades(s)
    Mocking.activate()
    patch1 = @patch function Python._mockable_pyfetch(f::Py, args...; kwargs...)
        if occursin("trades", string(f.__name__))
            _pyjson("mytrades.json")
        else
            Python._pyfetch(f, args...; kwargs...)
        end
    end
    disabled = Ref{Any}()
    patch2 = @patch function exs.ExchangeTypes._mockable_has(exc::exs.CcxtExchange, sym)
        if sym in disabled
            false
        else
            exs.ExchangeTypes._has(exc, sym)
        end
    end
    @live_setup!
    try
        Mocking.apply([patch1, patch2]) do
            trades = lm.live_my_trades(s, ai)
            @test pyisinstance(trades, pybuiltins.list)
            @test length(trades) == 50
            since = pyconvert(Int, trades[-2].get("timestamp")) |> tt.dtstamp
            trades = lm.live_my_trades(s, ai; since)
            @test pyisinstance(trades, pybuiltins.list)
            @test length(trades) == 2
            disabled[] = (:fetchMyTrades)
            lm.exc_live_funcs!(s)
            @test_throws MethodError lm.live_my_trades(s, ai; since)
        end
    finally
        lm.exc_live_funcs!(s)
    end
end

_pyjson(filename) =
    let v = read(live_stubs_file(filename), String)
        pyimport("json").loads(v)
    end

function test_live_order_trades(s)
    Mocking.activate()
    lm.exc_live_funcs!(s)
    patch1 = @patch function Python._mockable_pyfetch(f::Py, args...; kwargs...)
        if occursin("trades", string(f.__name__))
            _pyjson("mytrades.json")
        elseif occursin("order", string(f.__name__))
            _pyjson("fetch_orders.json")
        else
            Python._pyfetch(f, args...; kwargs...)
        end
    end
    haspatch, disabled = _has_patch()
    id = "1682179200-BTCUSDT-1439869-Buy"
    mockapp([patch1, haspatch]) do
        disabled[] = (:fetchOrderTrades,)
        @live_setup!
        trades = lm.live_order_trades(s, ai, id)
        @test length(trades) == 1
        @test string(trades[0]["order"]) == id
        trades = lm.live_order_trades(s, ai, "")
        @test isempty(trades)
    end
end

function test_live_openclosed_orders(s)
    Mocking.activate()
    lm.exc_live_funcs!(s)
    patch1 = @patch function Python._mockable_pyfetch(f::Py, args...; kwargs...)
        if occursin("order", string(f.__name__))
            _pyjson("fetch_orders.json")
        else
            Python._pyfetch(f, args...; kwargs...)
        end
    end
    disabled = Ref{Any}(())
    @live_setup!
    patch2 = @patch function exs.ExchangeTypes._mockable_has(exc::exs.CcxtExchange, sym)
        if sym in disabled[]
            false
        else
            exs.ExchangeTypes._has(exc, sym)
        end
    end
    Mocking.apply([patch1, patch2]) do
        @test has(exchange(ai), :fetchOpenOrders)
        orders = lm.fetch_open_orders(s, ai)
        @test length(orders) == 15 # no check is done when query is direct from exchange
        @test all(pyeq(Bool, o["symbol"], @pyconst(raw(ai))) for o in orders)
        disabled[] = (:fetchOpenOrders,)
        lm.exc_live_funcs!(s)
        orders = lm.fetch_open_orders(s, ai)
        @test length(orders) == 1
        @test all(pyeq(Bool, o["status"], @pyconst("open")) for o in orders)
        @test all(pyeq(Bool, o["symbol"], @pyconst(raw(ai))) for o in orders)

        disabled[] = ()
        lm.exc_live_funcs!(s)
        @test has(exchange(ai), :fetchClosedOrders)
        orders = lm.fetch_closed_orders(s, ai)
        @test length(orders) == 15 # no check is done when query is direct from exchange
        @test all(pyeq(Bool, o["symbol"], @pyconst(raw(ai))) for o in orders)
        disabled[] = (:fetchClosedOrders,)
        lm.exc_live_funcs!(s)
        orders = lm.fetch_closed_orders(s, ai)
        @test length(orders) == 14
        @test all(pyne(Bool, o["status"], @pyconst("open")) for o in orders)
        @test all(pyeq(Bool, o["symbol"], @pyconst(raw(ai))) for o in orders)
    end
end

# test_live_watch_trades(s) = begin
#     ai = s[m"btc"]
#     lm.watch_trades
# end

# test_live_limit_order(s) = begin end

function test_live()
    @testset "live" begin
        @eval include(joinpath(@__DIR__, "env.jl"))
        @eval _live_load()

        s = live_strat(:ExampleMargin)
        @testset "live_fetch_orders" test_live_fetch_orders(s)
        @testset "live_fetch_positions" test_live_fetch_positions(s)
        @testset "live_cancel_orders" test_live_cancel_orders(s)
        @testset "live_cancel_all_orders" test_live_cancel_all_orders(s)
        @testset "live_position" test_live_position(s)
        @testset "live_position_sync" test_live_position_sync(s)
        @testset "live_pnl" test_live_pnl(s)
        @testset "live_send_order" test_live_send_order(s)
        @testset "live_my_trades" test_live_my_trades(s)
        @testset "live_order_trades" test_live_order_trades(s)
        @testset "live_openclosed_order" test_live_openclosed_orders(s)
    end
end
