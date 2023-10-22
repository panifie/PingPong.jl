using OrderTypes: OrderError

## Strategy interface
@doc "Called on each timestep iteration, possible multiple times.
Receives:
- `current_time`: the current timestamp to evaluate (the current candle would be `current_time - timeframe`).
- `ctx`: The context of the executor.
$(TYPEDSIGNATURES)
"
ping!(::Strategy, current_time::DateTime, ctx) = error("Not implemented")
struct LoadStrategy <: ExecAction end
struct ResetStrategy <: ExecAction end
struct StrategyMarkets <: ExecAction end
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
@doc "When an order is cancelled the strategy is pinged with an order error. $(TYPEDSIGNATURES)"
ping!(::Strategy, ::Order, err::OrderError, ::AssetInstance; kwargs...) = err
@doc "Market symbols that populate the strategy universe"
ping!(::Type{<:Strategy}, ::StrategyMarkets)::Vector{String} = String[]

macro interface()
    ex = quote
        import .Strategies: ping!
        using .Strategies: assets, exchange
        using .Executors: pong!
    end
    esc(ex)
end
