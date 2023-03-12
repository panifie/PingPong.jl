using ..Orders
using ..Instances
using .Engine.Checks: sanitize_price, sanitize_amount, check_cost

function _docheck(checker, ai, whats...)
    ai = esc(ai)
    checker = esc(checker)
    expr = quote end
    for w in whats
        w = esc(w)
        push!(expr.args, :($w = $checker($ai, $w)))
    end
    expr
end

@doc "Ensure price is within correct boundaries."
macro price!(ai, prices...)
    _docheck(:sanitize_price, ai, prices...)
end
@doc "Ensures amount is within correct boundaries."
macro amount!(ai, amounts...)
    _docheck(:sanitize_amount, ai, amounts...)
end

include("limit.jl")
