using Data: Candle, empty_ohlcv
using Exchanges
using Misc: Iterable
using Processing.TradesOHLCV
using Processing: trail!
using Python

const CcxtOHLCVVal = Val{:ccxt_ohlcv}

# FIXME
Python.pyconvert(::Type{DateTime}, py::Py) = dt(pyconvert(Int, py))
Python.pyconvert(::Type{TradeSide}, py::Py) = TradeSide(py)
Python.pyconvert(::Type{TradeRole}, py::Py) = TradeRole(py)

trades_fromdict(v, ::Val{CcxtTrade}) = fromdict(CcxtTrade, String, v)
_trades(w::Watcher) = w.attrs[:trades]
_trades!(w) = w.attrs[:trades] = CcxtTrade[]
_lastfetched(w) = w.attrs[:last_fetched]
_lastfetched!(w, v) = w.attrs[:last_fetched] = v

@doc """ Create a `Watcher` instance that tracks ohlcv for an exchange (ccxt).

- On startup candles are initially loaded from storage (if any).
- Then they are fastfowarded to the last available candle.
- After which, fetching happen on *trades*
- Once time crosses the timeframe, new candles are created from trades.

If The watcher is restarted, a new call for OHLCV data is made to re-fastfoward.
If no trades happen during a timeframe, an empty candle for that timeframe is added.
The `view` of the watcher SHOULD NOT have duplicate candles (same timestamp), and all the
candles SHOULD be contiguous (the time difference between adjacent candles is always equal to the timeframe).

If these constraints are not met that's a bug.

!!! warning "Watcher data."
The data saved by the watcher on disk SHOULD NOT be relied upon to be contiguous, since the watcher
doesn't ensure it, it only uses it to reduce the number of candles to fetch from the exchange at startup.
"""
function ccxt_ohlcv_watcher(exc::Exchange, sym; timeframe::TimeFrame, interval=Second(5))
    check_timeout(exc, interval)
    attrs = Dict{Symbol,Any}()
    _sym!(attrs, sym)
    _exc!(attrs, exc)
    _tfunc!(attrs, "Trades")
    _tfr!(attrs, timeframe)
    watcher_type = Vector{CcxtTrade}
    wid = string(CcxtOHLCVVal.parameters[1], "-", hash((exc.id, sym)))
    w = watcher(
        watcher_type,
        wid,
        CcxtOHLCVVal();
        start=false,
        flush=true,
        process=true,
        buffer_capacity=1,
        fetch_interval=interval,
        fetch_timeout=2interval,
        attrs,
    )
    start!(w)
    w
end

function ccxt_ohlcv_watcher(exc::Exchange, syms::Iterable; kwargs...)
    tasks = [@async ccxt_ohlcv_watcher(exc, s; kwargs...) for s in syms]
    [fetch(t) for t in tasks]
end
ccxt_ohlcv_watcher(syms::Iterable; kwargs...) = ccxt_ohlcv_watcher.(exc, syms; kwargs...)

_init!(w::Watcher, ::CcxtOHLCVVal) = begin
    default_init(w, empty_ohlcv())
    _trades!(w)
    _key!(w, "ccxt_$(_exc(w).name)_ohlcv_$(_sym(w))")
    _pending!(w)
    _lastfetched!(w, DateTime(0))
    _lastflushed!(w, DateTime(0))
end

_load!(w::Watcher, ::CcxtOHLCVVal) = _fastforward(w)

_tradestask(w) = get(w.attrs, :trades_task, nothing)
_tradestask!(w) = begin
    task = _tradestask(w)
    if isnothing(task) || istaskfailed(task)
        w.attrs[:trades_task] = @async _fetch_trades_loop(w)
    end
end
function _start!(w::Watcher, ::CcxtOHLCVVal)
    _pending!(w)
    empty!(_trades(w))
    _fetchto!(w, w.view, _sym(w), _tfr(w); to=_curdate(_tfr(w)))
    _check_contig(w, w.view)
end

function _fetch_trades_loop(w)
    backoff = ms(0)
    while !isnothing(w._timer) && isopen(w._timer)
        pytrades = @logerror w @pyfetch _tfunc(w)(_sym(w))
        if pytrades isa Exception
            backoff += ms(500)
            sleep(backoff)
            continue
        end
        if length(pytrades) > 0
            new_trades = [
                fromdict(CcxtTrade, String, py, pyconvert, pyconvert) for py in pytrades
            ]
            append!(_trades(w), new_trades)
        end
    end
end

function _fetch!(w::Watcher, ::CcxtOHLCVVal)
    _tradestask!(w)
    isempty(_trades(w)) && return true
    trade = _lasttrade(w)
    if trade.timestamp != _lastfetched(w)
        pushnew!(w, _trades(w))
        _lastfetched!(w, trade.timestamp)
    end
    true
end

_flush!(w::Watcher, ::CcxtOHLCVVal) = _flushfrom!(w)
_delete!(w::Watcher, ::CcxtOHLCVVal) = _delete_ohlcv!(w)

_empty_candles(_, ::Pending) = nothing
# Ensure that when no trades happen, candles are still updated
# NOTE: this assumes all trades were witnesses from the watcher side
# otherwise we couldn't tell if a candle truly had 0 volume.
function _empty_candles(w, ::Warmed)
    tf = _tfr(w)
    right = length(_trades(w)) == 0 ? _curdate(tf) : apply(tf, _firsttrade(w).timestamp)
    left = apply(tf, _lastdate(w.view))
    trail!(w.view, tf; from=left, to=right, cap=w.capacity.view)
end

function _process!(w::Watcher, ::CcxtOHLCVVal)
    _empty_candles(w, _status(w))
    # On startup, the first trades that we receive are likely incomplete
    # So we have to discard them, and only consider trades after the first (normalized) timestamp
    # Practically, the `trades_to_ohlcv` function has to *trim_left* only once, at the beginning (for every sym).
    temp = trades_to_ohlcv(_trades(w), _tfr(w); trim_left=@ispending(w), trim_right=false)
    isnothing(temp) && return nothing
    if isempty(w.view)
        appendmax!(w.view, temp.ohlcv, w.capacity.view)
    else
        _resolve(w, w.view, temp.ohlcv)
    end
    keepat!(_trades(w), (temp.stop + 1):lastindex(_trades(w)))
    _warmed!(w, _status(w))
    @debug "Latest candle for $(_sym(w)) is $(_lastdate(temp.ohlcv))"
end
