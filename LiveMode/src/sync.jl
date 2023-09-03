function live_sync_strategy!(s::LiveStrategy; strategy_cash=true, universe_cash=true)
    @sync begin
        strategy_cash && @async live_sync_strategy_cash!(s)
        universe_cash && @async live_sync_universe_cash!(s)
    end
end
