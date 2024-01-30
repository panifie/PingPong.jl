using Test
using PingPongDev.PingPong.Engine.Lang: @m_str
using PingPongDev.PingPong.Engine.TimeTicks
using PingPongDev.PingPong.Engine.Exchanges.Python
using PingPongDev.PingPong.Engine.Simulations.Random

function test_sanitize(exc)
    s = "BTC/USDT:USDT"
    asset = parse(Derivative, s)
    @test asset isa Derivative
    @test exc isa Exchange{ExchangeID{:binanceusdm}}
    ai = inst.instance(exc, asset)
    @test ai isa AssetInstance{Instruments.Derivatives.Derivative8,ExchangeID{:binanceusdm},NoMargin}

    init_amount = amount = 123.1234567891012
    init_price = price = 0.12333333333333333

    amount = ect.Checks.sanitize_amount(ai, amount)
    price = ect.Checks.sanitize_price(ai, price)

    amt_prec = exc.markets[s]["precision"]["amount"]
    prc_prec = exc.markets[s]["precision"]["price"]
    @test price != init_price
    @test amount != init_amount
    ccxt_amt_prec = pyconvert(
        Float64, @py float(exc.py.decimalToPrecision(amount; counting_mode=Int(exc.precision), precision=amt_prec))
    )
    ccxt_prc_prec = pyconvert(
        Float64, @py float(exc.py.decimalToPrecision(price; counting_mode=Int(exc.precision), precision=prc_prec))
    )
    @info "TEST: " price ccxt_prc_prec prc_prec
    @test price ≈ ccxt_prc_prec atol = prc_prec
    @info "TEST: " amount ccxt_amt_prec amt_prec
    @test amount ≈ ccxt_amt_prec atol = amt_prec
end

_strat() = begin
    Random.seed!(123)
    backtest_strat(:ExampleMargin)
end

function test_orderscount(s)
    @test ect.execmode(s) == ect.Sim()
    st.reset!(s)
    ai = s[m"btc"]
    @info "TEST: " typeof(ai)
    row = ai.ohlcv[100, :]
    date(n=1) = row.timestamp + tf"1m" * n
    ect.pong!(
        s,
        ai,
        ect.GTCOrder{ect.Buy};
        amount=ai.limits.amount.min - eps(),
        price=100.0,
        date=row.timestamp,
    )
    @info "TEST: " collect(ect.orders(s, ai))
    @test length(collect(ect.orders(s, ai))) == 0
    ect.pong!(s, ai, ect.GTCOrder{ect.Buy}; amount=100.0, price=1e10, date=date())
    @test length(collect(ect.orders(s, ai))) == 0
    ect.pong!(
        s,
        ai,
        ect.GTCOrder{ect.Buy};
        amount=ai.limits.amount.min,
        price=ai.limits.price.min,
        date=row.timestamp,
    )
    ect.pong!(s, ai, ect.GTCOrder{ect.Buy}; amount=100.0, price=1e-8, date=date())
    @test_throws AssertionError ect.pong!(s, ai, ect.GTCOrder{ect.Buy}; amount=100.0, price=1e-8, date=date())
    ect.pong!(s, ai, ect.GTCOrder{ect.Buy}; amount=100.0, price=1e-8, date=date(2))
    @test length(collect(ect.orders(s, ai))) == 2
    @test length(collect(ect.orders(s, ai, ect.Buy))) == 2
    @test length(collect(ect.orders(s, ai, ect.Sell))) == 0
    @test ect.hasorders(s, ect.Buy)
    @test !ect.hasorders(s, ect.Sell)
    st.default!(s)
    ect.cash!(s.cash, 1e6)
    ect.pong!(s, ai, ect.MarketOrder{ect.Buy}; amount=10.0, date=date(3))
    @test s.cash < 1e6
    ect.pong!(s, ai, ect.GTCOrder{ect.Sell}; amount=1.0, price=100, date=date(3))
    @test cash(ai) == 9.0
    ect.pong!(s, ai, ect.GTCOrder{ect.Sell}; amount=1.0, price=1e9, date=date(3))
    @test length(collect(ect.orders(s, ai, ect.Sell))) == 1
    @test length(collect(ect.orders(s))) == 3
    @test length(collect(ect.orders(s, ai, Long()))) == 3
    @test length(collect(ect.orders(s, ai, Short()))) == 0
    @test ect.hasorders(s, ai, Long)
    @test !ect.hasorders(s, Short)
    @test length(collect(ect.shortorders(s, ai))) == 0
    @test length(collect(ect.longorders(s, ai))) == 3
    @test length(collect(ect.longorders(s, ai, ect.Buy))) == 2
    let prevc = s.cash.value
        ect.pong!(s, ai, Long(), date(3), ect.PositionClose())
        @test isnothing(cash(ai))
        @test s.cash > prevc
    end
    ect.pong!(s, ai, ect.ShortGTCOrder{ect.Sell}; amount=1.0, price=1e5, date=date(4))
    @test length(collect(ect.shortorders(s, ai))) == 1
    @test isnothing(cash(ai))
    ect.pong!(s, ai, ect.ShortMarketOrder{ect.Sell}; amount=1.0, date=date(4))
    @test cash(ai) == -1.0
    @test inst.status(position(ai, Short)) == ect.PositionOpen()
    let prevc = s.cash.value
        try
            ect.pong!(s, ai, Long(), date(4), ect.PositionClose())
        catch e
            @test occursin("!(isopen", string(e))
        end
        ect.pong!(s, ai, Short(), date(4), ect.PositionClose())
        @test s.cash.value > prevc
        @test isnothing(cash(ai))
        @test inst.status(position(ai, Short())) == ect.PositionClose()
    end
end

test_orders() = @testset "orders" begin
    @eval begin
        using PingPongDev
        using PingPongDev.PingPong
        PingPongDev.PingPong.@environment!
        using PingPongDev.PingPong.Engine.Simulations.Random
        using .Misc: roundfloat
    end
    @info "TEST: sanitize"
    exc = getexchange!(:binanceusdm) # NOTE: binanceusdm NON sandbox version is geo restricted (not CI friendly)
    @testset failfast = FAILFAST test_sanitize(exc)
    @info "TEST: orderscount"
    s = _strat()
    @testset failfast = FAILFAST test_orderscount(s)
end
