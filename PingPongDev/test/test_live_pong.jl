using Base: _wait2
using Test
using PingPongDev.PingPong.Engine.Lang: @m_str

function _check_state(s, ai)
    lm.waitsync(s, since=now())
    lm.waitsync(ai, since=now())
    eid = exchangeid(ai)
    if !(s.cash > 0.0)
        @warn "TEST: sync failed" lm.get_events(s)
    end
    @test s.cash > 0.0
    @test all(isfinite(cash(ai, side)) for ai in s.universe, side in (Long, Short))
    @info "TEST: check state loop" ai
    pos = position(ai)
    for ai in s.universe, side in (Long, Short)
        @test isapprox(cash(ai, side), lm.live_contracts(s, ai, side, synced=true), rtol=1e-1)
        @test isfinite(committed(ai, side))
    end
    _get(v, args...) = get(v, args...)
    _get(::Nothing, _, def) = def
    @info "TEST: check state sides" ai
    for side in (Long, Short)
        pside = posside(ai)
        resps = @something lm.fetch_positions(s, ai; side=pside, timeout=Second(10)) _get(lm.get_positions(s, ai, side), :resp, missing)
        if Python.pyisinstance(resps, pybuiltins.dict)
            resps = [resps]
        elseif Python.pyisinstance(resps, pybuiltins.list)
            resps = PyList(resps)
        end
        if !ismissing(resps) && !isnothing(resps)
            @info "TEST: check state" typeof(resps) length(resps) pytp = resps isa Py ? pytype(resps) : nothing
            idx = findfirst(resps) do resp
                string(lm.resp_position_symbol(resp, eid)) == raw(ai) &&
                    string(lm.resp_position_side(resp, eid)) == lm._ccxtposside(side)
            end
            if !isnothing(idx)
                @info "TEST: check state" side cash(ai)
                @test abs(cash(ai, side)) == abs(lm.resp_position_contracts(resps[idx], eid))
            end
        end
    end
    @info "TEST: check state finish" isnothing(pos) long = position(ai, Long).status[] short = position(ai, Short).status[] s[m"btc"]
    @test isnothing(position(ai)) ||
          (isopen(ai, Long()) && !isopen(ai, Short())) ||
          isopen(ai, Short())
end

function _reset_remote_pos(s, ai)
    for side in (Long, Short)
        pos = position(ai, side)
        waitfor = round(lm.throttle(s), Second, RoundUp) + Second(1)
        @test if isopen(ai, Long) || isopen(ai, Short)
            @info "TEST: PositionClose" posside(pos) cash(ai)
            ect.pong!(s, ai, posside(pos), now(), ect.PositionClose(); waitfor)
        else
            @test !isopen(ai)
            @info "TEST: CancelOrders" side = isnothing(pos) ? nothing : posside(pos)
            lm.waitsync(ai)
            if ect.pong!(s, ai, ect.CancelOrders(); t=BuyOrSell)
                true
            else
                lm.waitsync(ai; waitfor)
            end
        end
    end
    @test !isopen(ai)
    @test isempty(lm.active_orders(ai))
    @test ect.orderscount(s, ai) == 0
end

_waitwatchers(s) = begin
    bw = lm.balance_watcher(s)
    while bw[:last_processed] == DateTime(0)
        @info "TEST: waiting for balance watcher initial update" bw.view
        lm.safewait(bw.beacon.process)
    end
    if s isa lm.MarginStrategy
        pw = lm.positions_watcher(s)
        while pw[:last_processed] == DateTime(0)
            @info "TEST: waiting for position watcher initial update"
            lm.safewait(pw.beacon.process)
        end
    end
end

