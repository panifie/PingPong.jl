import Base: getproperty
import Serialization: deserialize, serialize
using Serialization: AbstractSerializer, serialize_type

using Reexport
@reexport using ExchangeTypes
using ExchangeTypes: OptionsDict, exc, CcxtExchange
using Ccxt: Ccxt, ccxt_exchange, choosefunc
using Python: Py, pyconvert, pyfetch, PyDict, PyList, pydict, pyimport, @pystr
using Python.PythonCall: pyisnone
using Data: Data, DataFrame
using Pbar.Term: RGB, tprint
using JSON
using TimeTicks
using Instruments
using Misc: DATA_PATH, dt, futures_exchange, exchange_keys, Misc, NoMargin, LittleDict
using Misc.OrderedCollections: OrderedSet
using Misc.TimeToLive
using Lang: @lget!

const exclock = ReentrantLock()
const tickers_cache = safettl(Tuple{String,Symbol}, Dict, Minute(100))

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

function _elconvert(v)
    if v isa PyDict
        ans = pyconvert(Dict{Any,Any}, v)
        for (k, v) in ans
            ans[k] = _elconvert(v)
        end
        ans
    elseif v isa PyList
        ans = pyconvert(Vector{Any}, v)
        for i in eachindex(ans)
            ans[i] = _elconvert(ans[i])
        end
        ans
    elseif v isa Py
        pyconvert(Any, v)
    else
        v
    end
end

function jlpyconvert(py)
    d = pyconvert(Dict{Any,Any}, py)
    for (k, v) in d
        d[k] = _elconvert(v)
    end
    d
end

@doc "Load exchange markets:
- `cache`: rely on storage cache
- `agemax`: max cache valid period [1 day]."
function loadmarkets!(exc; cache=true, agemax=Day(1))
    sbox = issandbox(exc) ? "_sandbox" : ""
    mkt = joinpath(DATA_PATH, exc.name, "markets$(sbox).jlz")
    empty!(exc.markets)
    pyjson = pyimport("json")
    function force_load()
        try
            @debug "Loading markets from exchange and caching at $mkt."
            pyfetch(exc.loadMarkets, true)
            mkpath(dirname(mkt))
            cache = Dict{Symbol,String}()
            cache[:markets] = string(pyjson.dumps(exc.py.markets))
            cache[:markets_by_id] = string(pyjson.dumps(exc.py.markets_by_id))
            cache[:currencies] = string(pyjson.dumps(exc.py.currencies))
            cache[:symbols] = string(pyjson.dumps(exc.py.symbols))
            write(mkt, json(cache))
            merge!(exc.markets, jlpyconvert(exc.py.markets))
        catch e
            @warn e
        end
    end
    if isfileyounger(mkt, agemax) && cache
        try
            @debug "Loading markets from cache."
            cache = JSON.parse(read(mkt, String)) # this should be a PyDict
            merge!(exc.markets, JSON.parse(cache["markets"]))
            exc.py.markets = pyjson.loads(cache["markets"])
            exc.py.markets_by_id = pyjson.loads(cache["markets_by_id"])
            exc.py.symbols = pyjson.loads(cache["symbols"])
            exc.py.currencies = pyjson.loads(cache["currencies"])
        catch error
            @warn error
            Base.show_backtrace(stderr, catch_backtrace())
            force_load()
        end
    else
        @debug cache ? "Force loading markets." : "Loading markets because cache is stale."
        force_load()
    end
    types = exc.types
    for m in values(exc.markets)
        push!(types, Symbol(m["type"]))
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
        OrderedSet{String}()
    else
        tf_strings = [v |> string for v in exc.py.timeframes.keys()]
        OrderedSet{String}(string(v) for v in sort!(tf_strings; by=t -> timeframe(t)))
    end
    isempty(tfkeys) || push!(exc.timeframes, tfkeys...)
    @debug "Loading Markets..."
    if markets in (:yes, :force)
        loadmarkets!(exc; cache=(markets != :force))
    end
    @debug "Loaded $(length(exc.markets))."
    setflags!(exc)
    precision = getfield(exc, :precision)
    precision[1] = (x -> ExcPrecisionMode(pyconvert(Int, x)))(exc.py.precisionMode)
    fees = getfield(exc, :fees)
    for (k, v) in exc.py.fees["trading"].items()
        fees[Symbol(k)] = let c = pyconvert(Any, v)
            if c isa String
                Symbol(c)
            elseif c isa AbstractFloat
                convert(DFT, c)
            elseif c isa AbstractDict # tiers
                LittleDict{Symbol,Vector{Vector{DFT}}}(Symbol(k) => v for (k, v) in c)
            else
                c
            end
        end
    end

    exckeys!(exc)
    exc
