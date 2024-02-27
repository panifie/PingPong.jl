using Watchers
using Watchers: default_init
using Watchers.WatchersImpls: _tfunc!, _tfunc, _exc!, _exc, _lastfetched!, _lastfetched
@watcher_interface!
using .Exchanges: check_timeout
using .Lang: splitkws, safenotify, safewait

const CcxtPositionsVal = Val{:ccxt_positions}
# :read, if true, the value of :pos has already be locally synced
# :closed, if true, the value of :pos should be considered stale, and the position should be closed (contracts == 0)
@doc """ A named tuple for keeping track of position updates.

$(FIELDS)

This named tuple `PositionUpdate7` has fields for date (`:date`), notification condition (`:notify`), read status (`:read`), closed status (`:closed`), and Python response (`:resp`), which are used to manage and monitor the updates of a position.

"""
const PositionUpdate7 = NamedTuple{
    (:date, :notify, :read, :closed, :resp),
    Tuple{DateTime,Base.Threads.Condition,Ref{Bool},Ref{Bool},Py},
}
const PositionsDict2 = Dict{String,PositionUpdate7}

@doc """ Guesses the settlement for a given margin strategy.

$(TYPEDSIGNATURES)

This function attempts to guess the settlement for a given margin strategy `s`. The guessed settlement is returned.
"""
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
    if kwargs isa NamedTuple && haskey(kwargs, :params)
        kwargs[:params], length(kwargs) == 1 ? (;) : withoutkws(:params; kwargs)
    else
        LittleDict{Any,Any}(), kwargs
    end
end

@doc """ Wraps a fetch positions function with a specified interval.

$(TYPEDSIGNATURES)

This function wraps a fetch positions function `s` with a specified `interval`. Additional keyword arguments `kwargs` are passed to the fetch positions function.
"""
function _w_fetch_positions_func(s, interval; is_watch_func, kwargs)
    exc = exchange(s)
    params, rest = split_params(kwargs)
    timeout = throttle(s)
    @lget! params "settle" guess_settle(s)
    fetch_f = first(exc, :fetchPositionsWs, :fetchPositions)
    if is_watch_func
        f = exc.watchPositions
        init = Ref(true)
        (w) -> try # TODO: implement `init[]` like the balance watcher
            if init[]
                @lock w begin
                    v = _execfunc_timeout(fetch_f; timeout, params, rest...)
                    if islist(v)
                        _dopush!(w, v)
                    end
                end
                init[] = false
                sleep(interval)
            else
                v = _execfunc(f; params, rest...)
                @lock w _dopush!(w, v)
            end
        catch
            @debug_backtrace _module = LogWatchPos
            sleep(1)
        end
    else
        (w) -> try
            @lock w begin
                v = fetch_positions(s, (); params, rest...)
                if islist(v)
                    _dopush!(w, v)
                end
            end
            sleep(interval)
        catch
            @debug_backtrace _module = LogWatchPos
            sleep(1)
        end
    end
end

@doc """ Sets up a watcher for CCXT positions.

$(TYPEDSIGNATURES)

This function sets up a watcher for positions in the CCXT library. The watcher keeps track of the positions and updates them as necessary.
"""
function ccxt_positions_watcher(
    s::Strategy;
    interval=Second(5),
    wid="ccxt_positions",
    buffer_capacity=10,
    start=true,
    kwargs...,
)
    exc = st.exchange(s)
    check_timeout(exc, interval)
    attrs = Dict{Symbol,Any}()
    is_watch_func = @lget! s.attrs :live_watch_positions has(exc, :watchPositions)
    _tfunc!(attrs, _w_fetch_positions_func(s, interval; is_watch_func, kwargs))
    _exc!(attrs, exc)
    watcher_type = Py
    wid = string(wid, "-", hash((exc.id, nameof(s))))
    attrs[:is_watch_func] = is_watch_func
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

@doc """ Starts the watcher for positions in a live strategy.

$(TYPEDSIGNATURES)

This function starts the watcher for positions in a live strategy `s`. The watcher checks and updates the positions at a specified interval.
"""
function watch_positions!(s::LiveStrategy; interval=st.throttle(s))
    @lock s begin
        w = @lget! attrs(s) :live_positions_watcher ccxt_positions_watcher(
            s; interval, start=true
        )
        isstopped(w) && start!(w)
        w
    end
end

@doc """ Stops the watcher for positions in a live strategy.

$(TYPEDSIGNATURES)

This function stops the watcher that is tracking and updating positions for a live strategy `s`.

"""
function stop_watch_positions!(s::LiveStrategy)
    w = get(s.attrs, :live_positions_watcher, nothing)
    if w isa Watcher && isstarted(w)
        stop!(w)
    end
end

_position_task!(w) = begin
    f = _tfunc(w)
    @async begin
        while isstarted(w)
            try
                f(w)
            catch
            end
            safenotify(w.beacon.fetch)
        end
    end
end

_position_task(w) = @lget! attrs(w) :position_task _position_task!(w)

function Watchers._fetch!(w::Watcher, ::CcxtPositionsVal)
    try
        task = _position_task(w)
        if !istaskstarted(task) || istaskdone(task)
            new_task = _position_task!(w)
            setattr!(w, new_task, :position_task)
        end
        true
    catch
        @debug_backtrace _module = LogWatchPos
        false
    end
