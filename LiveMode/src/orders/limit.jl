
function create_live_limit_order(s::LiveStrategy, t::Type{<:AnyLimitOrder}, ai; amount, kwargs...)
    s.config.initial_cash = 1e8
    doreset!(s)
    @test execmode(s) == Paper()
    @test s isa st.NoMarginStrategy
    ai = s[m"eth"]
    date = now()
    prev_cash = s.cash.value
    ect.pong!(s, ai, ot.GTCOrder{ot.Buy}; amount=0.02, date)
    @test length(collect(ect.orders(s, ai))) == 1 || length(ai.history) > 0
    o = if length(ai.history) > 0
        last(ai.history).order
    else
        first(values(ect.orders(s, ai, ot.Buy)))
    end
    if haskey(st.attr(s, :paper_order_tasks), o)
        task, alive = st.attr(s, :paper_order_tasks)[o]
        @test istaskdone(task) || alive[]
        wait(task)
    end
    @test ect.isfilled(ai, last(ai.history).order)
    @test s.cash <= prev_cash
    @test !ect.iszero(cash(ai, Long()))
    date = now()
    prev_cash = s.cash.value
    this_p = lastprice(ai)
    t = ect.pong!(
        s, ai, ot.GTCOrder{ot.Sell}; amount=0.01, price=this_p - this_p / 100.0, date
    )
    if haskey(st.attr(s, :paper_order_tasks), o)
        task, alive = st.attr(s, :paper_order_tasks)[o]
        @test istaskdone(task) || !alive[]
        wait(task)
    end
    @test ect.isfilled(ai, last(ai.history).order)
    @test s.cash >= prev_cash
    @test !ect.iszero(cash(ai, Long())) && cash(ai, Long()) < 0.02
    _, taken_vol, total_vol = st.attr(s, :paper_liquidity)[ai]
    t = ect.pong!(
        s,
        ai,
        ot.GTCOrder{ot.Buy};
        amount=total_vol[] / 100.0,
        price=this_p - this_p / 100000.0,
        date,
    )
    o = first(ect.orders(s, ai, ot.Buy))[2]
    prev_len = length(o.attrs.trades)
    start_mon = now()
    was_filled = false
    ect.isfilled(ai, o) || while now() - start_mon < Second(10)
        sleep(1)
        length(o.attrs.trades) > prev_len && (was_filled = true; break)
    end
    @test ect.isfilled(ai, o) ||
        length(o.attrs.trades) > prev_len ||
        lastprice(ai) >= o.price
    amount = total_vol[] / 100.0
    price = this_p * 2.0
    date += Millisecond(1)
    this_vol = 0.0
    while taken_vol[] + amount < total_vol[]
        t = ect.pong!(s, ai, ot.GTCOrder{ot.Buy}; amount, price, date)
        date += Millisecond(1)
        t isa ot.Trade && (this_vol += t.amount)
        yield()
    end
    n_orders = ect.orderscount(s, ai)
    t = ect.pong!(
        s, ai, ot.GTCOrder{ot.Buy}; amount=total_vol[] / 100.0, price=this_p, date
    )
    @test n_orders == ect.orderscount(s, ai)
    @test isnothing(t)
    @test s.cash < s.initial_cash - this_vol * this_p
end
