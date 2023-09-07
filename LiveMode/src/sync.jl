function live_sync_strategy!(s::LiveStrategy)
    live_sync_active_orders!(s) # NOTE: before cash
    @sync begin
        @async live_sync_strategy_cash!(s)
        @async live_sync_universe_cash!(s)
    end
end
