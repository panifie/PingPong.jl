using Test

test_exch() = Symbol(lowercase(setexchange!(EXCHANGE, sandbox=false).name)) == EXCHANGE
_exchange() = begin
    empty!(Exchanges.exchanges)
    empty!(Exchanges.sb_exchanges)
    e = getexchange!(EXCHANGE, markets=:yes, cache=false, sandbox=false)
    @test nameof(e) == EXCHANGE
    @test (EXCHANGE, "") ∈ keys(ExchangeTypes.exchanges) || (exc_sym, "") ∈ keys(ExchangeTypes.sb_exchanges)
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

_exchanges_test_env() = begin
    @eval begin
        using .PingPong.Exchanges: Exchanges, marketsid, sandbox!, ratelimit!, setexchange!, getexchange!, issandbox
        using .PingPong.Exchanges: ExchangeTypes
        using PingPongDev.Stubs
    end
end

_do_test_exchanges() = begin
    @test test_exch()
    e = _exchange()
    _exchange_pairs(e)
    @test _exchange_sbox()
end

test_exchanges() = begin
    _exchanges_test_env()
    @testset "exchanges" failfast = FAILFAST _do_test_exchanges()
end
