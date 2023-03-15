using Misc: config
using Lang: @get, @multiget, @lget!

quoteid(mkt) = @multiget mkt "quoteId" "quote" "n/a"
isquote(id, qc) = lowercase(id) == qc
ismargin(mkt) = Bool(@get mkt "margin" false)

function has_leverage(pair, pairs_with_leverage)
    !is_leveraged_pair(pair) && pair ∈ pairs_with_leverage
end
function leverage_func(exc, with_leveraged, with_futures)
    # Leveraged `:from` filters the pairlist taking non leveraged pairs, IF
    # they have a leveraged counterpart
    if with_leveraged == :from
        with_futures &&
            @warn "Filtering by leveraged when futures markets are enabled, are you sure?"
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
    with_margin=config.margin,
    with_futures=config.futures,
    with_leverage=config.leverage,
    as_vec=false,
)::Union{Dict,Vector}
    # swap exchange in case of futures
    @tickers!
    pairlist = []
    quot = string(quot)

    lquot = lowercase(quot)
    exc = ifelse(with_futures, futures(exc), exc)

    as = ifelse(as_vec, askey, aspair)
    pushas(p, k, v, _) = push!(p, as(k, v))
    pushifquote(p, k, v, q) = isquote(quoteid(v), q) && pushas(p, k, v, nothing)
    addto = ifelse(isempty(quot), pushas, pushifquote)
    leverage_check = leverage_func(exc, with_leverage, with_futures)
    # TODO: all this checks should be decomposed into functions transducer style
    function skip_check(spot, islev, mkt)
        (with_leverage == :no && islev) ||
            (with_leverage == :only && !islev) ||
            !leverage_check(spot) ||
            (spot ∈ keys(tickers) && quotevol(tickers[spot]) <= min_vol) ||
            (skip_fiat && is_fiat_pair(spot)) ||
            (with_margin && Bool(@get(mkt, "margin", false)))
    end

    for (sym, mkt) in exc.markets
        spot = spotsymbol(sym, mkt)
        islev = is_leveraged_pair(spot)
        skip_check(spot, islev, mkt) && continue
        addto(pairlist, sym, mkt, lquot)
    end

    function result(pairlist, as_vec)
        isempty(pairlist) &&
            @warn "No pairs found, check quote currency ($quot) and min volume parameters ($min_vol)."
        isempty(quot) && return pairlist
        as_vec && return unique!(pairlist)
        Dict(pairlist)
    end
    result(pairlist, as_vec)
end

using Python.PythonCall: pystr
const pyCached = Dict{String,Py}()
macro pystr(k)
    s = esc(k)
    :(@lget! pyCached $s pystr($s))
end

const marketsCache1Min = TTL{String,Py}(Minute(1))
const tickersCache1Min = TTL{String,Py}(Minute(1))
const activeCache1Min = TTL{String,Bool}(Minute(1))
@doc "Retrieves a cached market (1minute) or fetches it from exchange."
function market!(pair::AbstractString, exc::Exchange=exc)
    @lget! marketsCache1Min pair exc.py.market(pair)
end

function ticker!(pair::AbstractString, exc::Exchange)
    @lget! tickersCache1Min pair pyfetch(exc.py.fetchTicker, pair)
end

@doc "Precision of the (base, quote) currencies of the market."
function market_precision(pair::AbstractString, exc::Exchange=exc)
    mkt = exc.markets[pair]["precision"]
    p_amount = pyconvert(Real, @py mkt["amount"])
    p_price = pyconvert(Real, @py mkt["price"])
    (; amount=p_amount, price=p_price)
end

py_str_to_float(n::Real) = n
function py_str_to_float(py::Py)
    (x -> Base.parse(Float64, x))(pyconvert(String, py))
end

const DEFAULT_LEVERAGE = (; min=0.0, max=100.0)
const DEFAULT_AMOUNT = (; min=1e-15, max=Inf)
const DEFAULT_PRICE = (; min=1e-15, max=Inf)
const DEFAULT_COST = (; min=1e-15, max=Inf)

function _minmax_pair(mkt, l, default)
    Symbol(l) => (;
        min=pyconvert(Float64, (@py get(mkt[l], "min", default.min))),
        max=pyconvert(Float64, (@py get(mkt[l], "max", default.max))),
    )
end

@doc "Minimum order size of the of the market."
function market_limits(
    pair::AbstractString,
    exc::Exchange=exc;
    default_leverage=DEFAULT_LEVERAGE,
    default_amount=DEFAULT_AMOUNT,
    default_price=DEFAULT_PRICE,
    default_cost=DEFAULT_COST,
)
    mkt = exc.markets[pair]["limits"]
    (;
        (
            _minmax_pair(mkt, "leverage", default_leverage),
            _minmax_pair(mkt, "amount", default_amount),
            _minmax_pair(mkt, "price", default_price),
            _minmax_pair(mkt, "cost", default_cost),
        )...
    )
end

@doc ""
function is_pair_active(pair::AbstractString, exc::Exchange=exc)
    @lget! activeCache1Min pair begin
        pyconvert(Bool, market!(pair)["active"])
    end
end

@doc "Taker fees for market."
market_fees(pair::AbstractString, exc::Exchange=exc) = exc.markets[pair]["taker"]::Float64
