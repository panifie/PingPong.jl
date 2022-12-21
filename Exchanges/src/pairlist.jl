using Misc: config

@inline function qid(v)
    k = keys(v)
    "quoteId" ∈ k ? v["quoteId"] : "quote" ∈ k ? v["quote"] : false
end
@inline is_qmatch(id, q) = lowercase(id) === q
get_pairs(args...; kwargs...) = keys(get_pairlist(args...; kwargs...))
get_pairlist(quot::Symbol, args...; kwargs...) =
    get_pairlist(exc, quot, args...; kwargs...)
get_pairlist(
    exc::Exchange=exc,
    quot::Symbol=config.qc,
    min_vol::T where {T<:AbstractFloat}=config.vol_min;
    kwargs...
) = begin
    get_pairlist(exc, string(quot), convert(Float64, min_vol); kwargs...)
end

@doc """Get the exchange pairlist.
`quot`: Only choose pairs where the quot currency equals `quot`.
`min_vol`: The minimum volume of each pair.
`skip_fiat`: Ignore fiat/fiat pairs.
`margin`: Only choose pairs enabled for margin trading.
`leveraged`: If `:no` skip all pairs where the base currency matches the `leverage_pair_rgx` regex.
`as_vec`: Returns the pairlist as a Vector instead of as a Dict.
"""
function get_pairlist(
    exc::Exchange,
    quot::String,
    min_vol::Float64;
    skip_fiat=true,
    margin=config.margin,
    futures=config.futures,
    leveraged=config.leverage,
    as_vec=false
)::Union{Dict,Vector}
    # swap exchange in case of futures
    @tickers
    pairlist = []
    lquot = lowercase(quot)

    if futures
        futures_sym = get(futures_exchange, exc.sym, exc.sym)
        if futures_sym !== exc.sym
            exc = getexchange!(futures_sym)
        end
    end

    tup_fun = as_vec ? (k, _) -> k : (k, v) -> k => v
    push_fun =
        isempty(quot) ? (p, k, v) -> push!(p, tup_fun(k, v)) :
        (p, k, v) -> is_qmatch(qid(v), lquot) && push!(p, tup_fun(k, v))
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
    quote
        try
            pyCached[$k]
        catch KeyError
            get!(pyCached, $k, pystr($k))
        end
    end
end

using Misc: @lget!
const marketsCache1Min = TTL{String,Py}(Minute(1))
const tickersCache1MIn = TTL{String,Py}(Minute(1))
const activeCache1Min = TTL{String,Bool}(Minute(1))
@doc "Retrieves a cached market (1minute) or fetches it from exchange."
market!(pair::AbstractString, exc::Exchange=exc) =
    @lget! marketsCache1Min pair exc.py.market(pair)

ticker!(pair::AbstractString, exc::Exchange) =
    @lget! tickersCache1Min pair exc.py.fetchTicker(pair)

@doc "Precision of the (base, quote) currencies of the market."
function pair_precision(pair::AbstractString, exc::Exchange=exc)
    info = exc.markets[pair]["info"]
    base_str = pyconvert(String, info[@pystr("baseIncrement")])
    quot_str = pyconvert(String, info[@pystr("quoteIncrement")])
    baseNum = split(base_str, ".")[2] |> length |> UInt8
    quotNum = split(quot_str, ".")[2] |> length |> UInt8
    (; b=baseNum, q=quotNum)
end

@inline function py_str_to_float(py::Py)
    pyconvert(String, py) |> x -> Base.parse(Float64, x)
end

@doc "Minimum order size of the (base, quote) currencies of the market."
function pair_min_size(pair::AbstractString, exc::Exchange=exc)
    info = exc.markets[pair]["info"]
    base = py_str_to_float(info[@pystr("baseMinSize")])
    quot = py_str_to_float(info[@pystr("quoteMinSize")])
    (; b=base, q=quot)
end

function is_pair_active(pair::AbstractString, exc::Exchange=exc)
    @lget! activeCache1Min pair begin
        pyconvert(Bool, market!(pair)["active"])
    end
end

pair_fees(pair::AbstractString, exc::Exchange=exc) = exc.markets[pair]["taker"]::Float64