function test_live_pong_mg(s)
    @info "TEST: pong mg"
    ai = s[m"btc"]
    amount = 2ai.limits.amount.min
    eid = exchangeid(ai)
    @info "TEST: strategy reset"
    reset!(s)

    waitfor = 2 * round(lm.throttle(s), Second)
    @test lm.hasattr(s, :trades_cache_ttl)
    @info "TEST: strategy sync"
    _live_sync_strategy!(s)
    lm.start_handlers!(s)
    sleep(0)
    let t = s.event_handler
        @test istaskstarted(t) && !istaskdone(t)
    end
    for ai in s.universe
        t = ai.event_handler
        @test istaskstarted(t) && !istaskdone(t)
    end
    @info "TEST: wait watchers"
    _waitwatchers(s)
    since = now()
    pos = position(ai)
    #  TODO: wait for first sync
    _check_state(s, ai)
    setglobal!(Main, :s, s)

    _reset_remote_pos(s, ai)
    @info "TEST: live contracts"
    @test lm.live_contracts(s, ai, Short(); since, force=true) == 0
    @info "TEST: livecontracs2" w = lm.positions_watcher(s)
    @test lm.live_contracts(s, ai, Long(); since, force=true) == 0
    lm.waitsync(s, waitwatchers=true)
    @test !isopen(ai)

    @info "TEST: Short sell" amount cash(ai, Short)
    trade = ect.pong!(s, ai, ShortGTCOrder{Sell}; amount, price=lastprice(ai) - 100, skipchecks=true)
    @test !isnothing(trade)
    o = nothing
    if ismissing(trade)
        o = first(values(s, ai, Sell))
        @info "TEST: trades delay" o.id lm.isownable(ai._internal_lock)
        while !lm.isfilled(ai, o)
            lm.waittrade(s, ai, o; waitfor) || lm.waitorder(s, ai, o; waitfor)
        end
    else
        o = trade.order
    end
    @test lm.waittrade(s, ai, o; waitfor) || lm.waitorder(s, ai, o; waitfor) || @lock ai lm.isfilled(ai, o)
    @info "TEST:" trade cash(ai)
    @test (lm.live_contracts(s, ai, force=true) < 0.0) || iszero(cash(ai))
    pup = @something lm.live_position(s, ai) lm.live_position(s, ai, since=last(lm.trades(o)).date)
    @info "TEST: " pup
    @test !isnothing(position(ai))
    @test !isnothing(pup)
    @info "TEST: Position" date = isnothing(pup) ? nothing : pup.date lm.live_contracts(
        s, ai
    )
    @test inst.timestamp(ai) >= since
    timeout = now() + Second(10)
    while !ect.isfilled(ai, last(ect.trades(ai)).order) && now() < timeout
        @info "TEST: waiting for fill"
        sleep(1)
    end
    @test cash(ai, Short()) == -amount == lm.live_contracts(s, ai, Short(), since=last(ai.history).date, force=true)
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
    @test iszero(lm.live_contracts(s, ai, Long))
    @test iszero(lm.live_contracts(s, ai, Short))
    @info "TEST: Long Buy waittrade" position(ai)
    orders_offset = length(lm.ordershistory(ai))
    since = now()
    price = lastprice(ai) + 100
    long_amount = min(s.cash * 0.3 / price, amount * price)
    w = lm.positions_watcher(s)
    n_trades = 0
    @sync begin
        for n in 0:2
            sleep_n = n
            @async let
                sleep(sleep_n) # this avoid potential orders having same date on some exchanges
                trade = ect.pong!(s, ai, GTCOrder{Buy}; amount=long_amount, price, waitfor)
                if !isnothing(trade)
                    n_trades += 1
                    if ismissing(trade)
                        lm.waittrade(s, ai, first(values(s, ai, Buy)); waitfor=Second(10)) ||
                            lm._force_fetchtrades(s, ai, first(values(s, ai, Buy)))
                    end
                end
            end
        end
    end
    @test n_trades > 0
    while lm.timestamp(ai, Long) < since
        @info "TEST: waiting for timestamp" isstarted(w) lm.timestamp(ai, Long) since
        @lock w nothing
        sleep(1)
    end
    @info "TEST: timestamp updated" lm.timestamp(ai, Long)
    pos = position(ai)
    @test lm.islong(pos)
    @test !isnothing(pos)
    @test isopen(pos)
    @test !isopen(lm.position(ai, lm.opposite(posside(ai))))
    tries = 0
    while lm.orderscount(s, ai) > 0
        @info "TEST: waiting for orders to be closed"
        lm.waitsync(ai)
        sleep(tries)
        tries += 1
        if tries > 15
            error("TEST: orders still pending")
        end
    end
    since = lm.trades(ai)[end].date
    lm.live_position(s, ai; since, force=true)
    @test lm.timestamp(ai) >= since
    n_test_orders = length(lm.ordershistory(ai)) - orders_offset
    @info "TEST: orders amount" length(lm.ordershistory(ai)) orders_offset
    lm.waitsync(s, waitwatchers=true)
    lm.waitsync(ai)
    orders_amount = sum(o.amount for o in lm.ordershistory(ai)[orders_offset+1:end])
    contracts = lm.live_contracts(s, ai, force=true)
    this_cash = cash(pos)
    @info "TEST: " lm.orderscount(s, ai) lm.ordershistory(ai) cash(ai) contracts n_test_orders orders_offset since lm.timestamp(ai) lm.get_positions(s, ai, posside(ai)).date
    @test this_cash ≈ orders_amount ≈ contracts
    pside = posside(ai)
    @info "TEST: Position Close (3rd)"
    @test !isnothing(lm.get_positions(s, ai, Short()))
    tries = 0
    while tries < 3
        if ect.pong!(s, ai, posside(ai), now(), ect.PositionClose(); waitfor)
            break
        end
        tries += 1
    end
    @test !isopen(ai)
    @test isempty(lm.active_orders(ai))
    @test ect.orderscount(s, ai) == 0
    @test lm.live_contracts(s, ai, force=true) == 0
