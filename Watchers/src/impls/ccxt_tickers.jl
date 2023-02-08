using Exchanges
using Exchanges.Ccxt: choosefunc
using Python

const CcxtTicker = @NamedTuple begin
    symbol::String
    timestamp::Option{DateTime}
    open::Float64
    high::Float64
    low::Float64
    close::Float64
    previousClose::Option{Float64}
    bid::Float64
    ask::Float64
    bidVolume::Option{Float64}
    askVolume::Option{Float64}
    last::Float64
    vwap::Float64
    change::Float64
    percentage::Float64
    average::Float64
    baseVolume::Float64
    quoteVolume::Float64
end

@doc """ Create a `Watcher` instance that tracks all markets for an exchange (ccxt).

"""
function ccxt_tickers_watcher(exc::Exchange, syms=[], interval=Second(5))
    tfunc = choosefunc(exc, "ticker", syms)
    fetcher() = begin
        data = tfunc()
        result = Dict{String, CcxtTicker}()
        for (k, v) in PyDict(data)
            result[pyconvert(String, k)] = fromdict(CcxtTicker, String, v, pyconvert, pyconvert)
        end
        result
    end
    name = "ccxt_$(exc.name)-$(join(syms, "-"))-tickers"
    watcher_type = Dict{String,CcxtTicker}
    watcher(watcher_type, name, fetcher; flusher=true, interval)
end

ccxt_tickers_watcher(syms...) = ccxt_tickers_watcher([syms...])
