import Base: getproperty
import Serialization: deserialize, serialize
using Serialization: AbstractSerializer, serialize_type

using Reexport
using Pbar.Term: RGB, tprint
using ExchangeTypes
using Data: Data, DataFrame
@reexport using ExchangeTypes
using ExchangeTypes: OptionsDict, exc, CcxtExchange, Python
using ExchangeTypes.Ccxt: Ccxt, ccxt_exchange, choosefunc
import .Ccxt: issupported
using .Python: pyfetch, @pystr
using .Python: Py, pyconvert, PyDict, PyList, pydict, pyimport, @pyconst
using .Python: pyisnone, pyisnull, pyisbool, pyisTrue, pyisstr
using JSON
using Instruments
using Instruments: Misc
using .Misc:
    DATA_PATH, dt, futures_exchange, exchange_keys, Misc, NoMargin, LittleDict, isoffline
using .Misc.OrderedCollections: OrderedSet
using .Misc.TimeToLive
using .TimeToLive: ConcurrentDict
using .Misc.TimeTicks
using .Misc.Lang: @lget!
using .Misc.DocStringExtensions

# exchangeid, markettype
@doc "The cache for tickers which lasts for 100 minutes by exchange pair."
const TICKERS_CACHE100 = safettl(Tuple{Symbol,Symbol}, Dict, Minute(100))
const TICKERS_CACHE10 = safettl(Tuple{Symbol,Symbol}, Dict, Second(10))
@doc "Lock held when fetching tickers (list)."
const TICKERSLIST_LOCK_DICT = ConcurrentDict(Dict{Tuple{Symbol,Symbol},ReentrantLock}())

@doc "Define an exchange variable set to its matching exchange instance.

$(TYPEDSIGNATURES)
"
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

@doc """Checks if a file is younger than a specified period.

$(TYPEDSIGNATURES)

- `f`: a string that represents the path to the file.
- `p`: a Period object that represents the time period.

"""
function isfileyounger(f::AbstractString, p::Period)
    isfile(f) && dt(stat(f).mtime) < now() - p
end

function _elconvert(v)
    # If input is a Python dict or list, convert to Julia and recursively handle inner elements
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
        # If input is a generic Python object, convert it to Julia object
    elseif v isa Py
        pyconvert(Any, v)
        # If input is not a Python object, return it as is
    else
        v
    end
end

@doc """Convert a Python object into a Julia object.

$(TYPEDSIGNATURES)
"""
function jlpyconvert(py)
    (pyisnull(py) || pyisnone(py)) && return nothing
    d = pyconvert(Dict{Any,Any}, py)
    for (k, v) in d
        d[k] = _elconvert(v)
    end
    d
end

@doc """Load exchange markets.

$(TYPEDSIGNATURES)

- `exc`: an Exchange object that represents the exchange to load markets from.
- `cache` (optional, default is true): a boolean that indicates whether to rely on storage cache.
- `agemax` (optional, default is Day(1)): a Period object that represents the maximum cache valid period.

"""
function loadmarkets!(exc; cache=true, agemax=Day(1))
    sbox = issandbox(exc) ? "_sandbox" : ""
    mkt = joinpath(DATA_PATH, exc.name, "markets$(sbox).jlz")
    empty!(exc.markets)
    pyjson = pyimport("json")
    function force_load()
        isoffline() && return nothing
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
            conv = jlpyconvert(exc.py.markets)
            if conv isa AbstractDict
                merge!(exc.markets, conv)
            end
        catch e
            @warn e
        end
    end
    if (isfileyounger(mkt, agemax) && cache) || isoffline()
        try
            @debug "Loading markets from cache."
            cache = JSON.parse(read(mkt, String)) # this should be a PyDict
            merge!(exc.markets, JSON.parse(cache["markets"]))
            exc.py.markets = pyjson.loads(cache["markets"])
            exc.py.markets_by_id = pyjson.loads(cache["markets_by_id"])
            exc.py.symbols = pyjson.loads(cache["symbols"])
            exc.py.currencies = pyjson.loads(cache["currencies"])
        catch error
            @debug error bt = Base.show_backtrace(stderr, catch_backtrace())
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

@doc "Get the global exchange."
getexchange() = exc

