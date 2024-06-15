using Watchers
using Watchers: default_init
using Watchers.WatchersImpls: _tfunc!, _tfunc, _exc!, _exc, _lastpushed!, _lastpushed
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
    start=false,
    kwargs...,
)
    exc = st.exchange(s)
    check_timeout(exc, interval)
    iswatch = s[:is_watch_positions] && !isnothing(first(exc, :watchPositions))
    attrs = Dict{Symbol,Any}()
    attrs[:strategy] = s
    attrs[:kwargs] = kwargs
    attrs[:interval] = interval
    attrs[:iswatch] = iswatch
    _tfunc!(attrs, _w_positions_func(s, interval; iswatch, kwargs))
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
        process=false,
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
function _w_positions_func(s, interval; iswatch, kwargs)
    exc = exchange(s)
    params, rest = split_params(kwargs)
    timeout = throttle(s)
    @lget! params "settle" guess_settle(s)
    tasks = Task[]
    init = Ref(true)
    if iswatch
        buffer_size = attr(s, :live_buffer_size, 1000)
        s[:positions_buffer] = buf = Vector{Any}()
        s[:positions_notify] = buf_notify = Condition()
        sizehint!(buf, buffer_size)
        function process_pos!(w, v)
            if !isnothing(v)
                _dopush!(w, pylist(v))
            end
            if !isempty(buf)
                push!(tasks, @async process!(w))
            end
            filter!(!istaskdone, tasks)
        end
        function init_watch_func(w)
            let v = @lock w fetch_positions(s; timeout, params, rest...)
                process_pos!(w, v)
            end
            init[] = false
            f_push(v) = begin
                push!(buf, v)
                notify(buf_notify)
            end
            h =
                w[:positions_handler] = watch_positions_handler(
                    exc, (ai for ai in s.universe); f_push, params, rest...
                )
            start_handler!(h)
            w[:process_tasks] = tasks
        end
        function watch_positions_func(w)
            if init[]
                init_watch_func(w)
            end
            while isempty(buf)
                wait(buf_notify)
            end
            v = popfirst!(buf)
            if v isa Exception
                @error "positions watcher: unexpected value" exception = v
                sleep(1)
            else
                @ifdebug LogWatchPos begin
                    function getup(prop=:time)
                        get(get(last(w.buffer, 1), 1, (;)), prop, nothing)
                    end
                    function getval(k="datetime"; src=getup(:value))
                        get(get(src, 1, pydict()), k, nothing)
                    end
                end
                @debug "positions watcher: PUSHING" _module = LogWatchPos w_time = getup() new_time = getval(;
                    src=v
                ) n = length(getup(:value))
                process_pos!(w, v)
                @debug "positions watcher: PUSHED" _module = LogWatchPos getup(:time) getval(
                    "contracts", src=v
                )
            end
            return true
        end
    else
        fetch_positions_func(w) = begin
            start = now()
            if init[]
                w[:process_tasks] = tasks
                init[] = false
            end
            try
                v = @lock w fetch_positions(s; timeout, params, rest...)
                _dopush!(w, v)
                push!(tasks, @async process!(w))
                filter!(!istaskdone, tasks)
            finally
                sleep_pad(start, interval)
            end
        end
    end
end

@doc """ Starts the watcher for positions in a live strategy.

$(TYPEDSIGNATURES)

This function starts the watcher for positions in a live strategy `s`. The watcher checks and updates the positions at a specified interval.
"""
function watch_positions!(s::LiveStrategy; interval=st.throttle(s), wait=false)
    @lock s begin
        w = @lget! attrs(s) :live_positions_watcher ccxt_positions_watcher(s; interval)
        just_started = @lock w if isstopped(w) && !attr(s, :stopped, false)
            start!(w)
            true
        else
            false
        end
        while wait && just_started && _lastprocessed(w) == DateTime(0)
            @debug "live: waiting for initial positions" _module = LogWatchPos
            safewait(w.beacon.process)
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
    if w isa Watcher
        @debug "live: stopping positions watcher" _module = LogWatchPos
        if isstarted(w)
            stop!(w)
        end
        @debug "live: positions watcher stopped" _module = LogWatchPos
    end
end

_positions_task!(w) = begin
    f = _tfunc(w)
    w[:positions_task] = @async begin
        while isstarted(w)
            try
                f(w)
                safenotify(w.beacon.fetch)
            catch e
                if e isa InterruptException
                    break
                else
                    @debug_backtrace LogWatchPos2
                end
            end
        end
    end
end

_positions_task(w) = @lget! attrs(w) :positions_task _positions_task!(w)

function Watchers._start!(w::Watcher, ::CcxtPositionsVal)
    _lastprocessed!(w, DateTime(0))
    attrs = w.attrs
    view = attrs[:view]
    empty!(view.long)
    empty!(view.short)
    empty!(view.last)
    s = attrs[:strategy]
    _exc!(attrs, exchange(s))
    _tfunc!(
        attrs,
        _w_positions_func(
            s, attrs[:interval]; iswatch=attrs[:iswatch], kwargs=w[:kwargs]
        ),
    )
end
function Watchers._stop!(w::Watcher, ::CcxtPositionsVal)
    handler = attr(w, :positions_handler, nothing)
    if !isnothing(handler)
        stop_handler!(handler)
    end
    nothing
end
function Watchers._fetch!(w::Watcher, ::CcxtPositionsVal)
    try
        fetch_task = _positions_task(w)
        if !istaskrunning(fetch_task)
            _positions_task!(w)
        end
        true
    catch
        @debug_backtrace LogWatchPos
        false
    end
end

