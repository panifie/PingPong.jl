pair = "ETH/USDT"
n_pairs = ["ETH/USDT", "BTC/USDT"]
timeframe = "5m"

_test_ohlcv_exc() = begin
    @eval using Fetch
    @eval using Data: OHLCV_COLUMNS
    @eval using Processing: islast
    timeframe = "5m"
    count = 500
    o = fetch_ohlcv(timeframe, pair; from=-count, progress=false)
    @assert pair ∈ keys(o)
    pd = o[pair]
    @assert pd isa PairData
    @assert pd.name == pair
    @assert pd.tf == timeframe
    @assert pd.z isa ZArray
    @assert names(pd.data) == String.(OHLCV_COLUMNS)
    @assert size(pd.data)[1] > (count / 10 * 9) # if its less there is something wrong
    lastcandle = pd.data[end, :][1]
    @assert islast(lastcandle, timeframe)
    true
end

_test_ohlcv() = begin
    # if one exchange does not succeeds try on other exchanges
    # until one succeeds
    for e in (:kucoin, :bybit, :binance)
        try
            setexchange!(e)
            _test_ohlcv_exc()
            return true
        catch
        end
    end
    false
end

test_ohlcv() = @testset "ohlcv" begin
    @test begin
        _test_ohlcv()
    end
end