using .Misc.Lang: @caller
@doc """getexchage!: ccxt exchange by symbol either from cache or anew.

$(TYPEDSIGNATURES)
It uses a WS instance if available, otherwise an async instance.
"""
function getexchange!(
    x::Symbol, params=PyDict("newUpdates" => true); sandbox=true, markets=:yes, kwargs...
)
    @debug "exchanges: getexchange!" x @caller
    @lget!(
        sandbox ? sb_exchanges : exchanges,
        x,
        if x == Symbol() || x == Symbol("")
            Exchange(pybuiltins.None)
        else
            py = ccxt_exchange(x, params; kwargs...)
            e = Exchange(py)
            sandbox && sandbox!(e; flag=true, remove_keys=false)
            setexchange!(e; markets)
        end,
    )
end
function getexchange!(x::Union{ExchangeID,Type{<:ExchangeID}}, args...; kwargs...)
    getexchange!(Symbol(x), args...; kwargs...)
end

@doc """Initializes an exchange struct.

$(TYPEDSIGNATURES)

- `exc`: an Exchange object to be set.
- `args...`: a variable number of arguments to pass to the exchange setup.
- `markets` (optional, default is `:yes`): a symbol that indicates whether to load markets during setup.
- `kwargs...`: a variable number of keyword arguments to pass to the exchange setup.

Configures the matching ccxt class, optionally loads the markets, sets the exchange timeframes, and sets the exchange API keys.

"""
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
    precision[] = (x -> ExcPrecisionMode(pyconvert(Int, x)))(exc.py.precisionMode)
    fees = getfield(exc, :fees)
    for (k, v) in exc.py.fees["trading"]
        _setfees!(fees, k, v)
    end
    exckeys!(exc)
    exc
end

@doc """Ccxt fees can have different forms."""
function _setfees!(fees, k, v)
    fees[Symbol(k)] = if pyisbool(v)
        pyisTrue(v)
    elseif pyisstr(v)
        Symbol(v)
    elseif pyisfloat(v)
        pyconvert(DFT, v)
    elseif pyisdict(v) # tiers
        LittleDict{Symbol,Vector{Vector{DFT}}}(Symbol(k) => v for (k, v) in v)
    else
        # c = pyconvert(Any, v)
        # fees[Symbol(k)] = if c isa String
        #     Symbol(c)
        # elseif c isa AbstractFloat
        #     pyconvert(DFT, c)
        # elseif c isa AbstractDict # tiers

        # else
        #     c
        # end
    end
end

function setexchange!(x::Symbol, args...; kwargs...)
    exc = getexchange!(x, args...; kwargs...)
    setexchange!(exc, args...; kwargs...)
    globalexchange!(exc)
end

@doc "Set the ccxt exchange `has` flags."
function setflags!(exc::CcxtExchange)
    has = exc.has
    for (k, v) in exc.py.has.items()
        has[Symbol(k)] = Bool(v)
    end
end
setflags!(args...; kwargs...) = nothing

@doc "When serializing an exchange, serialize only its id."
function serialize(s::AbstractSerializer, exc::E) where {E<:Exchange}
    serialize_type(s, E, false)
    serialize(s, (exc.id, issandbox(exc)))
end

@doc "When deserializing an exchange, use the deserialized id to construct the exchange."
deserialize(s::AbstractSerializer, ::Type{<:Exchange}) = begin
    id, sandbox = deserialize(s)
    getexchange!(id; sandbox)
end

@doc "Check if exchange has tickers list.

$(TYPEDSIGNATURES)
"
@inline function hastickers(exc::Exchange)
    has(exc, :fetchTickers, :fetchTickersWs, :watchTickers)
end

@doc "Ccxt market types."
MARKET_TYPES = (:spot, :future, :swap, :option, :margin, :delivery)

_lasttype(types) = begin
    len = length(types)
    if len == 0
        nothing
    elseif len == 1
        first(types)
    else
        first(Iterators.drop(types, len - 1))
    end
end
@doc "Any of $MARKET_TYPES"
function markettype(exc, margin=Misc.config.margin)
    types = exc.types
    if margin == NoMargin()
        if :spot ∈ types
            :spot
        else
            _lasttype(types)
        end
    else
        if :linear ∈ types
            :linear
        elseif :swap ∈ types
            :swap
        elseif :future ∈ types
            :future
        else
            _lasttype(types)
        end
    end
