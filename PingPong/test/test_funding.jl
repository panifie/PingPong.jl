function _test_funding_history(exc)
    assets = [d"BTC/USDT:USDT", d"ETH/USDT:USDT"]
    fu = Fetch.funding_history(exc, assets; from=dtr"2022-06..".start, to=dtr"..2023-".stop)
    @info "TEST: funding " exc = nameof(exc)
    for (n, (k, v)) in enumerate(fu)
        @test k == assets[n]
        @test Data.nrow(v) > 0
        @test first(v.timestamp) >= dt"2022-06"
        @test Data.contiguous_ts(v.timestamp, "8h")
    end
    true
end

function _test_funding_rate(e)
    exc = getexchange!(e)
    v = funding_rate(exc, "BTC/USDT:USDT")
    @test v isa Number
    @test v >= ZERO
end

_test_funding(e) = begin
    exc = getexchange!(e)
    _test_funding_history(exc)
end

test_funding() = begin
    @eval begin
        using Fetch
        using TimeTicks
        using Data
    end
    @testset "funding" begin
        _test_funding(:binance)
        _test_funding(:bybit)
        _test_funding(:phemex)
        _test_funding_rate(:binance)
        _test_funding_rate(:bybit)
        _test_funding_rate(:phemex)
    end
end
