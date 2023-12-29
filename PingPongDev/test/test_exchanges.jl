using Test

exc_sym = :bybit
test_exch() = @test setexchange!(:bybit, sandbox=false).name == "Bybit"
_exchange() = begin
    empty!(Exchanges.exchanges)
    empty!(Exchanges.sb_exchanges)
    e = getexchange!(exc_sym, markets=:yes, cache=false, sandbox=false)
    @test nameof(e) == exc_sym
    @test exc_sym ∈ keys(ExchangeTypes.exchanges) || exc_sym ∈ keys(ExchangeTypes.sb_exchanges)
    e
end
_exchange_pairs(exc) = begin
    @test length(exc.markets) > 0
    @test length(marketsid(exc, "USDT", min_vol=10)) > 0
end

_exchange_sbox() = begin
    @assert !issandbox()
    sandbox!(flag=false)
    @assert !issandbox()
    sandbox!()
    @assert issandbox()
    ratelimit!()
end

test_exchanges() = begin
    @eval begin
        using PingPong.Exchanges: Exchanges, marketsid, sandbox!, ratelimit!, setexchange!, getexchange!, issandbox
        using PingPong.Exchanges: ExchangeTypes
        using Stubs
    end
    @testset "exchanges" failfast = true begin
        test_exch()
        e = _exchange()
        Main.e = e
        _exchange_pairs(e)
        @test _exchange_sbox()
    end
end
