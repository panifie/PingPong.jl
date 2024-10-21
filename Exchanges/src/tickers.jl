using .Misc.Lang: @get, @multiget, @lget!, Option, safenotify, safewait
using .Misc: config, NoMargin, DFT
using .Misc.ConcurrentCollections: ConcurrentDict
using .Misc: waitforcond
using Instruments: isfiatquote, spotpair
using .Python: @pystr, @pyconst, pyfetch_timeout, pylist, pytruth
using ExchangeTypes: decimal_to_size, excDecimalPlaces, excSignificantDigits, excTickSize

@doc """A leveraged pair is a pair like `BTC3L/USD`.
- `:yes` : Leveraged pairs will not be filtered.
- `:only` : ONLY leveraged will be kept.
- `:from` : Selects non leveraged pairs, that also have at least one leveraged sibling.
"""
const LEVERAGED_PAIR_OPTIONS = (:yes, :only, :from)

@doc """Quote id of the market."""
quoteid(mkt) = @multiget mkt "quoteId" "quote" "n/a"
@doc "True if `id` is a quote id."
isquote(id, qc) = lowercase(id) == qc
@doc "True if `mkt` is a leveraged market."
ismargin(mkt) = Bool(@get mkt "margin" false)

@doc "True if `pair` is a leveraged pair."
function has_leverage(pair, pairs_with_leverage)
    !isleveragedpair(pair) && pair ∈ pairs_with_leverage
end
@doc "Constructor that returns a function that checks if a pair is leveraged."
function leverage_func(exc, with_leveraged, verbose=true)
    # Leveraged `:from` filters the pairlist taking non leveraged pairs, IF
    # they have a leveraged counterpart
    if with_leveraged == :from
        verbose && @warn "Filtering by leveraged, are you sure?"
        pairs_with_leverage = Set()
        for k in keys(exc.markets)
            dlv = deleverage_pair(k)
            k !== dlv && push!(pairs_with_leverage, dlv)
        end
        (pair) -> has_leverage(pair, pairs_with_leverage)
    else
        Returns(true)
    end
end
@doc "True if symbol `sym` has a quote volume less than `min_vol`."
function hasvolume(sym, spot; tickers, min_vol)
    if spot ∈ keys(tickers)
        quotevol(tickers[spot]) <= min_vol
    else
        quotevol(tickers[sym]) <= min_vol
    end
end

marketsid(args...; kwargs...) = error("not implemented")
@doc "Get the exchange market ids."
marketsid(exc::Exchange, args...; kwargs...) = keys(tickers(exc, args...; kwargs...))
@doc "Get the tickers matching quote currency `quot`."
tickers(quot::Symbol, args...; kwargs...) = tickers(exc, quot, args...; kwargs...)

aspair(k, v) = k => v
askey(k, _) = k
asvalue(_, v) = v

