import Base: getproperty

using Reexport
@reexport using ExchangeTypes
using ExchangeTypes: OptionsDict, exc
using Ccxt: ccxt_exchange
using Python: Py, @py, pyconvert, pyfetch, PyDict, pydict
using Python.PythonCall: pyisnone
using Data: DataFrame
using JSON
using Serialization: deserialize, serialize
using TimeTicks
using Instruments
using Misc: DATA_PATH, dt, futures_exchange, exchange_keys
using Misc.TimeToLive
using Lang: @lget!

const exclock = ReentrantLock()
const tickers_cache = TTL{String,AbstractDict}(Minute(100))

@doc "Define an exchange variable set to its matching exchange instance."
macro exchange!(name)
    exc_var = esc(name)
    exc_str = lowercase(string(name))
    exc_istr = string(name)
    quote
        exc_sym = Symbol($exc_istr)
        $exc_var = if (exc.isset && lowercase(exc.name) === $exc_str)
            exc
        else
            (
                if hasproperty($(__module__), exc_sym)
                    getproperty($(__module__), exc_sym)
                else
                    Exchange(exc_sym)
                end
            )
        end
    end
end

function isfileyounger(f::AbstractString, p::Period)
    isfile(f) && dt(stat(f).mtime) < now() - p
end

@doc "Load exchange markets:
- `cache`: rely on storage cache
- `agemax`: max cache valid period [1 day]."
function loadmarkets!(exc; cache=true, agemax=Day(1))
    sbox = issandbox(exc) ? "_sandbox" : ""
    mkt = joinpath(DATA_PATH, exc.name, "markets$(sbox).jlz")
    empty!(exc.markets)
    function force_load()
        @debug "Loading markets from exchange and caching at $mkt."
        pyfetch(exc.loadMarkets, true)
        pd = pyconvert(OptionsDict, exc.py.markets)
        mkpath(dirname(mkt))
        serialize(mkt, PyDict(pd))
        merge!(exc.markets, pd)
    end
    if isfileyounger(mkt, agemax) && cache
        try
            @debug "Loading markets from cache."
            cached_dict = deserialize(mkt) # this should be a PyDict
            merge!(exc.markets, pyconvert(OptionsDict, cached_dict))
            exc.py.markets = pydict(cached_dict)
            exc.py.markets_by_id = exc.py.index_by(exc.markets, "id")
        catch error
            @warn error
            force_load()
        end
    else
        @debug cache ? "Force loading markets." : "Loading markets because cache is stale."
        force_load()
    end
    nothing
end

getexchange() = exc

@doc """getexchage!: ccxt exchange by symbol either from cache or anew.
It uses a WS instance if available, otherwise an async instance.

"""
function getexchange!(x::Symbol, args...; sandbox=true, markets=:yes, kwargs...)
    @lget!(
        sandbox ? sb_exchanges : exchanges,
        x,
        begin
            py = ccxt_exchange(x, args...; kwargs...)
            e = Exchange(py)
            sandbox && sandbox!(e, true; remove_keys=false)
            setexchange!(e; markets)
        end,
    )
end
function getexchange!(x::ExchangeID, args...; kwargs...)
    getexchange!(nameof(x), args...; kwargs...)
end

@doc "Instantiate an exchange struct. it sets:
- The matching ccxt class.
- Pre-emptively loads the markets.
- Sets the exchange timeframes.
- Sets exchange api keys.
"
function setexchange!(exc::Exchange, args...; markets::Symbol=:yes, kwargs...)
    empty!(exc.timeframes)
    tfkeys = if pyisnone(exc.py.timeframes)
        Set{String}()
    else
        pyconvert(Set{String}, exc.py.timeframes.keys())
    end
    isempty(tfkeys) || push!(exc.timeframes, tfkeys...)
    @debug "Loading Markets..."
    if markets in (:yes, :force)
        loadmarkets!(exc; cache=(markets != :force))
    end
    @debug "Loaded $(length(exc.markets))."
    precision = getfield(exc, :precision)
    precision[1] = (x -> ExcPrecisionMode(pyconvert(Int, x)))(exc.py.precisionMode)
    exckeys!(exc)
    exc
end

function setexchange!(x::Symbol, args...; kwargs...)
    exc = getexchange!(x, args...; kwargs...)
    setexchange!(exc, args...; kwargs...)
    globalexchange!(exc)
end

@doc "Check if exchange has tickers list."
@inline function hastickers(exc::Exchange)
    Bool(exc.has["fetchTickers"])
end

@doc "Fetch and cache tickers data."
macro tickers!(force=false)
    exc = esc(:exc)
    tickers = esc(:tickers)
    @assert force isa Bool
    quote
        local $tickers
        let nm = $(exc).name
            if $force || nm ∉ keys(tickers_cache)
                @assert hastickers($exc) "Exchange doesn't provide tickers list."
                tickers_cache[nm] =
                    $tickers = pyconvert(
                        Dict{String,Dict{String,Any}}, pyfetch($(exc).fetchTickers)
                    )
            else
                $tickers = tickers_cache[nm]
            end
        end
    end
end

@doc "Get the the markets of the `ccxt` instance, according to `min_volume` and `quot`e currency.
"
function filter_markets(exc; min_volume=10e4, quot="USDT", sep='/')
    @assert exc.has["fetchTickers"] "Exchange doesn't provide tickers list."
    markets = exc.markets
    @tickers!
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