end

function test_live_pong_nm_gtc(s)
    @info "TEST: pong nm gtc"
    @test s isa lm.NoMarginStrategy
    ai = s[m"btc"]
    setglobal!(Main, :ai, ai)
    eid = exchangeid(ai)
    reset!(s)
    _live_sync_strategy!(s)
    since = now()
    waitfor = Second(3)
    _waitwatchers(s)
    if lm.hasorders(s, ai)
        @test ect.pong!(s, ai, ect.CancelOrders(); t=BuyOrSell)
        @test lm.waitsync(ai, waitfor=Second(3))
    end
    lm.waitsync(s, waitfor=Second(5), waitwatchers=true)
    @info "TEST: init" length(s.events) upds = length(lm.balance_watcher(s))
    @test s.cash > 0.0
    @test all(isfinite(cash(ai)) for ai in s.universe)
    for ai in s.universe
        @test isapprox(cash(ai), lm.live_free(s, ai), rtol=1e-1)
        @test isfinite(committed(ai))
        @test iszero(lm.orderscount(s, ai)) || isapprox(committed(ai), sum(lm.unfilled(o) for o in values(lm.orders(s, ai))))
    end
    lp = lastprice(ai)
    price = lp + lp * 0.02
    amount = 0.001
    t = ect.pong!(s, ai, GTCOrder{Buy}; amount, price, waitfor)
    if ismissing(t)
        o = first(values(s, ai))
        if lm.waittrade(s, ai, o; waitfor=Second(10))
            @test length(lm.trades(o)) > 0
        else
            lm._force_fetchtrades(s, ai, o)
            if length(lm.trades(o)) > 0
                @test first(lm.trades(o)) isa Trade
            end
        end
    elseif isnothing(t)
        @test isempty(collect(values(s, ai, Buy)))
    else
        @test t isa Trade
    end
    lp = lastprice(s, ai, Buy, Val(:ob))
    buy_count = lm.orderscount(s, ai, Buy)
    sell_count = lm.orderscount(s, ai, Sell)
    buy_price = lp - lp * 0.10
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
    @info "TEST: pong nm market"
    @test s isa st.NoMarginStrategy
    reset!(s)
    @test lm.hasattr(s, :trades_cache_ttl)
    _live_sync_strategy!(s)
    _waitwatchers(s)
    ai = s[m"btc"]
    side = Buy
    prev_trades = length(ai.history)
    prev_cash = cash(ai).value
    waitfor = Second(5)
    this_price = lastprice(ai)
    amount = ai.limits.cost.min / this_price + ai.limits.amount.min
    @info "TEST: market 1" prev_cash
    if s.cash < amount * this_price
        lm.pong!(s, ai, MarketOrder{Sell}, amount=prev_cash)
    end
    t = ect.pong!(s, ai, MarketOrder{side}; amount)
    if ismissing(t)
        o = last(lm.orders(s, ai, side))
        @test isfilled(ai, o) || lm.waitorder(s, ai, o; waitfor=Second(3))
    else
        @test t isa Trade
        o = t.order
    end
    @info "TEST: nm_market for order" o lm.filled_amount(o) length(lm.trades(o)) lm.feespaid(o)
    @test lm.waitorder(s, ai, o; waitfor=Second(3))
    @test ect.isfilled(ai, o)
    lm.waitsync(ai, waitfor=Second(3))
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
        lm.waitsync(ai, waitfor=Second(3))
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
    reset!(s)
    _live_sync_strategy!(s)
    _waitwatchers(s)
    waitfor = Second(5)
    since = now()
    lm.waitsync(s; since, waitfor, waitwatchers=true)
    @info "TEST: nm $type" length(lm.balance_watcher(s).buf_process)
    @test s.cash > 0.0
    ai = s[m"btc"]
    lm.waitsync(ai; since, waitfor)
    amount = ai.limits.cost.min / lastprice(ai) + ai.limits.amount.min
    lp = lastprice(ai)
    price = lp - 100
    this_quote = s.cash.value
    if cash(ai) <= 0.0 || committed(ai) <= 0.0
        lm.live_sync_cash!(s, ai, waitfor=Second(3))
    end
    if lm.isdust(ai, lp)
        ect.pong!(s, ai, MarketOrder{Buy}; amount=3amount, waitfor)
        lm.waitorder(s, ai, first(s, ai, Buy))
        @test s.cash <= this_quote - last(ai.history).order.value
    end
    @test cash(ai) >= 3amount
    prev_cash = cash(ai).value
    prev_quote = s.cash.value
    prev_trades = length(ai.history)
    side = Sell # this test assumes sell
    t = nothing
    tries = 3
    while isnothing(t)
        lp = lastprice(ai)
        price = lp - 100
        amount = ai.limits.cost.min / price + ai.limits.amount.min
        @info "TEST: " committed(ai)
        t = ect.pong!(s, ai, type{side}; amount, price, waitfor)
        t isa Trade && break
    end
    @test t isa Trade
    o = t.order
    @info "TEST: " typeof(o)
    @test o isa type{side}
    lm.waitsync(ai; waitfor)
    lm.live_sync_cash!(s, ai; since=last(ect.trades(o)).date + Millisecond(1), waitfor=Second(3))
    lm.waitorder(s, ai, o, waitfor=Second(3))
    @test ect.isfilled(ai, o)
    @test !ect.hasorders(s, ai, o.id, side)
    filled = sum(getproperty.(ect.trades(o), :amount))
    diff = cash(ai) - prev_cash
    @info "TEST: " diff prev_cash cash(ai) filled
    @test ect.ltxzero(ai, diff, Val(:amount))
    fees = sum(getproperty.(ect.trades(o), :fees))
    fees_base = sum(getproperty.(ect.trades(o), :fees_base))
    val = sum(getproperty.(ect.trades(o), :value))
    expected_quote = prev_quote + val - fees - fees_base * price
    @info "TEST: " fees fees_base prev_quote val expected_quote s.cash.value
    quote_diff = s.cash - expected_quote
    @test ect.gtxzero(ai, quote_diff, Val(:cost))
    @test isapprox(s.cash, expected_quote) || isapprox(lm.live_total(s, since=last(lm.trades(o)).date), expected_quote)
    @test length(ai.history) > prev_trades
