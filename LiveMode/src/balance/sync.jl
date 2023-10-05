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
    isapprox(s.cash.value, c; rtol=1e-4) ||
        @warn "strategy cash unsynced, local ($(s.cash.value)), remote ($c)"
    cash!(s.cash, c)

    used_cash = get(used, bc, nothing)
    cc = if isnothing(used_cash)
        dowarn("committed cash")
        ZERO
    else
        used_cash
    end
    isapprox(s.cash_committed.value, cc; rtol=1e-4) ||
        @warn "strategy committment unsynced, local ($(s.cash_committed.value)), remote ($cc)"
    cash!(s.cash_committed, cc)
end

@doc """ Asset balance is the true balance when no margin is invoved.


"""
function live_sync_universe_cash!(s::NoMarginStrategy{Live}; kwargs...)
    bal_dict = get_balance(s).balance
    @sync for ai in s.universe
        @debug "Locking ai" ai = raw(ai)
        @async @lock ai begin
            bal_ai = get(bal_dict, bc(ai), nothing)
            if isnothing(bal_ai)
                cash!(ai, ZERO)
                cash!(committed(ai), ZERO)
            else
                cash!(ai, bal_ai.total)
                cash!(committed(ai), bal_ai.used)
            end
        end
    end
end

function live_sync_cash!(
    s::NoMarginStrategy{Live}, ai; since=nothing, waitfor=Second(5), kwargs...
)
    bal = live_balance(s, ai; since, waitfor, force=true)
    @lock ai if isnothing(bal)
        @warn "Resetting asset cash (not found)" ai = raw(ai)
        cash!(ai, ZERO)
        cash!(committed(ai), ZERO)
    elseif isnothing(since) || bal.date >= since
        cash!(ai, bal.balance.total)
        cash!(committed(ai), bal.balance.used)
    else
        @error "Could not update asset cash" since bal.date ai = raw(ai)
    end
end
