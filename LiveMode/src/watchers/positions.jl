using Watchers
using Watchers: default_init
using Watchers.WatchersImpls: _tfunc!, _tfunc, _exc!, _exc, _lastfetched!, _lastfetched
@watcher_interface!
using .PaperMode: sleep_pad
using .Exchanges: check_timeout, current_account
using .Lang: splitkws, safenotify, safewait

const CcxtPositionsVal = Val{:ccxt_positions}
# :read, if true, the value of :pos has already be locally synced
# :closed, if true, the value of :pos should be considered stale, and the position should be closed (contracts == 0)
@doc """ A named tuple for keeping track of position updates.

$(FIELDS)

This named tuple `PositionTuple` has fields for date (`:date`), notification condition (`:notify`), read status (`:read`), closed status (`:closed`), and Python response (`:resp`), which are used to manage and monitor the updates of a position.

"""
const PositionTuple = NamedTuple{
    (:date, :notify, :read, :closed, :resp),
    Tuple{DateTime,Base.Threads.Condition,Ref{Bool},Ref{Bool},Py},
}
const PositionsDict2 = Dict{String,PositionTuple}


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
    is_watch_func = @lget! s.attrs :is_watch_positions has(exc, :watchPositions)
    attrs = Dict{Symbol,Any}()
    attrs[:strategy] = s
    attrs[:kwargs] = kwargs
    attrs[:interval] = interval
    attrs[:is_watch_func] = is_watch_func
    _tfunc!(attrs, _w_fetch_positions_func(s, interval; is_watch_func, kwargs))
    _exc!(attrs, exc)
    watcher_type = Union{Py,PyList}
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
    try
        if if_func(v)
            pushnew!(w, v, now())
            _lastfetched!(w, now())
        end
    catch
        @debug_backtrace LogWatchPos
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
    if is_watch_func
        init = Ref(true)
        buffer_size = attr(s, :live_buffer_size, 1000)
        channel = Channel{Any}(buffer_size)
        (w) -> begin
            start = now()
            try
                if init[]
                    @lock w begin
                        v = fetch_positions(s; timeout, params, rest...)
                        _dopush!(w, v)
                    end
                    init[] = false
                    f_push = (v) -> put!(channel, v)
                    handler = w[:positions_handler] = watch_positions_handler(
                        exc, (ai for ai in s.universe); f_push, params, rest...
                    )
                    start_handler!(handler)
                    bind(channel, handler.task[])
                end
                v = try
                    take!(channel)
                catch e
                    if e isa InvalidStateException
                        return nothing
                    else
                        rethrow(e)
                    end
                end
                if v isa Exception
                    @info "positions watcher: EXCEPTION" exception = v
                else
                    @ifdebug begin
                        getup(prop=:time) = get(get(last(w.buffer, 1), 1, (;)), prop, nothing)
                        getval(k="datetime"; src=getup(:value)) = get(get(src, 1, pydict()), k, nothing)
                    end
                    @debug "positions watcher: PUSHING" _module = LogWatchPos w_time = getup() new_time = getval(src=v) n = length(getup(:value))
                    @lock w _dopush!(w, pylist(v))
                    @debug "positions watcher: PUSHED" _module = LogWatchPos getup(:time) getval("contracts", src=v)
                end
            catch
                @debug_backtrace LogWatchPos
            end
            sleep_pad(start, interval)
        end
    else
        (w) -> begin
            start = now()
            try
                @lock w begin
                    v = fetch_positions(s; params, rest...)
                    _dopush!(w, v)
                end
            catch
                @debug_backtrace LiveMode.LogWatchPos
            end
            sleep_pad(start, interval)
        end
    end
end

function sync_positions_task!(s, w; force=false)
    if force || !istaskrunning(strategy_task(s, :sync_positions))
        t = @start_task IdDict() begin
            while isstarted(w)
                safewait(w.beacon.process)
                if !@istaskrunning()
                    break
                end
                # NOTE: this is a little spammy (follows watcher throttle)
                live_sync_universe_cash!(s)
            end
        end
        t.storage[:stop_callbacks] = [() -> safenotify(w.beacon.process)]
        # wait a little for task to start
        while !(istaskstarted(t)) && !istaskdone(t)
            sleep(0.001)
        end
        set_strategy_task!(s, t, :sync_positions)
    end
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
        if isstopped(w) && !attr(s, :stopping, false)
            start!(w)
        end
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

_positions_task!(w) = begin
    f = _tfunc(w)
    @async begin
        while isstarted(w)
            try
                f(w)
            catch
                @debug_backtrace LogWatchPos
            end
            safenotify(w.beacon.fetch)
        end
    end
end

_positions_task(w) = @lget! attrs(w) :positions_task _positions_task!(w)

function Watchers._start!(w::Watcher, ::CcxtPositionsVal)
    attrs = w.attrs
    s = attrs[:strategy]
    _exc!(attrs, exchange(s))
    _tfunc!(attrs,
        _w_fetch_positions_func(s, attrs[:interval]; is_watch_func=attrs[:is_watch_func], kwargs=w[:kwargs])
    )

end
function Watchers._stop!(w::Watcher, ::CcxtPositionsVal)
    s = w[:strategy]
    task = strategy_task(s, :sync_positions)
    if task isa Task
        stop_task(task)
    end
    handler = attr(w, :positions_handler, nothing)
    if !isnothing(handler)
        stop_handler!(handler)
    end
