using Fetch: OrderBookLevel, L1, L2, L3

const CcxtOrderBookVal = Val{:ccxt_order_book}

# da.DataFrame(AskOrderTuple{Float64}.(pyconvert.(Tuple, ob["bids"])))
_l1func(w) = w.attrs[:l1func]
_l2func(w) = w.attrs[:l2func]
function _ob_func(attrs, level)
    name = "$(level)OrderBook"
    names = if level == L1
        ("OrderBook", name)
    else
        (name,)
    end
    for func in names
        try
            _tfunc!(attrs, func)
            break
        catch e
            @error e
        end
    end
    @assert :tfunc in keys(attrs)
end

function ccxt_orderbook_watcher(exc::Exchange, sym; level=L1, interval=Second(1))
    check_timeout(exc, interval)
    attrs = Dict{Symbol,Any}()
    _sym!(attrs, sym)
    _exc!(attrs, exc)
    _tfr!(attrs, timeframe)
    _ob_func(attrs, OrderBookLevel(level))
    watcher_type = DataFrame
    wid = string(CcxtOrderBookVal.parameters[1], "-", hash((exc.id, sym, level)))
    w = watcher(
        watcher_type,
        wid,
        CcxtOrderBookVal();
        start=false,
        load=false,
        flush=true,
        process=true,
        buffer_capacity=10,
        view_capacity=1000,
        fetch_interval=interval,
        fetch_timeout=2interval,
        flush_interval=3interval,
        attrs,
    )
    _key!(w, "ccxt_$(exc.name)_orderbook_$(snakecased(_sym(w)))")
    start!(w)
    w
end

function ccxt_orderbook_watcher(exc::Exchange, syms::Iterable; kwargs...)
    tasks = [@async ccxt_orderbook_watcher(exc, s; kwargs...) for s in syms]
    [fetch(t) for t in tasks]
end

function _init!(w::Watcher, ::CcxtOrderBookVal)
    default_init(w, DataFrame())
    _lastflushed!(w, DateTime(0))
end

Base.float(py::Py) = pyconvert(Float64, py)
_totimestamp(v) = dt(pyconvert(Int, v))
_timestamp!(d, v) = metadata!(d, "timestamp", v)
_symbol!(d, ob) = metadata!(d, "symbol", string(ob["symbol"]))
_obtimestamp(d::DataFrame) = metadata(d, "timestamp")

function _ob_to_df(ob)
    out = (
        timestamp=DateTime[],
        bid_price=Float64[],
        bid_amount=Float64[],
        ask_price=Float64[],
        ask_amount=Float64[],
    )
    ts = _totimestamp(ob["timestamp"])
    # NOTE: zipping makes sure that even if bids and asks are uneven
    # the dataframe will be to the lower count
    for (bid, ask) in zip(ob["bids"], ob["asks"])
        push!(out.timestamp, ts)
        push!(out.bid_price, float(ask[0]))
        push!(out.bid_amount, float(ask[1]))
        push!(out.ask_price, float(bid[0]))
        push!(out.ask_amount, float(bid[1]))
    end
    d = df!(out)
    _timestamp!(d, ts)
    _symbol!(d, ob)
    d
end

function _fetch!(w::Watcher, ::CcxtOrderBookVal)
    ob = @pyfetch _tfunc(w)(_sym(w))
    if length(ob) > 0
        result = _ob_to_df(ob)
        pushnew!(w, result, _obtimestamp(result))
        true
    else
        false
    end
end

function _process!(w::Watcher, ::CcxtOrderBookVal)
    appendby(v, b, cap) = appendmax!(v, last(b).value, cap)
    default_process(w, appendby)
end

function _flush!(w::Watcher, ::CcxtOrderBookVal)
    isempty(w.view) && return nothing
    range = rangeafter(w.buffer, (; time=_lastflushed(w)); by=x -> x.time)
    if length(range) > 0
        toflush = vcat(getproperty.(view(w.buffer, range), :value)...)
        save_data(zi[], _key(w), toflush; serialize=false, type=Float64)
        _lastflushed!(w, w.buffer[end].time)
    end
end

const OBCHUNKS = (100, 5) # chunks of the z array
function _load_ob_data(w)
    load_data(zi[], _key(w); sz=OBCHUNKS, serialized=false, type=Float64)
end
