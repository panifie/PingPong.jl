using Test

function _test_markets(name=:binance, pair="BTC/USDT")
    exc = getexchange!(name)
    @test exc isa Exchanges.CcxtExchange
    @test nameof(exc) == name
    @test length(exc.markets) > 0
    # without cache
    @test_nowarn loadmarkets!(exc; cache=false)
    @test pair ∈ keys(exc.markets)
    empty!(exchanges)
    exc = getexchange!(name)
    # with cache
    @test_nowarn loadmarkets!(exc; cache=true)
    @test pair ∈ keys(exc.markets)
end

test_markets() = @testset "markets" begin
    @eval using .PingPong.Exchanges: loadmarkets!, exchanges, getexchange!, Exchanges
    _test_markets()
end
