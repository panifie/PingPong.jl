using Exchanges
using Exchanges.Ccxt: choosefunc
using Python

const CcxtTickerVal = Val{:ccxt_ticker}
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
    attrs = Dict{Symbol,Any}()
    attrs[:tfunc] = choosefunc(exc, "Ticker", syms)
    attrs[:ids] = syms
    attrs[:key] = "ccxt_$(exc.name)_tickers_$(join(syms, "_"))"
    watcher_type = Dict{String,CcxtTicker}
    watcher(
        watcher_type, :ccxt_ticker; flush=true, process=false, fetch_interval=interval, attrs
    )
end
ccxt_tickers_watcher(syms...) = ccxt_tickers_watcher([syms...])

function _fetch!(w::Watcher, ::CcxtTickerVal)
    data = w.attrs[:tfunc]() |> PyDict
    if length(data) > 0
        result = Dict{String,CcxtTicker}()
        for k in keys(data)
            result[pyconvert(String, k)] = fromdict(
                CcxtTicker, String, data[k], pyconvert, pyconvert
            )
        end
        pushnew!(w, result)
        true
    else
        false
    end
end

_init!(w::Watcher, ::CcxtTickerVal) = default_init(w, nothing)
