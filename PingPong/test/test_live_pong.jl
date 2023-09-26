include("test_live.jl")

function test_live_pong_margin(s)
    # lm.stop_all_tasks(s)
    ai = s[m"btc"]
    eid = exchangeid(ai)
    lm.live_sync_strategy!(s)
    pos = position(ai)
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
    @info "TEST: " isnothing(pos) long = position(ai, Long).status[] short = position(ai, Short).status[]
    @test isnothing(pos) ||
        (isopen(ai, Long()) && !isopen(ai, Short())) ||
        isopen(ai, Short())
    @test if !isnothing(pos) && isopen(pos)
        @info "TEST: PositionClose"
        v = ect.pong!(s, ai, posside(pos), now(), ect.PositionClose(); waitfor)
        @test !isopen(pos) && !isopen(ai)
        v
    else
        @info "TEST: CancelOrders" side = isnothing(pos) ? nothing : posside(pos)
        @test !isopen(ai)
        ect.pong!(s, ai, ect.CancelOrders(); t=Both)
    end
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
            lm._force_fetchtrades(s, ai, o)
            !isempty(lm.trades(o))
        end
    end
    pup = lm.live_position(s, ai)
    @info "TEST:" pup
    @test !isnothing(position(ai))
    @test !isnothing(pup)
    @info "TEST: Position" date = isnothing(pup) ? nothing : pup.date lm.live_contracts(
        s, ai
    )
    @test inst.timestamp(ai) >= since
    @test cash(ai, Short()) == -0.001 == lm.live_contracts(s, ai, Short())
    @test iszero(cash(ai, Long()))
    @test ect.pong!(s, ai, Short(), now(), ect.PositionClose(); waitfor)
    @test !isopen(ai, Long())
    @test !isopen(ai, Short())
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
    @test !isnothing(pos)
    @test isopen(pos)
    @test !isopen(lm.position(ai, lm.opposite(posside(ai))))
    @test cash(pos) == 0.003 - 0.001 * lm.orderscount(s, ai) == lm.live_contracts(s, ai)
    @test ect.pong!(s, ai, posside(ai), now(), ect.PositionClose(); waitfor)
    @test !isopen(ai)
    @test isempty(lm.active_orders(s, ai))
    @test ect.orderscount(s, ai) == 0
    @test lm.live_contracts(s, ai, side) == 0
end

function test_live_pong_nomargin(s)
    @test s isa lm.NoMarginStrategy
    ai = s[m"btc"]
    eid = exchangeid(ai)
    lm.live_sync_strategy!(s)
    pos = position(ai)
    side = posside(ai)
    since = now()
    waitfor = Second(3)
    @test all(isfinite(cash(ai)) for ai in s.universe)
    for ai in s.universe
        @test isapprox(cash(ai), lm.live_total(s, ai), rtol=1e-1)
        @test isapprox(committed(ai), lm.live_used(s, ai), rtol=1e-1)
        @test isfinite(committed(ai))
    end
end

function test_live_pong()
    @testset "live" begin
        @eval include(joinpath(@__DIR__, "env.jl"))
        @eval _live_load()

        s = live_strat(:ExampleMargin; exchange=:bybit)
        @testset failfast = true test_live_pong_margin(s)
        s = live_strat(:Example; exchange=:bybit)
        @testset failfast = true test_live_pong_nomargin(s)
    end
end
