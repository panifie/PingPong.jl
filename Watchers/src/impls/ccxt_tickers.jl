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

_ids!(attrs, ids) = attrs[:ids] = ids
_ids(w) = w.attrs[:ids]

@doc """ Create a `Watcher` instance that tracks all markets for an exchange (ccxt).

"""
function ccxt_tickers_watcher(
    exc::Exchange;
    wid=:ccxt_ticker,
    syms=[],
    interval=Second(5),
    start=true,
    load=true,
    process=false,
    buffer_capacity=100,
    view_capacity=1000,
)
    check_timeout(exc, interval)
    attrs = Dict{Symbol,Any}()
    _sym!(attrs, syms)
    _tfunc!(attrs, exc, "Ticker", syms)
    _ids!(attrs, syms)
    _exc!(attrs, exc)
    watcher_type = Dict{String,CcxtTicker}
    watcher(
        watcher_type,
        wid;
        start,
        load,
        flush=true,
        process,
        buffer_capacity,
        view_capacity,
        fetch_interval=interval,
        attrs,
    )
end
ccxt_tickers_watcher(syms...) = ccxt_tickers_watcher([syms...])

function _fetch!(w::Watcher, ::CcxtTickerVal)
    data = w.attrs[:tfunc]() |> PyDict
    if length(data) > 0
        result = Dict{String,CcxtTicker}()
        for py_ticker in values(data)
            ticker = fromdict(CcxtTicker, String, py_ticker, pyconvert, pyconvert)
            result[ticker.symbol] = ticker
        end
        pushnew!(w, result)
        true
    else
        false
    end
end

function _init!(w::Watcher, ::CcxtTickerVal)
    _key!(w, "ccxt_$(_exc(w).name)_tickers_$(join(snakecased.(_ids(w)), "_"))")
    default_init(w, nothing)
end
