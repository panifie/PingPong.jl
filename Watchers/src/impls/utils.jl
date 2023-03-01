using Data: df, _contiguous_ts, nrow, save_ohlcv, zi, check_all_flag, snakecased
using Data.DataFramesMeta
using Exchanges: Exchange
using Exchanges.Ccxt: _multifunc
using Fetch: fetch_candles
using Lang
using Misc: rangeafter, rangebetween
using Processing: cleanup_ohlcv_data, iscomplete, isincomplete

_parsedatez(s::AbstractString) = begin
    s = rstrip(s, 'Z')
    Base.parse(DateTime, s)
end

macro parsedata(tick_type, mkts, key="symbol")
    key = esc(key)
    mkts = esc(mkts)
    quote
        NamedTuple(
            convert(Symbol, m[$key]) => fromdict($tick_type, String, m) for m in $mkts
        )
    end
end

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

@doc "Defines a closure that appends new data on each symbol dataframe."
macro append_dict_data(dict, data, maxlen_var)
    maxlen = esc(maxlen_var)
    quote
        function doappend((key, newdata))
            df = @kget! $(esc(dict)) key df()
            appendmax!(df, newdata, $maxlen)
        end
        foreach(doappend, $(esc(data)))
    end
end

# FIXME
Base.convert(::Type{Symbol}, s::LazyJSON.String) = Symbol(s)
Base.convert(::Type{DateTime}, s::LazyJSON.String) = _parsedatez(s)
Base.convert(::Type{DateTime}, s::LazyJSON.Number) = unix2datetime(s)
Base.convert(::Type{String}, s::Symbol) = string(s)
Base.convert(::Type{Symbol}, s::AbstractString) = Symbol(s)

_checks(w) = w.attrs[:checks]
_checksoff!(w) = w.attrs[:checks] = Val(:off)
_checkson!(w) = w.attrs[:checks] = Val(:on)
_do_check_contig(w, df, ::Val{:on}) = _contiguous_ts(df.timestamp, timefloat(_tfr(w)))
_do_check_contig(_, _, ::Val{:off}) = nothing
_check_contig(w, df) = !isempty(df) && _do_check_contig(w, df, _checks(w))

_exc(attrs) = attrs[:exc]
_exc(w::Watcher) = _exc(w.attrs)
_exc!(attrs, exc) = attrs[:exc] = exc
_exc!(w::Watcher, exc) = _exc!(w.attrs, exc)
_tfunc!(attrs, suffix, k) = attrs[k] = _multifunc(_exc(attrs), suffix, true)[1]
_tfunc!(attrs, suffix) = attrs[:tfunc] = _multifunc(_exc(attrs), suffix, true)[1]
_tfunc!(attrs, exc::Exchange, args...) = attrs[:tfunc] = choosefunc(exc, args...)
_tfunc(w::Watcher) = w.attrs[:tfunc]
_sym(w::Watcher) = w.attrs[:sym]
_sym!(attrs, v) = attrs[:sym] = v
_sym!(w::Watcher, v) = _sym!(w.attrs, v)
_tfr(attrs) = attrs[:timeframe]
_tfr(w::Watcher) = _tfr(w.attrs)
_tfr!(attrs, tf) = attrs[:timeframe] = tf
_tfr!(w::Watcher, tf) = w.attrs[:timeframe] = tf
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
_lastflushed!(w::Watcher, v) = w.attrs[:last_flushed] = v
_lastflushed(w::Watcher) = w.attrs[:last_flushed]
_lastprocessed!(w::Watcher, v) = w.attrs[:last_processed] = v
_lastprocessed(w::Watcher) = w.attrs[:last_processed]

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
_warmed!(w, ::Pending) = w.attrs[:status] = Warmed()
_pending!(attrs) = attrs[:status] = Pending()
_pending!(w::Watcher) = _pending!(w.attrs)
_status(w::Watcher) = w.attrs[:status]
_chill!(w) = w.attrs[:next] = apply(_tfr(w), now())
_warmup!(_, ::Warmed) = nothing
@doc "Checks if we can start processing data, after we are past the initial incomplete timeframe."
function _warmup!(w, ::Pending)
    apply(_tfr(w), now()) > w.attrs[:next] && _warmed!(w, _status(w))
end
macro warmup!(w)
    w = esc(w)
    :(_warmup!($w, _status($w)))
end

_key!(w::Watcher, k) = w.attrs[:key] = k
_key(w::Watcher) = w.attrs[:key]
_view!(w, v) = w.attrs[:view] = v
_view(w) = w.attrs[:view]

