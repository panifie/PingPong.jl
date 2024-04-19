import .LiveMode.Watchers.Fetch: fetch_ohlcv
import .Processing.Data: load_ohlcv
using .Exchanges: exchangeid

function fetch_ohlcv(
    s::Strategy;
    sandbox=false,
    tf=s.config.min_timeframe,
    pairs=(raw(a) for a in assets(s)),
    fetch_kwargs...,
)
    exc = getexchange!(exchangeid(s); sandbox)
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
