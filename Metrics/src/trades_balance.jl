using .ect.Instances: NoMarginInstance, MarginInstance
using .ect.OrderTypes: PositionSide
using .ect.Executors.Checks: withfees
using .ect.Strategies: tradesedge
using .ect.Strategies: DateRange

@doc """ Replaces missing values in a vector with 0.0.

$(SIGNATURES)

This function iterates over each index of the vector `v`. 
If the value at a given index is missing, it replaces it with 0.0. 
The vector `v` is then returned with the replaced values.
"""
zeromissing!(v) = begin
    for i in eachindex(v)
        ismissing(v[i]) && (v[i] = 0.0)
    end
    v
end

possum(x, y) = begin
    max(0.0, x + y)
end
orzero(; atol=1e-15) = v -> orzero(v, atol)
orzero(v, atol=1e-15) = isapprox(v, 0.0; atol) ? 0.0 : v
appsum(x, y, atol=1e-15) = orzero(x + y, atol)

@doc """ Provides trade data for a given asset instance around a specified timeframe.

$(SIGNATURES)

It calculates a start and a stop date based on the dates of the first and last trades in the `AssetInstance` history and the specified timeframe.
It then extracts the OHLCV data for the `AssetInstance` within this date range, and resamples this data to the specified timeframe.
The resultant resampled DataFrame is returned.
"""
aroundtrades(ai, tf) = begin
    start_date = first(ai.history).order.date - tf
    stop_date = last(ai.history).date + tf
    df = ohlcv(ai)[DateRange(start_date, stop_date)]
    df = resample(df, tf)
end

_cum_value_balance(::NoMarginInstance, df) = df.cum_base .* df.close

@doc """ Calculates the cumulative value balance for a MarginInstance.

$(TYPEDSIGNATURES)

This function takes a `MarginInstance` `ai` and a DataFrame `df` as parameters. 
It defines a helper function `cvb` that calculates the value of an order based on various parameters, 
and updates some variables (`last_lev`, `last_ep`, `last_side`) with the details of the last non-missing order.

The function then applies `cvb` to each order in `df`, along with the corresponding `ai`, `entryprice`, `cum_base`, `leverage`, and `close` values from `df`.
The earned amounts for each order are returned as a vector.
"""
function _cum_value_balance(ai::MarginInstance, df)
    last_lev = one(DFT)
    last_ep = zero(DFT)
    last_side = Long
    def_fees = maxfees(ai)
    function cvb(o, ai, entryprice, cum_amount, leverage, close_price)
        this_val = abs(cum_amount * close_price)
        this_fees = ismissing(o) ? 0.0 : @something fees(o) def_fees
        if !ismissing(o)
            last_lev = leverage
            last_ep = entryprice
            last_side = positionside(o)
        end
        _earned(last_side, last_ep, cum_amount, last_lev, close_price, this_val, this_fees)
    end
    cvb.(df.order, ai, df.entryprice, df.cum_base, df.leverage, df.close)
end

@doc """Replays the trade history of a single asset instance.

$(TYPEDSIGNATURES)

`return_all`: if `true` returns a dataframe where:
  - `base/quote_balance` the volume generated by the trades that happened at that timestamp.
  - `:cum_total` represents the total balance held for each timestamp.
  - `:cum_value_balance` represents the value in quote currency of the asset for each timestamp.

!!! warning "For single assets only"
    If your strategy trades multiple assets the profits returned by this function
    won't match the strategy actual holdings since calculation are done only w.r.t
    this single asset.
"""
function trades_balance(
    ai::AssetInstance; tf=tf"1d", return_all=true, df=aroundtrades(ai, tf), initial_cash=0.0
)
    isempty(ai.history) && return nothing
    trades = resample_trades(
        ai,
        tf;
        style=:minimal,
        custom=(:order => last, :entryprice => last, :leverage => last),
    )
    df = outerjoin(df, trades; on=:timestamp, order=:left)
    while ismissing(df.close[end])
        @debug "Removing trades at the end since there is no matching candle." maxlog = 1
        pop!(df)
    end
    transform!(
        df,
        :quote_balance => zeromissing!,
        :base_balance => zeromissing!,
        :quote_balance => (x -> accumulate(+, x; init=initial_cash)) => :cum_quote,
        :base_balance => ((x) -> accumulate(orzero() ∘ +, x; init=0.0)) => :cum_base;
        renamecols=false,
    )
    if return_all
        df[!, :cum_value_balance] = _cum_value_balance(ai, df)
        df[!, :cum_total] = df.cum_quote + df.cum_value_balance
        df
    else
        df.cum_quote .+ _cum_value_balance(ai, df)
    end
end

function trades_balance(s::Strategy, aa; kwargs...)
    trades_balance(s.universe[aa].instance; kwargs...)
end
@doc """ Calculates the value of a position at a given timestamp for a NoMarginInstance.

$(SIGNATURES)

This function takes a `NoMarginInstance` `ai`, a `cum_amount`, and a `timestamp` as parameters, along with any number of additional arguments.
It calculates the value of the position as the product of the cumulative amount and the closing price at the given timestamp, and returns this value.
Note: For a `NoMarginInstance`, leverage is not considered, hence the value is directly dependent on the cumulative amount and the closing price.
"""
_valueat(ai::NoMarginInstance, cum_amount, timestamp, args...) =
    cum_amount * closeat(ai, timestamp)
