using Exchanges
using Exchanges.Ccxt: _multifunc
using Python
using Data:
    Candle,
    save_ohlcv,
    zilmdb,
    DataFramesMeta,
    OHLCV_COLUMNS,
    empty_ohlcv,
    nrow,
    _contiguous_ts
using Misc: ohlcv_limits, rangeafter, Iterable, rangebetween
using .DataFramesMeta
using Processing: cleanup_ohlcv_data, iscomplete, isincomplete
using Processing.TradesOHLCV
using Base.Iterators: drop, reverse
using Fetch: fetch_candles
using Lang: @ifdebug

const CcxtOHLCVVal = Val{:ccxt_ohlcv}
@enum TradeSide buy sell
@enum TradeRole taker maker
CcxtTrade = @NamedTuple begin
    timestamp::DateTime
    symbol::String
    order::Option{String}
    type::Option{String}
    side::TradeSide
    takerOrMaker::Option{TradeRole}
    price::Float64
    amount::Float64
    cost::Float64
    fee::Option{Float64}
    fees::Vector{Float64}
end
TradeSide(v) = getproperty(@__MODULE__, Symbol(v))
TradeRole(v) = getproperty(@__MODULE__, Symbol(v))
Base.convert(::Type{TradeSide}, v) = TradeSide(v)
Base.convert(::Type{TradeRole}, v) = TradeRole(v)

Python.pyconvert(::Type{DateTime}, py::Py) = dt(pyconvert(Int, py))
Python.pyconvert(::Type{TradeSide}, py::Py) = TradeSide(py)
Python.pyconvert(::Type{TradeRole}, py::Py) = TradeRole(py)

trades_fromdict(v, ::Val{CcxtTrade}) = @fromdict(CcxtTrade, String, v)

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
    attrs[:tfunc] = _multifunc(exc, "Trades", true)[1]
    attrs[:sym] = sym
    attrs[:key] = "ccxt_$(exc.name)_ohlcv_$sym"
    attrs[:exc] = exc
    attrs[:timeframe] = timeframe
    attrs[:status] = Pending()
    attrs[:last_saved_date] = nothing
    watcher_type = Vector{CcxtTrade}
    watcher(
        watcher_type,
        :ccxt_ohlcv;
        flush=true,
        process=true,
        buffer_capacity=1,
        fetch_interval=interval,
        fetch_timeout=2interval,
        attrs
    )
end

function ccxt_ohlcv_watcher(exc::Exchange, syms::Iterable; kwargs...)
    tasks = [@async ccxt_ohlcv_watcher(exc, s; kwargs...) for s in syms]
    [fetch(t) for t in tasks]
end
ccxt_ohlcv_watcher(syms::Iterable; kwargs...) = ccxt_ohlcv_watcher.(exc, syms; kwargs...)

function _fetch!(w::Watcher, ::CcxtOHLCVVal)
    pytrades = @pyfetch _tfunc(w)(_sym(w))
    if length(pytrades) > 0
        new_trades = [
            fromdict(CcxtTrade, String, py, pyconvert, pyconvert) for py in pytrades
        ]
        append!(_trades(w), new_trades)
        pushnew!(w, new_trades)
    end
    true
end

function _flush!(w::Watcher, ::CcxtOHLCVVal)
    # we assume that _load! and process already clean the data
    from_date = max(w.view.timestamp[begin], w.attrs[:last_saved_date])
    save_ohlcv(
        zilmdb(),
        _exc(w).name,
        _sym(w),
        string(_tfr(w)),
        w.view[DateRange(from_date)];
        check=@ifdebug(true, false)
    )
    w.attrs[:last_saved_date] = w.view.timestamp[end]
end

function _get_available(w, z, last_timestamp)
    max_lookback = last_timestamp - _tfr(w) * w.capacity.view
    isempty(z) && return nothing
    maxlen = min(w.capacity.view, size(z, 1))
    available = @view(z[(end-maxlen+1):end, :])
    if dt(available[end, 1]) < max_lookback
        # data is too old, fetch just the latest candles,
        # and schedule a background task to fast forward saved data
        return nothing
    else
        return Data.to_ohlcv(available[:, :])
    end
end

function _load!(w::Watcher, ::CcxtOHLCVVal)
    tf = _tfr(w)
    df = w.view
    w.attrs[:trades] = CcxtTrade[]
    z = load(zilmdb(), _exc(w).name, _sym(w), string(tf); raw=true)[1]
    @debug @assert isempty(z) || _lastdate(z) != 0 "Corrupted storage because last date is 0: $(_lastdate(z))"

    last_timestamp = apply(tf, now())
    avl = _get_available(w, z, last_timestamp)
    rem = if isnothing(avl)
        rem = w.capacity.view
    else
        append!(df, avl)
        _check_contig(w, df)
        (last_timestamp - _lastdate(df)) ÷ period(tf)
    end

    if rem > 0
        candles = _fetch_candles(w, -max(rem, 2))
        appendmax!(df, cleanup_ohlcv_data(candles, tf), w.capacity.view)
        _check_contig(w, df)
    end