@doc """Get the exchange tickers.

$(TYPEDSIGNATURES)

- `exc`: an Exchange object to fetch the tickers from.
- `quot`: only choose pairs where the quote currency equals `quot`.
- `min_vol`: the minimum volume of each pair.
- `skip_fiat` (optional, default is true): ignore fiat/fiat pairs.
- `with_margin` (optional, default is the result of `config.margin != NoMargin()`): only choose pairs enabled for margin trading.
- `with_leverage` (optional, default is `:no`): if `:no`, skip all pairs where the base currency matches the `leverage_pair_rgx` regex.
- `as_vec` (optional, default is false): return the pair list as a Vector instead of as a Dict.
- `verbose` (optional, default is true): print detailed output about the operation.
- `type` (optional, default is the result of `markettype(exc)`): the type of markets to fetch tickers for.
- `cross_match` list of other exchanges where the filter pairs must also be present in

"""
function tickers(
    exc::Exchange,
    quot;
    min_vol,
    skip_fiat=true,
    with_margin=config.margin != NoMargin(),
    with_leverage=:no,
    as_vec=false,
    verbose=true,
    type=markettype(exc),
    cross_match::Tuple{Vararg{Symbol}}=()
) # ::Union{Dict,Vector}
    # swap exchange in case of futures
    @tickers! type
    pairlist = []
    quot = string(quot)

    lquot = lowercase(quot)

    as = ifelse(as_vec, askey, aspair)
    pushas(p, k, v, _) = push!(p, as(k, v))
    pushifquote(p, k, v, q) = isquote(quoteid(v), q) && pushas(p, k, v, nothing)
    addto = ifelse(isempty(quot), pushas, pushifquote)
    leverage_check = leverage_func(exc, with_leverage, verbose)
    notinmarket(sym) = any(sym ∉ keys(getexchange!(e).markets) for e in cross_match)
    # TODO: all this checks should be decomposed into functions transducer style
    function skip_check(sym, spot, islev, mkt)
        notinmarket(sym) ||
        (with_leverage == :no && islev) ||
            (with_leverage == :only && !islev) ||
            !leverage_check(spot) ||
            hasvolume(sym, spot; tickers, min_vol) ||
            (skip_fiat && isfiatpair(spot)) ||
            (with_margin && Bool(@get(mkt, "margin", false)))
    end

    let markets = exc.markets
        for (sym, mkt) in tickers
            mkt = get(markets, sym, nothing)
            isnothing(mkt) && continue
            spot = spotsymbol(sym, mkt)
            islev = isleveragedpair(spot)
            skip_check(sym, spot, islev, mkt) && continue
            addto(pairlist, sym, mkt, lquot)
        end
    end

    function result(pairlist, as_vec)
        isempty(pairlist) &&
            verbose &&
            @warn "No pairs found, check quote currency ($quot) and min volume parameters ($min_vol)."
        isempty(quot) && return pairlist
        as_vec && return unique!(pairlist)
        Dict(pairlist)
    end
    result(pairlist, as_vec)
end

@doc "Caches markets (1minute)."
const marketsCache1Min = safettl(String, Py, Minute(1))
@doc "Caches tickers (10seconds)."
const tickersCache10Sec = safettl(String, Py, Second(10))
@doc "Caches active states (1minute)."
const activeCache1Min = safettl(String, Bool, Minute(1))
@doc "Lock held when fetching tickers (per ticker)."
const tickersLockDict = ConcurrentDict(Dict{String,ReentrantLock}())
@doc "Retrieves a cached market (1minute) or fetches it from exchange.

$(TYPEDSIGNATURES)
"
function market!(pair, exc::Exchange)
    @lget! marketsCache1Min pair exc.py.market(pair)
end
market!(a::AbstractAsset, args...) = market!(a.raw, args...)

_tickerfunc(exc) = first(exc, :fetchTickerWs, :fetchTicker)
@doc """Fetch the ticker for a specific pair from an exchange.

$(TYPEDSIGNATURES)

The `ticker!` function takes the following parameters:

- `pair`: a string representing the currency pair to fetch the ticker for.
- `exc`: an Exchange object to fetch the ticker from.
- `timeout` (optional, default is 3 seconds): the maximum time to wait for the ticker fetch operation.
- `func` (optional, default is the result of `_tickerfunc(exc)`): the function to use to fetch the ticker.
"""
function ticker!(
    pair, exc::Exchange; timeout=Second(3), func=_tickerfunc(exc), delay=Second(1)
)
    l = @lget!(tickersLockDict, pair, ReentrantLock())
    waitforcond(l.cond_wait, timeout)
    if islocked(l)
        waitforcond(l.cond_wait, timeout)
        return @get tickersCache10Sec pair pydict()
    else
        @lock l begin
            fetch_func = first(exc, :fetchTicker)
            @lget! tickersCache10Sec pair begin
                v = nothing::Option{Py}
                tries = 0
                while tries < 3
                    tries += 1
                    def_func = pyisTrue(func == fetch_func) ? Returns(missing) : fetch_func
                    v = pyfetch_timeout(func, exc.fetchTicker, timeout, pair)
                    if v isa PyException
                        @error "Fetch ticker error: $v" offline = isoffline() func pair
                        v = pylist()
                        isoffline() && break
                    else
                        break
                    end
                    sleep(delay)
                end
                safenotify(l.cond_wait)
                v
            end
        end
    end
