using ..Data: df!, _contiguous_ts, nrow, save_ohlcv, zi, check_all_flag, snakecased
using ..Data.DFUtils: firstdate, lastdate, copysubs!, addcols!
using ..Data.DataFramesMeta
using ..Fetch.Exchanges.ExchangeTypes: params
using ..Fetch.Exchanges: Exchange, account
using ..Fetch.Exchanges.Ccxt: _multifunc, Py
using ..Fetch.Exchanges.Python: islist, isdict, StreamHandler
using ..Fetch: fetch_candles
using ..Lang
using ..Lang: safenotify, safewait
using ..Misc: rangeafter, rangebetween
using ..Fetch.Processing: cleanup_ohlcv_data, iscomplete, isincomplete
using ..Watchers: logerror
using ..Watchers: JSON3

@add_statickeys! begin
    exc
    status
    ohlcv_method
end

@doc """
Removes trailing 'Z' from a string and parses it into a DateTime object.

"""
_parsedatez(s::AbstractString) = begin
    s = rstrip(s, 'Z')
    Base.parse(DateTime, s)
end

@doc """
Converts market data into a NamedTuple.

$(TYPEDSIGNATURES)

This macro takes a tick type, a collection of market data, and an optional key (defaulting to "symbol"). It then converts each market data item into the specified tick type and constructs a NamedTuple where each entry corresponds to a market, with the key being the market's symbol and the value being the converted data.
"""
macro parsedata(tick_type, mkts, key="symbol")
    key = esc(key)
    mkts = esc(mkts)
    quote
        NamedTuple(
            convert(Symbol, m[$key]) => fromdict($tick_type, String, m) for m in $mkts
        )
    end
end

@doc """ Collects data from a buffer and stores it in a dictionary

$(TYPEDSIGNATURES)

The `collect_buffer_data` macro takes a buffer variable, key type, value type, and an optional push function.
It escapses the provided parameters and initializes a dictionary with the key type and vector of the value type.
The push function is used to populate the dictionary with data from the buffer.
If no push function is provided, a default one is used which pushes the ticker data into the dictionary.
The dictionary is then returned after collecting all data from the buffer.

"""
macro collect_buffer_data(buf_var, key_type, val_type, push=nothing)
    key_type = esc(key_type)
    val_type = esc(val_type)
    buf = esc(buf_var)
    push_func = isnothing(push) ? :(push!(@kget!(data, key, $(val_type)[]), tick)) : push
    quote
        let data = Dict{$key_type,Vector{$val_type}}(), dopush((key, tick)) = $push_func
            docollect((_, value)) = foreach(dopush, pairs(value))
            foreach(docollect, $buf)
            data
        end
    end
end

@doc """ Defines a closure that appends new data on each symbol dataframe

$(TYPEDSIGNATURES)

The `append_dict_data` macro takes a dictionary, data, and a maximum length variable.
It defines a closure `doappend` that appends new data to each symbol dataframe in the dictionary.
The macro ensures that the length of the dataframe does not exceed the provided maximum length.

"""
macro append_dict_data(dict, data, maxlen_var)
    maxlen = esc(maxlen_var)
    df = esc(:df)
    quote
        function doappend((key, newdata))
            $(df) = @kget! $(esc(dict)) key df()
            appendmax!($df, newdata, $maxlen)
        end
        foreach(doappend, $(esc(data)))
    end
end

# FIXME
Base.convert(::Type{Symbol}, s::JSON3.String) = Symbol(s)
Base.convert(::Type{DateTime}, s::JSON3.String) = _parsedatez(s)
Base.convert(::Type{DateTime}, s::JSON3.Number) = unix2datetime(s)
Base.convert(::Type{String}, s::Symbol) = string(s)
Base.convert(::Type{Symbol}, s::AbstractString) = Symbol(s)

_checks(w) = attr(w, :checks)
_checksoff!(w) = setattr!(w, Val(:off), :checks)
_checkson!(w) = setattr!(w, Val(:on), :checks)
function _do_check_contig(w, df, ::Val{:on})
    isempty(df) || _contiguous_ts(df.timestamp, timefloat(_tfr(w)))