function Watchers._init!(w::Watcher, ::CcxtPositionsVal)
    default_init(
        w,
        (; long=PositionsDict2(), short=PositionsDict2(), last=Dict{String,PositionSide}()),
        false,
    )
    _lastpushed!(w, DateTime(0))
    _lastprocessed!(w, DateTime(0))
    _lastcount!(w, ())
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
function Watchers._process!(w::Watcher, ::CcxtPositionsVal; fetched=false)
    if isempty(w.buffer)
        return nothing
    end
    eid = typeof(exchangeid(_exc(w)))
    data_date, data = last(w.buffer)
    if !islist(data)
        @debug "watchers process: wrong data type" _module = LogWatchPosProcess data_date typeof(data)
        _lastprocessed!(w, data_date)
        _lastcount!(w, ())
        return nothing
    end
    if data_date == _lastprocessed(w) && length(data) == _lastcount(w)
        @debug "watchers process: already processed" _module = LogWatchPosProcess data_date
        return nothing
    end
    s = w[:strategy]
    long_dict = w.view.long
    short_dict = w.view.short
    last_dict = w.view.last
    processed_syms = Set{Tuple{String,PositionSide}}()
    iswatch = w[:iswatch]
    # In case of fetching we must still call `_setposflags!`
    if iswatch && isempty(data)
        @debug "watchers process: nothing to process" _module = LogWatchPosProcess typeof(
            data
        )
        _lastprocessed!(w, data_date)
        _lastcount!(w, data)
        return nothing
    end
    @debug "watchers process: position" _module = LogWatchPosProcess
    @sync for resp in data
        if !isdict(resp) || resp_event_type(resp, eid) != ot.PositionUpdate
            @debug "watchers process: not a position update" resp _module =
                LogWatchPosProcess
            continue
        end
        sym = resp_position_symbol(resp, eid, String)
        ai = asset_bysym(s, sym)
        if isnothing(ai)
            @warn "watchers process: no matching asset for symbol" sym
            continue
        end
        default_side_func = Returns(_last_updated_position(long_dict, short_dict, sym))
        side = posside_fromccxt(resp, eid; default_side_func)
        push!(processed_syms, (sym, side))
        side_dict = ifelse(islong(side), long_dict, short_dict)
        pup_prev = get(side_dict, sym, nothing)
        prev_date, cond = if isnothing(pup_prev)
            DateTime(0), Threads.Condition()
        else
            pup_prev.date, pup_prev.notify
        end
        prev_side = get(last_dict, sym, side)
        this_date = @something pytodate(resp, eid) data_date
        # FIXME: Can a new update have a lower date?
        if this_date <= prev_date && side == prev_side
            @warn "watchers: received stale position update" sym side prev_side maxlog = 1
            continue
        end
        is_stale = this_date == prev_date
        # this ensure even if there are no updates we know
        # the date of the last fetch run
        @async @lock ai @lock cond begin
            pup = if isnothing(pup_prev)
                _posupdate(this_date, resp)
            elseif !is_stale
                _posupdate(pup_prev, this_date, resp)
            end
            @debug "watchers: position processed" _module = LogWatchPosProcess sym side is_stale
            if !isnothing(pup)
                @debug "watchers: UNREAD" _module = LogWatchPosProcess contracts = resp_position_contracts(
                    pup.resp, eid
                ) pup.date
                pup.read[] = false
                pup.closed[] = iszero(resp_position_contracts(pup.resp, eid))
                prev_side = get(last_dict, sym, side)
                mm = @something resp_position_margin_mode(resp, eid, Val(:parsed)) marginmode(w[:strategy])
                # NOTE: In isolated margin, we assume that if the last update is of the opposite side
                # the other side has been closed
                if mm isa IsolatedMargin && prev_side != side && !isnothing(pup_prev)
                    @deassert LogWatchPosProcess resp_position_side(pup_prev.resp, eid) |> _ccxtposside == prev_side
                    pup_prev.closed[] = true
                    if iswatch && !fetched
                        live_sync_cash!(s, ai, prev_side; pup=pup_prev)
                    end
                end
                last_dict[sym] = side
                side_dict[sym] = pup
                if iswatch && !fetched
                    live_sync_cash!(s, ai, side; pup)
                end
                safenotify(cond)
            end
        end
    end
    _lastprocessed!(w, data_date)
    _lastcount!(w, data)
    if !iswatch || fetched
        n_closed = _setposflags!(s, data_date, long_dict, Long(), processed_syms)
        n_closed += _setposflags!(s, data_date, short_dict, Short(), processed_syms)
        if !isempty(processed_syms) || n_closed > 0
            live_sync_universe_cash!(s)
        end
    end
    @debug "watchers process: done" _module = LogWatchPosProcess
end

@doc """ Updates position flags for a symbol in a dictionary.

$(TYPEDSIGNATURES)

This function updates the `PositionUpdate` status when *not* using `watch*` function. This is neccesary in case the returned list of positions from the exchange does not include closed positions (that were previously open). When using `watch*` functions it is expected that position close updates are received as new events.

"""
function _setposflags!(s, data_date, dict, side, processed_syms)
    n_closed = Ref(0)
    @sync for (sym, pup) in dict
        ai = asset_bysym(s, sym)
        @async @lock ai @lock pup.notify if !pup.closed[] && (sym, side) ∉ processed_syms
            dict[sym] = _posupdate(pup, data_date, pup.resp)
            pup.closed[] = true
            n_closed[] += 1
        end
    end
    return n_closed[]
end

function _setunread!(w)
    data = w.view
    map(v -> (v.read[] = false), values(data.long))
    map(v -> (v.read[] = false), values(data.short))
end

positions_watcher(s) = s[:live_positions_watcher]

# function _load!(w::Watcher, ::ThisVal) end

# function _process!(w::Watcher, ::ThisVal) end
