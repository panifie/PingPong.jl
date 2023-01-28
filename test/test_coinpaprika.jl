using Test

function test_paprika()
    @testset "paprika" begin
        @eval begin
            using PingPong.Watchers.CoinPaprika
            using Instruments
            using TimeTicks
            using .CoinPaprika.LazyJSON
            using Misc: Candle
            cp = CoinPaprika
        end
        @test test_ratelimit()
        @test test_twitter()
        @test test_exchanges()
        @test (unix2datetime(cp.glob()["last_updated"]) > now() - Day(1))
        @test "btc-bitcoin" ∈ keys(cp.loadcoins!())
        @test "dydx-dydx" ∈ keys(cp.coin_markets("eth-ethereum"))
        @test cp.coin_ohlcv("xmr-monero") isa Candle
        @test test_tickers()
        @test cp.ticker("btc-bitcoin") isa Dict{String,Float64}
        @test (
            betas = cp.betas(); betas isa NamedTuple &&
                length(betas.coins) == length(betas.betas)
        )
        @test cp.hourly("btc-bitcoin").timestamp[begin] > now() - Day(1)
    end
end

function test_twitter()
    tw = cp.twitter("btc-bitcoin")
    tw isa LazyJSON.Array && length(tw) > 25 && occursin("bitcoin", string(tw))
end

function test_ratelimit()
    cp.coin_ohlcv("btc-bitcoin")
    cp.query_stack[] = 1
    start = now()
    cp.coin_ohlcv("btc-bitcoin")
    cp.query_stack[] == 0 &&
        now() - start < Second(1) &&
        (cp.addcalls!(100); cp.query_stack[] == 100)
end

function test_exchanges()
    excs = cp.coin_exchanges("btc-bitcoin")
    "binance" in keys(excs)
end

function test_markets()
    excs = cp.loadexchanges!()
    one = "binance" ∈ keys(excs)
    mkt = cp.markets("binance")
    one && "BTC/USDT:Spot" ∈ keys(mkt)
end

function test_tickers()
    tkrs = cp.tickers()
    "btc-bitcoin" in keys(tkrs) && tkrs isa Dict{String, Dict{String,Float64}}
end
