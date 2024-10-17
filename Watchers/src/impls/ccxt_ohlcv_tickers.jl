using ..Data: OHLCV_COLUMNS, contiguous_ts
using ..Data.DFUtils: lastdate, dateindex
using ..Misc: between, truncate_file
using ..Fetch.Processing: iscomplete
using ..Fetch.Exchanges: ratelimit_njobs
using ..Lang: fromstruct, ifproperty!, ifkey!, @acquire, @add_statickeys!, @k_str
using ..Watchers: @logerror, _val, default_view, buffer, watcher_tasks

const PRICE_SOURCES = (:last, :vwap, :bid, :ask)
const CcxtOHLCVTickerVal = Val{:ccxt_ohlcv_ticker}

baremodule LogOHLCVTickers end

@add_statickeys! begin
    tickers_ohlcv
    price_source
    diff_volume
    volume_divisor
    stale_candle
    stale_df
    callback
    vwap
    minrows_warned
    symstates
end

@doc """OHLCV watcher based on exchange tickers data. This differs from the ohlcv watcher based on trades.

- The OHLCV ticker watcher can monitor a group of symbols, while the trades watcher only one symbol per instance.
- The OHLCV ticker watcher candles do not match 1:1 the exchange candles, since they rely on polled data.
- The OHLCV ticker watcher is intended to be *lazy*. It won't pre-load/fetch data for all symbols, it will only
process new candles from the time it is started w.r.t. the timeframe provided.
- The source price chooses which price to use to build the candles any of `:last`, `:vwap`, `:bid`, `:ask` (default `:last`).

To back-fill the *view* (DataFrame) of a particular symbol, call `load!(watcher, symbol)`, which will fill
the view up to the watcher `view_capacity`.

- `logfile`: optional path to save errors.
- `diff_volume`: calculate volume by subtracting the rolling 1d snapshots (`true`)
- `n_jobs`: concurrent startup fetching jobs for ohlcv
- `callback`: function `fn(df, sym)` called every time a dataframe is updated

!!! "warning" startup times
    The higher the number of symbols, the longer it will take to load initial OHLCV candles. When the semaphore (`w[:sem]`) is not full anymore, all the symbols should then start to trail the latest (full) candle as soon as possible.
"""
function ccxt_ohlcv_tickers_watcher(
    exc::Exchange;
    price_source=:last,
    diff_volume=true,
    timeframe=tf"1m",
    logfile=nothing,
    buffer_capacity=100,
    view_capacity=count(timeframe, tf"1d") + 1 + buffer_capacity,
    default_view=nothing,
    n_jobs=ratelimit_njobs(exc),
    callback=Returns(nothing),
    kwargs...,
)
    w = ccxt_tickers_watcher(
        exc;
        val=CcxtOHLCVTickerVal(),
        wid=CcxtOHLCVTickerVal.parameters[1],
        start=false,
        load=false,
        process=false,
        view_capacity,
        buffer_capacity,
        kwargs...,
    )

    a = attrs(w)
    @assert price_source ∈ PRICE_SOURCES "price_source $price_source is not one of: $PRICE_SOURCES"
    @setkey! a price_source
    @setkey! a default_view
    @setkey! a timeframe
    @setkey! a n_jobs
    @setkey! a callback
    @setkey! a diff_volume
    a[k"ohlcv_method"] = :tickers
    a[k"minrows_warned"] = false
    a[k"tickers_ohlcv"] = true
    a[k"sem"] = Base.Semaphore(n_jobs)
    a[k"volume_divisor"] = Day(1) / period(timeframe)
    a[k"status"] = Pending()
    a[k"key"] = string(
        "ccxt_", exc.name, issandbox(exc), "_ohlcv_tickers_", join(a[k"ids"], "_")
    )
    if !isnothing(logfile)
        @setkey! a logfile
    end
    w
end

function _fetch!(w::Watcher, ::CcxtOHLCVTickerVal; sym=nothing)
    _fetch!(w, CcxtTickerVal())
    _checkforstale(w)
    true
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
        new{DFT}(args...; kwargs...)
    end
end

@kwdef mutable struct TickerWatcherSymbolState2
    const sym::String
    const temp::TempCandle = TempCandle()
    const lock::ReentrantLock = ReentrantLock()
    loaded::Bool = false
    daily_volume::DFT = 0.0
    ticks::Int16 = 0
    backoff::Int8 = 0
    isprocessed::Bool = false
    processed_time::DateTime = DateTime(0)
end

@doc """ Initializes the watcher for the OHLCV ticker.

$(TYPEDSIGNATURES)

This function initializes the watcher with default view, temporary OHLCV, candle ticks, loaded symbols, and symbol locks.
It also initializes the symbols and checks for the watcher.

"""
function _init!(w::Watcher, ::CcxtOHLCVTickerVal)
    _view!(w, default_view(w, Dict{String,DataFrame}))
    a = attrs(w)
    a[k"last_processed"] = typemax(DateTime)
    _checkson!(w)
