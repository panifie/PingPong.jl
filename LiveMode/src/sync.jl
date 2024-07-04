using .Executors:
    hold!,
    queue!,
    decommit!,
    position!,
    reset!,
    PositionOpen,
    PositionClose,
    PositionTrade,
    isqueued,
    hastrade
using .st: Strategy, SimStrategy
using PaperMode.SimMode: _update_from_trade!

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

function _astuple(ev, tr)
    timestamp = Data.todata(tr._buf, ev[1])
    event = if !(timestamp isa DateTime)
        @warn "data: corrupted event trace, expected timestamp" v = timestamp maxlog = 1
        # HACK: try to get the timestamp from the event
        event = timestamp
        timestamp = if hasproperty(event, :timestamp)
            event.timestamp
        else
            DateTime(0)
        end
        event
    else
        Data.todata(tr._buf, ev[2])
    end
    (; timestamp, event)
end
function order_from_event(s, ev)
    o = if hasproperty(ev.event, :order)
        ev.event.order
    elseif hasproperty(ev.event, :data) && hasproperty(ev.event.data, :order)
        ev.event.data.order
    else
        @error "data: corrupted event trace, expected order" ev.event
    end
    ai = asset_bysym(s, raw(o.asset))
    o, ai
end
function trade_tuple(trade)
    timestamp = trade.timestamp
    price = trade.price
    amount = trade.amount
    asset = trade.order.asset
    (; timestamp, price, amount, asset)
end

function execute_trade!(s, o, ai, trade)
    _update_from_trade!(s, ai, o, trade; actual_price=trade.price)
    position!(s, ai, trade)
end

function replay_position!(s::SimStrategy, ai, o::Order)
    this_pos = position(ai, o)
    for t in trades(o)
        if t.date > timestamp(this_pos)
            position!(s, ai, t)
        end
    end
end

function prepare_replay!(live_s::LiveStrategy)
    s = st.similar(live_s; mode=Sim())
    st.default!(s)
    return s
end

function copy_cash!(dst_ai::A, src_ai::A) where {A<:NoMarginInstance}
    cash!(dst_ai, cash(src_ai))
    committed!(dst_ai, committed(src_ai))
end

function copy_cash!(dst_ai::A, src_ai::A) where {A<:MarginInstance}
    cash!(dst_ai, cash(src_ai, Long()))
    committed!(dst_ai, committed(src_ai, Long()))
    cash!(dst_ai, cash(src_ai, Short()))
    committed!(dst_ai, committed(src_ai, Short()))
end

@doc """ Reconstructs strategy state for events trace.

NOTE: Previous ohlcv data must be present from the date of the first event to replay.
"""
function replay_from_trace!(s::LiveStrategy)
    sim_s = prepare_replay!(s)
    tr = exchange(s)._trace
    events = [_astuple(ev, tr) for ev in eachrow(tr._arr)]
    sort!(events; by=ev -> ev.timestamp)
    replay_loop!(sim_s, events)
    for (live_ai, sim_ai) in zip(s.universe, sim_s.universe)
        # copy the trades history from the sim strategy to the live strategy
        append!(trades(live_ai), trades(sim_ai))
        cash!(live_ai, cash(sim_ai))
    end
end

function replay_loop!(s::SimStrategy, events)
    since_idx = findlast(
        ev -> ev.event.tag == :strategy_started && ev.event.group == nameof(s), events
    )
    orders_processed = Dict{String,Order}()
    orders_active = Dict{String,Order}()
    for idx in (since_idx + 1):lastindex(events)
        ev = events[idx]
        if ev.event.group != nameof(s)
            continue
        end
        tag = ev.event.tag
        if tag == :order_created
            trace_create_order!(s, ev; orders_active)
        elseif tag == :order_closed
            trace_close_order!(s, ev; orders_active, orders_processed)
        elseif tag in (:trade_created, :trade_created_emulated)
            trace_execute_trade!(s, ev; orders_processed, orders_active)
        elseif tag == :order_closed_replayed
            trace_close_order!(s, ev; replayed=true, orders_active, orders_processed)
        elseif tag == :strategy_balance_updated
            trace_balance_update!(s, ev)
        elseif tag == :asset_balance_updated
            trace_asset_balance_update!(s, ev)
        elseif tag in (
            :position_updated,
            :position_stale_closed,
            :position_oppos_closed,
            :position_updated_closed,
        )
            trace_sync_position!(s, tag, ev.event)
        elseif tag in (
            :margin_mode_set_isolated,
            :margin_mode_set_cross,
            Symbol("margin_mode_set_Isolated Margin"),
            Symbol("margin_mode_set_Isolated Margin"),
        )
            trace_sync_margin!(s, ev.event)
        elseif tag == :leverage_updated
            trace_sync_leverage!(s, ev.event)
        elseif tag == :strategy_stopped
            break
        else
            @error "trace replay: unknown event tag" tag ev.timestamp
        end
    end
end

