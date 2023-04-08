using Lang: @deassert, @lget!, Option
using OrderTypes
using Strategies: Strategies as st
import Instruments: cash!
using Instruments

function cash!(s::Strategy, ai, t::BuyTrade)
    sub!(s.cash, t.size)
    sub!(s.cash_committed, t.size)
    @deassert s.cash >= 0.0 && s.cash_committed >= 0.0
    add!(ai.cash, t.amount)
end
function cash!(s::Strategy, ai, t::SellTrade)
    add!(s.cash, t.size)
    sub!(ai.cash, t.amount)
    sub!(ai.cash_committed, t.amount)
    @deassert ai.cash >= 0.0 && ai.cash_committed >= 0.0
end

@doc "Get strategy buy orders for asset."
function orders(s::Strategy{M,S,E}, ai, ::Type{Buy}) where {M,S,E}
    @lget! s.buyorders ai Set{st.ExchangeBuyOrder(E)}()
end
buyorders(s::Strategy, ai) = orders(s, ai, Buy)
function orders(s::Strategy{M,S,E}, ai, ::Type{Sell}) where {M,S,E}
    @lget! s.sellorders ai Set{st.ExchangeSellOrder(E)}()
end
sellorders(s::Strategy, ai) = orders(s, ai, Sell)
@doc "Check if the asset instance has pending orders."
hasorders(s::Strategy, ai, t::Type{Buy}) = !isempty(orders(s, ai, t))
hasorders(::Strategy, ai, ::Type{Sell}) = ai.cash_committed > 0.0
hasorders(s::Strategy, ai) = hasorders(s, ai, Sell) || hasorders(s, ai, Buy)
@doc "Remove a single order from the order queue."
Base.pop!(s::Strategy, ai, o::BuyOrder) = begin
    pop!(orders(s, ai, Buy), o)
    sub!(s.cash_committed, committed(o))
end
Base.pop!(s::Strategy, ai, o::SellOrder) = begin
    pop!(orders(s, ai, Sell), o)
    sub!(ai.cash_committed, committed(o))
    # If we don't have cash for this asset, it should be released from holdings
    release!(s, ai, o)
end
@doc "Remove all buy/sell orders for an asset instance."
Base.pop!(s::Strategy, ai, t::Type{<:OrderSide}) = pop!.(s, ai, orders(s, ai, t))
Base.pop!(s::Strategy, ai) = begin
    pop!(s, ai, Buy)
    pop!(s, ai, Sell)
end
@doc "Inserts an order into the order set of the asset instance."
function Base.push!(s::Strategy, ai, o::Order{<:OrderType{S}}) where {S<:OrderSide}
    push!(orders(s, ai, S), o)
end

commit!(s::Strategy, o::BuyOrder, _) = add!(s.cash_committed, committed(o))
commit!(::Strategy, o::SellOrder, ai) = add!(ai.cash_committed, committed(o))
iscommittable(s::Strategy, o::BuyOrder, _) = st.freecash(s) >= committed(o)
iscommittable(::Strategy, o::SellOrder, ai) = Instances.freecash(ai) >= committed(o)
hold!(s::Strategy, ai, ::BuyOrder) = push!(s.holdings, ai)
hold!(::Strategy, _, ::SellOrder) = nothing
release!(::Strategy, _, ::BuyOrder) = nothing
release!(s::Strategy, ai, ::SellOrder) = isapprox(ai.cash, 0.0) && pop!(s.holdings, ai)
@doc "Check if this is the last trade of the order and if so unqueue it."
fullfill!(s::Strategy, ai, o::Order, ::Trade) = isfilled(o) && pop!(s, ai, o)

@doc "Add order to the pending orders of the strategy."
function queue!(s::Strategy, o::Order{<:OrderType{S}}, ai) where {S<:OrderSide}
    # This is already done in general by the function that creates the order
    iscommittable(s, o, ai) || return false
    hold!(s, ai, o)
    commit!(s, o, ai)
    push!(s, ai, o)
    return true
end

@doc "Cancel an order with given error."
function cancel!(s::Strategy, o::Order, ai; err::OrderError)
    pop!(s, ai, o)
    st.ping!(s, o, err, ai)
end

export queue!, cancel!
