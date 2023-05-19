using PingPong
using Stubs
@environment!

backtest_strat(sym) = begin
    s = egn.strategy(sym)
    Random.seed!(1)
    Stubs.stub!(s; trades=false)
    s
end

function loadbtc()
    @eval begin
        betc = let s = st.strategy!(:Example, cfg)
            fill!(s.universe, config.timeframes[(begin + 1):end]...)
            s.universe[d"BTC/USDT:USDT"].instance[1]
        end
    end
end

function dostub!(pairs=["eth", "btc", "sol"])
    @eval using Scrapers: Scrapers as scr
    @eval let
        GC.gc()
        qc = string(nameof(s.cash))
        data = scr.BinanceData.binanceload($pairs; quote_currency=qc)
        egn.stub!(s.universe, data)
    end
end
