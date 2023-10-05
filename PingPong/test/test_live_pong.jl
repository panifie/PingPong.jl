include("test_live.jl")

function test_live_pong_mg(s)
    # lm.stop_all_tasks(s)
    ai = s[m"btc"]
    eid = exchangeid(ai)
    lm.live_sync_strategy!(s)
    side = posside(ai)
    since = now()
    waitfor = Second(3)
    @test all(isfinite(cash(ai, side)) for ai in s.universe, side in (Long, Short))
    for ai in s.universe, side in (Long, Short)
        @test isapprox(cash(ai, side), lm.live_contracts(s, ai, side), rtol=1e-1)
        @test isfinite(committed(ai, side))
    end
    if !isnothing(side)
        let resps = lm.fetch_positions(s, ai; side=posside(ai)) |> PyList
            idx = findfirst(resps) do resp
                string(lm.resp_position_symbol(resp, eid)) == raw(ai) &&
                    string(lm.resp_position_side(resp, eid)) == lm._ccxtposside(posside(ai))
            end
            @info "TEST: " side cash(ai)
            @test abs(cash(ai)) == lm.resp_position_contracts(resps[idx], eid)
        end
    end
    pos = position(ai)
    @info "TEST: " isnothing(pos) long = position(ai, Long).status[] short = position(ai, Short).status[]
    @test isnothing(pos) ||
        (isopen(ai, Long()) && !isopen(ai, Short())) ||
        isopen(ai, Short())
    @test if !isnothing(pos) && isopen(pos)
        @info "TEST: PositionClose"
        v = ect.pong!(s, ai, posside(pos), now(), ect.PositionClose(); waitfor=Day(1))
        @test !isopen(pos) && !isopen(ai)
        v
    else
        @info "TEST: CancelOrders" side = isnothing(pos) ? nothing : posside(pos)
        @test !isopen(ai)
        ect.pong!(s, ai, ect.CancelOrders(); t=Both)
    end
    setglobal!(Main, :s, s)
    @test !isopen(ai)
    @test isempty(lm.active_orders(s, ai))
    @test ect.orderscount(s, ai) == 0
    @test lm.live_contracts(s, ai, side) == 0
    since = now()
    trade = ect.pong!(s, ai, ShortGTCOrder{Sell}; amount=0.001, price=lastprice(ai) - 100)
    if ismissing(trade)
        o = first(values(s, ai, Sell))
        @info "TEST: trades delay"
        @test lm.waitfortrade(s, ai, o; waitfor=Second(10)) || begin
            while true
                lm._force_fetchtrades(s, ai, o)
                isempty(lm.trades(o)) || break
                lm.hasorders(s, ai, o)
                sleep(1)
            end
            !isempty(lm.trades(o))
        end
    end
    pup = lm.live_position(s, ai)
    @info "TEST:" pup
    @test !isnothing(position(ai))
    @test !isnothing(pup) # FLAPS
    @info "TEST: Position" date = isnothing(pup) ? nothing : pup.date lm.live_contracts(
        s, ai
    )
    @test inst.timestamp(ai) >= since
    @test cash(ai, Short()) == -0.001 == lm.live_contracts(s, ai, Short())
    @test iszero(cash(ai, Long()))
    @test isopen(ai, Short())
    ect.pong!(s, ai, Short(), now(), ect.PositionClose(); waitfor)
    while true
        lm.waitposclose(s, ai, Short(); waitfor) && break
    end
    @test !isopen(ai, Long())
    @test !isopen(ai, Short())
    @test iszero(cash(ai, Short()))
    @sync begin
        price = lastprice(ai) + 100
        for _ in 1:3
            @async let trade = ect.pong!(s, ai, GTCOrder{Buy}; amount=0.001, price, waitfor)
                if ismissing(trade)
                    lm.waitfortrade(s, ai, first(values(s, ai, Buy)); waitfor=Second(10)) ||
                        lm._force_fetchtrades(s, ai, first(values(s, ai, Buy)))
                end
            end
            sleep(Millisecond(1))
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
    @test cash(pos) == 0.003 - 0.001 * lm.orderscount(s, ai) == lm.live_contracts(s, ai) # FLAPS
    pside = posside(ai)
    ect.pong!(s, ai, posside(ai), now(), ect.PositionClose(); waitfor)
    while true
        lm.waitposclose(s, ai, pside; waitfor) && break
    end
    @test !isopen(ai)
    @test isempty(lm.active_orders(s, ai))
    @test ect.orderscount(s, ai) == 0
    @test lm.live_contracts(s, ai, side) == 0
