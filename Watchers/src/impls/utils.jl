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
        let doappend((key, newdata)) = begin
                df = @kget! $(esc(dict)) key DataFrame(; copycols=false)
                appendmax!(df, newdata, $maxlen)
            end
            foreach(doappend, $(esc(data)))
        end
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

_tfunc(w::Watcher) = w.attrs[:tfunc]
_exc(w::Watcher) = w.attrs[:exc]
_sym(w::Watcher) = w.attrs[:sym]
_tfr(w::Watcher) = w.attrs[:timeframe]
_trades(w::Watcher) = w.attrs[:trades]
_firstdate(df::DataFrame, range::UnitRange) = df[range.start, :timestamp]
_firstdate(df::DataFrame) = df[begin, :timestamp]
_firsttrade(w::Watcher) = first(_trades(w))
_lasttrade(w::Watcher) = last(_trades(w))
_lastdate(df::DataFrame) = df[end, :timestamp]
_nextdate(df::DataFrame, tf) = df[end, :timestamp] + period(tf)
_lastdate(z::ZArray) = z[end, 1] # the first col is a timestamp
_curdate(tf) = apply(tf, now())
_nextdate(tf) = _curdate(tf) + tf
_dateidx(tf, from, to) = max(1, (to - from) ÷ period(tf))

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
_pending!(w::Watcher) = w.attrs[:status] = Pending()
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

_key!(w, k) = w.attrs[:key] = k
_view!(w, v) = w.attrs[:view] = v
_view(w) = w.attrs[:view]

function _fetch_candles(w, from, to="", sym=_sym(w))
    fetch_candles(_exc(w), _tfr(w), sym; zi=zilmdb(), from, to)
end

function _fetch_error(w, from, to, sym=_sym(w))
    error("Trades/ohlcv fetching failed for $sym @ $(_exc(w).name) from: $from to: $to")
end

_op(::Val{:append}, args...; kwargs...) = appendmax!(args...; kwargs...)
_op(::Val{:prepend}, args...; kwargs...) = prependmax!(args...; kwargs...)
_fromto(to, tf, cap, kept) = to - period(tf) * (cap - kept) - (2period(tf))
function _from(df, to, tf, cap, ::Val{:append})
    @debug @assert to >= _lastdate(tf)
    kept = isempty(df) ? 0 : _lastdate(df) - to + period(tf), period(tf)
    _fromto(to, tf, cap, kept)
end
_from(df, to, tf, cap, ::Val{:prepend}) = _fromto(to, tf, cap, nrow(df))

@doc "`op`: `appendmax!` or `prependmax!`"
function _fetchto!(w, df, sym, tf, op=Val(:append); to, from=nothing)
    rows = nrow(df)
    rows > 0 && _check_contig(w, df)
    from = @something from _from(df, to, tf, w.capacity.view, op)#  if isempty(df)
    if (to - from).value > 0
        candles = _fetch_candles(w, from, to, sym) # add one more period to ensure from inclusion
        from_to_range = rangebetween(candles.timestamp, from, to)
        isempty(from_to_range) && _fetch_error(w, from, to, sym)
        @debug begin
            to,
            candles[end, :timestamp],
            from,
            candles[begin, :timestamp],
            length(from_to_range),
            nrow(candles)
        end
        sliced = if length(from_to_range) == nrow(candles)
            candles
        else
            view(candles, from_to_range, :)
        end
        @debug sliced[begin, :timestamp]
        cleaned = cleanup_ohlcv_data(sliced, tf)
        _firstdate(cleaned) != from + period(tf) && _fetch_error(w, from, to, sym)
        _op(op, df, cleaned, w.capacity.view)
        @debug @assert nrow(df) <= w.capacity.view
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
        @debug @assert isrightadj(right, left, tf) "Should $(right) is not right adjacent to $(left)!"
    end
end

function _append_ohlcv!(w, ohlcv_dst, ohlcv_src, left, next)
    # at initialization it can happen that processing is too slow
    # and fetched ohlcv overlap with processed ohlcv
    @debug @assert _lastdate(ohlcv_dst) == left
    @debug @assert left + _tfr(w) == next
    from_range = rangeafter(ohlcv_src.timestamp, left)
    if length(from_range) > 0 && _firstdate(ohlcv_src) == next
        @debug "Appending trades from $(_firstdate(ohlcv_src, from_range)) to $(_lastdate(ohlcv_src))"
        appendmax!(ohlcv_dst, view(ohlcv_src, from_range, :), w.capacity.view)
        _check_contig(w, w.view)
    end
end
