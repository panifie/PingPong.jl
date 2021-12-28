import Base.filter

@doc "Filters a list of pairs using a predicate function. The predicate functions must return a `Real` number which will be used for sorting."
function filter(pred::Function, pairs::AbstractDict, min_v::Real, max_v::Real)
    flt = PairData[]
    idx = Real[]
    for (name, p) in pairs
        v = pred(p.data)
        if max_v > v > min_v
            push!(idx, searchsortedfirst(idx, v))
            push!(flt, p)
        end
    end
    flt[idx]
end

function slopefilter(timeframe="1d"; qc="USDT", minv=10., maxv=90., window=20)
    exc[] == pynone && throw("Global exchange variable is not set.")
    pairs = get_pairlist(exc[], qc)
    pairs = load_pairs(zi, exc[], pairs, timeframe)
    pred = x -> slopeangle(x; window)
    filter(pred, pairs, minv, maxv)
end

function slopefilter(pairs::AbstractVector; minv=10., maxv=90., window=20)
    pred = x -> slopeangle(x; window)
    filter(pred, pairs, minv, maxv)
end
