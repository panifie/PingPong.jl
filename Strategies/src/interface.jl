using OrderTypes: OrderError

## Strategy interface
@doc "Called on each timestep iteration, possible multiple times.
Receives:
- `current_time`: the current timestamp to evaluate (the current candle would be `current_time - timeframe`).
- `ctx`: The context of the executor.
"
ping!(::Strategy, current_time, ctx, args...; kwargs...) = error("Not implemented")
const evaluate! = ping!
struct LoadStrategy <: ExecAction end
struct ResetStrategy <: ExecAction end
@doc "Called to construct the strategy, should return the strategy instance."
ping!(::Type{<:Strategy}, cfg, ::LoadStrategy) = nothing
ping!(::Strategy, ::ResetStrategy) = nothing
struct WarmupPeriod <: ExecAction end
@doc "How much lookback data the strategy needs."
ping!(s::Strategy, ::WarmupPeriod) = s.timeframe.period
ping!(::Strategy, ::Order, err::OrderError, ::AssetInstance; kwargs...) = err

macro interface()
    quote
        import .Strategies: ping!, evaluate!
        using .Strategies: assets, exchange
        using .Executors: pong!, execute!
    end
end
