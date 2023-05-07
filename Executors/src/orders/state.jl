using Lang: @deassert, @lget!, Option
using OrderTypes
import OrderTypes: commit!, tradepos
using Strategies: Strategies as st, MarginStrategy, IsolatedStrategy
using Misc: Short
using Instruments
using Instruments: @importcash!
@importcash!

##  committed::Float64 # committed is `cost + fees` for buying or `amount` for selling
const _BasicOrderState{T} = NamedTuple{
    (:take, :stop, :committed, :unfilled, :trades),
    Tuple{Option{T},Option{T},Vector{T},Vector{T},Vector{Trade}},
}

@doc "Get strategy buy orders for asset."
function orders(s::Strategy{M,S,E}, ai, ::Type{Buy}) where {M,S,E}
    @lget! s.buyorders ai st.BuyOrdersDict{E}(st.BuyPriceTimeOrdering())
end
buyorders(s::Strategy, ai) = orders(s, ai, Buy)
function orders(s::Strategy{M,S,E}, ai, ::Type{Sell}) where {M,S,E}
    @lget! s.sellorders ai st.SellOrdersDict{E}(st.SellPriceTimeOrdering())
end
sellorders(s::Strategy, ai) = orders(s, ai, Sell)
@doc "Check if the asset instance has pending orders."
hasorders(s::Strategy, ai, t::Type{Buy}) = !isempty(orders(s, ai, t))
hasorders(::Strategy, ai, ::Type{Sell}) = ai.cash_committed != 0.0
hasorders(s::Strategy, ai) = hasorders(s, ai, Sell) || hasorders(s, ai, Buy)
@doc "Remove a single order from the order queue."
function Base.pop!(s::Strategy, ai, o::IncreaseOrder)
    @deassert !(o isa MarketOrder) # Market Orders are never queued
    @deassert committed(o) >= 0.0 committed(o)
    subzero!(s.cash_committed, committed(o))
    pop!(orders(s, ai, orderside(o)), pricetime(o))
end
function Base.pop!(s::Strategy, ai, o::SellOrder)
    @deassert committed(o) >= 0.0 committed(o)
    sub!(committed(ai, Long()), committed(o))
    pop!(orders(s, ai, Sell), pricetime(o))
    # If we don't have cash for this asset, it should be released from holdings
    release!(s, ai, o)
end
function Base.pop!(s::Strategy, ai, o::ShortBuyOrder)
    # Short buy orders have negative committment
    @deassert committed(o) <= 0.0 committed(o)
    @deassert committed(ai, Short()) <= 0.0
    add!(committed(ai, Short()), committed(o))
    pop!(orders(s, ai, Buy), pricetime(o))
    # If we don't have cash for this asset, it should be released from holdings
    release!(s, ai, o)
end
@doc "Remove all buy/sell orders for an asset instance."
function Base.pop!(s::Strategy, ai, t::Type{<:Union{Buy,Sell}})
    pop!.(s, ai, values(orders(s, ai, t)))
end
Base.pop!(s::Strategy, ai, ::Type{Both}) = begin
    pop!(s, ai, Buy)
    pop!(s, ai, Sell)
end
Base.pop!(s::Strategy, ai) = pop!(s, ai, Both)
@doc "Inserts an order into the order dict of the asset instance. Orders should be identifiable by a unique (price, date) tuple."
function Base.push!(s::Strategy, ai, o::Order{<:OrderType{S}}) where {S<:OrderSide}
    let k = pricetime(o), d = orders(s, ai, S) #, stok = searchsortedfirst(d, k)
        @assert k ∉ keys(d) "Orders with same price and date are not allowed."
        d[k] = o
    end
end

function cash!(s::Strategy, ai, t::Trade)
    _check_trade(t)
    cash!(s, t)
    cash!(ai, t)
    _check_cash(ai, tradepos(t)())
end
attr(o::Order, sym) = getfield(getfield(o, :attrs), sym)
unfilled(o::Order) = abs(o.attrs.unfilled[])

commit!(s::Strategy, o::IncreaseOrder, _) = add!(s.cash_committed, committed(o))
commit!(::Strategy, o::SellOrder, ai) = begin
    add!(committed(ai, orderpos(o)()), committed(o))
end
function commit!(::Strategy, o::ShortBuyOrder, ai)
    @assert committed(ai, orderpos(o)()) <= 0.0
    add!(committed(ai, orderpos(o)()), committed(o))
end
iscommittable(s::Strategy, o::IncreaseOrder, _) = begin
    @deassert committed(o) > 0.0
    st.freecash(s) >= committed(o)
end
function iscommittable(::Strategy, o::SellOrder, ai)
    @deassert committed(o) > 0.0
    Instances.freecash(ai, Long()) >= committed(o)
end
function iscommittable(::Strategy, o::ShortBuyOrder, ai)
    @deassert committed(o) < 0.0
    Instances.freecash(ai, Short()) <= committed(o)
end

hold!(s::Strategy, ai, ::IncreaseOrder) = push!(s.holdings, ai)
hold!(::Strategy, _, ::SellOrder) = nothing
release!(::Strategy, _, ::BuyOrder) = nothing
function release!(s::Strategy, ai, o::ReduceOrder)
    isapprox(cash(ai, orderpos(o)()), 0.0) && pop!(s.holdings, ai)
end
@doc "Cancel an order with given error."
function cancel!(s::Strategy, o::Order, ai; err::OrderError)
    pop!(s, ai, o)
    st.ping!(s, o, err, ai)
end
