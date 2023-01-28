module Query
include("slope.jl")

@doc "Given a (non-prefixed) exchange name, do the following:
 - load its CCXT instance (if not loaded)
 - load its pairslist and relative data based on configuration
 - apply filtering based on slopeangle
 - save output in the key exchange.name of `results` dict.
 - output is of the form (trg, price, data) where:
   - trg: pairs sorted by slope
   - flt: filtered pairs data
   - data: full data
"
macro excfilter(exc_name)
    @eval begin
        include("slope.jl")
        # using .Exchanges
        # using .Misc
        # explore!()
    end
    quote
        local trg
        @info "timeframe: $(config.timeframe), window: $(config.window), quote: $(config.qc), min_vol: $(config.vol_min)"
        @exchange! $exc_name

        # How should we filter the pairs?
        pred = @λ(x -> slopeangle(x; n=config.window)[end])
        # load the data from exchange with the quote currency and timeframe from config
        data = ((x -> $bt.load_ohlcv($bt.Data.zi, $exc_name, x, config.timeframe))(
            $bt.Exchanges.get_pairlist($exc_name, config.qc)
        ))
        # apply the filter
        flt = $bt.filter(pred, data, config.slope_min, config.slope_max)
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

@doc "Filter pairs in `hs` that are bottomed longs."
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
        append!(bottomed, keys(an.find_bottomed(mrkts; n=r, fb_kwargs...)))
        length(bottomed) < min_n || break
    end
    mask = [p ∈ bottomed for p in hs.pair]
    sort(@view(hs[mask, :]), sort_col)
end

@doc "Filter pairs in `hs` that are peaked shorts."
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
        append!(peaked, keys(an.find_peaked(mrkts; n=r, fb_kwargs...)))
        length(peaked) < min_n || break
    end
    mask = [p ∈ peaked for p in hs.pair]
    sort(@view(hs[mask, :]), sort_col)
end

@doc "Sorted MVP."
function smvp(mrkts)
    mrkts = an.resample(mrkts, "1d"; save=false)
    mvp = DataFrame(an.MVP.discrete_mvp(mrkts)[1])
    mvp[!, :score_sum] = mvp.m .+ mvp.v .+ mvp.p
    sort!(mvp, :score_sum)
end

@doc "The average rate of change for a universe of markets."
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

@doc "The last day price change."
function last_day_roc(r, mrkts)
    roc = []
    for pair in r.pair
        oneday = an.resample(mrkts[pair], "1d"; save=false)
        push!(roc, mrkts[pair].data.close[end] - oneday.close[end])
    end
    df = hcat(r, roc)
    sort!(df, :x1)
end

@doc "Bollinger bands.
- Load data from the `mrkts` variable.
- Resample to given timeframe (8h)
- Return as dataframe."
macro bbranges(pair, timeframe="8h")
    mrkts = esc(:mrkts)
    !isdefined(an, :bbands!) && an.explore!()
    quote
        df = bb = an.bbands(an.resample($mrkts[$pair], $timeframe))
        ranges = bb[end, :]
        DataFrame([name => bb[end, n] for (n, name) in enumerate((:low, :mid, :high))])
    end
end

end
