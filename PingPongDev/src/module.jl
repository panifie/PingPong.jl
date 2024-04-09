using Reexport
@reexport using PingPong
using PingPong.Engine: Strategies as st, Engine as egn
using PingPong: @environment!
using PingPong.Exchanges.Python: Python
using .Python.PythonCall.GC: enable as gc_enable, disable as gc_disable
using Random
using Stubs

using PingPong.Misc

global s, ai, e

function backtest_strat(sym; mode=Sim(), config_attrs=(;), kwargs...)
    @info "btstrat: newconfig"
    cfg = Config(sym; mode, kwargs...)
    for (k, v) in pairs(config_attrs)
        cfg.attrs[k] = v
    end
    @info "btstrat: strategy!" cfg.exchange
    s = egn.strategy!(sym, cfg)
    Random.seed!(1)
    mode == Sim() && begin
        @info "btstrat: stub!"
        Stubs.stub!(s; trades=false)
    end
    s
end

function symnames(s=Main.s)
    String[lowercase(v) for v in (string.(getproperty.(st.assets(s), :bc)))]
end

function default_loader(load_func=nothing)
    @eval Main begin
        using Scrapers: Scrapers as scr
        let f = @something $(load_func) scr.BinanceData.binanceload
            (pairs, qc) -> f(pairs; quote_currency=qc)
        end
    end
end

function dostub!(pairs=symnames(); s=s, loader=default_loader())
    isempty(pairs) && return nothing
    @eval Main let
        this_s = $s
        qc = string(nameof(this_s.cash))
        data = $(loader)($(pairs), qc)
        egn.stub!(this_s.universe, data)
    end
end

function loadstrat!(strat=:Example, bind=:s; stub=true, mode=Sim(), kwargs...)
    @eval Main begin
        GC.enable(false)
        $gc_disable()
        try
            global $bind, ai
            if isdefined(Main, $(QuoteNode(bind))) &&
               $bind isa st.Strategy{<:Union{Paper,Live}}
                try
                    exs.ExchangeTypes._closeall()
                    @async lm.stop_all_tasks($bind)
                catch this_err
                    @warn this_err
                end
            end
            $bind = st.strategy($(QuoteNode(strat)); mode=$mode, $(kwargs)...)
            st.issim($bind) && fill!(
                $bind.universe,
                $bind.timeframe,
                $bind.config.timeframes[(begin+1):end]...,
            )
            execmode($bind) == Sim() && $stub  && dostub!(symnames($bind); s=$bind)
            st.default!($bind)
            ai = try
                first($bind.universe)
            catch
            end
            $bind
        finally
            $gc_enable()
            GC.enable(true)
            GC.gc()
        end
    end
end

if isdefined(Main, :Revise)
    using Pkg: Pkg
    Main.Revise.revise(s::st.Strategy) =
        if endswith(s.path, "toml")
            prev = Base.active_project()
            try
                Pkg.activate(s.path)
                Main.Revise.revise(s.self)
            finally
                Pkg.activate(prev)
            end
        else
            Main.Revise.revise(s.self)
        end
end

""" Required when interrupting a function in the repl (CTRL-C) and causes the python event loop to terminate.

Requires strategy to be reloaded.
"""
resetenv!() = begin
    @eval begin
        @environment!
        using .Python
    end
    try
        Python.py_start_loop()
    catch
    end
    exs.ExchangeTypes._closeall()
    Watchers._closeall()
end

togglewatch!(s, enable=true) = begin
    for name in (:positions, :orders, :mytrades, :tickers)
        s[Symbol(:is_watch_, name)] = enable
    end
    lm.stop_all_tasks(s)
end

export backtest_strat, loadstrat!, symnames, default_loader
export @environment!, dostub!, resetenv!, togglewatch!