end

function _init!(w::Watcher, ::CcxtOHLCVVal)
    exc_limit = get(ohlcv_limits, _exc(w).id, 1000)
    w.attrs[:fetch_limit] = min(exc_limit, w.capacity.view)
    default_init(w, empty_ohlcv())
end

_date_to_idx(tf, from, to) = max(1, (to - from) ÷ period(tf))
function _reconcile_error(w)
    @error "Trades/ohlcv reconcile failed for $(_sym(w)) @ $(_exc(w).name)"
end

function _resolve_and_append(w, temp)
    sym = _sym(w)
    tf = _tfr(w)
    left = _lastdate(w.view)
    right = _firstdate(temp.ohlcv)
    next = _nextdate(w.view, tf)
    if next < right
        let from = next,
            to = right - period(tf),
            candles = _fetch_candles(w, from, to),
            from_to_range = rangebetween(candles.timestamp, left, right),
            sliced = nrow(candles) > 1 ? view(candles, from_to_range, :) : candles

            isempty(sliced) && begin
                @debug left right from to from_to_range
                _reconcile_error(w)
                return nothing
            end
            let cleaned = cleanup_ohlcv_data(sliced, tf)
                _firstdate(cleaned) != next && begin
                    _reconcile_error(w)
                    return nothing
                end
                appendmax!(w.view, cleaned, w.capacity.view)
                _check_contig(w, w.view)
            end
        end
    end
    # at initialization it can happen that trades fetching is too slow
    # and fetched ohlcv overlap with processed ohlcv
    from_range = rangeafter(temp.ohlcv.timestamp, left)
    if length(from_range) > 0 &&
       _firstdate(temp.ohlcv, from_range) == next
        @debug "Appending trades from $(_firstdate(temp.ohlcv, from_range)) to $(_lastdate(temp.ohlcv))"
        appendmax!(w.view, view(temp.ohlcv, from_range, :), w.capacity.view)
        _check_contig(w, w.view)
    end
    keepat!(_trades(w), (temp.stop+1):lastindex(_trades(w)))
    _warmed!(w, _status(w))
    @debug "Latest candle for $sym is $(_lastdate(temp.ohlcv))"
end

_update_timestamps(left, prd, ts, from_idx) = begin
    for i in from_idx:lastindex(ts)
        left += prd
        ts[i] = left
    end
end

_empty_candles(_, ::Pending) = nothing
# Ensure that when no trades happen, candles are still updated
# NOTE: this assumes all trades were witnesses from the watcher side
# otherwise we couldn't tell if a candle truly had 0 volume.
function _empty_candles(w, ::Warmed)
    tf = _tfr(w)
    prd = period(tf)
    # If no trades happened at all, consider the actual candle
    right = length(_trades(w)) == 0 ? _curdate(tf) : apply(tf, _firsttrade(w).timestamp)
    left = apply(tf, _lastdate(w.view))
    n_to_append = (right - left) ÷ prd - 1
    if n_to_append > 0
        df = w.view
        push!(df, @view(df[end, :]))
        size(df, 1) > w.capacity.view && popfirst!(df)
        left += prd
        close = df[end, :close]
        df[end, :timestamp] = left
        df[end, :open] = close
        df[end, :high] = close
        df[end, :low] = close
        df[end, :volume] = 0
        n_to_append -= 1
        if n_to_append > 0
            to_append = repeat(@view(df[end:end, :]), n_to_append)
            appendmax!(df, to_append, w.capacity.view)
            from_idx = lastindex(df.timestamp) - n_to_append + 1
            _update_timestamps(left, prd, df.timestamp, from_idx)
        end
    end
end

function _process!(w::Watcher, ::CcxtOHLCVVal)
    _empty_candles(w, _status(w))
    # On startup, the first trades that we receive are likely incomplete
    # So we have to discard them, and only consider trades after the first (normalized) timestamp
    # Practically, the `trades_to_ohlcv` function has to *trim_left* only once, at the beginning (for every sym).
    temp = trades_to_ohlcv(
        _trades(w), _tfr(w); trim_left=@ispending(w), trim_right=false
    )
    isnothing(temp) && return nothing
    if isempty(w.view)
        appendmax!(w.view, temp.ohlcv, w.capacity.view)
        keepat!(_trades(w), (temp.stop+1):lastindex(_trades(w)))
        _warmed!(w, _status(w))
    else
        _resolve_and_append(w, temp)
    end
end

function _start(w::Watcher, ::CcxtOHLCVVal)
    _pending!(w)
    empty!(_trades(w))
    candles = _fetch_candles(w, _lastdate(w))
    candles = cleanup_ohlcv_data(candles, _tfr(w))
    ra = rangeafter(candles.timestamp, _lastdate(w.view))
    appendmax!(w.view, view(candles, ra, :), w.capacity.view)
    _check_contig(w, w.view)
end
