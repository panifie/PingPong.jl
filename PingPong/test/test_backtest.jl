using Test

_openval(s, a) = s.universe[a].instance.ohlcv.open[begin]
_closeval(s, a) = s.universe[a].instance.ohlcv.close[end]
_eq4(a, b) = isapprox(a, b; atol=1e-4)
_test_nomargin() = begin
    s = egn.strategy(:Example)
    Random.seed!(1)
    Stubs.stub!(s)
    egn.backtest!(s)
    @test _openval(s, m"sol") == 101.0
    @test _closeval(s, m"sol") == 1754.0
    @test _openval(s, m"btc") == 99.0
    @test _closeval(s, m"btc") == 580.0
    @test _openval(s, m"eth") == 97.0
    @test _closeval(s, m"eth") == 129.0
    @test marginmode(s) == NoMargin
    @test _eq4(Cash(:USDT, 9.7730), s.cash.value)
    @test s.cash_committed == Cash(:USDT, 0.0)
    @test st.trades_total(s) == 2938
    mmh = st.minmax_holdings(s)
    @test mmh.count == 1
    @test mmh.min[1] == :SOL
    @test mmh.min[2] ≈ 1.0694938310898965
    @test mmh.max[1] == :SOL
    @test mmh.max[2] ≈ 1.0694938310898965
end

test_backtest() = @testset "backtest" begin
    @eval include(joinpath(@__DIR__, "env.jl"))
    @eval begin
        using Stubs
        using Random
        using Lang: @m_str
    end
    @testset _test_nomargin()
end
