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
mutable struct LiveOrder5{A<:AbstractAsset,E<:ExchangeID}
    asset::Ref{AssetInstance{A,E}}
    order::Order{A,E}
    delay::Millisecond
    function LiveOrder5(i::AssetInstance, o::Order; delay=Millisecond(0))
        new{A,E}(i, o, date, delay)
    end
    function LiveOrder5(a::AssetInstance, amt::Float64; kwargs...)
        order = Order(a.asset, a.exc.id, kind, amt)
        LiveOrder5(order, kwargs...)
    end
end

LiveOrder = LiveOrder5

export LiveOrder

end