end

function markettype(exc::Exchange, sym, margin)
    mkt = get(exc.markets, string(sym), missing)
    if ismissing(mkt)
        markettype(exc, margin)
    else
        mkt["type"]
    end
end

@doc """Fetch and cache tickers data.

$(TYPEDSIGNATURES)

The `@tickers!` macro takes the following parameters:

- `type` (optional, default is nothing): the type of tickers to fetch and cache.
- `force` (optional, default is false): a boolean that indicates whether to force the data fetch, even if the data is already present.

"""
macro tickers!(type=nothing, force=false, cache=TICKERS_CACHE100)
    exc = esc(:exc)
    tickers = esc(:tickers)
    type = type ∈ MARKET_TYPES ? QuoteNode(type) : esc(type)
    cache = esc(cache)
    quote
        local $tickers
        tp = @something($type, markettype($exc), missing)
        nm = nameof($(exc))
        k = (nm, tp)
        l = @lget! $(TICKERSLIST_LOCK_DICT) k ReentrantLock()
        @lock l begin
            if ismissing(tp)
                @warn "tickers: no market type found (offline?)" type = tp $exc.id
                $tickers = Dict{String,Dict{String,Any}}()
            elseif $force || !haskey($cache, k)
                @assert hastickers($exc) "Exchange doesn't provide tickers list."
                $cache[k] = let f = first($(exc), :fetchTickersWs, :fetchTickers)
                    $tickers = pyconvert(
                        Dict{String,Dict{String,Any}}, fetch_tickers($exc, tp)
                    )
                end
            else
                $tickers = $cache[k]
            end
        end
    end
end

@doc """Get the markets of the `ccxt` instance, according to `min_volume` and `quote` currency.

$(TYPEDSIGNATURES)

The `filter_markets` function takes the following parameters:

- `exc`: an Exchange object to get the markets from.
- `min_volume` (optional, default is 10e4): the minimum volume that a market should have.
- `quot` (optional, default is "USDT"): the quote currency to filter the markets by.
- `sep` (optional, default is '/'): the separator used in market strings.

"""
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

@doc """Get price from ticker.

$(TYPEDSIGNATURES)

The `tickerprice` function takes the following parameters:

- `tkr`: a Ticker object.
"""
function tickerprice(tkr)
    @something tkr["average"] tkr["last"] tkr["bid"]
end

@doc """Get price ranges using tickers data from exchange.

$(TYPEDSIGNATURES)

The `price_ranges` function takes the following parameters:

- `pair`: a string representing the currency pair.
- `args...`: a variable number of arguments to pass to the price ranges calculation.
- `exc` (optional, default is global `exc`): an Exchange object to get the tickers data from.
- `kwargs...`: a variable number of keyword arguments to pass to the price ranges calculation.
"""
function price_ranges(pair::AbstractString, args...; exc=exc, kwargs...)
    type = markettype(exc)
    tkrs = @tickers! type true
    price_ranges(tkrs[pair]["last"], args...; kwargs...)
end

@doc """Get quote volume from ticker.

$(TYPEDSIGNATURES)
"""
function quotevol(tkr::AbstractDict)
    v1 = get(tkr, "quoteVolume", nothing)
    isnothing(v1) || return v1
    v2 = get(tkr, "baseVolume", nothing)
    # NOTE: this is not the actual quote volume, since vol from trades
    # have different prices
    isnothing(v2) || return v2 * tickerprice(tkr)
    0
end

@doc "Trims the settlement currency in futures. (`mkt` is a ccxt market.)

$(TYPEDSIGNATURES)
"
@inline function spotsymbol(sym, mkt)
    if "quote" ∈ keys(mkt)
        "$(mkt["base"])/$(mkt["quote"])"
    else
        split(sym, ":")[1]
    end
end

issupported(tf::AbstractString, exc) = tf ∈ exc.timeframes
@doc """Check if a timeframe is supported by an exchange.

$(TYPEDSIGNATURES)
"""
issupported(tf::TimeFrame, exc) = issupported(string(tf), exc)

