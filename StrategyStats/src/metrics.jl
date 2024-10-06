using Indicators: Indicators;
const ind = Indicators;
using Data.DataFramesMeta
using .Misc: config
using Data: @to_mat, PairData
using .Misc.Lang

@doc """Identifies maximum and minimum points in a DataFrame.

$(TYPEDSIGNATURES)

The `maxmin` function takes the following parameters:

- `df`: a DataFrame in which to identify maxima and minima.
- `order` (optional, default is 1): an integer specifying how many points on each side of a point to use for the comparison to consider the point as a maximum or minimum. For example, if order=3, a point will be considered a maximum if it has three datapoints in either direction that are smaller than it.
- `threshold` (optional, default is 0.0): a threshold value which the datapoint must exceed to be considered a maximum or minimum.
- `window` (optional, default is 100): a window size to apply a moving maximum/minimum filter.

The function identifies maximum and minimum points in the DataFrame `df` based on the specified `order`, `threshold`, and `window`. It then returns a DataFrame with the identified maxima and minima.
"""
function maxmin(df; order=1, threshold=0.0, window=100)
    df[!, :maxima] .= NaN
    df[!, :minima] .= NaN
    dfv = @view df[(window + 2):end, :]
    price = df.close
    # prev_window = window - 2
    @eachrow! dfv begin
        stop = row + window
        # ensure no lookahead bias
        @assert df.timestamp[stop] < :timestamp
        subts = @view(price[row:stop])
        mx = maxima(subts; order, threshold)
        local ma = mi = NaN
        for (n, x) in enumerate(mx)
            if x
                ma = n
                break
            end
        end
        mn = minima(subts; order, threshold)
        for (n, x) in enumerate(mn)
            if x
                mi = n
                break
            end
        end
        :maxima = ma > mi
        :minima = mi > ma
    end
    df
end

@doc """Calculates the success rate of given column against the next candle.

$(TYPEDSIGNATURES)

The `up_successrate` function takes the following parameters:

- `df`: a DataFrame that represents historical market data.
- `bcol`: a Symbol or String that represents the column name in `df` to calculate the success rate against.
- `threshold` (optional, default is 0.05): a threshold value which the price change must exceed to be considered a success.

The function calculates the success rate of a particular strategy indicated by `bcol` for buying or selling. A trade is considered successful if the price change in the next candle exceeds the `threshold`. The direction of the trade (buy or sell) is determined by the `bcol` column: `true` for buy and `false` for sell.

The function returns a float that represents the success rate of the strategy.

"""
function up_successrate(df, bcol::Union{Symbol,String}; threshold=0.05)
    bcol_v = (x -> circshift(x, 1))(getproperty(df, bcol))
    bcol_v[1] = NaN
    rate = 0
    tv = 1 + threshold
    @eachrow df begin
        br = bcol_v[row]
        rate += convert(Int, Bool(isnan(br) ? false : br) && :high / :open > tv)
    end
    rate
end

@doc "Complement of [`up_successrate`](@ref)."
function down_successrate(df, bcol::Union{Symbol,String}; threshold=0.05)
    bcol_v = (x -> circshift(x, 1))(getproperty(df, bcol))
    bcol_v[1] = NaN
    rate = 0
    tv = 1 + threshold
    @eachrow df begin
        br = bcol_v[row]
        rate += convert(Int, Bool(isnan(br) ? false : br) && :open / :low > tv)
    end
    rate
end