end
_do_check_contig(_, _, ::Val{:off}) = nothing
_check_contig(w, df) = !isempty(df) && _do_check_contig(w, df, _checks(w))

_exc(attrs) = attrs[:exc]
_exc(w::Watcher) = _exc(attrs(w))
_exc!(attrs, exc) = attrs[:exc] = exc
_exc!(w::Watcher, exc) = _exc!(attrs(w), exc)
_tfunc!(attrs, suffix) = attrs[:tfunc] = _multifunc(_exc(attrs), suffix, true)[1]
_tfunc!(attrs, f::Function) = attrs[:tfunc] = f
_tfunc(w::Watcher) = attr(w, :tfunc)
_sym(w::Watcher) = attr(w, :sym)
_sym!(attrs, v) = attrs[:sym] = v
_sym!(w::Watcher, v) = _sym!(attrs(w), v)
_tfr(attrs) = attrs[:timeframe]
_tfr(w::Watcher) = _tfr(attrs(w))
_tfr!(attrs, tf) = attrs[:timeframe] = tf
_tfr!(w::Watcher, tf) = setattr!(w, tf, :timeframe)
_firstdate(df::DataFrame, range::UnitRange) = df[range.start, :timestamp]
_firstdate(df::DataFrame) = df[begin, :timestamp]
_firsttrade(w::Watcher) = first(_trades(w))
_lasttrade(w::Watcher) = last(_trades(w))
_lastdate(df::DataFrame) = df[end, :timestamp]
_nextdate(df::DataFrame, tf) = df[end, :timestamp] + period(tf)
_lastdate(z::ZArray) = z[end, 1] # the first col is a to
_curdate(tf) = apply(tf, now())
_nextdate(tf) = _curdate(tf) + tf
_dateidx(tf, from, to) = max(1, (to - from) ÷ period(tf))
_lastflushed!(w::Watcher, v) = setattr!(w, v, :last_flushed)
_lastflushed(w::Watcher) = attr(w, :last_flushed)
_lastprocessed!(w::Watcher, v) = setattr!(w, v, :last_processed)
_lastprocessed(w::Watcher) = attr(w, :last_processed)
_lastcount!(w::Watcher, v, f=length) = setattr!(w, f(v), :last_count)
_lastcount(w::Watcher) = attr(w, :last_count)

struct Warmed end
struct Pending end
_ispending(::Warmed) = false
_ispending(::Pending) = true
_iswarm(::Warmed) = true
_iswarm(::Pending) = false
macro iswarm(w)
    w = esc(w)
    :(_iswarm(_status($w)))
end
macro ispending(w)
    w = esc(w)
    :(_ispending(_status($w)))
end
_warmed!(_, ::Warmed) = nothing
_warmed!(w, ::Pending) = setattr!(w, Warmed(), :status)
_pending!(attrs) = attrs[:status] = Pending()
_pending!(w::Watcher) = _pending!(attrs(w))
_status(w::Watcher) = w[:status]
@doc "`_chill!` sets the warmup target attribute of the window to the current time applied with the time frame rate."
_chill!(w) = setattr!(w, apply(_tfr(w), now()), :warmup_target)
_warmup!(_, ::Warmed) = nothing
@doc "Checks if we can start processing data, after we are past the initial incomplete timeframe."
function _warmup!(w, ::Pending)
    ats = apply(_tfr(w), now())
    target = w[:warmup_target]
    if ats > target
        @debug "watchers: warmed!" w
        _warmed!(w, _status(w))
    end
end
macro warmup!(w)
    w = esc(w)
    :(_warmup!($w, _status($w)))
end

_key!(w::Watcher, v) = setattr!(w, v, :key)
_key(w::Watcher) = attr(w, :key)
_view!(w, v) = setattr!(w, v, :view)
_view(w) = attr(w, :view)

_dopush!(w, v; if_func=islist) =
    try
        if if_func(v)
            pushnew!(w, v, now())
            _lastpushed!(w, now())
        end
    catch
        @debug_backtrace
    end