function exckeys!(exc, key, secret, pass, wa, pk)
    # FIXME: ccxt key/secret naming is swapped for kucoin apparently
    if Symbol(exc.id) ∈ (:kucoin, :kucoinfutures)
        (key, secret) = secret, key
    end
    exc.py.apiKey = key
    exc.py.secret = secret
    exc.py.password = pass
    exc.py.walletAddress = wa
    exc.py.privateKey = pk
    nothing
end

@doc "Set exchange api keys.

$(TYPEDSIGNATURES)
"
function exckeys!(exc; sandbox=issandbox(exc))
    eid = Symbol(exc.id)
    exc_keys = exchange_keys(eid; sandbox)
    # Check the exchange->futures mapping to re-use keys
    if isempty(exc_keys) && eid ∈ values(futures_exchange)
        id = argmax(x -> x[2] == eid, futures_exchange)
        merge!(exc_keys, exchange_keys(id.first; sandbox))
    end
    if !isempty(exc_keys)
        @debug "Setting exchange keys..."
        exckeys!(
            exc,
            (
                get(exc_keys, k, "") for
                k in ("apiKey", "secret", "password", "walletAddress", "privateKey")
            )...,
        )
    end
end

@doc """Enable sandbox mode for exchange. Should only be called on exchange construction.

$(TYPEDSIGNATURES)

- `exc` (optional, default is global `exc`): an Exchange object to set the sandbox mode for.
- `flag` (optional, default is the inverse of the current sandbox mode status): a boolean indicating whether to enable or disable sandbox mode.
- `remove_keys` (optional, default is true): a boolean indicating whether to remove the API keys while enabling sandbox mode.

"""
function sandbox!(exc::Exchange=exc; flag=!issandbox(exc), remove_keys=true)
    success = try
        exc.py.setSandboxMode(flag)
        true
    catch e
        if e isa PyException && occursin("sandbox", string(e.v))
            @warn e
            false
        else
            rethrow(e)
        end
    end
    if flag && success
        @assert issandbox(exc) "Exchange sandbox mode couldn't be enabled. (disable sandbox mode with `sandbox=false`)"
        remove_keys && exckeys!(exc, "", "", "", "", "")
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

@doc "Enable or disable rate limit.

$(TYPEDSIGNATURES)"
ratelimit!(exc::Exchange=exc, flag=true) = exc.py.enableRateLimit = flag
ratelimit(exc::Exchange=exc) = pyconvert(DFT, exc.py.rateLimit)
ratelimit_tokens(exc::Exchange=exc) = pyconvert(DFT, exc.py.rateLimitTokens)
function ratelimit_njobs(exc::Exchange)
    round(Int, div(ratelimit(exc), ratelimit_tokens(exc)), RoundDown)
end
@doc "Set exchange timeout. (milliseconds)

$(TYPEDSIGNATURES)"
timeout!(exc::Exchange=exc, v=5000) = exc.py.timeout = v
@doc "Check that the exchange timeout is not too low wrt the interval."
function check_timeout(exc::Exchange=exc, interval=Second(5))
    @assert Bool(Millisecond(interval).value <= exc.timeout) "Interval ($interval) shouldn't be lower than the exchange set timeout ($(exc.timeout))"
end
gettimeout(exc::Exchange)::Millisecond = Millisecond(pyconvert(Int, exc.timeout))

_fetchnoerr(f, t) =
    let v = pyfetch(f)
        if v isa Exception
        else
            pyconvert(t, v)
        end
    end

@doc "The current timestamp from the exchange."
timestamp(exc::Exchange) = _fetchnoerr(exc.py.fetchTime, Int64)
Base.time(exc::Exchange) = dt(_fetchnoerr(exc.py.fetchTime, Float64))

@doc "Returns the matching *futures* exchange instance, if it exists, or the input exchange otherwise."
function futures(exc::Exchange)
    futures_sym = get(futures_exchange, exc.id, exc.id)
    futures_sym != exc.id ? getexchange!(futures_sym; sandbox=issandbox(exc)) : exc
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

@doc """Checks if the python exchange instance supports all the calls required by PingPong.

$(TYPEDSIGNATURES)

- `exc`: an Exchange object to perform the check on.
- `type` (optional, default is `:basic`): a symbol representing the type of check to perform.
"""
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
