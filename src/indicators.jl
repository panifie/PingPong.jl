using Temporal: TS
using Indicators
using DataFramesMeta
using ProgressMeter

macro as_ts(df, c1, cols...)
    df = esc(df)
    local columns
    if cols[1] isa QuoteNode
        columns = [c.value for c in cols]::Vector{Symbol}
        @show columns
        return
    else
        @assert size(cols, 1) === 1
        columns = esc(cols[1])
    end
    if length(cols) === 0
        quote
            TS(getproperty($df, $c1), $df.timestamp, $c1)
        end
    else
        quote
            if !isdefined(Main, :type)
                type = Float64
            end
            idx = hasproperty($df, :timestamp) ? $(df).timestamp : $(esc(:dates))
            ns = vcat([$c1]::Vector{Symbol}, $columns::Vector{Symbol})
	        TS(@to_mat(@view($df[:, ns])), idx, ns)
        end
    end
end

function maxmin(df; order=1, threshold=0.0, window=100)
    df[!, :maxima] .= NaN
    df[!, :minima] .= NaN
    dfv = @view df[window+2:end, :]
    price = df.close
    # prev_window = window - 2
    @eachrow! dfv begin
        stop = row+window
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

isdown(threshold) = !isup(threshold)

@doc "Calculate successrate of given column against next candle.
`direction`: `true` is buy, `false` is sell."
function up_successrate(df, bcol::Union{Symbol, String}; threshold=0.05)
    bcol_v = getproperty(df, bcol) |> x -> circshift(x, 1)
    bcol_v[1] = NaN
    rate = 0
    tv = 1 + threshold
    @eachrow df begin
        br = bcol_v[row]
        rate += convert(Int, Bool(isnan(br) ? false : br) && :high / :open > tv)
    end
    rate
end

function down_successrate(df, bcol::Union{Symbol, String}; threshold=0.05)
    bcol_v = getproperty(df, bcol) |> x -> circshift(x, 1)
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
function supres(df; order=1, threshold=0., window=16)
    df[!, :sup] .= NaN
    df[!, :res] .= NaN
    dfv = @view df[window+2:end, :]
    price = df.close
    local prev_r, prev_s
    @assert window > 15 # use a large enough window size to prevent zero values
    @eachrow! dfv begin
        stop = row+window
        # ensure no lookahead bias
        @debug @assert df.timestamp[stop] < :timestamp
        subts = @view price[row:stop]
        res = resistance(subts; order, threshold)
        sup = support(subts; order, threshold=-threshold)
        r = findfirst(isfinite, res)
        s = findfirst(isfinite, sup)
        :res = isnothing(r) ? prev_r : prev_r = res[r]
        :sup = isnothing(s) ? prev_s : prev_s = sup[s]
        @debug @assert !iszero(prev_r)
    end
    df
end

function renkodf(df; box_size=10., use_atr=false, n=14)
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
        tailcheck = all(rnk.close[end-n] <= rnk.open[end-n] for n in 0:tail-1)
        tailcheck || return tailcheck
        # since long, the trend must be green
        headcheck = all(rnk.close[end-n] > rnk.open[end-n] for n in tail:head)
        return headcheck
    else
        # opposite...
        tailcheck = all(rnk.close[end-n] > rnk.open[end-n] for n in 0:tail-1)
        tailcheck || return tailcheck
        headcheck = all(rnk.close[end-n] <= rnk.open[end-n] for n in tail:head)
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

function gridrenko(data::AbstractDataFrame; head_range=1:10, tail_range=1:3, n_range=10:10:200)
    out = []
    for head in head_range,
        tail in tail_range,
        n in n_range
        if isrenkoentry(data; head, tail, n)
            push!(out, (;head, tail, n))
        end
    end
    out
end

function gridrenko(data::AbstractDict; as_df=false, kwargs...)
    out = Dict()
    @showprogress for (_, p) in data
        trials = gridrenko(p.data; kwargs...)
        length(trials) > 0 && setindex!(out, trials, p.name)
    end
    as_df && return DataFrame(vcat(values(out)...))
    out
end

function bbands(df::AbstractDataFrame; kwargs...)
    local bb
    bbcols = [:bb_low, :bb_mid, :bb_high]
    @with df begin
        bb = Indicators.bbands(:close; kwargs...)
    end
    if bbcols[1] ∈ getfield(df, :colindex).names
        df[:, bbcols] = bb
    else
        insertcols!(df, [c => bb[n] for (n, c) in enumerate(bbcols)]...)
    end
    df
end

using Base.Iterators: countfrom, take
function gridbbands(df::AbstractDataFrame; n_range=3:1000, sigma_range=collect(take(countfrom(1., 0.1), 21)), corr=true)
    out = Dict()
    out_df = []
    n_range = n_range.start:min(size(df, 1) - 1, n_range.stop)
    local postproc
    if corr
        postproc = n -> begin
            vals = collect(corsp(@view(getproperty(df, col1)[n:end]),
                                 @view(getproperty(df, col2)[n:end, :]))
            for (col1, col2) in ((:bb_low, :low), (:bb_mid, :close), (:bb_high, :high)))
            (;bb_low=vals[1], bb_mid=vals[2], bb_high=vals[3])
        end
    else
        postproc = identity
    end
    @showprogress for n in n_range,
        sigma in sigma_range
        trials = bbands(df; n, sigma)
        co = postproc(n)
        push!(out_df, (;n, sigma, co...))
        size(trials, 1) > 0 && setindex!(out, trials, (;n, sigma))
    end
    out, DataFrame(out_df)
end
