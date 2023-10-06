using Executors: orderscount
using Executors: isoutof_orders
import .Misc: start!, stop!

@doc """Backtest a strategy `strat` using context `ctx` iterating according to the specified timeframe.

On every iteration, the strategy is queried for the _current_ timestamp.
The strategy should only access data up to this point.
Example:
- Timeframe iteration: `1s`
- Strategy minimum available timeframe `1m`
Iteration gives time `1999-12-31T23:59:59` to the strategy:
The strategy (that can only lookup up to `1m` precision)
looks-up data until the timestamp `1999-12-31T23:58:00` which represents the
time until `23:59:00`.
Therefore we have to shift by one period down, the timestamp returned by `apply`:
```julia
julia> t = TimeTicks.apply(tf"1m", dt"1999-12-31T23:59:59")
1999-12-31T23:59:00 # we should not access this timestamp
julia> t - tf"1m".period
1999-12-31T23:58:00 # this is the correct candle timestamp that we can access
```
To avoid this mistake, use the function `available(::TimeFrame, ::DateTime)`, instead of apply.
"""
function start!(s::Strategy{Sim}, ctx::Context; trim_universe=false, doreset=true)
    # ensure that universe data start at the same time
    @ifdebug _resetglobals!()
    if trim_universe
        let data = flatten(universe(s))
            !check_alignment(data) && trim!(data)
        end
    end
    if doreset
        tt.current!(ctx.range, ctx.range.start + ping!(s, WarmupPeriod()))
        st.reset!(s)
    end
    update_mode = s.attrs[:sim_update_mode]::ExecAction
    for date in ctx.range
        isoutof_orders(s) && begin
            @deassert all(iszero(ai) for ai in universe(s))
            break
        end
        update!(s, date, update_mode)
        ping!(s, date, ctx)
    end
    s
end

@doc "Backtest with context of all data loaded in the strategy universe."
start!(s::Strategy{Sim}; kwargs...) = start!(s, Context(s); kwargs...)
function start!(s::Strategy{Sim}, count::Integer; kwargs...)
    if count > 0
        from = ohlcv(first(universe(s).data.instance)).timestamp[begin]
        to = from + s.timeframe.period * count
    else
        to = ohlcv(last(universe(s).data.instance)).timestamp[end]
        from = to + s.timeframe.period * count
    end
    ctx = Context(Sim(), s.timeframe, from, to)
    start!(s, ctx; kwargs...)
end

stop!(::Strategy{Sim}) = nothing

backtest!(s::Strategy{Sim}, args...; kwargs...) = begin
    @warn "DEPRECATED: use `start!`"
    start!(s, args...; kwargs...)
end
