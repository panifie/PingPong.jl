function init_ccxt()
    if !ccxt_loaded[]
        try
            ccxt[] = pyimport("ccxt")
            ccxt_loaded[] = true
        catch
            Conda.pip("install", "ccxt")
            ccxt[] = pyimport("ccxt")
        end
    end
end

function get_exchange(name::Symbol, params=nothing)
    init_ccxt()
    exc_cls = getproperty(ccxt[], name)
    exc = isnothing(params) ? exc_cls() : exc_cls(params)
    exc.loadMarkets()
    exc
end

function get_markets(exc ;quot="USDT", sep='/')
    markets = exc.markets
    f_markets = Dict()
    for (p, info) in markets
        _, pquot = split(p, sep)
        # NOTE: split returns a substring
        pquot == quot && begin f_markets[p] = info end
    end
    f_markets
end

function exckeys!(exc, key, secret, pass)
    name = uppercase(exc.name)
    exc.apiKey = key
        exc.secret = secret
        exc.password = pass
    nothing
end

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
