using Engine: DFT
using Engine.OrderTypes: Order
using Engine.Instances: pnl
using Engine.Strategies: NoMarginStrategy, MarginStrategy
using Engine.Misc: MarginMode, NoMargin, WithMargin, marginmode
using Engine.Lang: @ifdebug

# Use a generic Order instead to avoid the dataframe creating a too concrete order vector
TradesTuple2 = NamedTuple{
    (:date, :amount, :price, :value, :fees, :size, :leverage, :entryprice, :order),
    Tuple{
        collect(Vector{T} for T in (DateTime, DFT, DFT, DFT, DFT, DFT, DFT, DFT, Order))...
    },
}
function _tradesdf(trades::AbstractVector)
    tt = TradesTuple2(T[] for T in fieldtypes(TradesTuple2))
    df = DataFrame(tt)
    append!(df, trades)
    rename!(df, :date => :timestamp)
    df
end
function _tradesdf(ai::AssetInstance, from=firstindex(ai.history), to=lastindex(ai.history))
    length(from:to) < 1 || length(s.history) == 0 && return nothing
    _tradesdf(@view ai.history[from:to])
end
tradesdf(ai) = _tradesdf(ai.history)

isincreaseorder(::O) where {O<:IncreaseOrder} = true
isincreaseorder(_) = false
isreduceorder(::O) where {O<:ReduceOrder} = true
isreduceorder(_) = false
entryexit(g) = (entries=count(x -> x < 0, g), exits=count(x -> x > 0, g))
function _spent(_, _, _, leverage, _, value, fees)
    v = value / leverage + fees
    @assert v >= 0.0
    Base.negate(abs(v))
end
function _earned(o, entryprice, amount, leverage, price, _, fees)
    (abs(entryprice * amount) / leverage) +
    pnl(entryprice, price, amount, positionside(o)()) - fees
end
_quotebalance(o::IncreaseOrder, args...) = _spent(o, args...)
_quotebalance(o::ReduceOrder, args...) = _earned(o, args...)
function quotebalance(entryprice, amount, leverage, value, price, fees, order)
    _quotebalance.(order, entryprice, amount, leverage, price, value, fees)
end
function transforms(m::MarginMode, style, custom)
    base = Any[:timestamp => first, :base_volume => sum => :base_balance]
    push!(
        base,
        if m == NoMargin
            :quote_volume => sum => :quote_balance
        else
            [:entryprice, :amount, :leverage, :value, :price, :fees, :order] =>
                sum ∘ quotebalance => :quote_balance
        end,
    )
    if style == :full
        append!(
            base,
            (
                :base_volume => x -> sum(abs.(x)),
                :quote_volume => x -> sum(abs.(x)),
                :timestamp => length => :trades_count,
                :quote_volume => entryexit => [:entries, :exits],
                # :order => tuple,
            ),
        )
    end
    append!(base, custom)
    base
end

@doc "Buys substract quote currency, while sells subtract base currency"
function tradesvolume!(::NoMargin, data)
    data[!, :quote_volume] = data.size
    data[!, :base_volume] = data.amount
    @ifdebug let increasemask = isincreaseorder.(data.order),
        reducemask = xor.(increasemask, true)

        @assert all(view(data, reducemask, :base_volume) .<= 0)
        @assert all(view(data, reducemask, :quote_volume) .>= 0)
        @assert all(view(data, increasemask, :base_volume) .>= 0)
        @assert all(view(data, increasemask, :quote_volume) .<= 0)
    end
end

_negative(v) = (Base.negate ∘ abs)(v)
_positive(v) = abs(v)
@doc "Entries substract quote currency, Exits subtract base currency"
function tradesvolume!(::WithMargin, data)
    data[!, :quote_volume] = data.size
    data[!, :base_volume] = data.amount
    let increasemask = isincreaseorder.(data.order), reducemask = xor.(increasemask, true)
        data.base_volume[reducemask] = _negative.(data.base_volume[reducemask])
        data.quote_volume[reducemask] = _positive.(data.quote_volume[reducemask])
        data.base_volume[increasemask] = _positive.(data.base_volume[increasemask])
        data.quote_volume[increasemask] = _negative.(data.quote_volume[increasemask])
    end
end

function bydate(data, tf, tags...; sort=false)
    td = timefloat(tf)
    data[!, :sample] = timefloat.(data.timestamp) .÷ td
    groupby(data, [tags..., :sample]; sort)
end

function applytimeframe!(df, tf)
    select!(df, Not(:sample))
    df.timestamp[:] = apply.(tf, df.timestamp)
    df
end

@doc "Resamples trades data from a smaller to a higher timeframe."
function resample_trades(ai::AssetInstance, to_tf; style=:full, custom=())
    data = tradesdf(ai)
    isnothing(data) && return nothing
    tradesvolume!(marginmode(ai), data)
    gb = bydate(data, to_tf)
    df = combine(gb, transforms(marginmode(ai), style, custom)...; renamecols=false)
    applytimeframe!(df, to_tf)
end

# @doc "Converts a trade to a named tuple with its symbol as :name attribute."
# function namedtrade(name, trade)
#     NamedTuple((
#         :name => name, (p => getproperty(trade, p) for p in propertynames(trade))...
#     ))
# end
#

function expand(df, tf=timeframe!(df))
    df = outerjoin(
        DataFrame(:timestamp => collect(DateTime, daterange(df, tf))), df; on=:timestamp
    )
    sort!(df, :timestamp)
end

@doc """ Aggregates all trades of a strategy in a single dataframe

`byinstance`: `(trades_df, ai) -> nothing` can modify the dataframe of a single instance before it is appended
to the full df.
`style`: `:full` or `:minimal` specifies what columns should be aggregated in the resampled df
`custom`: similar to `style` but instead allows you to define custom aggregation rules (according to `DataFrame`)
`expand_dates`: returns a contiguous dataframe from the first trade date to the last (inserting default ohlcv rows where no trades have happened.)
"""
function resample_trades(
    s::Strategy,
    tf=tf"1d";
    style=:full,
    byinstance=Returns(nothing),
    custom=(),
    expand_dates=false,
)
    df = DataFrame()
    for ai in s.universe
        isempty(ai.history) && continue
        tdf = tradesdf(ai)
        tdf[!, :instance] .= ai
        byinstance(tdf, ai)
        append!(df, tdf)
    end
    isempty(df) && return nothing
    tradesvolume!(marginmode(s), df)
    # Group by instance because we need to calc value for each one separately
    gb = bydate(df, tf, :instance)
    df = combine(
        gb,
        transforms(marginmode(s), style, (:instance => first, custom...))...;
        renamecols=false,
    )
    applytimeframe!(df, tf)
    expand_dates ? expand(df, tf) : sort!(df, :timestamp)
end

export tradesdf, resample_trades