@doc """ Calculates the value of a position at a given timestamp.

$(SIGNATURES)

This function takes a `MarginInstance` `ai`, a `cum_amount`, a `timestamp`, a `leverage`, an `entryprice`, and a position `pos` as parameters.
It first calculates the closing price at the given timestamp, the value of the position based on the cumulative amount and the closing price, and the fees based on this value.
It then returns the earned amount based on these values, using the `_earned` function.
"""
function _valueat(
    ai::MarginInstance,
    cum_amount,
    timestamp,
    leverage,
    entryprice,
    pos,
    fees,
    fees_base=0.0,
)
    close = closeat(ai, timestamp)
    this_value = cum_amount * close

    _earned(pos, entryprice, cum_amount, leverage, close, this_value, fees, fees_base)
end

@doc """Plots the trade history for all the assets in a strategy.

$(SIGNATURES)

`return_all`[`true`]: similar to the function for single assets, plus:
  - `cum_quote`: the balance of cash for each timestamp
  - `cum_value_balance`: the balance of all held assets in quote currency for each timestamp.
`byasset`[`false`]: also return a column that tracks the value balance by asset for each timestamp
`normalize_timeframes`:

"""
function trades_balance(
    s::Strategy;
    tf::TimeFrame=tf"1d",
    return_all=true,
    byasset=false,
    # normalize_timeframes=true,
    kwargs...,
)
    df = resample_trades(
        s,
        tf;
        style=:minimal,
        custom=(
            :order => last,
            :entryprice => last,
            :leverage => last,
            :amount => sum,
            [:fees, :fees_base, :price] =>
                ((f, b, p) -> sum(@. f .+ b .* p)) => :fees_total,
        ),
    )
    isnothing(df) && return nothing
    # Expand dates
    df = expand(df, tf)
    # We need to accumulate base balances for each asset
    let elt = eltype(df.quote_balance),
        assets = Dict(
            ai => (;
                cum_value_balance=Ref(zero(elt)),
                cum_base=Ref(zero(elt)),
                lev=Ref(one(elt)),
                ep=Ref(zero(elt)),
                pos=Ref{PositionSide}(Long()),
                fees=Ref(zero(elt)),
            ) for ai in s.universe
        )

        @inbounds @eachrow! df begin
            @newcol :cum_value_balance::typeof(df.quote_balance)
            let ai = :instance
                # only update values if there are trades for this timestamp
                ismissing(ai) || begin
                    let state = assets[ai]
                        # we only accumulate the *amounts* of the assets
                        state.cum_base[] += :base_balance
                        # Keep track of the last trade for the asset such
                        # that we know the last known lev/ep/side
                        state.lev[] = :leverage
                        state.ep[] = :entryprice
                        state.pos[] = positionside(:order)()
                        state.fees[] = :fees_total
                    end
                end
                # while the actual cash value is updated in place for all assets
                for ai in keys(assets)
                    firstdate(ai) <= :timestamp <= lastdate(ai) && let
                        state = assets[ai]
                        state.cum_value_balance[] = _valueat(
                            ai,
                            state.cum_base[],
                            :timestamp,
                            state.lev[],
                            state.ep[],
                            state.pos[],
                            state.fees[],
                        )
                    end
                end
                # on each timestamp, update the known total value of the assets.
                # The sum of all assets value will be correct only on the last
                # trade for a particular timestamp.
                let value_dict = Dict(
                        ai => state.cum_value_balance[] for (ai, state) in assets
                    )
                    :cum_value_balance = sum(values(value_dict))
                    if ^(byasset)
                        @newcol :byasset::Vector{Dict{AssetInstance,elt}}
                        :byasset = copy(value_dict)
                    end
                end
            end
        end
    end
    # Now we can sum all assets over their quote balance.
    # The value balance is already in cumulative form,
    # therefore we only take the last value, which ensures that all assets balances are updated
    # since grouping does not affect the order
    gb = groupby(df, :timestamp)
    df = combine(
        gb,
        :quote_balance => sum ∘ skipmissing,
        :cum_value_balance => last,
        # include the byasset colum only if computed
        (byasset ? (:byasset => last,) : ())...;
        renamecols=false,
    )
    # Add initial cash before cumsum
    df.quote_balance[begin] += s.initial_cash
    transform!(df, :quote_balance => cumsum ∘ skipmissing => :cum_quote)
    # finally the total at each timestamp is given by the cumulative quote balance
    # summed to the value of all the assets at each timestamp.
    df[!, :cum_total] = df.cum_quote + df.cum_value_balance
    df.timestamp[:] = apply.(tf, df.timestamp)
    if return_all
        df
    else
        cols = [:timestamp, :cum_total]
        byasset && push!(cols, :byasset)
        @view df[:, cols]
    end
end

@doc """ Forward fills missing values in a vector.

$(SIGNATURES)

This function takes a vector `v` and an optional output vector `out` (which defaults to `v` itself).
It starts with the first value in `v` (which must not be missing) and applies the `coalesce` function to each subsequent pair of values in `v` and `out`.
The `coalesce` function replaces each missing value in `v` with the corresponding value from `out`.
The function then returns `out` with the filled missing values.
This is effectively a forward fill operation, carrying the most recent non-missing value forward to replace missing values.
"""
ffill!(v, out=v) = begin
    f = first(v)
    @assert !ismissing(f)
    accumulate!(((x, y) -> coalesce(y, x)), out, v; init=f)
end
ffill(v) = ffill!(v, similar(v))
