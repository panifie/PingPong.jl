module WatchersImpls
using LazyJSON
using Lang: @define_fromdict!, @lget!, @kget!, fromdict, Option
using TimeTicks
using ..Watchers
import ..Watchers: _fetch!, _init!, _load!, _flush!, _process!, _get
using Data
using Data.DFUtils: appendmax!
using Processing.DataFrames

using ..CoinGecko: CoinGecko
cg = CoinGecko
using ..CoinPaprika: CoinPaprika
cp = CoinPaprika

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

macro collect_buffer_data(buf_var, key_type, val_type, push=nothing)
    key_type = esc(key_type)
    val_type = esc(val_type)
    buf = esc(buf_var)
    push_func = isnothing(push) ? :(push!(@kget!(data, key, $(val_type)[]), tick)) : push
    quote
        let data = Dict{$key_type,Vector{$val_type}}(),
            # dopush((key, tick)) = push!(@kget!(data, key, $(val_type)[]), tick),
            dopush((key, tick)) = $push_func
            docollect((_, value)) = foreach(dopush, pairs(value))

            foreach(docollect, $buf)
            data
        end
    end
end

@doc "Defines a closure that appends new data on each symbol dataframe."
macro append_dict_data(dict, data, maxlen_var)
    maxlen = esc(maxlen_var)
    quote
        let doappend((key, newdata)) = begin
                df = @kget! $(esc(dict)) key DataFrame(; copycols=false)
                appendmax!(df, newdata, $maxlen)
            end
            foreach(doappend, $(esc(data)))
        end
    end
end

Base.convert(::Type{Symbol}, s::LazyJSON.String) = Symbol(s)
Base.convert(::Type{DateTime}, s::LazyJSON.String) = _parsedatez(s)
Base.convert(::Type{DateTime}, s::LazyJSON.Number) = unix2datetime(s)
Base.convert(::Type{String}, s::Symbol) = string(s)
Base.convert(::Type{Symbol}, s::AbstractString) = Symbol(s)

include("cg_ticker.jl")
include("cg_derivatives.jl")
include("cp_markets.jl")
include("cp_twitter.jl")
include("ccxt_tickers.jl")
include("ccxt_ohlcv.jl")

end
