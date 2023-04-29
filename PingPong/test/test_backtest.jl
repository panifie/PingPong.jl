using Test

_eq4(a, b) = isapprox(a, b; atol=1e-5)
_test_nomargin() = begin
    s = egn.strategy(:Example)
    Random.seed!(1)
    Stubs.stub!(s)
    egn.backtest!(s)
    @test marginmode(s) == NoMargin
    @test _eq4(Cash(:USDT, 9.8795), s.cash.value)
    @test s.cash_committed == Cash(:USDT, 0.0)
    @test st.trades_total(s) == 2951
    mmh = st.minmax_holdings(s)
    @test mmh.count == 0
    @test mmh.min == (:USDT, Inf)
    @test mmh.max == (:USDT, 0.0)
end

test_backtest() = @testset "backtest" begin
    @eval include(joinpath(@__DIR__, "env.jl"))
    @eval begin
        using Stubs
        using Random
    end
    @testset _test_nomargin()
end
