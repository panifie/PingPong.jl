@doc """`PairData` is a low level struct, to attach some metadata to a `ZArray`. (*deprecated*)"
$(FIELDS)

Instead of constructing a `PairData`, directly use the OHLCV `DataFrame` to hold the pair information and the `ZArray` itself.
"""
@kwdef struct PairData
    name::String
    tf::String # string
    data::Union{Nothing,AbstractDataFrame} # in-memory data
    z::Union{Nothing,ZArray} # reference zarray
end

function Base.convert(
    ::Type{AbstractDict{String,N}}, d::AbstractDict{String,PairData}
) where {N<:AbstractDataFrame}
    Dict(p.name => p.data for p in values(d))
end
