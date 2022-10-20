using Misc: timefloat, @as_td
using StatsBase: transform!, transform, fit, ZScoreTransform, UnitRangeTransform

normalize!(arr; unit = false, dims = ndims(arr)) = _normalize(arr; unit, dims, copy = true)
normalize(arr; unit = false, dims = ndims(arr)) = _normalize(arr; unit, dims, copy = false)

function _normalize(arr::AbstractArray; unit = false, dims = ndims(arr), copy = false)
    t = copy ? transform! : transform
    fit(unit ? UnitRangeTransform : ZScoreTransform, arr; dims) |> x -> t(x, arr)
end

@doc "Apply a function over data, resampling data to each timeframe in `tfs`.
`f`: signature is (data; kwargs...)::DataFrame
`tfsum`: sum the scores across multiple timeframes for every pair."
function maptf(
    tfs::AbstractVector{T} where {T<:String},
    data,
    f::Function;
    tfsum = true,
    kwargs...,
)
    res = []
    # sort timeframes
    tfs_idx = tfs .|> Symbol .|> timefloat |> sortperm
    permute!(tfs, tfs_idx)
    unique!(tfs)
    # apply an ordinal 2x weighting formula and normalize it
    tf_weights = [n * 2.0 for (n, _) in enumerate(tfs)]
    tf_weights ./= sum(tf_weights)

    for (n, tf) in enumerate(tfs)
        data_r = resample(data, tf; save = false, progress = false)
        d = f(data_r; kwargs...)
        tfsum || (d[!, :timeframe] .= tf)
        d[!, :score] = d.score .* tf_weights[n]
        push!(res, d)
    end
    df = vcat(res...)
    if tfsum && length(tfs) > 1 && :pair ∈ index(df).names
        g = groupby(df, :pair)
        df = combine(g, :score => sum)
        sort!(df, :score_sum)
    else
        rename!(df, :score => :score_sum)
        select!(df, [:pair, :score_sum])
    end
    df
end
