pair = "BTC/USDT"
n_pairs = ["BTC/USDT", "ADA/USDT"]
timeframe = "1d"

function _test_funding_exc()
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
