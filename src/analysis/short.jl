module Shorts

using Backtest.Analysis.MVP

function find(mrkts::AbstractDict; window=15)
    mvp = []
    for p in mrkts
        b, d = MVP.is_mvp(p; real=false)
        push!(mvp, (p[1], d))
    end
    # A good short should have high volume, (too) high price change, and dominating red candles.
    isshorter = (x, y) -> x[2].v > y[2].v && x[2].p > y[2].p && x[2].m < y[2].m
    sort!(mvp; lt=isshorter)
    mvp
end

end
