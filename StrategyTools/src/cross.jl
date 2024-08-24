@doc """ Determine if a crossover occurred in a specified direction.

$(TYPEDSIGNATURES)

Checks if values `a`, `b`, and `c` satisfy the conditions for a crossover in the specified direction (`:above` or `:below`).
"""
iscrossed(::Val{:above}; a, b, prev_a, prev_b) = a > b && prev_a <= prev_b
iscrossed(::Val{:below}; a, b, prev_a, prev_b) = a < b && prev_a >= prev_b
iscrossed(::Val{:above_now}; a, b, args...) = a > b
iscrossed(::Val{:below_now}; a, b, args...) = a < b

@doc """ Retrieve a signal value from a dictionary for a given key.

$(TYPEDSIGNATURES)

Extracts the `sig.value` from the property of the dictionary item identified by `k`.
"""
get_signal_value(ct, k) = getproperty(ct, k).state.value
ismissingvalue(v::F) where {F<:AbstractFloat} = isnan(v)
ismissingvalue(v) = ismissing(v)
function cmptarget(s, ai; data, ats, prev_date)
    a = closeat(data, ats)
    prev_a = closeat(data, prev_date)
    (; a, prev_a)
end

@doc """ Check if a signal crossover condition is met at a given time.

$(TYPEDSIGNATURES)

Evaluates if the closing prices at specified times cross a threshold in the direction `drc`.
Uses timeframes and signals to determine the crossover.
"""
function iscrossed(s, ai, ats, sig_b, drc::Val)
    tf = signal_timeframe(s, sig_b)
    prev_date = available(tf, ats)
    data = ohlcv(ai, tf)
    if firstdate(data) > prev_date
        @debug "crossed: not enough candles"
        return false
    else
        data = ohlcv(ai, tf)
        ats = apply(tf, ats)

        sig = strategy_signal(s, ai, sig_b)
        sig_val = signal_value(sig.state; sig)
        prev_sig_val = signal_history(sig.state; sig)
        if ismissingvalue(sig_val) || ismissingvalue(prev_sig_val)
            @debug "crossed: signal missing" ai sig_b
            return false
        elseif sig.date < prev_date
            @warn "crossed: stale signal" maxlog = 1 sig.date prev_date
            return false
        end
        a, prev_a = cmptarget(s, ai; data, ats, prev_date)
        if ismissingvalue(a) || ismissingvalue(prev_a)
            @debug "crossed: cmptarget missing values" ai ats sig_b a prev_a
            return false
        end
        @debug "crossed: " drc a sig_b
        iscrossed(drc; a, prev_a, b=sig_val, prev_b=prev_sig_val)
    end
end

function iscrossed(s, ai, ats, sig_a_name, sig_b_name, drc::Val)
    tf_a = signal_timeframe(s, sig_a_name)
    tf_b = signal_timeframe(s, sig_b_name)
    tf_s = s.timeframe
    sig_a = strategy_signal(s, ai, sig_a_name)
    @assert sig_a.date >= ats
    prev_sig_a_val = signal_history(sig_a.state; sig=sig_a)
    sig_b = strategy_signal(s, ai, sig_b_name)
    @assert sig_b.date >= ats
    prev_sig_b_val = signal_history(sig_b.state; sig=sig_b)
    a = signal_value(sig_a.state; sig=sig_a)
    b = signal_value(sig_b.state; sig=sig_b)
    if ismissingvalue(a) ||
        ismissingvalue(b) ||
        ismissingvalue(prev_sig_a_val) ||
        ismissingvalue(prev_sig_b_val)
        @debug "crossed: signal missing" ai sig_a sig_b
        return false
    elseif sig_a.date < available(tf_a, ats) || sig_b.date < available(tf_b, ats)
        @warn "crossed: stale signal" sig_a_name sig_b_name
        return false
    end
    @debug "crossed: " drc a b
    iscrossed(drc; a, b, prev_a=prev_sig_a_val, prev_b=prev_sig_b_val)
end

function iscrossed(s, ai, ats, sig_name, field_a, field_b, drc::Val)
    sig = strategy_signal(s, ai, sig_name)
    hist = signal_history(sig.state; sig)
    if ismissingvalue(sig.state.value)
        @debug "crossed: signal field missing" ai sig_name field_a field_b
        return false
    end
    current_val_a = getproperty(sig.state.value, field_a)
    current_val_b = getproperty(sig.state.value, field_b)
    tf = signal_timeframe(s, sig_name)

    if ismissingvalue(current_val_a) ||
        ismissingvalue(current_val_b) ||
        ismissingvalue(hist)
        @debug "crossed: signal field missing" ai sig_name field_a field_b
        return false
    elseif sig.date < available(tf, ats)
        @warn "crossed: stale signal" sig_name sig.date ats signal_timeframe(s, sig_name)
        return false
    end

    prev_sig_val_a = getproperty(hist, field_a)
    prev_sig_val_b = getproperty(hist, field_b)

    @debug "crossed: " drc current_val_a current_val_b
    iscrossed(
        drc; a=current_val_a, b=current_val_b, prev_a=prev_sig_val_a, prev_b=prev_sig_val_b
    )
end