end

function test_live_pong_nm_ioc(s)
    @info "TEST: pong nm ioc"
    _test_live_nm_fok_ioc(s, IOCOrder)
end

function test_live_pong_nm_fok(s)
    @info "TEST: pong nm fok"
    start!(s)
    @test lm.hasattr(s, :trades_cache_ttl)
    @test isrunning(s)
    lm.waitsync(s, waitwatchers=true)
    _live_sync_strategy!(s)
    _test_live_nm_fok_ioc(s, FOKOrder)
    ai = s[m"btc"]
    waitfor = Second(5)
    amount = ai.limits.amount.min
    price = lastprice(s, ai, Sell)
    sell_price = price + price * 0.08
    (cash(ai) <= 0.0 || committed(ai) <= 0.0) && lm.live_sync_cash!(s, ai, waitfor=Second(3))
    prev_cash = cash(ai).value
    prev_quote = s.cash.value
    prev_trades = length(ai.history)
    prev_comm = committed(ai)
    prev_orders = length(lm.orders(s, ai, Sell))
    t = ect.pong!(s, ai, FOKOrder{Sell}; amount, price=sell_price, waitfor)
    @info "TEST: " t
    if ismissing(t)
        @test lm.waitorder(s, ai, waitfor=Second(10))
    elseif !isnothing(t)
        @test length(lm.orders(s, ai, Sell)) == prev_orders
        @test isnothing(t) || ismissing(t) && hasorders(s, ai)
        @test prev_cash == cash(ai)
        @test prev_comm == committed(ai)
        @test prev_quote == s.cash || isapprox(prev_quote, lm.live_total(s, since=lm.last(ai.history, force=true).date), Val(:amount))
        @test prev_trades == length(ai.history)
    else
        @warn "TEST: last test group failed"
    end
