using Executors: orderscount
using Executors: isoutof_orders
using .Instances.Data.DFUtils: lastdate
using .Misc.LoggingExtras
using Base: with_logger
using .st: universe

import .Misc: start!, stop!

@doc """Backtest a strategy `strat` using context `ctx` iterating according to the specified timeframe.

$(TYPEDSIGNATURES)

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
function start!(
    s::Strategy{Sim}, ctx::Context; trim_universe=false, doreset=true, resetctx=true
)
    # ensure that universe data start at the same time
    @ifdebug _resetglobals!(s)
    if trim_universe
        let data = st.coll.flatten(st.universe(s))
            !check_alignment(data) && trim!(data)
        end
    end
    if resetctx
        tt.current!(ctx.range, ctx.range.start + ping!(s, WarmupPeriod()))
    end
    if doreset
        st.reset!(s)
    end
    update_mode = s.attrs[:sim_update_mode]::ExecAction
    logger = if s[:sim_debug]
        current_logger()
    else
        MinLevelLogger(current_logger(), s[:log_level])
    end
    with_logger(logger) do
        for date in ctx.range
            isoutof_orders(s) && begin
                @deassert all(iszero(ai) for ai in universe(s))
                break
            end
            update!(s, date, update_mode)
            ping!(s, date, ctx)
            @debug "sim: iter" s.cash ltxzero(s.cash) isempty(s.holdings) orderscount(s)
        end
    end
    s
end

@doc """
Backtest with context of all data loaded in the strategy universe.

$(TYPEDSIGNATURES)

Backtest the strategy with the context of all data loaded in the strategy universe. This function ensures that the universe data starts at the same time. If `trim_universe` is true, it trims the data to ensure alignment. If `doreset` is true, it resets the strategy before starting the backtest. The backtest is performed using the specified `ctx` context.

"""
start!(s::Strategy{Sim}; kwargs...) = start!(s, Context(s); kwargs...)

@doc """
Starts the strategy with the given count.

$(TYPEDSIGNATURES)

Starts the strategy with the given count.
If `count` is greater than 0, it sets the start and end timestamps based on the count and the strategy's timeframe.
Otherwise, it sets the start and end timestamps based on the last timestamp in the strategy's universe.

"""
function start!(s::Strategy{Sim}, count::Integer; kwargs...)
    if count > 0
        from = ohlcv(first(s.universe)).timestamp[begin]
        to = from + s.timeframe.period * count
    else
        to = ohlcv(last(s.universe)).timestamp[end]
        from = to + s.timeframe.period * count
    end
    ctx = Context(Sim(), s.timeframe, from, to)
    start!(s, ctx; kwargs...)
end

@doc """Returns the latest date in the given strategy's universe.

$(TYPEDSIGNATURES)

Iterates over the strategy's universe to find the date of the last data point. Returns the latest date as a `DateTime` object.

"""
_todate(s) = begin
    to = typemin(DateTime)
    for ai in s.universe
        this_date = lastdate(ai)
        if this_date > to
            to = this_date
        end
    end
    return to
end

@doc """ Starts the strategy simulation from a specific date to another.

$(TYPEDSIGNATURES)

This function initializes a simulation context with the given timeframe and date range, then starts the strategy with this context.

"""
function start!(s::Strategy{Sim}, from::DateTime, to::DateTime=_todate(s); kwargs...)
    ctx = Context(Sim(), s.timeframe, from, to)
    start!(s, ctx; kwargs...)
end

stop!(::Strategy{Sim}) = nothing

backtest!(s::Strategy{Sim}, args...; kwargs...) = begin
    @warn "DEPRECATED: use `start!`"
    start!(s, args...; kwargs...)
end
