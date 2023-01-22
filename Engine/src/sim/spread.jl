using Lang
using Dates: DateTime, now
using TimeTicks
# using DataFrames
# using DataFramesMeta
# using ..Strategies
# using ..Collections
using ..Instances
using Data.DFUtils
using Instruments
using Data.DFUtils

@doc """ A Simple Estimation of Bid Ask spread

NOTE: this calculation can return NaNs
calc mid price
mid_range = (np.log(high) + np.log(low)) / 2
forward mid price
mid_range_1 = (np.log(shift_nb(high, -1)) + np.log(shift_nb(low, -1))) / 2
log_close = np.log(close)
"""
function spread(high::T, low::T, close::T) where {T<:PricePair}
    # The first price of the pair should precede the second in the chronological order
    lcp = log(close.prev)
    max(4
        * (lcp - (log(high.prev) + log(low.prev) / 2))
        * (lcp - (log(high.next) + log(low.next)) / 2), 0)
end

@inline spread(l2::LastTwo) = spread(l2.high, l2.low, l2.close)


# @doc "Get two adjacent candles of a ohlcv table."
# function attwo(data::T where {T<:AbstractDataFrame}, date::DateTime)
#     (; (field => lasttwo(getproperty(data, field)) for field in fieldnames(LastTwo))...)
# end
#
macro foreach(expr, args, el=:el)
    out = :()
    for el in eval(args)
        push!(out.args, @macroexpand1 expr)
    end
    out
end

macro splatpairs(data, idx, syms...)
    data = esc(data)
    if eltype(syms) == QuoteNode
        syms = [s.value for s in syms]
    end
    idx = esc(idx)
    Expr(
        :tuple,
        [:($PricePair(($(data).$(sym)[$idx-1], $(data).$(sym)[$idx])))
         for sym in syms
        ]...
    )
end

@doc "Calc the spread of an asset instance at a specified date.

If date is not provided, the last available date will be considered."
function spreadat(inst::AssetInstance, date::Option{DateTime}=nothing)
    data = first(inst.data).second
    isnothing(date) && (date = data.timestamp[end])
    idx = dateindex(data, date)
    spread((@splatpairs data idx :high :low :close)...)
end

export spreadat