@doc """Identifies support and resistance levels in a DataFrame.

$(TYPEDSIGNATURES)

The `supres` function takes the following parameters:

- `df`: a DataFrame in which to identify support and resistance levels.
- `order` (optional, default is 1): an integer specifying how many points on each side of a point to use for the comparison to consider the point as a support or resistance level. For example, if order=3, a point will be considered a support/resistance level if it has three datapoints in either direction that are smaller/larger than it.
- `threshold` (optional, default is 0.0): a threshold value which the datapoint must exceed to be considered a support or resistance level.
- `window` (optional, default is 16): a window size to apply a moving maximum/minimum filter.

The function identifies support and resistance levels in the DataFrame `df` based on the specified `order`, `threshold`, and `window`. It then returns a DataFrame with the identified support and resistance levels.

"""
function supres(df; order=1, threshold=0.0, window=16)
    df[!, :sup] .= NaN
    df[!, :res] .= NaN
    dfv = @view df[(window + 2):end, :]
    price = df.close
    local prev_r, prev_s
    @assert window > 15 # use a large enough window size to prevent zero values
    @eachrow! dfv begin
        stop = row + window
        # ensure no lookahead bias
        @ifdebug @assert df.timestamp[stop] < :timestamp
        subts = @view price[row:stop]
        res = resistance(subts; order, threshold)
        sup = support(subts; order, threshold=-threshold)
        r = findfirst(isfinite, res)
        s = findfirst(isfinite, sup)
        :res = isnothing(r) ? prev_r : prev_r = res[r]
        :sup = isnothing(s) ? prev_s : prev_s = sup[s]
        @ifdebug @assert !iszero(prev_r)
    end
    df
end

@doc """Generates a Renko chart DataFrame.

$(TYPEDSIGNATURES)

The `renkodf` function takes the following parameters:

- `df`: a DataFrame that represents historical market data.
- `box_size` (optional, default is 10.0): a float that represents the box size for the Renko chart. This is the minimum price change required to form a new brick in the chart.
- `use_atr` (optional, default is false): a boolean that indicates whether to use the Average True Range (ATR) to determine the box size. If true, the function will calculate the ATR over `n` periods and use this as the box size.
- `n` (optional, default is 14): an integer that represents the number of periods to calculate the ATR over if `use_atr` is true.

The function generates a Renko chart DataFrame based on the input DataFrame `df` and the specified parameters. Renko charts are price charts with rising and falling bricks (or boxes) that are based on changes in price, not time, unlike most charts. They help filter out market noise and can be a useful tool in technical analysis.
The function returns a DataFrame that represents the Renko chart.

"""
function renkodf(df; box_size=10.0, use_atr=false, n=14)
    local rnk_idx
    if use_atr
        type = Float64
        rnk_idx = renko(@to_mat(@view(df[:, [:high, :low, :close]])); box_size, use_atr, n)
    else
        rnk_idx = renko(df.close; box_size)
    end
    # can't use view on sub dataframes
    rnk_df = df[rnk_idx, [:open, :high, :low, :close, :volume]]
    rnk_df[!, :timestamp] = df.timestamp
    rnk_df
end

@doc "A good renko entry is determined by X candles of the opposite color after Y candles."
function isrenkoentry(df::AbstractDataFrame; head=3, tail=1, long=true, kwargs...)
    size(df, 1) < 1 && return false
    rnk = renkodf(df; kwargs...)
    @assert head > 0 && tail > 0
    size(rnk, 1) > head + tail || return false
    if long
        # if long the tail (the last candles) must be red
        tailcheck = all(rnk.close[end - n] <= rnk.open[end - n] for n in 0:(tail - 1))
        tailcheck || return tailcheck
        # since long, the trend must be green
        headcheck = all(rnk.close[end - n] > rnk.open[end - n] for n in tail:head)
        return headcheck
    else
        # opposite...
        tailcheck = all(rnk.close[end - n] > rnk.open[end - n] for n in 0:(tail - 1))
        tailcheck || return tailcheck
        headcheck = all(rnk.close[end - n] <= rnk.open[end - n] for n in tail:head)
        return headcheck
    end
end

@doc """Determines if the current state in a Renko chart indicates an entry point.

$(TYPEDSIGNATURES)

The `isrenkoentry` function takes the following parameters:

- `data`: an AbstractDict that represents the current state in a Renko chart.
- `kwargs`: a variable number of optional keyword arguments that allow you to specify additional criteria for an entry point.

The function determines if the current state in the Renko chart represented by `data` indicates an entry point based on the specified criteria. An entry point in a Renko chart is typically determined by a change in the direction of the bricks (or boxes).

The function returns a boolean that indicates whether the current state represents an entry point.

"""
function isrenkoentry(data::AbstractDict; kwargs...)
    out = Bool[]
    for (_, p) in data
        isrenkoentry(p.data; kwargs...) && push!(out, p.name)
    end
    out
end

