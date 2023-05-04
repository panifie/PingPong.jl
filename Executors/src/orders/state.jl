using Lang: @deassert, @lget!, Option
using OrderTypes
using Strategies: Strategies as st, MarginStrategy, IsolatedStrategy
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
Base.pop!(s::Strategy, ai, o::BuyOrder) = begin
    @deassert !(o isa MarketOrder) # Market Orders are never queued
    pop!(orders(s, ai, Buy), pricetime(o))
    @deassert committed(o) >= 0.0 committed(o)
    subzero!(s.cash_committed, committed(o))
end
Base.pop!(s::Strategy, ai, o::SellOrder) = begin
    @deassert !(o isa MarketOrder) # Market Orders are never queued
    pop!(orders(s, ai, Sell), pricetime(o))
    @deassert committed(o) >= 0.0 committed(o)
    sub!(ai.cash_committed, committed(o))
    # If we don't have cash for this asset, it should be released from holdings
    release!(s, ai, o)
end
@doc "Remove all buy/sell orders for an asset instance."
Base.pop!(s::Strategy, ai, t::Type{<:Union{Buy,Sell}}) = pop!.(s, ai, values(orders(s, ai, t)))
Base.pop!(s::Strategy, ai, _::Type{Both}) = begin
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

attr(o::Order, sym) = getfield(getfield(o, :attrs), sym)
unfilled(o::Order) = abs(o.attrs.unfilled[])
commit!(s::Strategy, o::BuyOrder, _) = add!(s.cash_committed, committed(o))
commit!(::Strategy, o::SellOrder, ai) = add!(ai.cash_committed, committed(o))
iscommittable(s::Strategy, o::BuyOrder, _) = st.freecash(s) >= committed(o)
iscommittable(::Strategy, o::SellOrder, ai) = Instances.freecash(ai) >= committed(o)
hold!(s::Strategy, ai, ::BuyOrder) = push!(s.holdings, ai)
hold!(::Strategy, _, ::SellOrder) = nothing
release!(::Strategy, _, ::BuyOrder) = nothing
release!(s::Strategy, ai, ::SellOrder) = isapprox(ai.cash, 0.0) && pop!(s.holdings, ai)

@doc "Cancel an order with given error."
function cancel!(s::Strategy, o::Order, ai; err::OrderError)
    pop!(s, ai, o)
    st.ping!(s, o, err, ai)
end