end

@doc """ Resets the temporary candlestick chart with a new timestamp and price.

$(TYPEDSIGNATURES)

This function resets the temporary candlestick chart with a new timestamp and price.
It also resets the high and low prices to their extreme values and the volume to zero if the price source is not `vwap`.

"""
resetcandle!(w, cdl::TempCandle, ts, price) = begin
    cdl.timestamp = ts
    cdl.open = price
    cdl.high = typemin(Float64)
    cdl.low = typemax(Float64)
    cdl.close = price
    cdl.volume = ifelse(_isvwap(w), NaN, 0.0)
end
_isvwap(w) = w[k"price_source"] == k"vwap"

function _maybe_resolve(w, df, sym, this_ts, tf)
    if isempty(df)
        @acquire w[k"sem"] _ensure_ohlcv!(w, sym)
        if isempty(df)
            return k"stale_df"
        end
    end
    if this_ts == _lastdate(df)
        k"stale_candle"
    elseif !isrightadj(this_ts, _lastdate(df), tf)
        @debug "ohlcv tickers: resolving stale df" _module = LogOHLCVTickers sym _lastdate(
            df
        ) this_ts
        @acquire w[k"sem"] _ensure_ohlcv!(w, sym)
        @ifdebug @assert isrightadj(this_ts, _lastdate(df), tf)
        k"stale_df"
    end
end
@doc """ Adjusts the volume of the temporary candlestick chart.

$(TYPEDSIGNATURES)

This function adjusts the volume of the temporary candlestick chart by dividing it by the number of ticks and the volume divisor.

"""
function _meanvolume!(w, state)
    cdl = state.temp
    cdl.volume = cdl.volume / cdl.ticks / w[k"volume_divisor"]
end
@doc """ Appends temp_candle ensuring contiguity.

$(TYPEDSIGNATURES)

This function appends the temporary candle to the DataFrame ensuring contiguity.
If the temporary candle is not right adjacent to the last date in the DataFrame, it resolves the gap and then appends the candle.

"""
function _ensure_contig!(w, df, temp_candle::TempCandle, tf, sym)
    if isnothing(_maybe_resolve(w, df, sym, temp_candle.timestamp, tf))
        ## append complete candle (check again adjaciency)
        if isrightadj(temp_candle.timestamp, _lastdate(df), tf)
            @debug "ohlcv tickers watcher: pushing" _module = LogOHLCVTickers sym temp_candle.timestamp
            pushmax!(df, fromstruct(temp_candle), w.capacity.view)
            invokelatest(w[k"callback"], df, sym)
        end
    end
end
function diff_volume!(w, df, state, latest_timestamp)
    temp_candle = state.temp
    sym = state.sym
    # this is set on each ticker should be equal to the previous ticker baseVolume
    prev_candle_daily = state.daily_volume
    state.daily_volume = temp_candle.volume
    if iszero(prev_candle_daily) && !iszero(temp_candle.volume)
        @warn "ohlcv tickers watcher: zero prev daily volume" latest_timestamp sym temp_candle.volume
        @acquire w[k"sem"] _ensure_ohlcv!(w, sym)
        return false
    end
    # the index of the first candle which volume
    # should be dropped from the rolling 1d ticker volume
    dropped_candle_date = latest_timestamp - Day(1) - _tfr(w)
    idx = dateindex(df, dropped_candle_date)
    if idx < 1
        resolution = _maybe_resolve(w, df, sym, latest_timestamp, _tfr(w))
        if k"stale_candle" == resolution
            @debug "ohlcv tickers watcher: stale candle" _module = LogOHLCVTickers sym _lastdate(
                df
            ) latest_timestamp
            temp_candle.volume = 0.0
            return false
        else
            if state.backoff < 3
                @acquire w[k"sem"] _ensure_ohlcv!(w, sym)
                state.backoff += 1
            end
            idx = dateindex(df, dropped_candle_date)
            if idx < 1
                @debug "ohlcv tickers watcher: failed to resolve candles history" _module =
                    LogOHLCVTickers sym n = nrow(df) dropped_candle_date
                temp_candle.volume = 0.0
                return false
            end
        end
    end
    first_tf_candle_volume = df.volume[idx]
    volume_diff = temp_candle.volume - prev_candle_daily + first_tf_candle_volume
    temp_candle.volume = max(volume_diff, 0.0)
    true
