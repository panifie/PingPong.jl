module LiveOrders
using Dates: DateTime, Period
using Misc: Candle
using ExchangeTypes
using ..Instances: AssetInstance
using TimeTicks
using Instruments
using ..Orders

@doc """ Live orders can hold additional info about live execution. They are short lived

`delay`: how much time has passed since the order request \
          and the exchange execution of the order (to account for api issues).
"""
mutable struct LiveOrder4{A<:Asset,E<:ExchangeID}
    asset::Ref{AssetInstance{A,E}}
    order::Order{A,E}
    delay::Millisecond
    function LiveOrder4(
        i::AssetInstance{A,E}, o::Order{A,E}; delay=Millisecond(0)
    ) where {A<:Asset,E<:ExchangeID}
        begin
            new{A,E}(i, o, date, delay)
        end
    end
    function LiveOrder4(a::AssetInstance, kind::OrderKind, amt::Float64; kwargs...)
        begin
            order = Order(a.asset, a.exc.id, kind, amt)
            LiveOrder4(order, kwargs...)
        end
    end
end

LiveOrder = LiveOrder4

export LiveOrder

end
