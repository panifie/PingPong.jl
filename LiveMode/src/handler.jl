function condition(ai::AssetInstance)
    @lget! ai :event_cond Threads.Condition()
end

function condition(s::LiveStrategy)
    @lget! s :event_cond Threads.Condition()
end

function sync_condition(ai::AssetInstance)
    @lget! ai :sync_cond Threads.Condition()
end

function sync_condition(s::LiveStrategy)
    @lget! s :sync_cond Threads.Condition()
end

function lasteventrun!(obj::Union{Strategy,AssetInstance}, date::DateTime)
    obj[:last_event_date] = date
end

function lasteventrun!(obj::Union{Strategy,AssetInstance})
    @lget! obj :last_event_date DateTime(0)
end

const SyncRequest1 = NamedTuple{(:date, :func),Tuple{DateTime,<:Function}}
function get_events(s::LiveStrategy)
    @lget! s :events begin
        lasteventrun!(s)
        condition(s)
        SortedArray(Vector{SyncRequest1}(); by=erq -> erq.date)
    end
end

function get_events(ai::AssetInstance)
    @lget! ai :events begin
        lasteventrun!(ai)
        condition(ai)
        SortedArray(Vector{SyncRequest1}(); by=erq -> erq.date)
    end
end

function notify_request(ai::AssetInstance)
    safenotify(condition(ai))
end

function notify_request(s::LiveStrategy)
    safenotify(condition(s))
end

function notify_sync(ai::AssetInstance)
    safenotify(sync_condition(ai))
end

function notify_sync(s::LiveStrategy)
    safenotify(sync_condition(s))
end

function sendrequest!(obj, date::DateTime, f::Function; events=get_events(obj))
    if !get(obj, :stopping_handler, false)
        h = get_handler!(obj)
        if istaskrunning(h)
            func() = begin
                f()
                notify_sync(obj)
            end
            push!(events, (; date, func))
            notify_request(obj)
            nothing
        else
            @warn "events: request unscheduled, event handler not running" date @caller(10)
        end
    end
end

function sendrequest!(
    obj, date::DateTime, f::Function, waitfor::Period; events=get_events(obj)
)
    if !get(obj, :stopping_handler, false)
        h = get_handler!(obj)
        if istaskrunning(h)
            done = Ref(false)
            ans = Ref{Any}(nothing)
            func() = begin
                ans[] = f()
                notify_sync(obj)
                done[] = true
            end
            push!(events, (; date, func))
            notify_request(obj)
            waitforcond(() -> done[], waitfor)
            ans[]
        else
            @warn "events: request unscheduled, event handler not running" date @caller(10)
        end
    end
end

function handle_events(obj, events=get_events(obj), cond=condition(obj))
    while !isempty(events)
        req = first(events)
        diff = req.date - now()
        if diff <= Second(0)
            try
                req.func()
            catch
                @debug_backtrace LogEvents
            end
            popfirst!(events)
            lasteventrun!(obj, req.date)
        else
            @debug "events: waiting for the future" _module = LogEvents req.date
            @async (sleep(abs(diff)); safenotify(cond))
            break
        end
    end
end

get_handler!(obj) = @lget! attrs(obj) :event_handler @lock obj _start_handler!(obj)
get_handler(obj) = attr(obj, :event_handler, nothing)

# TODO: handlers should stop after a while (similar to watch_orders and watch_trades)
function _start_handler!(obj)
    t = attr(obj, :event_handler, nothing)
    if !istaskrunning(t)
        events = get_events(obj)
        cond = condition(obj)
        obj[:event_handler] = @start_task IdDict() begin
            obj[:stopping_handler] = false
            handle_events(obj, events, cond)
            while @istaskrunning()
                if obj[:stopping_handler]
                    break
                else
                    safewait(cond)
                end
                try
                    handle_events(obj, events, cond)
                catch
                    @debug_backtrace LogEvents
                end
            end
        end
    end
end

function start_handlers!(s::LiveStrategy)
    _start_handler!(s)
    for ai in universe(s)
        _start_handler!(ai)
    end
end

function delete_handler!(obj)
    delete!(attrs(obj), :event_handler)
end

function _stop_handler!(obj)
    t = get_handler(obj)
    if !isnothing(t)
        try
            obj[:stopping_handler] = true
            waitsync(obj)
            stop_task(t)
            delete_handler!(obj)
            notify_request(obj)
            notify_sync(obj)
        finally
            obj[:stopping_handler] = false
        end
    end
    t
end

function stop_handlers!(s::LiveStrategy)
    s_task = _stop_handler!(s)
    task = [_stop_handler!(ai) for ai in universe(s)]
    @debug "handlers: waiting termination" _module = LogEvents
    if istaskrunning(s_task)
        wait(s_task)
    end
    for ai in universe(s)
        t = get_handler(ai)
        if istaskrunning(t)
            try
                ai[:stopping_handler] = true
                notify_request(ai) # this solves some race conditions with `sendrequest!`
                wait(t)
            finally
                ai[:stopping_handler] = false
            end
        end
    end
    @debug "handlers: handlers terminated" _module = LogEvents
end

function reset_events!(s::LiveStrategy)
    empty!(get_events(s))
    foreach(empty!, (get_events(ai) for ai in universe(s)))
end

function restart_handlers!(s::LiveStrategy)
    reset_events!(s)
    stop_handlers!(s)
    start_handlers!(s)
end

