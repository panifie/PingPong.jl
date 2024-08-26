using ..Fetch: OrderBookLevel, L1, L2, L3

const CcxtOrderBookVal = Val{:ccxt_order_book}

# da.DataFrame(AskOrderTuple{Float64}.(pyconvert.(Tuple, ob["bids"])))
_l1func(w) = attr(w, :l1func)
_l2func(w) = attr(w, :l2func)
@doc """ Assigns the appropriate order book function based on the level.

$(TYPEDSIGNATURES)

The function assigns the appropriate order book function to the `attrs` dictionary based on the `level` provided.
It tries to assign the function in the order of preference and breaks the loop as soon as a function is successfully assigned.
If no function can be assigned, it throws an assertion error.

"""
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

@doc """ Creates a watcher for the order book of a given exchange and symbol.

$(TYPEDSIGNATURES)

This function creates a watcher for the order book of a given exchange and symbol.
It sets up the watcher with the specified `level`, `interval`, and other parameters.
The watcher is then started and returned for use.
The function checks for timeout, sets up the attributes, and assigns the appropriate order book function based on the level.

"""
function ccxt_orderbook_watcher(exc::Exchange, sym; level=L1, interval=Second(1))
    check_timeout(exc, interval)
    attrs = Dict{Symbol,Any}()
    _sym!(attrs, sym)
    _exc!(attrs, exc)
    _tfr!(attrs, timeframe)
    attrs[:oblevel] = level
    attrs[:issandbox] = issandbox(exc)
    attrs[:excparams] = params(exc)
    attrs[:excaccount] = account(exc)
    _ob_func(attrs, OrderBookLevel(level))
    watcher_type = DataFrame
    wid = string(
        CcxtOrderBookVal.parameters[1], "-", hash((exc.id, attrs[:issandbox], sym, level))
    )
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

@doc """ Converts order book data to a DataFrame.

$(TYPEDSIGNATURES)

This function takes an order book and converts it into a DataFrame.
It creates separate columns for timestamp, bid price, bid amount, ask price, and ask amount.
The function also ensures that the DataFrame is created even if the bids and asks are uneven by using the zip function.

"""
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

@doc """ Fetches the order book data and pushes it to the watcher.

$(TYPEDSIGNATURES)

This function fetches the order book data using the appropriate function and symbol.
If the fetched order book has data, it is converted to a DataFrame and pushed to the watcher.
The function returns `true` if data was fetched and pushed, and `false` otherwise.

"""
function _fetch!(w::Watcher, ::CcxtOrderBookVal)
    ob = pyfetch(_tfunc(w), _sym(w))
    if length(ob) > 0
        result = _ob_to_df(ob)
        pushnew!(w, result, _obtimestamp(result))
        true
    else
        false
    end
end

@doc """ Processes the watcher data.

$(TYPEDSIGNATURES)

This function processes the watcher data by appending it to the view.
It uses the `appendby` function to append the last buffer value to the view, with a capacity limit.

"""
function _process!(w::Watcher, ::CcxtOrderBookVal)
    appendby(v, b, cap) = appendmax!(v, last(b).value, cap)
    default_process(w, appendby)
end

@doc """ Flushes the watcher data.

$(TYPEDSIGNATURES)

This function checks if the watcher view is empty and returns nothing if it is.
Otherwise, it gets the range of data after the last flushed time from the buffer and saves it if the range has data.
The last flushed time is then updated to the time of the last data in the buffer.

"""
function _flush!(w::Watcher, ::CcxtOrderBookVal)
    isempty(w.view) && return nothing
    range = rangeafter(w.buffer, (; time=_lastflushed(w)); by=x -> x.time)
    if length(range) > 0
        toflush = vcat(getproperty.(view(w.buffer, range), :value)...)
        save_data(zi[], _key(w), toflush; serialize=false, type=Float64)
        _lastflushed!(w, w.buffer[end].time)
    end
end

function _start!(w::Watcher, ::CcxtOrderBookVal)
    attrs = w.attrs
    eid = exchangeid(_exc(w))
    exc = getexchange!(
        eid, attrs[:excparams]; sandbox=attrs[:issandbox], account=attrs[:excaccount]
    )
    _exc!(attrs, exc)
    _ob_func(attrs, OrderBookLevel(attrs[:oblevel]))
end

const OBCHUNKS = (100, 5) # chunks of the z array
@doc """ Loads order book data.

$(TYPEDSIGNATURES)

This function loads the order book data from the specified location.

"""
function _load_ob_data(w)
    load_data(zi[], _key(w); sz=OBCHUNKS, serialized=false, type=Float64)
end
