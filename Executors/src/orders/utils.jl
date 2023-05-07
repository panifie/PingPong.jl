using .Checks: sanitize_price, sanitize_amount
using .Checks: iscost, ismonotonic, SanitizeOff, cost, withfees
using Instances: MarginInstance, NoMarginInstance, AssetInstance
using OrderTypes: IncreaseOrder, ShortBuyOrder
using Base: negate
using Lang: @deassert
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
    _doclamp(:sanitize_price, ai, prices...)
end
@doc "Ensures amount is within correct boundaries."
macro amount!(ai, amounts...)
    _doclamp(:sanitize_amount, ai, amounts...)
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

function unfillment(t::Type{<:BuyOrder}, amount)
    @deassert amount > 0.0
    @deassert !(t isa SellOrder)
    [negate(amount)]
end
function unfillment(t::Type{<:SellOrder}, amount)
    @deassert amount > 0.0
    @deassert !(t isa BuyOrder)
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

_check_trade(t::BuyTrade) = begin
    @deassert t.price <= t.order.price
    @deassert t.size < 0.0
    @deassert t.amount > 0.0
    @deassert committed(t.order) >= 0
end

_check_trade(t::SellTrade) = begin
    @deassert t.price >= t.order.price
    @deassert t.size > 0.0
    @deassert t.amount < 0.0
    @deassert committed(t.order) >= 0
end

_check_trade(t::ShortSellTrade) = begin
    @deassert t.price >= t.order.price
    @deassert t.size < 0.0
    @deassert t.amount < 0.0
    @deassert committed(t.order) >= 0
end

_check_trade(t::ShortBuyTrade) = begin
    @deassert t.price <= t.order.price
    @deassert t.size > 0.0
    @deassert t.amount > 0.0
    @deassert committed(t.order) >= 0
end

_check_cash(ai::AssetInstance, ::Long) = begin
    @deassert committed(ai, Long()) >= 0.0
    @deassert cash(ai, Long()) >= 0.0
end

_check_cash(ai::AssetInstance, ::Short) = begin
    @deassert committed(ai, Short()) >= 0.0
    @deassert cash(ai, Short()) <= 0.0
end
