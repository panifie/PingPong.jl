using PingPongDev.PingPong.Engine.Exchanges.Python
using PingPongDev.PingPong.Engine.Lang: @lget!, @m_str
using Test
using PingPongDev.PingPong.Engine.Exchanges: Exchanges as exs
using PingPongDev.PingPong.Engine.Misc: MarginMode

include("common.jl")

patch_pf = @expr function Python.pyfetch(f::Py, args...; kwargs...)
    _mock_py_f(Python.__pyfetch, f, args...; kwargs...)
end
patch_pft = @expr function Python.pyfetch_timeout(f::Py, args...; kwargs...)
    _mock_py_f(Python._pyfetch_timeout, f, args...; kwargs...)
end

function _mock_py_f(pyf, f, args...; kwargs...)
    name = string(f.__name__)
    if occursin("position", name)
        _pyjson("fetch_positions.json")
    elseif occursin("_orders", name)
        pylist()
    elseif occursin("_balance", name)
        pylist()
    elseif occursin("leverage", name) && !occursin("tiers", name)
        PyDict("code" => "0")
    else
        @warn "MOCKING: Unhandled call!" f
        pyf(f, args...; kwargs...)
    end
end

macro live_setup!()
    ex = quote
        @pass [patch_pf, patch_pft] begin
            reset!(s)
        end
        ai = s[m"btc"]
        eid = exchangeid(s)
    end
    esc(ex)
end

function _live_load()
    @eval begin
        using PingPongDev
        try
            @eval PingPongDev.PingPong.@environment!
        catch
        end
        using Base.Experimental: @overlay
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
        using .Python: pyisTrue, Py, pyisnone
        using .Misc.Lang: @lget!, Option
        using .ect.OrderTypes: ByPos
        using .ect: committed, marginmode, update_leverage!, liqprice!, update_maintenance!
        using .ect.Instruments: qc, bc, cash!
        using .ect.Instruments.Derivatives: sc
        using .ect.OrderTypes
        using PingPongDev
    end
end

function live_strat(name; kwargs...)
    s = backtest_strat(name; config_attrs=(; skip_watcher=true), mode=Live(), kwargs...)
    lm.set_exc_funcs!(s)
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

function live_dump_fetch_balance_json(s)
    v = lm.fetch_balance(s)
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
    patch = @expr function Python._pyfetch(f::Py, args...; kwargs...)
        _pyjson("fetch_orders.json")
    end
    @live_setup!
    @pass [patch] begin
        let resp = lm.fetch_orders(s, ai)
            @test length(resp) == 15
            @test all(string(o["symbol"]) == "BTC/USDT:USDT" for o in resp)
        end
        let resp = lm.fetch_orders(s, ai; side=Buy)
            @test length(resp) == 1
            @test all(string(o.get("side")) == "buy" for o in resp) #
        end
        let resp = lm.fetch_orders(s, ai; side=Sell)
            @test all(string(o.get("side")) == "sell" for o in resp)
        end
        let ids = [
                "96ed6ff5-92a9-47e3-a4cc-c56648559856",
                "f734049a-152d-49fe-a411-fd1c1f676d6a",
            ],
            resp = lm.fetch_orders(s, ai; ids)

            @test all(@py(o.get("id") in ids) for o in resp)
            @test length(resp) == 2
        end
    end
end

function test_live_fetch_positions(s)
    patch = @expr function Python.pyfetch_timeout(f::Py, args...; kwargs...)
        _pyjson("fetch_positions.json")
    end
    @pass [patch] begin
        @live_setup!
        lm.set_exc_funcs!(s)
        ais = [s[m"btc"], s[m"eth"]]
        resp = lm.fetch_positions(s, ais)
        @test length(resp) == 2
        Main.resp = resp
        syms = getindex.(PyList(resp), "symbol") .|> string
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
    @eval resps = []
    patch = @expr function Python.pyfetch(f::Py, args...; kwargs...)
        if string(f.__name__) in ("cancel_order", "cancel_orders", "cancel_order_ws", "cancel_orders_ws")
            push!(resps, (args, kwargs))
        else
            _pyjson("fetch_orders.json")
        end
    end
    @live_setup!
    @pass [patch] begin
        lm.cancel_orders(s, ai)
        Main.ords = resps
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
    @eval disabled = Ref{Any}(())
    patch = @expr function exs.ExchangeTypes.has(exc, sym)
        if sym in disabled[]
            false
        else
            exs.ExchangeTypes._has(exc, sym)
        end
    end
    (patch, disabled)