@doc """ Synchronizes a position state from a PositionUpdated event.

$(TYPEDSIGNATURES)
"""
function trace_sync_position!(s::Strategy, tag::Symbol, ev::PositionUpdated)
    ai = asset_bysym(s, ev.asset)
    side, status = ev.side_status
    ai = asset_bysym(s, ev.asset)
    pos = position(ai, side)
    if !status
        reset!(pos)
        return nothing
    end
    status!(ai, posside(pos), status ? PositionOpen() : PositionClose())
    timestamp!(pos, ev.timestamp)
    liqprice!(pos, ev.liquidation_price)
    entryprice!(pos, ev.entryprice)
    maintenance!(pos, ev.maintenance_margin)
    initial!(pos, ev.initial_margin)
    leverage!(pos, ev.leverage)
    notional!(pos, ev.notional)
end

@doc """ Synchronizes a margin state from a MarginUpdated event.
"""
function trace_sync_margin!(s::Strategy, ev::MarginUpdated)
    ai = asset_bysym(s, ev.asset)
    pos = position(ai, ev.side)
    if timestamp(pos) > DateTime(0) && !isapprox(ev.from, margin(pos); rtol=1e-4)
        @warn "trace replay: margin update from value mismatch" ev.from margin(pos)
    end
    addmargin!(pos, ev.value)
    if !isempty(ev.mode)
        @assert string(marginmode(pos)) == ev.mode
    end
    timestamp!(pos, ev.timestamp)
end

@doc """ Synchronizes a leverage state from a LeverageUpdated event.

$(TYPEDSIGNATURES)
"""
function trace_sync_leverage!(s::Strategy, ev::LeverageUpdated)
    ai = asset_bysym(s, ev.asset)
    pos = position(ai, ev.side)
    if timestamp(ai) > DateTime(0) && !isapprox(ev.from, leverage(pos); rtol=1e-4)
        @warn "trace replay: leverage update from value mismatch" timestamp(ai) ev.from leverage(
            pos
        )
    end
    leverage!(pos, ev.value)
    timestamp!(pos, ev.timestamp)
end

@doc """ Synchronizes a position state from a PositionUpdated event.

$(TYPEDSIGNATURES)
"""
function trace_create_order!(s::Strategy, ev; orders_active)
    o, ai = order_from_event(s, ev)
    if hasorders(s, ai, o)
        @error "trace replay: order already exists" o.id
        return nothing
    end
    hold!(s, ai, o)
    queue!(s, o, ai)
    replay_position!(s, ai, o)
    orders_active[o.id] = o
end

@doc """ Synchronizes a position state from a PositionUpdated event.

$(TYPEDSIGNATURES)
"""
function trace_close_order!(
    s::Strategy, ev; replayed::Bool, orders_active, orders_processed
)
    o, ai = order_from_event(s, ev)
    if replayed
        if haskey(orders_processed, o.id)
            @debug "trace replay: order_closed_replayed event for already closed order" _module =
                LogTraceReplay o.id
            return nothing
        end
        if !isempty(trades(o))
            @error "trace replay: order_closed_replayed event for order with trades" _module =
                LogTraceReplay o.id replayed
        end
        # is this necessary?
        if isqueued(o, s, ai)
            decommit!(s, o, ai)
            delete!(s, ai, o)
        end
        delete!(orders_active, o.id)
        orders_processed[o.id] = o
        return nothing
    end
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
end

@doc """ Synchronizes a position state from a PositionUpdated event.

$(TYPEDSIGNATURES)
"""
function trace_execute_trade!(s::Strategy, ev; orders_processed, orders_active)
    trade = ev.event.data.trade
    ai = asset_bysym(s, raw(trade.order.asset))
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
            reset!(trade.order, ai)
            hold!(s, ai, trade.order)
            queue!(s, trade.order, ai)
            execute_trade!(s, trade.order, ai, trade)
        end
    end
end

@doc """ Synchronizes a position state from a PositionUpdated event.

$(TYPEDSIGNATURES)
"""
function trace_balance_update!(s::Strategy, ev)
    @debug "trace replay: balance update" _module = LogTraceReplay
    bal = ev.event.data.balance
    if bal.currency == nameof(s.cash)
        kind = s.live_balance_kind
        avl_cash = @something getproperty(bal, kind) ZERO
        if isfinite(avl_cash)
            cash!(s.cash, avl_cash)
        else
            @warn "strategy cash: non finite" c kind bal maxlog = 1
        end
    else
        @error "trace replay: strategy balance wrong currency" event_cur = bal.currency strategy_cur = nameof(
            s.cash
        )
    end
end

@doc """ Synchronizes a position state from a PositionUpdated event.

$(TYPEDSIGNATURES)
"""
function trace_asset_balance_update!(s::Strategy, ev)
    bal = ev.data.balance
    ai = asset_bysym(s, bal.currency)
    if bal.currency == bc(ai)
        if isfinite(bal.free)
            cash!(ai, bal.free)
        else
            @warn "asset cash: non finite" ai = raw(ai) bal
        end
    else
        @error "trace replay: asset_balance_updated event missing balance" ev.data
    end
end
