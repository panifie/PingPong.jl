using Test


_test_ohlcv_exc(exc) = begin
    pair = "ETH/USDT"
    timeframe = "5m"
    count = 500
    o = fetch_ohlcv(exc, timeframe, [pair]; from=-count, progress=false)
    @test pair ∈ keys(o)
    pd = o[pair]
    @test pd isa PairData
    @test pd.name == pair
    @test pd.tf == timeframe
    @test pd.z isa ZArray
    @test names(pd.data) == String.(OHLCV_COLUMNS)
    @test size(pd.data)[1] > (count / 10 * 9) # if its less there is something wrong
    lastcandle = pd.data[end, :][1]
    @test islast(lastcandle, timeframe) || now() - lastcandle.timestamp < Second(5)
end

_test_ohlcv() = begin
    # if one exchange does not succeeds try on other exchanges
    # until one succeeds
    for e in (:kucoin, :bybit, :binance)
        @debug "TEST: test_ohlcv" exchange = e
        let exc = setexchange!(e)
            _test_ohlcv_exc(exc)
        end
    end
end

test_ohlcv() = @testset "ohlcv" begin
    @eval begin
        using .PingPong.Engine.LiveMode.Watchers.Fetch
        using .Fetch.Exchanges
        using .PingPong.Engine.Data: OHLCV_COLUMNS, ZArray, PairData
        using .PingPong.Engine.Processing: islast
    end
    _test_ohlcv()
end
