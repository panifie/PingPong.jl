@doc """ Synchronizes a live trading strategy.

$(TYPEDSIGNATURES)

This function synchronizes both open orders and cash balances of the live strategy `s`.
The synchronization is performed in parallel for cash balances of the strategy and its universe.
The `strict` parameter controls whether the synchronization should be strict or not.

"""
function live_sync_strategy!(s::LiveStrategy; strict=true, force=false)
    live_sync_open_orders!(s; strict) # NOTE: before cash
    @sync begin
        @async live_sync_strategy_cash!(s; force)
        @async live_sync_universe_cash!(s; force)
    end
end
