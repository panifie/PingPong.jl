import .LiveMode.Watchers.Fetch: fetch_ohlcv, propagate_ohlcv!, update_ohlcv!
import .Processing.Data: load_ohlcv
using .Exchanges: exchangeid, account
using .Exchanges.ExchangeTypes: params

function fetch_ohlcv(
    s::Strategy;
    sandbox=false,
    tf=s.config.min_timeframe,
    pairs=(raw(a) for a in assets(s)),
    fetch_kwargs...,
)
    exc = getexchange!(exchangeid(s), params(exc); sandbox, account=account(exc))
    tf_str = string(tf)
    pairs_str = collect(pairs)
    fetch_ohlcv(exc, tf_str, pairs_str; fetch_kwargs...)
end

function load_ohlcv(
    s::Strategy; tf=s.config.min_timeframe, pairs=(raw(a) for a in assets(s))
)
    exc = exchange(s)
    tf_str = string(tf)
    pairs_str = collect(pairs)
    Data.load_ohlcv(exc, pairs_str, tf_str)
    fill!(s)
end

function fetch_ohlcv!(s::Strategy)
    @sync for ai in s.universe
        @async begin
            exc = exchange(ai)
            sym = raw(ai)
            v = fetch_ohlcv(exc, s.timeframe, sym, from=-2000)
            ai.data[s.timeframe] = v[sym].data
            propagate_ohlcv!(ai.data, raw(ai), exc)
        end
    end
end

function update_ohlcv!(s::Strategy; kwargs...)
    tf = s.timeframe
    @sync for ai in s.universe
        @async begin
            exc = exchange(ai)
            sym = raw(ai)
            update_ohlcv!(ohlcv(ai, tf), sym, exc, tf; kwargs...)
            propagate_ohlcv!(ai.data, sym, exc)
        end
    end
end
