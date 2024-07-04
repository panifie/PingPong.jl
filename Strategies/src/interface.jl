using .OrderTypes: OrderError, AssetEvent, event!

## Strategy interface
@doc "Called on each timestep iteration, possible multiple times.
Receives:
- `current_time`: the current timestamp to evaluate (the current candle would be `current_time - timeframe`).
- `ctx`: The context of the executor.
$(TYPEDSIGNATURES)
"
ping!(::Strategy, current_time::DateTime, ctx) = error("Not implemented")
@doc "[`ping!(s::Strategy, ::LoadStrategy)`](@ref)"
struct LoadStrategy <: ExecAction end
@doc "[`ping!(s::Strategy, ::ResetStrategy)`](@ref)"
struct ResetStrategy <: ExecAction end
@doc "[`ping!(s::Strategy, ::StrategyMarkets)`](@ref)"
struct StrategyMarkets <: ExecAction end
@doc "[`ping!(s::Strategy, ::WarmupPeriod)`](@ref)"
struct WarmupPeriod <: ExecAction end
# TODO: maybe methods that dispatch on strategy types should be named `ping` (without excl mark)
@doc """Called to construct the strategy, should return the strategy instance.
$(TYPEDSIGNATURES)"""
ping!(::Type{<:Strategy}, cfg, ::LoadStrategy) = nothing
@doc "Called at the end of the `reset!` function applied to a strategy.
$(TYPEDSIGNATURES)"
ping!(::Strategy, ::ResetStrategy) = nothing
@doc "How much lookback data the strategy needs. $(TYPEDSIGNATURES)"
ping!(s::Strategy, ::WarmupPeriod) = s.timeframe.period
@doc "When an order is canceled the strategy is pinged with an order error. $(TYPEDSIGNATURES)"
ping!(s::Strategy, ::Order, err::OrderError, ::AssetInstance; kwargs...) =
    event!(exchange(s), AssetEvent, :order_error, s; err)
@doc "Market symbols that populate the strategy universe"
ping!(::Type{<:Strategy}, ::StrategyMarkets)::Vector{String} = String[]

@doc """ Provides a common interface for strategy execution.

The `interface` macro imports the `ping!` function from the Strategies module, the `assets` and `exchange` functions, and the `pong!` function from the Executors module.
This macro is used to provide a common interface for strategy execution.
"""
macro interface()
    ex = quote
        import .Strategies: ping!
        using .Strategies: assets, exchange
        using .Executors: pong!
    end
    esc(ex)
end
