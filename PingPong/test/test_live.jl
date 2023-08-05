using Python
using Lang: @lget!

function _live_load()
    @eval begin
        using Test
        using Mocking
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

function test_live_nomargin_gtc(s)
    @testset "live_position" begin
        # create a mock exchange with fetchPosition and fetchPositions methods

        # test live_position with fetchPosition method
        @test live_position(mock_ai) isa PyDict
        @test live_position(mock_ai).get("symbol") == @pystr("BTC/USD")
        @test live_position(mock_ai).get("contracts") == 10.0
        @test live_position(mock_ai).get("entryPrice") == 100.0
        @test live_position(mock_ai).get("maintenanceMarginPercentage") == 0.01
        @test live_position(mock_ai).get("side") == @pystr("long")

        # test live_position with fetchPositions method
        mock_exchange["has"]["fetchPosition"] = false # disable fetchPosition method
        @test live_position(mock_ai) isa PyDict
        @test live_position(mock_ai).get("symbol") == @pystr("BTC/USD")
        @test live_position(mock_ai).get("contracts") == 10.0
        @test live_position(mock_ai).get("entryPrice") == 100.0
        @test live_position(mock_ai).get("maintenanceMarginPercentage") == 0.01
        @test live_position(mock_ai).get("side") == @pystr("long")

        # test live_position with empty list response from fetchPositions method
        mock_exchange["fetchPositions"] = (ai) -> PyList([]) # return an empty list
        @test live_position(mock_ai) === nothing

        # test live_position with PyException response from fetchPosition method
        mock_exchange["has"]["fetchPosition"] = true # enable fetchPosition method
        mock_exchange["fetchPosition"] = (ai) -> PyException(PyNone()) # return a PyException
        @test live_position(mock_ai) === nothing

        # test live_position with invalid symbol response from fetchPosition method
        mock_exchange["fetchPosition"] =
            (ai) -> PyDict(
                "symbol" => @pystr("ETH/USD"), # different symbol from mock_ai
                "contracts" => 10.0,
                "entryPrice" => 100.0,
                "maintenanceMarginPercentage" => 0.01,
                "side" => @pystr("long"),
            )
        @test live_position(mock_ai) === nothing
    end

    @testset "_optposside" begin
        # create a mock margin instance with position field
        mock_ai = MarginInstance(; position=ByPos(Long(); cash=10.0))

        # test _optposside with existing position
        @test _optposside(mock_ai) isa Long

        # test _optposside with no position
        mock_ai.position = nothing
        @test _optposside(mock_ai) === nothing
    end
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
        v = lm.live_position(s, s[m"btc"], Short(), keep_info=true)
        @test pyisinstance(v.get("info"), pybuiltins.dict)
    end
end

function test_live()
    @testset "live" begin
        @eval include(joinpath(@__DIR__, "env.jl"))
        @eval _live_load()

        s = live_strat()

        @testset "live_fetch_orders" test_live_fetch_orders(s)
        @testset "live_fetch_positions" test_live_fetch_positions(s)
        @testset "live_cancel_orders" test_live_cancel_orders(s)
        @testset "live_cancel_all_orders" test_live_cancel_all_orders(s)
        @testset "live_position" test_live_position(s)
        # @testset "live_position_sync" test_live_cancel_all_orders(s)
    end
end