end

function test_live_cancel_all_orders(s)
    @eval resps = []
    patch1 = @expr function Python.pyfetch(f::Py, args...; kwargs...)
        if startswith(string(f.__name__), "cancel")
            push!(resps, (args, kwargs))
        else
            _pyjson("fetch_orders.json")
        end
    end
    patch2, disabled = _has_patch()
    disabled[] = (:cancelAllOrdersWs, :cancelAllOrders)
    @live_setup!
    @pass [patch1, patch2] begin
        lm.set_exc_funcs!(s)
        lm.cancel_all_orders(s, ai)
        @test length(resps[1]) == 2
        @test string(resps[1][1][1]) == "5fdd5248-0621-470b-b5df-e9c6bbe89860"
        @test string(resps[1][2][1]) == raw(ai) #
        empty!(resps)
        disabled[] = ()
        lm.set_exc_funcs!(s)
        lm.cancel_all_orders(s, ai)
        @test length(resps[1][1]) == 1
        @test string(resps[1][1][1]) == raw(ai)
        @test isempty(resps[1][2])
    end
    lm.set_exc_funcs!(s)
end

function test_live_position(s)
    @eval resps = []
    patch1 = @expr function Python.pyfetch_timeout(f::Py, args...; kwargs...)
        if occursin("position", string(f.__name__))
            _pyjson("fetch_positions.json")
        else
            @warn "MOCKING: Unhandled call!" f
            Python._pyfetch_timeout(f, args...; kwargs...)
        end
    end
    @live_setup!
    @pass [patch1] begin
        # NOTE: use force=true otherwise we might fetch not mocked results
        empty!(lm.get_positions(s).long)
        empty!(lm.get_positions(s).short)
        pw = lm.positions_watcher(s)
        lm.waitwatcherprocess(pw; since=now())
        # ensure watcher is unlocked otherwise force fetching gets skipped
        @lock lm.positions_watcher(s) nothing
        update = lm.live_position(s, ai, Short(); force=true)
        @test update.date <= now()
        @test !update.read[] || lm.position(ai, Short()).timestamp[] >= update.date
        @test !update.closed[]
        @test update.notify isa Base.GenericCondition
        v = update.resp
        @test pyisinstance(v, pybuiltins.dict)
        @test string(v.get("symbol")) == raw(ai)
        @test "info" ∈ v.keys()
        @test string(v.get("side")) == "short"
        v = lm.live_position(s, ai, Short();).resp
        @test pyisinstance(v.get("info"), pybuiltins.dict)
        # NOTE: use force=true otherwise we might fetch not mocked results
        empty!(lm.get_positions(s).long)
        empty!(lm.get_positions(s).short)
        # ensure watcher is unlocked otherwise force fetching gets skipped
        @lock lm.positions_watcher(s) nothing
        v = lm.live_position(s, ai, Long(); force=true)
        @test isnothing(v)
    end
end