end
@doc """ Updates the OHLCV for a specific symbol.

$(TYPEDSIGNATURES)

This function updates the OHLCV for a specific symbol based on the latest timestamp and price from the ticker.
It resets the temporary candlestick chart if the timestamp is newer than the current one and ensures contiguity when appending the candle to the DataFrame.

"""
function _update_sym_ohlcv(w, ticker, latest_timestamp, sym=ticker.symbol)
    @debug "ohlcv tickers watcher: update temp candle" _module = LogOHLCVTickers sym latest_timestamp now()
    state = w[k"symstates"][sym]::TickerWatcherSymbolState2
    df = @lget! w.view sym cached_ohlcv!(w, :tickers; sym=sym)
    price = getproperty(ticker, w[k"price_source"])
    temp_candle = state.temp
    isdiff = w[k"diff_volume"]
    if temp_candle.timestamp == DateTime(0)
        resetcandle!(w, temp_candle, latest_timestamp, price)
        # if new candle timestamp, push the previous finished candle
    elseif temp_candle.timestamp < latest_timestamp
        if isdiff
            diff_volume!(w, df, state, latest_timestamp)
        elseif !_isvwap(w)
            # NOTE: this is where a stall can happen since can potentially call
            # process adjusted volume
            _meanvolume!(w, state)
        end
        # `_fetch_candles`
        _ensure_contig!(w, df, temp_candle, _tfr(w), sym)
        resetcandle!(w, temp_candle, latest_timestamp, price)
        state.ticks = 0
    end

    # update high if higher than current
    ifproperty!(isless, temp_candle, :high, price)
    # update low if lower than current
    ifproperty!(>, temp_candle, :low, price)
    # Sum daily volume averages (to be processed at candle finalization, see above)
    if isdiff
        temp_candle.volume = ticker.baseVolume
    elseif !_isvwap(w)
        temp_candle.volume += ticker.baseVolume
    end
    # update the close price to the last price
    temp_candle.close = price
    state.ticks += 1
end

function _idx_to_process(w, date, prev_idx)
    idx = findprev(snap -> snap.time <= date, buffer(w), prev_idx)
    if isnothing(idx)
        if first((buffer(w))).time > date
            firstindex(buffer(w))
        end
    elseif buffer(w)[idx].time != date
        idx
    elseif idx < length(buffer(w))
        idx + 1
    end
end

function sym_procstate!(state::TickerWatcherSymbolState2, p=false, time=DateTime(0))
    state.isprocessed = p
    state.processed_time = time
end

@doc """ Processes the watcher data.

$(TYPEDSIGNATURES)

This function processes the watcher data by updating the OHLCV for each symbol in the last fetch.
It does this in a synchronous manner, ensuring that all updates are completed before proceeding.

"""
function _process!(w::Watcher, ::CcxtOHLCVTickerVal)
    @warmup! w
    last_p_date = _lastprocessed(w)
    if isempty(w)
        return nothing
    elseif @ispending(w)
        if w[k"diff_volume"] && !isempty(buffer(w))
            data_date, data = last(buffer(w))
            states = w[k"symstates"]
            for (sym, ticker) in data
                this_state = get(states, sym, nothing)
                if this_state isa TickerWatcherSymbolState2
                    this_state.daily_volume = ticker.baseVolume
                end
            end
        end
        return nothing
    end
    symstates = w[k"symstates"]
    map(sym_procstate!, values(symstates))
    last_idx = lastindex(buffer(w))
    idx = _idx_to_process(w, last_p_date, last_idx)
    latest_timestamp = DateTime(0)
    this_tf = _tfr(w)
    tasks = watcher_tasks(w)
    while !isnothing(idx)
        data_date, data = w.buffer[idx]
        for (sym, ticker) in data
            state = get(symstates, sym, nothing)
            if !isnothing(state)
                latest_timestamp = apply(this_tf, @something ticker.timestamp data_date)
                t = @async @lock state.lock _update_sym_ohlcv(w, ticker, latest_timestamp)
                push!(tasks, errormonitor(t))
                sym_procstate!(state, true, latest_timestamp)
            end
        end
        _lastprocessed!(w, data_date)
        idx = _idx_to_process(w, data_date, last_idx)
    end
end

@doc """ Checks for stale data in the watcher.

$(TYPEDSIGNATURES)

This function checks for stale data in the watcher by iterating over the symbol states and updating the OHLCV if necessary.
"""
function _checkforstale(w)
    symstates = w.symstates
    this_tf = _tfr(w)
    latest_timestamp = apply(this_tf, @lget!(last(buffer(w), 1), 1, (; time=now())).time)
    tasks = watcher_tasks(w)
    for state in values(symstates)
        if !state.isprocessed && apply(this_tf, state.processed_time) < latest_timestamp
            t = @async @lock state.lock _update_sym_ohlcv(
                w, nothing, latest_timestamp, state.sym
            )
            push!(tasks, errormonitor(t))
            sym_procstate!(state, true, latest_timestamp)
        end
    end
