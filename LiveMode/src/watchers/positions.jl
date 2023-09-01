using Watchers
using Watchers: default_init
using Watchers.WatchersImpls: _tfunc!, _tfunc, _exc!, _exc, _lastfetched!, _lastfetched
@watcher_interface!
using .Exchanges: check_timeout
using .Lang: splitkws, safenotify, safewait

const CcxtPositionsVal = Val{:ccxt_positions}
const PositionUpdate4 = NamedTuple{
    (:date, :notify, :pos),Tuple{DateTime,Base.Threads.Condition,Py}
}

function guess_settle(s::MarginStrategy)
    try
        first(s.universe).asset.sc |> string |> uppercase
    catch
        ""
    end
end

_dopush!(w, v; if_func=islist) =
    if if_func(v)
        pushnew!(w, v)
        _lastfetched!(w, now())
    end

function split_params(kwargs)
    (split, rest) = splitkws(:params; kwargs)
    tup = tuple(split...)
    # (params, reset)
    isempty(tup) ? LittleDict{Py,Any}() : tup[1][2], rest
end

function _w_fetch_positions_func(s, interval; kwargs)
    exc = exchange(s)
    params, rest = split_params(kwargs)
    @lget! params @pyconst("settle") guess_settle(s)
    if has(exc, :watchPositions)
        f = exc.watchPositions
        (w) -> try
            v = _execfunc(f; params, rest...)
            _dopush!(w, v)
        catch
        end
    else
        (w) -> try
            v = fetch_positions(s, (); params, rest...)
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
    keep_info=true,
    start=true,
    kwargs...,
)
    exc = st.exchange(s)
    check_timeout(exc, interval)
    attrs = Dict{Symbol,Any}()
    attrs[:keep_info] = keep_info
    _tfunc!(attrs, _w_fetch_positions_func(s, interval; kwargs))
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

function watch_positions!(s::LiveStrategy; interval=st.throttle(s))
    w = @lget! s.attrs :live_positions_watcher ccxt_positions_watcher(
        s; interval, start=true
    )
    isstopped(w) && start!(w)
    w
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

_deletek(py, k=@pyconst("info")) = haskey(py, k) && py.pop(k)
function Watchers._process!(w::Watcher, ::CcxtPositionsVal)
    isempty(w.buffer) && return nothing
    _, update = last(w.buffer)
    data = w.view
    islist(update) || return nothing
    keep_info = w[:keep_info]
    eid = typeof(exchangeid(_exc(w)))
    for pos in update
        isdict(pos) || continue
        sym = resp_position_symbol(pos, eid, String)
        side = posside_fromccxt(pos, eid)
        side_dict = getproperty(data, ifelse(islong(side), :long, :short))
        prev = get(side_dict, sym, nothing)
        date = @something pytodate(pos, eid) now()
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
