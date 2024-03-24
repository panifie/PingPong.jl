@doc """ Synchronizes the cash balance of a live strategy.

$(TYPEDSIGNATURES)

This function synchronizes the cash balance of a live strategy with the actual cash balance on the exchange.
It checks the total and used cash balances, and updates the strategy's cash and committed cash values accordingly.

"""
function live_sync_strategy_cash!(s::LiveStrategy, kind=s[:live_balance_kind]; bal=nothing, overwrite=false, kwargs...)
    bal = @something bal live_balance(s; kwargs...)
    avl_cash = getproperty(bal.balance, kind)
    bc = nameof(s.cash)

    c = if isnothing(avl_cash)
        @warn "strategy cash: sync failed" s = nameof(s) cur = bc exc = nameof(
            exchange(s)
        )
        ZERO
    else
        avl_cash
    end
    if !isapprox(s.cash.value, c; rtol=1e-4)
        @warn "strategy cash: total unsynced" loc = cash(s).value rem = c
    end
    cash!(s.cash, c)

    nothing
end

@doc """ Synchronizes the cash balance of all assets in a NoMarginStrategy universe.

$(TYPEDSIGNATURES)

The function iterates over each asset in the universe of a `NoMarginStrategy` instance.
For each asset, it locks the asset and updates its cash and committed cash values based on the balance information retrieved from the exchange.
If no balance information is found for an asset, its cash and committed cash values are set to zero.

"""
function live_sync_universe_cash!(s::NoMarginStrategy{Live}; kwargs...)
    bal = live_balance(s; kwargs...)
    loop_kwargs = filterkws(:fallback_kwargs; kwargs)
    @sync for ai in s.universe
        @async live_sync_cash!(s, ai; bal, loop_kwargs...)
    end
end

@doc """ Synchronizes the cash balance of a specific asset in a NoMarginStrategy universe.

$(TYPEDSIGNATURES)

The function retrieves the balance information for a specific asset in the universe of a `NoMarginStrategy` instance.
It locks the asset and updates its cash and committed cash values based on the retrieved balance information.
If no balance information is found for the asset, its cash and committed cash values are set to zero.
`drift` is the margin of error for timestamps ([5 milliseconds]).

"""
function live_sync_cash!(
    s::NoMarginStrategy{Live}, ai;
    since=nothing,
    waitfor=Second(5),
    force=false,
    drift=Millisecond(5),
    bal=live_balance(s, ai; since, waitfor, force),
    overwrite=false
)
    @lock ai if bal isa BalanceSnapshot
        @assert isnothing(since) || bal.date >= since - drift
        if overwrite || bal.date != DateTime(0) || !isfinite(cash(ai))
            this_bal = bal.balance
            cash!(ai, this_bal.free)
            # FIXME: used cash can't be assummed to only account for open orders.
            # It might consider (cross) margin as well (same problem as positions)
            # cash!(committed(ai), this_bal.used)
        end
    else
        @debug "Resetting asset cash (not found)" _module = LogUniSync ai = raw(ai)
        cash!(ai, ZERO)
        cash!(committed(ai), ZERO)
    end
end