end

function _start!(w::Watcher, ::CcxtOHLCVTickerVal)
    # NOTE: order is important
    empty!(buffer(w))
    _pending!(w)
    _chill!(w)
    a = attrs(w)
    a[k"sem"] = Base.Semaphore(a[k"n_jobs"])
    a[k"symstates"] = Dict(sym => TickerWatcherSymbolState2(; sym) for sym in _ids(w))
    _reset_tickers_func!(w)
end

_stop!(w::Watcher, ::CcxtOHLCVTickerVal) = _stop!(w, CcxtTickerVal())

function _ensure_ohlcv!(w, sym)
    @debug "ohlcv tickers watcher: ensure" _module = LogOHLCVTickers sym
    tf = _tfr(w)
    min_rows = w.capacity.view - w.capacity.buffer
    df = @lget! w.view sym ohlcv_cached!(w; sym)
    if isempty(df)
        local this, from, to
        # fetch in excess
        this = now()
        from = this - (w.capacity.view + 1) * tf
        to = _nextdate(tf)
        _fetchto!(w, df, sym, tf, Val(:append); from, to)
        _do_check_contig(w, df, _checks(w))
    else
        (from, to) = (lastdate(df), _nextdate(tf))
        if length(from:(period(tf)):to) > min_rows
            from = to - period(tf) * w.capacity.view
        end
        _fetchto!(w, df, sym, tf, Val(:append); from, to)
        _do_check_contig(w, df, _checks(w))
        if nrow(df) < min_rows
            to = _firstdate(df) + period(tf)
            _fetchto!(w, df, sym, tf, Val(:prepend); to)
            _do_check_contig(w, df, _checks(w))
        end
    end
    if nrow(df) < min_rows && !w[k"minrows_warned"]
        # TODO: provide support of upsampling with interpolation
        @warn "ohlcv tickers watcher: can't fill view with enough data" sym nrow(df) min_rows
        w[k"minrows_warned"] = true
    end
    cb = get(w.attrs, k"callback", nothing)
    if applicable(cb, (df, sym))
        invokelatest(cb, df, sym)
    end
end

function _load_ohlcv!(w, sym)
    state = attr(w, k"symstates", nothing)
    if isnothing(state)
        @error "ohlcv tickers watcher: load filed, not tracking" sym
    end
    if !state.loaded
        @lock state.lock @acquire w[k"sem"] _ensure_ohlcv!(w, sym)
        state.loaded = true
    end
end

@doc """ Loads the OHLCV data for a specific symbol.

$(TYPEDSIGNATURES)

This function loads the OHLCV data for a specific symbol.
If the symbol is not being tracked by the watcher or if the data for the symbol has already been loaded, the function returns nothing.

"""
_load!(w::Watcher, ::CcxtOHLCVTickerVal, sym) = _load_ohlcv!(w, sym)

function _load_all_ohlcv!(w)
    if (isempty(w.buffer) || isempty(w.view))
        return nothing
    end
    syms = isempty(w.buffer) ? keys(w.view) : keys(last(w.buffer).value)
    @sync for sym in syms
        @async @acquire w[k"sem"] @logerror w _load!(w, _val(w), sym)
    end
end

@doc """ Loads the OHLCV data for all symbols.

$(TYPEDSIGNATURES)

This function loads the OHLCV data for all symbols.
If the buffer or view of the watcher is empty, the function returns nothing.

"""
_loadall!(w::Watcher, ::CcxtOHLCVTickerVal) = _load_all_ohlcv!(w)

function _update_sym_ohlcv(w, ::Nothing, latest_timestamp, sym)
    @debug "ohlcv tickers watcher: no update trail check" _module = LogOHLCVTickers sym
    df = get(w.view, sym, nothing)
    if isnothing(df)
        return nothing
    end
    state = get(w[k"symstates"], sym, nothing)
    if isnothing(state)
        return nothing
    end
    temp_candle = state.temp
    price = if isfinite(temp_candle.close) && !iszero(temp_candle.close)
        temp_candle.close
    elseif !isempty(df)
        p = last(df.close)
        resetcandle!(w, temp_candle, _lastdate(df), p)
        p
    else
        return nothing
    end
    # if new candle timestamp, push the previous finished candle
    if temp_candle.timestamp < latest_timestamp
        if state.ticks > 0
            if w[k"diff_volume"]
                diff_volume!(w, df, state, latest_timestamp)
            elseif !_isvwap(w)
                # NOTE: this is where a stall can happen since can potentially call
                # process adjusted volume
                _meanvolume!(w, state)
            end
        end
        # `_fetch_candles`
        _ensure_contig!(w, df, temp_candle, _tfr(w), sym)
        resetcandle!(w, temp_candle, latest_timestamp, price)
        state.ticks = 0
    end
end
