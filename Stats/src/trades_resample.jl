using Data.DataFrames
using Engine.Types.Orders

_tradesdf(trades) = begin
    df = select!(DataFrame(trades), [:date, :amount, :size, :order])
    rename!(df, :date => :timestamp)
end
function tradesdf(ai, from=firstindex(ai.history), to=lastindex(ai.history))
    _tradesdf(@view ai.history[from:to])
end
tradesdf(ai) = _tradesdf(ai.history)

isbuyorder(::Order{<:OrderType{S}}) where {S<:OrderSide} = S == Buy
issellorder(::Order{<:OrderType{S}}) where {S<:OrderSide} = S == Sell

@doc "Resamples trades data from a smaller to a higher timeframe."
function resample_trades(ai, to_tf)
    data = tradesdf(ai)
    size(data, 1) === 0 && return nothing
    rename!(data, :size => :quote_volume)
    rename!(data, :amount => :base_volume)
    let buymask = isbuyorder.(data.order), sellmask = xor.(buymask)
        data[sellmask, :base_volume] = -data.base_volume[sellmask]
        data[buymask, :quote_volume] = -data.quote_volume[buymask]
    end

    buysell = g -> (buys=count(x -> x < 0, g), sells=count(x -> x > 0, g))
    td = timefloat(to_tf)
    data[!, :sample] = timefloat.(data.timestamp) .÷ td
    gb = groupby(data, :sample)
    df = combine(
        gb,
        :timestamp => first,
        :base_volume => x-> sum(abs.(x)),
        :quote_volume => x-> sum(abs.(x)),
        :base_volume => sum => :base_balance,
        :quote_volume => sum => :quote_balance,
        :timestamp => length => :trades_count,
        :quote_volume => buysell => [:buys, :sells],
        # :order => tuple,
        ;
        renamecols=false,
    )
    select!(data, Not(:sample))
    select!(df, Not(:sample))
    df.timestamp[:] = apply.(to_tf, df.timestamp)
    df
end

export tradesdf, resample_trades
