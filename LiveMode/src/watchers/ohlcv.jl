using Watchers.WatchersImpls: ccxt_ohlcv_watcher, ccxt_ohlcv_tickers_watcher
using .st: logpath

@doc "Real time strategy."
const RTStrategy = Strategy{<:Union{Paper,Live}}

propagate_loop(::RTStrategy, ai, w::Watcher) = begin
    data = ai.data
    while true
        safewait(w.beacon.process)
        isstopped(w) && break
        try
            propagate_ohlcv!(data)
        catch
        end
    end
end

propagate_loop(s::RTStrategy, w::Watcher) = begin
    while true
        safewait(w.beacon.process)
        isstopped(w) && break
        for ai in s.universe
            try
                propagate_ohlcv!(data)
            catch
            end
        end
    end
end

function isohlcv_bytrades(s::Strategy)
    length(s.universe) < 3 || attr(s, :live_ohlcv_use_trades, false)
end

function ohlcv_watchers(s::RTStrategy)
    if isohlcv_bytrades(s)
        @lget! s.attrs :live_ohlcv_watchers Dict{AssetInstance,Watcher}()
    else
        attr(s, :live_ohlcv_watcher, nothing)
    end
end

function watch_ohlcv!(s::RTStrategy, kwargs...)
    exc = exchange(s)
    ow = ohlcv_watchers(s)
    if isohlcv_bytrades(s)
        function start_watcher(ai)
            sym = raw(ai)
            default_view = @lget! ai.data s.timeframe Data.empty_ohlcv()
            w = ow[ai] = ccxt_ohlcv_watcher(exc, sym; s.timeframe, default_view)
            Watchers.load!(w)
            w[:process_task] = @async propagate_loop(s, ai, w)
            start!(w)
        end

        if length(s.universe) == 1
            start_watcher(first(s.universe))
        else
            @sync for ai in s.universe
                @async start_watcher(ai)
            end
        end
    else
        default_view = Dict{String,DataFrame}(
            raw(ai) => @lget!(ai.data, s.timeframe, empty_ohlcv()) for ai in s.universe
        )
        s[:live_ohlcv_watcher] =
            w = ccxt_ohlcv_tickers_watcher(
                exc;
                timeframe=s.timeframe,
                syms=(raw(ai) for ai in s.universe),
                flush=false,
                logfile=logpath(s; name="tickers_watcher_$(nameof(s))"),
                view_capacity=attr(s, :live_view_capacity, 1000),
                default_view,
            )
        w[:quiet] = true
        w[:resync_noncontig] = true
        wv = w.view
        @sync for ai in s.universe
            sym = raw(ai)
            @assert wv[sym] == ai.data[s.timeframe]
            @async Watchers.load!(w, sym)
        end
        w[:process_task] = @async propagate_loop(s, w)
        start!(w)
    end
end
ohlcv_watcher(s::RTStrategy) = attr(s, :ohlcv_watcher, nothing)

function stop_watch_ohlcv!(s::RTStrategy)
    w = ohlcv_watchers(s)
    isnothing(w) && return nothing
    if w isa Watcher
        stop!(w)
    elseif valtype(w) <: Watcher
        for ai_w in values(w)
            stop!(ai_w)
        end
    else
        error()
    end
end
