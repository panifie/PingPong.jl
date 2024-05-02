@doc """ Determine if a crossover occurred in a specified direction.

$(TYPEDSIGNATURES)

Checks if values `a`, `b`, and `c` satisfy the conditions for a crossover in the specified direction (`:above` or `:below`).
"""
iscrossed(a, b, ::Val{:above}) = a > b
iscrossed(a, b, ::Val{:below}) = a <= b

@doc """ Retrieve a signal value from a dictionary for a given key.

$(TYPEDSIGNATURES)

Extracts the `sig.value` from the property of the dictionary item identified by `k`.
"""
_getter(ct, k) = getproperty(ct, k).state.value

@doc """ Check if a signal crossover condition is met at a given time.

$(TYPEDSIGNATURES)

Evaluates if the closing prices at specified times cross a threshold in the direction `drc`.
Uses timeframes and signals to determine the crossover.
"""
function iscrossed(s, ai, ats, sig_name, drc::Val; signals_dict=s.signals, getter=_getter)
    tf = signal_timeframe(s, sig_name)
    prev_date = ats - tf
    data = ohlcv(ai, tf)
    if firstdate(data) > prev_date
        @debug "crossed: not enough candles"
        return false
    else
        data = ohlcv(ai, tf)
        ats = apply(tf, ats)

        b = getter(signals_dict[ai], sig_name)
        if ismissing(b)
            @debug "crossed: signal missing" ai sig_name
            return false
        end
        a = closeat(data, ats)
        @debug "crossed: " drc a b
        iscrossed(a, b, drc)
    end
end
