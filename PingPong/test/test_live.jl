using Python
using Lang: @lget!
using Test
using Mocking
using Suppressor: @capture_err

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

live_strat() = begin
    backtest_strat(:Example; config_attrs=(; skip_watcher=true), mode=Live())
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

function test_live_fetch_orders(s)
    Mocking.activate()
    patch = @patch function pyfetch(f::Py, args...; kwargs...)
        v = read(live_stubs_file("fetch_orders.json"), String)
        pyimport("json").loads(v)
    end
    ai = s[m"btc"]
    Mocking.apply(patch) do
        let resp = lm.fetch_orders(s, ai)
            @test length(resp) == 15
            @test all(string(o["symbol"]) == "BTC/USDT:USDT" for o in resp)
        end
        let resp = lm.fetch_orders(s, ai; side=Buy)
            @test length(resp) == 1
            @test all(string(o.get("side")) == "buy" for o in resp)
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
    patch = @patch function pyfetch(f::Py, args...; kwargs...)
        v = read(live_stubs_file("fetch_positions.json"), String)
        pyimport("json").loads(v)
    end
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
    patch = @patch function pyfetch(f::Py, args...; kwargs...)
        if string(f.__name__) in
            ("cancel_order", "cancel_orders", "cancel_order_ws", "cancel_orders_ws")
            push!(resps, (args, kwargs))
        else
            v = read(live_stubs_file("fetch_orders.json"), String)
            pyimport("json").loads(v)
        end
    end
    Mocking.apply(patch) do
        lm.cancel_orders(s, s[m"btc"])
        @test string(resps[1][1][1]) == "5fdd5248-0621-470b-b5df-e9c6bbe89860"
        @test length(resps[1][2]) == 1
        @test first(resps[1][2]) == (:symbol => "BTC/USDT:USDT")
        empty!(resps)
        lm.cancel_orders(s, s[m"btc"]; side=Buy)
        @test string(resps[1][1][1]) == "5fdd5248-0621-470b-b5df-e9c6bbe89860"
        @test length(resps[1][2]) == 1
        @test resps[1][2][1] == "BTC/USDT:USDT"
        empty!(resps)
        lm.cancel_orders(s, s[m"btc"]; side=Sell)
        @test isempty(resps)
    end
end

function test_live_cancel_all_orders(s)
    Mocking.activate()
    resps = []
    patch1 = @patch function pyfetch(f::Py, args...; kwargs...)
        if startswith(string(f.__name__), "cancel")
            push!(resps, (args, kwargs))
        else
            v = read(live_stubs_file("fetch_orders.json"), String)
            pyimport("json").loads(v)
        end
    end
    disabled = Ref{Any}((:cancelAllOrdersWs, :cancelAllOrders))
    patch2 = @patch function exs.ExchangeTypes._has(exc::exs.CcxtExchange, sym)
        if sym in disabled[]
            false
        else
            exs.ExchangeTypes._has_check(exc, sym)
        end
    end
    Mocking.apply([patch1, patch2]) do
        lm.exc_live_funcs!(ts)
        lm.cancel_all_orders(s, s[m"btc"])
        @test length(resps[1][1]) == 1
        @test string(resps[1][1][1]) == "5fdd5248-0621-470b-b5df-e9c6bbe89860"
        @test collect(resps[1][2])[1] == (:symbol => SubString("BTC/USDT:USDT"))
        empty!(resps)
        disabled[] = ()
        lm.exc_live_funcs!(ts)
        lm.cancel_all_orders(s, s[m"btc"])
        @test length(resps[1][1]) == 1
        @test string(resps[1][1][1]) == "BTC/USDT:USDT"
        @test isempty(resps[1][2])
    end
    lm.exc_live_funcs!(ts)
end

function test_live_position(s)
    Mocking.activate()
    resps = []
    patch1 = @patch function Python._mockable_pyfetch(f::Py, args...; kwargs...)
        if occursin("position", string(f.__name__))
            v = read(live_stubs_file("fetch_positions.json"), String)
            pyimport("json").loads(v)
        else
            Python._pyfetch(f, args...; kwargs...)
        end
    end
    Mocking.apply([patch1]) do
        v = lm.live_position(s, s[m"btc"], Short())
        @test pyisinstance(v, pybuiltins.dict)
        @test string(v.get("symbol")) == "BTC/USDT:USDT"
        @test "info" ∉ v.keys()
        @test string(v.get("side")) == "short"
        v = lm.live_position(s, s[m"btc"], Long())
        @test isnothing(v)
        v = lm.live_position(s, s[m"btc"], Short(); keep_info=true)
        @test pyisinstance(v.get("info"), pybuiltins.dict)
    end
end

