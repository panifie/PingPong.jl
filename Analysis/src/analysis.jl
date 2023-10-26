using ExchangeTypes: Exchange, exc
using Data: @to_mat, save_ohlcv, PairData, empty_ohlcv, DataFrames, Misc
using .Misc.TimeTicks: td_tf, timefloat, @as_td
using .DataFrames: DataFrame, groupby, combine, Not, select!, index, rename!
using Logging: NullLogger, with_logger

# InformationMeasures, EffectSizes...
function _doinit()
end

@doc "Filters a list of pairs using a predicate function. The predicate functions must return a `Real` number which will be used for sorting."
function Base.filter(pred::Function, pairs::AbstractDict, min_v::Real, max_v::Real)
    flt = Tuple{AbstractFloat,PairData}[]
    for (_, p) in pairs
        v = pred(p.data)
        if !ismissing(v) && max_v > v > min_v
            push!(flt, (v, p))
        end
    end
    sort!(flt; by=x -> x[1])
end

@doc "Return the summary of a filtered vector of pairdata."
function fltsummary(flt::AbstractVector{Tuple{AbstractFloat,PairData}})
    [(x[1], x[2].name) for x in flt]
end

fltsummary(flt::AbstractVector{PairData}) = [p.name for p in flt]

@doc "Loads the Mark module."
function mark!()
    dir = @__DIR__
    modpath = joinpath(dirname(dir), "Mark")
    if modpath ∉ Base.LOAD_PATH
        push!(Base.LOAD_PATH, modpath)
    end
end

export fltsummary, mark!
