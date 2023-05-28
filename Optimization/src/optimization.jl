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
struct OptSession15{S<:SimStrategy,N}
    s::S
    ctx::Context{Sim}
    params::Any
    results::DataFrame
    best::Ref{Any}
    lock::ReentrantLock
    s_clones::NTuple{N,Tuple{ReentrantLock,S}}
    ctx_clones::NTuple{N,Context{Sim}}
    function OptSession15(s::Strategy; ctx, params, repeats)
        s_clones = tuple(((ReentrantLock(), similar(s)) for _ in 1:repeats)...)
        ctx_clones = tuple((similar(ctx) for _ in 1:repeats)...)
        new{typeof(s),repeats}(
            s, ctx, params, DataFrame(), Ref(nothing), ReentrantLock(), s_clones, ctx_clones
        )
    end
end

OptSession = OptSession15

function ctxsteps(ctx, repeats)
    small_step = Millisecond(ctx.range.step).value
    big_step = let timespan = Millisecond(ctx.range.stop - ctx.range.start).value
        Millisecond(round(Int, timespan / max(1, repeats - 1)))
    end
    (; small_step, big_step)
end

function define_backtest_func(sess, small_step, big_step)
    (params, n) -> let slot = sess.s_clones[n]
        @lock slot[1] let s = slot[2], ctx = sess.ctx_clones[n]
            # clear strat
            st.reset!(s, true)
            # apply params
            ping!(s, params, OptRun())
            # randomize strategy startup time
            let wp = ping!(s, WarmupPeriod()),
                inc = Millisecond(round(Int, small_step / n)) + big_step * (n - 1)

                current!(ctx.range, ctx.range.start + wp + inc)
            end
            # backtest and score
            backtest!(s, ctx; doreset=false)
            obj = ping!(s, OptScore())
            # record run
            cash = value(st.current_total(s))
            trades = st.trades_total(s)
            @lock sess.lock push!(
                sess.results,
                (;
                    obj,
                    cash,
                    trades,
                    (Symbol("x$n") => p for (n, p) in enumerate(params))...,
                ),
            )
            obj
        end
    end
end

@doc "Multi(threaded) optimization function."
function _multi_opt_func(repeats, backtest_func, median_func, obj_type)
    (params) -> let scores = obj_type[]
        Threads.@threads for n in 1:repeats
            push!(scores, backtest_func(params, n))
        end
        mapreduce(permutedims, vcat, scores) |> median_func
    end
end

@doc "Single(threaded) optimization function."
function _single_opt_func(repeats, backtest_func, median_func, args...)
    (params) -> begin
        mapreduce(permutedims, vcat, [(backtest_func(params, n) for n in 1:repeats)...]) |> median_func
    end
end

@doc "The media in multi(objective) mode has to be applied over all the (repeated) iterations."
function define_median_func(ismulti)
    if ismulti
        (x) -> tuple(median(x; dims=1)...)
    else
        (x) -> median(x)
    end
end

function define_opt_func(s::Strategy; backtest_func, ismulti, repeats, obj_type)
    median_func = define_median_func(ismulti)
    opt_func = isthreadsafe(s) ? _multi_opt_func : _single_opt_func
    opt_func(repeats, backtest_func, median_func, obj_type)
end

@doc "Returns the number of objectives and their type."
function objectives(s)
    let test_obj = ping!(s, OptScore())
        typeof(test_obj), length(test_obj)
    end
end

include("bbopt.jl")
include("grid.jl")
