using .ect: DFT
using .ect.OrderTypes: Order
using .ect.Instances: pnl
using .ect.Strategies: NoMarginStrategy, MarginStrategy
using .ect.Misc: MarginMode, NoMargin, WithMargin, marginmode
using .ect.Lang: @ifdebug

@doc "A NamedTuple representing trade data, including `date`, `amount`, `price`, `value`, `fees`, `fees_base`, `size`, `leverage`, `entryprice`, and `order`."
const TradesTuple = NamedTuple{
    (:date, :amount, :price, :value, :fees, :fees_base, :size, :leverage, :entryprice, :order),
    Tuple{
        collect(Vector{T} for T in (DateTime, DFT, DFT, DFT, DFT, DFT, DFT, DFT, DFT, Order))...
    },
}
@doc """ Transforms an `AbstractVector` of trades into a DataFrame.

$(TYPEDSIGNATURES)

The function creates an empty DataFrame from `TradesTuple` and appends the trades.
Afterwards, it renames the `:date` column to `:timestamp`.
"""
function _tradesdf(trades::AbstractVector)
    tt = TradesTuple(T[] for T in fieldtypes(TradesTuple))
    df = DataFrame(tt)
    append!(df, trades)
    rename!(df, :date => :timestamp)
    df
end
@doc """ Retrieves trades from an `AssetInstance` within a specified range and transforms them into a DataFrame.

$(TYPEDSIGNATURES)

The function retrieves trades within this range and then transforms them into a DataFrame using the `_tradesdf()` function.
"""
function _tradesdf(ai::AssetInstance, from=firstindex(ai.history), to=lastindex(ai.history))
    length(from:to) < 1 || length(s.history) == 0 && return nothing
    _tradesdf(@view ai.history[from:to])
end
tradesdf(ai) = _tradesdf(ai.history)

@doc """Checks if an `Order` is an `IncreaseOrder`."""
isincreaseorder(::O) where {O<:IncreaseOrder} = true
isincreaseorder(_) = false
@doc """Checks if an `Order` is a `ReduceOrder`."""
isreduceorder(::O) where {O<:ReduceOrder} = true
isreduceorder(_) = false
@doc """ Counts the number of entries and exits in a trade.

$(TYPEDSIGNATURES)

The function takes a trade as input, counts the number of entries (negative values) and exits (positive values) and returns a tuple with these counts.
"""
entryexit(g) = (entries=count(x -> x < 0, g), exits=count(x -> x > 0, g))
@doc """ Calculates the spent amount in a trade considering `leverage`, `value` and `fees`.

$(TYPEDSIGNATURES)

The function calculates the spent amount as the `value` divided by `leverage` plus `fees`, and returns the negative absolute value of this amount. 
An assertion ensures that the calculated value is non-negative before negation.
"""
function _spent(_, _, _, leverage, price, value, fees, fees_base)
    v = value / leverage + fees + fees_base * price
    @assert v >= 0.0
    Base.negate(abs(v))
end
@doc """ Calculates the earned amount in a trade considering `entryprice`, `amount`, `leverage`, `price`, and `fees`.

$(TYPEDSIGNATURES)

The function computes the earned amount as the absolute value of the product of `entryprice` and `amount` divided by `leverage`, plus the profit and loss (pnl) calculated from the `entryprice`, `price`, `amount`, and the position side of the order, minus `fees`.
"""
function _earned(o, entryprice, amount, leverage, price, value, fees, fees_base=0.0)
    (abs(entryprice * amount) / leverage) +
    pnl(entryprice, price, amount, positionside(o)()) - fees - fees_base * price
end
_quotebalance(o::IncreaseOrder, args...) = _spent(o, args...)
_quotebalance(o::ReduceOrder, args...) = _earned(o, args...)
function quotebalance(entryprice, amount, leverage, value, price, fees, fees_base, order)
    _quotebalance.(order, entryprice, amount, leverage, price, value, fees, fees_base)
