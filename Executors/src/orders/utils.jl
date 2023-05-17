using .Checks: sanitize_price, sanitize_amount
using .Checks: iscost, ismonotonic, SanitizeOff, cost, withfees
using Instances: MarginInstance, NoMarginInstance, AssetInstance, @rprice, @ramount
using OrderTypes:
    IncreaseOrder, ShortBuyOrder, ordertype, LimitOrderType, MarketOrderType, ExchangeID
using Instruments: AbstractAsset
using Base: negate
using Lang: @lget!, @deassert
using Misc: Long, Short, PositionSide

const AnyLimitOrder{S<:OrderSide,P<:PositionSide} = Order{
    <:LimitOrderType{S},<:AbstractAsset,<:ExchangeID,P
}
const AnyGTCOrder = Union{GTCOrder,ShortGTCOrder}
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
    withfees(cost(price, amount), maxfees(ai), IncreaseOrder)
end
@doc "When entering a leveraged position, what's committed is margin + fees (in quote currency)."
function committment(o::Type{<:IncreaseOrder}, ai::MarginInstance, price, amount)
    @deassert amount > 0.0
    ntl = cost(price, amount)
    fees = ntl * maxfees(ai)
    margin = ntl / leverage(ai, orderpos(o)())
    margin + fees
end

@doc "When exiting a position, what's committed is always the asset cash
But for longs the asset is already held, so its positive"
function committment(::Type{<:SellOrder}, ai, _, amount)
    @deassert amount > 0.0
    amount
end
@doc "For shorts the asset is un-held, so its committment is negative."
function committment(::Type{<:ShortBuyOrder}, ai, _, amount)
    @deassert amount > 0.0
    negate(amount)
end

@doc "The partial committment of a trade, such that `sum(committment.(trades(o))) == committed(o)`."
function committment(ai::AssetInstance, t::Trade)
    committment(typeof(t.order), ai, t.order.price, abs(t.amount))
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

function iscommittable(s::Strategy, ::Type{<:IncreaseOrder}, commit, ai)
    @deassert st.freecash(s) |> gtxzero
    st.freecash(s) >= commit[]
end
function iscommittable(s::Strategy, ::Type{<:SellOrder}, commit, ai)
    @deassert Instances.freecash(ai, Long()) |> gtxzero
    @deassert commit[] |> gtxzero
    Instances.freecash(ai, Long()) >= commit[]
end
function iscommittable(::Strategy, ::Type{<:ShortBuyOrder}, commit, ai)
    @deassert Instances.freecash(ai, Short()) |> ltxzero
    @deassert commit[] |> ltxzero
    Instances.freecash(ai, Short()) <= commit[]
end

@doc "Iterates over all the orders in a strategy."
function orders(s::Strategy)
    (o for side in (Buy, Sell) for ai in s.holdings for o in orders(s, ai, side))
end
orders(s::Strategy, ::BySide{Buy}) = getfield(s, :buyorders)
orders(s::Strategy, ::BySide{Sell}) = getfield(s, :sellorders)
@doc "Get strategy buy orders for asset."
function orders(s::Strategy{M,S,E}, ai, ::BySide{Buy}) where {M,S,E}
    @lget! s.buyorders ai st.BuyOrdersDict{E}(st.BuyPriceTimeOrdering())
end
function orders(s::Strategy{M,S,E}, ai, ::BySide{Sell}) where {M,S,E}
    @lget! s.sellorders ai st.SellOrdersDict{E}(st.SellPriceTimeOrdering())
end
@doc "The total number of pending orders in the strategy"
function orderscount(s::Strategy)
    ans = 0
    for v in values(s.buyorders)
        ans += length(v)
    end
    for v in values(s.sellorders)
        ans += length(v)
    end
    ans
end
@doc "True if any of the holdings has non dust cash."
function hascash(s::Strategy)
    for ai in s.holdings
        iszero(ai) || return true
    end
    return false
end
hasorders(s::Strategy) = orderscount(s) == 0
buyorders(s::Strategy, ai) = orders(s, ai, Buy)
sellorders(s::Strategy, ai) = orders(s, ai, Sell)
_hasany(arr) = begin
    n = 0
    for _ in arr
        n += 1
        break
    end
    n != 0
end

@doc "Check if the asset instance has pending orders."
hasorders(s::Strategy, ai, ::Type{Buy}) = _hasany(s.buyorders[ai])
function hasorders(s::Strategy, ai, ::Type{Sell})
    !(iszero(something(committed(ai), 0.0)) && _hasany(s.sellorders[ai]) == 0)
end
hasorders(s::Strategy, ai, args...) = (hasorders(s, ai, Sell) || hasorders(s, ai, Buy))
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
    @deassert committed(t.order) |> gtxzero || ordertype(t) <: MarketOrderType committed(
        t.order
    ),
    t.order.attrs.trades
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
    @deassert committed(t.order) |> ltxzero
end

function _check_cash(ai::AssetInstance, ::Long)
    @deassert committed(ai, Long()) |> gtxzero ||
        ordertype(last(ai.history)) <: MarketOrderType
    @deassert cash(ai, Long()) |> gtxzero
end

_check_cash(ai::AssetInstance, ::Short) = begin
    @deassert committed(ai, Short()) |> ltxzero
    @deassert cash(ai, Short()) |> ltxzero
end
