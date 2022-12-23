module Orders
using ..Trades: Order, Signal
using ..Instances: AssetInstance

struct LiveOrder1{I<:AssetInstance}
    signal::Signal
    amount::Float64
    asset::Ref{I}
    LiveOrder(a::T, o::Order) where T <: AssetInstance = begin
        new{T}(o.signal, o.amount, a)
    end
end

LiveOrder = LiveOrder1

export LiveOrder

end
