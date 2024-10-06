using ExchangeTypes: Exchange, exc
using Data: @to_mat, save_ohlcv, PairData, empty_ohlcv, DataFrames, Misc
using .Misc.TimeTicks: td_tf, timefloat, @as_td
using .Misc.DocStringExtensions
using .DataFrames: DataFrame, groupby, combine, Not, select!, index, rename!
using Logging: NullLogger, with_logger

# InformationMeasures, EffectSizes...
function _doinit()
end

@doc """Filters and sorts a list of pairs using a predicate function.

$(TYPEDSIGNATURES)

This function takes a list of pairs and a predicate function. It filters the list by applying the predicate function to each pair and keeping only those pairs for which the function returns a `Real` number. The function then sorts the filtered list based on the returned `Real` numbers.

"""
function filterminmax(pred::Function, pairs::AbstractDict, min_v::Real, max_v::Real)
    flt = Tuple{AbstractFloat,PairData}[]
    for (_, p) in pairs
        v = pred(p.data)
        if !ismissing(v) && max_v > v > min_v
            push!(flt, (v, p))
        end
    end
    sort!(flt; by=x -> x[1])
end

@doc """Generates a summary of a vector of tuples containing Floats and PairData.

$(TYPEDSIGNATURES)

This function takes a vector `flt` of tuples, where each tuple contains an AbstractFloat and a PairData. It generates a summary of `flt`, providing insights into the characteristics of the Floats and PairData in the vector.

"""
function fltsummary(flt::AbstractVector{Tuple{AbstractFloat,PairData}})
    [(x[1], x[2].name) for x in flt]
end

fltsummary(flt::AbstractVector{PairData}) = [p.name for p in flt]

include("explore.jl")
include("queries.jl")

using .Query

export fltsummary
