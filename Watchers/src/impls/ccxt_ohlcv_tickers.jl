using Data: OHLCV_COLUMNS
using Misc: between

const CcxtOHLCVTickerVal = Val{:ccxt_ohlcv_ticker}

_view(w) = w.attrs[:view]
function ccxt_ohlcv_tickers_watcher(exc::Exchange; timeframe=tf"1m", kwargs...)
    w = ccxt_tickers_watcher(
        exc; wid=:ccxt_ohlcv_ticker, start=false, process=true, kwargs...
    )
    w.attrs[:tickers_ohlc] = true
    w.attrs[:timeframe] = timeframe
    ids = w.attrs[:ids]
    _key!(w, "ccxt_$(exc.name)_ohlcv_tickers_$(join(ids, "_"))")
    _view!(w, Dict{String,DataFrame}())
    _pending!(w)
    w
end

function _fetch!(w::Watcher, ::CcxtOHLCVTickerVal; sym=nothing)
    _fetch!(w, CcxtTickerVal())
end

@kwdef mutable struct TempCandle{T}
    timestamp::DateTime = DateTime(0)
    open::T = 0
    high::T = 0
    low::T = 0
    close::T = 0
    volume::T = 0
    TempCandle(args...; kwargs...) = begin
        new{Float64}(args...; kwargs...)
    end
end

function _init!(w::Watcher, ::CcxtOHLCVTickerVal)
    w.attrs[:temp_ohlcv] = Dict{String,TempCandle}()
end

_ohlcv(w) = w.attrs[:temp_ohlcv]

function _update_sym_ohlcv(w, ticker, last_time)
    sym = ticker.symbol
    latest_timestamp = apply(_tfr(w), @something(ticker.timestamp, last_time))
    temp_candle = @lget! _ohlcv(w) sym TempCandle(timestamp=latest_timestamp)
    if temp_candle.timestamp < latest_timestamp
        @assert iscomplete(temp_candle)
        @assert isrightadj(temp_candle.timestamp, _lastdate(w.view[sym]))
        ## append complete candle
        push!(w.view[sym], temp_candle)
    end
    temp_candle.timestamp = latest_timestamp
    temp_candle.open = ticker.open
    temp_candle.high = ticker.high
    temp_candle.low = ticker.low
    temp_candle.close = ticker.close
    temp_candle.volume = ticker.baseVolume
end

function _process!(w::Watcher, ::CcxtOHLCVTickerVal)
    @warmup! w
    @ispending(w) && return nothing
    last_fetch = last(w.buffer)
    for (sym, ticker) in last_fetch.value
        _update_sym_ohlcv(w, ticker, last_fetch.time)
    end
end

function _start(w::Watcher, ::CcxtOHLCVTickerVal)
    _pending!(w)
    _chill!(w)
    empty!(_view(w))
end

function _load!(w::Watcher, ::CcxtOHLCVTickerVal, sym)
    df = w.view[sym]
    if nrow(df) < w.view.capacity
        from = _firstdate(df)
        to = _lastdate(df)
        candles = _fetch_candles(w, from, to)
        # to_idx = min(_date_to_idx(tf, from, to), nrow(candles)),
    end
end
