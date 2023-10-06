using Stubs
using Test
using Random
using Lang: @m_str

openval(s, a) = s.universe[a].instance.ohlcv.open[begin]
closeval(s, a) = s.universe[a].instance.ohlcv.close[end]
test_synth(s) = begin
    @test openval(s, m"sol") == 101.0
    @test closeval(s, m"sol") == 1753.0
    @test openval(s, m"btc") == 99.0
    @test closeval(s, m"btc") == 574.0
    @test openval(s, m"eth") == 97.0
    @test closeval(s, m"eth") == 123.0
end

trades(s) = s.universe[m"eth"].instance.history
eq4(a, b) = isapprox(a, b; atol=1e-4)
test_nomargin_market(s) = begin
    @test marginmode(s) isa egn.NoMargin
    s.attrs[:overrides] = (; ordertype=:market)
    egn.start!(s)
    @test first(trades(s)).order isa egn.MarketOrder
    @test eq4(Cash(:USDT, 9.7334), s.cash.value)
    @test eq4(Cash(:USDT, 0.0), s.cash_committed)
    @test st.trades_count(s) == 77
    mmh = st.minmax_holdings(s)
    @test mmh.count == 1
    @test mmh.min[1] == :ETH
    @test mmh.min[2] ≈ 335.2945 atol = 1e-4
    @test mmh.max[1] == :ETH
    @test mmh.max[2] ≈ 335.2945 atol = 1e-4
end

test_nomargin_gtc(s) = begin
    @test marginmode(s) isa egn.NoMargin
    s.attrs[:overrides] = (; ordertype=:gtc)
    egn.start!(s)
    @test first(trades(s)).order isa egn.GTCOrder
    @test eq4(Cash(:USDT, 9.4619), s.cash.value)
    @test eq4(Cash(:USDT, 0.0), s.cash_committed)
    @test st.trades_count(s) == 130
    mmh = st.minmax_holdings(s)
    @test mmh.count == 1
    @test mmh.min[1] == :ETH
    @test mmh.min[2] ≈ 275.3880 atol = 1e3
    @test mmh.max[1] == :ETH
    @test mmh.max[2] ≈ 275.3880 atol = 1e3
end

test_nomargin_ioc(s) = begin
    @test marginmode(s) isa egn.NoMargin
    s.attrs[:overrides] = (; ordertype=:ioc)
    egn.start!(s)
    @test first(trades(s)).order isa egn.IOCOrder
    @test Cash(:USDT, 9.359) ≈ s.cash atol = 1e-3
    @test Cash(:USDT, 0.0) ≈ s.cash_committed
    @test st.trades_count(s) == 92
    mmh = st.minmax_holdings(s)
    @test mmh.count == 1
    @test mmh.min[1] == :ETH
    @test mmh.min[2] ≈ 453.41604 atol = 1e-1
    @test mmh.max[1] == :ETH
    @test mmh.max[2] ≈ 453.41604 atol = 1e-1
end

test_nomargin_fok(s) = begin
    @test marginmode(s) isa egn.NoMargin
    s.attrs[:overrides] = (; ordertype=:fok)
    # increase cash to trigger order kills
    s.config.initial_cash = 1e6
    s.config.min_size = 1e3
    egn.start!(s)
    @test first(trades(s)).order isa egn.FOKOrder
    @test Cash(:USDT, 917.976) ≈ s.cash atol = 1e-3
    @test Cash(:USDT, 0.0) ≈ s.cash_committed atol = 1e-7
    @test st.trades_count(s) == 677
    mmh = st.minmax_holdings(s)
    reset!(s, true)
    @test mmh.count == 1
    @test mmh.min[1] == :ETH
    @test mmh.min[2] ≈ 798414.27082 atol = 1e-4
    @test mmh.max[1] == :ETH
    @test mmh.max[2] ≈ 798414.27082 atol = 9e-1
end

