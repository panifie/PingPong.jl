module WatchersImpls
using ..Watchers
using Data
using TimeTicks
using Lang: @define_fromdict!
using LazyJSON
using ..CoinGecko: CoinGecko
cg = CoinGecko



const Tick = @NamedTuple begin
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

_cgdatedt(s::AbstractString) = begin
    s = rstrip(s, 'Z')
    Base.parse(DateTime, s)
end

@define_fromdict!()
# FIXME: ARR
Base.convert(::Type{Symbol}, s::LazyJSON.String) = Symbol(s)
Base.convert(::Type{DateTime}, s::LazyJSON.String) = _cgdatedt(s)

function _parse_data(mkts)
    NamedTuple(
        convert(Symbol, m["symbol"]) => @fromdict(Tick, String, m) for m in mkts
    )
end

@doc """ Create a `Watcher` instance that tracks the price of some currencies on an exchange.

"""
cg_ticker_watcher(syms::AbstractVector) = begin
    ids = cg.idbysym.(syms)
    fetcher() = begin
        mkts = cg.coinsmarkets(; ids)
        _parse_data(mkts)
    end
    name = join(string.(syms))
    watcher_type = NamedTuple{tuple(Symbol.(syms)...),NTuple{length(syms),Tick}}
    watcher(watcher_type, name, fetcher; flusher=true, interval=Second(360))
end
cg_ticker_watcher(syms...) = cg_ticker_watcher([syms...])

end