@doc "Get price from ticker."
function tickerprice(tkr)
    @something tkr["average"] tkr["last"] tkr["bid"]
end

@doc "Get price ranges using tickers data from exchange."
function price_ranges(pair::AbstractString, args...; kwargs...)
    tkrs = @tickers! true
    price_ranges(tkrs[pair]["last"], args...; kwargs...)
end

@doc "Get quote volume from ticker."
function quotevol(tkr::AbstractDict)
    v1 = get(tkr, "quoteVolume", nothing)
    isnothing(v1) || return v1
    v2 = get(tkr, "baseVolume", nothing)
    isnothing(v2) || return v2 * tickerprice(tkr)
    0
end

@doc "Trims the settlement currency in futures. (`mkt` is a ccxt market.)"
@inline function spotsymbol(sym, mkt)
    if "quote" ∈ keys(mkt)
        "$(mkt["base"])/$(mkt["quote"])"
    else
        split(sym, ":")[1]
    end
end

issupported(tf::AbstractString, exc) = tf ∈ exc.timeframes
issupported(tf::TimeFrame, exc) = issupported(string(tf), exc)

@doc "Set exchange api keys."
function exckeys!(exc, key, secret, pass)
    # FIXME: ccxt key/secret naming is swapped for kucoin apparently
    if nameof(exc.id) ∈ (:kucoin, :kucoinfutures)
        (key, secret) = secret, key
    end
    exc.py.apiKey = key
    exc.py.secret = secret
    exc.py.password = pass
    nothing
end

function exckeys!(exc; sandbox=issandbox(exc))
    exc_keys = exchange_keys(nameof(exc.id); sandbox)
    # Check the exchange->futures mapping to re-use keys
    if isempty(exc_keys) && nameof(exc.id) ∈ values(futures_exchange)
        sym = Symbol(exc.id)
        id = argmax(x -> x[2] == sym, futures_exchange)
        merge!(exc_keys, exchange_keys(id.first; sandbox))
    end
    if !isempty(exc_keys)
        @debug "Setting exchange keys..."
        exckeys!(exc, (exc_keys[k] for k in ("apiKey", "secret", "password"))...)
    end
end

@doc "Enable sandbox mode for exchange. Should only be called on exchange construction."
function sandbox!(exc::Exchange=exc, flag=!issandbox(exc); remove_keys=true)
    exc.py.setSandboxMode(flag)
    if flag
        @assert issandbox(exc) "Exchange sandbox mode couldn't be enabled. (disable sandbox mode with `sandbox=false`)"
        remove_keys && exckeys!(exc, "", "", "")
    elseif isempty(exc.py.secret)
        exckeys!(exc)
    end
end
@doc "Check if exchange is in sandbox mode."
function issandbox(exc::Exchange=exc)
    "apiBackup" in exc.py.urls.keys()
end

@doc "Enable or disable rate limit."
ratelimit!(exc::Exchange=exc, flag=true) = exc.py.enableRateLimit = flag
@doc "Set exchange timouet"
timeout!(exc::Exchange=exc, v=5000) = exc.py.timeout = v
function check_timeout(exc::Exchange=exc, interval=Second(5))
    @assert Bool(Millisecond(interval).value <= exc.timeout) "Interval ($interval) shouldn't be lower than the exchange set timeout ($(exc.timeout))"
end

timestamp(exc::Exchange) = pyconvert(Int64, pyfetch(exc.py.fetchTime))
Base.time(exc::Exchange) = dt(pyconvert(Float64, pyfetch(exc.py.fetchTime)))

@doc "Returns the matching *futures* exchange instance, if it exists, or the input exchange otherwise."
function futures(exc::Exchange)
    futures_sym = get(futures_exchange, exc.id, exc.id)
    futures_sym != exc.id ? getexchange!(futures_sym) : exc
end

_checkfunc(exc, sym, out) = Bool(exc.has.get(string(sym), false)) || push!(out, sym)
@doc "Checks if the python exchange instance supports all the calls required by PingPong."
function check(exc::Py)
    missing_funcs = Set()
    _checkfunc(exc, :fetchOHLCV, missing_funcs)
    _checkfunc(exc, :fetchBalance, missing_funcs)
    _checkfunc(exc, :fetchPositions, missing_funcs)
    _checkfunc(exc, :fetchPosition, missing_funcs)
    _checkfunc(exc, :createOrder, missing_funcs)
    _checkfunc(exc, :cancelOrder, missing_funcs)
    _checkfunc(exc, :fetchMarkets, missing_funcs)
    _checkfunc(exc, :fetchMarket, missing_funcs)
    _checkfunc(exc, :watchTrades, missing_funcs)
    _checkfunc(exc, :watchOrders, missing_funcs)
    _checkfunc(exc, :fetchLeverageTiers, missing_funcs)
    _checkfunc(exc, :fetchTickers, missing_funcs)
    _checkfunc(exc, :fetchOrderBook, missing_funcs)
    _checkfunc(exc, :fetchOrders, missing_funcs)
    _checkfunc(exc, :fetchCurrencies, missing_funcs)
    nmis = length(missing_funcs)
    if nmis == 0
        println("$(exc.name) supports all functions!")
    else
        println("$nmis functions are not supported by $(exc.name)")
        for f in missing_funcs
            println(stdout, string(f))
        end
        flush(stdout)
    end
    # _checkfunc(exc, :cancelOrders, missing_funcs)
end
