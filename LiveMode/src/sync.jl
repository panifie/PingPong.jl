@doc """ Synchronizes a live trading strategy.

$(TYPEDSIGNATURES)

This function synchronizes both open orders and cash balances of the live strategy `s`.
The synchronization is performed in parallel for cash balances of the strategy and its universe.
The `overwrite` parameter controls whether to ignore the `read` state of an update.

"""
function live_sync_strategy!(s::LiveStrategy; overwrite=false, force=false)
    live_sync_open_orders!(s; overwrite) # NOTE: before cash
    @sync begin
        @async live_sync_strategy_cash!(s; overwrite, force)
        @async live_sync_universe_cash!(s; overwrite, force)
    end
end
