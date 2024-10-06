module Query
using ..Misc.DocStringExtensions
include("slope.jl")

@doc """Filters exchange data based on slope angle and saves the output.

The `excfilter` macro takes a non-prefixed exchange name `exc_name`. It performs several operations:

- If the CCXT instance for the exchange is not already loaded, it loads it.
- It loads the pairs list and relative data for the exchange based on the current configuration settings.
- It applies a filter to the data based on the slope angle.
- It saves the output in the `results` dictionary under the key corresponding to the exchange name.
- The output is a tuple of the form (trg, flt, data), where:
  - trg: The pairs, sorted by slope
  - flt: The filtered pairs data
  - data: The full data for the exchange

This macro is useful for filtering and sorting pairs data for individual exchanges based on the slope angle.

"""
macro excfilter(exc_name)
    @eval begin
        include("slope.jl")
    end
    quote
        local trg
        @info "timeframe: $(config.min_timeframe), window: $(config.window), quote: $(config.qc), min_vol: $(config.min_vol)"
        @exchange! $exc_name

        # How should we filter the pairs?
        pred = @λ(x -> slopeangle(x; n=config.window)[end])
        # load the data from exchange with the quote currency and timeframe from config
        data = ((x -> $bt.load_ohlcv($bt.Data.zi, $exc_name, x, config.min_timeframe))(
            $bt.Exchanges.tickers($exc_name, config.qc)
        ))
        # apply the filter
        flt = $bt.filterminmax(pred, data, config.slope_min, config.slope_max)
        # Calculate the price ranges for filtered pairs
        trg = DataFrame([
            (p[2].name, p[1], price_ranges(p[2].data.close[end])) for p in flt
        ])
        # Save the data
        results[lowercase($(exc_name).name)] = (; trg, flt, data)
        # show the result
        $(esc(:res)) = results[lowercase($(exc_name).name)]
        trg
    end
end

@doc "Filter pairs in `hs` that are bottomed longs.

$(TYPEDSIGNATURES)
"
function cbot(
    hs::AbstractDataFrame,
    mrkts;
    n::StepRange=30:-3:3,
    min_n=16,
    sort_col=:score_sum,
    fb_kwargs=(up_thresh=0, mn=5.0, mx=45.0),
)
    @assert :n ∉ fb_kwargs "Don't pass the n arg to `find_bottomed`."
    bottomed = []
    for r in n
        append!(bottomed, keys(sst.find_bottomed(mrkts; n=r, fb_kwargs...)))
        length(bottomed) < min_n || break
    end
    mask = [p ∈ bottomed for p in hs.pair]
    sort(@view(hs[mask, :]), sort_col)
end


@doc "Filter pairs in `hs` that are peaked long.

$(TYPEDSIGNATURES)
"
function cpek(
    hs::AbstractDataFrame,
    mrkts;
    n::StepRange=30:-3:3,
    min_n=5,
    sort_col=:score_sum,
    fb_kwargs=(up_thresh=0, mn=5.0, mx=45.0),
)
    peaked = []
    for r in n
        append!(peaked, keys(sst.find_peaked(mrkts; n=r, fb_kwargs...)))
        length(peaked) < min_n || break
    end
    mask = [p ∈ peaked for p in hs.pair]
    sort(@view(hs[mask, :]), sort_col)
end

@doc """Calculates the average Rate of Change (ROC) for a set of markets.

$(TYPEDSIGNATURES)

This function `average_roc` takes a set of markets `mrkts` as input. It calculates the average Rate of Change (ROC) for these markets over a certain period. The ROC is a momentum oscillator that measures the percentage change in price between the current price and the price a certain number of periods ago.
The function returns the average ROC for the set of markets.

"""
function average_roc(mrkts)
    positive = Float64[]
    negative = Float64[]
    for pair in values(mrkts)
        roc = pair.data.close[end] / pair.data.close[end - 1] - 1.0
        if roc > 0.0
            push!(positive, roc)
        else
            push!(negative, roc)
        end
    end
    mpos = mean(positive)
    mneg = mean(negative)
    DataFrame(:positive => mpos, :negative => mneg, :ratio => mpos / abs(mneg))
end

@doc """Calculates the last day's Rate of Change (ROC) for a set of markets.

$(TYPEDSIGNATURES)

"""
function last_day_roc(r, mrkts)
    roc = []
    for pair in r.pair
        oneday = sst.resample(mrkts[pair], "1d"; save=false)
        push!(roc, mrkts[pair].data.close[end] - oneday.close[end])
    end
    df = hcat(r, roc)
    sort!(df, :x1)
end

@doc """Calculates Bollinger Bands for a given market pair over a specified timeframe.

$(TYPEDSIGNATURES)

"""
macro bbranges(pair, timeframe="8h")
    mrkts = esc(:mrkts)
    !isdefined(sst, :bbsstds!) && sst.explore!()
    quote
        df = bb = sst.bbsstds(sst.resample($mrkts[$pair], $timeframe))
        ranges = bb[end, :]
        DataFrame([name => bb[end, n] for (n, name) in enumerate((:low, :mid, :high))])
    end
end

end
