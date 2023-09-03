
function set_active_position!(
    ai;
    cash_long=cash(ai, Long()),
    cash_short=cash(ai, Short()),
    ts_long=position(ai, Long()).timestamp[],
    ts_short=position(ai, Short()).timestamp[],
    default_date=now(),
)
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
    ai.lastpos[] = if isnothing(active_side)
    else
        position(ai, active_side)
    end
end
