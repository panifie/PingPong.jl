using TimeTicks
using DataFrames: AbstractDataFrame
const DF = Union{DateTime,Float64}
const PricePair = NamedTuple{(:prev, :next),Tuple{DF,DF}}
LastTwo = @NamedTuple begin
    timestamp::PricePair
    open::PricePair
    high::PricePair
    low::PricePair
    close::PricePair
    volume::PricePair
end

@inline lasttwo(arr::AbstractArray) = PricePair((arr[end-1], arr[end]))

@doc "Get the last two candles of a ohlcv table."
function lasttwo(data::T where {T<:AbstractDataFrame})
    (; (field => lasttwo(getproperty(data, field)) for field in fieldnames(LastTwo))...)
end
