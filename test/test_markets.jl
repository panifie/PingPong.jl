using Test

function _test_markets(name=:binance, pair="BTC/USDT")
    @eval using PingPong.Exchanges: loadmarkets!, exchanges
    exc = getexchange!(name)
    # without cache
    loadmarkets!(exc, cache=false)
    @assert pair ∈ keys(exc.markets)
    empty!(exchanges)
    exc = getexchange!(name)
    # with cache
    loadmarkets!(exc, cache=true)
    @assert pair ∈ keys(exc.markets)
end

test_markets() = @testset "markets" begin
    @test begin
        _test_markets()
    end
end
