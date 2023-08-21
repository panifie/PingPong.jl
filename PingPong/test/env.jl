using PingPong
using Stubs
using Random
@environment!
const ot = ect.OrderTypes
using OrderTypes

function backtest_strat(sym; mode=Sim(), config_attrs=(;), kwargs...)
    cfg = Config(sym; mode, kwargs...)
    for (k, v) in pairs(config_attrs)
        cfg.attrs[k] = v
    end
    s = egn.strategy!(sym, cfg)
    Random.seed!(1)
    mode == Sim() && Stubs.stub!(s; trades=false)
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

function symnames(s=s)
    lowercase.(string.(getproperty.(st.assets(s), :bc)))
end

function dostub!(pairs=symnames())
    @eval using Scrapers: Scrapers as scr
    @eval let
        GC.gc()
        qc = string(nameof(s.cash))
        data = scr.BinanceData.binanceload($pairs; quote_currency=qc)
        egn.stub!(s.universe, data)
    end
end
