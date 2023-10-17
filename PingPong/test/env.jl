using PingPong
using Stubs
using Random
@environment!
const ot = ect.OrderTypes
using OrderTypes
using Instances

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
        btc = let s = st.strategy!(:Example, cfg)
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

function loadstrat!(strat=:Example; stub=true, mode=Sim(), kwargs...)
    @eval Main begin
        GC.enable(false)
        try
            global s, ai
            if isdefined(Main, :s) && s isa st.Strategy{<:Union{Paper,Live}}
                @async lm.stop_all_tasks(s)
            end
            s = st.strategy($(QuoteNode(strat)); mode=$mode, $(kwargs)...)
            st.issim(s) &&
                fill!(s.universe, s.timeframe, config.timeframes[(begin + 1):end]...)
            execmode(s) == Sim() && $stub && dostub!()
            st.default!(s)
            ai = try
                first(s.universe)
            catch
            end
            s
        finally
            GC.enable(true)
            GC.gc()
        end
    end
end
