using .Checks:
    sanitize_price, sanitize_amount, iscost, ismonotonic, SanitizeOff, cost, withfees
using OrderTypes: IncreaseOrder
using Base: negate
using Lang: @deassert

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

function committment(::Type{<:IncreaseOrder}, price, amount, fees)
    @deassert amount > 0.0
    [withfees(cost(price, amount), fees, IncreaseOrder)]
end
function committment(::Type{<:ReduceOrder}, _, amount, _)
    @deassert amount > 0.0
    [amount]
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

function iscommittable(s::Strategy, ::Type{<:BuyOrder}, commit, _)
    st.freecash(s) >= commit[]
end
function iscommittable(_::Strategy, ::Type{<:SellOrder}, commit, ai)
    Instances.freecash(ai) >= commit[]
end
