using Test
using PingPongDev.PingPong.Engine.Lang: @m_str

function _check_state(s, ai)
    eid = exchangeid(ai)
    pos = position(ai)
    side = posside(ai)
    @test s.cash > ZERO
    @test all(isfinite(cash(ai, side)) for ai in s.universe, side in (Long, Short))
    for ai in s.universe, side in (Long, Short)
        @info "TEST: check state" ai side
        @test isapprox(cash(ai, side), lm.live_contracts(s, ai, side, force=true), rtol=1e-1)
        @test isfinite(committed(ai, side))
    end
    if !isnothing(side)
        let resps = lm.fetch_positions(s, ai; side=posside(ai)) |> PyList
            idx = findfirst(resps) do resp
                string(lm.resp_position_symbol(resp, eid)) == raw(ai) &&
                    string(lm.resp_position_side(resp, eid)) == lm._ccxtposside(posside(ai))
            end
            @info "TEST: check state" side cash(ai)
            @test abs(cash(ai)) == lm.resp_position_contracts(resps[idx], eid)
        end
    end
    @info "TEST: check state" isnothing(pos) long = position(ai, Long).status[] short = position(ai, Short).status[] s[m"btc"]
    @test isnothing(pos) ||
          (isopen(ai, Long()) && !isopen(ai, Short())) ||
          isopen(ai, Short())
end

function _reset_remote_pos(s, ai)
    pos = position(ai)
    @test if !isnothing(pos) && isopen(pos)
        @info "TEST: PositionClose" posside(pos)
        ect.pong!(s, ai, posside(pos), now(), ect.PositionClose(); waitfor=Second(3))
    else
        @info "TEST: CancelOrders" side = isnothing(pos) ? nothing : posside(pos)
        @test !isopen(ai)
        if ect.pong!(s, ai, ect.CancelOrders(); t=BuyOrSell)
            true
        else
            lm.waitfor_closed(s, ai, Second(3); t=BuyOrSell)
        end
    end
    @test !isopen(ai)
    @test isempty(lm.active_orders(s, ai))
    @test ect.orderscount(s, ai) == 0
end

function test_live_pong_mg(s)
    ai = s[m"btc"]
    eid = exchangeid(ai)
    start!(s)
    @test lm.hasattr(s, :trades_cache_ttl)
    @test lm.isrunning(s)
    lm.live_sync_strategy!(s, force=true)
    side = posside(ai)
    since = now()
    waitfor = Second(3)
    pos = position(ai)
    @test lm.isrunning(s)

    _check_state(s, ai)
    setglobal!(Main, :s, s)
    @test lm.isrunning(s)

    _reset_remote_pos(s, ai)
    @test lm.live_contracts(s, ai, side) == 0
    @test lm.isrunning(s)

    @info "TEST: Short sell"
    trade = ect.pong!(s, ai, ShortGTCOrder{Sell}; amount=0.001, price=lastprice(ai) - 100)
    @test !isnothing(trade)
    if ismissing(trade)
        o = first(values(s, ai, Sell))
        @info "TEST: trades delay" o.id
        @test lm.waitfortrade(s, ai, o; waitfor=Second(3)) || lm.waitfororder(s, ai, o, waitfor=Second(3))
    end
    pup = lm.live_position(s, ai, force=true)
    @info "TEST:" pup trade
    @test lm.live_contracts(s, ai, force=true) < ZERO || iszero(cash(ai))
    @test !isnothing(position(ai))
    @test !isnothing(pup) # FLAPS
    @info "TEST: Position" date = isnothing(pup) ? nothing : pup.date lm.live_contracts(
        s, ai
    )
    @test inst.timestamp(ai) >= since
    @test cash(ai, Short()) == -0.001 == lm.live_contracts(s, ai, Short(), since=last(ai.history).date, force=true)
    @test iszero(cash(ai, Long()))
    @test isopen(ai, Short())
    @info "TEST: Position Close (2nd)"
    ect.pong!(s, ai, Short(), now(), ect.PositionClose(); waitfor)
    @info "TEST: wait posclose" waitfor
    lm.waitposclose(s, ai, Short(); waitfor=Second(10))
    @test lm.waitposclose(s, ai, Short(); waitfor=Second(0))
    @test !isopen(ai, Long())
    @test !isopen(ai, Short())
    @test iszero(cash(ai, Short()))
    @info "TEST: Long Buy waitfortrade" position(ai)
    @sync begin
        price = lastprice(ai) + 100
        for n in 0:2
            sleep_n = n
            @async let
                sleep(sleep_n) # this avoid potential orders having same date on some exchanges
                trade = ect.pong!(s, ai, GTCOrder{Buy}; amount=0.001, price, waitfor)
                if ismissing(trade)
                    lm.waitfortrade(s, ai, first(values(s, ai, Buy)); waitfor=Second(10)) ||
                        lm._force_fetchtrades(s, ai, first(values(s, ai, Buy)))
                end
            end
        end
    end
    pos = position(ai)
    @test lm.islong(pos)
    @test !isnothing(pos)
    @test isopen(pos)
    @test !isopen(lm.position(ai, lm.opposite(posside(ai))))
    while lm.orderscount(s, ai) > 0
        @info "TEST: waiting for orders to be closed"
        lm.waitfor_closed(s, ai)
    end
    @info "TEST: " lm.orderscount(s, ai) cash(ai)
    @test cash(pos) == 0.003 - 0.001 * lm.orderscount(s, ai) == lm.live_contracts(s, ai, force=true) # FLAPS
    pside = posside(ai)
    @info "TEST: Position Close (3rd)"
    @test !isnothing(lm.get_positions(s, ai, Short()))
    @test if ect.pong!(s, ai, posside(ai), now(), ect.PositionClose(); waitfor)
        true
    else
        @info "TEST: waitposclose" pside lm.live_contracts(s, ai)
        if !lm.waitposclose(s, ai, posside(ai); waitfor) || error()
            lm._force_fetchpos(s, ai; fallback_kwargs=(;))
        end
        lm.live_sync_position!(s, ai, force=true)
        lm.waitposclose(s, ai, posside(ai); waitfor=Second(0))
    end
    @test !isopen(ai)
    @test isempty(lm.active_orders(s, ai))
    @test ect.orderscount(s, ai) == 0
    @test lm.live_contracts(s, ai, force=true) == 0
