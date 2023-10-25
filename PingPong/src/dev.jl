global s, ai, e

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

function symnames(s=s)
    String[lowercase(v) for v in (string.(getproperty.(st.assets(s), :bc)))]
end

function default_loader()
    @eval using Scrapers: Scrapers as scr
    (pairs, qc) -> scr.BinanceData.binanceload(pairs; quote_currency=qc)
end

function dostub!(pairs=symnames(); loader=default_loader())
    isempty(pairs) && return nothing
    @eval let
        GC.gc()
        qc = string(nameof(s.cash))
        data = $loader($pairs, qc)
        egn.stub!(s.universe, data)
    end
end

function loadstrat!(strat=:Example; stub=true, mode=Sim(), kwargs...)
    @eval Main begin
        GC.enable(false)
        try
            global s, ai
            if isdefined(Main, :s) && s isa st.Strategy{<:Union{Paper,Live}}
                try
                    exs.ExchangeTypes._closeall()
                    @async lm.stop_all_tasks(s)
                catch this_err
                    @warn this_err
                end
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

if isdefined(Main, :Revise)
    Revise.revise(s::st.Strategy) =
        if endswith(s.path, "toml")
            prev = Base.active_project()
            try
                Pkg.activate(s.path)
                Revise.revise(s.self)
            finally
                Pkg.activate(prev)
            end
        else
            Revise.revise(s.self)
        end
end
