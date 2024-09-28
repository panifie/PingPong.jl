function _sync_comm_cash!(s)
    comm = 0.0
    buys = s.buyorders
    sells = s.sellorders
    for ai in s.universe
        this_buys = get(buys, ai, missing)
        if !ismissing(this_buys)
            for o in this_buys
                if o isa IncreaseOrder
                    comm += committed(o)
                end
            end
        end
        this_sells = get(sells, ai, missing)
        if !ismissing(this_sells)
            for o in this_sells
                if o isa IncreaseOrder
                    comm += committed(o)
                end
            end
        end
    end
    if !isapprox(s.cash_committed, comm; rtol=0.01)
        @warn "strategy cash: cash committed unsynced" set = s.cash_committed actual = comm f = @caller(
            10
        )
        cash!(s.cash_committed, comm)
    end
end

@doc """ Synchronizes the cash balance of a live strategy.

$(TYPEDSIGNATURES)

This function synchronizes the cash balance of a live strategy with the actual cash balance on the exchange.
It checks the total and used cash balances, and updates the strategy's cash and committed cash values accordingly.

"""
function _live_sync_strategy_cash!(
    s::Strategy, kind=s.live_balance_kind; bal=nothing, overwrite=false, kwargs...
)
    if isnothing(bal)
        bal = live_balance(s; kwargs...)
    end
    avl_cash = getproperty(bal, kind)
    bc = nameof(s.cash)

    c = if isnothing(avl_cash)
        @warn "strategy cash: sync failed" s = nameof(s) cur = bc exc = nameof(exchange(s))
        0.0
    else
        avl_cash
    end
    if !isapprox(s.cash.value, c; rtol=1e-4)
        @warn "strategy cash: total unsynced" loc = cash(s).value rem = c
    end
    if isfinite(c)
        cash!(s.cash, c)
    else
        @warn "strategy cash: non finite" c kind bal
    end
    # FIXME: cash_committed goes out of sync, possible causes:
    # - unhandled exception before the value is updated
    # - orders are popped but cash is not decommitted? (seems impossible)
    # - trades not updating the comm? Still seems unlikely
    # HACK: resync committed cash from all local orders
    _sync_comm_cash!(s)

    @debug "strategy cash: event" _module = LogSyncCash
    event!(s, ot.BalanceUpdated(s, :strategy_balance_updated, s, bal))
    @debug "strategy cash: synced" _module = LogSyncCash
    nothing
end

@doc """ Synchronizes the cash balance of all assets in a NoMarginStrategy universe.

$(TYPEDSIGNATURES)

The function iterates over each asset in the universe of a `NoMarginStrategy` instance.
For each asset, it locks the asset and updates its cash and committed cash values based on the balance information retrieved from the exchange.
If no balance information is found for an asset, its cash and committed cash values are set to zero.

"""
function _live_sync_universe_cash!(s::NoMarginStrategy{Live}; force=false, waitfor=Second(15), kwargs...)
    @timeout_start
    if force
        waitwatcherupdate(() -> watch_balance!(s))
    end
    bal = live_balance(s; full=true, withoutkws(:overwrite; kwargs)...)
    if isnothing(bal)
        @error "sync uni: failed, no balance" e = exchangeid(s)
        return nothing
    end
    loop_kwargs = filterkws(:fallback_kwargs; kwargs)
    all_synced = Set(ai for ai in universe(s))
    events = get_events(s)
    for ai in s.universe
        push!(all_synced, ai)
        ai_bal = @get bal ai BalanceSnapshot(ai)
        function func()
            live_sync_cash!(s, ai; bal=ai_bal, loop_kwargs...)
            # might not be present, don't use pop!
            delete!(all_synced, ai)
        end
        sendrequest!(ai, bal.date, func; events)
    end
    waitforcond(() -> isempty(all_synced), @timeout_now())
    @debug "sync universe cash(nm): synced"
end

@doc """ Synchronizes the cash balance of a specific asset in a NoMarginStrategy universe.

$(TYPEDSIGNATURES)

The function retrieves the balance information for a specific asset in the universe of a `NoMarginStrategy` instance.
It locks the asset and updates its cash and committed cash values based on the retrieved balance information.
If no balance information is found for the asset, its cash and committed cash values are set to zero.
`drift` is the margin of error for timestamps ([5 milliseconds]).

"""
function _live_sync_cash!(
    s::NoMarginStrategy{Live},
    ai;
    since=nothing,
    waitfor=Second(5),
    force=false,
    drift=Millisecond(5),
    bal=live_balance(s, ai; since, waitfor, force),
    overwrite=false,
    kwargs...,
)
    @inlock ai if bal isa BalanceSnapshot
        @assert isnothing(since) || bal.date >= since - drift
        if overwrite || bal.date != DateTime(0) || !isfinite(cash(ai))
            if isfinite(bal.free)
                cash!(ai, bal.free)
            else
                @warn "asset cash: non finite" ai = raw(ai) bal
            end
            # FIXME: used cash can't be assummed to only account for open orders.
            # It might consider (cross) margin as well (same problem as positions)
            # cash!(committed(ai), this_bal.used)
        end
    else
        @debug "Resetting asset cash (not found)" _module = LogUniSync ai = raw(ai)
        cash!(ai, 0.0)
        cash!(committed(ai), 0.0)
    end
    event!(ai, ot.BalanceUpdated(ai, :asset_balance_updated, s, bal))
end
