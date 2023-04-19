pair = "BTC/USDT"
n_pairs = ["BTC/USDT", "ADA/USDT"]
timeframe = "1d"

function _test_funding_exc()
    @eval using Fetch
    fu = Fetch.funding(exc, [d"BTC/USDT:USDT", d"ETH/USDT:USDT"]; from="2022-06-")
    @assert all(size(v)[1] > 0 for v in values(fu))
end

_test_funding() = begin
    # if one exchange does not succeeds try on other exchanges
    # until one succeeds
    for e in (:binance, :bybit)
        try
            setexchange!(e)
            _test_funding_exc()
            return true
        catch
        end
    end
    false
end

test_ohlcv() = @testset "ohlcv" begin
    @test begin
        _test_funding()
    end
end
