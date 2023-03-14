
# LIX formula
# values between ~5..~10 higher is more liquid
function liquidity(volume, close, high, low)
    return log10((volume * close) / (high - low))
end

function liqat(idx::Integer, volume::V, close::V, high::V, low::V) where {V<:AbstractVector}
    liquidity(volume[idx], close[idx], high[idx], low[idx])
end

function illiqat(idx::Integer, close::T, volume::T; window=120) where {T<:AbstractVector}
    start = idx - window + 1
    start > 0 || return missing
    close_win = view(close, start:idx)
    # volume in quote currency
    volume_at = volume[idx] * close[idx]
    prev_close = mt.lagged(close, window; idx)
    returns_volume_ratio = abs.(((close_win .- prev_close)) ./ volume_at)
    return sum(returns_volume_ratio) / window * 1e6
end

