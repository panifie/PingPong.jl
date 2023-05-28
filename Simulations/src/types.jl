using .TimeTicks
using Data: AbstractDataFrame
const DF = Union{DateTime,Float64}
const PricePair = NamedTuple{(:prev, :this),Tuple{DF,DF}}
LastTwo = @NamedTuple begin
    timestamp::PricePair
    open::PricePair
    high::PricePair
    low::PricePair
    close::PricePair
    volume::PricePair
end

@inline lasttwo(arr::AbstractArray) = PricePair((arr[end - 1], arr[end]))

@doc "Get the last two candles of a ohlcv table."
function lasttwo(data::T where {T<:AbstractDataFrame})
    (; (field => lasttwo(getproperty(data, field)) for field in fieldnames(LastTwo))...)
end

macro splatpairs(data, idx, syms...)
    data = esc(data)
    if eltype(syms) == QuoteNode
        syms = [s.value for s in syms]
    end
    idx = esc(idx)
    Expr(
        :tuple,
        [
            :($PricePair(($(data).$(sym)[$idx - 1], $(data).$(sym)[$idx]))) for sym in syms
        ]...,
    )
end

# @doc "Get two adjacent candles of a ohlcv table."
# function attwo(data::T where {T<:AbstractDataFrame}, date::DateTime)
#     (; (field => lasttwo(getproperty(data, field)) for field in fieldnames(LastTwo))...)
# end
#
