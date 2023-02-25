@define_fromdict!(true)

_parsedatez(s::AbstractString) = begin
    s = rstrip(s, 'Z')
    Base.parse(DateTime, s)
end

macro parsedata(tick_type, mkts, key="symbol")
    key = esc(key)
    mkts = esc(mkts)
    quote
        NamedTuple(
            convert(Symbol, m[$key]) => @fromdict($tick_type, String, m) for m in $mkts
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
        let function doappend((key, newdata))
                df = @kget! $(esc(dict)) key DataFrame(; copycols=false)
                appendmax!(df, newdata, $maxlen)
            end
            foreach(doappend, $(esc(data)))
        end
    end
end

Base.convert(::Type{Symbol}, s::LazyJSON.String) = Symbol(s)
Base.convert(::Type{DateTime}, s::LazyJSON.String) = _parsedatez(s)
Base.convert(::Type{DateTime}, s::LazyJSON.Number) = unix2datetime(s)
Base.convert(::Type{String}, s::Symbol) = string(s)
Base.convert(::Type{Symbol}, s::AbstractString) = Symbol(s)

_check_contig(w, df) = _contiguous_ts(df.timestamp, timefloat(_tfr(w)))

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
_warmup!(w, ::Warmed) = nothing
function _warmup!(w, ::Pending)
    apply(_tfr(w), now()) > w.attrs[:next] && _warmed!(w, _status(w))
end
macro warmup!(w)
    w = esc(w)
    :(_warmup!($w, _status($w)))
end

_key!(w, k) = w.attrs[:key] = k
_view!(w, v) = w.attrs[:view] = v

function _fetch_candles(w, from, to="")
    fetch_candles(_exc(w), _tfr(w), _sym(w); zi=zilmdb(), from, to)
end