@doc """Generates a grid of Renko charts with varying parameters.

$(TYPEDSIGNATURES)

The `gridrenko` function takes the following parameters:

- `data`: an AbstractDataFrame that represents historical market data.
- `head_range` (optional, default is 1:10): a range that represents the range of possible values for the head in the Renko chart. The head is the most recent part of the chart.
- `tail_range` (optional, default is 1:3): a range that represents the range of possible values for the tail in the Renko chart. The tail is the oldest part of the chart.
- `n_range` (optional, default is 10:10:200): a range that represents the range of possible values for the number of periods to calculate the Average True Range (ATR) over.

The function generates a grid of Renko charts based on the input DataFrame `data` and the specified parameters. Each chart in the grid uses a different combination of `head_range`, `tail_range`, and `n_range`.
The function returns a DataFrame that represents the grid of Renko charts.

"""
function gridrenko(
    data::AbstractDataFrame; head_range=1:10, tail_range=1:3, n_range=10:10:200
)
    out = []
    for head in head_range, tail in tail_range, n in n_range
        if isrenkoentry(data; head, tail, n)
            push!(out, (; head, tail, n))
        end
    end
    out
end

@doc "[`gridrenko`](@ref) over a dict of `PairData`."
function gridrenko(data::AbstractDict; as_df=false, kwargs...)
    out = Dict()
    for (_, p) in data
        trials = gridrenko(p.data; kwargs...)
        length(trials) > 0 && setindex!(out, trials, p.name)
    end
    as_df && return DataFrame(vcat(values(out)...))
    out
end

@doc """Adds Bollinger Bands to a DataFrame.

$(TYPEDSIGNATURES)

The `bbands!` function takes the following parameters:

- `df`: an AbstractDataFrame to which the Bollinger Bands will be added.
- `kwargs`: a variable number of optional keyword arguments that allow you to specify additional parameters for the Bollinger Bands.

The function calculates the Bollinger Bands for the data in `df` based on the specified parameters in `kwargs`. Bollinger Bands are a type of statistical chart characterizing the prices and volatility over time of a financial instrument or commodity, using a formulaic method propounded by John Bollinger in the 1980s.
The function modifies the input DataFrame `df` in place by adding the calculated Bollinger Bands.

"""
function bbands!(df::AbstractDataFrame; kwargs...)
    local bb
    bbcols = [:bb_low, :bb_mid, :bb_high]
    bb = bbands(df; kwargs...)
    if bbcols[1] ∈ getfield(df, :colindex).names
        df[!, bbcols] = bb
    else
        insertcols!(
            df, [c => @view(bb[:, n]) for (n, c) in enumerate(bbcols)]...; copycols=false
        )
    end
    df
end

function Indicators.bbands(df::AbstractDataFrame; kwargs...)
    Indicators.bbands(df.close; kwargs...)
end

using Base.Iterators: countfrom, take
using Base.Threads: @spawn
const Float = typeof(0.0)

@doc """Generates a grid of Bollinger Bands with varying parameters.

$(TYPEDSIGNATURES)

The `gridbbands` function takes the following parameters:

- `df`: an AbstractDataFrame that represents historical market data.
- `n_range` (optional, default is 2:2:100): a range that represents the range of possible values for the number of periods to calculate the moving average over.
- `sigma_range` (optional, default is [1.0]): an array that represents the range of possible values for the number of standard deviations to calculate the bands at.
- `corr` (optional, default is :corke): a symbol that represents the correlation method to use.

The function generates a grid of Bollinger Bands based on the input DataFrame `df` and the specified parameters. Each band in the grid uses a different combination of `n_range` and `sigma_range`.

The function returns a DataFrame that represents the grid of Bollinger Bands.

"""
function gridbbands(df::AbstractDataFrame; n_range=2:2:100, sigma_range=[1.0], corr=:corke)
    out = Dict()
    out_df = []
    # out_df = IdDict(n => [] for n in 1:Threads.nthreads())
    if n_range isa UnitRange
        n_range = (n_range.start):min(size(df, 1) - 1, n_range.stop)
    elseif n_range isa StepRange
        n_range = (n_range.start):(n_range.step):min(size(df, 1) - 1, n_range.stop)
    end
    local postproc
    if eval(corr) isa Function
        corfn = getproperty(@__MODULE__, corr)
        postproc =
            (n, bb) -> begin
                vals = collect(
                    corfn(@view(bb[:, col1][n:end]), @view(getproperty(df, col2)[n:end])) for (col1, col2) in ((1, :low), (2, :close), (2, :high))
                )
                (; bb_low_corr=vals[1], bb_mid_corr=vals[2], bb_high_corr=vals[3])
            end
    else
        postproc = (_, _) -> (nothing, nothing, nothing)
    end
    # p = Progress(length(n_range) * length(sigma_range))
    th = []
    l = ReentrantLock()
    for n in n_range, sigma in sigma_range
        push!(th, Threads.@spawn begin
            bb = bbands(df; n, sigma)
            co = postproc(n, bb)
            lock(l)
            push!(out_df, (; n, sigma, co...))
            size(bb, 1) > 0 && setindex!(out, bb, (; n, sigma))
            # next!(p)
            unlock(l)
        end)
    end
    for t in th
        wait(t)
    end
    out, DataFrame(out_df)