end
ticker!(a::AbstractAsset, args...; kwargs...) = ticker!(a.raw, args...; kwargs...)
@doc """Fetch the latest price for a specific pair from an exchange.

$(TYPEDSIGNATURES)

- `pair`: a string representing the currency pair to fetch the latest price for.
- `exc`: an Exchange object to fetch the latest price from.
- `kwargs` (optional): any additional keyword arguments are passed on to the underlying fetch operation.
"""
function lastprice(pair::AbstractString, exc::Exchange; kwargs...)
    tick = ticker!(pair, exc; kwargs...)
    lastprice(exc, tick, pair)
end

function lastprice(exc::Exchange, tick, pair="")
    if !pytruth(tick)
        sym = try
            @coalesce get(tick, "symbol", missing) pair
        catch
        end
        @warn "exchanges: failed to fetch ticker" pair nameof(exc)
        0.0
    else
        lp = tick["last"]
        if !pytruth(lp)
            ask = tick["ask"]
            bid = tick["bid"]
            if pytruth(ask) && pytruth(bid)
                (pytofloat(ask) + pytofloat(bid)) / 2
            else
                close = tick["close"]
                if pytruth(close)
                    pytofloat(close)
                else
                    vwap = tick["vwap"]
                    if pytruth(vwap)
                        pytofloat(vwap)
                    else
                        high = tick["high"]
                        low = tick["low"]
                        if pytruth(high) && pytruth(low)
                            (pytofloat(high) + pytofloat(low)) / 2
                        else
                            @warn "lastprice failed" nameof(exc) get(tick, "symbol", "")
                            0.0
                        end
                    end
                end
            end
        else
            lp |> pytofloat
        end
    end
end

function default_amount_precision(exc)
    if exc.precision == excDecimalPlaces
        8
    elseif exc.precision == excSignificantDigits
        9
    elseif exc.precision == excTickSize
        1e-8
    end
end

function default_price_precision(exc)
    if exc.precision == excDecimalPlaces
        2
    elseif exc.precision == excSignificantDigits
        3
    elseif exc.precision == excTickSize
        1e-2
    end
end

function _get_precision(exc, mkt, k)
    v = mkt[k]
    if !pyisnone(v)
        pytofloat(v)
    elseif k in ("amount", "base")
        default_amount_precision(exc)
    else # price cost quote
        default_price_precision(exc)
    end
end

@doc "Precision of the (base, quote) currencies of the market.

$(TYPEDSIGNATURES)
"
function market_precision(pair::AbstractString, exc::Exchange)
    mkt = exc.markets[pair]["precision"]
    p_amount = decimal_to_size(_get_precision(exc, mkt, "amount"), exc.precision; exc)
    p_price = decimal_to_size(_get_precision(exc, mkt, "price"), exc.precision; exc)
    (; amount=p_amount, price=p_price)
end
market_precision(a::AbstractAsset, args...) = market_precision(a.raw, args...)

py_str_to_float(n::DFT) = n
function py_str_to_float(py::Py)
    (x -> Base.parse(Float64, x))(pyconvert(String, py))
end

const DEFAULT_LEVERAGE = (; min=0.0, max=100.0)
const DEFAULT_AMOUNT = (; min=1e-15, max=Inf)
const DEFAULT_PRICE = (; min=1e-15, max=Inf)
const DEFAULT_COST = (; min=1e-15, max=Inf)
const DEFAULT_FIAT_COST = (; min=1e-8, max=Inf)

_min_from_precision(::Nothing) = nothing
_min_from_precision(v::Int) = 1.0 / 10.0^v
_min_from_precision(v::Real) = v
function _minmax_pair(mkt, l, prec, default)
    k = string(l)
    Symbol(l) => (;
        min=(@something pyconvert(Option{DFT}, get(mkt[k], "min", nothing)) _min_from_precision(
            prec
        ) default.min),
        max=(@something pyconvert(Option{DFT}, get(mkt[k], "max", nothing)) default.max),
    )