iswatchfunc(func::Function) = startswith(string(nameof(func)), "watch")
iswatchfunc(func::Py) = startswith(string(func.__name__), "watch")

@doc """ Returns the available data within the given window

$(TYPEDSIGNATURES)

The `_get_available` function checks if data is available within a given window.
It calculates the maximum lookback period and checks if the data in the window is empty.
If it is, the function returns nothing.
If data is available, it creates a view of the data and checks if the data is too old.
If it is, it returns nothing and schedules a background task to update the data.
Otherwise, it converts the available data to OHLCV format and returns it.

"""
function _get_available(w, z, to)
    max_lookback = to - _tfr(w) * w.capacity.view
    isempty(z) && return nothing
    maxlen = min(w.capacity.view, size(z, 1))
    available = @view(z[(end - maxlen + 1):end, :])
    return if dt(available[end, 1]) < max_lookback
        # data is too old, fetch just the latest candles,
        # and schedule a background task to fast forward saved data
        nothing
    else
        Data.to_ohlcv(available[:, :])
    end
end

@doc """ Deletes OHLCV data of a given symbol from the window

$(TYPEDSIGNATURES)

The `_delete_ohlcv!` function removes OHLCV data of a specified symbol from the window.
If no symbol is provided, it defaults to the symbol of the window.
It fetches the data associated with the symbol and the current time frame rate, and deletes it.

"""
function _delete_ohlcv!(w, sym=_sym(w))
    z = load(zi, _exc(w).name, snakecased(sym), string(_tfr(w)); raw=true)[1]
    delete!(z)
end

@doc """ Fast forwards the window to the current timestamp

$(TYPEDSIGNATURES)

The `_fastforward` function ensures the window is up-to-date by fast-forwarding to the current timestamp.
It checks whether the stored data is empty or corrupted and retrieves available data within the window.
If no data is available, it calculates the starting point for fetching new data.
Otherwise, it appends the available data to the dataframe, checks the continuity of the data, and updates the starting point.
If the starting point is not equal to the current timestamp, it fetches new data up to the current timestamp and checks the data continuity again.

"""
function _fastforward(w, sym=_sym(w))
    tf = _tfr(w)
    df = w.view
    z = load(zi, _exc(w).name, sym, string(tf); raw=true)[1]
    @ifdebug @assert isempty(z) || _lastdate(z) != 0 "Corrupted storage because last date is 0: $(_lastdate(z))"

    cur_timestamp = _curdate(tf)
    avl = _get_available(w, z, cur_timestamp)
    from = if isnothing(avl)
        (cur_timestamp - period(tf) * w.capacity.view) - period(tf)
    else
        appendmax!(df, avl, w.capacity.view)
        _check_contig(w, df)
        _lastdate(df)
    end
    if from != cur_timestamp
        @debug "watchers fast forward: fetching " sym tf from to = cur_timestamp
        _sticky_fetchto!(w, w.view, sym, tf; to=cur_timestamp, from)
        _check_contig(w, df)
    end
end

function _fetch_candles(w, from, to="", sym=_sym(w); tf=_tfr(w))
    fetch_candles(_exc(w), tf, sym; from, to)
end

@doc """ Generates an error message when data fetching fails

$(TYPEDSIGNATURES)

The `_fetch_error` function is used when data fetching for a given symbol fails.
It generates an error message detailing the symbol, exchange name, and the time frame for which data fetching failed, unless the `quiet` attribute of the window is set to `true`.

"""
function _fetch_error(w, from, to, sym=_sym(w), args...)
    get(w.attrs, :quiet, false) || error(
        "Trades/ohlcv fetching failed for $sym @ $(_exc(w).name) from: $from to: $to ($(args...))",
    )
end

