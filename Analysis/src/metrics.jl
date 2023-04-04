using Indicators: Indicators;
const ind = Indicators;
using Data.DataFramesMeta
using Misc: config
using Data: @to_mat, PairData
using Lang

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

@doc "Calculate successrate of given column against next candle.
`direction`: `true` is buy, `false` is sell."
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

@doc "This support and resistance functions from Indicators appear to be too inaccurate despite parametrization."
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

function isrenkoentry(data::AbstractDict; kwargs...)
    out = Bool[]
    for (_, p) in data
        isrenkoentry(p.data; kwargs...) && push!(out, p.name)
    end
    out
end

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

function gridrenko(data::AbstractDict; as_df=false, kwargs...)
    out = Dict()
    for (_, p) in data
        trials = gridrenko(p.data; kwargs...)
        length(trials) > 0 && setindex!(out, trials, p.name)
    end
    as_df && return DataFrame(vcat(values(out)...))
    out
end

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

function is_peaked(ohlcv::DataFrame; thresh=0.05, n=26)
    @checksize
    bb = bbands(ohlcv; n)
    ohlcv.close[end] / bb[end, 3] > 1 + thresh
end

function is_peaked(ohlcv::DataFrame, bb::AbstractArray; thresh=0.05)
    @checksize
    ohlcv.close[end] / bb[end, 3] > 1 + thresh
end

function is_bottomed(ohlcv::DataFrame; thresh=0.05, n=26)
    @checksize
    bb = bbands(ohlcv; n)
    ohlcv.close[end] / bb[end, 1] < 1 + thresh
end

function is_bottomed(ohlcv::DataFrame, bb::AbstractArray; thresh=0.05)
    @checksize
    ohlcv.close[end] / bb[end, 1] < 1 + thresh
end

function is_uptrend(ohlcv::DataFrame; thresh=0.05, n=26)
    @checksize
    ind.momentum(@view(ohlcv.close[(end - n):end]); n)[end] > thresh
end

function is_lowvol(ohlcv::DataFrame; thresh=0.05, n=3) end

include("corr.jl")
include("slope.jl")
