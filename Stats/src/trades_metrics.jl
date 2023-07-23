using .OrderTypes: LiquidationTrade, LongTrade, ShortTrade

function trades_duration(ai::AssetInstance; raw=false, f=mean)
    periods = getproperty.(ai.history, :date) |> diff
    periods_num = getproperty.(periods, :value) # milliseconds
    μ = if length(ai.history) > 1
        f(periods_num)
    else
        Millisecond(lastdate(ai) - first(ai.history).date).value
    end
    raw ? μ : compact(Millisecond(trunc(μ)))
end

function trades_duration(s::Strategy; f=mean)
    [trades_duration(ai; raw=true, f) for ai in s.universe] |>
    mean |>
    trunc |>
    Millisecond |>
    compact
end

function trades_size(ai::AssetInstance; f=mean)
    vals = getproperty.(ai.history, :size)
    f(abs.(vals))
end

function trades_size(s::Strategy; f=mean)
    [trades_size(ai; f) for ai in s.universe] |> f
end

function trades_leverage(ai::AssetInstance; f=mean)
    vals = getproperty.(ai.history, :leverage)
    f(abs.(vals))
end

function trades_hour(ai::AssetInstance; f=mean)
    h = Hour.(getproperty.(ai.history, :date))
    h = getproperty.(h, :value)
    f(h) |> trunc |> Hour
end

function trades_weekday(ai::AssetInstance; f=mean)
    w = dayofweek.(getproperty.(ai.history, :date))
    f(w) |> trunc |> Int |> dayname
end

function trades_monthday(ai::AssetInstance; f=mean)
    w = dayofmonth.(getproperty.(ai.history, :date))
    f(w) |> trunc |> Int
end

function trades_stats(s::Strategy)
    res = DataFrame()
    for ai in s.universe
        isempty(ai.history) && continue
        avg_dur = trades_duration(ai; f=mean)
        med_dur = trades_duration(ai; f=median)
        min_dur = trades_duration(ai; f=minimum)
        max_dur = trades_duration(ai; f=maximum)

        avg_size = trades_size(ai; f=mean)
        med_size = trades_size(ai; f=median)
        min_size = trades_size(ai; f=minimum)
        max_size = trades_size(ai; f=maximum)

        avg_leverage = trades_leverage(ai; f=mean)
        med_leverage = trades_leverage(ai; f=median)
        min_leverage = trades_leverage(ai; f=minimum)
        max_leverage = trades_leverage(ai; f=maximum)

        trades = length(ai.history)
        liquidations = count(x -> x isa LiquidationTrade, ai.history)
        longs = count(x -> x isa LongTrade, ai.history)
        shorts = count(x -> x isa ShortTrade, ai.history)
        weekday = trades_weekday(ai; f=mean)
        monthday = trades_monthday(ai; f=mean)

        push!(
            res,
            (;
                asset=ai.asset.raw,
                trades,
                liquidations,
                longs,
                shorts,
                avg_dur,
                med_dur,
                min_dur,
                max_dur,
                weekday,
                monthday,
                avg_size,
                med_size,
                min_size,
                max_size,
                avg_leverage,
                med_leverage,
                min_leverage,
                max_leverage,
            );
            promote=false,
        )
        # upcast periods for pretty print
        if nrow(res) == 1
            for prop in (:avg, :med, :min, :max)
               prop = Symbol("$(prop)_dur")
               arr = getproperty(res, prop)
               setproperty!(res, prop, convert(Vector{Period}, arr))
            end
        end
    end
    res
end
