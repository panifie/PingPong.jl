using Misc.Pbar
using Misc: Exchange, PairData

resample(pair::PairData, timeframe; kwargs...) = resample(exc, pair, timeframe; kwargs...)

@doc "Resamples ohlcv data from a smaller to a higher timeframe."
function resample(exc::Exchange, pair::PairData, timeframe; save=false)
    @debug @assert all(
        cleanup_ohlcv_data(pair.data, pair.tf).timestamp .== pair.data.timestamp,
    ) "Resampling assumptions are not met, expecting cleaned data."
    # NOTE: need at least 2 points
    sz = size(pair.data, 1)
    sz > 1 || return _empty_df()

    @as_td
    src_prd = data_td(pair.data)
    src_td = timefloat(src_prd)

    @assert td >= src_td "Upsampling not supported. (from $((td_tf[src_td])) to $(td_tf[td]))"
    td === src_td && return pair.data
    frame_size::Integer = td ÷ src_td
    sz >= frame_size || return _empty_df()

    data = pair.data


    # remove incomplete candles at timeseries edges, a full resample requires candles with range 1:frame_size
    left = 1
    while (data.timestamp[left] |> timefloat) % td !== 0.0
        left += 1
    end
    right = size(data, 1)
    let last_sample_candle_remainder = src_td * (frame_size - 1)
        while (data.timestamp[right] |> timefloat) % td !== last_sample_candle_remainder
            right -= 1
        end
    end

    # Create a new dataframe to keep thread safety
    data = DataFrame(@view(data[left:right, :]); copycols=false)
    size(data, 1) === 0 && return _empty_df()

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
        renamecols=false
    )
    select!(data, Not(:sample))
    select!(df, Not(:sample))
    save && save_pair(exc, pair.name, timeframe, df)
    df
end

resample(mrkts::AbstractDict{String,PairData}, timeframe; kwargs...) =
    resample(exc, mrkts, timeframe; kwargs...)

function resample(
    exc::Exchange,
    mrkts::AbstractDict{String,PairData},
    timeframe;
    save=true,
    progress=false
)
    rs = Dict{String,PairData}()
    progress && @pbar! "Pairs" false
    for (name, pair_data) in mrkts
        rs[name] =
            PairData(name, timeframe, resample(exc, pair_data, timeframe; save), nothing)
        progress && @pbupdate!
    end
    progress && @pbclose
    rs
end