function test_live_position_sync(s)
    Mocking.activate()
    resps = []
    patch2 = @patch function Python._mockable_pyfetch(f::Py, args...; kwargs...)
        if occursin("position", string(f.__name__))
            v = read(live_stubs_file("fetch_positions.json"), String)
            pyimport("json").loads(v)
        else
            Python._pyfetch(f, args...; kwargs...)
        end
    end
    Mocking.apply([patch2]) do
        # set some parameters for testing
        commits = true
        ai = s[m"btc"]
        p = Short()
        update = lm.live_position(s, s[m"btc"], p)

        # test if sync! returns a Position object with the correct attributes
        reset!(ai.shortpos)
        reset!(ai.longpos)
        pos = lm.live_sync!(s, ai, p, update; commits=commits)
        @test typeof(pos) <: ect.Position{Short}
        @test pos.timestamp[] == lm.get_time(update, "timestamp")
        @test pos.status[] == ect.PositionOpen()
        @test pos.leverage[] == lm.get_float(update, "leverage")
        @test pos.notional[] == lm.get_float(update, lm.Pos.notional)
        @test pos.liquidation_price[] == lm.get_float(update, lm.Pos.liquidationPrice)
        @test pos.initial_margin[] ≈ lm.get_float(update, lm.Pos.initialMargin) atol = 1
        @test pos.maintenance_margin[] ≈ lm.get_float(update, lm.Pos.maintenanceMargin) atol =
            1
        @test inst.committed(pos) == inst.committed(s, ai, inst.posside(p))

        # test hedged mode mismatch
        update[lm.Pos.side] = lm._ccxtposside(opposite(lm.posside(p)))
        @test_throws AssertionError lm.live_sync!(s, ai, p, update; commits=commits)

        # test if sync! throws an exception if the position side does not match the update side
        patch_hedged = @patch function inst.ishedged(::MarginMode)
            true
        end

        Mocking.apply(patch_hedged) do
            @test_throws AssertionError lm.live_sync!(s, ai, p, update; commits=commits)
            reset!(ai)
            ep = update.get(lm.Pos.entryPrice)
            try
                pos = lm.live_sync!(s, ai, p, update; amount=0.01, ep_in=ep, commits=false)
            catch e
                @test occursin("can't be higher", e.msg)
            end
            pos = Ref{Any}()
            ep_d = pytofloat(ep * 2)
            out = @capture_err let
                pos[] = lm.live_sync!(
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
            v = read(live_stubs_file("fetch_positions.json"), String)
            v = pyimport("json").loads(v)
            isnothing(upnl[]) || for p in v
                p[lm.Pos.unrealizedPnl] = upnl[]
            end
            v
        else
            Python._pyfetch(f, args...; kwargs...)
        end
    end
    Mocking.apply([patch1]) do
        # set some parameters for testing
        ai = s[m"btc"]
        p = Short()
        lp = lm.live_position(s, ai, p)
        pos = lm.live_sync!(s, ai, p, lp; commits=false)
        price = lp.get(lm.Pos.lastPrice) |> pytofloat

        # test if live_pnl returns the correct unrealized pnl from the live position
        pnl = lm.live_pnl(s, ai, p; force_resync=:no, verbose=false)
        @test pnl == lm.get_float(lp, lm.Pos.unrealizedPnl)

        upnl[] = 0.0
        pnl = lm.live_pnl(s, ai, p; force_resync=:no, verbose=false)
        @test pnl ≈ 124.992 atol = 1e-2
        lm.entryprice!(pos, 0.0)
        pnl = lm.live_pnl(s, ai, p; force_resync=:no, verbose=false)
        @test pnl ≈ -9299 atol = 1
        pnl = lm.live_pnl(s, ai, p; force_resync=:auto, verbose=false)
        @test pnl ≈ 124.992 atol = 1e-2
    end
end

function test_live_create_order(s)
    Mocking.activate()
    doerror = Ref(false)
    tries = Ref(0)
    patch1 = @patch function Python._mockable_pyfetch(f::Py, args...; kwargs...)
        doerror[] && begin
            tries[] += 1
            return ErrorException("")
        end
        if occursin("create_order", string(f.__name__))
            v = read(live_stubs_file("create_order.json"), String)
            pyimport("json").loads(v)
        else
            Python._pyfetch(f, args...; kwargs...)
        end
    end
    Mocking.apply(patch1) do
        resp = lm.live_create_order(
            s, s[m"btc"], ect.GTCOrder{Sell}; amount=0.123, price=60000.0
        )
        @test pyisinstance(resp, pybuiltins.dict)
        @test string(resp.get("id")) == "997477f8-3857-45f6-b20b-8bae58ab28d9"
        doerror[] = true
        resp = lm.live_create_order(
            s, s[m"btc"], ect.GTCOrder{Sell}; amount=0.123, price=60000
        )
        @test resp isa ErrorException
        tries[] = 0
        resp = lm.live_create_order(
            s, s[m"btc"], ect.GTCOrder{Sell}; amount=0.123, price=60000, retries=3
        )
        @test tries[] == 4
        @test resp isa ErrorException
    end
end

function test_live()
    @testset "live" begin
        @eval include(joinpath(@__DIR__, "env.jl"))
        @eval _live_load()

        s = live_strat()

        # @testset "live_fetch_orders" test_live_fetch_orders(s)
        # @testset "live_fetch_positions" test_live_fetch_positions(s)
        # @testset "live_cancel_orders" test_live_cancel_orders(s)
        # @testset "live_cancel_all_orders" test_live_cancel_all_orders(s)
        # @testset "live_position" test_live_position(s)
        # @testset "live_position_sync" test_live_position_sync(s)
        # @testset "live_position_sync" test_live_pnl(s)
        # @testset "live_pnl" test_live_pnl(s)
        # TODO: test fetch_open_orders
        # TODO: test fetch_closed_orders
        test_live_create_order(s)
    end
end
