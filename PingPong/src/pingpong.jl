using Engine
using Engine.Exchanges
using .Exchanges.ExchangeTypes.Python
using Engine.Data
using Engine.Misc
using .Misc: Lang
using .Misc.TimeTicks: @tf_str
using Pkg: Pkg as Pkg

include("logmacros.jl")
include("repl.jl")
include("strat.jl")

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
    if isinteractive()
        @info "Loading interactive utilities"
        @eval Main begin
            $(@__MODULE__).@environment!
            (isdefined(Main, :Revise) ? Revise.includet : include)(
                $(joinpath(@__DIR__, "dev.jl"))
            )
        end
    end
end

macro environment!()
    quote
        using PingPong
        using PingPong: PingPong as pp
        using PingPong.Exchanges
        using PingPong.Exchanges: Exchanges as exs
        using PingPong.Engine:
            OrderTypes as ot,
            Instances as inst,
            Collections as co,
            Simulations as sim,
            Strategies as st,
            Executors as ect,
            SimMode as sm,
            PaperMode as pm,
            LiveMode as lm,
            Engine as egn

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
        using Data.Cache: save_cache, load_cache
        using Processing: Processing as pro
        using Remote: Remote as rmt
        using Watchers
        using Watchers: WatchersImpls as wi

        using Random
        using Stubs
        using .inst
        using .ot
    end
end

macro strategyenv!()
    expr = quote
        __revise_mode__ = :eval
        using PingPong: PingPong as pp
        using .pp.Engine
        using .pp.Engine: Strategies as st
        using .pp.Engine.Instances: Instances as inst
        using .pp.Engine.OrderTypes: OrderTypes as ot
        using .pp.Engine.Executors: Executors as ect
        using .pp.Engine.LiveMode.Watchers: Watchers as wa
        using .pp.Engine.Processing: Processing as pc
        using .wa.WatchersImpls: WatchersImpls as wim
        using .st
        using .ect
        using .ot

        using .ot.ExchangeTypes
        using .pp.Engine.Data
        using .pp.Engine.Data.DFUtils
        using .pp.Engine.Data.DataFrames
        using .pp.Engine.Instruments
        using .pp.Engine.Misc
        using .pp.Engine.TimeTicks
        using .pp.Engine.Lang

        using .st: freecash, setattr!, attr
        using .pp.Engine.Exchanges: getexchange!, marketsid
        using .pc: resample, islast, iscomplete, isincomplete
        using .Data: propagate_ohlcv!, stub!
        using .Data.DataStructures: CircularBuffer
        using .Misc: after, before, rangeafter, rangebefore, LittleDict
        using .inst: asset, ohlcv, ohlcv_dict, raw, lastprice, bc, qc
        using .inst: takerfees, makerfees, maxfees, minfees
        using .inst: ishedged, cash, committed, instance, isdust, nondust
        using .pp.Engine.LiveMode: updated_at!
        using .Instruments: compactnum

        using .ect: OptSetup, OptRun, OptScore
        using .ect: NewTrade
        using .ect: WatchOHLCV, UpdateData, InitData
        using .ect: UpdateOrders, CancelOrders

        $(Engine.Strategies).@interface

        const EXCID = ExchangeID(isdefined(@__MODULE__, :EXC) ? EXC : Symbol())
        if !isdefined(@__MODULE__, :MARGIN)
            const MARGIN = NoMargin
        end
        const S{M} = Strategy{M,nameof(@__MODULE__()),typeof(EXCID),MARGIN}
        const SC{E,M,R} = Strategy{M,nameof(@__MODULE__()),E,R}
    end
    esc(expr)
end

macro contractsenv!()
    quote
        using .inst: PositionOpen, PositionUpdate, PositionClose
        using .inst: position, leverage, PositionSide
        using .ect: UpdateLeverage, UpdateMargin, UpdatePositions

        using .inst: ishedged, margin, additional, leverage, mmr, maintenance
        using .inst: price, entryprice, liqprice, posside, collateral
    end
end

macro optenv!()
    quote
        using Engine.SimMode: SimMode as sm
        using Stats: Stats as stats
    end
end

export ExchangeID, @tf_str, @strategyenv!, @contractsenv!, @optenv!
export Isolated, NoMargin
