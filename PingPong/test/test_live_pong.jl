include("test_live.jl")

function test_live_pong_limit(s)
    # lm.stop_all_tasks(s)
    ai = s[m"btc"]
    eid = exchangeid(ai)
    lm.live_sync_strategy!(s)
    pos = position(ai)
    side = posside(ai)
    since = now()
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
            @info "TEST: " cash(ai)
            @test abs(cash(ai)) == lm.resp_position_contracts(resps[idx], eid)
        end
    end
    @test isnothing(pos) || !(isopen(ai, Long()) || !isopen(ai, Short()))
    @test if !isnothing(pos) && isopen(pos)
        @info "TEST: PositionClose"
        v = ect.pong!(s, ai, posside(pos), now(), ect.PositionClose())
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
    trade = ect.pong!(s, ai, ShortGTCOrder{Sell}; amount=0.001, price=lastprice(ai) - 10)
    pup = lm.live_position(s, ai)
    @info "TEST:" pup
    if ismissing(trade)
        o = first(values(s, ai, Sell))
        @test lm.waitfortrade(s, ai, o, waitfor=Second(20))
    end
    @test !isnothing(position(ai))
    @test !isnothing(pup)
    @info "TEST: Position" date = isnothing(pup) ? nothing : pup.date lm.live_contracts(
        s, ai
    )
    @test inst.timestamp(ai) >= since
    @test cash(ai, Short()) == -0.001 == lm.live_contracts(s, ai, Short())
    @test iszero(cash(ai, Long()))
    return nothing
    ect.pong!(s, ai, Short(), now(), ect.PositionClose())
    @test !isopen(ai, Long())
    @test !isopen(ai, Short())
    @sync begin
        price = lastprice(ai) - 10
        @async ect.pong!(s, ai, ShortGTCOrder{Sell}; amount=0.001, price)
        @async ect.pong!(s, ai, ShortGTCOrder{Sell}; amount=0.001, price)
        @async ect.pong!(s, ai, ShortGTCOrder{Sell}; amount=0.001, price)
    end
    @test cash(ai) == -0.003 == lm.live_contracts(s, ai)
    ect.pong!(s, ai, Short(), now(), ect.PositionClose())
end

function test_live_pong()
    @testset "live" begin
        @eval include(joinpath(@__DIR__, "env.jl"))
        @eval _live_load()

        s = live_strat(:ExampleMargin; exchange=:bybit)
    end
end
