using Watchers
using Watchers: default_init
using Watchers.WatchersImpls: _tfunc!, _tfunc, _exc!, _lastfetched!, _lastfetched
@watcher_interface!
using .Exchanges: check_timeout
using .Lang: splitkws, safenotify

const CcxtPositionsVal = Val{:ccxt_positions}
const PositionUpdate4 = NamedTuple{(:date, :notify, :pos),Tuple{DateTime,Base.Threads.Condition,Py}}

function guess_settle(s::MarginStrategy)
    try
        first(s.universe).asset.sc |> string |> uppercase
    catch
        ""
    end
end

_dopush!(w, v) =
    if islist(v)
        pushnew!(w, v)
        _lastfetched!(w, now())
    end

function _fetch_func(s, interval; kwargs)
    exc = exchange(s)
    params, rest = let (split, rest) = splitkws(:params; kwargs)
        tup = tuple(split...)
        isempty(tup) ? LittleDict{Py,Any}() : tup[1][2], rest
    end
    @lget! params @pystr("settle") guess_settle(s)
    if has(exc, :watchPositions)
        f = exc.watchPositions
        (w) -> try
            v = _execfunc(f; params, kwargs...)
            _dopush!(w, v)
        catch
        end
    else
        (w) -> try
            v = fetch_positions(s, (); params, kwargs...)
            _dopush!(w, v)
            sleep(interval)
        catch
            sleep(interval)
        end
    end
end

function ccxt_positions_watcher(
    s::Strategy;
    interval=Second(5),
    wid="ccxt_positions",
    buffer_capacity=10,
    keep_info=false,
    start=true,
    kwargs...,
)
    exc = st.exchange(s)
    check_timeout(exc, interval)
    attrs = Dict{Symbol,Any}()
    attrs[:keep_info] = keep_info
    _tfunc!(attrs, _fetch_func(s, interval; kwargs))
    _exc!(attrs, exc)
    watcher_type = Py
    wid = string(wid, "-", hash((exc.id, nameof(s))))
    watcher(
        watcher_type,
        wid,
        CcxtPositionsVal();
        start,
        load=false,
        flush=false,
        process=true,
        buffer_capacity,
        view_capacity=1,
        fetch_interval=interval,
        attrs,
    )
end

_position_task!(w) = begin
    f = _tfunc(w)
    @async while isstarted(w)
        f(w)
    end
end

_position_task(w) = @lget! w.attrs :position_task _position_task!(w)

function Watchers._fetch!(w::Watcher, ::CcxtPositionsVal)
    task = _position_task(w)
    if !istaskstarted(task) || istaskdone(task)
        _position_task!(w)
    end
    return true
end

const PositionsDict = Dict{String,PositionUpdate4}

function Watchers._init!(w::Watcher, ::CcxtPositionsVal)
    default_init(w, (; long=PositionsDict(), short=PositionsDict()), false)
    _lastfetched!(w, DateTime(0))
end

_deletek(py, k=@pystr("info")) = haskey(py, k) && py.pop(k)
function Watchers._process!(w::Watcher, ::CcxtPositionsVal)
    isempty(w.buffer) && return nothing
    _, update = last(w.buffer)
    data = w.view
    islist(update) || return nothing
    keep_info = w[:keep_info]
    for pos in update
        isdict(pos) || continue
        sym = get_py(pos, "symbol") |> string
        side = get_side(pos)
        side_dict = getproperty(data, ifelse(islong(side), :long, :short))
        prev = get(side_dict, sym, nothing)
        date = @something pytodate(pos) now()
        pos_tuple = if isnothing(prev)
            (; date, notify=Base.Threads.Condition(), pos)
        elseif prev.date < date
            keep_info || _deletek(pos)
            (; date, prev.notify, pos)
        end
        isnothing(pos_tuple) || begin
            side_dict[sym] = pos_tuple
            try
                safenotify(pos_tuple.notify)
            catch
            end
        end
    end
end

positions_watcher(s) = s[:live_positions_watcher]

# function _load!(w::Watcher, ::ThisVal) end

# function _process!(w::Watcher, ::ThisVal) end

# function _start!(w::Watcher, ::ThisVal) end

# function _stop!(w::Watcher, ::ThisVal) end
