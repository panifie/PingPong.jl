using ..Data: Candle, empty_ohlcv
using ..Fetch.Exchanges
using ..Misc: Iterable
using ..Fetch.Processing.TradesOHLCV
using ..Fetch.Processing: trail!
using ..Fetch.Python

const CcxtOHLCVVal = Val{:ccxt_ohlcv}

# FIXME
Python.pyconvert(::Type{DateTime}, py::Py) = dt(pyconvert(Int, py))
Python.pyconvert(::Type{TradeSide}, py::Py) = TradeSide(py)
Python.pyconvert(::Type{TradeRole}, py::Py) = TradeRole(py)

trades_fromdict(v, ::Val{CcxtTrade}) = fromdict(CcxtTrade, String, v)
_trades(w::Watcher) = attr(w, :trades)
_trades!(w) = setattr!(w, CcxtTrade[], :trades)
_lastfetched(w) = attr(w, :last_fetched)
_lastfetched!(w, v) = setattr!(w, v, :last_fetched)

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
function ccxt_ohlcv_watcher(
    exc::Exchange,
    sym;
    timeframe::TimeFrame,
    interval=Second(5),
    default_view=nothing,
    quiet=true,
    start=false,
)
    check_timeout(exc, interval)
    attrs = Dict{Symbol,Any}()
    _sym!(attrs, sym)
    _exc!(attrs, exc)
    _tfunc!(attrs, "Trades")
    _tfr!(attrs, timeframe)
    attrs[:default_view] = default_view
    attrs[:quiet] = quiet
    watcher_type = Vector{CcxtTrade}
    wid = string(CcxtOHLCVVal.parameters[1], "-", hash((exc.id, issandbox(exc), sym)))
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
    start && start!(w)
    w
end

function ccxt_ohlcv_watcher(exc::Exchange, syms::Iterable; kwargs...)
    tasks = [@async ccxt_ohlcv_watcher(exc, s; kwargs...) for s in syms]
    [fetch(t) for t in tasks]
end
ccxt_ohlcv_watcher(syms::Iterable; kwargs...) = ccxt_ohlcv_watcher.(exc, syms; kwargs...)

@doc """ Initializes the watcher

$(TYPEDSIGNATURES)

This function initializes the watcher by setting up its attributes and preparing it for data fetching and processing.
It sets the symbol, exchange, and time frame for the watcher, and prepares the trades buffer.
It also sets the watcher's status to pending and initializes the last fetched and last flushed timestamps.

"""
function _init!(w::Watcher, ::CcxtOHLCVVal)
    def_view = let def_view = attr(w, :default_view, nothing)
        if isnothing(def_view)
            empty_ohlcv()
        else
            delete!(w.attrs, :default_view)
            if def_view isa Function
                def_view()
            else
                def_view
            end
        end
    end
    default_init(w, def_view)
    _trades!(w)
    _key!(w, "ccxt_$(_exc(w).name)_ohlcv_$(_sym(w))")
    _pending!(w)
    _lastfetched!(w, DateTime(0))
    _lastflushed!(w, DateTime(0))
end

_load!(w::Watcher, ::CcxtOHLCVVal) = _fastforward(w)

_tradestask(w) = attr(w, :trades_task, nothing)
_tradestask!(w) = begin
    task = _tradestask(w)
    if isnothing(task) || istaskfailed(task) || istaskdone(task)
        setattr!(w, @async(_fetch_trades_loop(w)), :trades_task)
    end
end
@doc """ Starts the watcher and fetches data

$(TYPEDSIGNATURES)

This function starts the watcher and fetches data for the watcher's symbol and time frame.
If the dataframe is not empty, it fetches data from the last date in the dataframe to the current date.
It then checks the continuity of the data in the dataframe.

"""
function _start!(w::Watcher, ::CcxtOHLCVVal)
    _pending!(w)
    empty!(_trades(w))
    df = w.view
    _fetchto!(w, df, _sym(w), _tfr(w); to=_curdate(_tfr(w)), from=if !isempty(df)
        lastdate(df)
    end)
    _check_contig(w, w.view)
end

@doc """ Continuously fetches trades and updates the watcher's trades buffer

$(TYPEDSIGNATURES)

This function continuously fetches trades for the watcher's symbol and time frame, and updates the watcher's trades buffer.
If new trades are fetched, they are appended to the trades buffer. If fetching fails, the function waits for a certain period before trying again. The waiting period increases with each failed attempt.

"""
function _fetch_trades_loop(w)
    backoff = ms(0)
    while !isnothing(w._timer) && isopen(w._timer)
        pytrades = @logerror w pyfetch(_tfunc(w), _sym(w))
        if pytrades isa Exception
            backoff += ms(500)
            @debug "ohlcv trades watcher: error" pytrades
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

@doc """ Fetches trades and updates the watcher's trades buffer

$(TYPEDSIGNATURES)

This function fetches trades for the watcher's symbol and time frame, and updates the watcher's trades buffer.
If new trades are fetched, they are appended to the trades buffer and the last fetched timestamp is updated.

"""
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
@doc """ Returns nothing if the watcher status is pending

$(TYPEDSIGNATURES)

This function checks the status of the watcher. If the status is pending, it returns nothing.

"""
function _empty_candles(w, ::Warmed)
    tf = _tfr(w)
    right = length(_trades(w)) == 0 ? _curdate(tf) : apply(tf, _firsttrade(w).timestamp)
    left = apply(tf, _lastdate(w.view))
    trail!(w.view, tf; from=left, to=right, cap=w.capacity.view)
end

@doc """ Processes the watcher data and updates the dataframe

$(TYPEDSIGNATURES)

This function processes the watcher data and updates the dataframe.
It first ensures that when no trades happen, candles are still updated.
Then, it converts trades to OHLCV format and appends the resulting data to the dataframe.
If the dataframe is not empty, it resolves any discrepancies between the dataframe and the new data.
Finally, it removes processed trades from the trades buffer.

"""
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