end
function Watchers._fetch!(w::Watcher, ::CcxtPositionsVal)
    try
        fetch_task = _positions_task(w)
        if !istaskrunning(fetch_task)
            new_task = _positions_task!(w)
            setattr!(w, new_task, :positions_task)
        end
        s = w[:strategy]
        sync_task = strategy_task(s, :sync_positions)
        if !istaskrunning(sync_task) && isstarted(w)
            sync_positions_task!(s, w)
        end
        true
    catch
        @debug_backtrace LogWatchPos
        false
    end
end

function Watchers._init!(w::Watcher, ::CcxtPositionsVal)
    default_init(w, (; long=PositionsDict2(),
            short=PositionsDict2(),
            last=Dict{String,PositionSide}()
        ),
        false)
    _lastfetched!(w, DateTime(0))
    _lastprocessed!(w, DateTime(0))
end

function _posupdate(date, resp)
    PositionTuple((;
        date, notify=Base.Threads.Condition(), read=Ref(false), closed=Ref(false), resp
    ))
end
function _posupdate(prev, date, resp)
    prev.read[] = false
    PositionTuple((; date, prev.notify, prev.read, prev.closed, resp))
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
    if isempty(w.buffer)
        return nothing
    end
    data_date, data = last(w.buffer)
    eid = typeof(exchangeid(_exc(w)))
    if data_date == _lastprocessed(w)
        @debug "watchers process: already processed" _module = LogWatchPosProcess data_date
        return nothing
    elseif !islist(data)
        @debug "watchers process: data is not a list (or dict)" _module = LogWatchPosProcess typeof(data)
        _lastprocessed!(w, data_date)
        return nothing
    end
    long_dict = w.view.long
    short_dict = w.view.short
    last_dict = w.view.last
    processed_syms = Set{Tuple{String,PositionSide}}()
    @debug "watchers process: position" _module = LogWatchPosProcess
    @sync for resp in data
        if !isdict(resp) || resp_event_type(resp, eid) != ot.PositionUpdate
            @debug "watchers process: not a position update" resp _module = LogWatchPosProcess
            continue
        end
        sym = resp_position_symbol(resp, eid, String)
        default_side_func = Returns(_last_updated_position(long_dict, short_dict, sym))
        side = posside_fromccxt(resp, eid; default_side_func)
        side_dict = ifelse(islong(side), long_dict, short_dict)
        pup_prev = get(side_dict, sym, nothing)
        prev_date, cond = if isnothing(pup_prev)
            DateTime(0), Threads.Condition()
        else
            pup_prev.date, pup_prev.notify
        end
        this_date = @something pytodate(resp, eid) data_date
        # NOTE: this is an equality, becase a newer update can still have a *lower* date
        # than the most recent update date because of fetching delays
        @assert this_date >= prev_date
        is_stale = this_date == prev_date
        # this ensure even if there are no updates we know
        # the date of the last fetch run
        @async @lock cond begin
            pup = if isnothing(pup_prev)
                _posupdate(this_date, resp)
            elseif !is_stale
                _posupdate(pup_prev, this_date, resp)
            end
            @debug "watchers: position processed" _module = LogWatchPosProcess sym side is_stale
            if !isnothing(pup)
                push!(processed_syms, (sym, side))
                @info "UNREAD" contracts = resp_position_contracts(pup.resp, eid)
                pup.read[] = false
                pup.closed[] = iszero(resp_position_contracts(pup.resp, eid))
                last_dict[sym] = side
                @info "NEW pup date" pup.date
                side_dict[sym] = pup
            end
        end
    end
    skip_notify = isempty(processed_syms)
    if !w[:is_watch_func]
        _setposflags!(data_date, long_dict, Long(), processed_syms; forced_sym, eid)
        _setposflags!(data_date, short_dict, Short(), processed_syms; forced_sym, eid)
    end
    @debug "watchers process: notify" _module = LogWatchPosProcess skip_notify
    # notify if we added at least one response, or removed at least one
    if !isempty(processed_syms)
        _lastprocessed!(w, data_date)
        safenotify(w.beacon.process)
    end
end

@doc """ Updates position flags for a symbol in a dictionary.

$(TYPEDSIGNATURES)

This function updates the `PositionUpdate` status when *not* using `watch*` function. This is neccesary in case the returned list of positions from the exchange does not include closed positions (that were previously open). When using `watch*` functions it is expected that position close updates are received as new events.

"""
function _setposflags!(data_date, dict, side, processed_syms; forced_sym, eid)
    set!(this_sym, pup) = @lock pup.notify begin
        prev_closed = pup.closed[]
        # in case forced_sym is set, the response only returned the requested position
        # hence this assumption does not apply
        if isnothing(forced_sym) && (this_sym, side) ∉ processed_syms
            pup_prev = get(dict, this_sym, nothing)
            @assert pup_prev === pup
            dict[this_sym] = _posupdate(pup_prev, data_date, pup_prev.resp)
            pup.closed[] = true
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
        @sync for (sym, pup) in dict
            @async set!(sym, pup)
        end
    else
        pup = get(dict, forced_sym, nothing)
        if pup isa PositionTuple
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
