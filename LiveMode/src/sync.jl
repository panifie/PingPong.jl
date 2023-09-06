function live_sync_strategy!(s::LiveStrategy)
    @sync begin
        live_sync_active_orders!(s) # NOTE: before cash
        @async live_sync_strategy_cash!(s)
        @async live_sync_universe_cash!(s)
    end
end
