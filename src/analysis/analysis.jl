module Analysis

using Requires
import Base.filter
using Backtest.Misc: @as_td, PairData, timefloat
using Backtest.Data: @to_mat, data_td, save_pair
using DataFrames: groupby, combine, Not, select!

function __init__()
    ## InformationMeasures.jl ...
    @require Indicators = "70c4c096-89a6-5ec6-8236-da8aa3bd86fd" begin
        @require EffectSizes = "e248de7e-9197-5860-972e-353a2af44d75" nothing
        @require CausalityTools = "5520caf5-2dd7-5c5d-bfcb-a00e56ac49f7" nothing
        @require StatsBase = "2913bbd2-ae8a-5f71-8c99-4fb6c76f3a91" nothing
        @require StatsModels = "3eaba693-59b7-5ba5-a881-562e759f1c8d" function explore!()
            let mod_dir = dirname(@__FILE__)
                include(joinpath(mod_dir, indicators.jl),
                    joinpath(mod_dir, "explore.jl"),)
            end
        end
    end
end

@doc "Filters a list of pairs using a predicate function. The predicate functions must return a `Real` number which will be used for sorting."
function filter(pred::Function, pairs::AbstractDict, min_v::Real, max_v::Real)
    flt = Tuple{AbstractFloat, PairData}[]
    for (name, p) in pairs
        v = pred(p.data)
        if max_v > v > min_v
            push!(flt, (v, p))
        end
    end
    sort!(flt; by=x->x[1])
end

function slopefilter(timeframe="1d"; qc="USDT", minv=10., maxv=90., window=20)
    exc == pynull && throw("Global exchange variable is not set.")
    pairs = get_pairlist(exc, qc)
    pairs = load_pairs(zi, exc, pairs, timeframe)
    pred = x -> slopeangle(x; window)
    filter(pred, pairs, minv, maxv)
end

function slopefilter(pairs::AbstractVector; minv=10., maxv=90., window=20)
    pred = x -> slopeangle(x; window)
    filter(pred, pairs, minv, maxv)
end

function slopeangle(df; window=10)
    size(df, 1) > window || return false
    slope = mlr_slope(@view(df.close[end-window:end]); n=window)[end]
    atan(slope) * (180 / π)
end

@doc "Resamples ohlcv data from a smaller to a higher timeframe."
function resample(pair::PairData, timeframe; save=true)
    @debug @assert all(cleanup_ohlcv_data(data, pair.tf).timestamp .== pair.data.timestamp) "Resampling assumptions are not met, expecting cleaned data."

    @as_td
    src_prd = data_td(pair.data)
    src_td = timefloat(src_prd)

    @assert td > src_td "Upsampling not supported."
    td === src_td && return pair
    frame_size::Integer = td ÷ src_td

    data = pair.data

    # remove incomplete candles at timeseries edges, a full resample requires candles with range 1:frame_size
    left = 1
    while (data.timestamp[left] |> timefloat) % td !== 0.
        left += 1
    end
    right = size(data, 1)
    let last_sample_candle_remainder = src_td * (frame_size - 1)
        while (data.timestamp[right] |> timefloat) % td !== last_sample_candle_remainder
            right -= 1
        end
    end
    data = @view data[left:right, :]
    size(data, 1) === 0 && return _empty_df()

    data[!, :sample] = timefloat.(data.timestamp) .÷ td
    gb = groupby(data, :sample)
    df = combine(gb, :timestamp => first, :open => first, :high => maximum, :low => minimum, :close => last, :volume => sum; renamecols=false)
    select!(data, Not(:sample))
    select!(df, Not(:sample))
    save && save_pair(pair.name, timeframe, df)
    df
end

function resample(mrkts::AbstractDict{String, PairData}, timeframe; save=true)
    rs = Dict()
    for (name, pair_data) in mrkts
        rs[name] = resample(pair_data, timeframe; save)
    end
    rs
end



export explore!

end
