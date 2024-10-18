using Test

function test_coinpaprika()
    @testset "coinpaprika" begin
        @eval begin
            using .PingPong.Engine.LiveMode.Watchers.CoinPaprika
            using .PingPong.Engine.Instruments
            using .PingPong.Engine.TimeTicks
            using .CoinPaprika.JSON3
            using .PingPong.Engine.Data: Candle
            cpr = CoinPaprika
        end
        @test test_ratelimit()
        @test test_twitter()
        @test test_cp_exchanges()
        @test (unix2datetime(cpr.glob()["last_updated"]) > now() - Day(1))
        @test "btc-bitcoin" ∈ keys(cpr.loadcoins!())
        @test "dydx-dydx" ∈ keys(cpr.coin_markets("eth-ethereum"))
        @test cpr.coin_ohlcv("xmr-monero") isa Candle
        @test test_cp_markets()
        @test test_tickers()
        @test cpr.ticker("btc-bitcoin") isa Dict{String,Float64}
        betas = cpr.betas()
        @test betas isa NamedTuple
        @test length(betas.coins) == length(betas.betas)
        @test cpr.hourly("btc-bitcoin").timestamp[begin] > now() - Day(1)
    end
end

function test_twitter()
    tw = cpr.twitter("btc-bitcoin")
    tw isa JSON3.Array && length(tw) > 25 && occursin("bitcoin", string(tw))
end

function test_ratelimit()
    cpr.coin_ohlcv("btc-bitcoin")
    cpr.query_stack[] = 1
    start = now()
    cpr.coin_ohlcv("btc-bitcoin")
    cpr.query_stack[] == 0 &&
        now() - start < Second(1) &&
        (cpr.addcalls!(100); cpr.query_stack[] == 100)
end

function test_cp_exchanges()
    excs = cpr.coin_exchanges("btc-bitcoin")
    "binance" in keys(excs)
end

function test_cp_markets()
    excs = cpr.loadexchanges!()
    one = "binance" ∈ keys(excs)
    mkt = cpr.markets("binance")
    one && "BTC/USDT:Spot" ∈ keys(mkt)
end

function test_tickers()
    tkrs = cpr.tickers()
    "btc-bitcoin" in keys(tkrs) && tkrs isa Dict{String,Dict{String,Float64}}
end
