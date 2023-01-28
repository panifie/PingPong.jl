@doc "Implements the universe filtering strategy by Mark Minervini."
module Mark
using Requires
using Long
using Short
using Analysis
using DataFrames: groupby, combine

@doc "Calculate metrics based on:
- Long: positive score
- Stage 2: stage 2 calculation only (still positive)
- Short: negative score.
- After Calculation, their normalization is summed together to obtain a net balance.
- Display the tail and the head of the sorted pairlist with its score.
- Return the edges (head, tail) and the full results as a tuple."
function vcons(data, tfs=[]; cargs=(), vargs=(), sargs=(), onevi=false)
    datargs = isempty(tfs) ? (data,) : (data, tfs)
    @info "Longs..."
    c_t = @async Long.long(datargs...; cargs..., sorted=false)
    @info "Stage 2..."
    s_t = @async Long.stage2(datargs...; sargs..., sorted=false)
    @info "Shorts..."
    onevi && (datargs = isempty(tfs) ? (data,) : (data, tfs[end:end]))
    v_t = @async Short.short(datargs...; vargs..., sorted=false)

    c = (wait(c_t); c_t.result)
    s = (wait(s_t); s_t.result)
    v = (wait(v_t); v_t.result)

    @info "Merging..."
    sk = length(datargs) > 1 ? :score_sum : :score
    t = vcat(c, s, v)
    gb = groupby(t, :pair)
    res = combine(gb, sk => sum; renamecols=false)
    sort!(res, sk)
    edges = vcat((@views res[1:10, :], res[(end - 10):end, :])...)
    display(edges)
    edges, res
end

export testmark

end # module Mark
