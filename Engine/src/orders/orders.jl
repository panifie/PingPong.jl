module Orders
using Reexport
using Lang: @lget!, Option, @deassert
using TimeTicks
using Misc
using ExchangeTypes
@reexport using ..Types.Orders
using Instruments
using ..Types.Instances
using ..Engine: Engine
using ..Engine.Checks
using ..Engine.Checks: sanitize_price, sanitize_amount, iscost, ismonotonic
using ..Engine.Strategies: Strategy, ExchangeOrder, Strategies as st
using ..Engine.Executors: Executors, UpdateOrders
using ..Engine.Simulations: Simulations as sim
using .Executors: pong!

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

abstract type OrderError end
struct NotEnoughCash <: OrderError end
struct OrderTimeOut <: OrderError end
struct OrderCancelled <: OrderError end

include("state.jl")
include("trades.jl")
include("limit.jl")
include("pong.jl") # Always place at the end

end
