module Analysis

using Requires
import Base.filter
using Misc: @evalmod, @as_td, PairData, timefloat, _empty_df, td_tf
using Pbar
using Data: @to_mat, data_td, save_pair
using Exchanges: Exchange, exc
using DataFrames: DataFrame, groupby, combine, Not, select!, index, rename!
using Logging: NullLogger, with_logger
using LegibleLambdas

function __init__()
    ## InformationMeasures.jl ...
    @require Indicators = "70c4c096-89a6-5ec6-8236-da8aa3bd86fd" begin
        @require EffectSizes = "e248de7e-9197-5860-972e-353a2af44d75" :()
        @require CausalityTools = "5520caf5-2dd7-5c5d-bfcb-a00e56ac49f7" :()
        @require StatsBase = "2913bbd2-ae8a-5f71-8c99-4fb6c76f3a91" :()
        @require StatsModels = "3eaba693-59b7-5ba5-a881-562e759f1c8d" :()
        include("metrics.jl")
        include("explore.jl")
    end
end

@doc "Filters a list of pairs using a predicate function. The predicate functions must return a `Real` number which will be used for sorting."
function filter(pred::Function, pairs::AbstractDict, min_v::Real, max_v::Real)
    flt = Tuple{AbstractFloat,PairData}[]
    for (_, p) in pairs
        v = pred(p.data)
        if !ismissing(v) && max_v > v > min_v
            push!(flt, (v, p))
        end
    end
    sort!(flt; by = @λ(x -> x[1]))
end

@doc "Return the summary of a filtered vector of pairdata."
function fltsummary(flt::AbstractVector{Tuple{AbstractFloat,PairData}})
    [(x[1], x[2].name) for x in flt]
end

fltsummary(flt::AbstractVector{PairData}) = [p.name for p in flt]

@doc "Loads the Mark module."
function mark!()
    dir = @__DIR__
    modpath = joinpath(dir |> dirname, "Mark")
    if modpath ∉ Base.LOAD_PATH
        push!(Base.LOAD_PATH, modpath)
    end
end

export explore!, filter, fltsummary, mark!

end