end

function test_live_pong_nm_gtc(s)
    @test s isa lm.NoMarginStrategy
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
        @test ect.pong!(s, ai, ect.CancelOrders(); t=Both)
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
    @test ect.pong!(s, ai, ect.CancelOrders(); t=Both)
    @test lm.orderscount(s, ai) == 0
end

function test_live_pong_nm_market(s)
    ai = s[m"btc"]
    side = Buy
    prev_trades = length(ai.history)
    prev_cash = cash(ai).value
    waitfor = Second(5)
    amount = 0.001
    t = ect.pong!(s, ai, MarketOrder{side}; amount, waitfor)
    @test t isa Trade
    o = t.order
    @test lm.waitfor_closed(s, ai, Second(20); t=side)
    lm.live_sync_cash!(s, ai; since=last(ect.trades(o)).date + Millisecond(1))
    @test ect.isfilled(ai, o)
    @test !ect.hasorders(s, ai, o.id, side)
    fees = sum(getproperty.(ect.trades(o), :fees_base))
    @info "TEST: market fees" fees
    # @test cash(ai).value >= prev_cash + amount - fees
    diff = cash(ai).value - (prev_cash + amount - fees)
    @test ect.gtxzero(ai, diff, Val(:amount))
    @test length(ai.history) > prev_trades
    t = ect.pong!(s, ai, MarketOrder{side}; amount, waitfor=Second(0), synced=false)
    @test ismissing(t)
    o = first(values(lm.active_orders(s, ai))).order
    @info "TEST: " o
    @test o isa ect.MarketOrder{side}
    @test lm.waitfor_closed(s, ai, Second(20); t=side)
    @test if ect.isfilled(ai, o)
        trade = last(ect.trades(o))
        lm.live_sync_cash!(s, ai; since=trade.date + Millisecond(1))
        fees = sum(getproperty.(ect.trades(o), :fees_base))
        @info "TEST: market fees" fees
        diff = cash(ai).value - (prev_cash + amount - fees)
        ect.gtxzero(ai, diff, Val(:amount))
    else
        @test isapprox(prev_cash, cash(ai))
        !ect.hasorders(s, ai, o.id, side)
    end
end

function _test_live_nm_fok_ioc(s, type)
    ai = s[m"btc"]
    waitfor = Second(5)
    amount = 0.001
    price = lastprice(ai) - 100
    (cash(ai) <= ZERO || committed(ai) <= ZERO) && lm.live_sync_cash!(s, ai)
    cash(ai) <= ZERO && ect.pong!(s, ai, MarketOrder{Buy}; amount=3amount, waitfor)
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
    @test lm.waitfor_closed(s, ai, Second(20); t=side)
    lm.live_sync_cash!(s, ai; since=last(ect.trades(o)).date + Millisecond(1))
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
    # _test_live_nm_fok_ioc(s, FOKOrder)
    ai = s[m"btc"]
    waitfor = Second(5)
    amount = 0.001
    price = lastprice(s, ai, Sell)
    sell_price = price + price * 0.08
    (cash(ai) <= ZERO || committed(ai) <= ZERO) && lm.live_sync_cash!(s, ai)
    prev_cash = cash(ai).value
    prev_quote = s.cash.value
    prev_trades = length(ai.history)
    prev_comm = committed(ai)
    prev_orders = length(lm.orders(s, ai, Sell))
    t = ect.pong!(s, ai, FOKOrder{Sell}; amount, price=sell_price, waitfor)
    @info "TEST: " t
    @test length(lm.orders(s, ai, Sell)) == prev_orders
    @test isnothing(t) || ismissing(t) && hasorders()
    @test prev_cash == cash(ai)
    @test prev_comm == committed(ai)
    @test prev_quote == s.cash
    @test prev_trades == length(ai.history)
end

function test_live_pong()
    @testset failfast = true "live" begin
        @eval include(joinpath(@__DIR__, "env.jl"))
        @eval _live_load()

        s = live_strat(:ExampleMargin; exchange=:bybit)
        @testset failfast = true test_live_pong_mg(s)
        s = live_strat(:Example; exchange=:bybit)
        @testset test_live_pong_nm_gtc(s)
        @testset test_live_pong_nm_market(s)
        @testset test_live_pong_nm_ioc(s)
        @testset test_live_pong_nm_fok(s)
    end
end