function test_live_position_sync(s)
    @live_setup!
    @pass [patch_pf, patch_pft] begin
        # set some parameters for testing
        commits = true
        p = Short()
        resp = lm.fetch_positions(s, ai; side=p)[0]
        @test lm.pyisTrue(resp["unrealizedPnl"] == 1.4602989788032e-07)
        update = lm._posupdate(now(), resp)::lm.PositionTuple

        @info "TEST: watch positions!"
        s[:is_watch_positions] = false
        lm.watch_positions!(s)
        # test if sync! returns a Position object with the correct attributes
        @info "TEST: lock"
        @lock lm.positions_watcher(s) nothing
        reset!(ai.shortpos)
        reset!(ai.longpos)
        @info "TEST: sync"
        lm.live_sync_position!(s, ai, p, update; commits=commits)
        pos = lm.position(ai, p)
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
        @test pos.cash[] == -0.32
        @test lm.pyisTrue(pos.entryprice[] == resp.get(lm.Pos.entryPrice))

        # test hedged mode mismatch
        @info "TEST: double check" posside(ai) resp[lm.Pos.side] ccxt_side = lm._ccxtposside(opposite(lm.posside(p)))
        resp[lm.Pos.side] = lm._ccxtposside(opposite(lm.posside(p)))
        position(ai, opposite(posside(ai))).status[] = lm.PositionOpen()
        pos = position(ai)
        @test isopen(position(ai, Long))
        @test isopen(position(ai, Short))
        lm.live_sync_position!(
            s, ai, p, update; commits=commits
        )
        @test (isopen(position(ai, Long)) && !isopen(position(ai, Short))) ||
              (isopen(position(ai, Short)) && !isopen(position(ai, Long)))

        reset!(ai)
        @test pos.cash[] == 0.0
        try
            update.read[] = false
            ep = resp.get(lm.Pos.entryPrice)
            lm.live_sync_position!(s, ai, p, update; amount=0.01, ep_in=ep, commits=false)
        catch e
            @test occursin("can't be higher", e.msg)
        end
    end
end
function test_live_pnl(s)
    @live_setup!
    @pass [patch_pf, patch_pft] begin
        # set some parameters for testing
        p = Short()
        lp = lm.fetch_positions(s, ai; side=p)[0]
        @test !isnothing(lp)
        update = lm.PositionTuple(lm._posupdate(now(), lp))
        lm.live_sync_position!(s, ai, p, update; commits=false)
        pos = position(ai, p)
        price = lp.get(lm.Pos.lastPrice) |> pytofloat

        st.default!(s, skip_sync=true)
        lm.watch_positions!(s)
        empty!(lm.positions_watcher(s))
        # test if live_pnl returns the correct unrealized pnl from the live position
        update = lm.live_position(s, ai, p; force=true)
        pnl = lm.live_pnl(s, ai, p; synced=true, verbose=false)
        @test pnl == lm.resp_position_unpnl(update.resp, eid)

        update.resp[lm.Pos.unrealizedPnl] = 0.0
        pnl = lm.live_pnl(s, ai, p; update, synced=true, verbose=false)
        @test pnl ≈ 124.992 atol = 1e-2
        lm.entryprice!(pos, 0.0)
        pnl = lm.live_pnl(s, ai, p; update, synced=true, verbose=false)
        @test pnl ≈ 124.992 atol = 1
    end
end

function test_live_send_order(s)
    doerror, tries = @eval begin
        doerror = Ref(false)
        tries = Ref(0)
        doerror, tries
    end
    patch1 = @expr function Python.pyfetch(f::Py, args...; kwargs...)
        if occursin("create_order", string(f.__name__))
            doerror[] && begin
                tries[] += 1
                return ErrorException("")
            end
            _pyjson("create_order.json")
        else
            _mock_py_f(Python._pyfetch, f, args...; kwargs...)
        end
    end
    @live_setup!
    lm.cash!(s.cash, 1e8)
    @pass [patch1] begin
        cash!(ai, 0.123, Long())
        @info "TEST: send1"
        resp = lm.live_send_order(s, ai, ect.GTCOrder{Sell}; amount=0.123, price=60000.0)
        @test pyisinstance(resp, pybuiltins.dict)
        @test string(resp.get("id")) == "997477f8-3857-45f6-b20b-8bae58ab28d9"
        doerror[] = true
        cash!(ai, 0.123, Long())
        @info "TEST: send2"
        resp = lm.live_send_order(s, ai, ect.GTCOrder{Sell}; amount=0.123, price=60000)
        @test resp isa ErrorException
        cash!(ai, 0.123, Long())
        tries[] = 0
        @info "TEST: send3"
        resp = lm.live_send_order(
            s, ai, ect.GTCOrder{Sell}; amount=0.123, price=60000, retries=3
        )
        @test tries[] == 4
        @test resp isa ErrorException
        cash!(ai, 0, Long())
        @info "TEST: send4"
        @test_warn "not enough cash" resp = lm.live_send_order(s, ai, ect.GTCOrder{Sell}; amount=0.123, price=60000.0)
        @test isnothing(resp)
    end