end

mm_debug = "Executors,LogWatchPos,LogWatchPosProcess,LogWatchTrade,LogPosClose,LogCreateOrder,LogCreateTrade,LogEvents"
nm_debug = "Executors,LogWatchTrade,LogCreateOrder,LogCreateTrade,LogEvents"

# NOTE: phemex testnet is disabled during weekends
function test_live_pong(exchange=EXCHANGE, mm_exchange=EXCHANGE_MM; debug="Executors,LogCreateOrder,LogSyncOrder,LogWatchOrder,LogWatchTrade,LogPosSync,LogTradeFetch",
    sync=false, stop=true, save=false, clear_deadlocks=true)
    @eval begin
        if !isdefined(Main, :_live_load)
            using Pkg
            include(joinpath(dirname(Pkg.project().path), "test", "test_live.jl"))
        end
        if !isdefined(Main, :FAILFAST)
            FAILFAST = true
        end
        _live_load()
        if isdefined(Main, :s) && Main.s isa st.Strategy
            @info "stopping existing strategy"
            stop!(s)
        end
    end
    prev_debug = get(ENV, "JULIA_DEBUG", "")
    if !isempty(debug)
        ENV["JULIA_DEBUG"] = debug
    end
    try
        let cbs = st.STRATEGY_LOAD_CALLBACKS.live
            if lm.load_strategy_cache ∉ cbs
                push!(cbs, lm.load_strategy_cache)
            end
        end
        if clear_deadlocks
            empty!(mi.lock_errors)
        end
        @eval @testset failfast = FAILFAST "live" begin

            exchange = $(QuoteNode(exchange))
            mm_exchange = $(QuoteNode(mm_exchange))
            s = live_strat(:ExampleMargin; exchange=mm_exchange, initial_cash=1e8, skip_sync=true)
            name = string(lm.exchange(s).id)
            if startswith(name, "binance")
                lm.exchange(s).py.timeout = 20000
            end
            setglobal!(Main, :s, s)
            try
                @testset test_live_pong_mg(s)
            finally
                setglobal!(Main, :w, lm.watch_positions!(s))
                if $stop
                    t = @async lm.stop!(s)
                    if $sync
                        wait(t)
                    end
                end
            end
            s = live_strat(:Example; exchange, initial_cash=1e8, skip_sync=true)
            setglobal!(Main, :s, s)
            try
                @testset test_live_pong_nm_gtc(s)
                @testset test_live_pong_nm_market(s)
                @testset test_live_pong_nm_ioc(s)
                @testset test_live_pong_nm_fok(s)
            finally
                if $stop
                    t = @async lm.stop!(s)
                    if $sync
                        wait(t)
                    end
                end
                if $save
                    lm.save_strategy_cache(s, inmemory=true)
                end
            end
        end
    finally
        ENV["JULIA_DEBUG"] = prev_debug
    end
end

function _live_sync_strategy!(s)
    lm.live_sync_strategy_cash!(s)
    lm.live_sync_universe_cash!(s)
end
