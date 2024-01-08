using PingPongDev.Stubs
using Test
using .PingPong.Engine.Simulations.Random
using PingPongDev.PingPong.Engine.Lang: @m_str

openval(s, a) = s.universe[a].ohlcv.open[begin]
closeval(s, a) = s.universe[a].ohlcv.close[end]
test_synth(s) = begin
    @test openval(s, m"sol") == 101.0
    @test closeval(s, m"sol") == 1753.0
    @test openval(s, m"eth") == 99.0
    @test closeval(s, m"eth") == 574.0
    @test openval(s, m"btc") == 97.0
    @test closeval(s, m"btc") == 123.0
end

_ai_trades(s) = s[m"eth"].history
eq1(a, b) = isapprox(a, b; atol=1e-1)
test_nomargin_market(s) = begin
    @test egn.marginmode(s) isa egn.NoMargin
    s.attrs[:overrides] = (; ordertype=:market)
    egn.start!(s)
    @test first(_ai_trades(s)).order isa egn.MarketOrder
    @info "TEST: " s.cash.value
    @test eq1(Cash(:USDT, 9.12134), s.cash.value)
    @test eq1(Cash(:USDT, 0.0), s.cash_committed)
    @test st.trades_count(s) == 5109
    mmh = st.minmax_holdings(s)
    @test mmh.count == 1
    @test mmh.min[1] == :BTC
    @test mmh.min[2] ≈ 0.9704 atol = 1e-4
    @test mmh.max[1] == :BTC
    @test mmh.max[2] ≈ 0.9704 atol = 1e-4
end

test_nomargin_gtc(s) = begin
    @test marginmode(s) isa egn.NoMargin
    s.attrs[:overrides] = (; ordertype=:gtc)
    egn.start!(s)
    @test first(_ai_trades(s)).order isa egn.GTCOrder
    @info "TEST: " s.cash.value
    @test eq1(Cash(:USDT, 7615.8), s.cash.value)
    @test eq1(Cash(:USDT, 0.0), s.cash_committed)
    @test st.trades_count(s) == 10105
    mmh = st.minmax_holdings(s)
    @test mmh.count == 0
    @test mmh.min[1] == :USDT
    @test mmh.min[2] ≈ Inf atol = 1e3
    @test mmh.max[1] == :USDT
    @test mmh.max[2] ≈ 0 atol = 1e3
end

test_nomargin_ioc(s) = begin
    @test marginmode(s) isa egn.NoMargin
    s.attrs[:overrides] = (; ordertype=:ioc)
    egn.start!(s)
    @test first(_ai_trades(s)).order isa egn.IOCOrder
    @info "TEST: " s.cash.value
    @test Cash(:USDT, 79514.0133) ≈ s.cash atol = 1
    @info "TEST: " s.cash_committed.value
    @test Cash(:USDT, -0.4e-7) ≈ s.cash_committed atol = 1e-6
    @test st.trades_count(s) == 8318
    mmh = st.minmax_holdings(s)
    @test mmh.count == 1
    @test mmh.min[1] == :ETH
    @test mmh.min[2] ≈ 6874.15118 atol = 1e-1
    @test mmh.max[1] == :ETH
    @test mmh.max[2] ≈ 6874.15118 atol = 1e-1
end

test_nomargin_fok(s) = begin
    @test marginmode(s) isa egn.NoMargin
    s.attrs[:overrides] = (; ordertype=:fok)
    # increase cash to trigger order kills
    s.config.initial_cash = 1e6
    s.config.min_size = 1e3
    egn.start!(s)
    @test first(_ai_trades(s)).order isa egn.FOKOrder
    @test Cash(:USDT, 958.192) ≈ s.cash atol = 1e-1
    @test Cash(:USDT, 0.0) ≈ s.cash_committed atol = 1e-7
    @test st.trades_count(s) == 824
    mmh = st.minmax_holdings(s)
    reset!(s, true)
    @test mmh.count == 1
    @test mmh.min[1] == :ETH
    @test mmh.min[2] ≈ 2.65385492016e6 atol = 1e2
    @test mmh.max[1] == :ETH
    @test mmh.max[2] ≈ 2.65385492016e6 atol = 1e2
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
    @test first(_ai_trades(s)).order isa ect.AnyMarketOrder
    @test Cash(:USDT, 0.959) ≈ s.cash atol = 1e-3
    @test Cash(:USDT, 0.364) ≈ s.cash_committed atol = 1e-1
    @test st.trades_count(s) == 405
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
    @test first(_ai_trades(s)).order isa ect.AnyGTCOrder
    @test Cash(:USDT, 0.992) ≈ s.cash atol = 1e-3
    @test Cash(:USDT, 0.148) ≈ s.cash_committed atol = 1e-1
    @test st.trades_count(s) == 588
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
    @test first(_ai_trades(s)).order isa ect.AnyFOKOrder
    @test Cash(:USDT, 1276.0) ≈ s.cash atol = 1e1
    @test Cash(:USDT, 1275.0) ≈ s.cash_committed atol = 1e1
    @test st.trades_count(s) == 2822
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
    @test first(_ai_trades(s)).order isa ect.AnyIOCOrder
    @test Cash(:USDT, 743.104) ≈ s.cash atol = 1e-3
    @test Cash(:USDT, 743.032) ≈ s.cash_committed atol = 1e-1
    @test st.trades_count(s) == 2070
    mmh = st.minmax_holdings(s)
    reset!(s, true)
    @test mmh.count == 0
    @test mmh.min[1] == :USDT
    @test mmh.min[2] ≈ Inf atol = 1e-3
    @test mmh.max[1] == :USDT
    @test mmh.max[2] ≈ 0.0 atol = 1e-3
end

_nomargin_backtest_tests(s) = begin
    @testset test_synth(s)
    @testset test_nomargin_market(s)
    @testset test_nomargin_gtc(s)
    @testset test_nomargin_ioc(s)
    @testset test_nomargin_fok(s)
end

_margin_backtest_tests(s) = begin
    @testset test_margin_market(s)
    @testset test_margin_gtc(s)
    @testset test_margin_ioc(s)
    @testset test_margin_fok(s)
end

test_backtest() = begin
    @eval begin
        using PingPongDev.PingPong.Engine: Engine as egn
        using .egn.Instruments: Cash
        PingPong.@environment!
        using .PingPong.Engine.Strategies: reset!
    end
    @testset failfast = FAILFAST "backtest" begin
        s = backtest_strat(:Example)
        invokelatest(_nomargin_backtest_tests, s)

        s = backtest_strat(:ExampleMargin)
        invokelatest(_margin_backtest_tests, s)
    end
end
