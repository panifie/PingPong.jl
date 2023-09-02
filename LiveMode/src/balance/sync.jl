function live_sync_strategy_cash!(s::LiveStrategy; kwargs...)
    _, this_kwargs = splitkws(:status; kwargs)
    tot = balance!(s; status=TotalBalance, this_kwargs...)
    used = balance!(s; status=UsedBalance, this_kwargs...)
    bc = nameof(s.cash)
    tot_cash = get(tot, bc, nothing)
    function dowarn(what)
        @warn "Couldn't sync strategy($(nameof(s))) $what, currency $bc not found in exchange $(nameof(exchange(s)))"
    end

    if isnothing(tot_cash)
        dowarn("total cash")
    else
        cash!(s.cash, tot_cash)
    end
    used_cash = get(used, bc, nothing)
    if isnothing(tot_cash)
        dowarn("committed cash")
    else
        cash!(s.cash_committed, used_cash)
    end
end

@doc """ Asset balance is the true balance when no margin is invoved.


"""
function live_sync_universe_cash!(s::NoMarginStrategy{Live}; kwargs...)
    this_kwargs = splitkws(:status; kwargs)
    tot = balance!(s; status=TotalBalance, this_kwargs...)
    used = balance!(s; status=UsedBalance, this_kwargs...)
    for ai in s.universe
        ai_tot = get(tot, ai.bc, ZERO)
        cash!(ai, ai_tot)
    end
end


function live_sync_universe!(s::MarginStrategy{Live}; kwargs...)
end

function live_sync_strategy!(s::LiveStrategy)
    @sync begin
        @async live_sync_strategy_cash!(s)
        @async live_sync_universe!(s)
        # TODO
    end
    s
end
