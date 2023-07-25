using Data: OHLCV_COLUMNS
using Data.DFUtils: lastdate
using Misc: between
using Processing: iscomplete
using Lang: fromstruct, ifproperty!, ifkey!
using ..Watchers: @logerror

const PRICE_SOURCES = (:last, :vwap, :bid, :ask)
const CcxtOHLCVTickerVal = Val{:ccxt_ohlcv_ticker}

@doc """OHLCV watcher based on exchange tickers data. This differs from the ohlcv watcher based on trades.

- The OHLCV ticker watcher can monitor a group of symbols, while the trades watcher only one symbol per instance.
- The OHLCV ticker watcher candles do not match 1:1 the exchange candles, since they rely on polled data.
- The OHLCV ticker watcher is intended to be *lazy*. It won't pre-load/fetch data for all symbols, it will only
process new candles from the time it is started w.r.t. the timeframe provided.
- The source price chooses which price to use to build the candles any of `:last`, `:vwap`, `:bid`, `:ask` (default `:last`).

To back-fill the *view* (DataFrame) of a particular symbol, call `load!(watcher, symbol)`, which will fill
the view up to the watcher `view_capacity`.

- `logfile`: optional path to save errors.

!!! warning "Inaccurate volume"
    Since the volume data from the ticker is a daily rolling sum, the recorded volume is adjusted to be
    a fraction of it (using the timeframe as unit, see `_meanvolume!`).
    If this behaviour is not desired, it is better to use `vwap` as price source for building OHLC and ignore
    the volume column.
"""
function ccxt_ohlcv_tickers_watcher(
    exc::Exchange; price_source=:last, timeframe=tf"1m", logfile=nothing, kwargs...
)
    w = ccxt_tickers_watcher(
        exc;
        val=CcxtOHLCVTickerVal(),
        wid=CcxtOHLCVTickerVal.parameters[1],
        start=false,
        load=false,
        process=true,
        kwargs...,
    )
    w.attrs[:tickers_ohlcv] = true
    w.attrs[:timeframe] = timeframe
    @assert price_source ∈ PRICE_SOURCES "price_source $price_source is not one of: $PRICE_SOURCES"
    w.attrs[:price_source] = price_source
    w.attrs[:volume_divisor] = Day(1) / period(timeframe)
    ids = w.attrs[:ids]
    isnothing(logfile) || (w.attrs[:logfile] = logfile)
    _key!(w, "ccxt_$(exc.name)_ohlcv_tickers_$(join(ids, "_"))")
    _pending!(w)
    w
end

function _fetch!(w::Watcher, ::CcxtOHLCVTickerVal; sym=nothing)
    _fetch!(w, CcxtTickerVal())
end

@kwdef mutable struct TempCandle{T}
    timestamp::DateTime = DateTime(0)
    open::T = NaN
    high::T = -Inf
    low::T = Inf
    close::T = NaN
    volume::T = 0
    TempCandle(args...; kwargs...) = begin
        new{Float64}(args...; kwargs...)
    end
end

_symlock(w, sym) = w.attrs[:sym_locks][sym]
_loaded!(w, sym, v=true) = w.attrs[:loaded][sym] = v
_isloaded(w, sym) = get(w.attrs[:loaded], sym, false)
function _init!(w::Watcher, ::CcxtOHLCVTickerVal)
    _view!(w, Dict{String,DataFrame}())
    w.attrs[:temp_ohlcv] = Dict{String,TempCandle}()
    w.attrs[:candle_ticks] = Dict{String,Int}()
    w.attrs[:loaded] = Dict{String,Bool}()
    w.attrs[:sym_locks] = Dict{String,ReentrantLock}()
    _initsyms!(w)
    _checkson!(w)
end

function _initsyms!(w::Watcher)
    loaded = w.attrs[:loaded]
    locks = w.attrs[:sym_locks]
    for sym in _ids(w)
        loaded[sym] = false
        locks[sym] = ReentrantLock()
    end
end

_resetcandle!(w, cdl, ts, price) = begin
    cdl.timestamp = ts
    cdl.open = price
    cdl.high = typemin(Float64)
    cdl.low = typemax(Float64)
    cdl.close = price
    cdl.volume = ifelse(_isvwap(w), NaN, 0)
