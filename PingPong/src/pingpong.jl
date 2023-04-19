using Engine
using Exchanges
using Python
using Data
using Misc
using Pkg: Pkg as Pkg

include("repl.jl")

function _doinit()
    @debug "Initializing python async..."
    if "JULIA_BACKTEST_REPL" ∈ keys(ENV)
        exc = Symbol(get!(ENV, "JULIA_BACKTEST_EXC", :kucoin))
        Config(exc)
        wait(t)
        setexchange!(exc)
    end
    # default to using lmdb store for data
    @debug "Initializing LMDB zarr instance..."
    Data.zi[] = Data.zilmdb()
end

macro environment!()
    quote
        using Lang: @m_str
        using TimeTicks
        using TimeTicks: TimeTicks as tt
        using Misc
        using Misc: Misc as mi
        using Instruments
        using Instruments: Instruments as im
        using Instruments.Derivatives
        using Instruments.Derivatives: Derivatives as der
        using Data: Data as da, DFUtils as du
        using Processing: Processing as pro
        using PingPong.Exchanges
        using PingPong.Exchanges: Exchanges as exs
        using PingPong.Engine:
            Engine as egn,
            Strategies as st,
            Simulations as sim,
            SimMode as bt,
            Collections as co,
            Executors as ect
    end
end

export @environment!
