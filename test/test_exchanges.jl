using Test

exc_sym = :kucoin
test_exch() = @test setexchange!(:kucoin).name == "KuCoin"
_exchange_id() = begin
    getexchange!(exc_sym)
    exc_sym ∈ keys(ExchangeTypes.exchanges)
end
_exchange_pairs() = begin
    @eval begin
        using JuBot.Exchanges: get_pairs
        const getpairs = JuBot.Exchanges.get_pairs
        prs = getpairs()
    end
    length(prs) > 0
end

_exchange_sbox() = begin
    @eval using Jubot.Exchanges
    @assert !issandbox()
    sandbox!()
    @assert issandbox()
    sandbox!(flag=false)
    @assert !issandbox()
    ratelimit!()
end


test_exchanges() = @testset "exchanges" begin
    test_exch()
    @test _exchange_id()
    @test _exchange_pairs()
    @test _exchange_sbox()
end
