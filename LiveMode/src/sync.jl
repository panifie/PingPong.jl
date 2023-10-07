function live_sync_strategy!(s::LiveStrategy; strict=true)
    live_sync_open_orders!(s; strict) # NOTE: before cash
    @sync begin
        @async live_sync_strategy_cash!(s)
        @async live_sync_universe_cash!(s)
    end
end
