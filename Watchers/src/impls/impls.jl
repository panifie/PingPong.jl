module WatchersImpls
using ..Watchers
using Data
using TimeTicks
using Lang: @define_fromdict!
using LazyJSON

using ..CoinGecko: CoinGecko
cg = CoinGecko

@define_fromdict!(true)

_parsedatez(s::AbstractString) = begin
    s = rstrip(s, 'Z')
    Base.parse(DateTime, s)
end

macro parsedata(tick_type, mkts, key="symbol")
    key = esc(key)
    mkts = esc(mkts)
    quote
        NamedTuple(
            convert(Symbol, m[$key]) => @fromdict($tick_type, String, m) for m in $mkts
        )
    end
end

# FIXME: ARR
Base.convert(::Type{Symbol}, s::LazyJSON.String) = Symbol(s)
Base.convert(::Type{DateTime}, s::LazyJSON.String) = _parsedatez(s)
Base.convert(::Type{DateTime}, s::LazyJSON.Number) = unix2datetime(s)

include("cg_ticker.jl")
include("cg_derivatives.jl")

end