end

function setexchange!(x::Symbol, args...; kwargs...)
    exc = getexchange!(x, args...; kwargs...)
    setexchange!(exc, args...; kwargs...)
    globalexchange!(exc)
end

function setflags!(exc::CcxtExchange)
    has = exc.has
    for (k, v) in exc.py.has.items()
        has[Symbol(k)] = Bool(v)
    end
end
setflags!(args...; kwargs...) = nothing

function serialize(s::AbstractSerializer, exc::E) where {E<:Exchange}
    serialize_type(s, E, false)
    serialize(s, exc.id)
end

deserialize(s::AbstractSerializer, ::Type{<:Exchange}) = begin
    deserialize(s) |> getexchange!
end

@doc "Check if exchange has tickers list."
@inline function hastickers(exc::Exchange)
    has(exc, :watchTickers) || has(exc, :fetchTickers)
end

MARKET_TYPES = (:spot, :future, :swap, :option, :margin, :delivery)

@doc "Any of $MARKET_TYPES"
function markettype(exc)
    types = exc.types
    if Misc.config.margin == NoMargin()
        if :spot ∈ types
            :spot
        else
            last(types)
        end
    else
        if :linear ∈ types
            :linear
        elseif :swap ∈ types
            :swap
        elseif :future ∈ types
            :future
        else
            last(types)
        end
    end
end

@doc "Fetch and cache tickers data."
macro tickers!(type=nothing, force=false)
    exc = esc(:exc)
    tickers = esc(:tickers)
    type = type ∈ MARKET_TYPES ? QuoteNode(type) : esc(type)
    quote
        local $tickers
        let tp = @something($type, markettype($exc)), nm = $(exc).name, k = (nm, tp)
            if $force || k ∉ keys(tickers_cache)
                @assert hastickers($exc) "Exchange doesn't provide tickers list."
                tickers_cache[k] = let f = first($(exc), :watchTickers, :fetchTickers)
                    $tickers = pyconvert(
                        Dict{String,Dict{String,Any}},
                        let v = pyfetch(f; params=LittleDict("type" => @pystr(tp)))
                            if v isa PyException && Bool(f == $exc.watchTickers)
                                pyfetch(
                                    $(exc).fetchTickers;
                                    params=LittleDict("type" => @pystr(tp)),
                                )
                            elseif v isa Exception
                                throw(v)
                            else
                                v
                            end
                        end,
                    )
                end
            else
                $tickers = tickers_cache[k]
            end
        end
    end
end

@doc "Get the the markets of the `ccxt` instance, according to `min_volume` and `quot`e currency.
"
function filter_markets(exc; min_volume=10e4, quot="USDT", sep='/')
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
function price_ranges(pair::AbstractString, args...; exc=exc, kwargs...)
    type = markettype(exc)
    tkrs = @tickers! type true
    price_ranges(tkrs[pair]["last"], args...; kwargs...)
end

@doc "Get quote volume from ticker."
function quotevol(tkr::AbstractDict)
    v1 = get(tkr, "quoteVolume", nothing)
    isnothing(v1) || return v1
    v2 = get(tkr, "baseVolume", nothing)
    # NOTE: this is not the actual quote volume, since vol from trades
    # have different prices
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

@doc "Check if market has percentage or absolute fees."
function ispercentage(mkt)
    something(get(mkt, "percentage", true), true)
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

