using Reexport
using Pkg: Pkg
@reexport using PingPong
using PingPong.Engine: Strategies as st, Engine as egn
using PingPong: @environment!
using PingPong.Exchanges.Python: Python
using Random
using Stubs
using PingPong.Misc
using .Misc.Lang

import .egn.Data: stub!

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

function default_data_loader(load_func=nothing)
    @eval Main begin
        using Scrapers: Scrapers as scr
        let f = @something $(load_func) scr.BinanceData.binanceload
            (pairs, qc; kwargs...) -> f(pairs; quote_currency=qc, kwargs...)
        end
    end
end

function avl_gigabytes(reserved=1)
    (round(Int, Base.Sys.free_memory() / 1e9, RoundDown) - reserved) * 1e9
end

function safe_from(s, pairs)
    tf = s.timeframe
    len_per_pair = round(
        Int, avl_gigabytes() / length(pairs) / sizeof(egn.Data.Candle{DFT}) / 2
    )
    egn.now() - len_per_pair * tf
end

function stub!(
    pairs=symnames(); s=Main.s, loader=default_data_loader(), safeoom=length(pairs) > 10
)
    isempty(pairs) && return nothing
    GC.gc()
    @eval Main let
        this_s = $s
        qc = string(nameof(this_s.cash))
        kwargs = $safeoom ? (; from=$safe_from(this_s, $pairs)) : ()
        data = $(loader)($(pairs), qc; kwargs...)
        t = Threads.@spawn egn.stub!(this_s.universe, data)
        errormonitor(t)
        while !istaskdone(t)
            GC.gc(true)
            sleep(1)
        end
    end
end

function loadstrat!(strat=:Example, bind=:s; load=false, stub=false, mode=Sim(), kwargs...)
    @eval Main begin
        global $bind, ai
        if isdefined(Main, $(QuoteNode(bind))) && $bind isa st.Strategy{<:Union{Paper,Live}}
            try
                exs.ExchangeTypes._closeall()
                @async lm.stop_all_tasks($bind)
            catch exception
                @warn "stop failed" exception
            end
        end
        $bind = st.strategy($(QuoteNode(strat)); mode=$mode, $(kwargs)...)
        if st.issim($bind)
            if $load
                fill!(
                    $bind.universe,
                    $bind.timeframe,
                    $bind.config.timeframes[(begin + 1):end]...,
                )
            end
            if $stub
                pairs = symnames($bind)
                stub!(pairs; s=$bind)
            end
        end
        st.default!($bind)
        ai = try
            first($bind.universe)
        catch
        end
        $bind
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
        Python.py_stop_loop()
    finally
        Python.py_start_loop()
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

using PingPong: _activate_and_import
tools!() = _activate_and_import(:StrategyTools, :stt)

export backtest_strat, loadstrat!, symnames, default_data_loader
export @environment!, stub!, resetenv!, togglewatch!, tools!