end
_isvwap(w) = w.attrs[:price_source] == :vwap
_ohlcv(w) = w.attrs[:temp_ohlcv]
_ticks(w) = w.attrs[:candle_ticks]
_tick!(w, sym) = _ticks(w)[sym] += 1
_zeroticks!(w, sym) = _ticks(w)[sym] = 0
function _meanvolume!(w, sym, temp_candle)
    temp_candle.volume = temp_candle.volume / _ticks(w)[sym] / w.attrs[:volume_divisor]
end
# Appends temp_candle ensuring contiguity
function _ensure_contig!(w, df, temp_candle, tf, sym)
    if !isempty(df)
        left = _lastdate(df)
        if !isrightadj(temp_candle.timestamp, left, tf)
            _resolve(w, df, temp_candle.timestamp, sym)
            @ifdebug @assert isrightadj(temp_candle.timestamp, _lastdate(df), tf)
        end
    end
    ## append complete candle
    pushmax!(df, fromstruct(temp_candle), w.capacity.view)
end
function _update_sym_ohlcv(w, ticker, last_time)
    sym = ticker.symbol
    df = @lget! w.view sym empty_ohlcv()
    latest_timestamp = apply(_tfr(w), last_time)
    price = getproperty(ticker, w.attrs[:price_source])
    temp_candle = @lget! _ohlcv(w) sym begin
        c = TempCandle(; timestamp=latest_timestamp)
        _resetcandle!(w, c, latest_timestamp, price)
        _zeroticks!(w, sym)
        c
    end
    if temp_candle.timestamp < latest_timestamp
        # NOTE: this is where a stall can happen since can potentially call
        # process adjusted volume
        _isvwap(w) ? nothing : _meanvolume!(w, sym, temp_candle)
        # `_fetch_candles`
        _ensure_contig!(w, df, temp_candle, _tfr(w), sym)
        _resetcandle!(w, temp_candle, latest_timestamp, price)
        _zeroticks!(w, sym)
    end

    # update high if higher than current
    ifproperty!(isless, temp_candle, :high, price)
    # update low if lower than current
    ifproperty!(>, temp_candle, :low, price)
    # Sum daily volume averages (to be processed at candle finalization, see above)
    _isvwap(w) || (temp_candle.volume += ticker.baseVolume)
    # update the close price to the last price
    temp_candle.close = price
    _tick!(w, sym)
end

function _process!(w::Watcher, ::CcxtOHLCVTickerVal)
    @warmup! w
    @ispending(w) && return nothing
    isempty(w.buffer) && return nothing
    last_fetch = last(w.buffer)
    @sync for (sym, ticker) in last_fetch.value
        @async @lock _symlock(w, sym) @logerror w _update_sym_ohlcv(
            w, ticker, last_fetch.time
        )
    end
end

function _start!(w::Watcher, ::CcxtOHLCVTickerVal)
    _pending!(w)
    _chill!(w)
end

function _load!(w::Watcher, ::CcxtOHLCVTickerVal, sym)
    sym ∉ _ids(w) && error("Trying to load $sym, but watcher is not tracking it.")
    _isloaded(w, sym) && return nothing
    tf = _tfr(w)
    @lock _symlock(w, sym) begin
        df = @lget! w.view sym empty_ohlcv()
        if isempty(df)
            _fetchto!(w, df, sym, tf, Val(:append); to=_nextdate(tf))
            _do_check_contig(w, df, _checks(w))
        else
            _fetchto!(w, df, sym, tf, Val(:prepend); to=_firstdate(df))
            _do_check_contig(w, df, _checks(w))
            _fetchto!(w, df, sym, tf, Val(:append); from=lastdate(df), to=_nextdate(tf))
            _do_check_contig(w, df, _checks(w))
        end
        if nrow(df) < w.view.capacity
            @warn "Can't fill view with enough data, exchange likely doesn't support fetching more than $(nrow(df)) past candles"
        end
    end
end

function _loadall!(w::Watcher, ::CcxtOHLCVTickerVal)
    (isempty(w.buffer) || isempty(w.view)) && return nothing
    syms = isempty(w.buffer) ? keys(w.view) : keys(last(w.buffer).value)
    @sync for sym in syms
        @async @logerror w _load!(w, w._val, sym)
    end
end