end

function test_live_my_trades(s)
    patch1 = @expr function Python.pyfetch(f::Py, args...; kwargs...)
        if occursin("trades", string(f.__name__))
            _pyjson("mytrades.json")
        else
            Python._pyfetch(f, args...; kwargs...)
        end
    end
    @eval disabled = Ref{Any}()
    patch2 = @expr function exs.ExchangeTypes.has(exc::exs.CcxtExchange, sym)
        if sym in disabled
            false
        else
            exs.ExchangeTypes._has(exc, sym)
        end
    end
    @live_setup!
    try
        @pass [patch1, patch2] begin
            trades = lm.live_my_trades(s, ai)
            @test pyisinstance(trades, pybuiltins.list)
            @test length(trades) == 50
            since = pyconvert(Int, trades[-2].get("timestamp")) |> tt.dtstamp
            trades = lm.live_my_trades(s, ai; since)
            @test pyisinstance(trades, pybuiltins.list)
            @test length(trades) == 2
            disabled[] = (:fetchMyTrades)
            lm.set_exc_funcs!(s)
            @test_throws MethodError lm.live_my_trades(s, ai; since)
        end
    finally
        lm.set_exc_funcs!(s)
    end
end

_pyjson(filename) =
    let v = read(live_stubs_file(filename), String)
        pyimport("json").loads(v)
    end

function test_live_order_trades(s)
    lm.set_exc_funcs!(s)
    patch1 = @expr function Python.pyfetch(f::Py, args...; kwargs...)
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
    @pass [patch1, haspatch] begin
        disabled[] = (:fetchOrderTrades, :fetchOrderTradesWs)
        @info "TEST: live setup"
        @live_setup!
        @info "TEST: order trades 1"
        trades = lm.live_order_trades(s, ai, id)
        @test length(trades) == 1
        @test string(first(trades)["order"]) == id
        @info "TEST: order trades 2"
        trades = lm.live_order_trades(s, ai, "")
        @test isempty(trades)
    end
end