end

function test_live_pong_nm_gtc(s)
    @test s isa lm.NoMarginStrategy
    start!(s)
    ai = s[m"btc"]
    eid = exchangeid(ai)
    lm.live_sync_strategy!(s)
    since = now()
    waitfor = Second(3)
    @test all(isfinite(cash(ai)) for ai in s.universe)
    for ai in s.universe
        @test isapprox(cash(ai), lm.live_total(s, ai), rtol=1e-1)
        @test isapprox(committed(ai), lm.live_used(s, ai), rtol=1e-1)
        @test isfinite(committed(ai))
    end
    @test s.cash > ZERO
    if lm.hasorders(s, ai)
        @test ect.pong!(s, ai, ect.CancelOrders(); t=BuyOrSell)
    end
    lp = lastprice(ai)
    price = lp + lp * 0.02
    amount = 0.001
    t = ect.pong!(s, ai, GTCOrder{Buy}; amount, price, waitfor)
    if ismissing(t)
        o = first(values(s, ai))
        if lm.waitfortrade(s, ai, o; waitfor=Second(10))
            @test length(lm.trades(o)) > 0
        else
            lm._force_fetchtrades(s, ai, o)
            if length(lm.trades(o)) > 0
                @test first(lm.trades(o)) isa Trade
            end
        end
    elseif isnothing(t)
        @test isempty(values(s, ai, Buy))
    else
        @test t isa Trade
    end
    lp = lastprice(s, ai, Buy)
    buy_count = lm.orderscount(s, ai, Buy)
    sell_count = lm.orderscount(s, ai, Sell)
    buy_price = lp - lp * 0.04
    @info "TEST: " buy_price
    t = ect.pong!(s, ai, GTCOrder{Buy}; amount, price=buy_price, waitfor)
    @info "TEST: " t
    @test ismissing(t)
    @test lm.orderscount(s, ai, Buy) == buy_count + 1
    @test lm.orderscount(s, ai, Sell) == sell_count
    lp = lastprice(s, ai, Sell)
    ect.pong!(s, ai, GTCOrder{Buy}; amount, price=buy_price, waitfor)
    @test lm.orderscount(s, ai, Buy) == buy_count + 2
    sell_price = lp + lp * 0.04
    @info "TEST: " sell_price
    ect.pong!(s, ai, GTCOrder{Sell}; amount, price=sell_price, waitfor)
    @test lm.orderscount(s, ai, Buy) == buy_count + 2
    @test lm.orderscount(s, ai, Sell) == 1
    @test ect.pong!(s, ai, ect.CancelOrders(); t=Buy)
    @test lm.orderscount(s, ai, Buy) == 0
    @test lm.orderscount(s, ai, Sell) == 1
    @test ect.pong!(s, ai, ect.CancelOrders(); t=BuyOrSell)
    @test lm.orderscount(s, ai) == 0
