function live_sync_strategy_cash!(s::LiveStrategy; kwargs...)
    _, this_kwargs = splitkws(:status; kwargs)
    bal = live_balance(s)
    tot_cash = bal.balance.total
    used_cash = bal.balance.used
    bc = nameof(s.cash)
    function dowarn(msg)
        @warn "strategy cash: sync failed" msg s = nameof(s) cur = bc exc = nameof(
            exchange(s)
        )
    end

    c = if isnothing(tot_cash)
        dowarn("total cash")
        ZERO
    else
        tot_cash
    end
    isapprox(s.cash.value, c; rtol=1e-4) ||
        @warn "strategy cash: total unsynced" loc = cash(s).value rem = c
    cash!(s.cash, c)

    cc = if isnothing(used_cash)
        dowarn("committed cash")
        ZERO
    else
        used_cash
    end
    isapprox(s.cash_committed.value, cc; rtol=1e-4) ||
        @warn "strategy cash: committment unsynced" loc = committed(s) rem = cc
    cash!(s.cash_committed, cc)
    nothing
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
