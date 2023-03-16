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
