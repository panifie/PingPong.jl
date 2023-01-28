using Test

function test_coingecko()
    @testset "coingecko" begin
        @eval begin
            using PingPong.Watchers.CoinGecko
            using Instruments
            using Instruments.Derivatives
            using TimeTicks
            cg = CoinGecko
        end
        @test cg.ping()
        @test coingecko_ratelimit()
        @test coingecko_tickers()
        @test coingecko_price()
        @test coingecko_currencies()
        @test length(cg.loadcoins!()) > 0
        @test length(cg.coinsmarkets!()) > 0
        @test cg.coinsid("bitcoin")["id"] == "bitcoin"
        @test "identifier" ∈ cg.coinsticker("monero")[1]["market"]
        @test trunc(cg.coinshistory("bitcoin", "2020-01-02").price) == 7193
        @test coingecko_chart()
        @test coingecko_ohlc()
        @test fieldnames(typeof(cg.globaldata())) == (:volume, :mcap_change_24h, :date)
        @test length(cg.trending()) > 0
    end
end

coingecko_tickers() = begin
    list = cg.loadexchanges!()
    one = "binance" ∈ keys(list)
    tickers = cg.tickers_from("binance")
    one && tickers isa Dict{Asset,<:Any}
end

coingecko_ratelimit() = begin
    cg.ping()
    start = now()
    cg.ping()
    now() - start > cg.limit
end

function coingecko_price()
    v = cg.price(["bitcoin", "ethereum"])
    "last_updated_at" ∈ keys(v["bitcoin"]) && "usd" ∈ keys(v["ethereum"])
end

coingecko_currencies() = begin
    curs = cg.vs_currencies()
    curs isa Set && length(curs) > 0
end

coingecko_chart() = begin
    data = cg.coinschart("ethereum"; days_ago=7)
    @assert data isa NamedTuple
    one = Day(6) < now() - data.dates[1] < Day(8)
    data = cg.coinschart_tf("monero"; timeframe=tf"5m")
    two = (data.dates[2] - data.dates[1]) <= Minute(5)
    one && two
end

coingecko_ohlc() = begin
    data = cg.coinsohlc("bitcoin")
    data isa Matrix{Flaot64} && size(data)[2] == 5 && size(data)[1] > 0
end

coingecko_derivatives() = begin
    one = length(cg.loadderivatives!()) > 0
    drv = cg.derivatives_from("binance_futures")
    two = drv isa Dict{Derivative, <:Dict} && length(drv) > 0
    one && two && d"BTC/BUSD:BUSD" ∈ keys(drv)
end