function _get_available(w, z, to)
    max_lookback = to - _tfr(w) * w.capacity.view
    isempty(z) && return nothing
    maxlen = min(w.capacity.view, size(z, 1))
    available = @view(z[(end-maxlen+1):end, :])
    return if dt(available[end, 1]) < max_lookback
        # data is too old, fetch just the latest candles,
        # and schedule a background task to fast forward saved data
        nothing
    else
        Data.to_ohlcv(available[:, :])
    end
end

function _delete_ohlcv!(w, sym=_sym(w))
    z = load(zi, _exc(w).name, snakecased(sym), string(_tfr(w)); raw=true)[1]
    delete!(z)
end

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
        _fetchto!(w, w.view, sym, tf; to=cur_timestamp, from)
        _check_contig(w, df)
    end
end

function _fetch_candles(w, from, to="", sym=_sym(w))
    fetch_candles(_exc(w), _tfr(w), sym; from, to)
end

function _fetch_error(w, from, to, sym=_sym(w))
    error("Trades/ohlcv fetching failed for $sym @ $(_exc(w).name) from: $from to: $to")
end

_op(::Val{:append}, args...; kwargs...) = appendmax!(args...; kwargs...)
_op(::Val{:prepend}, args...; kwargs...) = prependmax!(args...; kwargs...)
_fromto(to, prd, cap, kept) = to - prd * (cap - kept) - 2prd
function _from(df, to, tf, cap, ::Val{:append})
    @ifdebug @assert to >= _lastdate(tf)
    date_cap = (to - tf * cap) - tf # add one more period to ensure from inclusion
    (isempty(df) ? date_cap : max(date_cap, _lastdate(df)))
end
_from(df, to, tf, cap, ::Val{:prepend}) = _fromto(to, period(tf), cap, nrow(df))

@doc "`op`: `appendmax!` or `prependmax!`"
function _fetchto!(w, df, sym, tf, op=Val(:append); to, from=nothing)
    rows = nrow(df)
    prd = period(tf)
    rows > 0 && _check_contig(w, df)
    from = @something from _from(df, to, tf, w.capacity.view, op)
    diff = (to - from)
    if diff > prd || (diff == prd && to < _curdate(tf)) # the second case would fetch only the last incomplete candle
        candles = _fetch_candles(w, from, to, sym)
        from_to_range = rangebetween(candles.timestamp, from, to)
        isempty(from_to_range) && _fetch_error(w, from, to, sym)
        @debug begin
            to,
            _lastdate(candles), from, _firstdate(candles), length(from_to_range),
            nrow(candles)
        end
        sliced = if length(from_to_range) == nrow(candles)
            candles
        else
            view(candles, from_to_range, :)
        end
        @debug sliced[begin, :timestamp]
        cleaned = cleanup_ohlcv_data(sliced, tf)
        _firstdate(cleaned) != from + prd && _fetch_error(w, from, to, sym)
        _op(op, df, cleaned, w.capacity.view)
        @ifdebug @assert nrow(df) <= w.capacity.view
    end
end

function _resolve(w, ohlcv_dst, ohlcv_src::DataFrame, sym=_sym(w))
    _resolve(w, ohlcv_dst, _firstdate(ohlcv_src), sym)
    _append_ohlcv!(
        w, ohlcv_dst, ohlcv_src, _lastdate(ohlcv_dst), _nextdate(ohlcv_dst, _tfr(w))
    )
end
@doc "This function checks that the date candidate is the correct next date to append to `ohclv_dst`."
function _resolve(w, ohlcv_dst, date_candidate::DateTime, sym=_sym(w))
    tf = _tfr(w)
    left = _lastdate(ohlcv_dst)
    right = date_candidate
    next = _nextdate(ohlcv_dst, tf)
    if next < right
        _fetchto!(w, ohlcv_dst, sym, tf; to=right, from=left)
    else
        @ifdebug @assert isrightadj(right, left, tf) "Should $(right) is not right adjacent to $(left)!"
    end
end

function _append_ohlcv!(w, ohlcv_dst, ohlcv_src, left, next)
    # at initialization it can happen that processing is too slow
    # and fetched ohlcv overlap with processed ohlcv
    @ifdebug @assert _lastdate(ohlcv_dst) == left
    @ifdebug @assert left + _tfr(w) == next
    from_range = rangeafter(ohlcv_src.timestamp, left)
    if length(from_range) > 0 && _firstdate(ohlcv_src) == next
        @debug "Appending trades from $(_firstdate(ohlcv_src, from_range)) to $(_lastdate(ohlcv_src))"
        appendmax!(ohlcv_dst, view(ohlcv_src, from_range, :), w.capacity.view)
        _check_contig(w, w.view)
    end
end

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
