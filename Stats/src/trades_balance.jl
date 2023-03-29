using Lang
using Engine.Strategies
using Engine.Types.Instances
using Data.DFUtils
using Data.DataFramesMeta
using Data

zeromissing!(v) = begin
    for i in eachindex(v)
        ismissing(v[i]) && (v[i] = 0.0)
    end
    v
end

possum(x, y) = begin
    max(0.0, x + y)
end

aroundtrades(ai, tf) = begin
    start_date = first(ai.history).order.date - tf
    stop_date = last(ai.history).date + tf
    df = ai.ohlcv[DateRange(start_date, stop_date)]
    df = resample(df, tf)
end

@doc """Plots the trade history of a single asset instance.

!!! warning "For single assets only"
    If your strategy trades multiple assets the profits returned by this function
    won't match the strategy actual holdings since calculation are done only w.r.t
    this single asset.
"""
function trades_balance(
    ai::AssetInstance, tf=tf"1d"; asdf=true, df=aroundtrades(ai, tf), initial_cash=0.0
)
    isempty(ai.history) && return nothing
    trades = resample_trades(ai, tf; style=:minimal)
    df = outerjoin(df, trades; on=:timestamp, order=:left)
    transform!(
        df,
        :quote_balance => zeromissing!,
        :base_balance => zeromissing!,
        :quote_balance => (x -> accumulate(+, x; init=initial_cash)) => :cum_quote,
        :base_balance => (x -> accumulate(possum, x; init=0.0)) => :cum_base;
        renamecols=false,
    )
    if asdf
        df[!, :cum_base_value] = df.cum_base .* df.close
        df[!, :cum_total] = df.cum_quote + df.cum_base_value
        df
    else
        df.cum_quote + df.cum_base .* df.close
    end
end

function trades_balance(s::Strategy, aa, args...; kwargs...)
    trades_balance(s.universe[aa].instance, args...; kwargs...)
end
