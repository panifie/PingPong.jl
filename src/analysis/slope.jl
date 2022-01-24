function slopefilter(timeframe="1d"; qc="USDT", minv=10., maxv=90., window=20)
    @assert exc.issset "Global exchange variable is not set."
    pairs = get_pairlist(exc, qc)
    pairs = load_pairs(zi, exc, pairs, timeframe)
    pred = x -> slopeangle(x; window)
    filter(pred, pairs, minv, maxv)
end

function slopefilter(pairs::AbstractDict; minv=10., maxv=90., window=20)
    pred = x -> slopeangle(x; window)
    filter(pred, pairs, minv, maxv)
end

function slopeangle(df; window=10)
    size(df, 1) > window || return false
    slope = ind.mlr_slope(@view(df.close[end-window:end]); n=window)[end]
    atan(slope) * (180 / π)
end
