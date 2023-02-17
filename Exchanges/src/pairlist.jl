using Misc: config
using Lang: @lget!

@inline function qid(v)
    k = keys(v)
    if "quoteId" ∈ k
        v["quoteId"]
    elseif "quote" ∈ k
        v["quote"]
    else
        false
    end
end
@inline is_qmatch(id, q) = lowercase(id) === q
get_pairs(args...; kwargs...) = keys(get_pairlist(args...; kwargs...))
get_pairlist(quot::Symbol, args...; kwargs...) = get_pairlist(exc, quot, args...; kwargs...)
function get_pairlist(
    exc::Exchange=exc,
    quot::Symbol=config.qc,
    min_vol::T where {T<:AbstractFloat}=config.vol_min;
    kwargs...,
)
    begin
        get_pairlist(exc, string(quot), convert(Float64, min_vol); kwargs...)
    end
end

@doc """Get the exchange pairlist.
- `quot`: Only choose pairs where the quot currency equals `quot`.
- `min_vol`: The minimum volume of each pair.
- `skip_fiat`: Ignore fiat/fiat pairs.
- `margin`: Only choose pairs enabled for margin trading.
- `leveraged`: If `:no` skip all pairs where the base currency matches the `leverage_pair_rgx` regex.
- `as_vec`: Returns the pairlist as a Vector instead of as a Dict.
"""
function get_pairlist(
    exc::Exchange,
    quot::String,
    min_vol::Float64;
    skip_fiat=true,
    margin=config.margin,
    futures=config.futures,
    leveraged=config.leverage,
    as_vec=false,
)::Union{Dict,Vector}
    # swap exchange in case of futures
    @tickers
    pairlist = []
    lquot = lowercase(quot)

    if futures
        futures_sym = get(futures_exchange, exc.id, exc.id)
        if futures_sym !== exc.id
            exc = getexchange!(futures_sym)
        end
    end

    tup_fun = as_vec ? (k, _) -> k : (k, v) -> k => v
    push_fun = if isempty(quot)
        (p, k, v) -> push!(p, tup_fun(k, v))
    else
        (p, k, v) -> is_qmatch(qid(v), lquot) && push!(p, tup_fun(k, v))
    end
    # Leveraged `:from` filters the pairlist taking non leveraged pairs, IF
    # they have a leveraged counterpart
    local hasleverage
    if leveraged === :from
        if futures
            @warn "Filtering by leveraged when futures markets are enabled, are you sure?"
        end
        pairs_with_leverage = Set()
        for k in keys(exc.markets)
            dlv = deleverage_pair(k)
            if k !== dlv
                push!(pairs_with_leverage, dlv)
            end
        end
        hasleverage = (k) -> (!is_leveraged_pair(k) && k ∈ pairs_with_leverage)
    else
        hasleverage = (_) -> true
    end

    for (k, v) in exc.markets
        k = as_spot_ticker(k, v)
        lev = is_leveraged_pair(k)
        if (leveraged === :no && lev) ||
            (leveraged === :only && !lev) ||
            !hasleverage(k) ||
            (k ∈ keys(tickers) && qvol(tickers[k]) <= min_vol) ||
            (skip_fiat && is_fiat_pair(k)) ||
            (margin && !isnothing(get(v, "margin", nothing)) && !v["margin"])
            continue
        else
            push_fun(pairlist, k, v)
        end
    end
    isempty(pairlist) &&
        @warn "No pairs found, check quote currency ($quot) and min volume parameters ($min_vol)."
    isempty(quot) && return pairlist
    as_vec && return pairlist
    Dict(pairlist)
end

using Python.PythonCall: pystr
const pyCached = Dict{String,Py}()
macro pystr(k)
    s = esc(k)
    :(@lget! pyCached $s pystr($s))
end

using Lang: @lget!
const marketsCache1Min = TTL{String,Py}(Minute(1))
const tickersCache1MIn = TTL{String,Py}(Minute(1))
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

@doc "Minimum order size of the of the market."
function market_limits(pair::AbstractString, exc::Exchange=exc)
    mkt = exc.markets[pair]["limits"]
    (;
        (
            Symbol(l) => (;
                min=pyconvert(Float64, (@py get(mkt[l], "min", 0.0))),
                max=pyconvert(Float64, (@py get(mkt[l], "max", 0.0))),
            ) for l in ("leverage", "amount", "price", "cost")
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
