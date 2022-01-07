using StatsBase: corspearman, corkendall, corkendall!
using StatsModels: lag, lead
# import StatsBase: corspearman

corsp(x, data::AbstractDataFrame; col=:close, kwargs...) = corsp(x, getproperty(data, col); kwargs...)

@doc "Compute spearman correlation between `x` and `y`, where `y` is shifted forward (lead)."
function corsp(x::AbstractArray, y::AbstractArray; n_lead=1, default=NaN)
    @assert n_lead > 0
    corspearman(
        @view(x[begin:end-n_lead]),
          @view(lead(y, n_lead; default)[begin:end-n_lead]))
end
