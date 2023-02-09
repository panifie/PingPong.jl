using Exchanges
using Python
using Data: Candle, @zkey

function Base.convert(::Type{Candle}, py::PyList)
    Candle(dt(pyconvert(Float64, py[1])), (pyconvert(Float64, py[n]) for n in 2:6)...)
end

@doc """ Create a `Watcher` instance that tracks ohlcv for an exchange (ccxt).

"""
function ccxt_ohlcv_watcher(
    exc::Exchange, syms::AbstractVector=[]; timeframe=tf"5m", interval=Second(5)
)
    tfunc = choosefunc(exc, "ohlcv", syms; timeframe)
    fetcher() = begin
        data = tfunc()
        result = Dict{String,Vector{Candle}}()
        for (k, v) in PyDict(data)
            result[pyconvert(String, k)] = pyconvert(Vector, v)
        end
        result
    end
    name = "ccxt_$(exc.name)_ohlcv_$(join(syms, "_"))"
    watcher_type = Dict{String,Vector{Candle}}
    watcher(watcher_type, name, fetcher; flusher=true, interval)
end

function ccxt_ohlcv_watcher(exc::Exchange, syms...; kwargs...)
    ccxt_tickers_watcher(exc, [syms...]; kwargs...)
end
function ccxt_ohlcv_watcher(syms...; kwargs...)
    ccxt_tickers_watcher(exc::Exchange, [syms...]; kwargs...)
end

# function candle_flusher(buf)
#     for i in eachindex(buf)

#     end
# end
