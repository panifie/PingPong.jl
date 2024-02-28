using ..Data: OHLCV_COLUMNS
using ..Data.DFUtils: lastdate
using ..Misc: between
using ..Fetch.Processing: iscomplete
using ..Lang: fromstruct, ifproperty!, ifkey!
using ..Watchers: @logerror, _val, default_view

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
    exc::Exchange;
    price_source=:last,
    timeframe=tf"1m",
    logfile=nothing,
    default_view=nothing,
    kwargs...,
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

    a = attrs(w)
    a[:default_view] = default_view
    a[:tickers_ohlcv] = true
    a[:timeframe] = timeframe
    @assert price_source ∈ PRICE_SOURCES "price_source $price_source is not one of: $PRICE_SOURCES"
    a[:price_source] = price_source
    a[:volume_divisor] = Day(1) / period(timeframe)
    ids = a[:ids]
    isnothing(logfile) || (a[:logfile] = logfile)
    _key!(w, string("ccxt_", exc.name, issandbox(exc), "_ohlcv_tickers_", join(ids, "_")))
    _pending!(w)
    w
end

function _fetch!(w::Watcher, ::CcxtOHLCVTickerVal; sym=nothing)
    _fetch!(w, CcxtTickerVal())
end

@doc """ A mutable struct representing a temporary candlestick chart.

$(FIELDS)

The `TempCandle` struct holds the timestamp, open, high, low, close, and volume values for a temporary candlestick chart.

"""
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

_symlock(w, sym) = attr(w, :sym_locks)[sym]
_loaded!(w, sym, v=true) = attr(w, :loaded)[sym] = v
_isloaded(w, sym) = get(attr(w, :loaded), sym, false)
@doc """ Initializes the watcher for the OHLCV ticker.

$(TYPEDSIGNATURES)

This function initializes the watcher with default view, temporary OHLCV, candle ticks, loaded symbols, and symbol locks.
It also initializes the symbols and checks for the watcher.

"""
function _init!(w::Watcher, ::CcxtOHLCVTickerVal)
    _view!(w, default_view(w, Dict{String,DataFrame}))
    a = attrs(w)
    a[:temp_ohlcv] = Dict{String,TempCandle}()
    a[:candle_ticks] = Dict{String,Int}()
    a[:loaded] = Dict{String,Bool}()
    a[:sym_locks] = Dict{String,ReentrantLock}()
    _initsyms!(w)
    _checkson!(w)
end

@doc """ Initializes the symbols for the watcher.

$(TYPEDSIGNATURES)

This function initializes the symbols for the watcher and sets up the loaded symbols and symbol locks.

"""
function _initsyms!(w::Watcher)
    loaded = attr(w, :loaded)
    locks = attr(w, :sym_locks)
    for sym in _ids(w)
        loaded[sym] = false
        locks[sym] = ReentrantLock()
    end
end

@doc """ Resets the temporary candlestick chart with a new timestamp and price.

$(TYPEDSIGNATURES)

This function resets the temporary candlestick chart with a new timestamp and price.
It also resets the high and low prices to their extreme values and the volume to zero if the price source is not `vwap`.

"""
_resetcandle!(w, cdl, ts, price) = begin
    cdl.timestamp = ts
    cdl.open = price
    cdl.high = typemin(Float64)
    cdl.low = typemax(Float64)
    cdl.close = price
    cdl.volume = ifelse(_isvwap(w), NaN, 0)
end
_isvwap(w) = attr(w, :price_source) == :vwap
_ohlcv(w) = attr(w, :temp_ohlcv)
_ticks(w) = attr(w, :candle_ticks)
_tick!(w, sym) = _ticks(w)[sym] += 1
_zeroticks!(w, sym) = _ticks(w)[sym] = 0
@doc """ Adjusts the volume of the temporary candlestick chart.

$(TYPEDSIGNATURES)

This function adjusts the volume of the temporary candlestick chart by dividing it by the number of ticks and the volume divisor.

"""
function _meanvolume!(w, sym, temp_candle)
    temp_candle.volume = temp_candle.volume / _ticks(w)[sym] / attr(w, :volume_divisor)
end
@doc """ Appends temp_candle ensuring contiguity.

$(TYPEDSIGNATURES)

This function appends the temporary candle to the DataFrame ensuring contiguity.
If the temporary candle is not right adjacent to the last date in the DataFrame, it resolves the gap and then appends the candle.

"""
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
@doc """ Updates the OHLCV for a specific symbol.

$(TYPEDSIGNATURES)

This function updates the OHLCV for a specific symbol based on the latest timestamp and price from the ticker.
It resets the temporary candlestick chart if the timestamp is newer than the current one and ensures contiguity when appending the candle to the DataFrame.

"""
function _update_sym_ohlcv(w, ticker, last_time)
    sym = ticker.symbol
    df = @lget! w.view sym empty_ohlcv()
    latest_timestamp = apply(_tfr(w), last_time)
    price = getproperty(ticker, attr(w, :price_source))
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

@doc """ Processes the watcher data.

$(TYPEDSIGNATURES)

This function processes the watcher data by updating the OHLCV for each symbol in the last fetch.
It does this in a synchronous manner, ensuring that all updates are completed before proceeding.

"""
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
    _reset_tickers_func!(w)
    _pending!(w)
    _chill!(w)
end

@doc """ Loads the OHLCV data for a specific symbol.

$(TYPEDSIGNATURES)

This function loads the OHLCV data for a specific symbol.
If the symbol is not being tracked by the watcher or if the data for the symbol has already been loaded, the function returns nothing.

"""
function _load!(w::Watcher, ::CcxtOHLCVTickerVal, sym)
    sym ∉ _ids(w) && error("Trying to load $sym, but watcher is not tracking it.")
    if _isloaded(w, sym)
        return nothing
    end
    tf = _tfr(w)
    @lock _symlock(w, sym) begin
        df = @lget! w.view sym empty_ohlcv()
        if isempty(df)
            _fetchto!(w, df, sym, tf, Val(:append); to=_nextdate(tf))
            _do_check_contig(w, df, _checks(w))
        else
            let (from, to) = (lastdate(df), _nextdate(tf))
                if length(from:(tf.period):to) > w.capacity.view
                    from = to - period(tf) * w.capacity.view
                end
                _fetchto!(w, df, sym, tf, Val(:append); from, to)
            end
            _do_check_contig(w, df, _checks(w))
            if nrow(df) < w.capacity.view
                let to = _firstdate(df) + period(tf)
                    _fetchto!(w, df, sym, tf, Val(:prepend); to)
                    _do_check_contig(w, df, _checks(w))
                end
            end
        end
        if nrow(df) < w.capacity.view
            @warn "Can't fill view with enough data, exchange likely doesn't support fetching more than $(nrow(df)) past candles"
        end
    end
end

@doc """ Loads the OHLCV data for all symbols.

$(TYPEDSIGNATURES)

This function loads the OHLCV data for all symbols.
If the buffer or view of the watcher is empty, the function returns nothing.

"""
function _loadall!(w::Watcher, ::CcxtOHLCVTickerVal)
    if (isempty(w.buffer) || isempty(w.view))
        return nothing
    end
    syms = isempty(w.buffer) ? keys(w.view) : keys(last(w.buffer).value)
    @sync for sym in syms
        @async @logerror w _load!(w, _val(w), sym)
    end
end
