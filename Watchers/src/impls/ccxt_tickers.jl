using ..Fetch.Exchanges
using .Exchanges.Ccxt: choosefunc
using ..Python
using .Python: pyisnone

const CcxtTickerVal = Val{:ccxt_ticker}
@doc "The ccxt ticker object as a NamedTuple."
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
_ids(w) = attr(w, :ids)

@doc """ Create a `Watcher` instance that tracks all markets for an exchange (ccxt)

$(TYPEDSIGNATURES)

This function creates a `Watcher` instance that tracks all markets for an exchange (ccxt).
It sets the symbol, exchange, and time frame for the watcher, and prepares the trades buffer.
It also sets the watcher's status to pending and initializes the last fetched and last flushed timestamps.

"""
function ccxt_tickers_watcher(
    exc::Exchange;
    val=CcxtTickerVal(),
    wid=CcxtTickerVal.parameters[1],
    syms=[],
    interval=Second(5),
    start=true,
    load=true,
    process=false,
    buffer_capacity=100,
    view_capacity=1000,
    flush=true,
)
    check_timeout(exc, interval)
    attrs = Dict{Symbol,Any}()
    _sym!(attrs, syms)
    _tfunc!(attrs, exc, "Ticker", syms)
    _ids!(attrs, syms)
    _exc!(attrs, exc)
    watcher_type = Dict{String,CcxtTicker}
    wid = string(wid, "-", hash((exc.id, syms, issandbox(exc))))
    watcher(
        watcher_type,
        wid,
        val;
        start,
        load,
        flush,
        process,
        buffer_capacity,
        view_capacity,
        fetch_interval=interval,
        attrs,
    )
end
ccxt_tickers_watcher(syms...) = ccxt_tickers_watcher([syms...])

# FIXME
wpyconvert(::Type{T}, py::Py) where {T} =
    if pyisnone(py)
        nothing
    else
        pyconvert(T, py)
    end

wpyconvert(::Type{F}, py::Py) where {F<:AbstractFloat} = begin
    if pyisnone(py)
        zero(F)
    else
        pyconvert(F, py)
    end
end
wpyconvert(::Type{Union{Nothing,DateTime}}, py::Py) =
    if pyisnone(py)
        nothing
    else
        dt(pyconvert(Int, py))
    end
wpyconvert(::Type{T}, v::Symbol) where {T} = T(v)

@doc """ Fetches trades and updates the watcher's trades buffer

$(TYPEDSIGNATURES)

This function fetches trades for the watcher's symbol and time frame, and updates the watcher's trades buffer.
If new trades are fetched, they are appended to the trades buffer and the last fetched timestamp is updated.

"""
function _fetch!(w::Watcher, ::CcxtTickerVal)
    data = attr(w, :tfunc)() |> PyDict
    if length(data) > 0
        result = Dict{String,CcxtTicker}()
        for py_ticker in values(data)
            ticker = fromdict(CcxtTicker, String, py_ticker, wpyconvert, wpyconvert)
            result[ticker.symbol] = ticker
        end
        pushnew!(w, result)
        true
    else
        false
    end
end

function _reset_tickers_func!(w::Watcher)
    attrs = w.attrs
    eid = echangeid(_exc(w))
    exc = getexchange!(eid)
    _exc!(attrs, exc)
    sym = _sym(attrs)
    _tfunc!(w.attrs, exc, "Ticker", sym)
end

function _start!(w::Watcher, ::CcxtTickerVal)
    _reset_tickers_func!(w)
end

function _init!(w::Watcher, ::CcxtTickerVal)
    exc = _exc(w)
    _key!(
        w,
        string(
            "ccxt_", exc.name, issandbox(exc), "_tickers_", join(snakecased.(_ids(w)), "_")
        ),
    )
    default_init(w, nothing)
end
