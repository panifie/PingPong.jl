@doc """ Synchronizes a live trading strategy.

$(TYPEDSIGNATURES)

This function synchronizes both open orders and cash balances of the live strategy `s`.
The synchronization is performed in parallel for cash balances of the strategy and its universe.
The `overwrite` parameter controls whether to ignore the `read` state of an update.

"""
function live_sync_strategy!(s::LiveStrategy; overwrite=false, force=false)
    live_sync_open_orders!(s; overwrite) # NOTE: before cash
    @sync begin
        @async live_sync_strategy_cash!(s; overwrite, force)
        @async live_sync_universe_cash!(s; overwrite, force)
    end
end

_astuple(ev, tr) = begin
    timestamp = Data.todata(tr._buf, ev[1])
    if !(timestamp isa DateTime)
        @warn "data: corrupted event trace, expected timestamp"
        timestamp = DateTime(0)
    end
    event = Data.todata(tr._buf, ev[2])
    (; timestamp, event)
end
function order_from_event(s, ev)
    o = ev.event.order
    ai = asset_byid(raw(o.asset))
    o, ai
end
function trade_tuple(trade)
    timestamp = trade.timestamp
    price = trade.price
    amount = trade.amount
    asset = trade.asset
    (; timestamp, price, amount, asset)
end

function execute_trade!(s, o, ai, trade)
    trade!(
        s,
        o,
        ai;
        nothing,
        trade,
        date=nothing,
        price=nothing,
        actual_amount=nothing,
        fees=nothing,
        slippage=false,
    )
    position!(s, ai, trade)
end

function replay_position!(s::LiveStrategy, ai, o::Order)
    this_pos = position(ai, o)
    for t in trades(o)
        if t.date > timestamp(this_pos)
            position!(s, ai, t)
        end
    end
end

