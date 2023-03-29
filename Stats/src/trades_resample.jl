using Data.DataFrames
using Engine.Types.Orders

_tradesdf(trades) = begin
    df = select!(DataFrame(trades), [:date, :amount, :size, :order])
    rename!(df, :date => :timestamp)
end
function tradesdf(ai, from=firstindex(ai.history), to=lastindex(ai.history))
    length(from:to) < 1 && return nothing
    _tradesdf(@view ai.history[from:to])
end
tradesdf(ai) = _tradesdf(ai.history)

isbuyorder(::Order{<:OrderType{S}}) where {S<:OrderSide} = S == Buy
issellorder(::Order{<:OrderType{S}}) where {S<:OrderSide} = S == Sell
buysell(g) = (buys=count(x -> x < 0, g), sells=count(x -> x > 0, g))
function transforms(style)
    base = [
        :timestamp => first,
        :quote_volume => sum => :quote_balance,
        :base_volume => sum => :base_balance,
    ]
    if style == :full
        append!(
            base,
            (
                :base_volume => x -> sum(abs.(x)),
                :quote_volume => x -> sum(abs.(x)),
                :timestamp => length => :trades_count,
                :quote_volume => buysell => [:buys, :sells],
                # :order => tuple,
            ),
        )
    end
    base
end

@doc "Resamples trades data from a smaller to a higher timeframe."
function resample_trades(ai, to_tf; style=:full)
    data = tradesdf(ai)
    isnothing(data) && return nothing
    data[!, :quote_volume] = data.size
    data[!, :base_volume] = data.amount
    let buymask = isbuyorder.(data.order), sellmask = xor.(buymask, true)
        data[sellmask, :base_volume] = -data.base_volume[sellmask]
        data[buymask, :quote_volume] = -data.quote_volume[buymask]
    end
    td = timefloat(to_tf)
    data[!, :sample] = timefloat.(data.timestamp) .÷ td
    gb = groupby(data, :sample)
    df = combine(gb, transforms(style)...; renamecols=false)
    select!(df, Not(:sample))
    df.timestamp[:] = apply.(to_tf, df.timestamp)
    df
end

export tradesdf, resample_trades
