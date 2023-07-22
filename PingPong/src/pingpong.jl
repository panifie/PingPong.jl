using Engine
using Engine.Exchanges
using .Exchanges.Python
using Engine.Data
using Engine.Misc
using .Misc: Lang
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
        using PingPong: PingPong as pp
        using PingPong.Exchanges
        using PingPong.Exchanges: Exchanges as exs
        using PingPong.Engine:
            Engine as egn,
            Strategies as st,
            Simulations as sim,
            SimMode as sm,
            PaperMode as pm,
            LiveMode as lm,
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
        using PingPong: PingPong as pp
        using .pp.Engine
        using .pp.Engine.Strategies
        using .pp.Engine: Strategies as st
        using .pp.Engine.Instances: Instances as inst
        using .pp.Engine.Executors
        using .pp.Engine.OrderTypes

        using .pp.Engine.OrderTypes.ExchangeTypes
        using .pp.Engine.Data
        using .pp.Engine.Data.DFUtils
        using .pp.Engine.Data.DataFrames
        using .pp.Engine.Instruments
        using .pp.Engine.Misc
        using .pp.Engine.TimeTicks
        using .pp.Engine.Lang

        using .st: freecash, setattr!, attr
        using .pp.Engine.Exchanges: getexchange!
        using .Data: propagate_ohlcv!
        using .Misc: after, before, rangeafter, rangebefore
        using .inst: ohlcv

        const $(esc(:ect)) = PingPong.Engine.Executors

        $(@__MODULE__).Engine.Strategies.@interface
    end
end

macro contractsenv!()
    quote
        using Engine.Instances: PositionOpen, PositionUpdate, PositionClose
        using Engine.Instances: position, leverage, PositionSide
    end
end

macro optenv!()
    quote
        using Engine.SimMode: SimMode as sm
        using Stats: Stats as stats
    end
end

export @environment!, @strategyenv!, @contractsenv!, @optenv!
