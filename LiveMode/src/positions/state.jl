import PaperMode.SimMode: liquidate!
using .Instances: value

function Executors.aftertrade!(
    s::MarginStrategy{Live}, ai::A, o::O, t::T
) where {A,O,T<:Trade}
    @info "($(t.date), $(nameof(s))) $(nameof(ordertype(t))) $(nameof(orderside(t))) $(cnum(t.amount)) of $(t.order.asset) at $(cnum(t.price))($(cnum(t.size)) $(ai.asset.qc))"
    try
        invoke(aftertrade!, Tuple{Strategy,A,O}, s, ai, o)
        update = get(get_positions(s, positionside(o)), raw(ai), nothing)
        if isnothing(update) || update.date < t.date
            @debug "After trade, re-fetch postiion for updates $(raw(ai))" id = t.order.id
            w = positions_watcher(s)
            if islocked(w)
                @debug "waiting for positions watcher to process new updates"
                safewait(w.beacon.process)
            else
                @debug "force fetching position updates from watcher"
                fetch!(positions_watcher(s))
            end
            @debug "Retrieving position update response" locked = islocked(w)
            update = lock(w) do
                live_position(s, ai, positionside(o); since=t.date)
            end
        end
        @ifdebug if isopen(position(ai, posside(o)))
            liqprice(ai, o) > 0 || @warn "Liqprice below zero ($(liqprice(ai, o)))"
            entryprice(ai, o.price, o) > 0 ||
                @warn "Entryprice below zero ($(entryprice(ai, o.price, o)))"
        end
        position!(s, ai, t)
        @ifdebug if isnothing(ai.lastpos[]) || isdust(ai, ai.lastpos[].entryprice[])
            @debug "Position state closed ($(raw(ai))): $(ai.lastpos[].entryprice[]), isdust: $(isdust(ai, ai.lastpos[].entryprice[]))"
        end
        if isnothing(update)
            @warn "Couldn't fetch position status from exchange."
        else
            live_sync_position!(s, ai, o, update)
        end
        @ifdebug if islong(o)
            cash(ai, posside(o)) >= 0 || @warn " cash for long should be positive."
        else
            cash(ai, posside(o)) <= 0 || @warn " cash for short should be negative"
        end
    catch
        @ifdebug Base.show_backtrace(stdout, Base.catch_backtrace())
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
