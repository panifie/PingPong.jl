using SimMode.Executors: st, Instances, OptSetup, OptRun, OptScore, Context
using SimMode.TimeTicks
using .Instances: value
using .Instances.Data: DataFrame
using .st: Strategy, Sim, SimStrategy, WarmupPeriod
using SimMode.Misc: DFT
using Base.Threads: @threads, @spawn
using SimMode.Lang: Option, splitkws
using Stats.Statistics: median
using BlackBoxOptim
import BlackBoxOptim: bboptimize
import .st: ping!

const ContextSpace = NamedTuple{(:ctx, :space),Tuple{Context,Any}}

@doc "Has to return a `Optimizations.ContextSpace` named tuple where `ctx` (`Executors.Context`) is the time period to backtest and the `space` is
either an already constructed subtype of `BlackBoxOptim.SearchSpace` or a tuple (`Symbol`, args...) for a search space pre-defined within the BBO package.
"
ping!(::Strategy, ::OptSetup) = error("not implemented")

@doc "This ping function should apply the parameters to the strategy, called before the backtest is performed. "
ping!(::Strategy, params, ::OptRun) = error("not implemented")

#TYPENUM
@doc "An optimization session stores all the evaluated parameters combinations."
struct OptSession12{S<:SimStrategy}
    s::S
    ctx::Context{Sim}
    params::Any
    results::DataFrame
    best::Ref{Any}
    function OptSession12(s::Strategy, ctx, params)
        new{typeof(s)}(s, ctx, params, DataFrame(), Ref(nothing))
    end
end

OptSession = OptSession12

include("bbopt.jl")
