import PaperMode.SimMode: liquidate!
using .Instances: value

@doc """ Executes post-trade updates for a given strategy, asset, order, and trade

$(TYPEDSIGNATURES)

Invoked after a trade event, it fetches the updated position data and syncs the local state. 
If the position update fails or is stale, warnings are logged.

"""
function Executors.aftertrade!(
    s::MarginStrategy{Live}, ai::A, o::O, t::T
) where {A,O,T<:Trade}
    @info "after trade:" t cash = cash(ai, posside(t)) nameof(s)
    try
        invoke(aftertrade!, Tuple{Strategy,A,O,T}, s, ai, o, t)
        # Update local state asap, since syncing can have long delays
        position!(s, ai, t)
        # NOTE: shift by 1ms to allow for some margin of error
        # ideally exchanges should be tested to see how usually timestamps
        # are handled when a trade event would update the timestamp of an order
        # and a position
        since = t.date - Millisecond(1)
        @debug "after trade: fetching position for updates $(raw(ai))" id = t.order.id
        update = live_position(s, ai, posside(o); since, force=true)
        @ifdebug begin
            if isopen(position(ai, posside(o)))
                liqprice(ai, o) >= 0 ||
                    @error "after trade: liqprice below zero" liqprice(ai, o)
                entryprice(ai, o.price, o) >= 0 ||
                    @error "after trade: entryprice below zero" entryprice(ai, o.price, o)
            end
            if !isnothing(ai.lastpos[]) && isdust(ai, ai.lastpos[].entryprice[])
                @debug "after trade: position state closed" ai = raw(ai) ep = ai.lastpos[].entryprice[] isdust = isdust(
                    ai, ai.lastpos[].entryprice[]
                )
            end
        end
        if isnothing(update)
            @warn "after trade: position sync failed, risk of corrupted state" side = posside(
                o
            ) o.id t.date
        elseif update.date >= since
            @deassert islocked(ai)
            @debug "after trade: syncing with position" update.date update.closed[] contracts = resp_position_contracts(
                update.resp, exchangeid(ai)
            )
            # NOTE: strict=true because the trade might have happened *after* a position
            # had already been synced (read=true)
            live_sync_position!(s, ai, o, update; strict=true)
        else
            @warn "after trade: stale position update" update.date since
        end
        @ifdebug if islong(o)
            cash(ai, posside(o)) >= 0 ||
                @error "after trade: cash for long should be positive."
        else
            cash(ai, posside(o)) <= 0 ||
                @error "after trade: cash for short should be negative"
        end
    catch
        @debug_backtrace
        @warn "after trade: failed" ai = raw(ai) s = nameof(s) exc = (exchange(ai))
    end
    t
end

@doc """ Logs a warning when a liquidation event is approaching in live mode

$(TYPEDSIGNATURES)

Liquidations are not simulated in live mode due to lack of unified behavior in ccxt. This function logs the crucial details such as leverage, margin, entry price, liquidation price, and position value when a liquidation event is impending.

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