_op(::Val{:append}, args...; kwargs...) = appendmax!(args...; kwargs...)
_op(::Val{:prepend}, args...; kwargs...) = prependmax!(args...; kwargs...)
@doc "`_fromto` calculates a starting timestamp given a target timestamp, period, capacity and data kept."
_fromto(to, prd, cap, kept) = to - prd * (cap - kept) - 2prd
@doc """ Calculates the starting date for appending data to a dataframe

$(TYPEDSIGNATURES)

The `_from` function determines the starting date for appending data to a dataframe.
It takes into account a target date, time frame rate, capacity, and the `:append` flag.
The function ensures that the target date is not earlier than the last date in the dataframe.
It then calculates the earliest date that can be included in the dataframe based on the capacity and the time frame rate.
If the dataframe is empty, this earliest date is returned.
Otherwise, the minimum between this date and the last date in the dataframe is returned.

"""
function _from(df, to, tf, cap, ::Val{:append})
    @ifdebug @assert to >= _lastdate(df)
    date_cap = (to - tf * cap) - tf # add one more period to ensure from inclusion
    (isempty(df) ? date_cap : min(date_cap, _lastdate(df)))
end
_from(df, to, tf, cap, ::Val{:prepend}) = _fromto(to, period(tf), cap, nrow(df))
@doc """ Empties a dataframe

$(TYPEDSIGNATURES)

The `_empty!!` function tries to empty a dataframe.
If calling the `empty!` function on the dataframe throws an error, it uses the `copysubs!` function with the `empty` argument to empty the dataframe.

"""
_empty!!(df::DataFrame) =
    try
        empty!(df)
    catch
        copysubs!(df, empty, empty!)
    end

@doc """ Fetches and appends or prepends data to a dataframe

$(TYPEDSIGNATURES)

This function fetches data for a given symbol and time frame, and appends or prepends it to a provided dataframe.
The operation (append or prepend) is determined by the `op` parameter.
If the dataframe is not empty, it checks for data continuity.
If the data is not contiguous and the `resync_noncontig` attribute of the watcher is set to `true`, it empties the dataframe and resets the rows count.
The function calculates the starting date for fetching new data based on the dataframe, target date, time frame, and operation.
It then fetches the data, cleans it, and checks if it can be appended or prepended to the dataframe.
If the operation is possible, it performs it and returns `true`.
If the fetched data is empty, it returns `false`.
If the difference between the target date and the starting date is less than or equal to the period of the time frame, it also returns `true`.

"""
function _fetchto!(w, df, sym, tf, op=Val(:append); to, from=nothing)
    rows = nrow(df)
    prd = period(tf)
    rows > 0 && try
        _check_contig(w, df)
    catch e
        logerror(w, e, catch_backtrace())
        if attr(w, :resync_noncontig, false)
            # df can have immutable vectors which can't be emptied
            try
                empty!(df)
            catch
                copysubs!(df, empty, empty!)
            end
            rows = 0
        end
    end
    from = @something from _from(df, to, tf, w.capacity.view, op)
    diff = (to - from)
    if diff > prd || (diff == prd && to < _curdate(tf)) # the second case would fetch only the last incomplete candle
        candles = _fetch_candles(w, from, to, sym; tf=nrow(df) < 2 ? tf : timeframe!(df))
        from_to_range = rangebetween(candles.timestamp, from, to)
        isempty(from_to_range) && _fetch_error(w, from, to, sym)
        @debug "watchers fetchto!: " to _lastdate(candles) from _firstdate(candles) length(
            from_to_range
        ) nrow(candles)
        sliced = if length(from_to_range) == nrow(candles)
            candles
        else
            view(candles, from_to_range, :)
        end
        cleaned = cleanup_ohlcv_data(sliced, tf)
        @debug "watchers fetchto!: " last_date =
            isempty(sliced) ? nothing : lastdate(sliced)

        # # Cleaning can add missing rows, and expand the range outside our target dates
        cleaned = DataFrame(
            @view(cleaned[rangebetween(cleaned.timestamp, from, to), :]); copycols=false
        )
        if isempty(cleaned)
            return false
        end
        @debug "watchers fetchto!: " firstdate(cleaned) lastdate(cleaned)
        if !isempty(df) && firstdate(cleaned) != lastdate(df) + prd
            _fetch_error(w, from, to, sym, firstdate(cleaned))
        end
        isleftadj() = lastdate(cleaned) + prd == firstdate(df)
        isrightadj() = firstdate(cleaned) - prd == lastdate(df)
        isrecent() = firstdate(cleaned) > lastdate(df)
        isprep() = op == Val(:prepend) && isleftadj()
        function isapp()
            op == Val(:append) && (isrightadj() || (isrecent() && (_empty!!(df); true)))
        end
        @debug "watchers fetchto!: " isprep() isapp() isleftadj() isrightadj()
        if isempty(df) || isprep() || isapp()
            _op(op, df, cleaned, w.capacity.view)
        end
        @debug "watchers fetchto!: returning " lastdate(cleaned) lastdate(df)
        @ifdebug @assert nrow(df) <= w.capacity.view
        true
    end
    true