end
@doc """ Applies custom transformations based on margin mode, style, and custom parameters.

$(TYPEDSIGNATURES)

Depending on the provided `MarginMode`, `style` and `custom` parameters, this function applies different transformations to the data.
The customization allows for flexibility in data processing and analysis.
"""
function transforms(m::MarginMode, style, custom)
    base = Any[:timestamp => first, :base_volume => sum => :base_balance]
    push!(
        base,
        if m == NoMargin
            :quote_volume => sum => :quote_balance
        else
            [:entryprice, :amount, :leverage, :value, :price, :fees, :fees_base, :order] =>
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

@doc """ Buys subtract quote currency, while sells subtract base currency.

$(TYPEDSIGNATURES)

This function adjusts the volume of trades in the `NoMargin` mode.
It assigns `size` to `quote_volume` and `amount` to `base_volume` in the `data`.
In debug mode, it asserts that all sell orders have non-positive base volume and non-negative quote volume, and all buy orders have non-negative base volume and non-positive quote volume.
"""
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
@doc """ Entries subtract quote currency, Exits subtract base currency.

$(TYPEDSIGNATURES)

This function adjusts the volume of trades in the `WithMargin` mode. 
It assigns `size` to `quote_volume` and `amount` to `base_volume` in the `data`. 
It then modifies these volumes based on whether each order in `data` is an increase order or not. 
For non-increase orders, `base_volume` is made non-positive and `quote_volume` is made non-negative. 
For increase orders, `base_volume` is made non-negative and `quote_volume` is made non-positive.
"""
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

@doc """ Groups trade data by date and other specified tags.

$(TYPEDSIGNATURES)

The function converts timestamps in `data` to a suitable format based on `tf` and then groups the data by the specified `tags` and the converted timestamps. 
The `sort` parameter determines whether the resulting grouped data should be sorted or not.
"""
function bydate(data, tf, tags...; sort=false)
    td = timefloat(tf)
    data[!, :sample] = timefloat.(data.timestamp) .÷ td
    groupby(data, [tags..., :sample]; sort)
end

@doc """ Applies a given timeframe to the timestamps in a DataFrame.

$(TYPEDSIGNATURES)

This function removes the `sample` column from the DataFrame `df` and applies the `tf` timeframe to the `timestamp` column. 
The DataFrame is then returned with the updated timestamps.
"""
function applytimeframe!(df, tf)
    select!(df, Not(:sample))
    df.timestamp[:] = apply.(tf, df.timestamp)
    df
end

@doc """ Resamples trades data from a smaller to a higher timeframe.

$(TYPEDSIGNATURES)

This function takes an `AssetInstance` and a target timeframe `to_tf` as parameters, as well as optional `style` and `custom` parameters for additional customization.
It extracts the trades data from the `AssetInstance` and resamples it to the target timeframe. 
Volume adjustments are made based on the margin mode of the `AssetInstance`.
The data is then grouped by date, transformed according to the margin mode, style, and custom parameters, and combined into a new DataFrame. 
Finally, the target timeframe is applied to the timestamps in the DataFrame.
"""
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

@doc """ Expands a DataFrame to include all timestamps in a range.

$(TYPEDSIGNATURES)

This function takes a DataFrame `df` and an optional timeframe `tf` (which defaults to the timeframe of `df`).
It creates a new DataFrame that includes all timestamps within the range of `df` and the given timeframe, and then joins this new DataFrame with `df` using an outer join on the `timestamp` column.
The resulting DataFrame is then sorted by `timestamp`.
"""
function expand(df, tf=timeframe!(df))
    df = outerjoin(
        DataFrame(:timestamp => collect(DateTime, daterange(df, tf))), df; on=:timestamp
    )
    sort!(df, :timestamp)
end

@doc """ Aggregates all trades of a strategy in a single dataframe

$(TYPEDSIGNATURES)

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
    if isempty(df)
        @warn "resample: no trades" tf
        return nothing
    end
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
