using Exchanges
using Python
using Data: Candle, save_ohlcv, zilmdb, DataFramesMeta, OHLCV_COLUMNS
using .DataFramesMeta
using Processing: cleanup_ohlcv_data, iscomplete, isincomplete
using Processing.TradesOHLCV
using TimeTicks
using Lang: @lget!
using Watchers: BufferEntry
using Base.Iterators: drop, reverse

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

function Base.convert(::Type{Candle}, py::PyList)
    Candle(dt(pyconvert(Float64, py[1])), (pyconvert(Float64, py[n]) for n in 2:6)...)
end
Python.pyconvert(::Type{DateTime}, py::Py) = dt(pyconvert(Int, py))
Python.pyconvert(::Type{TradeSide}, py::Py) = TradeSide(py)
Python.pyconvert(::Type{TradeRole}, py::Py) = TradeRole(py)

trades_fromdict(v, ::Val{CcxtTrade}) = @fromdict(CcxtTrade, String, v)

@doc """ Create a `Watcher` instance that tracks ohlcv for an exchange (ccxt).

"""
function ccxt_ohlcv_watcher(
    exc::Exchange, syms::AbstractVector=[]; timeframe::TimeFrame, interval=Second(5)
)
    tfunc = choosefunc(exc, "Trades", syms;)
    function fetcher(w)
        data = tfunc()
        # out = w.attrs[:trades]
        out = Dict{String,Vector{CcxtTrade}}()
        for (sym, trades) in data
            out[sym] = [
                fromdict(CcxtTrade, String, py, pyconvert, pyconvert) for py in trades
            ]
        end
        out
        # _trades_to_ohlcv()
        # push!(w.attrs[:ohlcv_ticks], result)
        # _merge_data(w.attrs[:ohlcv_ticks], timeframe)
    end
    return fetcher(nothing)
    flusher(w) = candle_flusher(w.buffer, exc, timeframe)
    starter(w) = begin
        w.attrs[:trades] = Dict{String,Vector{CcxtTrade}}
        candle_starter(exc, timeframe, syms)
    end
    key = "ccxt_$(exc.name)_ohlcv_$(join(syms, "_"))"
    watcher_type = Dict{String,Vector{Candle}}
    watcher(watcher_type, key, fetcher; flusher, starter=false, interval)
end

function ccxt_ohlcv_watcher(exc::Exchange, syms...; kwargs...)
    ccxt_ohlcv_watcher(exc, [syms...]; kwargs...)
end
function ccxt_ohlcv_watcher(syms::Vararg{T}; kwargs...) where {T}
    ccxt_ohlcv_watcher(exc::Exchange, [syms...]; kwargs...)
end

function candle_flusher(buf::AbstractVector, exc, tf)
    # save after cleaning data
    # zi = zilmdb()
    # exn = exc.name
    # timeframe = string(tf)
    # dosave((k, val)) = save_ohlcv(zi, exn, k, timeframe, cleanup_ohlcv_data(val, timeframe))
    # foreach(dosave, data)
end

function candle_starter(exc, tf, syms::AbstractVector)
    load_ohlcv(zilmdb(), exc, syms, string(tf); raw=true)
end

