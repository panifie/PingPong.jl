module Orders
using Lang: @lget!
using ..Types.Orders
using ..Types.Instances
using ..Engine: Engine
using ..Engine.Checks
using ..Engine.Checks: sanitize_price, sanitize_amount, checkcost, check_monotonic
using ..Engine.Strategies: Strategy
using ..Engine.Executors: Executors

function _docheck(checker, ai, whats...)
    ai = esc(ai)
    checker = esc(checker)
    expr = quote end
    for w in whats
        w = esc(w)
        push!(expr.args, :(isnothing($w) || begin
            $w = $checker($ai, $w)
        end))
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

end
