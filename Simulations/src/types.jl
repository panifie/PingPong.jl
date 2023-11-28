using .TimeTicks
using Data: AbstractDataFrame
@doc "A constant `DF` representing a union of `DateTime` and `Float64` types."
const DF = Union{DateTime,Float64}
@doc """ A named tuple `PricePair` representing the previous and current values of a data field.

$(FIELDS)

The `PricePair` is used to store and access the last two values of a data field in a DataFrame. 
It is a NamedTuple with two fields: `:prev` and `:this`, representing the previous and current values respectively. 
This is particularly useful when comparing or calculating differences between the last two values of a data field.
"""
const PricePair = NamedTuple{(:prev, :this),Tuple{DF,DF}}
@doc """ A named tuple `LastTwo` representing the last two values of each field in a OHLCV data.

$(FIELDS)

The `LastTwo` is used to store and access the last two values of each field in a OHLCV data. 
It is a NamedTuple with fields: `:timestamp`, `:open`, `:high`, `:low`, `:close`, and `:volume`, each of which is a `PricePair` representing the previous and current values respectively. 
This is particularly useful when comparing or calculating differences between the last two values of each field in a OHLCV data.
"""
const LastTwo = @NamedTuple begin
    timestamp::PricePair
    open::PricePair
    high::PricePair
    low::PricePair
    close::PricePair
    volume::PricePair
end

@doc """ Returns a `PricePair` of the last two elements in an array.

$(TYPEDSIGNATURES)

The function `lasttwo` takes an `AbstractArray` as input and returns a `PricePair` containing the last two elements of the array. 
"""
lasttwo(arr::AbstractArray) = PricePair((arr[end - 1], arr[end]))

@doc """ Returns the last two values of each field in a OHLCV data as a `LastTwo` named tuple.

$(TYPEDSIGNATURES)

The function `lasttwo` takes an `AbstractDataFrame` as input and returns a `LastTwo` named tuple. 
Each field in the `LastTwo` named tuple is a `PricePair` representing the last two values of the corresponding field in the input data.
"""
function lasttwo(data::T where {T<:AbstractDataFrame})
    (; (field => lasttwo(getproperty(data, field)) for field in fieldnames(LastTwo))...)
end

@doc """ Generates a tuple of `PricePair` for each symbol in a given data at a specific index.

$(TYPEDSIGNATURES)

The macro `splatpairs` takes a data object, an index, and a variable number of symbols as input. 
It generates a tuple where each element is a `PricePair` of the symbol's values at the given index and the previous index in the data. 
This is useful when you need to create a tuple of `PricePair` for multiple symbols in a data object at a specific index.
"""
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