end

function test_live_pong_nm_market(s)
    @test s isa st.NoMarginStrategy
    start!(s)
    @test lm.isrunning(s)
    @test lm.hasattr(s, :trades_cache_ttl)
    lm.live_sync_strategy!(s, force=true)
    ai = s[m"btc"]
    side = Buy
    prev_trades = length(ai.history)
    prev_cash = cash(ai).value
    waitfor = Second(5)
    amount = 0.02
    if s.cash < amount * lastprice(ai)
        lm.pong!(s, ai, MarketOrder{Sell}, amount=prev_cash)
    end
    t = ect.pong!(s, ai, MarketOrder{side}; amount)
    if ismissing(t)
        o = last(lm.orders(s, ai, side))
        @test isfilled(ai, o) || lm.waitfororder(s, ai, o; waitfor=Second(3))
    else
        @test t isa Trade
        o = t.order
    end
    @info "TEST: nm_market for order" o lm.filled_amount(o) length(lm.trades(o)) lm.feespaid(o)
    @test lm.waitfororder(s, ai, o; waitfor=Second(3))
    @test ect.isfilled(ai, o)
    @test lm.waitfor_closed(s, ai, Second(3); t=side)
    @info "TEST: nm_market sync cash" o.id last(ect.trades(o)).date
    lm.live_sync_cash!(s, ai; since=last(ect.trades(o)).date + Millisecond(1), force=true)
    @test !ect.hasorders(s, ai, o.id, side)
    fees = sum(getproperty.(ect.trades(o), :fees_base))
    @info "TEST: nm_market fees" fees
    diff = cash(ai) - prev_cash + amount
    @info "TEST: nm_market gtxzero" cash(ai) diff prev_cash amount fees
    @test ect.gtxzero(ai, diff, Val(:amount))
    @test length(ai.history) > prev_trades
    t = ect.pong!(s, ai, MarketOrder{side}; amount, waitfor=Second(0), synced=false, skipchecks=true)
    @test ismissing(t) || t isa Trade
    @test if ect.isfilled(ai, o)
        @test lm.waitfor_closed(s, ai, Second(3); t=side)
        o = last(lm.trades(ai)).order
        @test o isa ect.MarketOrder{side}
        trade = last(ect.trades(o))
        lm.live_sync_cash!(s, ai; since=trade.date + Millisecond(1), waitfor=Second(3), force=true)
        fees = sum(getproperty.(ect.trades(o), :fees_base))
        @info "TEST: market fees" fees
        diff = cash(ai).value - (prev_cash + amount - fees)
        ect.gtxzero(ai, diff, Val(:amount))
    else
        ao = lm.active_orders(s, ai)
        @test !isempty(ao)
        o = first(values(ao)).order
        @info "TEST: " o
        @test isapprox(prev_cash, cash(ai)) || length(lm.trades(o)) > 0 # unfilled or partially filled
        ect.hasorders(s, ai, o.id, side)
    end
end

