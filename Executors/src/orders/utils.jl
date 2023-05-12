using .Checks: sanitize_price, sanitize_amount
using .Checks: iscost, ismonotonic, SanitizeOff, cost, withfees
using Instances: MarginInstance, NoMarginInstance, AssetInstance
using OrderTypes: IncreaseOrder, ShortBuyOrder
using Base: negate
using Lang: @lget!, @deassert
using Misc: Long, Short, PositionSide

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

@doc "For leveraged orders, the committment includes both the fees to enter, and exit the position."
function committment(t::Type{<:IncreaseOrder}, ai::MarginInstance, price, amount)
    @deassert amount > 0.0
    let fees = maxfees(ai),
        cst = cost(price, amount),
        open_fees = cst * fees,
        close_fees = cost(bankruptcy(ai, price, orderpos(t)), amount) * fees

        [cst + open_fees + close_fees]
    end
end

# When entering a position, what's committed is always strategy cash
function committment(::Type{<:IncreaseOrder}, ai::NoMarginInstance, price, amount)
    @deassert amount > 0.0
    [withfees(cost(price, amount), maxfees(ai), IncreaseOrder)]
end
# When exiting a position, what's committed is always the asset cash
# But for longs the asset is already held, so its positive
function committment(::Type{<:SellOrder}, _, _, amount)
    @deassert amount > 0.0
    [amount]
end
# While for shorts the asset is un-held, so it its negative
function committment(::Type{<:ShortBuyOrder}, _, _, amount)
    @deassert amount > 0.0
    [negate(amount)]
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
    st.freecash(s) >= commit[]
end
function iscommittable(_::Strategy, ::Type{<:SellOrder}, commit, ai)
    Instances.freecash(ai, Long()) >= commit[]
end
function iscommittable(_::Strategy, ::Type{<:ShortBuyOrder}, commit, ai)
    Instances.freecash(ai, Short()) >= commit[]
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

_check_trade(t::BuyTrade) = begin
    @deassert t.price <= t.order.price
    @deassert t.size < 0.0
    @deassert t.amount > 0.0
    @deassert committed(t.order) >= -1e-12
end

_check_trade(t::SellTrade) = begin
    @deassert t.price >= t.order.price
    @deassert t.size > 0.0
    @deassert t.amount < 0.0
    @deassert committed(t.order) >= -1e-12
end

_check_trade(t::ShortSellTrade) = begin
    @deassert t.price >= t.order.price
    @deassert t.size < 0.0
    @deassert t.amount < 0.0
    @deassert committed(t.order) >= -1e-12
end

_check_trade(t::ShortBuyTrade) = begin
    @deassert t.price <= t.order.price
    @deassert t.size > 0.0
    @deassert t.amount > 0.0
    @deassert committed(t.order) >= -1e-12
end

_check_cash(ai::AssetInstance, ::Long) = begin
    @deassert committed(ai, Long()) >= -1e-12
    @deassert cash(ai, Long()) >= 0.0
end

_check_cash(ai::AssetInstance, ::Short) = begin
    @deassert committed(ai, Short()) >= 0.0
    @deassert cash(ai, Short()) <= 0.0
end