@doc """ Reconstructs strategy state for events trace.

NOTE: Previous ohlcv data must be present from the date of the first event to replay.
"""
function replay_from_trace!(s::LiveStrategy)
    tr = exchange(s)._trace
    events = [_astuple(ev, tr) for ev in eachrow(tr._arr)]
    sort!(events; by=ev -> ev.timestamp)
    maxout!(s)
    orders_processed = Dict{String,Order}()
    orders_active = Dict{String,Order}()
    for ev in events
        tag = ev.event.tag
        if tag == :order_created
            o, ai = order_from_event(s, ev)
            hold!(s, ai, trade.order)
            queue!(s, o, ai)
            invoke(position!, Tuple{Strategy,MarginInstance,PositionTrade}, s, ai, o)
            replay_position!(s, ai, o)
            orders_active[o.id] = o
        elseif tag == :order_closed
            o, ai = order_from_event(s, ev)
            if isqueued(o, s, ai)
                if isfilled(ai, o)
                    trades_amount = _amount_from_trades(trades(o))
                    if !isequal(ai, trades_amount, o.amount, Val(:amount))
                        @error "trace replay: unexpected closed order amount" o.id trades_amount o.amount unfilled(
                            o
                        )
                    end
                    decommit!(s, o, ai)
                    delete!(s, ai, o)
                else
                    @error "trace replay: order_closed event can't be unfilled" o.id o.amount unfilled(
                        o
                    )
                end
            end
            this_pos = position(ai)
            replay_position!(s, ai, o)
            delete!(orders_active, o.id)
            orders_processed[o.id] = o
        elseif tag in (:trade_created, :trade_created_emulated)
            trade = ev.event.data.trade
            ai = asset_byid(trade.asset)
            average_price = ev.event.data.avgp
            # the version in orders_processed should have all trades in it
            order_proc = get(orders_processed, trade.order.id, nothing)
            if !isnothing(order_proc) # the order was closed, so should have all trades
                if !hastrade(order_proc, trade)
                    @error "trace replay: trade expected to be in order" trade.id order_proc.id
                end
            else
                o = get(orders_active, trade.order.id, nothing) # check if the order exists
                if !isnothing(o) # the order is still open
                    if !hastrade(o, trade) # execute the trade
                        execute_trade!(s, o, ai, trade)
                    end
                else # the trade somewhat has a timestamp older than the order creation or the order event wasn't registered
                    # enqueue the order and re-execute the trade
                    reset!(trade.order)
                    hold!(s, ai, trade.order)
                    queue!(s, trade.order, ai)
                    execute_trade!(s, trade.order, ai, trade)
                end
            end
        elseif tag == :order_closed_replayed
            o, ai = order_from_event(s, ev)
            if haskey(orders_processed, o.id)
                @debug "trace replay: order_closed_replayed event for already closed order" o.id
                return nothing
            end
            if !isempty(trades(o))
                @error "trace replay: order_closed_replayed event for order with trades" o.id
            end
            # is this necessary?
            if isqueued(s, o, ai)
                decommit!(s, o, ai)
                delete!(s, ai, o)
            end
            delete!(orders_active, o.id)
            orders_processed[o.id] = o
        elseif tag == :strategy_balance_updated
            if ev.data.sym == nameof(s.cash)
                live_sync_strategy_cash!(s, ai; overwrite=true, force)
            else
                @error "trace replay: strategy balance wrong currency" event_cur =
                    ev.data.sym strategy_cur = nameof(s.cash)
            end
        elseif tag == :asset_balance_updated
            bal = @coalesce get(ev.data, :balance, missing) bal = BalanceSnapshot(
                ev.data.currency, ev.data.date, ev.data.total, ev.data.free, ev.data.used
            )
            if !ismissing(bal)
                live_sync_cash!(s, ai; bal, overwrite=true)
            else
                @error "trace replay: asset_balance_updated event missing balance" ev.data
            end
        elseif tag in (
            :position_updated,
            :position_stale_closed,
            :position_oppos_closed,
            :position_updated_closed,
        )
            trace_sync_position!(s, tag, ev)
        elseif tag == (:margin_mode_set_isolated, :margin_mode_set_cross)
            trace_sync_margin!(s, ev)
        elseif tag == :leverage_updated
            trace_sync_leverage!(s, ev)
        else
            @error "trace replay: unknown event tag" tag
        end
    end
end

@doc """ Synchronizes a position state from a PositionUpdated event.
"""
function trace_sync_position!(s::Strategy, tag::Symbol, ev::PositionUpdated)
    ai = asset_byid(ev.asset)
    side, status = ev.side_status
    ai = asset_byid(pup.asset)
    pos = position(ai, side)
    status!(pos, status ? PositionOpen() : PositionClose())
    timestamp!(pos, pup.timestamp)
    liqprice!(pos, pup.liquidation_price)
    entryprice!(pos, pup.entryprice)
    maintenance!(pos, pup.maintenance_margin)
    initial!(pos, pup.initial_margin)
    leverage!(pos, pup.leverage)
    notional!(pos, pup.notional)
end

@doc """ Synchronizes a margin state from a MarginUpdated event.
"""
function trace_sync_margin!(s::Strategy, ev::MarginUpdated)
    ai = asset_byid(ev.asset)
    pos = position(ai, ev.side)
    if !isapprox(ev.from, margin(pos); rtol=1e-4)
        @warn "trace replay: margin update from value mismatch" ev.from margin(pos)
    end
    addmargin!(pos, ev.value)
    if !isempty(ev.mode)
        @assert string(marginmode(pos)) == ev.mode
    end
    timestamp!(pos, ev.timestamp)
end

@doc """ Synchronizes a leverage state from a LeverageUpdated event.
"""
function trace_sync_leverage!(s::Strategy, ev::LeverageUpdated)
    ai = asset_byid(ev.asset)
    pos = position(ai, ev.side)
    if !isapprox(ev.from, leverage(pos); rtol=1e-4)
        @warn "trace replay: leverage update from value mismatch" ev.from leverage(pos)
    end
    leverage!(pos, ev.value)
    timestamp!(pos, ev.timestamp)
end