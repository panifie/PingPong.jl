using Stubs
using Test
using Random
using Lang: @m_str

_openval(s, a) = s.universe[a].instance.ohlcv.open[begin]
_closeval(s, a) = s.universe[a].instance.ohlcv.close[end]
_test_synth(s) = begin
    @test _openval(s, m"sol") == 101.0
    @test _closeval(s, m"sol") == 1753.0
    @test _openval(s, m"btc") == 99.0
    @test _closeval(s, m"btc") == 574.0
    @test _openval(s, m"eth") == 97.0
    @test _closeval(s, m"eth") == 123.0
end

_backtest_strat(sym) = begin
    s = egn.strategy(sym)
    Random.seed!(1)
    Stubs.stub!(s, trades=false)
    s
end

_trades(s) = s.universe[m"eth"].instance.history
_eq4(a, b) = isapprox(a, b; atol=1e-4)
_test_nomargin_market(s) = begin
    @test marginmode(s) == egn.NoMargin
    s.attrs[:overrides] = (; ordertype=:market)
    egn.backtest!(s)
    @test first(_trades(s)).order isa egn.MarketOrder
    @test _eq4(Cash(:USDT, 9.044), s.cash.value)
    @test s.cash_committed == Cash(:USDT, 0.0)
    @test st.trades_total(s) == 2788
    mmh = st.minmax_holdings(s)
    @test mmh.count == 1
    @test mmh.min[1] == :SOL
    @test mmh.min[2] ≈ 1.0171209856632697
    @test mmh.max[1] == :SOL
    @test mmh.max[2] ≈ 1.0171209856632697
end

_test_nomargin_gtc(s) = begin
    @test marginmode(s) == egn.NoMargin
    s.attrs[:overrides] = (; ordertype=:gtc)
    egn.backtest!(s)
    @test first(_trades(s)).order isa egn.GTCOrder
    @test _eq4(Cash(:USDT, 13611.1249), s.cash.value)
    @test _eq4(Cash(:USDT, 12624.8261), s.cash_committed)
    @test st.trades_total(s) == 4134
    mmh = st.minmax_holdings(s)
    @test mmh.count == 2
    @test mmh.min[1] == :ETH
    @test mmh.min[2] ≈ 2.1545 atol = 1e14
    @test mmh.max[1] == :BTC
    @test mmh.max[2] ≈ 121.4197 atol = 1e5
end

_test_nomargin_ioc(s) = begin
    @test marginmode(s) == egn.NoMargin
    s.attrs[:overrides] = (; ordertype=:ioc)
    egn.backtest!(s)
    @test first(_trades(s)).order isa egn.IOCOrder
    @test Cash(:USDT, 8.9480) ≈ s.cash atol = 1e-4
    @test Cash(:USDT, 0.0) ≈ s.cash_committed
    @test st.trades_total(s) == 4290
    mmh = st.minmax_holdings(s)
    @test mmh.count == 2
    @test mmh.min[1] == :ETH
    @test mmh.min[2] ≈ 261.615 atol = 1e-3
    @test mmh.max[1] == :BTC
    @test mmh.max[2] ≈ 741.876 atol = 1e-3
end

_test_nomargin_fok(s) = begin
    @test marginmode(s) == egn.NoMargin
    s.attrs[:overrides] = (; ordertype=:fok)
    # increase cash to trigger order kills
    s.config.initial_cash = 1e6
    s.config.min_size = 1e3
    egn.backtest!(s)
    @test first(_trades(s)).order isa egn.FOKOrder
    @test Cash(:USDT, 995.515) ≈ s.cash atol = 1e-3
    @test Cash(:USDT, 0.0) ≈ s.cash_committed
    @test st.trades_total(s) == 2150
    mmh = st.minmax_holdings(s)
    reset!(s, true)
    @test mmh.count == 3
    @test mmh.min[1] == :SOL
    @test mmh.min[2] ≈ 0.0 atol = 1e-8
    @test mmh.max[1] == :BTC
    @test mmh.max[2] ≈ 28422 atol = 9e-1
end

_test_margin_market(s) = begin
    @test marginmode(s) == egn.Isolated
    s.attrs[:overrides] = (; ordertype=:market)
    egn.backtest!(s)
    s
end

test_backtest() = @testset "backtest" begin
    @eval include(joinpath(@__DIR__, "env.jl"))
    s = _backtest_strat(:Example)
    @testset _test_synth(s)
    @testset _test_nomargin_market(s)
    @testset _test_nomargin_gtc(s)
    @testset _test_nomargin_ioc(s)
    @testset _test_nomargin_fok(s)
end