end

@doc """ Continuously attempts to fetch and append or prepend data to a dataframe until successful

$(TYPEDSIGNATURES)

This function continuously calls the `_fetchto!` function until it successfully fetches and appends or prepends data to a dataframe.
If the `_fetchto!` function fails, the function waits for a certain period before trying again.
The waiting period increases with each failed attempt.

"""
function _sticky_fetchto!(args...; kwargs...)
    backoff = 0.5
    while true
        _fetchto!(args...; kwargs...) && break
        sleep(backoff)
        backoff += 0.5
    end
end

function _resolve(w, ohlcv_dst, ohlcv_src::DataFrame, sym=_sym(w))
    _resolve(w, ohlcv_dst, _firstdate(ohlcv_src), sym)
    _append_ohlcv!(
        w, ohlcv_dst, ohlcv_src, _lastdate(ohlcv_dst), _nextdate(ohlcv_dst, _tfr(w))
    )
end
@doc """ Ensures the dataframe is up-to-date by fetching and appending data

$(TYPEDSIGNATURES)

This function ensures the dataframe is up-to-date by fetching and appending data for a given symbol and time frame.
It checks whether the stored data is empty or corrupted and retrieves available data within the window.
If no data is available, it calculates the starting point for fetching new data.
Otherwise, it appends the available data to the dataframe, checks the continuity of the data, and updates the starting point.
If the starting point is not equal to the current timestamp, it fetches new data up to the current timestamp and checks the data continuity again.

"""
function _resolve(w, ohlcv_dst, date_candidate::DateTime, sym=_sym(w))
    tf = _tfr(w)
    left = _lastdate(ohlcv_dst)
    right = date_candidate
    next = _nextdate(ohlcv_dst, tf)
    if next < right
        _sticky_fetchto!(w, ohlcv_dst, sym, tf; to=right, from=left)
    else
        @ifdebug @assert isrightadj(right, left, tf) "Should $(right) is not right adjacent to $(left)!"
    end
end

@doc """ Appends data to a dataframe if it is contiguous

$(TYPEDSIGNATURES)

This function appends data from a source dataframe to a destination dataframe if the data is contiguous.
It checks if the first date in the source dataframe is the next expected date in the destination dataframe.
If it is, the function appends the data from the source dataframe to the destination dataframe and checks the continuity of the data.

"""
function _append_ohlcv!(w, ohlcv_dst, ohlcv_src, left, next)
    # at initialization it can happen that processing is too slow
    # and fetched ohlcv overlap with processed ohlcv
    @ifdebug @assert _lastdate(ohlcv_dst) == left
    @ifdebug @assert left + _tfr(w) == next
    from_range = rangeafter(ohlcv_src.timestamp, left)
    if length(from_range) > 0
        src_view = view(ohlcv_src, from_range, :)
        if src_view.timestamp[begin] == next
            @debug "Appending trades from $(_firstdate(ohlcv_src, from_range)) to $(_lastdate(ohlcv_src))"
            appendmax!(ohlcv_dst, src_view, w.capacity.view)
            _check_contig(w, w.view)
        end
    end
end

