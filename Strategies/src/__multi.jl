@doc """
Differently from the [`Strategies.Strategy`](@ref) type. The cross strategy works
over multiple exchanges, so portfolio and orders are mapped to exchanges.
Instead of a single quote currency for cash, it holds one collection of Cash currency per exchange.
"""
struct MultiStrategy1{M}
    universe::AssetCollection
    portfolio::Dict{ExchangeID,Dict{Asset,Ref{AssetInstance}}}
    orders::Dict{ExchangeID,Dict{Asset,Ref{AssetInstance}}}
    wallet::Dict{Tuple{ExchangeID,Symbol},Cash}
    config::Config
    function MultiStrategy1(
        src::Symbol, assets::Union{Dict,Iterable{String}}, config::Config
    )
        exc = getexchange!(config.exchange, sandbox=config.sandbox)
        uni = AssetCollection(assets; exc)
        new{src}(uni, Dict(), Dict(), Dict(), config)
    end
end
CrossStrategy = MultiStrategy1
