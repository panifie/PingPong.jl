using Exchanges
using Python
using Data: Candle

function Base.convert(::Type{Candle}, py::PyList)
    Candle(dt(pyconvert(Float64, py[1])), (pyconvert(Float64, py[n]) for n in 2:6)...)
end

@doc """ Create a `Watcher` instance that tracks ohlcv for an exchange (ccxt).

"""
function ccxt_ohlcv_watcher(exc::Exchange, syms::AbstractVector=[]; interval=Second(5))
    tfunc = choosefunc(exc, "ohlcv", syms)
    fetcher() = begin
        data = tfunc()
        result = Dict{String,Vector{Candle}}()
        for (k, v) in PyDict(data)
            result[pyconvert(String, k)] = pyconvert(Vector, v)
        end
        result
    end
    name = "ccxt_$(exc.name)-$(join(syms, "-"))-ohlcv"
    watcher_type = Dict{String,Vector{Candle}}
    watcher(watcher_type, name, fetcher; flusher=true, interval)
end

function ccxt_ohlcv_watcher(exc::Exchange, syms...; kwargs...)
    ccxt_tickers_watcher(exc, [syms...]; kwargs...)
end
function ccxt_ohlcv_watcher(syms...; kwargs...)
    ccxt_tickers_watcher(exc::Exchange, [syms...]; kwargs...)
end
