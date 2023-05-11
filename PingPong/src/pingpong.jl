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
        using PingPong
        using PingPong.Exchanges
        using PingPong.Exchanges: Exchanges as exs
        using PingPong.Engine:
            Engine as egn,
            Strategies as st,
            Simulations as sim,
            SimMode as bt,
            Instances as inst,
            Collections as co,
            Executors as ect

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
    end
end

macro strategyenv!()
    quote
        using Engine
        using Engine.Strategies
        using Engine: Strategies as st
        using Engine.Instances: Instances as inst
        using Engine.Executors
        using Engine.OrderTypes

        using ExchangeTypes
        using Data
        using Data.DFUtils
        using Data.DataFrames
        using Instruments
        using Misc
        using TimeTicks
        using Lang

        $(@__MODULE__).Engine.Strategies.@interface
    end
end

macro contractsenv!()
    quote
        using Engine.Instances: PositionOpen, PositionUpdate, PositionClose
        using Engine.Instances: position
    end
end

export @environment!, @strategyenv!, @contractsenv!
