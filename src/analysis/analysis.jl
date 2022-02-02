module Analysis

using Requires
import Base.filter
using Backtest.Misc: @as_td, PairData, timefloat, _empty_df, td_tf
using Backtest.Misc.Pbar
using Backtest.Data: @to_mat, data_td, save_pair
using Backtest.Exchanges: Exchange, exc
using DataFrames: DataFrame, groupby, combine, Not, select!, index
using Logging: NullLogger, with_logger

macro evalmod(files...)
    quote
        with_logger(NullLogger()) do
            for f in $files
                eval(:(include(joinpath(@__DIR__, $f))))
            end
        end
    end
end

function explore!()
    @evalmod "indicators.jl" "explore.jl"
end

macro pairtraits!()
    quote
        @evalmod "slope.jl"
        @evalmod "mvp.jl"
        @evalmod "violations.jl"
        @evalmod "considerations.jl"
        @eval using Backtest.Analysis.MVP, Backtest.Analysis.Violations, Backtest.Analysis.Considerations
    end
end

function __init__()
    ## InformationMeasures.jl ...
    @require Indicators = "70c4c096-89a6-5ec6-8236-da8aa3bd86fd" begin
        @require EffectSizes = "e248de7e-9197-5860-972e-353a2af44d75" :()
        @require CausalityTools = "5520caf5-2dd7-5c5d-bfcb-a00e56ac49f7" :()
        @require StatsBase = "2913bbd2-ae8a-5f71-8c99-4fb6c76f3a91" :()
        @require StatsModels = "3eaba693-59b7-5ba5-a881-562e759f1c8d" :()
    end
end

@doc "Filters a list of pairs using a predicate function. The predicate functions must return a `Real` number which will be used for sorting."
function filter(pred::Function, pairs::AbstractDict, min_v::Real, max_v::Real)
    flt = Tuple{AbstractFloat, PairData}[]
    for (_, p) in pairs
        v = pred(p.data)
        if max_v > v > min_v
            push!(flt, (v, p))
        end
    end
    sort!(flt; by=x->x[1])
end

@doc "Return the summary of a filtered vector of pairdata."
function fltsummary(flt::AbstractVector{Tuple{AbstractFloat, PairData}})
    [(x[1], x[2].name) for x in flt]
end

fltsummary(flt::AbstractVector{PairData}) = [p.name for p in flt]

resample(pair::PairData, timeframe; kwargs...) = resample(exc, pair, timeframe; kwargs...)

@doc "Resamples ohlcv data from a smaller to a higher timeframe."
function resample(exc::Exchange, pair::PairData, timeframe; save=true)
    @debug @assert all(cleanup_ohlcv_data(pair.data, pair.tf).timestamp .== pair.data.timestamp) "Resampling assumptions are not met, expecting cleaned data."
    # NOTE: need at least 2 points
    sz = size(pair.data, 1)
    sz > 1 || return _empty_df()

    @as_td
    src_prd = data_td(pair.data)
    src_td = timefloat(src_prd)

    @assert td >= src_td "Upsampling not supported. (from $(td_tf[src_td]) to $(td_tf[td]))"
    td === src_td && return pair.data
    frame_size::Integer = td ÷ src_td
    sz >= frame_size || return _empty_df()

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
    save && save_pair(exc, pair.name, timeframe, df)
    df
end

resample(mrkts::AbstractDict{String, PairData}, timeframe; kwargs...) = resample(exc, mrkts, timeframe; kwargs...)

function resample(exc::Exchange, mrkts::AbstractDict{String, PairData}, timeframe; save=true, progress=false)
    rs = Dict{String, PairData}()
    progress && @pbar! "Pairs" false
    for (name, pair_data) in mrkts
        rs[name] = PairData(name,
                            timeframe,
                            resample(exc, pair_data, timeframe; save),
                            nothing)
        progress && @pbupdate!
    end
    progress && @pbclose
    rs
end

@doc "Apply a function over data, resampling data to each timeframe in `tfs`.
`f`: signature is (data; kwargs...)::DataFrame"
function maptf(tfs::AbstractVector{T} where T <: String, data, f::Function; kwargs...)
    res = []
    for tf in tfs
        data_r = resample(data, tf; save=false, progress=false)
        d = f(data_r; kwargs...)
        d[!, :timeframe] .= tf
        push!(res, d)
    end
    df = vcat(res...)
    if :pair ∈ index(df).names
        g = groupby(df, :pair)
        df = combine(g, :score => sum)
        sort!(df, :score_sum)
    end
    df
end

export explore!, filter, fltsummary, @evalmod, @pairtraits!

end
