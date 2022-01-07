struct PairData
    name::String
    tf::String # string
    data::Union{Nothing, AbstractDataFrame} # in-memory data
    z::Union{Nothing, ZArray} # reference zarray
end

PairData(;name, tf, data, z) = PairData(name, tf, data, z)

struct Candle
    timestamp::DateTime
    open::AbstractFloat
    high::AbstractFloat
    low::AbstractFloat
    close::AbstractFloat
    volume::AbstractFloat
end
