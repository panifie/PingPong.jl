using .Checks: sanitize_price, sanitize_amount
using .Checks: iscost, ismonotonic, SanitizeOff, cost, withfees
using Instances: MarginInstance, NoMarginInstance, AssetInstance
using OrderTypes:
    IncreaseOrder, ShortBuyOrder, ordertype, LimitOrderType, MarketOrderType, ExchangeID
using Instruments: AbstractAsset
using Base: negate
using Lang: @lget!, @deassert
using Misc: Long, Short, PositionSide

const AnyLimitOrder{S<:OrderSide,P<:PositionSide} = Order{
    <:LimitOrderType{S},<:AbstractAsset,<:ExchangeID,P
}
const AnyFOKOrder = Union{FOKOrder,ShortFOKOrder}
const AnyIOCOrder = Union{IOCOrder,ShortIOCOrder}
const AnyMarketOrder{S<:OrderSide,P<:PositionSide} = Order{
    <:MarketOrderType{S},<:AbstractAsset,<:ExchangeID,P
}

function _doclamp(clamper, ai, whats...)
    ai = esc(ai)
    clamper = esc(clamper)
    expr = quote end
    for w in whats
        w = esc(w)
        push!(expr.args, :(isnothing($w) || begin
            $w = $clamper($ai, $w)
        end))
    end
    expr
end

@doc "Ensure price is within correct boundaries."
macro price!(ai, prices...)
    _doclamp(:($(@__MODULE__).sanitize_price), ai, prices...)
end
@doc "Ensures amount is within correct boundaries."
macro amount!(ai, amounts...)
    _doclamp(:($(@__MODULE__).sanitize_amount), ai, amounts...)
end

@doc "Without margin, committment is cost + fees (in quote currency)."
function committment(::Type{<:IncreaseOrder}, ai::NoMarginInstance, price, amount)
    @deassert amount > 0.0
    [withfees(cost(price, amount), maxfees(ai), IncreaseOrder)]
end
@doc "When entering a leveraged position, what's committed is margin + fees (in quote currency)."
function committment(o::Type{<:IncreaseOrder}, ai::MarginInstance, price, amount)
    @deassert amount > 0.0
    ntl = cost(price, amount)
    fees = ntl * maxfees(ai)
    margin = ntl / leverage(ai, orderpos(o)())
    [margin + fees]
end

@doc "When exiting a position, what's committed is always the asset cash
But for longs the asset is already held, so its positive"
function committment(::Type{<:SellOrder}, _, _, amount)
    @deassert amount > 0.0
    [amount]
end
@doc "For shorts the asset is un-held, so its committment is negative."
function committment(::Type{<:ShortBuyOrder}, _, _, amount)
    @deassert amount > 0.0
    [negate(amount)]
end

@doc "The partial committment of a trade, such that `sum(committment.(trades(o))) == committed(o)`."
function committment(ai::AssetInstance, t::Trade)
    committment(typeof(t.order), ai, t.order.price, abs(t.amount))[]
end

function unfillment(t::Type{<:AnyBuyOrder}, amount)
    @deassert amount > 0.0
    @deassert !(t isa AnySellOrder)
    [negate(amount)]
end
function unfillment(t::Type{<:AnySellOrder}, amount)
    @deassert amount > 0.0
    @deassert !(t isa AnyBuyOrder)
    [amount]
end

function iscommittable(s::Strategy, ::Type{<:IncreaseOrder}, commit, _)
    @deassert st.freecash(s) >= 0.0
    st.freecash(s) >= commit[]
end
function iscommittable(_::Strategy, ::Type{<:SellOrder}, commit, ai)
    @deassert Instances.freecash(ai, Long()) >= 0.0
    @deassert commit[] >= 0.0
    Instances.freecash(ai, Long()) >= commit[]
end
function iscommittable(::Strategy, ::Type{<:ShortBuyOrder}, commit, ai)
    @deassert Instances.freecash(ai, Short()) <= 0.0
    @deassert commit[] <= 0.0
    Instances.freecash(ai, Short()) <= commit[]
end

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
hasorders(::Strategy, ai, ::Type{Sell}) = committed(ai) != 0.0
hasorders(s::Strategy, ai) = hasorders(s, ai, Sell) || hasorders(s, ai, Buy)
hasorders(s::Strategy, ::Type{Buy}) = !iszero(s.cash_committed)
hasorders(s::Strategy, ::Type{Sell}) = begin
    for (_, ords) in s.sellorders
        isempty(ords) || return true
    end
    return false
end

function _check_trade(t::BuyTrade)
    @deassert t.price <= t.order.price || ordertype(t) <: MarketOrderType
    @deassert t.size < 0.0
    @deassert t.amount > 0.0
    @deassert committed(t.order) >= -1e-12 || ordertype(t) <: MarketOrderType
end

function _check_trade(t::SellTrade)
    @deassert t.price >= t.order.price || ordertype(t) <: MarketOrderType
    @deassert t.size > 0.0
    @deassert t.amount < 0.0
    @deassert committed(t.order) >= -1e-12
end

function _check_trade(t::ShortSellTrade)
    @deassert t.price >= t.order.price || ordertype(t) <: MarketOrderType
    @deassert t.size < 0.0
    @deassert t.amount < 0.0
    @deassert abs(committed(t.order)) <= t.fees || t.order isa ShortSellOrder
end

function _check_trade(t::ShortBuyTrade)
    @deassert t.price <= t.order.price || ordertype(t) <: MarketOrderType (
        t.price, t.order.price
    )
    @deassert t.size > 0.0
    @deassert t.amount > 0.0
    @deassert committed(t.order) <= 1e-12
end

function _check_cash(ai::AssetInstance, ::Long)
    @deassert committed(ai, Long()) >= -1e-12 ||
        ordertype(last(ai.history)) <: MarketOrderType
    @deassert cash(ai, Long()) >= 0.0
end

_check_cash(ai::AssetInstance, ::Short) = begin
    @deassert committed(ai, Short()) <= 0.0
    @deassert cash(ai, Short()) <= 0.0
end