@doc """ Ensures the dataframe is up-to-date by flushing data

$(TYPEDSIGNATURES)

This function ensures the dataframe is up-to-date by flushing data.
If the dataframe is not empty, it checks the last flushed date and the last date in the dataframe.
If these dates are not the same, it saves the data in the dataframe from the last flushed date to the last date in the dataframe and updates the last flushed date.

"""
function _flushfrom!(w)
    isempty(w.view) && return nothing
    # we assume that _load! and process already clean the data
    from_date = max(_firstdate(w.view), _lastflushed(w))
    from_date == _lastdate(w.view) && return nothing
    save_ohlcv(
        zi,
        _exc(w).name,
        _sym(w),
        string(_tfr(w)),
        w.view[DateRange(from_date)];
        check=@ifdebug(check_all_flag, :none)
    )
    _lastflushed!(w, _lastdate(w.view))
end

@kwdef mutable struct WatcherHandler2
    init = true
    init_func::Function
    corogen_func::Function
    wrapper_func::Function
    buffer_notify::Condition
    buffer::Vector{Any}
    state::Option{StreamHandler} = nothing
    task::Option{Task} = nothing
    const process_tasks = Task[]
end

function maybe_backoff!(errors, v)
    if v isa Exception
        errors[] += 1
        if errors[] > 3
            sleep(0.1)
            errors[] = 0
        end
    end
end

function new_handler_task(w; init_func, corogen_func, wrapper_func=pylist, if_func=islist)
    interval = w.interval.fetch
    buffer_size = max(w.capacity.buffer, w.capacity.view)
    buffer = Vector{Any}()
    buffer_notify = Condition()
    sizehint!(buffer, buffer_size)
    wh = WatcherHandler2(; init_func, corogen_func, wrapper_func, buffer, buffer_notify)
    tasks = wh.process_tasks
    function process_val!(w, v)
        if !isnothing(v)
            @lock w _dopush!(w, wrapper_func(v); if_func)
        end
        push!(tasks, errormonitor(@async process!(w)))
        filter!(!istaskdone, tasks)
    end
    function init_watch_func(w)
        let v = @lock w if wh.init
                init_func()
            else
                return nothing
            end
            process_val!(w, v)
        end
        wh.init = false
        errors = Ref(0)
        f_push(v) = begin
            push!(wh.buffer, v)
            notify(wh.buffer_notify)
            maybe_backoff!(errors, v)
        end
        wh.state = stream_handler(corogen_func(w), f_push)
        start_handler!(wh.state)
    end
    function watch_func(w)
        if wh.init
            init_watch_func(w)
        end
        while isempty(wh.buffer)
            wait(wh.buffer_notify)
        end
        v = popfirst!(wh.buffer)
        if v isa Exception
            @error "watcher: $(w.name)" exception = v
            sleep(1)
        else
            process_val!(w, v)
        end
        return true
    end
    wh.task = @async while isstarted(w)
        try
            watch_func(w)
            safenotify(w.beacon.fetch)
        catch e
            if e isa InterruptException
                break
            else
                @debug_backtrace
            end
        end
    end
    return wh
end

handler_task!(w, sym; kwargs...) = @lget! w.handlers sym new_handler_task(w; kwargs...)
handler_task!(w; kwargs...) = w[:handler] = new_handler_task(w; kwargs...)
handler_task(w) = w.handler.task
handler_task(w, sym) = w.handlers[sym].task
function check_handler_task!(wh)
    try
        if !istaskrunning(wh.task)
            handler_task!(w; wh.init_func, wh.corogen_func, wh.wrapper_func)
            istaskrunning(handler_task(w))
        else
            true
        end
    catch
        @debug_backtrace
        false
    end
end

check_task!(w) = check_handler_task!(w.handler)
check_task!(w, sym) = check_handler_task!(w.handlers[sym])

function stop_watcher_handler!(wh)
    if !isnothing(wh)
        stop_handler!(wh.state)
    end
    nothing
end

stop_handler_task!(w) = begin
    h = get(w.attrs, :handler, nothing)
    if !isnothing(h)
        stop_watcher_handler!(h)
    end
end
stop_handler_task!(w, sym) = begin
    hs = get(w.attrs, :handlers, nothing)
    if !isnothing(hs)
        h = get(hs, sym, nothing)
        if !isnothing(h)
            stop_watcher_handler!(h)
        end
    end
end
