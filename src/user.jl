@doc "User functions."

using DataFrames
using DataFramesMeta
using Backtest.Misc: @margin!, @lev!

function kucoin_keys()
    cfg = Dict()
    open(joinpath(ENV["HOME"], "dev", "Backtest.jl", "cfg", "kucoin.json")) do f
        cfg = JSON.parse(f)
    end
        key = cfg["apiKey"]
    secret = cfg["secret"]
    password = cfg["password"]
    Dict("key" => key, "secret" => secret, "pass" => password)
end

function poloniex_update(;timeframe="15m", quot="USDT", min_vol=10e4)
    @exchange! poloniex
    fetch_pairs(poloniex, timeframe; qc=quot, zi, update=true)
    prl = get_pairlist(poloniex, quot, min_vol)
    load_pairs(zi, exc, prl, timeframe)
end

@doc "Given a price, output price at given ratios."
function price_ranges(price::Number; ranges=(0.8, 0.9, 0.95, 0.975, 1.025, 1.05, 1.1, 1.2))
    DataFrame(Dict(:price => price,
                   [Symbol(r) => price * r for r in ranges]...))
    # (price, -price * ranges[1], -price * ranges[2], -price * ranges[3], price * ranges[4])
end

function price_ranges(mrkts::AbstractDict; kwargs...)
    r = []
    for p in values(mrkts)
        push!(r, (p.name, price_ranges(p.data.close[end]; kwargs...)))
    end
    r
end

function price_ranges(pass::AbstractVector, mrkts::AbstractDict; kwargs...)
    r = []
    for (name, _) in pass
        push!(r, (name, price_ranges(mrkts[name].data.close[end]; kwargs...)))
    end
    r
end

function price_ranges(pair::AbstractString)
    tkrs = Backtest.Exchanges.@tickers true
    price_ranges(tkrs[pair]["last"])
end
# functinopranges(pair)
#     mrkts = esc(:mrkts)
#     tkrs = esc(:tickers)
#     quote
#         Backtest.Exchanges.@tickers true
#         price_ranges($tkrs[$pair]["last"])
#     end
# end


macro excfilter(exc_name)
    @eval begin
        using Backtest.Analysis
        explore!()
    end
    bt = Backtest
    quote
        local trg
        @info "timeframe: $(config.timeframe), window: $(config.window), quote: $(config.qc), min_vol: $(config.vol_min)"
	    @exchange! $exc_name
        pred = x -> $bt.Analysis.slopeangle(x; window=config.window)
        data = ($bt.Exchanges.get_pairlist($exc_name, config.qc) |> (x -> $bt.load_pairs($bt.Data.zi, $exc_name, x, config.timeframe)))
        flt = $bt.filter(pred, data, config.slope_min, config.slope_max)
        trg = DataFrame([(p[2].name, p[1], price_ranges(p[2].close[end])) for p in flt])
        results[lowercase($(exc_name).name)] = (;trg, flt, data)
        $(esc(:res)) = results[lowercase($(exc_name).name)]
        trg
    end
end

function vcons(args...; cargs=(), vargs=(), c_num=5)
    global an
    !isdefined(@__MODULE__, :an) && @eval begin
        using Backtest.Analysis;
        an.@pairtraits!
    end
    c = an.Considerations.considerations(args...; cargs...)
    v = an.Violations.violations(args...; vargs...)
    sk = length(args) > 1 ? :score_sum : :score
    v[!, sk] += @view(c[:, sk])
    sort!(v, sk)
    v
end

export @excfilter, price_ranges, @pranges, vcons