end

function Watchers._init!(w::Watcher, ::CcxtPositionsVal)
    default_init(w, (; long=PositionsDict2(), short=PositionsDict2()), false)
    _lastfetched!(w, DateTime(0))
end

function _posupdate(date, resp)
    PositionUpdate7((;
        date, notify=Base.Threads.Condition(), read=Ref(false), closed=Ref(false), resp
    ))
end
function _posupdate(prev, date, resp)
    PositionUpdate7((; date, prev.notify, prev.read, prev.closed, resp))
end
_deletek(py, k=@pyconst("info")) = haskey(py, k) && py.pop(k)
function _last_updated_position(long_dict, short_dict, sym)
    lp = get(long_dict, sym, nothing)
    sp = get(short_dict, sym, nothing)
    if isnothing(sp)
        Long()
    elseif isnothing(lp)
        Short()
    elseif lp.date >= sp.date
        Long()
    else
        Short()
    end
end
@doc """ Processes positions for a watcher using the CCXT library.

$(TYPEDSIGNATURES)

This function processes positions for a watcher `w` using the CCXT library. It goes through the positions stored in the watcher and updates their status based on the latest data from the exchange. If a symbol `sym` is provided, it processes only the positions for that symbol, updating their status based on the latest data for that symbol from the exchange.

"""
function Watchers._process!(w::Watcher, ::CcxtPositionsVal; forced_sym=nothing)
    isempty(w.buffer) && return nothing
    data_date, data = last(w.buffer)
    long_dict = w.view.long
    short_dict = w.view.short
    islist(data) || return nothing
    eid = typeof(exchangeid(_exc(w)))
    processed_syms = Set{Tuple{String,PositionSide}}()
    @debug "watchers process: position" data _module = LogWatchPos
    for resp in data
        if !isdict(resp) || resp_event_type(resp, eid) != PositionUpdate
            continue
        end
        sym = resp_position_symbol(resp, eid, String)
        side = posside_fromccxt(resp, eid, default_side_func=Returns(_last_updated_position(long_dict, short_dict, sym)))
        side_dict = ifelse(islong(side), long_dict, short_dict)
        pup_prev = get(side_dict, sym, nothing)
        date = let this_date = @something pytodate(resp, eid) data_date
            prev_date = isnothing(pup_prev) ? DateTime(0) : pup_prev.date
            if this_date == prev_date
                data_date
            else
                this_date
            end
        end
        pup = if isnothing(pup_prev)
            _posupdate(date, resp)
        elseif pup_prev.date < date
            _posupdate(pup_prev, date, resp)
        end
        push!(processed_syms, (sym, side))
        isnothing(pup) || (side_dict[sym] = pup)
    end
    # do notify if we added at least one response, or removed at least one
    skip_notify = all(isempty(x for x in (processed_syms, long_dict, short_dict)))
    # Only update closed state when using plain `fetch*` functions.
    if !w[:is_watch_func] && isnothing(forced_sym)
        _setposflags!(data_date, long_dict, Long(), processed_syms; forced_sym, eid)
        _setposflags!(data_date, short_dict, Short(), processed_syms; forced_sym, eid)
    end
    @debug "watchers process: notify" _module = LogWatchPos
    skip_notify || safenotify(w.beacon.process)
end

@doc """ Updates position flags for a symbol in a dictionary.

$(TYPEDSIGNATURES)

This function updates the `PositionUpdate` status when *not* using `watch*` function. This is neccesary in case the returned list of positions from the exchange does not include closed positions (that were previously open). When using `watch*` functions it is expected that position close updates are received as new events.

"""
function _setposflags!(data_date, dict, side, processed_syms; forced_sym, eid)
    set!(this_sym, pup) = begin
        prev_closed = pup.closed[]
        # in case forced_sym is set, the response only returned the requested position
        # hence this assumption does not apply
        if isnothing(forced_sym) && (this_sym, side) ∉ processed_syms
            pup_prev = get(dict, this_sym, nothing)
            @assert pup_prev === pup
            dict[this_sym] = _posupdate(pup_prev, data_date, pup_prev.resp)
            pup.closed[] = true
        else
            pup.closed[] = iszero(resp_position_contracts(pup.resp, eid))
            pup.read[] = false
        end
        # NOTE: this might fix some race conditions (when a position is updated right after).
        # The new update might have a lower timestamp and would skip sync (from `live_position_sync!`).
        # Therefore we reset the `read` state between position status updates.
        if prev_closed != pup.closed[]
            pup.read[] = false
        end
        safenotify(pup.notify)
    end
    if isnothing(forced_sym)
        for (sym, pup) in dict
            set!(sym, pup)
        end
    else
        pup = get(dict, forced_sym, nothing)
        if pup isa PositionUpdate7
            set!(forced_sym, pup)
        end
    end
end

function _setunread!(w)
    data = w.view
    map(v -> (v.read[] = false), values(data.long))
    map(v -> (v.read[] = false), values(data.short))
end

positions_watcher(s) = s[:live_positions_watcher]

# function _load!(w::Watcher, ::ThisVal) end

# function _process!(w::Watcher, ::ThisVal) end

# function _start!(w::Watcher, ::ThisVal) end

# function _stop!(w::Watcher, ::ThisVal) end
