using .OrderTypes: LiquidationTrade, LongTrade, ShortTrade
using .Data: default_value

@doc """ Computes the average duration of trades for an asset instance.

$(TYPEDSIGNATURES)

Calculates the average duration between trades for an `AssetInstance` `ai`.
The `raw` parameter determines whether the result should be in raw format (in milliseconds) or a compact time format.
The function `f` is used to aggregate the durations and defaults to the mean.

"""
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

@doc """ Computes the average duration of trades for a strategy.

$(TYPEDSIGNATURES)

Calculates the average duration between trades for a `Strategy` `s`.
The function `f` is used to aggregate the durations and defaults to the mean.

"""
function trades_duration(s::Strategy; f=mean)
    [trades_duration(ai; raw=true, f) for ai in s.universe] |>
    mean |>
    trunc |>
    Millisecond |>
    compact
end

@doc """ Computes the average trade size for an asset instance.

$(TYPEDSIGNATURES)

Calculates the average size of trades for an `AssetInstance` `ai`.
The function `f` is used to aggregate the sizes and defaults to the mean.

"""
function trades_size(ai::AssetInstance; f=mean)
    vals = getproperty.(ai.history, :size)
    f(abs.(vals))
end

@doc """ Computes the average trade size for a strategy.

$(TYPEDSIGNATURES)

Calculates the average size of trades for a `Strategy` `s`.
The function `f` is used to aggregate the sizes and defaults to the mean.

"""
function trades_size(s::Strategy; f=mean)
    [trades_size(ai; f) for ai in s.universe] |> f
end

@doc """ Computes the average leverage for trades of an asset instance.

$(TYPEDSIGNATURES)

Calculates the average leverage of trades for an `AssetInstance` `ai`.
The function `f` is used to aggregate the leverages and defaults to the mean.

"""
function trades_leverage(ai::AssetInstance; f=mean)
    vals = getproperty.(ai.history, :leverage)
    f(abs.(vals))
end

@doc """ Computes the average hour of trades for an asset instance.

$(TYPEDSIGNATURES)

Calculates the average hour of trades for an `AssetInstance` `ai`.
The function `f` is used to aggregate the hours and defaults to the mean.

"""
function trades_hour(ai::AssetInstance; f=mean)
    h = Hour.(getproperty.(ai.history, :date))
    h = getproperty.(h, :value)
    f(h) |> trunc |> Hour
end

@doc """ Computes the average weekday of trades for an asset instance.

$(TYPEDSIGNATURES)

Calculates the average weekday of trades for an `AssetInstance` `ai`.
The function `f` is used to aggregate the weekdays and defaults to the mean.

"""
function trades_weekday(ai::AssetInstance; f=mean)
    w = dayofweek.(getproperty.(ai.history, :date))
    f(w) |> trunc |> Int |> dayname
end

@doc """ Computes the average day of the month for trades of an asset instance.

$(TYPEDSIGNATURES)

Calculates the average day of the month for trades for an `AssetInstance` `ai`.
The function `f` is used to aggregate the days and defaults to the mean.

"""
function trades_monthday(ai::AssetInstance; f=mean)
    w = dayofmonth.(getproperty.(ai.history, :date))
    f(w) |> trunc |> Int
end

macro cumbal()
    ex = quote
        returns = let
            tf = first(keys(ohlcv_dict(ai)))
            trades_balance(ai; tf).cum_total
        end
    end
    esc(ex)
end

function trades_drawdown(ai::AssetInstance; cum_bal=@cumbal(), kwargs...)
    length(cum_bal) == 1 && return zero(DFT)
    ath = atl = first(cum_bal)
    dd = typemax(eltype(cum_bal))
    for v in cum_bal
        if v > ath
            ath = v
        elseif v < atl
            atl = v
        end
        aatl = abs(atl)
        shifted_ath = aatl + abs(ath)
        this_dd = aatl / shifted_ath
        if aatl > zero(aatl) && this_dd < dd
            dd = this_dd
        end
    end
    (; dd=isfinite(dd) ? dd : 1.0 - 1.0, atl, ath)
end

function trades_pnl(returns; f=mean)
    losses = (v for v in returns if isfinite(v) && v <= 0.0)
    gains = (v for v in returns if isfinite(v) && v > 0.0)
    NamedTuple((
        Symbol(nameof(f), :_, :loss) => isempty(losses) ? default_value(f) : f(losses),
        Symbol(nameof(f), :_, :profit) => isempty(gains) ? default_value(f) : f(gains),
    ))
end
function trades_pnl(ai::AssetInstance; returns=_returns_arr(@cumbal()), kwargs...)
    trades_pnl(returns; kwargs...)
end

function asset_stats!(res::DataFrame, ai::AssetInstance)
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

    cum_bal = @cumbal()
    drawdown, atl, ATH = trades_drawdown(ai; cum_bal)
    returns = _returns_arr(cum_bal)
    avg_loss, avg_profit = trades_pnl(ai; returns, f=mean)
    med_loss, med_profit = trades_pnl(ai; returns, f=median)
    loss_ext, profit_ext = trades_pnl(ai; returns, f=extrema)
    max_loss = loss_ext[1]
    max_profit = profit_ext[2]
    end_balance = cum_bal[end]

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
            drawdown,
            ATH,
            avg_loss,
            avg_profit,
            med_loss,
            med_profit,
            max_loss,
            max_profit,
            end_balance,
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

function trades_stats(s::Strategy; since=DateTime(0))
    res = DataFrame()
    for ai in s.universe
        isempty(ai.history) && continue
        if since >= first(ai.history).date
            hist = ai.history
            full_hist = copy(hist)
            try
                filter!(x -> x.date >= since, hist)
                asset_stats!(res, ai)
            finally
                empty!(hist)
                append!(hist, full_hist)
            end
        else
            asset_stats!(res, ai)
        end
    end
    res
end

function trades_perf(s::Strategy; sortby=[:drawdown])
    df = trades_stats(s)
    perf = select(df, occursin.(r"asset|drawdown|ATH|loss|profit|end_balance", names(df)))
    sort!(perf, sortby)
end
