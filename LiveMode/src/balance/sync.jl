function live_sync_strategy_cash!(s::LiveStrategy; kwargs...)
    _, this_kwargs = splitkws(:status; kwargs)
    tot = balance!(s; status=TotalBalance, this_kwargs...)
    used = balance!(s; status=UsedBalance, this_kwargs...)
    bc = nameof(s.cash)
    tot_cash = get(tot, bc, nothing)
    function dowarn(what)
        @warn "Couldn't sync strategy($(nameof(s))) $what, currency $bc not found in exchange $(nameof(exchange(s)))"
    end

    c = if isnothing(tot_cash)
        dowarn("total cash")
        ZERO
    else
        tot_cash
    end
    cash!(s.cash, c)

    used_cash = get(used, bc, nothing)
    cc = if isnothing(tot_cash)
        dowarn("committed cash")
        ZERO
    else
        used_cash
    end
    cash!(s.cash_committed, cc)
end

@doc """ Asset balance is the true balance when no margin is invoved.


"""
function live_sync_universe_cash!(s::NoMarginStrategy{Live}; kwargs...)
    this_kwargs = splitkws(:status; kwargs)
    tot = balance!(s; status=TotalBalance, this_kwargs...)
    used = balance!(s; status=UsedBalance, this_kwargs...)
    @sync for ai in s.universe
        @async lock(ai) do
            ai_tot = get(tot, ai.bc, ZERO)
            cash!(ai, ai_tot)
            ai_used = get(used, ai.bc, ZERO)
            cash!!(committed(ai), ai_used)
        end
    end
end
