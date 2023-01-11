module Orders
using Dates: DateTime, Period
using ..Trades: Order, Signal
using ..Instances: AssetInstance

@doc """A live order tracks in flight trades.

 `date`: the time at which the strategy requested the order.
 `delay`: how much time has passed since the order request \
          and the exchange execution of the order (to account for api issues).
 """
struct LiveOrder1{I<:AssetInstance}
    signal::Signal
    amount::Float64
    asset::Ref{I}
    date::DateTime
    delay::Period
    LiveOrder(a::T, o::Order) where {T<:AssetInstance} = begin
        new{T}(o.signal, o.amount, a)
    end
end

LiveOrder = LiveOrder1

export LiveOrder

end
