using Pbar
using ExchangeTypes: Exchange
using Lang: passkwargs
using TimeTicks
using Data: data_td, save_ohlcv, PairData, empty_ohlcv
using Data.DFUtils
using DataFrames

function resample(exc::Exchange, pair::PairData, to_tf; kwargs...)
    begin
        resample(exc, pair.name, pair.data, pair.tf, to_tf; kwargs...)
    end
end

@doc "Resamples ohlcv data from a smaller to a higher timeframe."
function resample(exc::Exchange, pairname, data, from_tf, to_tf; save=false)
    @debug @assert all(cleanup_ohlcv_data(data, from_tf).timestamp .== data.timestamp) \
        "Resampling assumptions are not met, expecting cleaned data."
    # NOTE: need at least 2 points
    sz = size(data, 1)
    sz > 1 || return empty_ohlcv()

    td = timefloat(to_tf)
    # src_prd = data_td(data)
    src_prd = timeframe(data).period
    src_td = timefloat(src_prd)

    @assert td >= src_td "Upsampling not supported. (from $((td_tf[src_td])) to $(td_tf[td]))"
    td === src_td && return data
    frame_size::Integer = td ÷ src_td
    sz >= frame_size || return empty_ohlcv()

    # remove incomplete candles at timeseries edges, a full resample requires candles with range 1:frame_size
    left = 1
    while (timefloat(data.timestamp[left])) % td !== 0.0
        left += 1
    end
    right = size(data, 1)
    let last_sample_candle_remainder = src_td * (frame_size - 1)
        while (timefloat(data.timestamp[right])) % td !== last_sample_candle_remainder
            right -= 1
        end
    end

    # Create a new dataframe to keep thread safety
    data = DataFrame(@view(data[left:right, :]); copycols=false)
    size(data, 1) === 0 && return empty_ohlcv()

    data[!, :sample] = timefloat.(data.timestamp) .÷ td
    gb = groupby(data, :sample)
    df = combine(
        gb,
        :timestamp => first,
        :open => first,
        :high => maximum,
        :low => minimum,
        :close => last,
        :volume => sum;
        renamecols=false,
    )
    select!(data, Not(:sample))
    select!(df, Not(:sample))
    save && size(df)[1] > 0 && save_ohlcv(exc, pairname, string(to_tf), df)
    @debug @show "last 2 candles: " df[end - 1, :timestamp] df[end, :timestamp]
    df
end

function resample(
    exc::Exchange,
    mrkts::AbstractDict{String,PairData},
    timeframe;
    save=true,
    progress=false,
)
    rs = Dict{String,PairData}()
    progress && @pbar! "Instruments" false
    try
        for (name, pair_data) in mrkts
            rs[name] = PairData(
                name, timeframe, resample(exc, pair_data, timeframe; save), nothing
            )
            progress && @pbupdate!
        end
    finally
        progress && @pbclose
    end
    rs
end

# resample(pair::PairData, timeframe; kwargs...) = resample(exc, pair, timeframe; kwargs...)
# macro resample(mrkts::AbstractDict{String,PairData}, timeframe::String, args...)
macro resample(params, mrkts, timeframe, args...)
    e = esc(:Exchanges)
    kwargs = passkwargs(args...)
    m = esc(mrkts)
    quote
        resample($(e).exc, $m, $timeframe; $(kwargs...))
    end
end

export resample, @resample
