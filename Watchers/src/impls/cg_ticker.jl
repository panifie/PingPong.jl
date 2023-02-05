const CgTick = @NamedTuple begin
    symbol::Symbol
    id::String
    last_updated::DateTime
    current_price::Float64
    high_24h::Float64
    low_24h::Float64
    price_change_24h::Float64
    price_change_percentage_24h::Float64
    fully_diluted_valuation::Float64
end

@doc """ Create a `Watcher` instance that tracks the price of some currencies on an exchange.

"""
cg_ticker_watcher(syms::AbstractVector) = begin
    ids = cg.idbysym.(syms)
    fetcher() = begin
        mkts = cg.coinsmarkets(; ids)
        @parsedata CgTick mkts "symbol"
    end
    name = join(string.(syms))
    watcher_type = NamedTuple{tuple(Symbol.(syms)...),NTuple{length(syms),CgTick}}
    watcher(watcher_type, name, fetcher; flusher=true, interval=Second(360))
end
cg_ticker_watcher(syms...) = cg_ticker_watcher([syms...])