const CCXT_REQUIRED_LOCAL4 = (
    (nothing, :fetchOHLCV),
    (:fetchBalance,),
    (:fetchPosition, :fetchPositions),
    (:cancelOrder, :cancelOrders, :cancelAllOrders),
    (:createOrder, :createPostOnlyOrder, :createReduceOnlyOrder),
    (:fetchMarkets,),
    (:fetchTrades, :watchTrades),
    (:fetchOrder, :fetchOrders, :watchOrders),
    (nothing, :fetchLeverageTiers),
    (:fetchTickers, :fetchTicker, :watchTickers, :watchTicker),
    (:fetchOrderBooks, :fetchOrderBook, :watchOrderBooks, :watchOrderBook),
    (nothing, :fetchCurrencies),
)
function _print_missing(exc, missing_funcs, func_type)
    nmis = length(missing_funcs)
    if nmis == 0
        tprint("{cyan}$(exc.name){/cyan} supports {bold}all{/bold} $func_type functions!")
    else
        tprint(
            "{bold}$nmis{/bold} functions are {bold}not{/bold} supported by {cyan}$(exc.name){/cyan}\n",
        )
        for f in missing_funcs
            tprint(stdout, string("{yellow}", f, "{/yellow}\n"))
        end
        flush(stdout)
    end
end
function _checkfunc(exc, funcs, missing_funcs, total)
    any = isnothing(first(funcs))
    for func in funcs
        isnothing(func) && continue
        if has(exc, func)
            any = true
            total[] += 1
        else
            push!(missing_funcs, func)
        end
    end
    any
end
function _print_total(total, max_total)
    red = RGB(1, 0, 0) # Red color
    green = RGB(0, 1, 0) # Green color
    x = total / max_total
    color = interpolate_color(green, red, x)
    tprint(
        string("\n{bold}Total score:{/bold} {$color}$total/$max_total{/$color}\n");
        highlight=false,
    )
end

function _print_blockers(exc, blockers, func_type)
    nblocks = length(blockers)
    if nblocks == 0
        tprint("\n{cyan}$(exc.name){/cyan} supports {bold}$func_type{/bold} functionality!")
    else
        tprint(
            "\nThere are {bold}$nblocks{/bold} blockers for {bold}$func_type{/bold} functionality for {cyan}$(exc.name){/cyan}\n",
        )
        for funcs in blockers
            tprint(
                stdout,
                string(
                    "\n {white}{bold}-{/bold}{/white} ",
                    (string("{red}", f, "{/red} ") for f in funcs)...,
                ),
            )
        end
        tprint("\n")
        flush(stdout)
    end
end

# Define a function that interpolates between two colors
function interpolate_color(c1, c2, x)
    # c1 and c2 are Color objects, x is a value between 0 and 1
    # Return a Color object that is a linear interpolation of c1 and c2
    v = clamp(x, 0.01, 0.99)
    r = c1.r + (c2.r - c1.r) * v
    g = c1.g + (c2.g - c1.g) * v
    b = c1.b + (c2.b - c1.b) * v
    return RGB(r, g, b) # Return the interpolated color
end

const CCXT_REQUIRED_LIVE2 = ((:setMarginMode,), (:setPositionMode,))

@doc "Checks if the python exchange instance supports all the calls required by PingPong."
function check(exc::Exchange, type=:basic)
    missing_funcs = Set()
    blockers = Set()
    total = Ref(0)
    max_total = 0
    allfuncs = if type == :basic
        CCXT_REQUIRED_LOCAL4
    elseif type == :live
        CCXT_REQUIRED_LIVE2
    else
        error()
    end
    for funcs in allfuncs
        max_total += length(funcs) - ifelse(isnothing(first(funcs)), 1, 0)
        any = _checkfunc(exc, funcs, missing_funcs, total)
        any || push!(blockers, funcs)
    end
    _print_missing(exc, missing_funcs, type)
    _print_blockers(exc, blockers, type)
    _print_total(total[], max_total)
end
