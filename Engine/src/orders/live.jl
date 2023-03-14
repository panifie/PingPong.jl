module LiveOrders
using Data: Candle
using ExchangeTypes
using ..Instances: AssetInstance
using TimeTicks
using Instruments
using ..Orders

# TYPENUM
@doc """ Live orders can hold additional info about live execution. They are short lived

`delay`: how much time has passed since the order request \
          and the exchange execution of the order (to account for api issues).
"""
mutable struct LiveOrder5{O<:OrderType,A<:AbstractAsset,E<:ExchangeID}
    asset::Ref{AssetInstance{A,E}}
    order::Order{O,A,E}
    delay::Millisecond
    function LiveOrder5(
        i::AssetInstance{A,E}, o::Order{O,A,E}; delay=ms(0)
    ) where {O<:OrderType,A<:AbstractAsset,E<:ExchangeID}
        new{O,A,E}(i, o, date, delay)
    end
    function LiveOrder5(a::AssetInstance, amount::Float64; delay=ms(0), kwargs...)
        order = Order(a.asset, a.exc.id; amount, kwargs...)
        LiveOrder5(order; delay)
    end
end

LiveOrder = LiveOrder5

export LiveOrder

end