end

macro checksize(data=nothing)
    ohlcv = isnothing(data) ? esc(:ohlcv) : esc(data)
    n = esc(:n)
    quote
        size($ohlcv, 1) <= $n && return false
    end
end

@doc """Determines if a peak has occurred in the OHLCV data.

$(TYPEDSIGNATURES)

The `is_peaked` function takes the following parameters:

- `ohlcv`: a DataFrame that represents OHLCV (Open, High, Low, Close, Volume) data.
- `thresh` (optional, default is 0.05): a threshold value which the price change must exceed to be considered a peak.
- `n` (optional, default is 26): an integer that represents the number of periods to consider for the peak detection.
"""
function is_peaked(ohlcv::DataFrame; thresh=0.05, n=26)
    @checksize
    bb = bbands(ohlcv; n)
    ohlcv.close[end] / bb[end, 3] > 1 + thresh
end

function is_peaked(ohlcv::DataFrame, bb::AbstractArray; thresh=0.05)
    @checksize
    ohlcv.close[end] / bb[end, 3] > 1 + thresh
end

@doc """Determines if a bottom has occurred in the OHLCV data.

$(TYPEDSIGNATURES)

The `is_bottomed` function takes the following parameters:

- `ohlcv`: a DataFrame that represents OHLCV (Open, High, Low, Close, Volume) data.
- `thresh` (optional, default is 0.05): a threshold value which the price change must exceed to be considered a bottom.
- `n` (optional, default is 26): an integer that represents the number of periods to consider for the bottom detection.

The function determines if a bottom has occurred in the OHLCV data based on the specified threshold and number of periods. A bottom is considered to have occurred when the price change exceeds the threshold within the given number of periods.
The function returns a boolean that indicates whether a bottom has occurred.

"""
function is_bottomed(ohlcv::DataFrame; thresh=0.05, n=26)
    @checksize
    bb = bbands(ohlcv; n)
    ohlcv.close[end] / bb[end, 1] < 1 + thresh
end

function is_bottomed(ohlcv::DataFrame, bb::AbstractArray; thresh=0.05)
    @checksize
    ohlcv.close[end] / bb[end, 1] < 1 + thresh
end

@doc """Determines if an uptrend has occurred in the OHLCV data.

$(TYPEDSIGNATURES)

The `is_uptrend` function takes the following parameters:

- `ohlcv`: a DataFrame that represents OHLCV (Open, High, Low, Close, Volume) data.
- `thresh` (optional, default is 0.05): a threshold value which the price change must exceed to be considered an uptrend.
- `n` (optional, default is 26): an integer that represents the number of periods to consider for the uptrend detection.

The function determines if an uptrend has occurred in the OHLCV data based on the specified threshold and number of periods. An uptrend is considered to have occurred when the price change exceeds the threshold within the given number of periods.
"""
function is_uptrend(ohlcv::DataFrame; thresh=0.05, n=26)
    @checksize
    ind.momentum(@view(ohlcv.close[(end - n):end]); n)[end] > thresh
end

# function is_lowvol(ohlcv::DataFrame; thresh=0.05, n=3) end

include("slope.jl")
