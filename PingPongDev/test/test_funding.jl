using PingPongDev.PingPong.Engine.Instruments.Derivatives: @d_str
using PingPongDev.PingPong.Engine.TimeTicks: @dtr_str, @dt_str

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
    @test v isa AbstractFloat
end

_test_funding(e) = begin
    exc = getexchange!(e)
    _test_funding_history(exc)
end

test_funding() = begin
    @eval begin
        using .PingPong.Engine.LiveMode.Watchers.Fetch
        using .PingPong.Engine.TimeTicks
        using .PingPong.Engine.Data
        using .PingPong.Engine.Exchanges: getexchange!
        using .PingPong.Engine.Misc
    end
    @testset "funding" begin
        _test_funding(EXCHANGE)
        _test_funding(EXCHANGE_MM)
        _test_funding(:phemex)
        _test_funding(:phemex)
        _test_funding_rate(EXCHANGE)
        _test_funding_rate(EXCHANGE_MM)
        _test_funding_rate(:phemex)
        _test_funding_rate(:phemex)
    end
end
