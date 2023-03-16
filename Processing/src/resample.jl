using TimeTicks
using Lang: passkwargs, @ifdebug
using Base: beginsym
using Data: zi, save_ohlcv, PairData, empty_ohlcv, DataFrames
using Data.DFUtils
using .DataFrames
using Pbar

# remove incomplete candles at timeseries edges, a full resample requires candles with range 1:frame_size
function _left_and_right(data, frame_size, src_td, td)
    left = 1
    while (timefloat(data.timestamp[left])) % td != 0.0
        left += 1
    end
    right = size(data, 1)
    let last_sample_candle_remainder = src_td * (frame_size - 1)
        while (timefloat(data.timestamp[right])) % td != last_sample_candle_remainder
            right -= 1
        end
    end
    left, right
end

function _deltas(data, to_tf)
    # NOTE: need at least 2 points
    result(f=NaN, s=NaN, t=NaN; abort=nothing) = (f, s, t, abort)
    sz = size(data, 1)
    sz > 1 || return result(; abort=empty_ohlcv())

    td = timefloat(to_tf)
    src_prd = timeframe(data).period
    src_td = timefloat(src_prd)

    @assert td >= src_td "Upsampling not supported. (from $((td_tf[src_td])) to $(td_tf[td]))"
    td === src_td && return result(; abort=data)
    frame_size::Integer = td ÷ src_td
    sz >= frame_size || return result(; abort=empty_ohlcv())
    result(frame_size, src_td, td)
end

@doc "Resamples ohlcv data from a smaller to a higher timeframe."
function resample(data, from_tf, to_tf)
    @ifdebug @assert all(cleanup_ohlcv_data(data, from_tf).timestamp .== data.timestamp) \
        "Resampling assumptions are not met, expecting cleaned data."

    frame_size, src_td, td, abort = _deltas(data, to_tf)
    isnothing(abort) || return abort
    left, right = _left_and_right(data, frame_size, src_td, td)

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
    @debug "last 2 candles: " df[end - 1, :timestamp] df[end, :timestamp]
    df
end
@doc """Resamples data, and saves to storage.

!!! warning "Usually not worth it"
    Resampling is quite fast, so it is simpler to keep only the smaller timeframe
    on storage, and resample the longer ones on demand.

"""
function resample(args...; exc_name, name)
    df = resample(args...)
    if size(df)[1] > 0
        save_ohlcv(zi, exc_name, name, string(last(args)), df)
    end
    df
end

function resample(pair::PairData, to_tf)
    from_tf = convert(TimeFrame, pair.tf)
    to_tf = convert(TimeFrame, to_tf)
    resample(pair.data, from_tf, to_tf)
end

function resample(mkts::AbstractDict{String,PairData}, timeframe; progress=false)
    rs = Dict{String,PairData}()
    progress && @pbar! mkts "Instruments"
    try
        lock = ReentrantLock()
        Threads.@threads for (name, pair_data) in collect(mkts)
            v = PairData(name, timeframe, resample(pair_data, timeframe), nothing)
            @lock lock rs[name] = v
            progress && @pbupdate!
        end
    finally
        progress && @pbclose!
    end
    rs
end

# resample(pair::PairData, timeframe; kwargs...) = resample(exc, pair, timeframe; kwargs...)
# macro resample(mkts::AbstractDict{String,PairData}, timeframe::String, args...)
macro resample(params, mkts, timeframe, args...)
    e = esc(:Exchanges)
    kwargs = passkwargs(args...)
    m = esc(mkts)
    quote
        resample($(e).exc, $m, $timeframe; $(kwargs...))
    end
end

export resample, @resample
