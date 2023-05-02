using Stubs
using Test
using Random
using Lang: @m_str

_openval(s, a) = s.universe[a].instance.ohlcv.open[begin]
_closeval(s, a) = s.universe[a].instance.ohlcv.close[end]
_test_synth(s) = begin
    @test _openval(s, m"sol") == 101.0
    @test _closeval(s, m"sol") == 1754.0
    @test _openval(s, m"btc") == 99.0
    @test _closeval(s, m"btc") == 580.0
    @test _openval(s, m"eth") == 97.0
    @test _closeval(s, m"eth") == 129.0
end

_backtest_strat(sym) = begin
    s = egn.strategy(sym)
    Random.seed!(1)
    Stubs.stub!(s)
    s
end

_eq4(a, b) = isapprox(a, b; atol=1e-4)
_test_nomargin_market(s) = begin
    s.attrs[:ordertype] = :market
    egn.backtest!(s)
    @test marginmode(s) == NoMargin
    @test _eq4(Cash(:USDT, 9.5524), s.cash.value)
    @test s.cash_committed == Cash(:USDT, 0.0)
    @test st.trades_total(s) == 3658
    mmh = st.minmax_holdings(s)
    @test mmh.count == 1
    @test mmh.min[1] == :BTC
    @test mmh.min[2] ≈ 8.236349534060919
    @test mmh.max[1] == :BTC
    @test mmh.max[2] ≈ 8.236349534060919
end

_test_nomargin_gtc(s) = begin
    s.attrs[:ordertype] = :gtc
    egn.backtest!(s)
    s
end

test_backtest() = @testset "backtest" begin
    @eval include(joinpath(@__DIR__, "env.jl"))
    s = _backtest_strat(:Example)
    # @testset _test_synth(s)
    # @testset _test_nomargin_market(s)
    @testset _test_nomargin_gtc(s)
end