function _test_live_nm_fok_ioc(s, type)
    lm.live_sync_strategy!(s)
    @test s.cash > ZERO
    ai = s[m"btc"]
    waitfor = Second(5)
    amount = 0.001
    price = lastprice(ai) - 100
    if cash(ai) <= ZERO || committed(ai) <= ZERO
        lm.live_sync_cash!(s, ai, waitfor=Second(3))
    end
    if cash(ai) <= ZERO
        ect.pong!(s, ai, MarketOrder{Buy}; amount=3amount, waitfor)
    end
    @test cash(ai) > ZERO
    prev_cash = cash(ai).value
    prev_quote = s.cash.value
    prev_trades = length(ai.history)
    side = Sell # this test assumes sell
    @info "TEST: " committed(ai)
    t = ect.pong!(s, ai, type{side}; amount, price, waitfor)
    @test t isa Trade
    o = t.order
    @info "TEST: " typeof(o)
    @test o isa type{side}
    @test lm.waitfor_closed(s, ai, Second(3); t=side)
    lm.live_sync_cash!(s, ai; since=last(ect.trades(o)).date + Millisecond(1), waitfor=Second(3))
    lm.waitfororder(s, ai, o, waitfor=Second(3))
    @test ect.isfilled(ai, o)
    @test !ect.hasorders(s, ai, o.id, side)
    filled = sum(getproperty.(ect.trades(o), :amount))
    diff = cash(ai) - prev_cash
    @info "TEST: " diff prev_cash cash(ai) filled
    @test ect.ltxzero(ai, diff, Val(:amount))
    fees = sum(getproperty.(ect.trades(o), :fees))
    val = sum(getproperty.(ect.trades(o), :value))
    @info "TEST: " fees val
    expected_quote = prev_quote + val - fees
    quote_diff = s.cash - expected_quote
    @test ect.gtxzero(ai, quote_diff, Val(:cost))
    @test isapprox(s.cash, expected_quote)
    @test length(ai.history) > prev_trades
end

function test_live_pong_nm_ioc(s)
    _test_live_nm_fok_ioc(s, IOCOrder)
end

function test_live_pong_nm_fok(s)
    start!(s)
    @test lm.hasattr(s, :trades_cache_ttl)
    @test isrunning(s)
    lm.live_sync_strategy!(s)
    _test_live_nm_fok_ioc(s, FOKOrder)
    ai = s[m"btc"]
    waitfor = Second(5)
    amount = 0.001
    price = lastprice(s, ai, Sell)
    sell_price = price + price * 0.08
    (cash(ai) <= ZERO || committed(ai) <= ZERO) && lm.live_sync_cash!(s, ai, waitfor=Second(3))
    prev_cash = cash(ai).value
    prev_quote = s.cash.value
    prev_trades = length(ai.history)
    prev_comm = committed(ai)
    prev_orders = length(lm.orders(s, ai, Sell))
    t = ect.pong!(s, ai, FOKOrder{Sell}; amount, price=sell_price, waitfor)
    @info "TEST: " t
    if ismissing(t)
        @test lm.waitfororder(s, ai, waitfor=Second(10))
    end
    @test length(lm.orders(s, ai, Sell)) == prev_orders
    @test isnothing(t) || ismissing(t) && hasorders(s, ai)
    @test prev_cash == cash(ai)
    @test prev_comm == committed(ai)
    @test prev_quote == s.cash
    @test prev_trades == length(ai.history)
end

# NOTE: phemex testnet is disabled during weekends
function test_live_pong(exchange=:phemex; debug=true, sync=false)
    @eval _live_load()
    if debug
        ENV["JULIA_DEBUG"] = "LiveMode,Executors"
    end
    let cbs = st.STRATEGY_LOAD_CALLBACKS.live
        if lm.load_strategy_cache ∉ cbs
            push!(cbs, lm.load_strategy_cache)
        end
    end
    @eval @testset failfast = FAILFAST "live" begin

        exchange = $(QuoteNode(exchange))
        s = live_strat(:ExampleMargin; exchange, initial_cash=1e8)
        s[:sync_history_limit] = 0
        setglobal!(Main, :s, s)
        try
            @testset test_live_pong_mg(s)
        finally
            t = @async lm.stop!(s)
            if $sync
                wait(t)
            end
        end
        s = live_strat(:Example; exchange, initial_cash=1e8)
        s[:sync_history_limit] = 0
        setglobal!(Main, :s, s)
        try
            @testset test_live_pong_nm_gtc(s)
            @testset test_live_pong_nm_market(s)
            @testset test_live_pong_nm_ioc(s)
            @testset test_live_pong_nm_fok(s)
        finally
            t = @async lm.stop!(s)
            if $sync
                wait(t)
            end
            s[:sync_history_limit] = 0
            reset!(s)
            lm.save_strategy_cache(s, inmemory=true)
        end
    end
end
