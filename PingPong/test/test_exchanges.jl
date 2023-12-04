using Test

exc_sym = :kucoin
test_exch() = @test setexchange!(:kucoin, sandbox=false).name == "KuCoin"
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

test_exchanges() = @testset "exchanges" failfast=true begin
    @eval begin
        using PingPong.Exchanges: marketsid, sandbox!, ratelimit!
    end
    test_exch()
    e = _exchange()
    _exchange_pairs(e)
    @test _exchange_sbox()
end