end

@doc """Fetch the market limits for a specific pair from an exchange.

$(TYPEDSIGNATURES)

- `pair`: a string representing the currency pair to fetch the market limits for.
- `exc`: an Exchange object to fetch the market limits from.
- `precision` (optional, default is `price=nothing, amount=nothing`): a named tuple specifying the precision for price and amount.
- `default_leverage` (optional, default is `DEFAULT_LEVERAGE`): the default leverage to use if not specified in the market data.
- `default_amount` (optional, default is `DEFAULT_AMOUNT`): the default amount to use if not specified in the market data.
- `default_price` (optional, default is `DEFAULT_PRICE`): the default price to use if not specified in the market data.
- `default_cost` (optional, default is `DEFAULT_COST` for non-fiat quote pairs and `DEFAULT_FIAT_COST` for fiat quote pairs): the default cost to use if not specified in the market data.
"""
function market_limits(
    pair::AbstractString,
    exc::Exchange;
    precision=(; price=nothing, amount=nothing),
    default_leverage=DEFAULT_LEVERAGE,
    default_amount=DEFAULT_AMOUNT,
    default_price=DEFAULT_PRICE,
    default_cost=(isfiatquote(pair) ? DEFAULT_FIAT_COST : DEFAULT_COST),
)
    mkt = exc.markets[pair]["limits"]
    (;
        (
            _minmax_pair(mkt, "leverage", nothing, default_leverage),
            _minmax_pair(mkt, "amount", precision.amount, default_amount),
            _minmax_pair(mkt, "price", precision.price, default_price),
            _minmax_pair(mkt, "cost", nothing, default_cost),
        )...
    )
end
function market_limits(a::AbstractAsset, args...; kwargs...)
    market_limits(a.raw, args...; kwargs...)
end

@doc """Check if a currency pair is active on an exchange.

$(TYPEDSIGNATURES)
"""
function is_pair_active(pair::AbstractString, exc::Exchange)
    @lget! activeCache1Min pair begin
        pyconvert(Bool, market!(pair, exc)["active"])
    end
end
is_pair_active(a::AbstractAsset, args...) = is_pair_active(a.raw, args...)

_default_fees(exc, side) = @something get(exc.fees, side, nothing) 0.01
function _fees_byside(exc, mkt, side)
    @something get(mkt, string(side), nothing) _default_fees(exc, Symbol(side))
end
@doc """Fetch the market fees for a specific pair from an exchange.

$(TYPEDSIGNATURES)

- `pair`: a string representing the currency pair to fetch the market fees for.
- `exc` (optional, default is the current exchange): an Exchange object to fetch the market fees from.
- `only_taker` (optional, default is `nothing`): a boolean indicating whether to fetch only the taker fee. If `nothing`, both maker and taker fees are fetched.

"""
function market_fees(
    pair::AbstractString, exc::Exchange; only_taker::Union{Bool,Nothing}=nothing
)
    m = exc.markets[pair]
    if isnothing(only_taker)
        taker = get(m, "taker", nothing)
        if isnothing(taker)
            # Fall back to fees from spot market
            m = get(exc.markets, spotpair(pair), nothing)
            if isnothing(m)
                # always ensure
                @warn "Failed to fetch $pair fees from $(exc.name), using default fees."
                taker = _default_fees(exc, :taker)
                maker = _default_fees(exc, :maker)
            else
                taker = _fees_byside(exc, m, :taker)
                maker = _fees_byside(exc, m, :maker)
            end
        else
            maker = _fees_byside(exc, m, :maker)
        end
        (; taker, maker, min=min(taker, maker), max=max(taker, maker))
    elseif only_taker
        _fees_byside(exc, m, :taker)
    else
        _fees_byside(exc, m, :maker)
    end
end
market_fees(a::AbstractAsset, args...; kwargs...) = market_fees(a.raw, args...; kwargs...)
