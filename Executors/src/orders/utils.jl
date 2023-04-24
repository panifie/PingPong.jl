using .Checks:
    sanitize_price, sanitize_amount, iscost, ismonotonic, SanitizeOff, cost, withfees

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

function committment(::Type{<:BuyOrder}, price, amount, fees)
    MVector(withfees(cost(price, amount), fees))
end
function committment(::Type{<:SellOrder}, _, amount, _)
    MVector(amount)
end

function iscommittable(s::Strategy, ::Type{<:BuyOrder}, commit, _)
    st.freecash(s) >= commit[1]
end
function iscommittable(_::Strategy, ::Type{<:SellOrder}, commit, ai)
    Instances.freecash(ai) >= commit[1]
end
