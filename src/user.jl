@doc "User functions."

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

macro excfilter(exc_name)
    @eval using Backtest.Analysis
    bt = Backtest
    quote
        local trg
        @info "timeframe: $(config.timeframe), window: $(config.window), quote: $(config.qc), min_vol: $(config.vol_min)"
	    @exchange! $exc_name
        data = ($bt.Exchanges.get_pairlist($exc_name, config.qc) |> (x -> $bt.load_pairs($bt.Data.zi, $exc_name, x, config.timeframe)))
        flt = $bt.filter(x -> $bt.Analysis.slopeangle(x; window=config.window), data, config.slope_min, config.slope_max)
        trg = [p[2].name for p in flt]
        results[lowercase($(exc_name).name)] = (;trg, flt, data)
        $(esc(:res)) = results[lowercase($(exc_name).name)]
        trg
    end
end

export @excfilter
