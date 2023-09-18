import PaperMode.SimMode: liquidate!
using .Instances: value

function Executors.aftertrade!(
    s::MarginStrategy{Live}, ai::A, o::O, t::T
) where {A,O,T<:Trade}
    @info "($(t.date), $(nameof(s))) $(nameof(ordertype(t))) $(nameof(orderside(t))) $(cnum(t.amount)) of $(t.order.asset) at $(cnum(t.price))($(cnum(t.size)) $(ai.asset.qc))"
    try
        invoke(aftertrade!, Tuple{Strategy,A,O,T}, s, ai, o, t)
        # Update local state asap, since syncing can have long delays
        position!(s, ai, t)
        # NOTE: shift by 1ms to allow for some margin of error
        # ideally exchanges should be tested to see how usually timestamps
        # are handled when a trade event would update the timestamp of an order
        # and a position
        since = t.date - Millisecond(1)
        @debug "After trade, fetching position for updates $(raw(ai))" id = t.order.id
        update = live_position(s, ai, posside(o); since, force=true)
        @ifdebug begin
            if isopen(position(ai, posside(o)))
                liqprice(ai, o) > 0 || @error "Liqprice below zero ($(liqprice(ai, o)))"
                entryprice(ai, o.price, o) > 0 ||
                    @error "Entryprice below zero ($(entryprice(ai, o.price, o)))"
            end
            if !isnothing(ai.lastpos[]) && isdust(ai, ai.lastpos[].entryprice[])
                @debug "Position state closed ($(raw(ai))): $(ai.lastpos[].entryprice[]), isdust: $(isdust(ai, ai.lastpos[].entryprice[]))"
            end
        end
        if isnothing(update)
            @warn "Couldn't fetch position status from exchange, possibly diverging local state"
        else
            live_sync_position!(s, ai, o, update)
        end
        @ifdebug if islong(o)
            cash(ai, posside(o)) >= 0 || @error " cash for long should be positive."
        else
            cash(ai, posside(o)) <= 0 || @error " cash for short should be negative"
        end
    catch
        @debug_backtrace
        @warn "After trade failed for $(raw(ai))@$(nameof(s))[$(exchange(ai))]"
    end
    t
end

@doc """ In live mode liquidations are not simulated because ccxt hasn't yet unified liquidation behaviour.
When a liquidation happens on the exchange w


"""
function liquidate!(
    s::MarginStrategy{Live}, ai::MarginInstance, p::PositionSide, date, args...
)
    pos = position(ai, p)
    @warn "Approaching liquidation!! $(raw(ai))[$(typeof(posside(p)))]@$(nameof(s)) $date
    lev: $(leverage(pos))
    margin: $(margin(pos))
    additional: $(additional(pos))
    price: $(entryprice(pos)) (entry) $(liqprice(pos)) (liquidation)
    value: $(cnum(value(ai, p)))
    "
end