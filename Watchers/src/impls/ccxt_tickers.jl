using ..Fetch.Exchanges
using .Exchanges.Ccxt: choosefunc
using ..Python
using .Python: pyisnone

baremodule LogTickersWatcher end

const CcxtTickerVal = Val{:ccxt_ticker}
@doc "The ccxt ticker object as a NamedTuple."
const CcxtTicker = @NamedTuple begin
    symbol::String
    timestamp::Option{DateTime}
    open::Float64
    high::Float64
    low::Float64
    close::Float64
    previousClose::Option{Float64}
    bid::Float64
    ask::Float64
    bidVolume::Option{Float64}
    askVolume::Option{Float64}
    last::Float64
    vwap::Float64
    change::Float64
    percentage::Float64
    average::Float64
    baseVolume::Float64
    quoteVolume::Float64
end

_ids!(attrs, ids) = attrs[:ids] = string.(ids)
_ids(w) = attr(w, :ids)

@doc """ Create a `Watcher` instance that tracks all markets for an exchange (ccxt)

$(TYPEDSIGNATURES)

This function creates a `Watcher` instance that tracks all markets for an exchange (ccxt).
It sets the symbol, exchange, and time frame for the watcher, and prepares the trades buffer.
It also sets the watcher's status to pending and initializes the last fetched and last flushed timestamps.

"""
function ccxt_tickers_watcher(
    exc::Exchange;
    val=CcxtTickerVal(),
    wid=CcxtTickerVal.parameters[1],
    syms=keys(exc.markets),
    interval=Second(5),
    start=true,
    load=true,
    process=false,
    buffer_capacity=100,
    view_capacity=2000,
    flush=true,
    iswatch=nothing,
)
    check_timeout(exc, interval)
    attrs = Dict{Symbol,Any}()
    if !isnothing(iswatch)
        attrs[:iswatch] = iswatch::Bool
    end
    attrs[:issandbox] = issandbox(exc)
    attrs[:excparams] = params(exc)
    attrs[:excaccount] = account(exc)
    _sym!(attrs, syms) # FIXME: this line should be removed
    _ids!(attrs, syms)
    _exc!(attrs, exc)
    watcher_type = Dict{String,CcxtTicker}
    wid = string(wid, "-", hash((exc.id, syms, attrs[:issandbox])))
    watcher(
        watcher_type,
        wid,
        val;
        start,
        load,
        flush,
        process,
        buffer_capacity,
        view_capacity,
        fetch_interval=interval,
        attrs,
    )
end
ccxt_tickers_watcher(syms...) = ccxt_tickers_watcher([syms...])

# FIXME
wpyconvert(::Type{T}, py::Py) where {T} =
    if pyisnone(py)
        nothing
    else
        pyconvert(T, py)
    end

wpyconvert(::Type{F}, py::Py) where {F<:AbstractFloat} = begin
    if pyisnone(py)
        zero(F)
    else
        pyconvert(F, py)
    end
end
wpyconvert(::Type{<:Union{Nothing,DateTime}}, py::Py) =
    if pyisnone(py)
        nothing
    else
        dt(pyconvert(Int, py))
    end
wpyconvert(::Type{T}, v::Symbol) where {T} = T(v)

function _parse_ticker_snapshot(snap)
    result = Dict{String,CcxtTicker}()
    if !(snap isa Py)
        try
            snap = pydict(snap)
        catch
            @error "watcher: failed to parse ticker snapshot" snap
            return result
        end
    end
    if !isempty(snap)
        for py_ticker in snap.values()
            ticker = fromdict(CcxtTicker, String, py_ticker, wpyconvert, wpyconvert)
            result[ticker.symbol] = ticker
        end
    end
    result
end

@doc """ Fetches trades and updates the watcher's trades buffer

$(TYPEDSIGNATURES)

This function fetches trades for the watcher's symbol and time frame, and updates the watcher's trades buffer.
If new trades are fetched, they are appended to the trades buffer and the last fetched timestamp is updated.

"""
_fetch!(w::Watcher, ::CcxtTickerVal) = _tfunc(w)()
function _check_ids(exc, ids)
    markets = keys(exc.markets)
    issymbol_available(sym) =
        if sym ∉ markets
            @warn "tickers watcher: symbol not on exchange" sym
            false
        else
            true
        end
    v = filter(issymbol_available, ids)
    if isempty(v)
        @debug "tickers watcher: no symbols" ids exc
        error("tickers watcher: no symbols on exchange")
    end
    v
end
_func_args(exc, ids) =
    if isempty(ids)
        ()
    else
        (_check_ids(exc, ids),)
    end
function _reset_tickers_func!(w::Watcher)
    attrs = w.attrs
    eid = exchangeid(_exc(w))
    exc = getexchange!(
        eid, attrs[:excparams]; sandbox=attrs[:issandbox], account=attrs[:excaccount]
    )
    _exc!(attrs, exc)
    # don't pass empty args to imply all symbols
    ids = _ids(w)
    @assert ids isa Vector
    args = _func_args(exc, ids)
    watch_func = first(exc, :watchTickersForSymbols, :watchTickers)
    fetch_func = choosefunc(exc, "Ticker", args...)
    iswatch = @lget! attrs :iswatch !isnothing(watch_func)
    if iswatch
        corogen_func(_) = coro_func() = watch_func(args...)
        init_func() = fetch_func()
        handler_task!(
            w;
            init_func,
            corogen_func,
            wrapper_func=_parse_ticker_snapshot,
            if_func=!isempty,
        )
        _tfunc!(attrs, () -> check_task!(w))
    else
        tickers_func() = begin
            tasks = @lget! attrs :process_tasks Task[]
            fetched = @lock w begin
                time = now()
                resp = fetch_func()
                result = _parse_ticker_snapshot(resp)
                if !isempty(result)
                    pushnew!(w, result, time)
                    true
                else
                    false
                end
            end
            if fetched
                push!(tasks, @async process!(w))
                filter!(!istaskdone, tasks)
            end
            return fetched
        end
        _tfunc!(attrs, tickers_func)
    end
end

_start!(w::Watcher, ::CcxtTickerVal) = _reset_tickers_func!(w)
_stop!(w::Watcher, ::CcxtTickerVal) = stop_handler_task!(w)

function _init!(w::Watcher, ::CcxtTickerVal)
    exc = _exc(w)
    _key!(
        w,
        string(
            "ccxt_", exc.name, issandbox(exc), "_tickers_", join(snakecased.(_ids(w)), "_")
        ),
    )
    default_init(w, nothing)
end
