const exc = Ref(PyObject(nothing))

macro exchange!(name)
    exc_var = esc(name)
    exc_str = lowercase(string(name))
    exc_istr = string(name)
    quote
        exc_sym = Symbol($exc_istr)
        $exc_var = (py"$(exc[]) is not None" && lowercase(exc[].name) === $exc_str) ?
            exc[] : (hasproperty($(__module__), exc_sym) ? 
            getproperty($(__module__), exc_sym) : getexchange(exc_sym))
    end
end

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

function getexchange(name::Symbol, params=nothing)
    init_ccxt()
    exc_cls = getproperty(ccxt[], name)
    exc = isnothing(params) ? exc_cls() : exc_cls(params)
    exc.loadMarkets()
    exc
end

function setexchange!(name, args...; kwargs...)
    exc[] = getexchange(name, args...; kwargs...)
    keysym = Symbol("$(name)_keys")
    if hasproperty(@__MODULE__, keysym)
        kf = getproperty(@__MODULE__, keysym)
        @assert kf isa Function "Can't set exchange keys."
        exckeys!(exc[], values(kf())...)
    end
end

macro tickers()
    exc = esc(:exc)
    tickers = esc(:tickers)
    quote
        @assert $(exc).has["fetchTickers"] "Exchange doesn't provide tickers list."
        $tickers = $(exc).fetchTickers()
    end
end

function get_markets(exc; min_volume=10e4, quot="USDT", sep='/')
    @assert exc.has["fetchTickers"] "Exchange doesn't provide tickers list."
    markets = exc.markets
    tickers = exc.fetchTickers()
    f_markets = Dict()
    for (p, info) in markets
        _, pquot = split(p, sep)
        # NOTE: split returns a substring
        if pquot == quot && tickers[p]["quoteVolume"] > min_volume
            f_markets[p] = info
        end
    end
    f_markets
end

function get_pairlist(quot::AbstractString="", min_vol::AbstractFloat=10e4)
    get_pairlist(exc[], quot, min_vol)
end

function get_pairlist(exc, quot::AbstractString, min_vol::AbstractFloat=10e4)
    @tickers
    pairlist = []
    local push_fun
    if isempty(quot)
        push_fun = (p, k, v) -> push!(p, (k, v))
    else
        push_fun = (p, k, v) -> v["quoteId"] === quot && push!(p, (k, v))
    end
    for (k, v) in exc.markets
        if is_leveraged_pair(k) || tickers[k]["quoteVolume"] <= min_vol
            continue
        else
            push_fun(pairlist, k, v)
        end
    end
    isempty(quot) && return pairlist
    Dict(pairlist)
end

function is_timeframe_supported(timeframe, exc)
    timeframe ∈ keys(exc.timeframes)
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

function poloniex_update(;timeframe="15m", quot="USDT", min_vol=10e4)
    @exchange! poloniex
    fetch_pairs(poloniex, timeframe; qc=quot, zi, update=true)
    prl = get_pairlist(poloniex, quot, min_vol)
    load_pairs(zi, exc, prl, timeframe)
end

const options = Dict{String, Any}()

function resetoptions!()
    empty!(options)
    options["window"] = 7
    options["timeframe"] = "1d"
    options["quote"] = "USDT"
    options["min_vol"] = 10e4
    options["min_slope"] = 0.
    options["max_slope"] = 90.
end
resetoptions!()

macro ifundef(name, val, mod=__module__)
    name_var = esc(name)
    name_sym = esc(:(Symbol($(string(name)))))
    quote
        if isdefined($mod, $name_sym)
            $name_var = getproperty($mod, $name_sym)
        else
            $name_var = $val
        end
    end
end

const results = Dict{String, Any}()

macro excfilter(exc_name)
    bt = @__MODULE__
    quote
        local trg
        @info "timeframe: $(options["timeframe"]), window: $(options["window"]), quote: $(options["quote"]), min_vol: $(options["min_vol"])"
	    @exchange! $exc_name
        $(bt).@ifundef data (get_pairlist(options["quote"]) |> (x -> load_pairs(zi, $exc_name, x, options["timeframe"])))
        flt = filter(x -> $(bt).slopeangle(x; window=options["window"]), data, options["min_slope"], options["max_slope"])
        trg = [p[2].name for p in flt]
        results[lowercase($(exc_name).name)] = (;trg, flt, data)
    end
end

export @excfilter, results, setexchange!