function test_live_openclosed_orders(s)
    @eval disabled = Ref{Any}(())
    patch1 = @expr function Python.pyfetch(f::Py, args...; kwargs...)
        if occursin("order", string(f.__name__))
            if :fallback in disabled[]
                pylist()
            else
                _pyjson("fetch_orders.json")
            end
        else
            @warn "MOCKING: unhandled call" f
            Python._pyfetch(f, args...; kwargs...)
        end
    end
    patch2 = @expr function exs.ExchangeTypes.has(exc, sym, args...; kwargs...)
        if sym in disabled[]
            false
        else
            exs.ExchangeTypes._has(exc, sym)
        end
    end
    patch3 = @expr function ExchangeTypes.first(exc::Exchange, args::Vararg{Symbol})
        if any(sym in disabled[] for sym in args)
            nothing
        else
            for a in args
                if ExchangeTypes._has(exc, a)
                    return getproperty(exc, a)
                end
            end
            nothing
        end
    end
    @pass [patch1, patch2, patch3] begin
        @live_setup!
        lm.set_exc_funcs!(s)
        @test has(exchange(ai), :fetchOpenOrders)
        orders = lm.fetch_open_orders(s, ai)
        Main.ords = orders
        @test all(pyeq(Bool, o["symbol"], @pyconst(raw(ai))) for o in orders)
        @test length(orders) == 1 # no check is done when query is direct from exchange
        @test lm.resp_order_id(first(orders), eid, String) == "5fdd5248-0621-470b-b5df-e9c6bbe89860"
        disabled[] = (:fetchOpenOrders, :fetchOpenOrdersWs)
        lm.set_exc_funcs!(s)
        orders = lm.fetch_open_orders(s, ai)
        @test length(orders) == 1
        @test all(pyeq(Bool, o["status"], @pyconst("open")) for o in orders)
        @test all(pyeq(Bool, o["symbol"], @pyconst(raw(ai))) for o in orders)

        disabled[] = (:fetchOpenOrders, :fetchOpenOrdersWs)
        lm.empty_caches!(s)
        lm.set_exc_funcs!(s)
        @test has(exchange(ai), :fetchClosedOrders, :fetchClosedOrdersWs)
        orders = lm.fetch_closed_orders(s, ai)
        @test length(orders) == 14
        @test all(pyeq(Bool, o["symbol"], @pyconst(raw(ai))) for o in orders)
        disabled[] = (:fetchClosedOrders, :fetchClosedOrdersWs)
        lm.set_exc_funcs!(s)
        orders = lm.fetch_closed_orders(s, ai)
        @test length(orders) == 14
        @test all(pyne(Bool, o["status"], @pyconst("open")) for o in orders)
        @test all(pyeq(Bool, o["symbol"], @pyconst(raw(ai))) for o in orders)
        disabled[] = (:fetchOrders, :fetchOrdersWs, :fallback)
        lm.set_exc_funcs!(s)
        orders = lm.fetch_orders(s, ai)
        @test length(orders) == 15
        @test all(pyeq(Bool, o["symbol"], @pyconst(raw(ai))) for o in orders)
        disabled[] = (:fetchOrders, :fetchOrdersWs, :fetchOpenOrdersWs, :fetchClosedOrdersWs, :fetchClosedOrders)
        lm.set_exc_funcs!(s)
        @test_throws UndefKeywordError lm.fetch_orders(s, ai)
    end
end

function _test_live(debug="LiveMode")
    if EXCHANGE_MM != :phemex
        @warn "skipping `live` tests for $EXCHANGE_MM (because currently mocked against a specific exchange)"
        return
    end
    prev_debug = get(ENV, "JULIA_DEBUG", nothing)
    ENV["JULIA_DEBUG"] = debug
    try
        let cbs = st.STRATEGY_LOAD_CALLBACKS.live
            if lm.load_strategy_cache ∉ cbs
                push!(cbs, lm.load_strategy_cache)
            end
        end
        @testset failfast = FAILFAST "live" begin
            s = @pass [patch_pf, patch_pft] begin
                live_strat(:ExampleMargin; exchange=EXCHANGE_MM, skip_sync=true)
            end
            setglobal!(Main, :s, s)
            try
                # @testset "live_fetch_orders" test_live_fetch_orders(s)
                # @testset "live_fetch_positions" test_live_fetch_positions(s)
                # @testset "live_cancel_orders" test_live_cancel_orders(s)
                # @testset "live_cancel_all_orders" test_live_cancel_all_orders(s)
                @testset "live_position" test_live_position(s)
                @testset "live_position_sync" test_live_position_sync(s)
                @testset "live_pnl" test_live_pnl(s)
                @testset "live_send_order" test_live_send_order(s)
                @testset "live_my_trades" test_live_my_trades(s)
                @testset "live_order_trades" test_live_order_trades(s)
                @testset "live_openclosed_order" test_live_openclosed_orders(s)
            finally
                @async lm.stop_all_tasks(s)
                lm.save_strategy_cache(s; inmemory=true)
            end
        end
    finally
        ENV["JULIA_DEBUG"] = prev_debug
    end
end

function test_live(debug=true)
    @eval _live_load()
    @eval _test_live($debug)
end
