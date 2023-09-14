function live_sync_strategy_cash!(s::LiveStrategy; kwargs...)
    _, this_kwargs = splitkws(:status; kwargs)
    tot = @something balance!(s; status=TotalBalance, this_kwargs...) (;)
    used = @something balance!(s; status=UsedBalance, this_kwargs...) (;)
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
    isapprox(s.cash, c, rtol=1e-4) ||
        @warn "strategy cash unsynced, local ($(s.cash.value)), remote ($c)"
    cash!(s.cash, c)

    used_cash = get(used, bc, nothing)
    cc = if isnothing(tot_cash)
        dowarn("committed cash")
        ZERO
    else
        used_cash
    end
    isapprox(s.cash_committed, cc, rtol=1e-4) ||
        @warn "strategy committment unsynced, local ($(s.cash_committed.value)), remote ($cc)"
    cash!(s.cash_committed, cc)
end

@doc """ Asset balance is the true balance when no margin is invoved.


"""
function live_sync_universe_cash!(s::NoMarginStrategy{Live}; kwargs...)
    this_kwargs = splitkws(:status; kwargs)
    tot = @something balance!(s; status=TotalBalance, this_kwargs...) (;)
    used = @something balance!(s; status=UsedBalance, this_kwargs...) (;)
    @sync for ai in s.universe
        @debug "Locking ai"
        @async @lock ai begin
            ai_tot = get(tot, ai.bc, ZERO)
            cash!(ai, ai_tot)
            ai_used = get(used, ai.bc, ZERO)
            cash!(committed(ai), ai_used)
        end
    end
end
