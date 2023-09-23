function _handle_bal_resp(resp)
    if resp isa PyException
        @debug "Force fetch balance error" resp
        return nothing
    elseif isdict(resp)
        return resp
    else
        @debug "Force fetch balance unhandled response" resp
        return nothing
    end
end

function _force_fetchbal(s; fallback_kwargs)
    w = balance_watcher(s)
    @lock w begin
        resp = fetch_balance(s; fallback_kwargs...)
        bal = _handle_bal_resp(resp)
        pushnew!(w, bal)
        process!(w)
        return bal
    end
end

function waitforbal(
    s::LiveStrategy,
    ai,
    args...;
    force=false,
    since=nothing,
    waitfor=Second(5),
    fallback_kwargs=(),
)
    timeout = Millisecond(waitfor).value
    slept = 0
    minsleep = Millisecond(max(Second(1), waitfor))
    bal = get_balance(s)
    if isnothing(bal) && force
        while true
            bal = get_balance(s, ai)
            isnothing(bal) || break
            slept < timeout || begin
                @debug "Wait for balance: timedout (balance not found)" ai = raw(ai)
                return false
            end
            sleep(minsleep)
            slept += minsleep.value
            _force_fetchbal(s; fallback_kwargs)
        end
    end

    prev_timestamp = @something bal.date[] DateTime(0)
    @debug "Wait for balance" prev_timestamp since
    isnothing(since) || if prev_timestamp >= since
        return true
    end

    this_timestamp = prev_timestamp - Millisecond(1)
    w = balance_watcher(s)
    cond = w.beacon.process
    buf = buffer(w)
    @debug "Wait for balance: waiting" timeout = timeout
    while true
        slept += waitforcond(cond, timeout - slept)
        if length(buf) > 0
            this_timestamp = last(buf).time
        end
        if this_timestamp >= prev_timestamp >= since
            @debug "Wait for balance: up to date " prev_timestamp this_timestamp
            return true
        else
            @debug "Wait for balance:" time_left = Millisecond(timeout - slept) prev_timestamp ai = raw(
                ai
            )
        end
        slept < timeout || begin
            @debug "Wait for balance: timedout (balance not changed)" ai = raw(ai)
            return false
        end
    end
end

function live_balance(
    s::LiveStrategy, ai; fallback_kwargs=(), since=nothing, force=false, waitfor=Second(5)
)
    bal = get_balance(s, ai)
    if force &&
        !islocked(balance_watcher(s)) &&
        (isnothing(bal) || (!isnothing(since)) && bal.date < since)
        _force_fetchbal(s; fallback_kwargs)
        bal = get_balance(s, ai)
    end
    isnothing(since) ||
        isnothing(bal) ||
        begin
            if waitforbal(s, ai; force, waitfor, fallback_kwargs)
            elseif force
                @debug "live bal: last force fetch"
                _force_fetchbal(s; fallback_kwargs)
            end
            bal = get_balance(s, ai)
            if isnothing(bal) || bal.date < since
                @error "live bal: unexpected" date = isnothing(bal) ? nothing : bal.date since ai = raw(
                    ai
                ) f = @caller
                return nothing
            end
        end
end