function margin_overrides(ot=:market)
    (;
        ordertype=ot,
        def_lev=10.0,
        longdiff=1.02,
        buydiff=1.01,
        selldiff=1.012,
        long_k=0.02,
        short_k=0.02,
        per_order_leverage=false,
        verbose=false,
    )
end

test_margin_market(s) = begin
    @test marginmode(s) isa egn.Isolated
    s.attrs[:overrides] = margin_overrides(:market)
    egn.start!(s)
    @test first(trades(s)).order isa ect.AnyMarketOrder
    @test Cash(:USDT, 0.046) ≈ s.cash atol = 1e-3
    @test Cash(:USDT, 0.0) ≈ s.cash_committed
    @test st.trades_count(s) == 252
    mmh = st.minmax_holdings(s)
    @test mmh.count == 0
    @test mmh.min[1] == :USDT
    @test mmh.min[2] ≈ Inf atol = 1e-3
    @test mmh.max[1] == :USDT
    @test mmh.max[2] ≈ 0.0 atol = 1e-3
end

test_margin_gtc(s) = begin
    @test marginmode(s) isa egn.Isolated
    s.attrs[:overrides] = margin_overrides(:gtc)
    egn.start!(s)
    @test first(trades(s)).order isa ect.AnyGTCOrder
    @test Cash(:USDT, 0.705) ≈ s.cash atol = 1e-3
    @test Cash(:USDT, 0.0) ≈ s.cash_committed
    @test st.trades_count(s) == 558
    mmh = st.minmax_holdings(s)
    reset!(s, true)
    @test mmh.count == 0
    @test mmh.min[1] == :USDT
    @test mmh.min[2] ≈ Inf atol = 1e-3
    @test mmh.max[1] == :USDT
    @test mmh.max[2] ≈ 0.0 atol = 1e-3
end

test_margin_fok(s) = begin
    @test marginmode(s) isa egn.Isolated
    s.attrs[:overrides] = margin_overrides(:fok)
    # increase cash to trigger order kills
    s.config.initial_cash = 1e6
    s.config.min_size = 1e3
    egn.start!(s)
    @test first(trades(s)).order isa ect.AnyFOKOrder
    @test Cash(:USDT, -0.357) ≈ s.cash atol = 1e-3
    @test Cash(:USDT, 0.0) ≈ s.cash_committed
    @test st.trades_count(s) == 1112
    mmh = st.minmax_holdings(s)
    reset!(s, true)
    @test mmh.count == 0
    @test mmh.min[1] == :USDT
    @test mmh.min[2] ≈ Inf atol = 1e-3
    @test mmh.max[1] == :USDT
    @test mmh.max[2] ≈ 0.0 atol = 1e-3
end

test_margin_ioc(s) = begin
    @test marginmode(s) isa egn.Isolated
    s.attrs[:overrides] = margin_overrides(:ioc)
    # increase cash to trigger order kills
    s.config.initial_cash = 1e6
    s.config.min_size = 1e3
    egn.start!(s)
    @test first(trades(s)).order isa ect.AnyIOCOrder
    @test Cash(:USDT, -0.357) ≈ s.cash atol = 1e-3
    @test Cash(:USDT, 0.0) ≈ s.cash_committed
    @test st.trades_count(s) == 1112
    mmh = st.minmax_holdings(s)
    reset!(s, true)
    @test mmh.count == 0
    @test mmh.min[1] == :USDT
    @test mmh.min[2] ≈ Inf atol = 1e-3
    @test mmh.max[1] == :USDT
    @test mmh.max[2] ≈ 0.0 atol = 1e-3
end

test_backtest() = @testset "backtest" begin
    @eval include(joinpath(@__DIR__, "env.jl"))
    s = backtest_strat(:Example)
    @testset test_synth(s)
    @testset test_nomargin_market(s)
    @testset test_nomargin_gtc(s)
    @testset test_nomargin_ioc(s)
    @testset test_nomargin_fok(s)

    s = backtest_strat(:ExampleMargin)
    @testset test_margin_market(s)
    @testset test_margin_gtc(s)
    @testset test_margin_ioc(s)
    @testset test_margin_fok(s)
end
