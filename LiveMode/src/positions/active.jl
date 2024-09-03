@doc """ Sets the active position for an asset based on cash and timestamp conditions

$(TYPEDSIGNATURES)

Determines the active position (long or short) for an asset based on the cash amounts and timestamps of the long and short positions.
If there is no decisive active side, the last active position remains.

"""
function set_active_position!(
    ai;
    cash_long=cash(ai, Long()),
    cash_short=cash(ai, Short()),
    ts_long=position(ai, Long()).timestamp[],
    ts_short=position(ai, Short()).timestamp[],
    default_date=now(),
)::Option{Position}
    active_side = if iszero(cash_long)
        if !iszero(cash_short)
            Short()
        end
    elseif iszero(cash_short)
        Long()
    elseif something(ts_long, default_date) > something(ts_short, default_date)
        Long()
    else
        Short()
    end
    ai.lastpos[] = if !isnothing(active_side)
        position(ai, active_side)
    end
end
