using ..Data: Candle
using ..Fetch.Exchanges
using ..Misc: Iterable
using ..Fetch.Processing.TradesOHLCV
using ..Fetch.Processing: trail!
using ..Fetch.Python
using ..Misc: sleep_pad
using .Lang: @get

const CcxtOHLCVVal = Val{:ccxt_ohlcv}

# FIXME
Python.pyconvert(::Type{DateTime}, py::Py) = dt(pyconvert(Int, py))
Python.pyconvert(::Type{TradeSide}, py::Py) = TradeSide(py)
Python.pyconvert(::Type{TradeRole}, py::Py) = TradeRole(py)
function Python.pyconvert(::Type{FeesType}, py::Py)
    if isdict(py)
        cost = get(py, "cost", pybuiltins.None)
        if pyisnone(cost)
            cost = nothing
        end
        currency = get(py, "currency", pybuiltins.None)
        if pyisnone(currency)
            currency = nothing
        end
        (; cost, currency)
    elseif pyisnone(py)
        nothing
    elseif pyisinstance(py, pybuiltins.float)
        pytofloat(py)
    else
        error("watchers: invalid fees type $py")
    end
end

_trades(w::Watcher) = attr(w, :trades)
_trades!(w) = setattr!(w, CcxtTrade[], :trades)
_lastpushed(w) = attr(w, :last_pushed)
_lastpushed!(w, v) = setattr!(w, v, :last_pushed)

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
    iswatch=nothing,
)
    check_timeout(exc, interval)
    attrs = Dict{Symbol,Any}()
    _sym!(attrs, sym)
    _exc!(attrs, exc)
    _tfr!(attrs, timeframe)
    attrs[:default_view] = default_view
    attrs[:quiet] = quiet
    attrs[k"ohlcv_method"] = :trades
    if !isnothing(iswatch)
        attrs[:iswatch] = iswatch
    end
    attrs[:issandbox] = issandbox(exc)
    attrs[:excparams] = params(exc)
    attrs[:excaccount] = account(exc)
    watcher_type = Vector{CcxtTrade}
    wid = string(CcxtOHLCVVal.parameters[1], "-", hash((exc.id, attrs[:issandbox], sym)))
    w = watcher(
        watcher_type,
        wid,
        CcxtOHLCVVal();
        start=false,
        flush=true,
        process=false,
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
            sym = _sym(w)
            met = :trades
            eid = exchangeid(_exc(w).id)
            period = _tfr(w).period
            cached_ohlcv!(eid, met, period, sym)
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
    _lastpushed!(w, DateTime(0))
    _lastflushed!(w, DateTime(0))
end

_load!(w::Watcher, ::CcxtOHLCVVal) = _fastforward(w)

@doc """ Starts the watcher and fetches data

$(TYPEDSIGNATURES)

This function starts the watcher and fetches data for the watcher's symbol and time frame.
If the dataframe is not empty, it fetches data from the last date in the dataframe to the current date.
It then checks the continuity of the data in the dataframe.

"""
function _start!(w::Watcher, ::CcxtOHLCVVal)
    attrs = w.attrs
    attrs[:backoff] = ms(0)
    eid = exchangeid(_exc(w))
    exc = getexchange!(
        eid, attrs[:excparams]; sandbox=attrs[:issandbox], account=attrs[:excaccount]
    )
    _exc!(attrs, exc)

    # TODO: Make watcher multi symbol compatible
    watch_func = first(exc, :watchTrades)
    sym = _sym(w)
    @assert sym isa AbstractString
    fetch_func = choosefunc(exc, "Trades", sym)
    iswatch = @lget! attrs :iswatch !isnothing(watch_func)

    _pending!(w)
    empty!(_trades(w))
    df = w.view
    _fetchto!(w, df, _sym(w), _tfr(w); to=_curdate(_tfr(w)), from=if !isempty(df)
        lastdate(df)
    end)
    _check_contig(w, w.view)

    if iswatch
        corogen_func(_) = coro_func() = watch_func(_sym(w))
        init_func() = fetch_func()
        wrapper_func(v) = _parse_trades(w, v)
        handler_task!(w; init_func, corogen_func, wrapper_func, if_func=!isempty)
        _tfunc!(attrs, () -> check_task!(w))
    else
        trades_func() = begin
            tasks = @lget! attrs :process_tasks Task[]
            fetched = @lock w begin
                resp = fetch_func()
                v = _parse_trades(w, resp)
                !isnothing(v) && !isempty(v)
            end
            if fetched
                push!(tasks, @async process!(w))
                filter!(!istaskdone, tasks)
            end
        end
        _tfunc!(attrs, trades_func)
    end
end

function _parse_trades(w, pytrades)
    this_trades = if isdict(pytrades)
        @get pytrades _sym(w) pydict()
    elseif islist(pytrades)
        pylist(pytrades)
    end
    if isnothing(this_trades)
        w[:backoff] += ms(500)
        @debug "ohlcv trades watcher: error" pytrades
        sleep(w[:backoff])
        return nothing
    end
    if length(pytrades) > 0
        new_trades = [
            fromdict(CcxtTrade, String, py, pyconvert, pyconvert) for py in this_trades
        ]
        Main.tr = new_trades
        Main.wtr = _trades(w)
        append!(_trades(w), new_trades)
        last_date = last(new_trades).timestamp
        _lastpushed!(w, last_date)
        if !w[:iswatch]
            @lock w pushnew!(w, _trades(w))
        end
        return new_trades
    end
end

@doc """ Fetches trades and updates the watcher's trades buffer

$(TYPEDSIGNATURES)

This function fetches trades for the watcher's symbol and time frame, and updates the watcher's trades buffer.
If new trades are fetched, they are appended to the trades buffer and the last fetched timestamp is updated.

"""
function _fetch!(w::Watcher, ::CcxtOHLCVVal)
    _tfunc(w)()
    return isempty(_trades(w))
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
    raw_right = isempty(_trades(w)) ? w.last_fetch : _firsttrade(w).timestamp
    left = apply(tf, _lastdate(w.view))
    right = apply(tf, raw_right)
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
    temp =
        let temp = trades_to_ohlcv(
                _trades(w), _tfr(w); trim_left=@ispending(w), trim_right=false
            )
            isnothing(temp) && return nothing
            ohlcv = cleanup_ohlcv_data(temp.ohlcv, _tfr(w))
            (; ohlcv, temp.start, temp.stop)
        end
    if isempty(w.view)
        appendmax!(w.view, temp.ohlcv, w.capacity.view)
    else
        _resolve(w, w.view, temp.ohlcv)
    end
    keepat!(_trades(w), (temp.stop + 1):lastindex(_trades(w)))
    _warmed!(w, _status(w))
    @debug "Latest candle for $(_sym(w)) is $(_lastdate(temp.ohlcv))"
end

_stop!(w::Watcher, ::CcxtOHLCVVal) = stop_handler_task!(w)
