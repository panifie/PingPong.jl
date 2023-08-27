using Lang: @get, @multiget, @lget!, Option
using Misc: config, NoMargin, DFT
using Misc.ConcurrentCollections: ConcurrentDict
using Instruments: isfiatquote, spotpair
using Python: @pystr, @pyconst, pyfetch_timeout

@doc """A leveraged pair is a pair like `BTC3L/USD`.
- `:yes` : Leveraged pairs will not be filtered.
- `:only` : ONLY leveraged will be kept.
- `:from` : Selects non leveraged pairs, that also have at least one leveraged sibling.
"""
const LEVERAGED_PAIR_OPTIONS = (:yes, :only, :from)

quoteid(mkt) = @multiget mkt "quoteId" "quote" "n/a"
isquote(id, qc) = lowercase(id) == qc
ismargin(mkt) = Bool(@get mkt "margin" false)

function has_leverage(pair, pairs_with_leverage)
    !isleveragedpair(pair) && pair ∈ pairs_with_leverage
end
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
function hasvolume(sym, spot; tickers, min_vol)
    if spot ∈ keys(tickers)
        quotevol(tickers[spot]) <= min_vol
    else
        quotevol(tickers[sym]) <= min_vol
    end
end

marketsid(args...; kwargs...) = keys(tickers(exc, args...; kwargs...))
marketsid(exc::Exchange, args...; kwargs...) = keys(tickers(exc, args...; kwargs...))
tickers(quot::Symbol, args...; kwargs...) = tickers(exc, quot, args...; kwargs...)

aspair(k, v) = k => v
askey(k, _) = k
asvalue(_, v) = v

@doc """Get the exchange tickers.
- `quot`: Only choose pairs where the quot currency equals `quot`.
- `min_vol`: The minimum volume of each pair.
- `skip_fiat`: Ignore fiat/fiat pairs.
- `margin`: Only choose pairs enabled for margin trading.
- `leveraged`: If `:no` skip all pairs where the base currency matches the `leverage_pair_rgx` regex.
- `as_vec`: Returns the pairlist as a Vector instead of as a Dict.
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
    # TODO: all this checks should be decomposed into functions transducer style
    function skip_check(sym, spot, islev, mkt)
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

const marketsCache1Min = safettl(String, Py, Minute(1))
const tickersCache10Sec = safettl(String, Py, Second(10))
const activeCache1Min = safettl(String, Bool, Minute(1))
const tickersLockDict = ConcurrentDict(Dict{String,ReentrantLock}())
@doc "Retrieves a cached market (1minute) or fetches it from exchange."
function market!(pair, exc::Exchange=exc)
    @lget! marketsCache1Min pair exc.py.market(pair)
end
market!(a::AbstractAsset, args...) = market!(a.raw, args...)

_tickerfunc(exc) = first(exc, :watchTicker, :fetchTicker)
function ticker!(pair, exc::Exchange; timeout=Second(3), func=_tickerfunc(exc))
    lock(@lget!(tickersLockDict, pair, ReentrantLock())) do
        @lget! tickersCache10Sec pair pyfetch_timeout(func, exc.fetchTicker, timeout, pair)
    end
end
ticker!(a::AbstractAsset, args...) = ticker!(a.raw, args...)
function lastprice(pair::AbstractString, exc::Exchange; kwargs...)
    ticker!(pair, exc; kwargs...)["last"] |> pytofloat
end

@doc "Precision of the (base, quote) currencies of the market."
function market_precision(pair::AbstractString, exc::Exchange)
    mkt = exc.markets[pair]["precision"]
    p_amount = pyconvert(DFT, mkt["amount"])
    p_price = pyconvert(DFT, mkt["price"])
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
const DEFAULT_FIAT_COST = (; min=1.0, max=Inf)

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

@doc "Minimum order size of the of the market."
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

@doc ""
function is_pair_active(pair::AbstractString, exc::Exchange=exc)
    @lget! activeCache1Min pair begin
        pyconvert(Bool, market!(pair)["active"])
    end
end
is_pair_active(a::AbstractAsset, args...) = is_pair_active(a.raw, args...)

_default_fees(exc, side) = @something get(exc.fees, side, nothing) 0.001
function _fees_byside(exc, mkt, side)
    @something get(mkt, string(side), nothing) _default_fees(exc, Symbol(side))
end
@doc "Taker fees for market."
function market_fees(
    pair::AbstractString, exc::Exchange=exc; only_taker::Union{Bool,Nothing}=nothing
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
