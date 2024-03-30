using Test

function test_coingecko()
    @eval begin
        using .PingPong.Engine.LiveMode.Watchers.CoinGecko
        using .PingPong.Engine.Instruments
        using .PingPong.Engine.TimeTicks
        using .Instruments.Derivatives: @d_str
        using .TimeTicks
        using .TimeTicks.Dates: format, @dateformat_str
        cg = CoinGecko
        # ensure other watchers are pulling data from coingecko
        # to avoid rate limit
        PingPong.Engine.LiveMode.Watchers._closeall()
    end
    @testset failfast = FAILFAST "coingecko" begin
        @test cg.RATE_LIMIT[] isa Period
        cg.RATE_LIMIT[] = Millisecond(1 * 1000)
        cg.RETRY[] = true
        @info "TEST: cg ping"
        @test cg.ping()
        @info "TEST: cg rate limit"
        @test coingecko_ratelimit()
        @info "TEST: cg ids"
        @test occursin("ethereum", cg.idbysym("eth"))
        @test "ethereum" in cg.idbysym("eth", false)
        @info "TEST: cg tickers"
        @test coingecko_tickers()
        @info "TEST: cg price"
        @test coingecko_price()
        @info "TEST: cg curr"
        @test coingecko_currencies()
        @info "TEST: cg load"
        @test length(cg.loadcoins!()) > 0
        @info "TEST: cg markets"
        @test length(cg.coinsmarkets()) > 0
        @test cg.coinsid("bitcoin")["id"] == "bitcoin"
        @test "identifier" ∈ keys(cg.coinsticker("monero")[1]["market"])
        date = format(now() - Month(1), dateformat"YYYY-mm-dd")
        @test 62500 < round(Int, cg.coinshistory("bitcoin", date).price) < 62600
        @info "TEST: cg start"
        coingecko_chart()
        @info "TEST: cg ohlc"
        coingecko_ohlc()
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
    now() - start > cg.RATE_LIMIT[]
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
    @test data isa NamedTuple
    @test Day(6) < now() - data.dates[1] < Day(8)
    data = cg.coinschart_tf("monero"; timeframe=tf"5m")
    @test round(data.dates[2] - data.dates[1], Minute) <= Minute(6)
end

coingecko_ohlc() = begin
    data = cg.coinsohlc("bitcoin")
    @test data isa Matrix{Float64}
    @test size(data)[2] == 5
    @test size(data)[1] > 0
end

coingecko_derivatives() = begin
    one = length(cg.loadderivatives!()) > 0
    drv = cg.derivatives_from("binance_futures")
    two = drv isa Dict{Derivative,<:Dict} && length(drv) > 0
    one && two && d"BTC/BUSD:BUSD" ∈ keys(drv)
end
